@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-02
//
// Device profile (ARCH §3.2, §12.5, D-40; BUILD_PLAN AND-02): what Capabilities, the tier table,
// compatibility and the job registry need to know about the device, gathered once per process:
//
// - RAM (ActivityManager.MemoryInfo.totalMem) and isLowRamDevice. Phones report less than their
//   marketing size (kernel and carve-outs), so the tier table works on the nominal size: the
//   smallest marketed size >= totalMem (1.38 GiB -> 1.5, 1.85 -> 2, 2.75 -> 3, 3.7 -> 4, 7.4 -> 8).
// - SoC (Build.SOC_MANUFACTURER/SOC_MODEL on API 31+, else Build.HARDWARE); diagnostics only.
// - Codecs (`CodecInventory`, MediaCodecList REGULAR_CODECS): decoders and encoders per MIME with
//   isHardwareAccelerated (API 29+), the H.264 decoder's maxSupportedInstances, encoder sizes, and
//   whether a decoder takes 10-bit HEVC/VP9/AV1. Also answers "is there a decoder for this Format".
// - GL (`GlInfo`): an EGL14 pbuffer context with EGL_CONTEXT_CLIENT_VERSION 3 (V-N7); with it,
//   GL_MAX_TEXTURE_SIZE and whether GL_EXT_YUV_target is exported (needed by Media3's OpenGL HDR
//   tone map, AND-01 V-N5). The one-time probe runs on the danaview-gl lane (ARCH §18.1) whichever
//   lane asks first; callers wait up to GL_PROBE_TIMEOUT_MS and the result is cached.
// - Thermal: PowerManager.OnThermalStatusChangedListener (API 29+) -> ctx.events.signal(thermal)
//   with the same mapping as danaview_whisper's AI-06 (NONE/LIGHT nominal, MODERATE fair, SEVERE
//   serious, CRITICAL and worse critical). Started by Capabilities once the editor is supported.
//
// The pure parts (`Tiers`, `ThermalLevels`, `ToneMappingSupport.canToneMap`) are JVM-tested with
// injected snapshots (src/test/.../probe/).

package com.vecvel.danaview.editor.engine.core

import android.annotation.SuppressLint
import android.app.ActivityManager
import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.GLES20
import android.os.Build
import android.os.PowerManager
import android.util.Log
import androidx.annotation.OptIn
import androidx.annotation.RequiresApi
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import com.vecvel.danaview.editor.engine.media.VideoFormats
import com.vecvel.danaview.editor.engine.pigeon.DeviceTierMsg
import com.vecvel.danaview.editor.engine.pigeon.SignalKindMsg
import com.vecvel.danaview.editor.engine.pigeon.SignalMsg
import com.vecvel.danaview.editor.engine.pigeon.ThermalLevelMsg
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executor
import java.util.concurrent.FutureTask
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.ceil

/** One codec of the device (from MediaCodecList). */
data class CodecEntry(
    val name: String,
    val mime: String,
    val encoder: Boolean,
    /** MediaCodecInfo.isHardwareAccelerated (API 29+); false below. */
    val hardware: Boolean,
    /** maxSupportedInstances (0 when unknown). */
    val maxInstances: Int,
    /** Whether a 1920x1080 frame is within the codec's supported sizes (video only). */
    val supports1080p: Boolean,
    /** Whether a 3840x2160 frame is within the codec's supported sizes (video only). */
    val supports2160p: Boolean,
    /** A 10-bit profile is advertised (HEVC Main10, VP9 profile 2, AV1 Main 10-bit). */
    val tenBit: Boolean,
    /** Profiles advertised (CodecProfileLevel.profile values). */
    val profiles: Set<Int> = emptySet(),
)

/**
 * The device's codecs. [decoderFinder] answers "a decoder exists for this MediaFormat"
 * (MediaCodecList.findDecoderForFormat on a device; injected in JVM tests).
 */
