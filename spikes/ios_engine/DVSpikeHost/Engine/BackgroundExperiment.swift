import AVFoundation
import BackgroundTasks
import Metal
import DVSpikeKernels
import UIKit

/// V-N20 / V-N11 fact finding: run a long export, let the app go to the background for > 30 s,
/// and record exactly what the writer/encoder report. Driven by the DVSpikeBackground UI test
/// (simulator or device) or by hand from the host app's buttons.
@MainActor
final class BackgroundExperiment {
  enum Mode: String, CaseIterable {
    /// One AVAssetWriter, no background task: the app is suspended shortly after backgrounding.
    case plain
    /// One AVAssetWriter inside `beginBackgroundTask` (≈ 30 s of background execution).
    case bgtask
    /// Segmented writer (IOS-17 shape): on didEnterBackground stop pumps and discard the open
    /// segment; on return resume from the checkpoint and concat.
    case segmented
  }

  static let shared = BackgroundExperiment()

  private(set) var lines: [String] = []
  var onUpdate: ((String) -> Void)?
  private(set) var running = false
  private var mode: Mode = .plain
  private var startedAt = Date()
  private var backgroundAt: Date?
  private var stopSegmented = false
  private var framesWritten = 0
  private var bgTask: UIBackgroundTaskIdentifier = .invalid
  private var observers: [NSObjectProtocol] = []

