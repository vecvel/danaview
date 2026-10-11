@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-05
//
// ProxyRegistry and ProxyJob's pure parts on the JVM: status by fingerprint (file, tracked job
// state, noProxy), the proxies/ file name, the min(4 GB, 10 % free) LRU cap with pinned and fresh
// proxies kept, the Transformer settings (540 short side, no upscale, HDR -> SDR tone-map choice,
// AND-01 V-N5) and the Transformer error mapping.

package com.vecvel.vwish.editor.engine.proxy

import android.content.ContextWrapper
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.ColorInfo
import androidx.media3.common.Format
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Composition
import androidx.media3.transformer.ExportException
import com.vecvel.vwish.editor.engine.core.CodecEntry
import com.vecvel.vwish.editor.engine.core.CodecInventory
import com.vecvel.vwish.editor.engine.core.EngineContext
import com.vecvel.vwish.editor.engine.core.EngineErrorCode
import com.vecvel.vwish.editor.engine.core.EngineException
import com.vecvel.vwish.editor.engine.core.Paths
import com.vecvel.vwish.editor.engine.core.ToneMappingSupport
import com.vecvel.vwish.editor.engine.glue.FakeThreads
import com.vecvel.vwish.editor.engine.media.DiskCache
import com.vecvel.vwish.editor.engine.media.ProxyJob
import com.vecvel.vwish.editor.engine.media.ProxyRegistry
import com.vecvel.vwish.editor.engine.pigeon.ProxyStatusMsg
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.FileNotFoundException

class ProxyRegistryTest {
    @get:Rule
    val temp = TemporaryFolder()

    private lateinit var paths: Paths
    private val gb = 1024L * 1024L * 1024L

    @Before
    fun setUp() {
        val root = temp.newFolder("app")
        paths = Paths.fromDart(File(root, "cache/vwish/editor").absolutePath, File(root, "files/vwish/editor").absolutePath)
        assertTrue(paths.ensureRoots())
    }

    private fun writeProxy(fingerprint: String, bytes: Int, accessedMs: Long): File {
        val file = ProxyRegistry.proxyFile(fingerprint, paths)
        file.parentFile!!.mkdirs()
        file.writeBytes(ByteArray(bytes))
        file.setLastModified(accessedMs)
        return file
    }

    @Test
    fun proxyLivesInProxiesWithTheQuickHashName() {
        val file = ProxyRegistry.proxyFile("0123abcd", paths)
        assertEquals(paths.proxies.absoluteFile, file.parentFile!!.absoluteFile)
        assertEquals("0123abcd-540.mp4", file.name)
        // Unsafe fingerprints are hashed into a file-safe name.
        val odd = ProxyRegistry.proxyFile("../x y", paths)
        assertEquals(paths.proxies.absoluteFile, odd.parentFile!!.absoluteFile)
        assertTrue(odd.name.matches(Regex("[0-9a-f]+-540\\.mp4")))
    }

    @Test
    fun statusIsReadyThenTrackedThenNoProxy() {
        assertEquals(ProxyStatusMsg.NO_PROXY, ProxyRegistry.status("s1", paths))
        ProxyRegistry.mark("s1", ProxyStatusMsg.QUEUED)
        assertEquals(ProxyStatusMsg.QUEUED, ProxyRegistry.status("s1", paths))
        ProxyRegistry.mark("s1", ProxyStatusMsg.RUNNING)
        assertEquals(ProxyStatusMsg.RUNNING, ProxyRegistry.status("s1", paths))
        ProxyRegistry.mark("s1", ProxyStatusMsg.FAILED)
        assertEquals(ProxyStatusMsg.FAILED, ProxyRegistry.status("s1", paths))
        writeProxy("s1", 10, 1_000)
        assertEquals("the file wins over the tracked state", ProxyStatusMsg.READY, ProxyRegistry.status("s1", paths))
        ProxyRegistry.mark("s1", null)
        assertEquals(ProxyStatusMsg.READY, ProxyRegistry.status("s1", paths))
        assertTrue(ProxyRegistry.proxyFile("s1", paths).delete())
        assertEquals(ProxyStatusMsg.NO_PROXY, ProxyRegistry.status("s1", paths))
    }

    @Test
    fun statusThroughTheServiceAnswersAndNeedsInitialize() {
        val fake = FakeThreads()
        val ctx = EngineContext(ContextWrapper(null), fake.threads)
        val early = mutableListOf<Result<ProxyStatusMsg>>()
        ProxyRegistry(ctx).status("s2") { early.add(it) }
        assertTrue(early.single().isFailure)
        ctx.installRoots(paths)
        val answers = mutableListOf<Result<ProxyStatusMsg>>()
        ProxyRegistry(ctx).status("s2") { answers.add(it) }
        assertEquals(ProxyStatusMsg.NO_PROXY, answers.single().getOrThrow())
    }

