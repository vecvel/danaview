// OWNER: AND-02
//
// D-33 placeholder created by ENG-08 (BUILD_PLAN ENG-08, ARCH §4.4). It holds only the names the
// glue calls; every call fails with `notSupportedOnDevice` (the Dart side maps that to the editor's
// unsupported state). The owner ticket replaces this file and keeps the signatures the glue uses.
// AND-02 computes the real capabilities (gate API >= 29 + GLES 3 + 2 GB, tiers, encoders,
// maxVisualSequences, maxTextureSize; ARCH §3.2, §12.5). Until then capabilities report the editor
// as unsupported with reason `engine_not_available`, which round-trips through the glue.

package com.vecvel.vwish.editor.engine.core

import com.vecvel.vwish.editor.engine.pigeon.BackgroundExportKindMsg
import com.vecvel.vwish.editor.engine.pigeon.CapabilitiesMsg
import com.vecvel.vwish.editor.engine.pigeon.DeviceTierMsg

/** Device capabilities and the editor gate (ARCH §3.2, §12.5; AND-02). */
class Capabilities(private val ctx: EngineContext) {
    /** Loads the capabilities. Called on vwish-io by `EngineHostApi.capabilities`. */
    fun load(done: Completion<CapabilitiesMsg>) {
        done.succeed(unsupported(ENGINE_NOT_AVAILABLE))
    }

    companion object {
        /** `UnsupportedReasons.engineNotAvailable` (vwish_editor_engine_api). */
        const val ENGINE_NOT_AVAILABLE = "engine_not_available"

        /** The capabilities of a device that cannot edit (mirrors Dart `EditorCapabilities.unsupported`). */
        fun unsupported(reason: String): CapabilitiesMsg = CapabilitiesMsg(
            supported = false,
            unsupportedReason = reason,
            tier = DeviceTierMsg.MINIMAL,
            lowMemoryDevice = false,
            h264Encode = false,
            hevcEncode = false,
            hardwareH264 = false,
            hardwareHevc = false,
            movContainer = false,
            maxExportWidth = 0,
            maxExportHeight = 0,
            maxFpsByHeight = emptyMap(),
            maxConcurrentVideoLayers = 0,
            maxVisualSequences = 0,
            maxTextureSize = 4096,
            maxPreviewLongSide = 960,
            backgroundKind = BackgroundExportKindMsg.NO_BACKGROUND,
            backgroundGpu = false,
            voiceRecording = false,
            proxiesRecommended = false,
            holdFrame = true,
            fpsUpconversion = true,
            externalDrop = false,
            minSpeed = 0.1,
            maxSpeed = 10.0,
            maxAudioSpeed = 4.0,
            maxLutSize = 65,
            planVersions = emptyList(),
        )
    }
}
