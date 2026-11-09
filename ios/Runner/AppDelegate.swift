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
