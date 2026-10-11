// OWNER: AND-02
//
// The device side of AND-02 on the emulator: the GLES 3 EGL context (V-N7; also run on the API 29
// AVD), GL_MAX_TEXTURE_SIZE, the capabilities and compatibility through the engine context with
// the <= 300 ms budget, and the thermal signal plumbing. Emulator numbers are logged under the tag
// VwishProbeTest (they are emulator measurements, not device numbers).
//
// The GLES 3 criterion on API 29: the default checks only agree with the GLES version the image
// declares, which passes on a GLES 2 image too. The API 29 run therefore passes
// -Pandroid.testInstrumentationRunnerArguments.requireGles3=true, which makes the probe and the
// editor gate assert GLES 3. The Pixel_API_29 AVD only exposes GLES 3 when booted with
// `-feature GLESDynamicVersion` (without it the guest is capped at GLES 2.0).

package com.vecvel.vwish.editor.engine.probe

import android.os.Build
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.vecvel.vwish.editor.engine.core.DeviceProfile
import com.vecvel.vwish.editor.engine.core.LaneSpec
import com.vecvel.vwish.editor.engine.core.Capabilities
import com.vecvel.vwish.editor.engine.core.EngineContext
import com.vecvel.vwish.editor.engine.core.EngineThreads
import com.vecvel.vwish.editor.engine.core.GlInfo
import com.vecvel.vwish.editor.engine.core.Tiers
import com.vecvel.vwish.editor.engine.harness.FixtureTree
import com.vecvel.vwish.editor.engine.harness.TestFixtures
import com.vecvel.vwish.editor.engine.media.Compatibility
import com.vecvel.vwish.editor.engine.pigeon.CapabilitiesMsg
import com.vecvel.vwish.editor.engine.pigeon.CompatibilityMsg
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

@RunWith(AndroidJUnit4::class)
class DeviceCapabilitiesTest {
    companion object {
        private const val TAG = "VwishProbeTest"
        private lateinit var ctx: EngineContext

        @BeforeClass
        @JvmStatic
        fun setUp() {
            ctx = EngineContext(TestFixtures.targetContext.applicationContext, EngineThreads.android())
        }

        @AfterClass
        @JvmStatic
        fun tearDown() {
            ctx.threads.shutdown()
        }
    }

    /** ConfigurationInfo.reqGlEsVersion: the GLES version the system declares (ro.opengles.version). */
    private fun declaredGlesVersion(): Int =
        (TestFixtures.targetContext.getSystemService(android.content.Context.ACTIVITY_SERVICE) as android.app.ActivityManager)
            .deviceConfigurationInfo.reqGlEsVersion

    /** `requireGles3=true` (instrumentation argument): this run must have GLES 3 (the API 29 criterion). */
    private val requireGles3: Boolean =
        InstrumentationRegistry.getArguments().getString("requireGles3")?.toBoolean() == true

    @Test
    fun gles3ContextAndMaxTextureSize() {
        val gl = GlInfo.probe()
        val declared = declaredGlesVersion()
        Log.i(
            TAG,
            "API ${Build.VERSION.SDK_INT}: declared GLES 0x${Integer.toHexString(declared)} -> GLES3=${gl.gles3} " +
                "GL_MAX_TEXTURE_SIZE=${gl.maxTextureSize} GL_EXT_YUV_target=${gl.yuvTarget} version=${gl.version}",
        )
        // The check agrees with the GLES version the system declares (ro.opengles.version): an
        // image that only offers GLES 2.0 must answer gles3_missing, never a false positive.
        assertEquals("an EGL context with GLES 3.0 (V-N7)", declared >= 0x30000, gl.gles3)
        if (requireGles3) {
            assertTrue("requireGles3: the image declares GLES 3 (0x${Integer.toHexString(declared)})", declared >= 0x30000)
            assertTrue("requireGles3: a GLES 3.0 EGL context", gl.gles3)
        }
        if (gl.gles3) assertTrue("GL_MAX_TEXTURE_SIZE read: ${gl.maxTextureSize}", gl.maxTextureSize >= 2048)
        // The probe leaves no context current on this thread.
        assertEquals(android.opengl.EGL14.EGL_NO_CONTEXT, android.opengl.EGL14.eglGetCurrentContext())
    }

