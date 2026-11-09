import Flutter
import FoundationModels
import UIKit

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