class CodecInventory(
    val entries: List<CodecEntry>,
    private val decoderFinder: (mime: String, width: Int, height: Int, profile: Int) -> Boolean =
        { mime, _, _, _ -> entries.any { !it.encoder && it.mime.equals(mime, ignoreCase = true) } },
) {
    private fun of(mime: String, encoder: Boolean) = entries.filter { it.encoder == encoder && it.mime.equals(mime, ignoreCase = true) }

    /** Any encoder for [mime]. */
    fun hasEncoder(mime: String): Boolean = of(mime, true).isNotEmpty()

    /** A hardware encoder for [mime]. */
    fun hasHardwareEncoder(mime: String): Boolean = of(mime, true).any { it.hardware }

    /** A hardware decoder for [mime]. */
    fun hasHardwareDecoder(mime: String): Boolean = of(mime, false).any { it.hardware }

    /** An encoder for [mime] that takes 1920x1080. */
    fun encoderSupports1080p(mime: String): Boolean = of(mime, true).any { it.supports1080p }

    /** An encoder for [mime] that takes 3840x2160. */
    fun encoderSupports2160p(mime: String): Boolean = of(mime, true).any { it.supports2160p }

    /** A decoder for [mime] that takes 10-bit content. */
    fun hasTenBitDecoder(mime: String): Boolean = of(mime, false).any { it.tenBit }

    /**
     * Decoder instances the editor can count on: the largest maxSupportedInstances among the H.264
     * decoders, preferring hardware ones (0 when unknown).
     */
    val maxDecoderInstances: Int
        get() {
            val avc = of(MimeTypes.VIDEO_H264, false)
            val pool = avc.filter { it.hardware }.ifEmpty { avc }
            return pool.maxOfOrNull { it.maxInstances } ?: 0
        }

    /** Whether a decoder exists for [format] (MIME, size and, for 10-bit content, a 10-bit profile). */
    fun hasDecoder(format: Format): Boolean {
        val mime = format.sampleMimeType ?: return false
        if (MimeTypes.isAudio(mime) && mime == MimeTypes.AUDIO_RAW) return true // PCM needs no codec
        val profile = if (MimeTypes.isVideo(mime) && VideoFormats.bitDepth(format) > 8) TEN_BIT_PROFILE else NO_PROFILE
        if (profile == TEN_BIT_PROFILE && !hasTenBitDecoder(mime)) return false
        return decoderFinder(mime, format.width, format.height, profile)
    }

    companion object {
        /** No profile constraint. */
        const val NO_PROFILE = -1

        /** Marker for "a 10-bit profile of the MIME's family". */
        const val TEN_BIT_PROFILE = -2

        /** Reads MediaCodecList (REGULAR_CODECS). */
        fun load(): CodecInventory {
            val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
            val entries = ArrayList<CodecEntry>()
            for (info in list.codecInfos) {
                for (type in info.supportedTypes) {
                    val caps = try {
                        info.getCapabilitiesForType(type)
                    } catch (e: IllegalArgumentException) {
                        continue
                    }
                    val video = caps.videoCapabilities
                    val profiles = caps.profileLevels.map { it.profile }.toSet()
                    entries.add(
                        CodecEntry(
                            name = info.name,
                            mime = type.lowercase(),
                            encoder = info.isEncoder,
                            hardware = isHardware(info),
                            maxInstances = caps.maxSupportedInstances,
                            supports1080p = video?.let { sizeOk(it, 1920, 1080) } ?: false,
                            supports2160p = video?.let { sizeOk(it, 3840, 2160) } ?: false,
                            tenBit = isTenBit(type.lowercase(), profiles),
                            profiles = profiles,
                        ),
                    )
                }
            }
            return CodecInventory(entries) { mime, width, height, profile ->
                val format = MediaFormat.createVideoFormat(mime, width.coerceAtLeast(16), height.coerceAtLeast(16))
                if (!MimeTypes.isVideo(mime)) {
                    entries.any { !it.encoder && it.mime.equals(mime, ignoreCase = true) }
                } else if (width <= 0 || height <= 0) {
                    entries.any { !it.encoder && it.mime.equals(mime, ignoreCase = true) }
                } else {
                    val found = list.findDecoderForFormat(format) != null ||
                        // Portrait sizes: some decoders list only landscape ranges.
                        list.findDecoderForFormat(MediaFormat.createVideoFormat(mime, height, width)) != null
                    found && (profile != TEN_BIT_PROFILE || entries.any { !it.encoder && it.mime == mime.lowercase() && it.tenBit })
                }
            }
        }

        private fun isHardware(info: MediaCodecInfo): Boolean =
            if (Build.VERSION.SDK_INT >= 29) isHardware29(info) else !info.name.startsWith("OMX.google.") && !info.name.startsWith("c2.android.")

        @RequiresApi(29)
        private fun isHardware29(info: MediaCodecInfo): Boolean = info.isHardwareAccelerated

        private fun sizeOk(video: MediaCodecInfo.VideoCapabilities, w: Int, h: Int): Boolean =
            try {
                video.isSizeSupported(w, h) || video.isSizeSupported(h, w)
            } catch (e: IllegalArgumentException) {
                false
            }

        /** Whether [profiles] of [mime] include a 10-bit profile (the constants are inlined ints, safe on any API). */
        @SuppressLint("InlinedApi")
        fun isTenBit(mime: String, profiles: Set<Int>): Boolean = when (mime) {
            MimeTypes.VIDEO_H265 -> profiles.any {
                it == MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10 ||
                    it == MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10HDR10 ||
                    it == MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10HDR10Plus
            }
            MimeTypes.VIDEO_VP9 -> profiles.any {
                it == MediaCodecInfo.CodecProfileLevel.VP9Profile2 || it == MediaCodecInfo.CodecProfileLevel.VP9Profile3 ||
                    it == MediaCodecInfo.CodecProfileLevel.VP9Profile2HDR || it == MediaCodecInfo.CodecProfileLevel.VP9Profile3HDR
            }
            MimeTypes.VIDEO_AV1 -> profiles.any {
                it == MediaCodecInfo.CodecProfileLevel.AV1ProfileMain10 || it == MediaCodecInfo.CodecProfileLevel.AV1ProfileMain10HDR10
            }
            MimeTypes.VIDEO_DOLBY_VISION -> true
            else -> false
        }
    }
}