    @Test
    fun glProbeRunsOnTheGlLane() {
        // The one-time probe runs on vwish-gl, whichever lane asks first (here vwish-io), and is cached.
        val threads = EngineThreads.android()
        val local = EngineContext(TestFixtures.targetContext.applicationContext, threads)
        try {
            val profile = DeviceProfile(local)
            assertFalse(threads.started().any { it.spec == LaneSpec.GL })
            val result = AtomicReference<GlInfo>()
            val latch = CountDownLatch(1)
            threads.io.execute { result.set(profile.gl()); latch.countDown() }
            assertTrue(latch.await(30, TimeUnit.SECONDS))
            assertTrue("the probe started the vwish-gl lane", threads.started().any { it.spec == LaneSpec.GL })
            assertEquals(GlInfo.probe(), result.get())
            assertTrue("cached", profile.gl() === result.get())
        } finally {
            threads.shutdown()
        }
    }

    @Test
    fun capabilitiesOnThisDevice() {
        val result = AtomicReference<Result<CapabilitiesMsg>>()
        val latch = CountDownLatch(1)
        ctx.threads.io.execute { ctx.capabilities.load { result.set(it); latch.countDown() } }
        assertTrue(latch.await(30, TimeUnit.SECONDS))
        val caps = result.get().getOrThrow()
        val snapshot = ctx.deviceProfile.snapshot()
        Log.i(
            TAG,
            "API ${snapshot.apiLevel} RAM ${snapshot.totalRamBytes / (1024 * 1024)} MB (nominal ${snapshot.nominalRamGb} GB) " +
                "lowRam=${snapshot.lowRamDevice} soc=${snapshot.soc} decoderInstances=${snapshot.codecs.maxDecoderInstances} -> " +
                "supported=${caps.supported} tier=${caps.tier} h264=${caps.h264Encode}/${caps.hardwareH264} hevc=${caps.hevcEncode} " +
                "export=${caps.maxExportWidth}x${caps.maxExportHeight} fps=${caps.maxFpsByHeight} layers=${caps.maxConcurrentVideoLayers} " +
                "sequences=${caps.maxVisualSequences} maxTexture=${caps.maxTextureSize} preview=${caps.maxPreviewLongSide} " +
                "proxies=${caps.proxiesRecommended}",
        )
        assertEquals(Capabilities.compute(snapshot), caps)
        if (requireGles3) assertTrue("requireGles3: the editor gate passes with GLES 3 (${caps.unsupportedReason})", caps.supported)
        if (declaredGlesVersion() < 0x30000) {
            // An image without GLES 3 (e.g. an API 29 AVD whose emulator caps the guest at GLES 2.0).
            assertFalse(caps.supported)
            assertEquals("gles3_missing", caps.unsupportedReason)
            return
        }
        assertTrue("the emulator passes the editor gate", caps.supported)
        assertEquals(Tiers.tier(snapshot), caps.tier)
        assertEquals(snapshot.gl!!.maxTextureSize.toLong(), caps.maxTextureSize)
        assertTrue(caps.h264Encode)
        assertTrue(caps.fpsUpconversion)
        assertEquals(listOf(1L), caps.planVersions)
    }

    private fun compatibility(uri: String): Pair<CompatibilityMsg, Long> {
        val result = AtomicReference<Result<CompatibilityMsg>>()
        val latch = CountDownLatch(1)
        val started = System.nanoTime()
        ctx.threads.io.execute { ctx.compatibility.check(uri) { result.set(it); latch.countDown() } }
        assertTrue(latch.await(5, TimeUnit.SECONDS))
        val ms = (System.nanoTime() - started) / 1_000_000
        return result.get().getOrThrow() to ms
    }

