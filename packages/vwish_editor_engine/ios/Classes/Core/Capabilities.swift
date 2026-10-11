// OWNER: IOS-02
//
// Device capabilities (ARCH §12.5, §14.2, D-14, D-22, D-40). `capabilities()` combines the
// DeviceProfile tier table, the encoder probe and the background facts into `CapabilitiesMsg`.
// `Capabilities.compute` is pure so RunnerTests/Probe checks every tier with injected profiles.
//
// Encoder probe (ARCH §14.2):
// - iOS 17.4+: a VTCompressionSession created with
//   kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder at the target size, then
//   kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder read back (both keys are 17.4+).
// - below 17.4: device encoders count as hardware; HEVC needs
//   AVOutputSettingsAssistant(preset: .hevc1920x1080) != nil plus a VTCompressionSession create and
//   a one-frame test encode at the target size.
// - simulator: software H.264 only (HEVC hidden, hardwareH264 false).
// The probe runs once per process (about 50–150 ms) and is cached.
//
// backgroundKind (D-22): `continued` only on an iPad on iOS 26+ whose
// BGTaskScheduler.supportedResources contains .gpu (the system reports .gpu only to apps holding
// the continued-processing GPU entitlement) and whose Info.plist permits the export task
// identifiers; `paused` on every iPhone and everywhere else. The simulator reports no .gpu
// (IOS-01), so `continued` stays unverified until a real iPad run (deferred: no device available).

import AVFoundation
import BackgroundTasks
import CoreMedia
import CoreVideo
import Foundation
import Metal
import VideoToolbox

/// Encoder facts of the device.
struct EncoderSupport: Equatable {
    var h264: Bool
    var hevc: Bool
    var hardwareH264: Bool
    var hardwareHevc: Bool

    /// The simulator: software H.264 only.
    static let softwareH264Only = EncoderSupport(h264: true, hevc: false, hardwareH264: false, hardwareHevc: false)
}

final class Capabilities: CapabilitiesProviding {
    private let context: EngineContext

    init(context: EngineContext) {
        self.context = context
    }

    /// Placeholder capabilities: not supported (`engine_not_available`), the same values as
    /// `EditorCapabilities.unsupported` in vwish_editor_engine_api (glue tests and fakes).
    static let placeholder = CapabilitiesMsg(
        supported: false,
        unsupportedReason: "engine_not_available",
        tier: .minimal,
        lowMemoryDevice: false,
        h264Encode: false,
        hevcEncode: false,
        hardwareH264: false,
        hardwareHevc: false,
        movContainer: false,
        maxExportWidth: 0,
        maxExportHeight: 0,
        maxFpsByHeight: [:],
        maxConcurrentVideoLayers: 0,
        maxVisualSequences: 0,
        maxTextureSize: 4096,
        maxPreviewLongSide: 960,
        backgroundKind: .noBackground,
        backgroundGpu: false,
        voiceRecording: false,
        proxiesRecommended: false,
        holdFrame: true,
        fpsUpconversion: true,
        externalDrop: false,
        minSpeed: 0.1,
        maxSpeed: 10,
        maxAudioSpeed: 4,
        maxLutSize: 65,
        planVersions: [])

    /// RenderPlan versions this engine decodes.
    static let planVersions: [Int64] = [1]

    func capabilities(reply: @escaping EngineReply<CapabilitiesMsg>) {
        let metal = MTLCreateSystemDefaultDevice() != nil
        let profile = DeviceProfile.current(hasMetal: metal)
        let encoders = Capabilities.encoderSupport(profile: profile)
        let gpu = Capabilities.backgroundGpuAvailable(profile: profile)
        reply(.success(Capabilities.compute(profile: profile, encoders: encoders, backgroundGpu: gpu)))
    }

    // MARK: Pure capability table

    /// Tier-dependent limits (ARCH §12.5, §13.4, §14.4).
    struct TierLimits: Equatable {
        var maxExportWidth: Int64
        var maxExportHeight: Int64
        var maxFpsByHeight: [Int64: Int64]
        var maxConcurrentVideoLayers: Int64
        var maxPreviewLongSide: Int64

