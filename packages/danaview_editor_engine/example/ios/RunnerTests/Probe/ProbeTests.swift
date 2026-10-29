// OWNER: IOS-02
//
// Probe, compatibility, device profile and capabilities (BUILD_PLAN IOS-02): probe fields on every
// ENG-05 fixture (rotation, HDR, VFR, 5.1, MKV/WebM refusal) checked against manifest.json,
// compatibility within 300 ms on the simulator, the tier table with injected profiles (minimal,
// low, mid, high, iPhone on iOS 26 = paused vs iPad with GPU = continued), and the live
// capabilities of the simulator (software H.264 only).
//
// Deferred (no device available, D-43): the pre-17.4 HEVC path on the iPhone 8 (iOS 16.7) lab
// device. Here it only runs on the simulator (testPreHardwareKeysPathRuns); iOS 15/16 API use is
// guarded at compile time (Swift availability + -Werror=unguarded-availability-new +
// scripts/ci/editor/check_ios_min_os.sh).

import AVFoundation
import XCTest

@testable import danaview_editor_engine

/// manifest.json of the ENG-05 fixtures.
enum ProbeFixtures {
    static func manifest() throws -> [String: [String: Any]] {
        let url = try XCTUnwrap(TestFixtures.url(.engine, "media/manifest.json"))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return try XCTUnwrap(json?["files"] as? [String: [String: Any]])
    }

    static func url(_ name: String) throws -> URL {
        try XCTUnwrap(TestFixtures.url(.engine, "media/\(name)"), "fixture \(name) missing")
    }

    static func probe(_ name: String) throws -> ProbeMsg {
        let url = try url(name)
        return try MediaBlocking.await { try await Probe.probe(url: url) }
    }
}

final class ProbeTests: XCTestCase {
    func testProbeMatchesManifestForEveryFixture() throws {
        let manifest = try ProbeFixtures.manifest()
        XCTAssertGreaterThanOrEqual(manifest.count, 18)
        for (name, entry) in manifest.sorted(by: { $0.key < $1.key }) {
            let probe = try ProbeFixtures.probe(name)
            let refused = entry["iosRefusal"] as? Bool ?? false
            XCTAssertEqual(ProbeJSON.int(entry["bytes"]), Int(probe.sizeBytes), name)
            if refused {
                XCTAssertFalse(probe.editable, name)
                XCTAssertEqual(probe.issues, [ProbeIssue.containerUnsupportedIOS], name)
                continue
            }
            XCTAssertTrue(probe.editable, "\(name) issues \(probe.issues)")
            if let image = entry["image"] as? [String: Any] {
                XCTAssertEqual(probe.kind, .image, name)
                XCTAssertEqual(Int(probe.width ?? 0), ProbeJSON.int(image["width"]), name)
                XCTAssertEqual(Int(probe.height ?? 0), ProbeJSON.int(image["height"]), name)
                continue
            }
            let seconds = (entry["durationSeconds"] as? NSNumber)?.doubleValue ?? 0
            XCTAssertEqual(Double(probe.durationUs) / 1_000_000, seconds, accuracy: 0.05, name)
            if let video = entry["video"] as? [String: Any] {
                XCTAssertEqual(probe.kind, .video, name)
                XCTAssertTrue(probe.hasVideo, name)
                let displayWidth = ProbeJSON.int(video["displayWidth"] ?? video["width"])
                let displayHeight = ProbeJSON.int(video["displayHeight"] ?? video["height"])
                XCTAssertEqual(Int(probe.width ?? 0), displayWidth, name)
                XCTAssertEqual(Int(probe.height ?? 0), displayHeight, name)
                XCTAssertEqual(Int(probe.rotation), ProbeJSON.int(video["rotationDegrees"]), name)
                XCTAssertEqual(probe.videoCodec, video["codec"] as? String, name)
                let vfr = video["variableFrameRate"] as? Bool ?? (video["fps"] is NSNull)
                XCTAssertEqual(probe.variableFrameRate, vfr, name)
                if let fps = (video["fps"] as? NSNumber)?.intValue {
                    XCTAssertEqual(Int(probe.nominalFrameRate ?? 0), fps, name)
                }
                XCTAssertEqual(Int(probe.bitDepth ?? 8), ProbeJSON.int(video["bitDepth"] ?? 8), name)
                let transfer = video["transfer"] as? String
                XCTAssertEqual(probe.transfer, transfer == "arib-std-b67" ? .hlg : (transfer == "smpte2084" ? .pq : .sdr), name)
            } else {
                XCTAssertEqual(probe.kind, .audio, name)
                XCTAssertFalse(probe.hasVideo, name)
            }
            if let audio = entry["audio"] as? [String: Any] {
                XCTAssertTrue(probe.hasAudio, name)
                XCTAssertEqual(probe.audioStreams, 1, name)
                XCTAssertEqual(Int(probe.channels ?? 0), ProbeJSON.int(audio["channels"]), name)
                XCTAssertEqual(Int(probe.sampleRate ?? 0), ProbeJSON.int(audio["sampleRate"]), name)
                XCTAssertEqual(probe.audioCodec, audio["codec"] as? String, name)
            } else {
                XCTAssertFalse(probe.hasAudio, name)
            }
        }
    }