    @Test
    fun compatibilityWithinBudget() {
        // Warm the codec list and GL facts once (the first editor call pays them in capabilities()).
        ctx.deviceProfile.codecs()
        ctx.deviceProfile.toneMapping()
        val codecs = ctx.deviceProfile.codecs()
        val tone = ctx.deviceProfile.toneMapping()
        val names = listOf(
            "frame_counter_1080p30.mp4", "clap_flash_av.mp4", "vfr_720p.mp4", "rotated_90.mov", "hlg_10bit_720p.mov",
            "sample_h264_aac.mkv", "sample_vp9_opus.webm", "speech_10s.m4a", "surround_5_1.m4a", "tone_1khz.wav",
            "still_4k.jpg", "alpha.png",
        )
        val times = ArrayList<Long>()
        for (name in names) {
            val file = TestFixtures.copyToCache(FixtureTree.ENGINE, "media/$name")
            val blockingStart = System.nanoTime()
            val direct = Compatibility.check(TestFixtures.targetContext, file.absolutePath, codecs, tone)
            val blockingMs = (System.nanoTime() - blockingStart) / 1_000_000
            val (answer, ms) = compatibility(file.absolutePath)
            times.add(ms)
            Log.i(TAG, "compatibility $name: editable=${answer.editable} code=${answer.code} in $ms ms (checks $blockingMs ms)")
            assertTrue("$name answered in $ms ms", ms <= 300)
            if (blockingMs < Compatibility.TIMEOUT_MS) assertEquals(name, direct, answer)
            val expectEditable = name != "hlg_10bit_720p.mov" ||
                (codecs.hasTenBitDecoder("video/hevc") && (tone.glYuvTarget || tone.apiLevel >= 31))
            assertEquals("$name editable", expectEditable, direct.editable)
        }
        times.sort()
        Log.i(TAG, "compatibility p50 ${times[times.size / 2]} ms, max ${times.last()} ms over ${times.size} fixtures")
    }

    @Test
    fun missingFileIsNotFound() {
        val (answer, _) = compatibility(File(TestFixtures.targetContext.cacheDir, "nope/missing.mp4").absolutePath)
        assertFalse(answer.editable)
        assertEquals("not_found", answer.code)
    }

    @Test
    fun thermalStatusBecomesASignal() {
        val received = java.util.Collections.synchronizedList(ArrayList<com.vecvel.vwish.editor.engine.pigeon.EngineEventMsg>())
        val sink = com.vecvel.vwish.editor.engine.core.EngineEventSink { received.add(it) }
        val instrumentation = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
        // A context of its own whose real PowerManager listener is never registered, so only the
        // statuses below reach the hub (the real listener is exercised by capabilitiesOnThisDevice).
        val thermalCtx = EngineContext(TestFixtures.targetContext.applicationContext, EngineThreads.android())
        instrumentation.runOnMainSync { thermalCtx.events.attach(sink) }
        try {
            val profile = thermalCtx.deviceProfile
            profile.onThermalStatus(3) // SEVERE -> serious
            profile.onThermalStatus(3) // unchanged: no event
            profile.onThermalStatus(4) // CRITICAL -> critical
            profile.onThermalStatus(0) // NONE -> nominal
            instrumentation.waitForIdleSync()
            val levels = received.filter { it.kind == com.vecvel.vwish.editor.engine.pigeon.EngineEventKindMsg.SIGNAL }
                .map { it.signal!!.thermalLevel }
            assertEquals(
                listOf(
                    com.vecvel.vwish.editor.engine.pigeon.ThermalLevelMsg.SERIOUS,
                    com.vecvel.vwish.editor.engine.pigeon.ThermalLevelMsg.CRITICAL,
                    com.vecvel.vwish.editor.engine.pigeon.ThermalLevelMsg.NOMINAL,
                ),
                levels,
            )
        } finally {
            instrumentation.runOnMainSync { thermalCtx.events.detach(sink) }
            thermalCtx.threads.shutdown()
        }
    }
}