        static func of(_ tier: DeviceTierMsg) -> TierLimits {
            switch tier {
            case .minimal:
                return TierLimits(
                    maxExportWidth: 1920, maxExportHeight: 1080, maxFpsByHeight: [720: 30, 1080: 30],
                    maxConcurrentVideoLayers: 2, maxPreviewLongSide: 640)
            case .low:
                return TierLimits(
                    maxExportWidth: 1920, maxExportHeight: 1080, maxFpsByHeight: [720: 60, 1080: 30],
                    maxConcurrentVideoLayers: 3, maxPreviewLongSide: 960)
            case .mid:
                // 1440p; IOS-12's preflight may allow 4K for plans with <= 2 layers (ARCH §14.4).
                return TierLimits(
                    maxExportWidth: 2560, maxExportHeight: 1440, maxFpsByHeight: [1080: 60, 1440: 30],
                    maxConcurrentVideoLayers: 4, maxPreviewLongSide: 1280)
            case .high:
                return TierLimits(
                    maxExportWidth: 3840, maxExportHeight: 2160, maxFpsByHeight: [1440: 60, 2160: 60],
                    maxConcurrentVideoLayers: 6, maxPreviewLongSide: 1920)
            }
        }
    }

    /// The capabilities of [profile] with the probed [encoders]. [backgroundGpu] is the
    /// `supportedResources.contains(.gpu)` + entitlement fact.
    static func compute(profile: DeviceProfile, encoders: EncoderSupport, backgroundGpu: Bool) -> CapabilitiesMsg {
        let tier = profile.tier
        let limits = TierLimits.of(tier)
        let minimal = tier == .minimal
        // Minimal devices export 1080p H.264 only (D-40).
        let hevc = encoders.hevc && !minimal
        let continued = profile.idiom == .pad && profile.osAtLeast(26) && backgroundGpu
        let supported = profile.hasMetal && encoders.h264
        return CapabilitiesMsg(
            supported: supported,
            unsupportedReason: supported ? nil : (profile.hasMetal ? "encoder_unavailable" : "no_metal"),
            tier: tier,
            lowMemoryDevice: minimal,
            h264Encode: encoders.h264,
            hevcEncode: hevc,
            hardwareH264: encoders.hardwareH264,
            hardwareHevc: hevc && encoders.hardwareHevc,
            movContainer: true,
            maxExportWidth: limits.maxExportWidth,
            maxExportHeight: limits.maxExportHeight,
            maxFpsByHeight: limits.maxFpsByHeight,
            maxConcurrentVideoLayers: limits.maxConcurrentVideoLayers,
            maxVisualSequences: 16,
            maxTextureSize: 16384,
            maxPreviewLongSide: limits.maxPreviewLongSide,
            backgroundKind: continued ? .continued : .paused,
            backgroundGpu: continued,
            voiceRecording: true,
            proxiesRecommended: minimal,
            holdFrame: true,
            fpsUpconversion: true,
            externalDrop: true,  // UIDropInteraction (IOS-16), iPhone and iPad on iOS 15+
            minSpeed: 0.1,
            maxSpeed: 10,
            maxAudioSpeed: 4,
            maxLutSize: 65,
            planVersions: planVersions)
    }

    // MARK: Background facts

    /// The continued-processing task identifier pattern the app must permit (INT-03).
    static let exportTaskIdentifierPattern = "com.vecvel.vwish.export.*"