    @Test
    fun readyProxyIsTouchedAsRecentlyUsed() {
        val file = writeProxy("t1", 10, 1_000)
        val found = ProxyRegistry.readyProxy("t1", paths)!!
        assertEquals(file.absoluteFile, found.absoluteFile)
        assertTrue("lookup touches the file", file.lastModified() > 1_000)
        assertNull(ProxyRegistry.readyProxy("missing", paths))
    }

    @Test
    fun capIsTheSmallerOfFourGbAndTenPercentFree() {
        assertEquals(4 * gb, ProxyRegistry.capBytes(paths, freeBytes = 100 * gb))
        assertEquals(gb, ProxyRegistry.capBytes(paths, freeBytes = 10 * gb))
        assertEquals(0L, ProxyRegistry.capBytes(paths, freeBytes = -5))
        assertTrue("reads the real free space", ProxyRegistry.capBytes(paths) > 0)
    }

    @Test
    fun enforceCapEvictsLeastRecentlyUsedButKeepsPinnedAndFreshProxies() {
        val old = writeProxy("old", 400, 1_000)
        val pinned = writeProxy("pinned", 400, 2_000)
        val mid = writeProxy("mid", 400, 3_000)
        val fresh = writeProxy("fresh", 400, 500) // oldest time, but it is the proxy just written
        ProxyRegistry.pin(pinned, paths)
        try {
            // Cap 1000 bytes (10 % of 10 000 free).
            val freed = ProxyRegistry.enforceCap(paths, keep = fresh, freeBytes = 10_000)
            assertEquals(800L, freed)
            assertFalse(old.exists())
            assertFalse(mid.exists())
            assertTrue(pinned.exists())
            assertTrue(fresh.exists())
            assertFalse("the keep pin is released", ProxyRegistry.store(paths).isPinned(fresh))
        } finally {
            ProxyRegistry.unpin(pinned, paths)
        }
        // Clear editor cache removes proxies too (when nothing is active).
        assertTrue(DiskCache.trim(com.vecvel.vwish.editor.engine.pigeon.CacheTrimLevelMsg.CLEAR_ALL, paths))
        assertFalse(pinned.exists())
    }

    // ---- ProxyJob settings ----

    private fun video(width: Int, height: Int, mime: String = "video/avc", transfer: Int = Format.NO_VALUE, tenBit: Boolean = false): Format {
        val builder = Format.Builder().setSampleMimeType(mime).setWidth(width).setHeight(height)
        if (transfer != Format.NO_VALUE || tenBit) {
            val color = ColorInfo.Builder().setColorTransfer(transfer)
            if (tenBit) color.setLumaBitdepth(10).setChromaBitdepth(10)
            builder.setColorInfo(color.build())
        }
        return builder.build()
    }

    private fun codecs(tenBitHevc: Boolean) = CodecInventory(
        listOf(
            CodecEntry("c2.test.avc.decoder", "video/avc", false, true, 16, true, true, false),
            CodecEntry("c2.test.hevc.decoder", "video/hevc", false, true, 16, true, true, tenBitHevc),
            CodecEntry("c2.test.avc.encoder", "video/avc", true, true, 16, true, true, false),
        ),
    )

    @Test
    fun shortSideIs540WithoutUpscaling() {
        val gl = ToneMappingSupport(glYuvTarget = true, apiLevel = 35)
        assertEquals(540, ProxyJob.Settings.of(video(1920, 1080), codecs(true), gl).shortSide)
        assertEquals("portrait sources too", 540, ProxyJob.Settings.of(video(1080, 1920), codecs(true), gl).shortSide)
        assertEquals(540, ProxyJob.Settings.of(video(1280, 720), codecs(true), gl).shortSide)
        assertNull("540p stays", ProxyJob.Settings.of(video(960, 540), codecs(true), gl).shortSide)
        assertNull("smaller sources are not upscaled", ProxyJob.Settings.of(video(640, 360), codecs(true), gl).shortSide)
        assertFalse(ProxyJob.Settings.of(video(1280, 720), codecs(true), gl, hasAudio = false).hasAudio)
        assertEquals(3_000_000, ProxyJob.VIDEO_BITRATE)
        assertEquals(0.33f, ProxyJob.I_FRAME_INTERVAL_S, 0f)
        assertEquals(128_000, ProxyJob.AUDIO_BITRATE)
    }

