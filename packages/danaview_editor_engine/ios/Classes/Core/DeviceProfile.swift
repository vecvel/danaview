// OWNER: IOS-02
//
// Device profile (ARCH §12.5, D-40): model, nominal RAM, Apple chip generation, idiom, OS version,
// thermal state and low-power mode, and the tier table:
//
//   minimal  < 3 GB RAM (A9–A11 2 GB: iPhone 6s/7/8/SE 1st gen)
//   low      3 GB (iPhone 7 Plus/8 Plus/X/XR/SE 2nd gen)
//   mid      4–6 GB
//   high     >= 8 GB, or A15 or newer with 6 GB
//
// RAM comes from a model table when the model is known (the simulator reports the Mac's memory,
// so its SIMULATOR_MODEL_IDENTIFIER is looked up as well), otherwise from
// `ProcessInfo.physicalMemory` rounded up to the nominal size (devices report a little less than
// their nominal RAM). Pure values: `Capabilities` turns a profile into `CapabilitiesMsg`, and tests
// inject profiles.

import Foundation
import UIKit

/// The device facts the engine's capabilities depend on.
struct DeviceProfile: Equatable {
    enum Idiom: String, Equatable {
        case phone, pad, other
    }

    /// Hardware model identifier ("iPhone10,4"); the simulated model on the simulator.
    var modelIdentifier: String
    var idiom: Idiom
    /// Nominal RAM in GB (2, 3, 4, 6, 8, 12, 16 ...).
    var nominalRamGB: Int
    /// Apple A-series generation (9 for A9 ... 19 for A19); M-series map to their A-series
    /// sibling (M1 = 14, M2 = 15, M3 = 17, M4 = 18). Nil when unknown.
    var chipGeneration: Int?
    var osVersion: OperatingSystemVersion
    var isSimulator: Bool
    /// A Metal device exists (the editor requires one).
    var hasMetal: Bool
    var thermalState: ProcessInfo.ThermalState
    var lowPowerMode: Bool

    static func == (lhs: DeviceProfile, rhs: DeviceProfile) -> Bool {
        lhs.modelIdentifier == rhs.modelIdentifier && lhs.idiom == rhs.idiom && lhs.nominalRamGB == rhs.nominalRamGB
            && lhs.chipGeneration == rhs.chipGeneration && lhs.osVersion.majorVersion == rhs.osVersion.majorVersion
            && lhs.osVersion.minorVersion == rhs.osVersion.minorVersion
            && lhs.osVersion.patchVersion == rhs.osVersion.patchVersion && lhs.isSimulator == rhs.isSimulator
            && lhs.hasMetal == rhs.hasMetal && lhs.thermalState == rhs.thermalState && lhs.lowPowerMode == rhs.lowPowerMode
    }

    // MARK: Tier (D-40)

    /// The device tier of this profile.
    var tier: DeviceTierMsg { DeviceProfile.tier(ramGB: nominalRamGB, chipGeneration: chipGeneration) }

    /// The tier table of ARCH §12.5.
    static func tier(ramGB: Int, chipGeneration: Int?) -> DeviceTierMsg {
        if ramGB < 3 { return .minimal }
        if ramGB >= 8 { return .high }
        if ramGB >= 6, let chip = chipGeneration, chip >= 15 { return .high }
        if ramGB >= 4 { return .mid }
        return .low
    }

    /// Whether the OS is at least [major].[minor].
    func osAtLeast(_ major: Int, _ minor: Int = 0) -> Bool {
        osVersion.majorVersion > major || (osVersion.majorVersion == major && osVersion.minorVersion >= minor)
    }

    // MARK: Current device

    /// The profile of the running device. Cheap: no media work.
    static func current(hasMetal: Bool) -> DeviceProfile {
        let info = ProcessInfo.processInfo
        #if targetEnvironment(simulator)
        let simulator = true
        let model = info.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? hardwareModel()
        #else
        let simulator = false
        let model = hardwareModel()
        #endif
        let idiom: Idiom
        if model.hasPrefix("iPhone") || model.hasPrefix("iPod") {
            idiom = .phone
        } else if model.hasPrefix("iPad") {
            idiom = .pad
        } else {
            switch UIDevice.current.userInterfaceIdiom {
            case .phone: idiom = .phone
            case .pad: idiom = .pad
            default: idiom = .other
            }
        }
        let measured = nominalGB(physicalBytes: info.physicalMemory)
        // On the simulator the physical memory is the Mac's: prefer the simulated model's RAM.
        let ram = knownRamGB[model] ?? measured
        return DeviceProfile(
            modelIdentifier: model,
            idiom: idiom,
            nominalRamGB: ram,
            chipGeneration: chipGeneration(model: model),
            osVersion: info.operatingSystemVersion,
            isSimulator: simulator,
            hasMetal: hasMetal,
            thermalState: info.thermalState,
            lowPowerMode: info.isLowPowerModeEnabled)
    }