  static var logURL: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("background_experiment.log")
  }

  func log(_ s: String) {
    let t = String(format: "%7.2f", Date().timeIntervalSince(startedAt))
    let state: String
    switch UIApplication.shared.applicationState {
    case .active: state = "active"
    case .inactive: state = "inactive"
    case .background: state = "background"
    @unknown default: state = "?"
    }
    let line = "[\(t)s \(state)] \(s)"
    lines.append(line)
    NSLog("DVSPIKE %@", line)
    if let data = (line + "\n").data(using: .utf8) {
      if let h = try? FileHandle(forWritingTo: Self.logURL) {
        h.seekToEndOfFile()
        h.write(data)
        try? h.close()
      } else {
        try? data.write(to: Self.logURL)
      }
    }
    onUpdate?(line)
  }

  /// Device facts recorded with every run (V-N20: `supportedResources.contains(.gpu)`).
  static func deviceFacts() -> [String] {
    var sys = utsname()
    uname(&sys)
    let machine = withUnsafePointer(to: &sys.machine) {
      $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
    }
    var facts = [
      "model=\(machine)",
      "os=\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
      "idiom=\(UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone")",
      "ramMB=\(ProcessInfo.processInfo.physicalMemory / 1_048_576)",
      "gpu=\(MTLCreateSystemDefaultDevice()?.name ?? "none")",
    ]
    #if targetEnvironment(simulator)
      facts.append("simulator=true")
    #endif
    if #available(iOS 26.0, *) {
      let gpu = BGTaskScheduler.supportedResources.contains(.gpu)
      facts.append("BGTaskScheduler.supportedResources.contains(.gpu)=\(gpu)")
    } else {
      facts.append("BGTaskScheduler.supportedResources=unavailable(<iOS 26)")
    }
    return facts
  }

  func start(_ mode: Mode, seconds: Int = 120) {
    guard !running else { return }
    running = true
    self.mode = mode
    startedAt = Date()
    try? FileManager.default.removeItem(at: Self.logURL)
    log("experiment \(mode.rawValue) start; " + Self.deviceFacts().joined(separator: " "))
    installObservers()
    Task { await self.run(seconds: seconds) }
  }

  private func installObservers() {
    let nc = NotificationCenter.default
    observers.append(
      nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.backgroundAt = Date()
          self.log("didEnterBackground framesWritten=\(self.framesWritten) remaining=\(UIApplication.shared.backgroundTimeRemaining)")
          if self.mode == .segmented { self.stopSegmented = true }
        }
      })
    observers.append(
      nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          let away = self.backgroundAt.map { Date().timeIntervalSince($0) } ?? 0
          self.log(String(format: "willEnterForeground after %.1fs framesWritten=%d", away, self.framesWritten))
        }
      })
  }

  private func plan(seconds: Int) -> SpikePlan {
    // A 1080p canvas with back-to-back 10 s clips of one generated source plus a blurred PiP,
    // so the export is GPU-bound like a real edit.
    var layers: [[String: Any]] = []
    let clipUs: Int64 = 10_000_000
    for i in 0..<(seconds / 10) {
      let t0 = Int64(i) * clipUs
      layers.append([
        "id": "main\(i)", "z": 10, "seq": 0, "t": [t0, t0 + clipUs], "kind": "media", "asset": "src",
        "map": [[t0, t0 + clipUs, 0, clipUs]], "base": [1920, 1080],
      ])
      layers.append([
        "id": "pip\(i)", "z": 20, "seq": 1, "t": [t0, t0 + clipUs], "kind": "media", "asset": "src",
        "map": [[t0, t0 + clipUs, 0, clipUs]], "base": [640, 360], "xf": ["cx": 1440, "cy": 270],
      ])
    }
    let json: [String: Any] = [
      "v": 1, "canvas": ["w": 1920, "h": 1080, "fps": 30], "durUs": Int64(seconds) * 1_000_000,
      "assets": ["src": ["kind": "video", "uri": "file:///bg_src_1080p30.mp4"]], "layers": layers,
    ]
    let data = try! JSONSerialization.data(withJSONObject: json)
    return try! JSONDecoder().decode(SpikePlan.self, from: data)
  }

  private func run(seconds: Int) async {
    do {
      log("generating source media")
      let src = try await MediaFactory.barcodeVideo(
        name: "bg_src_1080p30.mp4", width: 1920, height: 1080, fps: 30, frames: 300, clip: 7)
      let spacer = try await MediaFactory.spacer()
      let built = try await CompositionBuilder.build(plan: plan(seconds: seconds), media: ["src": src], spacer: spacer)
      built.state.setParams(look: SpikeLook(exposure: 0.2, contrast: 0.1, saturation: 0.2), blur: 4)
      log("ready; background the app now (> 30 s), then return")
      let out = FileManager.default.temporaryDirectory.appendingPathComponent("bg_export.mp4")
      switch mode {
      case .plain, .bgtask:
        if mode == .bgtask {
          bgTask = UIApplication.shared.beginBackgroundTask(withName: "dv.spike.export") { [weak self] in
            MainActor.assumeIsolated {
              guard let self else { return }
              self.log("background task expiration handler; framesWritten=\(self.framesWritten)")
              UIApplication.shared.endBackgroundTask(self.bgTask)
              self.bgTask = .invalid
            }
          }
        }
        var lastLog = Date()
        do {
          let r = try await ExportPipeline.export(
            built: built, to: out,
            shouldStop: { [weak self] n in
              DispatchQueue.main.async {
                guard let self else { return }
                self.framesWritten = n
                if Date().timeIntervalSince(lastLog) > 2 {
                  lastLog = Date()
                  self.log("progress frames=\(n)")
                }
              }
              return false
            })
          log("export completed frames=\(r.frames) status=\(r.writerStatus.rawValue) ms=\(Int(r.ms))")
        } catch let e as ExportPipeline.Failure {
          let ns = e.nsError
          log("export FAILED stage=\(e.stage) domain=\(ns?.domain ?? "-") code=\(ns?.code ?? 0) underlying=\(String(describing: ns?.userInfo[NSUnderlyingErrorKey])) desc=\(ns?.localizedDescription ?? "-")")
        }
        if bgTask != .invalid {
          UIApplication.shared.endBackgroundTask(bgTask)
          bgTask = .invalid
        }
      case .segmented:
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bg_segments", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        let seg = SegmentedExporter(built: built, directory: dir, segmentFrames: 300)
        var attempts = 0
        while true {
          attempts += 1
          stopSegmented = false
          let done = try await seg.run(interrupt: { [weak self] _, n in
            let stop = DispatchQueue.main.sync { self?.stopSegmented ?? false }
            if n % 60 == 0 { DispatchQueue.main.async { self?.framesWritten += 60 } }
            return stop
          })
          log("segmented attempt \(attempts): done=\(done) checkpoint=\(seg.loadCheckpoint().completed)")
          if done { break }
          // Wait for the foreground, then resume.
          while UIApplication.shared.applicationState != .active { try await Task.sleep(nanoseconds: 200_000_000) }
          log("resuming from checkpoint")
        }
        let n = try await seg.concat(to: out)
        let back = try ExportPipeline.readBack(out, rect: { pb in
          CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        })
        let ok = back.enumerated().filter { $0.element.value?.frame == $0.offset % 300 }.count
        log("segmented concat frames=\(n) barcodeOK=\(ok)/\(back.count) log=\(seg.log)")
      }
    } catch {
      log("experiment error \(error)")
    }
    // `running` must be false before the last update: the status label reads "done <line>" only
    // then, and the DVSpikeBackground UI test waits for that prefix (the first simulator run
    // timed out after 600 s because "done" was logged while still running).
    running = false
    log("done")
  }
}