    @Test
    fun hdrSourcesAreToneMappedToSdr() {
        val hlg = video(1280, 720, "video/hevc", C.COLOR_TRANSFER_HLG, tenBit = true)
        val pq = video(3840, 2160, "video/hevc", C.COLOR_TRANSFER_ST2084, tenBit = true)
        val sdr = video(1280, 720, transfer = C.COLOR_TRANSFER_SDR)
        // SDR: nothing to map.
        assertEquals(Composition.HDR_MODE_KEEP_HDR, ProxyJob.Settings.hdrMode(sdr, codecs(true), ToneMappingSupport.NONE))
        assertEquals(Composition.HDR_MODE_KEEP_HDR, ProxyJob.Settings.hdrMode(video(1280, 720), codecs(true), ToneMappingSupport.NONE))
        // OpenGL tone map: GL_EXT_YUV_target + a 10-bit decoder (AND-01 V-N5), on any API.
        val openGl = ToneMappingSupport(glYuvTarget = true, apiLevel = 29)
        assertEquals(Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL, ProxyJob.Settings.hdrMode(hlg, codecs(true), openGl))
        assertEquals(Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL, ProxyJob.Settings.hdrMode(pq, codecs(true), openGl))
        // No 10-bit decoder or no GL extension: MediaCodec tone mapping on API 31+.
        assertEquals(
            Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_MEDIACODEC,
            ProxyJob.Settings.hdrMode(hlg, codecs(false), ToneMappingSupport(glYuvTarget = true, apiLevel = 31)),
        )
        assertEquals(
            Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_MEDIACODEC,
            ProxyJob.Settings.hdrMode(hlg, codecs(true), ToneMappingSupport(glYuvTarget = false, apiLevel = 35)),
        )
        // Neither: unsupportedMedia (never an HDR proxy).
        val error = runCatching { ProxyJob.Settings.hdrMode(hlg, codecs(true), ToneMappingSupport(glYuvTarget = false, apiLevel = 30)) }.exceptionOrNull()
        assertEquals(EngineErrorCode.unsupportedMedia, (error as EngineException).code)
    }

    @Test
    fun transformerErrorsMapToEngineCodes() {
        fun code(errorCode: Int, cause: Throwable = RuntimeException("x")) =
            ProxyJob.mapError(ExportException.createForAssetLoader(cause, errorCode)).code
        assertEquals(EngineErrorCode.mediaOffline, code(ExportException.ERROR_CODE_IO_FILE_NOT_FOUND))
        assertEquals(EngineErrorCode.permissionDenied, code(ExportException.ERROR_CODE_IO_NO_PERMISSION))
        assertEquals(EngineErrorCode.decoderInitFailed, code(ExportException.ERROR_CODE_DECODER_INIT_FAILED))
        assertEquals(EngineErrorCode.decodeFailed, code(ExportException.ERROR_CODE_DECODING_FAILED))
        assertEquals(EngineErrorCode.unsupportedMedia, code(ExportException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED))
        assertEquals(EngineErrorCode.encoderUnavailable, code(ExportException.ERROR_CODE_ENCODER_INIT_FAILED))
        assertEquals(EngineErrorCode.encoderUnavailable, code(ExportException.ERROR_CODE_ENCODING_FORMAT_UNSUPPORTED))
        assertEquals(EngineErrorCode.encodingFailed, code(ExportException.ERROR_CODE_ENCODING_FAILED))
        assertEquals(EngineErrorCode.diskFull, code(ExportException.ERROR_CODE_MUXING_FAILED, java.io.IOException("write failed: ENOSPC")))
        assertEquals(EngineErrorCode.internal, code(ExportException.ERROR_CODE_UNSPECIFIED))
        assertEquals(EngineErrorCode.mediaOffline, ProxyJob.mapError(FileNotFoundException("gone")).code)
        val message = ProxyJob.mapError(ExportException.createForAssetLoader(RuntimeException("/sdcard/secret.mp4"), ExportException.ERROR_CODE_DECODING_FAILED)).message!!
        assertFalse("no paths in messages", message.contains("secret"))
    }

    @Test
    fun partFilesLiveInWorkPerJob() {
        val a = ProxyJob.partFile(paths, "job-1")
        val b = ProxyJob.partFile(paths, "job-2")
        assertEquals(paths.work.absoluteFile, a.parentFile!!.absoluteFile)
        assertTrue(a.name.endsWith(".mp4.part"))
        assertFalse(a == b)
    }
}
