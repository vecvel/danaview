import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var probe: LatencyProbe?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // IOS-01 / V-N23 probe: a texture fed by AVPlayerItemVideoOutput + CADisplayLink.
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LatencyProbe") else { return }
    let probe = LatencyProbe(registry: registrar.textures())
    self.probe = probe
    let channel = FlutterMethodChannel(name: "dv.spike/latency", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "start":
        probe.start { id in result(id) }
      case "report":
        let args = call.arguments as? [String: Any] ?? [:]
        let timings = args["timings"] as? [[Int]] ?? []
        let phase = args["phase"] as? String ?? "?"
        let next = args["nextCompensationMs"] as? Double
        let r = probe.report(phase: phase, timings: timings, nextCompensation: next.map { $0 / 1000 })
        if let data = try? JSONSerialization.data(withJSONObject: r, options: [.sortedKeys]),
          let s = String(data: data, encoding: .utf8)
        {
          print("DVSPIKE-METRIC \(s)")
          fflush(stdout)
        }
        result(r)
      case "exit":
        print("DVSPIKE-LATENCY done")
        fflush(stdout)
        result(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