    func testRotationHdrVfrAndSurroundDetails() throws {
        let rotated = try ProbeFixtures.probe("rotated_90.mov")
        XCTAssertEqual(rotated.rotation, 90)
        XCTAssertEqual(rotated.width, 720)
        XCTAssertEqual(rotated.height, 1280)
        XCTAssertEqual(rotated.container, "mov")

        let hdr = try ProbeFixtures.probe("hlg_10bit_720p.mov")
        XCTAssertEqual(hdr.transfer, .hlg)
        XCTAssertEqual(hdr.bitDepth, 10)
        XCTAssertEqual(hdr.videoCodec, "hevc")
        XCTAssertTrue(hdr.issues.contains(ProbeIssue.hdr))
        XCTAssertTrue(hdr.issues.contains(ProbeIssue.highBitDepth))

        let vfr = try ProbeFixtures.probe("vfr_720p.mp4")
        XCTAssertTrue(vfr.variableFrameRate)
        XCTAssertTrue(vfr.issues.contains(ProbeIssue.variableFrameRate))
        XCTAssertEqual(vfr.nominalFps ?? 0, 143.0 / 6.0, accuracy: 0.5)

        let surround = try ProbeFixtures.probe("surround_5_1.m4a")
        XCTAssertEqual(surround.channels, 6)
        XCTAssertEqual(surround.audioCodec, "aac")
        XCTAssertEqual(surround.container, "m4a")

        let wav = try ProbeFixtures.probe("stereo_440l_880r.wav")
        XCTAssertEqual(wav.audioCodec, "pcm_s16le")
        XCTAssertEqual(wav.container, "wav")

        for name in ["sample_h264_aac.mkv", "sample_vp9_opus.webm"] {
            let refused = try ProbeFixtures.probe(name)
            XCTAssertFalse(refused.editable)
            XCTAssertEqual(refused.issues, ["container_unsupported_ios"])
        }
    }

    func testMissingFileIsMediaOffline() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("missing-\(UUID()).mp4")
        XCTAssertThrowsError(try MediaBlocking.await { try await Probe.probe(url: url) }) { error in
            XCTAssertEqual(EngineError.from(error).code, .mediaOffline)
        }
    }

    func testRotationFromTransforms() {
        XCTAssertEqual(Probe.rotationDegrees(.identity), 0)
        XCTAssertEqual(Probe.rotationDegrees(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 720, ty: 0)), 90)
        XCTAssertEqual(Probe.rotationDegrees(CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0)), 180)
        XCTAssertEqual(Probe.rotationDegrees(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)), 270)
        XCTAssertFalse(Probe.isVariableFrameRate(averageFps: 29.97, minFrameDuration: 1001.0 / 30000))
        XCTAssertTrue(Probe.isVariableFrameRate(averageFps: 23.8, minFrameDuration: 1.0 / 60))
    }

    func testContainerSniff() {
        XCTAssertEqual(SniffedContainer.sniff(head: Data([0x1A, 0x45, 0xDF, 0xA3]) + Data("....webm".utf8), ext: ""), .webm)
        XCTAssertEqual(SniffedContainer.sniff(head: Data([0x1A, 0x45, 0xDF, 0xA3]) + Data("matroska".utf8), ext: ""), .matroska)
        XCTAssertEqual(SniffedContainer.sniff(head: Data("RIFF\0\0\0\0AVI LIST".utf8), ext: ""), .avi)
        XCTAssertEqual(SniffedContainer.sniff(head: Data("\0\0\0\u{14}ftypqt  ".utf8), ext: "mp4"), .mov)
        XCTAssertEqual(SniffedContainer.sniff(head: Data("\0\0\0\u{18}ftypisom".utf8), ext: "mov"), .mov)
        XCTAssertEqual(SniffedContainer.sniff(head: Data("\0\0\0\u{18}ftypisom".utf8), ext: "mp4"), .mp4)
        XCTAssertTrue(SniffedContainer.avi.unsupportedOnIOS)
        XCTAssertFalse(SniffedContainer.mp4.unsupportedOnIOS)
    }
}

