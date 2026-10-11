// OWNER: IOS-02
//
// D-33 placeholder created by ENG-07: device capabilities (ARCH §12.5, D-14, D-22, D-40).
// Only IOS-02 edits this file once it lands.
// The glue calls it through `CapabilitiesProviding` (Glue/ServiceProtocols.swift) and builds it with
// `init(context:)` (Glue/EngineServices.swift): keep both. Until then every call fails with
// `notSupportedOnDevice`, which Dart maps to the editor's unsupported state.

import Foundation

final class Capabilities: CapabilitiesProviding {
    private let context: EngineContext

    init(context: EngineContext) {
        self.context = context
    }

    /// Placeholder capabilities: not supported (`engine_not_available`), the same values as
    /// `EditorCapabilities.unsupported` in vwish_editor_engine_api.
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

    func capabilities(reply: @escaping EngineReply<CapabilitiesMsg>) {
        reply(.success(Capabilities.placeholder))
    }
}
