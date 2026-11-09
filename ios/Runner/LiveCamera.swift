import AVFoundation
import AVKit
import CoreMotion
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
/// It takes photos as the system camera does: every lens behind one zoom,
/// switched by the phone as it sees fit (macro too), focus and exposure where
/// tapped, the full-size photo processed at the best quality, and the volume
/// buttons as a shutter.
///
/// Without a camera (the Simulator), a still photo stands in for the feed so
/// the screen can still be worked on.
final class LiveCamera: NSObject, FlutterTexture, AVCaptureVideoDataOutputSampleBufferDelegate,
  AVCapturePhotoCaptureDelegate, CLLocationManagerDelegate
{
  static func register(registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "afterhue/camera", binaryMessenger: registrar.messenger())
    let camera = LiveCamera(textures: registrar.textures(), channel: channel)
    channel.setMethodCallHandler { call, result in camera.handle(call, result) }
    shared = camera
  }

  private static var shared: LiveCamera?

  private let textures: FlutterTextureRegistry
  private let channel: FlutterMethodChannel
  private var textureId: Int64 = -1
  private let session = AVCaptureSession()
  private let videoOutput = AVCaptureVideoDataOutput()
  private let photoOutput = AVCapturePhotoOutput()
  private let queue = DispatchQueue(label: "afterhue.camera")
  private var configured = false
  private var stillTimer: DispatchSourceTimer?
  private var still: CVPixelBuffer?

  // The lens in use, and how the person has set it.
  private var input: AVCaptureDeviceInput?
  private var camera: AVCaptureDevice? { input?.device }
  private var front = false
  private var flash = AVCaptureDevice.FlashMode.off
  private var resolution = 0  // megapixels; 0 is the largest
  private var locked = false
  private var subjectObserver: NSObjectProtocol?
  private let motion = CMMotionManager()
  /// How the phone is held, as the back camera's rotation: 90 upright, 0
  /// top to the left, 180 top to the right, 270 upside down.
  private var held: CGFloat = 90
  /// The rotation a photo needs to come out level.
  private var captureAngle: CGFloat {
    // The front camera faces the other way: its sideways turns swap.
    front && (held == 0 || held == 180) ? 180 - held : held
  }
  private var volume: AnyObject?  // AVCaptureEventInteraction

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

  /// Photos still being saved, by their settings' id.
  private var pending: [Int64: FlutterResult] = [:]
  private var warnedFormat = false

  /// Held on one frame while a color is picked from it, as Accent does: the
  /// spot under the finger stays put while the hand moves.
  private var frozen = false

  init(textures: FlutterTextureRegistry, channel: FlutterMethodChannel) {
    self.textures = textures
    self.channel = channel
    super.init()
    location.delegate = self
    location.desiredAccuracy = kCLLocationAccuracyHundredMeters
  }

  /// Tells the screen something it did not ask for.
  private func emit(_ name: String, _ args: Any? = nil) {
    DispatchQueue.main.async { self.channel.invokeMethod(name, arguments: args) }
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
    case "loupe":
      let x = args["x"] as? Double ?? 0.5, y = args["y"] as? Double ?? 0.5
      result(loupe(x: x, y: y, side: args["side"] as? Int ?? 96))
    case "capture":
      capture(result)
    case "zoom":
      result(zoom(to: args["factor"] as? Double ?? 1, ramp: args["ramp"] as? Bool ?? false))
    case "focus":
      focus(x: args["x"] as? Double ?? 0.5, y: args["y"] as? Double ?? 0.5)
      result(nil)
    case "lock":
      setLocked(args["on"] as? Bool ?? false)
      result(nil)
    case "bias":
      result(bias(args["ev"] as? Double ?? 0))
    case "flash":
      flash = switch args["mode"] as? String {
      case "on": .on
      case "auto": .auto
      default: .off
      }
      result(nil)
    case "resolution":
      resolution = args["mp"] as? Int ?? 0
      result(nil)
    case "freeze":
      lock.lock()
      frozen = args["on"] as? Bool ?? false
      lock.unlock()
      result(nil)
    case "flip":
      flip(result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Session

  private func start(stillPath: String?, result: @escaping FlutterResult) {
    if Self.lens(front: false) == nil {
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
            DispatchQueue.main.async {
              self.registerTexture()
              self.watchVolume(true)
              self.watchMotion(true)
              result(self.feedInfo())
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
    watchVolume(false)
    watchMotion(false)
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

  /// The best camera on a side: the one that joins all its lenses, when
  /// there is one.
  private static func lens(front: Bool) -> AVCaptureDevice? {
    let types: [AVCaptureDevice.DeviceType] =
      front
      ? [.builtInTrueDepthCamera, .builtInWideAngleCamera]
      : [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
    return AVCaptureDevice.DiscoverySession(
      deviceTypes: types, mediaType: .video, position: front ? .front : .back
    ).devices.first
  }

  private func configure() throws {
    if configured { return }
    guard let lens = Self.lens(front: front) else { throw NSError(domain: "camera", code: 1) }
    session.beginConfiguration()
    defer { session.commitConfiguration() }
    session.sessionPreset = .inputPriority
    try use(lens)

    videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    videoOutput.alwaysDiscardsLateVideoFrames = true
    videoOutput.setSampleBufferDelegate(self, queue: queue)
    if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
    // Asked again once attached, where the session can honor it.
    videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
    afterLensChange()
    configured = true
  }

  /// Puts [lens] in, on a format that develops every frame and still takes
  /// full-size photos. Called inside a session configuration.
  private func use(_ lens: AVCaptureDevice) throws {
    if let input { session.removeInput(input) }
    let next = try AVCaptureDeviceInput(device: lens)
    guard session.canAddInput(next) else { throw NSError(domain: "camera", code: 2) }
    session.addInput(next)
    input = next

    func photoArea(_ f: AVCaptureDevice.Format) -> Int32 {
      guard #available(iOS 16.0, *) else { return 0 }
      return f.supportedMaxPhotoDimensions.map { $0.width * $0.height }.max() ?? 0
    }
    let format = lens.formats
      .filter { f in
        let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        // 8-bit formats only: a 10-bit one is not turned into BGRA, and its
        // planes read as BGRA come out as a doubled, grainy grey picture.
        let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
        return (sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
          || sub == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
          && abs(Double(d.width) / Double(d.height) - 4.0 / 3.0) < 0.01 && d.width <= 1920
          && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
      }
      .max { a, b in
        let wa = CMVideoFormatDescriptionGetDimensions(a.formatDescription).width
        let wb = CMVideoFormatDescriptionGetDimensions(b.formatDescription).width
        if wa != wb { return wa < wb }
        // The biggest photos the sensor can give.
        let pa = photoArea(a), pb = photoArea(b)
        if pa != pb { return pa < pb }
        // Full range keeps the shadows the renderer works from.
        return CMFormatDescriptionGetMediaSubType(b.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
      }
    try lens.lockForConfiguration()
    if let format {
      lens.activeFormat = format
      if format.supportedColorSpaces.contains(.sRGB) { lens.activeColorSpace = .sRGB }
    }
    if lens.isFocusModeSupported(.continuousAutoFocus) { lens.focusMode = .continuousAutoFocus }
    if lens.isExposureModeSupported(.continuousAutoExposure) { lens.exposureMode = .continuousAutoExposure }
    if lens.isSmoothAutoFocusSupported { lens.isSmoothAutoFocusEnabled = false }
    lens.isSubjectAreaChangeMonitoringEnabled = true
    lens.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
    if lens.isVirtualDevice {
      // Let the phone change lenses as the system camera does, close up too.
      lens.setPrimaryConstituentDeviceSwitchingBehavior(.auto, restrictedSwitchingBehaviorConditions: [])
    }
    // Start on the main lens, as the system camera does.
    lens.videoZoomFactor = min(max(1 / Self.multiplier(lens), lens.minAvailableVideoZoomFactor), lens.maxAvailableVideoZoomFactor)
    lens.unlockForConfiguration()
    locked = false
    watchSubject(lens)
  }

  /// What depends on the lens: the photo size, the fast shutter, which way
  /// is up, the mirror. Called inside a session configuration.
  private func afterLensChange() {
    guard let camera else { return }
    if #available(iOS 16.0, *), let biggest = camera.activeFormat.supportedMaxPhotoDimensions.max(by: {
      $0.width * $0.height < $1.width * $1.height
    }) {
      photoOutput.maxPhotoDimensions = biggest
    }
    photoOutput.maxPhotoQualityPrioritization = .quality
    if #available(iOS 17.0, *) {
      // The system camera's quick shutter: the moment the button was
      // pressed, taken from frames already buffered, and the heavy
      // processing finished by the library afterwards.
      if photoOutput.isZeroShutterLagSupported { photoOutput.isZeroShutterLagEnabled = true }
      if photoOutput.isResponsiveCaptureSupported { photoOutput.isResponsiveCaptureEnabled = true }
      if photoOutput.isFastCapturePrioritizationSupported { photoOutput.isFastCapturePrioritizationEnabled = true }
      if photoOutput.isAutoDeferredPhotoDeliverySupported { photoOutput.isAutoDeferredPhotoDeliveryEnabled = true }
    }
    if let conn = videoOutput.connection(with: .video) {
      Self.turn(conn, angle: 90)
      if conn.isVideoMirroringSupported {
        conn.automaticallyAdjustsVideoMirroring = false
        conn.isVideoMirrored = front
      }
    }
    if let conn = photoOutput.connection(with: .video), conn.isVideoMirroringSupported {
      conn.automaticallyAdjustsVideoMirroring = false
      conn.isVideoMirrored = front
    }
  }

  /// The upright size of the frames, the long side as the height.
  private func previewSize() -> CGSize {
    guard let f = camera?.activeFormat else { return CGSize(width: 3, height: 4) }
    let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
    return CGSize(width: Int(min(d.width, d.height)), height: Int(max(d.width, d.height)))
  }

  /// What the screen needs to draw the controls for this lens.
  private func feedInfo() -> [String: Any] {
    let size = previewSize()
    var info: [String: Any] = [
      "texture": textureId, "width": size.width, "height": size.height, "front": front,
      "flash": photoOutput.supportedFlashModes.contains(.on),
    ]
    guard let camera else { return info }
    let mult = Self.multiplier(camera)
    var stops: [Double] = [Double(camera.minAvailableVideoZoomFactor) * mult]
    for f in camera.virtualDeviceSwitchOverVideoZoomFactors { stops.append(f.doubleValue * mult) }
    // A 48MP main lens crops a sharp 2x, which the system camera offers.
    var mps: [Int] = []
    if #available(iOS 16.0, *) {
      mps = Array(Set(camera.activeFormat.supportedMaxPhotoDimensions.map {
        Int((Double($0.width) * Double($0.height) / 1e6).rounded())
      })).sorted()
    }
    if !front, (mps.last ?? 0) >= 40, !stops.contains(where: { abs($0 - 2) < 0.2 }) { stops.append(2) }
    stops = stops.map { ($0 * 10).rounded() / 10 }.filter { $0 >= 0.4 }.sorted()
    info["zoom"] = [
      "stops": stops.isEmpty ? [1.0] : stops,
      "min": Double(camera.minAvailableVideoZoomFactor) * mult,
      // As far as the system camera goes, not into mush.
      "max": min(Double(camera.maxAvailableVideoZoomFactor), 15 / mult) * mult,
      "now": Double(camera.videoZoomFactor) * mult,
    ]
    info["resolutions"] = mps
    let ev = Double(min(abs(camera.minExposureTargetBias), abs(camera.maxExposureTargetBias)))
    info["bias"] = min(ev, 2)
    return info
  }

  /// The zoom factor shown for the device's 1.0: 0.5 where the ultra wide
  /// is the widest lens.
  private static func multiplier(_ lens: AVCaptureDevice) -> Double {
    if #available(iOS 18.0, *) { return Double(lens.displayVideoZoomFactorMultiplier) }
    if lens.constituentDevices.contains(where: { $0.deviceType == .builtInUltraWideCamera }),
      let first = lens.virtualDeviceSwitchOverVideoZoomFactors.first
    {
      return 1 / first.doubleValue
    }
    return 1
  }

  /// Turns a connection to [angle] degrees.
  private static func turn(_ conn: AVCaptureConnection, angle: CGFloat) {
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

  // MARK: - Lens controls

  /// Zooms to a factor as shown (0.5, 1, 2…), smoothly when [ramp]. Returns
  /// the factor it reached.
  private func zoom(to shown: Double, ramp: Bool) -> Double? {
    guard let camera, (try? camera.lockForConfiguration()) != nil else { return nil }
    defer { camera.unlockForConfiguration() }
    let mult = Self.multiplier(camera)
    let top = min(camera.maxAvailableVideoZoomFactor, CGFloat(15 / mult))
    let f = min(max(CGFloat(shown / mult), camera.minAvailableVideoZoomFactor), top)
    if ramp {
      camera.ramp(toVideoZoomFactor: f, withRate: 12)
    } else {
      if camera.isRampingVideoZoom { camera.cancelVideoZoomRamp() }
      camera.videoZoomFactor = f
    }
    return Double(f) * mult
  }

  /// A normalized point of the upright view, in the sensor's coordinates.
  private func sensorPoint(x: Double, y: Double) -> CGPoint {
    let s = previewSize()
    let r = videoOutput.metadataOutputRectConverted(
      fromOutputRect: CGRect(x: x * s.width - 1, y: y * s.height - 1, width: 2, height: 2))
    let p = CGPoint(x: r.midX, y: r.midY)
    if p.x.isFinite, p.y.isFinite, (0...1).contains(p.x), (0...1).contains(p.y) { return p }
    // The frames are turned a quarter: the sensor's x runs down the view.
    return CGPoint(x: y, y: front ? x : 1 - x)
  }

  /// Focuses and exposes for a point, until the scene changes or it is
  /// unlocked.
  private func focus(x: Double, y: Double) {
    guard let camera, (try? camera.lockForConfiguration()) != nil else { return }
    defer { camera.unlockForConfiguration() }
    let p = sensorPoint(x: x, y: y)
    if camera.isFocusPointOfInterestSupported {
      camera.focusPointOfInterest = p
      camera.focusMode = camera.isFocusModeSupported(.autoFocus) ? .autoFocus : camera.focusMode
    }
    if camera.isExposurePointOfInterestSupported {
      camera.exposurePointOfInterest = p
      camera.exposureMode = .autoExpose
    }
    camera.setExposureTargetBias(0, completionHandler: nil)
    camera.isSubjectAreaChangeMonitoringEnabled = true
    locked = false
  }

  /// Holds focus and exposure where they are, as the system camera's
  /// AE/AF lock does.
  private func setLocked(_ on: Bool) {
    guard let camera, (try? camera.lockForConfiguration()) != nil else { return }
    defer { camera.unlockForConfiguration() }
    locked = on
    if on {
      if camera.isFocusModeSupported(.locked) { camera.focusMode = .locked }
      if camera.isExposureModeSupported(.locked) { camera.exposureMode = .locked }
    } else {
      backToAuto(camera)
    }
  }

  /// Brighter or darker than the meter, in stops. Returns what was set.
  private func bias(_ ev: Double) -> Double? {
    guard let camera, (try? camera.lockForConfiguration()) != nil else { return nil }
    defer { camera.unlockForConfiguration() }
    let v = min(max(Float(ev), camera.minExposureTargetBias, -2), camera.maxExposureTargetBias, 2)
    camera.setExposureTargetBias(v, completionHandler: nil)
    return Double(v)
  }

  /// Back to watching the whole frame. The device must be locked.
  private func backToAuto(_ camera: AVCaptureDevice) {
    let mid = CGPoint(x: 0.5, y: 0.5)
    if camera.isFocusPointOfInterestSupported { camera.focusPointOfInterest = mid }
    if camera.isExposurePointOfInterestSupported { camera.exposurePointOfInterest = mid }
    if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
    if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
    camera.setExposureTargetBias(0, completionHandler: nil)
  }

  /// When the scene moves on from a tapped point, the camera goes back to
  /// the whole frame, unless it is locked.
  private func watchSubject(_ lens: AVCaptureDevice) {
    if let subjectObserver { NotificationCenter.default.removeObserver(subjectObserver) }
    subjectObserver = NotificationCenter.default.addObserver(
      forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: lens, queue: .main
    ) { [weak self] _ in
      guard let self, !self.locked, let camera = self.camera, (try? camera.lockForConfiguration()) != nil else { return }
      self.backToAuto(camera)
      camera.unlockForConfiguration()
      self.emit("focusReset")
    }
  }

  /// Which way the phone is held, for the photo and for the controls. Read
  /// from gravity, as the system camera does: the screen stays upright and
  /// the rotation lock does not matter.
  private func watchMotion(_ on: Bool) {
    guard on else {
      motion.stopAccelerometerUpdates()
      return
    }
    guard motion.isAccelerometerAvailable, !motion.isAccelerometerActive else { return }
    motion.accelerometerUpdateInterval = 0.1
    motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
      guard let self, let g = data?.acceleration else { return }
      // Lying flat says nothing; keep what it was.
      if abs(g.z) > 0.85 { return }
      let next: CGFloat
      // A clear lean only, so it does not flicker at the diagonal.
      if abs(g.y) > abs(g.x) + 0.25 {
        next = g.y < 0 ? 90 : 270
      } else if abs(g.x) > abs(g.y) + 0.25 {
        next = g.x > 0 ? 0 : 180
      } else {
        return
      }
      if next != self.held {
        self.held = next
        self.emit("orientation", Double(next))
      }
    }
  }

  /// The volume buttons take the photo while the camera is open.
  private func watchVolume(_ on: Bool) {
    guard #available(iOS 17.2, *) else { return }
    let view = UIApplication.shared.connectedScenes
      .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController?.view
    if let old = volume as? AVCaptureEventInteraction {
      old.view?.removeInteraction(old)
      volume = nil
    }
    guard on, let view else { return }
    let interaction = AVCaptureEventInteraction { [weak self] event in
      if event.phase == .ended { self?.emit("shutter") }
    }
    view.addInteraction(interaction)
    volume = interaction
  }

  /// To the other side's camera. The texture stays; its size may not.
  private func flip(_ result: @escaping FlutterResult) {
    guard configured, let lens = Self.lens(front: !front) else {
      result(FlutterError(code: "unavailable", message: "No other camera", details: nil))
      return
    }
    queue.async {
      self.session.beginConfiguration()
      let was = self.front
      self.front = !was
      do {
        try self.use(lens)
      } catch {
        self.front = was
        if let back = Self.lens(front: was) { try? self.use(back) }
      }
      self.afterLensChange()
      self.session.commitConfiguration()
      self.lock.lock()
      self.look.castStale = true
      self.lock.unlock()
      DispatchQueue.main.async { result(self.feedInfo()) }
    }
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
    // Everything here reads four bytes a pixel; anything else would be garbage.
    guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA else {
      if !warnedFormat {
        warnedFormat = true
        NSLog("LiveCamera: frames are not BGRA (%u)", CVPixelBufferGetPixelFormatType(pixels))
      }
      return
    }
    lock.lock()
    let still = frozen
    lock.unlock()
    if still { return }
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
  /// The original, uncolored by the look, in a square of [side] frame pixels
  /// around a normalized point, with the color at its middle.
  private func loupe(x: Double, y: Double, side: Int) -> [String: Any]? {
    lock.lock()
    let buffer = latestIn
    lock.unlock()
    guard let buffer, let lab = sample(x: x, y: y) else { return nil }
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
    let row = CVPixelBufferGetBytesPerRow(buffer)
    let p = base.assumingMemoryBound(to: UInt8.self)
    let n = max(8, min(side, 256))
    let cx = Int(min(max(x, 0), 1) * Double(w - 1)), cy = Int(min(max(y, 0), 1) * Double(h - 1))
    var out = [UInt8](repeating: 0, count: n * n * 4)
    for ty in 0..<n {
      let sy = cy - n / 2 + ty
      for tx in 0..<n {
        let sx = cx - n / 2 + tx
        let d = (ty * n + tx) * 4
        // Past the edge of the frame stays dark.
        guard sx >= 0, sy >= 0, sx < w, sy < h else {
          out[d + 3] = 255
          continue
        }
        let o = sy * row + sx * 4
        out[d] = p[o + 2]
        out[d + 1] = p[o + 1]
        out[d + 2] = p[o]
        out[d + 3] = 255
      }
    }
    return ["side": n, "pixels": FlutterStandardTypedData(bytes: Data(out)), "lab": lab]
  }

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
    guard pending.count < 4 else {
      result(FlutterError(code: "busy", message: "Still saving the last photos", details: nil))
      return
    }
    // HEIF, as the system camera saves, where the phone has it.
    let settings =
      photoOutput.availablePhotoCodecTypes.contains(.hevc)
      ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc]) : AVCapturePhotoSettings()
    if #available(iOS 16.0, *) { settings.maxPhotoDimensions = photoSize(resolution) }
    settings.photoQualityPrioritization = .quality
    if photoOutput.supportedFlashModes.contains(flash) { settings.flashMode = flash }
    pending[settings.uniqueID] = result
    let angle = captureAngle
    queue.async {
      if let conn = self.photoOutput.connection(with: .video) { Self.turn(conn, angle: angle) }
      self.photoOutput.capturePhoto(with: settings, delegate: self)
    }
  }

  /// The photo size nearest the megapixels asked for; the largest for 0.
  @available(iOS 16.0, *)
  private func photoSize(_ mp: Int) -> CMVideoDimensions {
    let all = (camera?.activeFormat.supportedMaxPhotoDimensions ?? []).filter {
      $0.width * $0.height <= photoOutput.maxPhotoDimensions.width * photoOutput.maxPhotoDimensions.height
    }
    guard mp > 0, !all.isEmpty else { return photoOutput.maxPhotoDimensions }
    return all.min {
      abs(Double($0.width) * Double($0.height) / 1e6 - Double(mp))
        < abs(Double($1.width) * Double($1.height) / 1e6 - Double(mp))
    } ?? photoOutput.maxPhotoDimensions
  }

  func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
    guard error == nil, let data = photo.fileDataRepresentation() else {
      finishCapture(photo, FlutterError(code: "capture", message: "\(error.map { "\($0)" } ?? "no data")", details: nil))
      return
    }
    save(data, as: .photo, photo)
  }

  /// The quick shutter's photo: a proxy the library finishes processing
  /// later, to the same quality as the system camera's.
  @available(iOS 17.0, *)
  func photoOutput(
    _ output: AVCapturePhotoOutput, didFinishCapturingDeferredPhotoProxy proxy: AVCaptureDeferredPhotoProxy?,
    error: Error?
  ) {
    guard error == nil, let proxy, let data = proxy.fileDataRepresentation() else {
      finishCapture(proxy, FlutterError(code: "capture", message: "\(error.map { "\($0)" } ?? "no proxy")", details: nil))
      return
    }
    save(data, as: .photoProxy, proxy)
  }

  private func save(_ data: Data, as type: PHAssetResourceType, _ photo: AVCapturePhoto) {
    let place = lastLocation
    let taken = Date()
    let angle = captureAngle
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        self.finishCapture(photo, FlutterError(code: "library", message: "Saving to Photos was not allowed", details: nil))
        return
      }
      var id: String?
      PHPhotoLibrary.shared().performChanges({
        let request = PHAssetCreationRequest.forAsset()
        request.addResource(with: type, data: data, options: nil)
        request.creationDate = taken
        request.location = place
        id = request.placeholderForCreatedAsset?.localIdentifier
      }) { ok, error in
        guard ok, let id else {
          self.finishCapture(photo, FlutterError(code: "library", message: "\(error.map { "\($0)" } ?? "not saved")", details: nil))
          return
        }
        let dims = photo.resolvedSettings.photoDimensions
        let upright = angle == 90 || angle == 270
        let (w, h) = (Int(dims.width), Int(dims.height))
        self.finishCapture(photo, [
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

  private func finishCapture(_ photo: AVCapturePhoto?, _ value: Any?) {
    DispatchQueue.main.async {
      // Without the photo to name it, the oldest waiting is answered.
      guard let id = photo?.resolvedSettings.uniqueID ?? self.pending.keys.min() else { return }
      self.pending.removeValue(forKey: id)?(value)
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
      // Nothing kept yet: the scene as it is, so its colors can be chosen.
      if (look.count < 0.5) { dst.write(float4(px.rgb, 1.0), gid); return; }
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