final class CompatibilityTests: XCTestCase {
    private func check(_ url: URL) throws -> (CompatibilityMsg, TimeInterval) {
        let done = expectation(description: "compatibility")
        var result: Result<CompatibilityMsg, Error>?
        let started = Date()
        var elapsed: TimeInterval = 0
        Compatibility.check(url) {
            elapsed = Date().timeIntervalSince(started)
            result = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return (try XCTUnwrap(result).get(), elapsed)
    }

    func testEveryFixtureWithin300ms() throws {
        let manifest = try ProbeFixtures.manifest()
        var slowest: TimeInterval = 0
        for (name, entry) in manifest.sorted(by: { $0.key < $1.key }) {
            let (answer, elapsed) = try check(try ProbeFixtures.url(name))
            slowest = max(slowest, elapsed)
            PerfGate.assertAtMost(elapsed, 0.3, "\(name) took \(Int(elapsed * 1000)) ms")
            if entry["iosRefusal"] as? Bool ?? false {
                XCTAssertFalse(answer.editable, name)
                XCTAssertEqual(answer.code, "container_unsupported_ios", name)
            } else {
                XCTAssertTrue(answer.editable, "\(name): \(answer.code ?? "")")
            }
        }
        print("IOS-02 compatibility slowest fixture: \(Int(slowest * 1000)) ms")
    }

    func testMissingFileIsNotFound() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("missing-\(UUID()).mov")
        let (answer, _) = try check(url)
        XCTAssertFalse(answer.editable)
        XCTAssertEqual(answer.code, "not_found")
    }

    func testAviByContentIsRefused() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clip-\(UUID()).mp4")
        try Data("RIFF\0\0\0\0AVI LIST\0\0\0\0hdrl".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let (answer, _) = try check(url)
        XCTAssertEqual(answer.code, "container_unsupported_ios")
    }
}

final class CapabilitiesTests: XCTestCase {
    private func profile(
        _ model: String, ram: Int, idiom: DeviceProfile.Idiom = .phone, os: Int = 18, metal: Bool = true
    ) -> DeviceProfile {
        DeviceProfile(
            modelIdentifier: model, idiom: idiom, nominalRamGB: ram, chipGeneration: DeviceProfile.chipGeneration(model: model),
            osVersion: OperatingSystemVersion(majorVersion: os, minorVersion: 0, patchVersion: 0), isSimulator: false,
            hasMetal: metal, thermalState: .nominal, lowPowerMode: false)
    }

    private let hardware = EncoderSupport(h264: true, hevc: true, hardwareH264: true, hardwareHevc: true)

