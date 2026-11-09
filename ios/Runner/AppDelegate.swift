import Flutter
import FoundationModels
import UIKit
import Vision

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AppleJudge") {
      AppleJudge.register(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LiveCamera") {
      LiveCamera.register(registrar: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "Haptics") {
      Haptics.register(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "Subject") {
      Subject.register(messenger: registrar.messenger())
    }
  }
}

/// The app's touch vocabulary on the system's generators, kept prepared so
/// each one lands on the frame it belongs to.
enum Haptics {
  static let selection = UISelectionFeedbackGenerator()
  static let light = UIImpactFeedbackGenerator(style: .light)
  static let medium = UIImpactFeedbackGenerator(style: .medium)
  static let rigid = UIImpactFeedbackGenerator(style: .rigid)
  static let soft = UIImpactFeedbackGenerator(style: .soft)
  static let notice = UINotificationFeedbackGenerator()

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "afterhue/haptics", binaryMessenger: messenger)
    [selection, light, medium, rigid, soft, notice].forEach { $0.prepare() }
    channel.setMethodCallHandler { call, result in
      guard call.method == "play", let kind = call.arguments as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      play(kind)
      result(nil)
    }
  }

  static func play(_ kind: String) {
    switch kind {
    case "tick":
      selection.selectionChanged()
      selection.prepare()
    case "light":
      light.impactOccurred(intensity: 0.8)
      light.prepare()
    case "firm":
      medium.impactOccurred()
      medium.prepare()
    case "snap":
      rigid.impactOccurred(intensity: 0.9)
      rigid.prepare()
    case "shutter":
      // The shutter: a firm press, then the curtain's softer return.
      rigid.impactOccurred(intensity: 1)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
        soft.impactOccurred(intensity: 0.55)
        rigid.prepare()
        soft.prepare()
      }
    case "success":
      notice.notificationOccurred(.success)
      notice.prepare()
    case "warning":
      notice.notificationOccurred(.warning)
      notice.prepare()
    default:
      break
    }
  }
}

