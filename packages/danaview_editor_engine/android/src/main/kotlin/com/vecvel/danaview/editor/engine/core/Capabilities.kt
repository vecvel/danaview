@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-02
//
// Device capabilities and the editor gate (ARCH §3.2, §12.5, D-14, D-40, D-43; BUILD_PLAN AND-02).
// `load` reads the DeviceProfile snapshot (RAM, codecs, GL) on danaview-io and `compute` turns it
// into CapabilitiesMsg. `compute` and `gate` are pure, so the tier table and the gate are
// JVM-tested with injected snapshots (src/test/.../probe/CapabilitiesTableTest.kt).
//
// Gate (ARCH §3.2), in this order: API >= 29 ('android_too_old'), an EGL context with GLES 3.0
// ('gles3_missing', V-N7), >= 2 GB nominal RAM ('insufficient_memory'). Below it the result is
// `unsupported(reason)`, which mirrors Dart's `EditorCapabilities.unsupported`.
//
// Tier limits (same table as iOS IOS-02; Android caps from AND-01 and ARCH §12.5):
//   tier     export      maxFpsByHeight         layers  sequences  preview
//   minimal  1920x1080   {720: 30, 1080: 30}    2       2          640
//   low      1920x1080   {720: 60, 1080: 30}    3       3          960
//   mid      2560x1440   {1080: 60, 1440: 30}   4       4          1280
//   high     3840x2160   {1440: 60, 2160: 60}   6       6          1920
// - maxConcurrentVideoLayers = min(table, codec instances - 1) (one instance stays free for
//   thumbnails and stills, design/native.md §8.2).
// - maxVisualSequences = min(table, (codec instances - 2) / 2): the AND-16 preview engine holds two
//   decoders per packing slot and keeps two instances free (AND-01 V-N25, recorded by ENG-06).
//   Both are at least 1; unknown instance counts (0) do not cap.
// - minimal exports 1080p H.264 only (no HEVC), sets proxiesRecommended and lowMemoryDevice (D-40).
// - hevcEncode needs a HARDWARE HEVC encoder (a software HEVC encoder is far too slow for export;
//   iOS hides HEVC on the simulator the same way); h264Encode is any H.264 encoder.
// - The export size is lowered to 1280x720 when the H.264 encoder does not take 1920x1080, and
//   from 2160p to 1440p when it does not take 3840x2160.
// - proxiesRecommended is also set when there is no hardware H.264 decoder (design/native.md §6.6).
// - backgroundKind foregroundService (AND-12's FGS keeps exports running; GL works there, so
//   backgroundGpu = true), movContainer false (Media3's muxer writes MP4), voiceRecording when the
//   device has a microphone, holdFrame, fpsUpconversion (AND-01 V-N15), externalDrop (AND-15),
//   speeds 0.1 / 10 / 4, maxLutSize 65, planVersions [1].
// - maxTextureSize = GL_MAX_TEXTURE_SIZE from the GL probe.
//
// When the editor is supported, load() also starts the thermal signal listener (DeviceProfile).

package com.vecvel.danaview.editor.engine.core

import androidx.annotation.OptIn
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import com.vecvel.danaview.editor.engine.pigeon.BackgroundExportKindMsg
import com.vecvel.danaview.editor.engine.pigeon.CapabilitiesMsg
import com.vecvel.danaview.editor.engine.pigeon.DeviceTierMsg

/** Device capabilities and the editor gate (ARCH §3.2, §12.5; AND-02). */
class Capabilities(private val ctx: EngineContext) {
    @Volatile private var cached: CapabilitiesMsg? = null

    /** Loads the capabilities. Called on danaview-io by `EngineHostApi.capabilities`. */
    fun load(done: Completion<CapabilitiesMsg>) {
        try {
            done.succeed(current())
        } catch (t: Throwable) {
            done.fail(t)
        }
    }

    /** The capabilities (computed once per process; blocking on first use). */
    fun current(): CapabilitiesMsg {
        cached?.let { return it }
        val result = compute(ctx.deviceProfile.snapshot())
        cached = result
        if (result.supported) ctx.deviceProfile.startThermalSignals()
        return result
    }

    /** Tier-dependent limits (ARCH §12.5, §13.4, §14.4; same values as iOS IOS-02). */
    data class TierLimits(
        val maxExportWidth: Long,
        val maxExportHeight: Long,
        val maxFpsByHeight: Map<Long, Long>,
        val maxConcurrentVideoLayers: Long,
        val maxVisualSequences: Long,
        val maxPreviewLongSide: Long,
    ) {
        companion object {
            /** The table row of [tier]. */
            fun of(tier: DeviceTierMsg): TierLimits = when (tier) {
                DeviceTierMsg.MINIMAL -> TierLimits(1920, 1080, mapOf(720L to 30L, 1080L to 30L), 2, 2, 640)
                DeviceTierMsg.LOW -> TierLimits(1920, 1080, mapOf(720L to 60L, 1080L to 30L), 3, 3, 960)
                DeviceTierMsg.MID -> TierLimits(2560, 1440, mapOf(1080L to 60L, 1440L to 30L), 4, 4, 1280)
                DeviceTierMsg.HIGH -> TierLimits(3840, 2160, mapOf(1440L to 60L, 2160L to 60L), 6, 6, 1920)
            }
        }
    }

