// OWNER: AI-06
//
// macOS host harness for ios/Classes/DeviceProfiler.swift, compiled and run by
// test/device/ios_profiler_host_test.dart. Prints one `PASS name` / `FAIL name` line per check.

import Foundation

var failures = 0
func check(_ name: String, _ ok: @autoclosure () -> Bool) {
  if ok() { print("PASS \(name)") } else { print("FAIL \(name)"); failures += 1 }
}

let profiler = DeviceProfiler()
let p = profiler.profile()

check("profile has every documented key", ["os", "osVersion", "model", "physicalRam", "isLowRam", "perfCores", "efficiencyCores",
  "totalCores", "is64Bit", "cpuFeatures", "gpuFamily", "isSimulator", "lowPowerMode", "thermal"].allSatisfy { p[$0] != nil })
check("os is ios", (p["os"] as? String) == "ios")
check("physicalRam positive", ((p["physicalRam"] as? Int) ?? 0) > 0)
check("totalCores positive", ((p["totalCores"] as? Int) ?? 0) > 0)
check("perf + efficiency <= total when known", {
  let perf = p["perfCores"] as? Int ?? 0, eff = p["efficiencyCores"] as? Int ?? 0, total = p["totalCores"] as? Int ?? 0
  return perf == 0 || perf + eff <= total
}())
check("thermal is one of four names", ["nominal", "fair", "serious", "critical"].contains(p["thermal"] as? String ?? ""))
check("cpuFeatures only known names", (p["cpuFeatures"] as? [String] ?? []).allSatisfy { ["dotprod", "fp16", "i8mm", "bf16"].contains($0) })
check("gpuFamily in 0...9", (0...9).contains(p["gpuFamily"] as? Int ?? -1))

check("thermal mapping nominal", ThermalNames.name(for: .nominal) == "nominal")
check("thermal mapping fair", ThermalNames.name(for: .fair) == "fair")
check("thermal mapping serious", ThermalNames.name(for: .serious) == "serious")
check("thermal mapping critical", ThermalNames.name(for: .critical) == "critical")

// excludeFromBackup: set, then verify through URLResourceValues read-back (independently of the helper).
let dir = NSTemporaryDirectory() + "danaview_whisper_host_\(ProcessInfo.processInfo.processIdentifier)"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(atPath: dir) }
let before = (try? URL(fileURLWithPath: dir).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) ?? nil
check("directory starts included in backup", before != true)
check("excludeFromBackup returns true", DeviceProfiler.excludeFromBackup(path: dir))
let after = (try? URL(fileURLWithPath: dir).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) ?? nil
check("read-back says excluded", after == true)
check("excludeFromBackup on a missing path is false", !DeviceProfiler.excludeFromBackup(path: dir + "/missing/nope"))

let free = profiler.freeDiskBytes(path: dir + "/does/not/exist/yet")
check("freeDiskBytes walks up to an existing parent", (free ?? 0) > 0)
check("freeDiskBytes of a root-level missing path resolves", (profiler.freeDiskBytes(path: "/definitely_missing_danaview_dir/x") ?? 0) > 0)
check("availableMemory is nil or positive", (profiler.availableMemory() ?? 1) > 0)
_ = profiler.isNetworkMetered

exit(failures == 0 ? 0 : 1)
