// OWNER: AI-06
//
// iOS device queries for the `danaview_whisper/device` channel (ai.md §4.8): RAM, performance cores
// (sysctl hw.perflevel0.physicalcpu), CPU features, Apple GPU family, thermal and power state,
// free memory (os_proc_available_memory), free disk, metered network, backup exclusion with
// read-back. Foundation, Metal and Network only (no UIKit, no Flutter) so the logic also compiles
// and runs on macOS in the host check (test/device/ios_profiler_host_test.dart).
//
// Privacy manifest: freeDiskBytes reads `volumeAvailableCapacityForImportantUsage`, a required
// reason API (NSPrivacyAccessedAPICategoryDiskSpace, reason E174.1) declared by AI-05's
// PrivacyInfo.xcprivacy.

import Foundation
import Metal
import Network
#if os(iOS)
import os
#endif

/// Maps `ProcessInfo.ThermalState` to the four names the Dart side knows.
enum ThermalNames {
  static func name(for state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "critical"
    }
  }
}

/// Tracks the current network path for the "Wi-Fi only" advice.
final class NetworkMeter {
  private let monitor = NWPathMonitor()
  private let lock = NSLock()
  private var metered = false

  init() {
    monitor.pathUpdateHandler = { [weak self] path in
      guard let self = self else { return }
      self.lock.lock()
      self.metered = path.isExpensive || path.isConstrained
      self.lock.unlock()
    }
    monitor.start(queue: DispatchQueue(label: "danaview_whisper.network", qos: .utility))
  }

  deinit { monitor.cancel() }

  var isMetered: Bool {
    lock.lock()
    defer { lock.unlock() }
    return metered
  }
}

final class DeviceProfiler {
  private let network = NetworkMeter()

  /// The `deviceProfile` map. Keys are documented in ai.md §4.8.
  func profile() -> [String: Any] {
    let info = ProcessInfo.processInfo
    let v = info.operatingSystemVersion
    let total = DeviceProfiler.sysctlInt("hw.logicalcpu") ?? info.processorCount
    let perf = DeviceProfiler.sysctlInt("hw.perflevel0.physicalcpu") ?? 0
    var efficiency = DeviceProfiler.sysctlInt("hw.perflevel1.physicalcpu") ?? 0
    if efficiency == 0, perf > 0, total > perf { efficiency = total - perf }
    return [
      "os": "ios",
      "osVersion": v.patchVersion == 0 ? "\(v.majorVersion).\(v.minorVersion)" : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
      "model": DeviceProfiler.modelIdentifier(),
      "physicalRam": Int(clamping: info.physicalMemory),
      "isLowRam": false,
      "perfCores": perf,
      "efficiencyCores": efficiency,
      "totalCores": total,
      "is64Bit": MemoryLayout<Int>.size == 8,
      "cpuFeatures": DeviceProfiler.cpuFeatures(),
      "gpuFamily": DeviceProfiler.appleGpuFamily(),
      "isSimulator": DeviceProfiler.isSimulator,
      "lowPowerMode": info.isLowPowerModeEnabled,
      "thermal": ThermalNames.name(for: info.thermalState),
    ]
  }

  /// Bytes this app may still allocate (`os_proc_available_memory`, iOS 13+); nil when the platform
  /// cannot tell (simulator, macOS host check). 1 when the app is at its limit, because the Dart
  /// side reads 0 as "unknown".
  func availableMemory() -> Int? {
    #if os(iOS) && !targetEnvironment(simulator)
    let bytes = Int(os_proc_available_memory())
    return bytes > 0 ? bytes : 1
    #else
    return nil
    #endif
  }

  /// Free bytes on the volume of `path` (walks up to the nearest existing parent).
  func freeDiskBytes(path: String) -> Int? {
    let fm = FileManager.default
    var url = URL(fileURLWithPath: path)
    while !fm.fileExists(atPath: url.path) && url.path != "/" { url.deleteLastPathComponent() }
    guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
      let free = values.volumeAvailableCapacityForImportantUsage
    else { return nil }
    return Int(clamping: free)
  }

  var isNetworkMetered: Bool { network.isMetered }

  /// Sets `isExcludedFromBackup` on `path` and reads it back; true only when the read-back says so.
  static func excludeFromBackup(path: String) -> Bool {
    guard FileManager.default.fileExists(atPath: path) else { return false }
    var url = URL(fileURLWithPath: path)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    do {
      try url.setResourceValues(values)
      url.removeAllCachedResourceValues()
      return try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    } catch {
      return false
    }
  }

  // MARK: - helpers

  static var isSimulator: Bool {
    #if targetEnvironment(simulator)
    return true
    #else
    return false
    #endif
  }

  static func modelIdentifier() -> String {
    if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !sim.isEmpty { return sim }
    var system = utsname()
    uname(&system)
    return withUnsafePointer(to: &system.machine) {
      $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
    }
  }

  static func sysctlInt(_ name: String) -> Int? {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return Int(value)
  }

  /// `hw.optional.arm.FEAT_*` flags (iOS 15+); absent keys mean "no".
  static func cpuFeatures() -> [String] {
    var out: [String] = []
    if sysctlInt("hw.optional.arm.FEAT_DotProd") == 1 { out.append("dotprod") }
    if sysctlInt("hw.optional.arm.FEAT_FP16") == 1 { out.append("fp16") }
    if sysctlInt("hw.optional.arm.FEAT_I8MM") == 1 { out.append("i8mm") }
    if sysctlInt("hw.optional.arm.FEAT_BF16") == 1 { out.append("bf16") }
    return out
  }

  /// Highest `MTLGPUFamilyApple<N>` the default device supports (0 when none). Families newer
  /// than the running OS are not probed.
  static func appleGpuFamily() -> Int {
    guard let device = MTLCreateSystemDefaultDevice() else { return 0 }
    let minMajor: [Int: Int] = [1: 13, 2: 13, 3: 13, 4: 13, 5: 13, 6: 13, 7: 15, 8: 16, 9: 17]
    let os = ProcessInfo.processInfo.operatingSystemVersion
    for n in stride(from: 9, through: 1, by: -1) {
      #if os(iOS)
      guard os.majorVersion >= (minMajor[n] ?? 99) else { continue }
      #else
      _ = os; _ = minMajor
      #endif
      if let family = MTLGPUFamily(rawValue: 1000 + n), device.supportsFamily(family) { return n }
    }
    return 0
  }
}