/** What the GL probe found. */
data class GlInfo(
    /** An EGL context with GLES 3.0 could be created (V-N7). */
    val gles3: Boolean,
    /** GL_MAX_TEXTURE_SIZE (0 when no context). */
    val maxTextureSize: Int,
    /** GL_EXT_YUV_target is exported (Media3's OpenGL HDR tone map, AND-01 V-N5). */
    val yuvTarget: Boolean,
    /** GLES version string (diagnostics). */
    val version: String? = null,
) {
    companion object {
        /** No usable GL. */
        val NONE = GlInfo(gles3 = false, maxTextureSize = 0, yuvTarget = false)

        /**
         * Creates a 1x1 pbuffer EGL context with EGL_CONTEXT_CLIENT_VERSION 3 on the calling thread,
         * reads GL_MAX_TEXTURE_SIZE and the extensions, and tears everything down.
         */
        fun probe(): GlInfo {
            val display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
            if (display == EGL14.EGL_NO_DISPLAY) return NONE
            val version = IntArray(2)
            if (!EGL14.eglInitialize(display, version, 0, version, 1)) return NONE
            val previousContext = EGL14.eglGetCurrentContext()
            val previousDraw = EGL14.eglGetCurrentSurface(EGL14.EGL_DRAW)
            val previousRead = EGL14.eglGetCurrentSurface(EGL14.EGL_READ)
            val previousDisplay = EGL14.eglGetCurrentDisplay()
            try {
                val attributes = intArrayOf(
                    EGL14.EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR,
                    EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
                    EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
                    EGL14.EGL_NONE,
                )
                val configs = arrayOfNulls<EGLConfig>(1)
                val count = IntArray(1)
                if (!EGL14.eglChooseConfig(display, attributes, 0, configs, 0, 1, count, 0) || count[0] == 0) return NONE
                val config = configs[0] ?: return NONE
                val context = EGL14.eglCreateContext(
                    display, config, EGL14.EGL_NO_CONTEXT, intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE), 0,
                )
                if (context == null || context == EGL14.EGL_NO_CONTEXT) return NONE
                val surface = EGL14.eglCreatePbufferSurface(display, config, intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0)
                try {
                    if (surface == null || surface == EGL14.EGL_NO_SURFACE) return NONE
                    if (!EGL14.eglMakeCurrent(display, surface, surface, context)) return NONE
                    val max = IntArray(1)
                    GLES20.glGetIntegerv(GLES20.GL_MAX_TEXTURE_SIZE, max, 0)
                    val extensions = GLES20.glGetString(GLES20.GL_EXTENSIONS).orEmpty()
                    val glVersion = GLES20.glGetString(GLES20.GL_VERSION)
                    val major = parseGlesMajor(glVersion)
                    return GlInfo(
                        gles3 = major >= 3,
                        maxTextureSize = max[0],
                        yuvTarget = extensions.split(' ').any { it == "GL_EXT_YUV_target" },
                        version = glVersion,
                    )
                } finally {
                    EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
                    if (surface != null && surface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, surface)
                    EGL14.eglDestroyContext(display, context)
                }
            } finally {
                if (previousContext != null && previousContext != EGL14.EGL_NO_CONTEXT) {
                    EGL14.eglMakeCurrent(previousDisplay, previousDraw, previousRead, previousContext)
                }
                // eglTerminate is not called: the default display is shared with Flutter and Media3.
            }
        }

        /** The major version of a GL_VERSION string ("OpenGL ES 3.2 ..."), 0 when unknown. */
        fun parseGlesMajor(version: String?): Int =
            Regex("""OpenGL ES (\d+)\.""").find(version.orEmpty())?.groupValues?.get(1)?.toIntOrNull() ?: 0

        /** EGL_KHR_create_context: EGL_OPENGL_ES3_BIT_KHR. */
        const val EGL_OPENGL_ES3_BIT_KHR = 0x0040
    }
}