    /// `utsname.machine` ("iPhone10,4"; "arm64" on the simulator).
    static func hardwareModel() -> String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// Nominal RAM sizes Apple ships.
    static let nominalSizes = [1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 64]

    /// Nominal RAM from the reported physical memory: devices report less than their nominal size
    /// (2 GB -> ~1.9 GiB, 3 GB -> ~2.8 GiB, 4 GB -> ~3.7 GiB, 8 GB -> ~7.4 GiB), so the smallest
    /// shipped size at or above the reported amount.
    static func nominalGB(physicalBytes: UInt64) -> Int {
        let gib = Double(physicalBytes) / 1_073_741_824
        return nominalSizes.first { Double($0) >= gib - 0.01 } ?? Int(gib.rounded(.up))
    }

    /// Apple chip generation from the model identifier. iPhone majors map to A(major + 1) from
    /// iPhone8 (A9) on; known iPad/iPod identifiers are listed.
    static func chipGeneration(model: String) -> Int? {
        if let known = knownChip[model] { return known }
        guard model.hasPrefix("iPhone"),
              let major = Int(model.dropFirst("iPhone".count).prefix { $0 != "," }), major >= 8
        else { return nil }
        return major + 1
    }

    /// Nominal RAM (GB) of known iPhone models (the simulator needs it; devices are also measured).
    static let knownRamGB: [String: Int] = [
        "iPhone8,1": 2, "iPhone8,2": 2, "iPhone8,4": 2,
        "iPhone9,1": 2, "iPhone9,3": 2, "iPhone9,2": 3, "iPhone9,4": 3,
        "iPhone10,1": 2, "iPhone10,4": 2, "iPhone10,2": 3, "iPhone10,5": 3, "iPhone10,3": 3, "iPhone10,6": 3,
        "iPhone11,2": 4, "iPhone11,4": 4, "iPhone11,6": 4, "iPhone11,8": 3,
        "iPhone12,1": 4, "iPhone12,3": 4, "iPhone12,5": 4, "iPhone12,8": 3,
        "iPhone13,1": 4, "iPhone13,2": 4, "iPhone13,3": 6, "iPhone13,4": 6,
        "iPhone14,4": 4, "iPhone14,5": 4, "iPhone14,2": 6, "iPhone14,3": 6, "iPhone14,6": 4,
        "iPhone14,7": 6, "iPhone14,8": 6,
        "iPhone15,2": 6, "iPhone15,3": 6, "iPhone15,4": 6, "iPhone15,5": 6,
        "iPhone16,1": 8, "iPhone16,2": 8,
        "iPhone17,1": 8, "iPhone17,2": 8, "iPhone17,3": 8, "iPhone17,4": 8, "iPhone17,5": 8,
        "iPhone18,1": 12, "iPhone18,2": 12, "iPhone18,3": 8, "iPhone18,4": 12,
        // iPads of the simulator runtimes.
        "iPad16,3": 8, "iPad16,4": 8, "iPad16,5": 8, "iPad16,6": 8,  // iPad Pro M4
        "iPad14,8": 8, "iPad14,9": 8, "iPad14,10": 8, "iPad14,11": 8,  // iPad Air M2
        "iPad16,1": 8, "iPad16,2": 8,  // iPad mini A17 Pro
    ]

    /// Chips of identifiers the iPhone rule does not cover.
    static let knownChip: [String: Int] = [
        "iPad16,3": 18, "iPad16,4": 18, "iPad16,5": 18, "iPad16,6": 18,
        "iPad14,8": 15, "iPad14,9": 15, "iPad14,10": 15, "iPad14,11": 15,
        "iPad16,1": 17, "iPad16,2": 17,
        "iPad13,4": 14, "iPad13,5": 14, "iPad13,6": 14, "iPad13,7": 14,  // iPad Pro M1
        "iPad13,8": 14, "iPad13,9": 14, "iPad13,10": 14, "iPad13,11": 14,
        "iPad14,3": 15, "iPad14,4": 15, "iPad14,5": 15, "iPad14,6": 15,  // iPad Pro M2
    ]
}
