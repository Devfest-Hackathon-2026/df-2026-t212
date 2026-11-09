import AVFoundation
import CoreLocation
import CoreVideo
import Flutter
import Metal
import Photos
import UIKit

/// The After Hue camera. Every frame of the viewfinder is developed on the
/// GPU with the same look the photo will get: the kept colors over a toned
/// black and white. Only the area mask is left out. The shutter saves the
/// untouched original to the photo library; After Hue keeps the look.
///
/// Without a camera (the Simulator), a still photo stands in for the feed so
/// the screen can still be worked on.
final class LiveCamera: NSObject, FlutterTexture, AVCaptureVideoDataOutputSampleBufferDelegate,
  AVCapturePhotoCaptureDelegate, CLLocationManagerDelegate
{
  static func register(registrar: FlutterPluginRegistrar) {
    let camera = LiveCamera(textures: registrar.textures())
    let channel = FlutterMethodChannel(name: "afterhue/camera", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in camera.handle(call, result) }
    shared = camera
  }

  private static var shared: LiveCamera?

  private let textures: FlutterTextureRegistry
  private var textureId: Int64 = -1
  private let session = AVCaptureSession()
  private let videoOutput = AVCaptureVideoDataOutput()
  private let photoOutput = AVCapturePhotoOutput()
  private let queue = DispatchQueue(label: "afterhue.camera")
  private var configured = false
  private var stillTimer: DispatchSourceTimer?
  private var still: CVPixelBuffer?

  // GPU
  private let device = MTLCreateSystemDefaultDevice()
  private lazy var commandQueue = device?.makeCommandQueue()
  private lazy var pipeline: MTLComputePipelineState? = {
    guard let device, let lib = try? device.makeLibrary(source: Self.kernel, options: nil),
      let fn = lib.makeFunction(name: "develop")
    else { return nil }
    return try? device.makeComputePipelineState(function: fn)
  }()
  private var cache: CVMetalTextureCache?
  private var pool: CVPixelBufferPool?
  private var poolSize = CGSize.zero

  // Shared between the camera queue and the platform thread.
  private let lock = NSLock()
  private var latestOut: CVPixelBuffer?
  private var latestIn: CVPixelBuffer?
  private var look = Look()
  private var frameCount = 0

  // Where the photo was taken.
  private let location = CLLocationManager()
  private var lastLocation: CLLocation?

  private var pendingCapture: FlutterResult?

  init(textures: FlutterTextureRegistry) {
    self.textures = textures
    super.init()
    location.delegate = self
    location.desiredAccuracy = kCLLocationAccuracyHundredMeters
  }

  // MARK: - Channel

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "start":
      start(stillPath: args["still"] as? String, result: result)
    case "stop":
      stop()
      result(nil)
    case "look":
      setLook(args)
      result(nil)
    case "sample":
      let x = args["x"] as? Double ?? 0.5, y = args["y"] as? Double ?? 0.5
      result(sample(x: x, y: y))
    case "thumb":
      result(thumb(width: args["width"] as? Int ?? 96))
    case "capture":
      capture(result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Session

  private func start(stillPath: String?, result: @escaping FlutterResult) {
    let haveCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
    if !haveCamera {
      guard let stillPath, let image = UIImage(contentsOfFile: stillPath) else {
        result(FlutterError(code: "unavailable", message: "No camera on this device", details: nil))
        return
      }
      startStill(image, result: result)
      return
    }
    AVCaptureDevice.requestAccess(for: .video) { granted in
      DispatchQueue.main.async {
        guard granted else {
          result(FlutterError(code: "denied", message: "Camera access was not allowed", details: nil))
          return
        }
        self.startLocation()
        self.queue.async {
          do {
            try self.configure()
            self.session.startRunning()
            let size = self.previewSize()
            DispatchQueue.main.async {
              self.registerTexture()
              result(["texture": self.textureId, "width": size.width, "height": size.height])
            }
          } catch {
            DispatchQueue.main.async {
              result(FlutterError(code: "configure", message: "\(error)", details: nil))
            }
          }
        }
      }
    }
  }

  private func registerTexture() {
    if textureId < 0 { textureId = textures.register(self) }
  }

  private func stop() {
    stillTimer?.cancel()
    stillTimer = nil
    location.stopUpdatingLocation()
    queue.async {
      if self.session.isRunning { self.session.stopRunning() }
    }
    if textureId >= 0 {
      textures.unregisterTexture(textureId)
      textureId = -1
    }
    lock.lock()
    latestOut = nil
    latestIn = nil
    lock.unlock()
  }

  private func configure() throws {
    if configured { return }
    guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
      throw NSError(domain: "camera", code: 1)
    }
    session.beginConfiguration()
    defer { session.commitConfiguration() }
    session.sessionPreset = .inputPriority
    let input = try AVCaptureDeviceInput(device: camera)
    if session.canAddInput(input) { session.addInput(input) }

    // A 4:3 format small enough to develop every frame, that still takes
    // full-size photos.
    let format = camera.formats
      .filter { f in
        let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        return abs(Double(d.width) / Double(d.height) - 4.0 / 3.0) < 0.01 && d.width <= 1920
          && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
      }
      .max { a, b in
        CMVideoFormatDescriptionGetDimensions(a.formatDescription).width
          < CMVideoFormatDescriptionGetDimensions(b.formatDescription).width
      }
    try camera.lockForConfiguration()
    if let format { camera.activeFormat = format }
    if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
    if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
    camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
    camera.unlockForConfiguration()

    videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    videoOutput.alwaysDiscardsLateVideoFrames = true
    videoOutput.setSampleBufferDelegate(self, queue: queue)
    if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
    if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
    if #available(iOS 16.0, *), let biggest = camera.activeFormat.supportedMaxPhotoDimensions.max(by: {
      $0.width * $0.height < $1.width * $1.height
    }) {
      photoOutput.maxPhotoDimensions = biggest
    }
    photoOutput.maxPhotoQualityPrioritization = .quality
    if let conn = videoOutput.connection(with: .video) { Self.upright(conn, portrait: true) }
    configured = true
  }

  /// Turns a connection to the phone held upright, or to how it is held now.
  private static func upright(_ conn: AVCaptureConnection, portrait: Bool) {
    let angle: CGFloat
    if portrait {
      angle = 90
    } else {
      switch UIDevice.current.orientation {
      case .landscapeLeft: angle = 0
      case .landscapeRight: angle = 180
      case .portraitUpsideDown: angle = 270
      default: angle = 90
      }
    }
    if #available(iOS 17.0, *) {
      if conn.isVideoRotationAngleSupported(angle) { conn.videoRotationAngle = angle }
    } else if conn.isVideoOrientationSupported {
      conn.videoOrientation =
        switch angle {
        case 0: .landscapeRight
        case 180: .landscapeLeft
        case 270: .portraitUpsideDown
        default: .portrait
        }
    }
  }

  private func previewSize() -> CGSize {
    guard let f = (session.inputs.first as? AVCaptureDeviceInput)?.device.activeFormat else {
      return CGSize(width: 3, height: 4)
    }
    let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
    // Delivered upright, so the long side is the height.
    return CGSize(width: Int(min(d.width, d.height)), height: Int(max(d.width, d.height)))
  }

  // MARK: - Still stand-in

  private func startStill(_ image: UIImage, result: @escaping FlutterResult) {
    let side: CGFloat = 1440
    let w = Int(side * 3 / 4), h = Int(side)
    guard let buffer = Self.makeBuffer(width: w, height: h) else {
      result(FlutterError(code: "unavailable", message: "No camera on this device", details: nil))
      return
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    if let ctx = CGContext(
      data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    {
      // Fill the 3:4 frame, as the camera would.
      let s = max(CGFloat(w) / image.size.width, CGFloat(h) / image.size.height)
      let dw = image.size.width * s, dh = image.size.height * s
      UIGraphicsPushContext(ctx)
      ctx.translateBy(x: 0, y: CGFloat(h))
      ctx.scaleBy(x: 1, y: -1)
      image.draw(in: CGRect(x: (CGFloat(w) - dw) / 2, y: (CGFloat(h) - dh) / 2, width: dw, height: dh))
      UIGraphicsPopContext()
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    still = buffer
    registerTexture()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(33))
    timer.setEventHandler { [weak self] in
      guard let self, let still = self.still else { return }
      self.process(still)
    }
    timer.resume()
    stillTimer = timer
    result(["texture": textureId, "width": w, "height": h])
  }

  // MARK: - Frames

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    process(pixels)
  }

  private func process(_ input: CVPixelBuffer) {
    frameCount += 1
    lock.lock()
    latestIn = input
    var look = self.look
    lock.unlock()
    // The light's color moves slowly; measure it a few times a second.
    if frameCount % 10 == 1 || look.castStale {
      let (a, b) = Self.lightCast(input)
      lock.lock()
      self.look.castA = a
      self.look.castB = b
      self.look.castStale = false
      lock.unlock()
      look.castA = a
      look.castB = b
    }
    guard let out = develop(input, look: look) else { return }
    lock.lock()
    latestOut = out
    lock.unlock()
    if textureId >= 0 { textures.textureFrameAvailable(textureId) }
  }

  private func develop(_ input: CVPixelBuffer, look: Look) -> CVPixelBuffer? {
    guard let device, let commandQueue, let pipeline else { return nil }
    let w = CVPixelBufferGetWidth(input), h = CVPixelBufferGetHeight(input)
    if cache == nil { CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) }
    if pool == nil || poolSize != CGSize(width: w, height: h) {
      pool = Self.makePool(width: w, height: h)
      poolSize = CGSize(width: w, height: h)
    }
    guard let cache, let pool else { return nil }
    var outBuffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
    guard let outBuffer, let src = Self.texture(input, cache: cache), let dst = Self.texture(outBuffer, cache: cache),
      let cmd = commandQueue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder()
    else { return nil }
    var params = look.packed()
    enc.setComputePipelineState(pipeline)
    enc.setTexture(src, index: 0)
    enc.setTexture(dst, index: 1)
    enc.setBytes(&params, length: MemoryLayout<Float>.stride * params.count, index: 0)
    let tw = pipeline.threadExecutionWidth, th = pipeline.maxTotalThreadsPerThreadgroup / tw
    enc.dispatchThreadgroups(
      MTLSize(width: (w + tw - 1) / tw, height: (h + th - 1) / th, depth: 1),
      threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
    enc.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()
    return outBuffer
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    guard let latestOut else { return nil }
    return Unmanaged.passRetained(latestOut)
  }

  private static func texture(_ buffer: CVPixelBuffer, cache: CVMetalTextureCache) -> MTLTexture? {
    var tex: CVMetalTexture?
    CVMetalTextureCacheCreateTextureFromImage(
      nil, cache, buffer, nil, .bgra8Unorm, CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &tex)
    return tex.flatMap(CVMetalTextureGetTexture)
  }

  private static func attributes(width: Int, height: Int) -> [String: Any] {
    [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
    ]
  }

  private static func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
    var pool: CVPixelBufferPool?
    CVPixelBufferPoolCreate(nil, nil, attributes(width: width, height: height) as CFDictionary, &pool)
    return pool
  }

  private static func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(
      nil, width, height, kCVPixelFormatType_32BGRA, attributes(width: width, height: height) as CFDictionary, &buffer)
    return buffer
  }

  // MARK: - Look

  private func setLook(_ args: [String: Any]) {
    var next = Look()
    for (i, c) in (args["colors"] as? [[Double]] ?? []).prefix(Look.maxColors).enumerated() where c.count >= 6 {
      next.colors[i] = Kept(
        hue: Float(c[0]), width: Float(c[1]), softness: Float(c[2]), chromaMin: Float(c[3]),
        lo: Float(c[4]), hi: Float(c[5]), gate: c.count > 6 ? Float(c[6]) : 0)
      next.count = i + 1
    }
    next.contrast = Float(args["contrast"] as? Double ?? 0.1)
    next.ambience = Float(args["ambience"] as? Double ?? 0.4)
    next.vignette = Float(args["vignette"] as? Double ?? 0)
    next.vignetteRadius = Float(args["vignetteRadius"] as? Double ?? 0.8)
    lock.lock()
    next.castA = look.castA
    next.castB = look.castB
    look = next
    lock.unlock()
  }

  // MARK: - Reading the frame

  /// OKLab at a normalized point of the upright frame: the median of a small
  /// patch, so a speck of noise does not decide the color.
  private func sample(x: Double, y: Double) -> [Double]? {
    lock.lock()
    let buffer = latestIn
    lock.unlock()
    guard let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
    let row = CVPixelBufferGetBytesPerRow(buffer)
    let p = base.assumingMemoryBound(to: UInt8.self)
    let cx = Int(min(max(x, 0), 1) * Double(w - 1)), cy = Int(min(max(y, 0), 1) * Double(h - 1))
    let r = max(2, Int(Double(min(w, h)) * 0.008))
    var ls: [Double] = [], as_: [Double] = [], bs: [Double] = []
    for yy in max(0, cy - r)...min(h - 1, cy + r) {
      for xx in max(0, cx - r)...min(w - 1, cx + r) {
        let o = yy * row + xx * 4
        let lab = Self.oklab(b: p[o], g: p[o + 1], r: p[o + 2])
        ls.append(lab.0)
        as_.append(lab.1)
        bs.append(lab.2)
      }
    }
    func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
    return [median(ls), median(as_), median(bs)]
  }

  /// A small RGBA copy of the upright frame, for finding its colors.
  private func thumb(width: Int) -> [String: Any]? {
    lock.lock()
    let buffer = latestIn
    lock.unlock()
    guard let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
    let row = CVPixelBufferGetBytesPerRow(buffer)
    let p = base.assumingMemoryBound(to: UInt8.self)
    let tw = width, th = max(1, width * h / w)
    var out = [UInt8](repeating: 255, count: tw * th * 4)
    for ty in 0..<th {
      let sy = ty * h / th
      for tx in 0..<tw {
        let sx = tx * w / tw
        let o = sy * row + sx * 4, d = (ty * tw + tx) * 4
        out[d] = p[o + 2]
        out[d + 1] = p[o + 1]
        out[d + 2] = p[o]
      }
    }
    return ["width": tw, "height": th, "pixels": FlutterStandardTypedData(bytes: Data(out))]
  }

  private static func lin(_ v: UInt8) -> Double {
    let c = Double(v) / 255
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
  }

  private static func oklab(b: UInt8, g: UInt8, r: UInt8) -> (Double, Double, Double) {
    let R = lin(r), G = lin(g), B = lin(b)
    let l = cbrt(0.4122214708 * R + 0.5363325363 * G + 0.0514459929 * B)
    let m = cbrt(0.2119034982 * R + 0.6806995451 * G + 0.1073969566 * B)
    let s = cbrt(0.0883024619 * R + 0.2817188376 * G + 0.6299787005 * B)
    return (
      0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
      1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
      0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    )
  }

  /// The color of the light, as the renderer measures it: the average tint
  /// of near-neutral surfaces, capped so it reads as a tone.
  private static func lightCast(_ buffer: CVPixelBuffer) -> (Float, Float) {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return (0, 0) }
    let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
    let row = CVPixelBufferGetBytesPerRow(buffer)
    let p = base.assumingMemoryBound(to: UInt8.self)
    var sa = 0.0, sb = 0.0, ws = 0.0
    let step = max(1, Int((Double(w * h) / 6000).squareRoot()))
    for y in stride(from: 0, to: h, by: step) {
      for x in stride(from: 0, to: w, by: step) {
        let o = y * row + x * 4
        let (l, a, b) = oklab(b: p[o], g: p[o + 1], r: p[o + 2])
        let c = (a * a + b * b).squareRoot()
        if c > 0.09 || l < 0.08 { continue }
        let k = 1 - c / 0.09
        sa += a * k
        sb += b * k
        ws += k
      }
    }
    if ws == 0 { return (0, 0) }
    var a = sa / ws, b = sb / ws
    let c = (a * a + b * b).squareRoot()
    if c > 0.035 {
      a *= 0.035 / c
      b *= 0.035 / c
    }
    return (Float(a * 1.6), Float(b * 1.6))
  }

  // MARK: - Shutter

  private func capture(_ result: @escaping FlutterResult) {
    guard configured, session.isRunning else {
      result(FlutterError(code: "unavailable", message: "No camera on this device", details: nil))
      return
    }
    guard pendingCapture == nil else {
      result(FlutterError(code: "busy", message: "Still saving the last photo", details: nil))
      return
    }
    pendingCapture = result
    queue.async {
      if let conn = self.photoOutput.connection(with: .video) { Self.upright(conn, portrait: false) }
      let settings = AVCapturePhotoSettings()
      if #available(iOS 16.0, *) { settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions }
      settings.photoQualityPrioritization = .quality
      self.photoOutput.capturePhoto(with: settings, delegate: self)
    }
  }

  func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
    guard error == nil, let data = photo.fileDataRepresentation() else {
      finishCapture(FlutterError(code: "capture", message: "\(error.map { "\($0)" } ?? "no data")", details: nil))
      return
    }
    let place = lastLocation
    let taken = Date()
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        self.finishCapture(FlutterError(code: "library", message: "Saving to Photos was not allowed", details: nil))
        return
      }
      var id: String?
      PHPhotoLibrary.shared().performChanges({
        let request = PHAssetCreationRequest.forAsset()
        request.addResource(with: .photo, data: data, options: nil)
        request.creationDate = taken
        request.location = place
        id = request.placeholderForCreatedAsset?.localIdentifier
      }) { ok, error in
        guard ok, let id else {
          self.finishCapture(FlutterError(code: "library", message: "\(error.map { "\($0)" } ?? "not saved")", details: nil))
          return
        }
        let dims = photo.resolvedSettings.photoDimensions
        let upright = [UIDeviceOrientation.portrait, .portraitUpsideDown, .unknown, .faceUp, .faceDown]
          .contains(UIDevice.current.orientation)
        let (w, h) = (Int(dims.width), Int(dims.height))
        self.finishCapture([
          "id": id,
          "taken": Int(taken.timeIntervalSince1970 * 1000),
          "width": upright ? min(w, h) : max(w, h),
          "height": upright ? max(w, h) : min(w, h),
          "lat": place?.coordinate.latitude as Any,
          "lng": place?.coordinate.longitude as Any,
        ])
      }
    }
  }

  private func finishCapture(_ value: Any?) {
    DispatchQueue.main.async {
      self.pendingCapture?(value)
      self.pendingCapture = nil
    }
  }

  // MARK: - Location

  private func startLocation() {
    switch location.authorizationStatus {
    case .notDetermined: location.requestWhenInUseAuthorization()
    case .authorizedWhenInUse, .authorizedAlways: location.startUpdatingLocation()
    default: break
    }
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    if textureId >= 0,
      manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways
    {
      manager.startUpdatingLocation()
    }
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    lastLocation = locations.last
  }

  // MARK: - The look, on the GPU

  struct Kept {
    var hue: Float = 0, width: Float = 0, softness: Float = 0, chromaMin: Float = 0
    var lo: Float = 0, hi: Float = 1, gate: Float = 0
  }

  struct Look {
    static let maxColors = 4
    var count = 0
    var colors = [Kept](repeating: Kept(), count: maxColors)
    var contrast: Float = 0.1, ambience: Float = 0.4, vignette: Float = 0, vignetteRadius: Float = 0.8
    var castA: Float = 0, castB: Float = 0
    var castStale = true

    /// Laid out as the kernel's `Look`: eight floats, then eight per color.
    func packed() -> [Float] {
      var out: [Float] = [Float(count), contrast, ambience, castA, castB, vignette, vignetteRadius, 0]
      for c in colors { out += [c.hue, c.width, c.softness, c.chromaMin, c.lo, c.hi, c.gate, 0] }
      return out
    }
  }

  /// The renderer's look (lib/core/renderer.dart), pixel by pixel. The
  /// renderer also smooths the weight along edges, which a live preview
  /// does without.
  private static let kernel = """
    #include <metal_stdlib>
    using namespace metal;

    struct Kept { float hue, width, softness, chromaMin, lo, hi, gate, pad; };
    struct Look {
      float count, contrast, ambience, castA, castB, vignette, vignetteRadius, pad;
      Kept colors[4];
    };

    static float lin(float c) { return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4); }
    static float srgb(float c) {
      c = clamp(c, 0.0, 1.0);
      return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055;
    }
    static float cb(float x) { return x <= 0.0 ? 0.0 : pow(x, 1.0 / 3.0); }
    static float ss(float e0, float e1, float x) {
      float t = clamp((x - e0) / max(e1 - e0, 1e-9), 0.0, 1.0);
      return t * t * (3.0 - 2.0 * t);
    }

    kernel void develop(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant Look& look [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
      uint w = dst.get_width(), h = dst.get_height();
      if (gid.x >= w || gid.y >= h) return;
      float4 px = src.read(gid);
      float R = lin(px.r), G = lin(px.g), B = lin(px.b);
      float l_ = cb(0.4122214708 * R + 0.5363325363 * G + 0.0514459929 * B);
      float m_ = cb(0.2119034982 * R + 0.6806995451 * G + 0.1073969566 * B);
      float s_ = cb(0.0883024619 * R + 0.2817188376 * G + 0.6299787005 * B);
      float L = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_;
      float A = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_;
      float Bb = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_;

      float C = sqrt(A * A + Bb * Bb);
      float H = fmod(atan2(Bb, A) * 180.0 / M_PI_F + 360.0, 360.0);
      float k = 0.0;
      int n = int(look.count);
      for (int i = 0; i < n; i++) {
        Kept c = look.colors[i];
        float dh = abs(fmod(H - c.hue + 540.0, 360.0) - 180.0);
        float t = clamp((dh - c.width) / max(c.softness, 1e-6), 0.0, 1.0);
        float wh = 0.5 * (1.0 + cos(M_PI_F * t));
        float wc = ss(c.chromaMin * 0.5, c.chromaMin * 1.5, C);
        float wl = c.gate > 0.5 ? ss(c.lo - 0.08, c.lo, L) * (1.0 - ss(c.hi, c.hi + 0.08, L)) : 1.0;
        k = max(k, wh * wc * wl);
      }

      float x = clamp(L, 0.0, 1.0);
      float tl = look.contrast == 0.0 ? L
        : clamp(x + 2.4 * look.contrast * sin(2.0 * M_PI_F * (x - 0.5)) / (2.0 * M_PI_F), 0.0, 1.0);
      float a = A * k, b = Bb * k;
      float amb = clamp(look.ambience, 0.0, 1.0);
      if (amb > 0.0) {
        float mid = 4.0 * tl * (1.0 - tl);
        float m = (1.0 - k) * amb;
        a += m * (look.castA * mid + A * 0.35);
        b += m * (look.castB * mid + Bb * 0.35);
      }
      float lo = tl + 0.3963377774 * a + 0.2158037573 * b;
      float mo = tl - 0.1055613458 * a - 0.0638541728 * b;
      float so = tl - 0.0894841775 * a - 1.2914855480 * b;
      lo = lo * lo * lo; mo = mo * mo * mo; so = so * so * so;
      float3 rgb = float3(4.0767416621 * lo - 3.3077115913 * mo + 0.2309699292 * so,
                          -1.2684380046 * lo + 2.6097574011 * mo - 0.3413193965 * so,
                          -0.0041960863 * lo - 0.7034186147 * mo + 1.7076147010 * so);
      float vig = clamp(look.vignette, 0.0, 1.0);
      if (vig > 0.0) {
        float cx = w / 2.0, cy = h / 2.0;
        float dx = gid.x + 0.5 - cx, dy = gid.y + 0.5 - cy;
        float d = sqrt(dx * dx + dy * dy) / sqrt(cx * cx + cy * cy);
        float r = clamp(look.vignetteRadius, 0.2, 1.6);
        float ww = r * (0.43 + 0.85 * 0.5);
        float t = clamp((d - (r - ww)) / (2.0 * ww), 0.0, 1.0);
        float v = 1.0 - vig * t * t * (3.0 - 2.0 * t);
        rgb *= v <= 0.0 ? 0.0 : pow(v, 2.2);
      }
      dst.write(float4(srgb(rgb.r), srgb(rgb.g), srgb(rgb.b), 1.0), gid);
    }
    """
}