/** HDR tone-mapping facts (AND-01 V-N5, ARCH §13.3). */
data class ToneMappingSupport(
    /** GL_EXT_YUV_target is exported (Media3's OpenGL tone map can compile). */
    val glYuvTarget: Boolean,
    /** Build.VERSION.SDK_INT (MediaCodec tone mapping needs API 31). */
    val apiLevel: Int,
) {
    /** Media3's OpenGL HDR -> SDR path works when a 10-bit decoder exists for [mime]. */
    fun openGlToneMap(codecs: CodecInventory, mime: String): Boolean = glYuvTarget && codecs.hasTenBitDecoder(mime)

    /** MediaCodec tone mapping (`HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_MEDIACODEC`) needs API 31+. */
    val mediaCodecToneMap: Boolean get() = apiLevel >= 31

    /**
     * Whether HDR [format] can be edited here: a decoder for it exists and either the OpenGL or the
     * MediaCodec tone map is available (the proxy is made with the same tone map, ARCH §9.5).
     */
    fun canToneMap(codecs: CodecInventory, format: Format): Boolean {
        val mime = format.sampleMimeType ?: return false
        if (!codecs.hasDecoder(format)) return false
        return openGlToneMap(codecs, mime) || mediaCodecToneMap
    }

    companion object {
        /** No tone mapping. */
        val NONE = ToneMappingSupport(glYuvTarget = false, apiLevel = 0)
    }
}

/** Everything the tier table and the gate read (injectable in tests). */
data class DeviceSnapshot(
    val apiLevel: Int,
    /** ActivityManager.MemoryInfo.totalMem. */
    val totalRamBytes: Long,
    /** ActivityManager.isLowRamDevice (Android Go). */
    val lowRamDevice: Boolean,
    /** SoC manufacturer/model or Build.HARDWARE (diagnostics only). */
    val soc: String,
    /** GL facts (null when not probed: below the API gate). */
    val gl: GlInfo?,
    val codecs: CodecInventory,
    /** The device has a microphone. */
    val microphone: Boolean = true,
) {
    /** Nominal RAM in GB (see the file comment). */
    val nominalRamGb: Double get() = Tiers.nominalRamGb(totalRamBytes)

    /** The device tier (ARCH §12.5, D-40). */
    val tier: DeviceTierMsg get() = Tiers.tier(this)

    /** Tone-mapping facts. */
    val toneMapping: ToneMappingSupport get() = ToneMappingSupport(gl?.yuvTarget == true, apiLevel)
}