    func testTierTable() {
        XCTAssertEqual(DeviceProfile.tier(ramGB: 2, chipGeneration: 11), .minimal)
        XCTAssertEqual(DeviceProfile.tier(ramGB: 3, chipGeneration: 13), .low)
        XCTAssertEqual(DeviceProfile.tier(ramGB: 4, chipGeneration: 14), .mid)
        XCTAssertEqual(DeviceProfile.tier(ramGB: 6, chipGeneration: 14), .mid)
        XCTAssertEqual(DeviceProfile.tier(ramGB: 6, chipGeneration: 15), .high)
        XCTAssertEqual(DeviceProfile.tier(ramGB: 8, chipGeneration: nil), .high)
        XCTAssertEqual(DeviceProfile.nominalGB(physicalBytes: 2_002_000_000), 2)
        XCTAssertEqual(DeviceProfile.nominalGB(physicalBytes: 2_960_000_000), 3)
        XCTAssertEqual(DeviceProfile.nominalGB(physicalBytes: 3_900_000_000), 4)
        XCTAssertEqual(DeviceProfile.nominalGB(physicalBytes: 5_900_000_000), 6)
        XCTAssertEqual(DeviceProfile.nominalGB(physicalBytes: 7_900_000_000), 8)
        XCTAssertEqual(DeviceProfile.chipGeneration(model: "iPhone10,4"), 11)
        XCTAssertEqual(DeviceProfile.chipGeneration(model: "iPhone8,4"), 9)
        XCTAssertEqual(DeviceProfile.chipGeneration(model: "iPhone14,2"), 15)
        XCTAssertEqual(DeviceProfile.chipGeneration(model: "iPad16,3"), 18)
        XCTAssertNil(DeviceProfile.chipGeneration(model: "iPad7,5"))
    }

    func testMinimalTier() {
        let caps = Capabilities.compute(profile: profile("iPhone10,4", ram: 2), encoders: hardware, backgroundGpu: false)
        XCTAssertTrue(caps.supported)
        XCTAssertEqual(caps.tier, .minimal)
        XCTAssertTrue(caps.lowMemoryDevice)
        XCTAssertTrue(caps.proxiesRecommended)
        XCTAssertTrue(caps.h264Encode)
        XCTAssertFalse(caps.hevcEncode, "minimal exports 1080p H.264 only")
        XCTAssertFalse(caps.hardwareHevc)
        XCTAssertEqual(caps.maxExportWidth, 1920)
        XCTAssertEqual(caps.maxExportHeight, 1080)
        XCTAssertEqual(caps.maxFpsByHeight[1080], 30)
        XCTAssertEqual(caps.maxConcurrentVideoLayers, 2)
        XCTAssertEqual(caps.maxPreviewLongSide, 640)
        XCTAssertEqual(caps.backgroundKind, .paused)
        XCTAssertEqual(caps.maxVisualSequences, 16)
        XCTAssertEqual(caps.maxTextureSize, 16384)
    }

    func testLowMidHighTiers() {
        let low = Capabilities.compute(profile: profile("iPhone12,8", ram: 3), encoders: hardware, backgroundGpu: false)
        XCTAssertEqual(low.tier, .low)
        XCTAssertFalse(low.lowMemoryDevice)
        XCTAssertFalse(low.proxiesRecommended)
        XCTAssertTrue(low.hevcEncode)
        XCTAssertEqual(low.maxConcurrentVideoLayers, 3)
        XCTAssertEqual(low.maxPreviewLongSide, 960)
        XCTAssertEqual(low.maxExportHeight, 1080)

        let mid = Capabilities.compute(profile: profile("iPhone13,3", ram: 6), encoders: hardware, backgroundGpu: false)
        XCTAssertEqual(mid.tier, .mid, "A14 with 6 GB stays mid")
        XCTAssertEqual(mid.maxConcurrentVideoLayers, 4)
        XCTAssertEqual(mid.maxPreviewLongSide, 1280)
        XCTAssertEqual(mid.maxExportHeight, 1440)

        let a15 = Capabilities.compute(profile: profile("iPhone14,2", ram: 6), encoders: hardware, backgroundGpu: false)
        XCTAssertEqual(a15.tier, .high, "A15 or newer with 6 GB is high")

        let high = Capabilities.compute(profile: profile("iPhone16,1", ram: 8), encoders: hardware, backgroundGpu: false)
        XCTAssertEqual(high.tier, .high)
        XCTAssertEqual(high.maxConcurrentVideoLayers, 6)
        XCTAssertEqual(high.maxPreviewLongSide, 1920)
        XCTAssertEqual(high.maxExportWidth, 3840)
        XCTAssertEqual(high.maxExportHeight, 2160)
        XCTAssertEqual(high.maxFpsByHeight[2160], 60)
        for caps in [low, mid, a15, high] {
            XCTAssertTrue(caps.movContainer)
            XCTAssertTrue(caps.holdFrame)
            XCTAssertTrue(caps.fpsUpconversion)
            XCTAssertTrue(caps.voiceRecording)
            XCTAssertEqual(caps.minSpeed, 0.1)
            XCTAssertEqual(caps.maxSpeed, 10)
            XCTAssertEqual(caps.maxAudioSpeed, 4)
            XCTAssertEqual(caps.maxLutSize, 65)
            XCTAssertEqual(caps.planVersions, [1])
            XCTAssertEqual(caps.maxVisualSequences, 16)
        }
    }