/// Screens a photo with Apple's on-device model: is it worth developing?
/// Free and private; the cloud agent only sees photos that pass.
enum AppleJudge {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "afterhue/apple_judge", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "status":
        result(status())
      case "judge":
        guard let args = call.arguments as? [String: Any], let path = args["path"] as? String,
              let instructions = args["instructions"] as? String
        else {
          result(FlutterError(code: "args", message: "path and instructions required", details: nil))
          return
        }
        guard #available(iOS 27.0, *) else {
          result(FlutterError(code: "os", message: "needs iOS 27", details: nil))
          return
        }
        Task {
          do {
            result(try await judge(path: path, instructions: instructions))
          } catch {
            result(FlutterError(code: "model", message: "\(error)", details: nil))
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// "ok", or why the model cannot be used here.
  static func status() -> String {
    guard #available(iOS 27.0, *) else { return "os" }
    let model = SystemLanguageModel.default
    switch model.availability {
    case .available:
      return model.capabilities.contains(.vision) ? "ok" : "noVision"
    case .unavailable(.deviceNotEligible):
      return "deviceNotEligible"
    case .unavailable(.appleIntelligenceNotEnabled):
      return "appleIntelligenceNotEnabled"
    case .unavailable(.modelNotReady):
      return "modelNotReady"
    case .unavailable:
      return "unavailable"
    }
  }

  @available(iOS 27.0, *)
  static func judge(path: String, instructions: String) async throws -> [String: Any] {
    let session = LanguageModelSession(model: .default, instructions: instructions)
    let url = URL(fileURLWithPath: path)
    let res = try await session.respond(generating: PhotoVerdict.self) {
      "Screen this photo."
      Attachment(imageURL: url)
    }
    let v = res.content
    return ["develop": v.develop, "subject": v.subject, "reason": v.reason]
  }
}

@available(iOS 27.0, *)
@Generable
struct PhotoVerdict {
  @Guide(description: "What the photographer pointed the camera at, 2-5 plain English words")
  let subject: String
  @Guide(description: "true when that subject has its own colors that would stand out against a black and white rest")
  let develop: Bool
  @Guide(description: "Why, under 8 words, written for the photographer")
  let reason: String
}

/// The outline of the thing under a tap, found on the device the way Photos
/// lifts a subject. Returned as polygons in 0..1 of the photo, top-left origin.
enum Subject {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "afterhue/subject", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "outline", let a = call.arguments as? [String: Any],
            let data = a["rgba"] as? FlutterStandardTypedData,
            let w = a["w"] as? Int, let h = a["h"] as? Int,
            let x = a["x"] as? Double, let y = a["y"] as? Double
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard #available(iOS 17.0, *) else {
        result(nil)
        return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let out = try outline(data.data, w: w, h: h, x: x, y: y)
          DispatchQueue.main.async { result(out) }
        } catch {
          DispatchQueue.main.async { result(FlutterError(code: "vision", message: "\(error)", details: nil)) }
        }
      }
    }
  }

  @available(iOS 17.0, *)
  static func outline(_ data: Data, w: Int, h: Int, x: Double, y: Double) throws -> [[[Double]]] {
    guard let provider = CGDataProvider(data: data as CFData),
          let image = CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { return [] }
    let request = VNGenerateForegroundInstanceMaskRequest()
    let handler = VNImageRequestHandler(cgImage: image)
    try handler.perform([request])
    guard let obs = request.results?.first else { return [] }
    guard let label = instance(in: obs.instanceMask, x: x, y: y) else { return [] }
    let mask = try obs.generateScaledMaskForImage(forInstances: IndexSet(integer: label), from: handler)
    return try contours(of: mask)
  }

  /// The instance under (x, y), or the nearest one a fingertip away.
  static func instance(in buf: CVPixelBuffer, x: Double, y: Double) -> Int? {
    CVPixelBufferLockBaseAddress(buf, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buf) else { return nil }
    let mw = CVPixelBufferGetWidth(buf), mh = CVPixelBufferGetHeight(buf)
    let row = CVPixelBufferGetBytesPerRow(buf)
    let p = base.assumingMemoryBound(to: UInt8.self)
    let cx = Int(x * Double(mw)), cy = Int(y * Double(mh))
    let reach = max(2, min(mw, mh) / 25)
    var best: (Int, Int)? = nil
    for dy in -reach...reach {
      for dx in -reach...reach {
        let px = cx + dx, py = cy + dy
        guard px >= 0, py >= 0, px < mw, py < mh else { continue }
        let v = Int(p[py * row + px])
        if v == 0 { continue }
        let d = dx * dx + dy * dy
        if best == nil || d < best!.1 { best = (v, d) }
      }
    }
    return best?.0
  }

  static func contours(of mask: CVPixelBuffer) throws -> [[[Double]]] {
    let request = VNDetectContoursRequest()
    request.detectsDarkOnLight = false
    request.contrastAdjustment = 1
    request.maximumImageDimension = 512
    try VNImageRequestHandler(cvPixelBuffer: mask).perform([request])
    guard let found = request.results?.first else { return [] }
    var out: [[[Double]]] = []
    for c in found.topLevelContours {
      let simple = (try? c.polygonApproximation(epsilon: 0.002)) ?? c
      let pts = simple.normalizedPoints
      guard pts.count >= 3 else { continue }
      var minX = 1.0, maxX = 0.0, minY = 1.0, maxY = 0.0
      let poly = pts.map { q -> [Double] in
        let px = Double(q.x), py = 1 - Double(q.y)
        minX = min(minX, px); maxX = max(maxX, px); minY = min(minY, py); maxY = max(maxY, py)
        return [px, py]
      }
      // Specks along the edge are noise, not parts of the thing.
      if (maxX - minX) * (maxY - minY) < 0.0004 { continue }
      out.append(poly)
    }
    return out
  }
}