/** The Android tier table (ARCH §12.5, D-40). */
object Tiers {
    private const val GIB = 1024.0 * 1024.0 * 1024.0

    /** Marketed RAM sizes in GB; a device's nominal size is the smallest one >= its totalMem. */
    val STANDARD_SIZES_GB = doubleArrayOf(0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0, 6.0, 8.0, 10.0, 12.0, 16.0, 18.0, 24.0, 32.0)

    /**
     * Marketing RAM size from totalMem (which excludes the kernel and carve-outs): the smallest
     * standard size >= totalMem / GiB (1.38 -> 1.5, 1.85 -> 2, 2.75 -> 3, 3.7 -> 4, 5.5 -> 6,
     * 7.4 -> 8); above the table, the next whole GB. 0 when unknown.
     */
    fun nominalRamGb(totalRamBytes: Long): Double {
        if (totalRamBytes <= 0) return 0.0
        val gib = totalRamBytes / GIB
        return STANDARD_SIZES_GB.firstOrNull { it >= gib } ?: ceil(gib)
    }

    /**
     * minimal: < 3 GB or isLowRamDevice (D-40); low: 3–4 GB (Android <= 4 GB); mid: the 6 GB class
     * (above 4, below 8); high: >= 8 GB.
     */
    fun tier(snapshot: DeviceSnapshot): DeviceTierMsg = tier(snapshot.nominalRamGb, snapshot.lowRamDevice)

    /** The tier of a device with [nominalRamGb] GB that is (or is not) a [lowRamDevice]. */
    fun tier(nominalRamGb: Double, lowRamDevice: Boolean): DeviceTierMsg = when {
        lowRamDevice || nominalRamGb < 3.0 -> DeviceTierMsg.MINIMAL
        nominalRamGb <= 4.0 -> DeviceTierMsg.LOW
        nominalRamGb < 8.0 -> DeviceTierMsg.MID
        else -> DeviceTierMsg.HIGH
    }
}

/** PowerManager thermal status -> ThermalLevelMsg (same mapping as danaview_whisper's AI-06 ThermalMapper). */
object ThermalLevels {
    /** PowerManager.THERMAL_STATUS_* values (literals so the mapping is JVM-testable). */
    const val STATUS_NONE = 0
    const val STATUS_LIGHT = 1
    const val STATUS_MODERATE = 2
    const val STATUS_SEVERE = 3
    const val STATUS_CRITICAL = 4

    /** NONE/LIGHT nominal, MODERATE fair, SEVERE serious, CRITICAL and worse critical; negative = no signal. */
    fun map(status: Int): ThermalLevelMsg? = when {
        status < 0 -> null
        status <= STATUS_LIGHT -> ThermalLevelMsg.NOMINAL
        status == STATUS_MODERATE -> ThermalLevelMsg.FAIR
        status == STATUS_SEVERE -> ThermalLevelMsg.SERIOUS
        else -> ThermalLevelMsg.CRITICAL
    }
}

/** Device profile used by capabilities and tiers (ARCH §3.2, §12.5; AND-02). */
class DeviceProfile(private val ctx: EngineContext) {
    @Volatile private var cachedCodecs: CodecInventory? = null
    @Volatile private var cachedGl: GlInfo? = null
    private val glProbe = AtomicReference<FutureTask<GlInfo>?>()
    @Volatile private var thermalListener: Any? = null
    private val thermalLock = Any()
    private var lastThermal: ThermalLevelMsg = ThermalLevelMsg.NOMINAL

    /** The device's codecs (MediaCodecList, read once). */
    fun codecs(): CodecInventory = cachedCodecs ?: synchronized(this) {
        cachedCodecs ?: CodecInventory.load().also { cachedCodecs = it }
    }