    func testIPhoneOnIOS26IsPausedAndIPadWithGpuIsContinued() {
        let iPhone = Capabilities.compute(
            profile: profile("iPhone18,1", ram: 12, os: 26), encoders: hardware, backgroundGpu: true)
        XCTAssertEqual(iPhone.backgroundKind, .paused)
        XCTAssertFalse(iPhone.backgroundGpu)

        let iPad = Capabilities.compute(
            profile: profile("iPad16,3", ram: 8, idiom: .pad, os: 26), encoders: hardware, backgroundGpu: true)
        XCTAssertEqual(iPad.backgroundKind, .continued)
        XCTAssertTrue(iPad.backgroundGpu)

        let iPadNoGpu = Capabilities.compute(
            profile: profile("iPad16,3", ram: 8, idiom: .pad, os: 26), encoders: hardware, backgroundGpu: false)
        XCTAssertEqual(iPadNoGpu.backgroundKind, .paused)

        let iPad18 = Capabilities.compute(
            profile: profile("iPad16,3", ram: 8, idiom: .pad, os: 18), encoders: hardware, backgroundGpu: true)
        XCTAssertEqual(iPad18.backgroundKind, .paused)
    }

    func testSupportedRequiresMetalAndH264() {
        let noMetal = Capabilities.compute(profile: profile("iPhone16,1", ram: 8, metal: false), encoders: hardware, backgroundGpu: false)
        XCTAssertFalse(noMetal.supported)
        XCTAssertEqual(noMetal.unsupportedReason, "no_metal")
        let noEncoder = Capabilities.compute(
            profile: profile("iPhone16,1", ram: 8),
            encoders: EncoderSupport(h264: false, hevc: false, hardwareH264: false, hardwareHevc: false), backgroundGpu: false)
        XCTAssertFalse(noEncoder.supported)
    }

    func testSimulatorCapabilities() throws {
        let roots = try TempRoots()
        defer { roots.remove() }
        let context = EngineContext(messenger: FakeMessenger(), textures: nil)
        let done = expectation(description: "capabilities")
        var caps: CapabilitiesMsg?
        Capabilities(context: context).capabilities {
            caps = try? $0.get()
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        let value = try XCTUnwrap(caps)
        XCTAssertTrue(value.supported)
        XCTAssertTrue(value.h264Encode)
        XCTAssertFalse(value.hardwareH264, "the simulator encodes in software")
        XCTAssertFalse(value.hevcEncode)
        XCTAssertEqual(value.backgroundKind, .paused)
        XCTAssertFalse(value.backgroundGpu)
        XCTAssertEqual(value.planVersions, [1])
        let profile = DeviceProfile.current(hasMetal: true)
        XCTAssertTrue(profile.isSimulator)
        XCTAssertEqual(value.tier, profile.tier)
        print("IOS-02 simulator profile \(profile.modelIdentifier) ram \(profile.nominalRamGB) GB tier \(value.tier)")
    }

    /// The pre-17.4 detection path compiles for 15.0 and runs; on the simulator its answer is not
    /// meaningful (deferred: the iPhone 8 / iOS 16.7 lab run, no device available).
    func testPreHardwareKeysPathRuns() {
        let support = Capabilities.preHardwareKeysSupport(hevcWidth: 1920, hevcHeight: 1080)
        XCTAssertTrue(support.h264)
        print("IOS-02 pre-17.4 path on the simulator: hevc=\(support.hevc)")
    }
}

/// Small JSON helpers shared by the IOS-02 tests.
enum ProbeJSON {
    static func int(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }
}