    companion object {
        /** `UnsupportedReasons.engineNotAvailable` (danaview_editor_engine_api). */
        const val ENGINE_NOT_AVAILABLE = "engine_not_available"

        /** `UnsupportedReasons.androidTooOld`. */
        const val ANDROID_TOO_OLD = "android_too_old"

        /** `UnsupportedReasons.gles3Missing`. */
        const val GLES3_MISSING = "gles3_missing"

        /** `UnsupportedReasons.insufficientMemory`. */
        const val INSUFFICIENT_MEMORY = "insufficient_memory"

        /** Lowest nominal RAM of the editor gate (ARCH §3.2). */
        const val MIN_RAM_GB = 2.0

        /** RenderPlan versions the engine decodes. */
        val PLAN_VERSIONS: List<Long> = listOf(1L)

        /** The gate's reason for [snapshot], or null when the editor is supported (ARCH §3.2). */
        fun gate(snapshot: DeviceSnapshot): String? = when {
            snapshot.apiLevel < DeviceProfile.MIN_EDITOR_API -> ANDROID_TOO_OLD
            snapshot.gl?.gles3 != true -> GLES3_MISSING
            snapshot.nominalRamGb < MIN_RAM_GB -> INSUFFICIENT_MEMORY
            else -> null
        }

        /** The capabilities of [snapshot] (pure). */
        fun compute(snapshot: DeviceSnapshot): CapabilitiesMsg {
            gate(snapshot)?.let { return unsupported(it) }
            val tier = snapshot.tier
            val limits = TierLimits.of(tier)
            val minimal = tier == DeviceTierMsg.MINIMAL
            val codecs = snapshot.codecs
            val instances = codecs.maxDecoderInstances
            val layers = if (instances > 0) minOf(limits.maxConcurrentVideoLayers, (instances - 1).toLong()) else limits.maxConcurrentVideoLayers
            val sequences = if (instances > 0) minOf(limits.maxVisualSequences, ((instances - 2) / 2).toLong()) else limits.maxVisualSequences
            val h264 = codecs.hasEncoder(MimeTypes.VIDEO_H264)
            val hevc = !minimal && codecs.hasHardwareEncoder(MimeTypes.VIDEO_H265)
            var exportW = limits.maxExportWidth
            var exportH = limits.maxExportHeight
            if (exportH > 1440 && !codecs.encoderSupports2160p(MimeTypes.VIDEO_H264)) {
                exportW = 2560
                exportH = 1440
            }
            if (exportH > 720 && h264 && !codecs.encoderSupports1080p(MimeTypes.VIDEO_H264)) {
                exportW = 1280
                exportH = 720
            }
            val fpsByHeight = limits.maxFpsByHeight.filterKeys { it <= exportH }.ifEmpty { mapOf(exportH to 30L) }
            return CapabilitiesMsg(
                supported = true,
                unsupportedReason = null,
                tier = tier,
                lowMemoryDevice = minimal,
                h264Encode = h264,
                hevcEncode = hevc,
                hardwareH264 = codecs.hasHardwareEncoder(MimeTypes.VIDEO_H264),
                hardwareHevc = hevc,
                movContainer = false,
                maxExportWidth = exportW,
                maxExportHeight = exportH,
                maxFpsByHeight = fpsByHeight,
                maxConcurrentVideoLayers = layers.coerceAtLeast(1),
                maxVisualSequences = sequences.coerceAtLeast(1),
                maxTextureSize = (snapshot.gl?.maxTextureSize ?: 0).toLong().takeIf { it > 0 } ?: 4096,
                maxPreviewLongSide = limits.maxPreviewLongSide,
                backgroundKind = BackgroundExportKindMsg.FOREGROUND_SERVICE,
                backgroundGpu = true,
                voiceRecording = snapshot.microphone,
                proxiesRecommended = minimal || !codecs.hasHardwareDecoder(MimeTypes.VIDEO_H264),
                holdFrame = true,
                fpsUpconversion = true,
                externalDrop = true,
                minSpeed = 0.1,
                maxSpeed = 10.0,
                maxAudioSpeed = 4.0,
                maxLutSize = 65,
                planVersions = PLAN_VERSIONS,
            )
        }

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
