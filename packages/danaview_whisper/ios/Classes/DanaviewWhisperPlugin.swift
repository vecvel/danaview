// OWNER: AI-06
//
// Method channel `danaview_whisper/device` and event channel `danaview_whisper/device/events`
// (ai.md §4.8; names mirrored in lib/src/device/device_channel.dart and checked by a Dart test).
// Methods: deviceProfile, availableMemory, freeDiskBytes, isNetworkMetered, excludeFromBackup,
// beginBackgroundTask, endBackgroundTask. Events: thermal, memoryWarning, lowPower, lifecycle,
// backgroundTaskExpiring. Observers are installed only while Dart listens.

import Flutter
import UIKit

public final class DanaviewWhisperPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  static let methodChannelName = "danaview_whisper/device"
  static let eventChannelName = "danaview_whisper/device/events"

  private let profiler = DeviceProfiler()
  private var sink: FlutterEventSink?
  private var observers: [NSObjectProtocol] = []
  private var backgroundTasks: [Int: UIBackgroundTaskIdentifier] = [:]
  private var nextTaskId = 1

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = DanaviewWhisperPlugin()
    let methods = FlutterMethodChannel(name: methodChannelName, binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: methods)
    FlutterEventChannel(name: eventChannelName, binaryMessenger: registrar.messenger()).setStreamHandler(instance)
  }

  // MARK: - methods

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "deviceProfile":
      result(profiler.profile())
    case "availableMemory":
      result(profiler.availableMemory())
    case "freeDiskBytes":
      guard let path = call.arguments as? String else {
        result(FlutterError(code: "bad_args", message: "path required", details: nil))
        return
      }
      result(profiler.freeDiskBytes(path: path))
    case "isNetworkMetered":
      result(profiler.isNetworkMetered)
    case "excludeFromBackup":
      guard let path = call.arguments as? String else {
        result(FlutterError(code: "bad_args", message: "path required", details: nil))
        return
      }
      result(DeviceProfiler.excludeFromBackup(path: path))
    case "beginBackgroundTask":
      result(beginBackgroundTask(name: (call.arguments as? String) ?? "Danaview"))
    case "endBackgroundTask":
      if let id = call.arguments as? Int { endBackgroundTask(id: id) }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - background tasks (downloads)

  private func beginBackgroundTask(name: String) -> Int {
    let id = nextTaskId
    nextTaskId += 1
    let task = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
      // The OS is about to suspend us: tell Dart (pause, keep the partial file) and end the task
      // right here, as the system requires before this handler returns.
      self?.emit(["type": "backgroundTaskExpiring", "value": id])
      self?.endBackgroundTask(id: id)
    }
    if task == .invalid { return 0 }
    backgroundTasks[id] = task
    return id
  }

  private func endBackgroundTask(id: Int) {
    guard let task = backgroundTasks.removeValue(forKey: id) else { return }
    UIApplication.shared.endBackgroundTask(task)
  }

  // MARK: - events

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    let center = NotificationCenter.default
    func observe(_ name: Notification.Name, _ body: @escaping () -> [String: Any]?) {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        if let event = body() { self?.emit(event) }
      })
    }
    observe(ProcessInfo.thermalStateDidChangeNotification) {
      ["type": "thermal", "value": ThermalNames.name(for: ProcessInfo.processInfo.thermalState)]
    }
    observe(.NSProcessInfoPowerStateDidChange) {
      ["type": "lowPower", "value": ProcessInfo.processInfo.isLowPowerModeEnabled]
    }
    observe(UIApplication.didReceiveMemoryWarningNotification) { ["type": "memoryWarning"] }
    observe(UIApplication.didEnterBackgroundNotification) { ["type": "lifecycle", "value": "background"] }
    observe(UIApplication.willEnterForegroundNotification) { ["type": "lifecycle", "value": "foreground"] }
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers.removeAll()
    sink = nil
    return nil
  }

  private func emit(_ event: [String: Any]) {
    if Thread.isMainThread {
      sink?(event)
    } else {
      DispatchQueue.main.async { [weak self] in self?.sink?(event) }
    }
  }
}