    /**
     * GL facts, probed once on the danaview-gl lane (never on the caller's io/compat/job lane) and cached.
     * Callers wait up to [GL_PROBE_TIMEOUT_MS]; on a timeout they get [GlInfo.NONE] uncached and the
     * probe still finishes and caches later. No lock is held while waiting, so a GL-lane task that
     * calls back into the profile cannot deadlock with a waiter.
     */
    fun gl(): GlInfo {
        cachedGl?.let { return it }
        if (Build.VERSION.SDK_INT < MIN_EDITOR_API) return GlInfo.NONE.also { cachedGl = it }
        val lane = ctx.threads.gl
        if (lane.isCurrentThread()) return safeGlProbe().also { cachedGl = it }
        val task = glProbe.get() ?: FutureTask { safeGlProbe().also { cachedGl = it } }.let { fresh ->
            if (!glProbe.compareAndSet(null, fresh)) return@let glProbe.get() ?: return gl()
            try {
                lane.execute(fresh)
            } catch (e: RejectedExecutionException) {
                glProbe.compareAndSet(fresh, null)
                return GlInfo.NONE
            }
            fresh
        }
        return try {
            task.get(GL_PROBE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        } catch (e: TimeoutException) {
            Log.w(EngineContext.TAG, "GL probe timed out on danaview-gl")
            if (!task.isDone) glProbe.compareAndSet(task, null)
            GlInfo.NONE
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            GlInfo.NONE
        } catch (e: ExecutionException) {
            GlInfo.NONE
        }
    }

    /** HDR tone-mapping facts of this device. */
    fun toneMapping(): ToneMappingSupport = ToneMappingSupport(gl().yuvTarget, Build.VERSION.SDK_INT)

    /** The full snapshot (blocking: codec list and GL probe on first use). */
    fun snapshot(): DeviceSnapshot {
        val context = ctx.appContext
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val info = ActivityManager.MemoryInfo()
        am.getMemoryInfo(info)
        val api = Build.VERSION.SDK_INT
        return DeviceSnapshot(
            apiLevel = api,
            totalRamBytes = info.totalMem,
            lowRamDevice = am.isLowRamDevice,
            soc = soc(),
            gl = if (api >= MIN_EDITOR_API) gl() else null,
            codecs = codecs(),
            microphone = context.packageManager.hasSystemFeature(PackageManager.FEATURE_MICROPHONE),
        )
    }

    /** The device tier (minimal/low/mid/high) without the GL probe. */
    fun tier(): DeviceTierMsg {
        val am = ctx.appContext.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val info = ActivityManager.MemoryInfo()
        am.getMemoryInfo(info)
        return Tiers.tier(Tiers.nominalRamGb(info.totalMem), am.isLowRamDevice)
    }

    /**
     * Starts forwarding thermal status changes as `signal(thermal)` events (API 29+; idempotent).
     * The first callback reports the current status; only changes from the last level are sent.
     */
    fun startThermalSignals() {
        if (Build.VERSION.SDK_INT < MIN_EDITOR_API || thermalListener != null) return
        synchronized(this) {
            if (thermalListener != null) return
            thermalListener = registerThermal29()
        }
    }

    @RequiresApi(29)
    private fun registerThermal29(): Any? {
        val pm = ctx.appContext.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return null
        val listener = PowerManager.OnThermalStatusChangedListener { status -> onThermalStatus(status) }
        val direct = Executor { it.run() }
        pm.addThermalStatusListener(direct, listener)
        return listener
    }

    /** Emits a thermal signal when [status] maps to a level different from the last one. */
    internal fun onThermalStatus(status: Int) {
        val level = ThermalLevels.map(status) ?: return
        synchronized(thermalLock) {
            if (level == lastThermal) return
            lastThermal = level
            // Emitted under the lock so two listener threads cannot reorder levels.
            ctx.events.signal(SignalMsg(kind = SignalKindMsg.THERMAL, thermalLevel = level))
        }
    }

    private fun soc(): String =
        if (Build.VERSION.SDK_INT >= 31) "${Build.SOC_MANUFACTURER} ${Build.SOC_MODEL}".trim() else Build.HARDWARE.orEmpty()

    private fun safeGlProbe(): GlInfo = try {
        GlInfo.probe()
    } catch (t: RuntimeException) {
        Log.w(EngineContext.TAG, "GL probe failed: ${t.javaClass.simpleName}")
        GlInfo.NONE
    }

    companion object {
        /** The editor's API gate (ARCH §3.2). */
        const val MIN_EDITOR_API = 29

        /** How long a caller waits for the one-time GL probe on danaview-gl. */
        const val GL_PROBE_TIMEOUT_MS = 5_000L
    }
}