    /// Whether this process may run a continued-processing export with the GPU (iOS 26+).
    static func backgroundGpuAvailable(profile: DeviceProfile, bundle: Bundle = .main) -> Bool {
        guard profile.idiom == .pad else { return false }
        let permitted = (bundle.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? [])
            .contains { $0 == exportTaskIdentifierPattern || $0.hasPrefix("com.vecvel.vwish.export.") }
        guard permitted else { return false }
        if #available(iOS 26.0, *) {
            return BGTaskScheduler.supportedResources.contains(.gpu)
        }
        return false
    }

    // MARK: Encoder probe

    private static let probeLock = NSLock()
    private static var probed: EncoderSupport?

    /// The device's encoders (cached after the first probe).
    static func encoderSupport(profile: DeviceProfile) -> EncoderSupport {
        probeLock.lock()
        defer { probeLock.unlock() }
        if let cached = probed { return cached }
        let support = probeEncoders(profile: profile)
        probed = support
        Log.info(.engine, "encoders h264=\(support.h264) hevc=\(support.hevc) hwH264=\(support.hardwareH264) hwHevc=\(support.hardwareHevc)")
        return support
    }

    /// Probes the encoders without the cache.
    static func probeEncoders(profile: DeviceProfile) -> EncoderSupport {
        if profile.isSimulator {
            return EncoderSupport.softwareH264Only
        }
        let hevcSize = profile.tier == .high ? (3840, 2160) : (1920, 1080)
        if #available(iOS 17.4, *) {
            let h264Hardware = hardwareSession(codec: kCMVideoCodecType_H264, width: 1920, height: 1080)
            let hevcHardware = hardwareSession(codec: kCMVideoCodecType_HEVC, width: hevcSize.0, height: hevcSize.1)
            let h264 = h264Hardware || testEncode(codec: kCMVideoCodecType_H264, width: 1920, height: 1080)
            return EncoderSupport(h264: h264, hevc: hevcHardware, hardwareH264: h264Hardware, hardwareHevc: hevcHardware)
        }
        return preHardwareKeysSupport(hevcWidth: hevcSize.0, hevcHeight: hevcSize.1)
    }

    /// The pre-17.4 path: device encoders count as hardware; HEVC needs the settings assistant and
    /// a one-frame test encode at the target size (D-41; runs on iOS 15/16 devices).
    static func preHardwareKeysSupport(hevcWidth: Int, hevcHeight: Int) -> EncoderSupport {
        let h264 = testEncode(codec: kCMVideoCodecType_H264, width: 1920, height: 1080)
        let assistant = AVOutputSettingsAssistant(preset: .hevc1920x1080) != nil
        let hevc = assistant && testEncode(codec: kCMVideoCodecType_HEVC, width: hevcWidth, height: hevcHeight)
        return EncoderSupport(h264: h264, hevc: hevc, hardwareH264: h264, hardwareHevc: hevc)
    }

    /// Creates a hardware-only session (17.4+ keys) and confirms the hardware flag.
    @available(iOS 17.4, *)
    static func hardwareSession(codec: CMVideoCodecType, width: Int, height: Int) -> Bool {
        let spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue as Any]
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: codec,
            encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session = session else { return false }
        defer { VTCompressionSessionInvalidate(session) }
        var value: CFTypeRef?
        let read = withUnsafeMutablePointer(to: &value) { pointer in
            VTSessionCopyProperty(
                session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                allocator: nil, valueOut: UnsafeMutableRawPointer(pointer))
        }
        guard read == noErr, let flag = value else { return true }
        return (flag as? Bool) ?? true
    }

    /// Creates a session and encodes one black frame at the size; true when a frame came out.
    static func testEncode(codec: CMVideoCodecType, width: Int, height: Int) -> Bool {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: codec,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session = session else { return false }
        defer { VTCompressionSessionInvalidate(session) }
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes as CFDictionary, &buffer) == kCVReturnSuccess, let frame = buffer
        else { return false }
        var produced = false
        let encoded = VTCompressionSessionEncodeFrame(
            session, imageBuffer: frame, presentationTimeStamp: .zero, duration: CMTime(value: 1, timescale: 30),
            frameProperties: nil, infoFlagsOut: nil
        ) { status, _, sample in
            if status == noErr, sample != nil { produced = true }
        }
        guard encoded == noErr else { return false }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        return produced
    }
}
