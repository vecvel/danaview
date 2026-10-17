import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let deviceOrientationHandler = DeviceOrientationStreamHandler()
  private static var pendingMedia: String?
  private static var mediaChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let url = launchOptions?[.url] as? URL {
      AppDelegate.handleIncomingUrl(url)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    AppDelegate.handleIncomingUrl(url)
    return super.application(app, open: url, options: options)
  }

  static func handleIncomingUrl(_ url: URL) {
    let mediaString: String
    if url.isFileURL {
      _ = url.startAccessingSecurityScopedResource()
      mediaString = url.path
    } else {
      mediaString = url.absoluteString
    }
    pendingMedia = mediaString
    mediaChannel?.invokeMethod("onOpenMedia", arguments: mediaString)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DanaviewDeviceOrientation") {
      FlutterEventChannel(name: "danaview/device_orientation", binaryMessenger: registrar.messenger())
        .setStreamHandler(deviceOrientationHandler)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DanaviewMediaIntent") {
      let channel = FlutterMethodChannel(name: "danaview/media_intent", binaryMessenger: registrar.messenger())
      AppDelegate.mediaChannel = channel
      channel.setMethodCallHandler { (call, result) in
        if call.method == "getInitialMedia" {
          let media = AppDelegate.pendingMedia
          AppDelegate.pendingMedia = nil
          result(media)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
      if let pending = AppDelegate.pendingMedia {
        channel.invokeMethod("onOpenMedia", arguments: pending)
      }
    }
  }
}

/// Streams how the phone is physically held, as the matching interface orientation
/// ("portraitUp", "portraitDown", "landscapeLeft", "landscapeRight"). UIKit stops reporting
/// changes while the user's rotation lock is on, so the player honours it.
final class DeviceOrientationStreamHandler: NSObject, FlutterStreamHandler {
  private var sink: FlutterEventSink?
  private var observer: NSObjectProtocol?

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    observer = NotificationCenter.default.addObserver(
      forName: UIDevice.orientationDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.emit()
    }
    emit()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    if let observer = observer {
      NotificationCenter.default.removeObserver(observer)
      UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }
    observer = nil
    sink = nil
    return nil
  }

  private func emit() {
    // Device and interface landscape are mirrored: a phone turned to its left shows the
    // interface's right side up.
    let name: String?
    switch UIDevice.current.orientation {
    case .portrait: name = "portraitUp"
    case .portraitUpsideDown: name = "portraitDown"
    case .landscapeLeft: name = "landscapeRight"
    case .landscapeRight: name = "landscapeLeft"
    default: name = nil  // Face up/down or unknown: keep the last orientation.
    }
    if let name = name {
      sink?(name)
    }
  }
}
