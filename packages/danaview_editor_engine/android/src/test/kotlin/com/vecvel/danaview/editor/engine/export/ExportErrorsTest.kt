// OWNER: AND-11
//
// ExportException → EngineErrorCode mapping (ARCH §14.3) and the §14.1 portrait retry rule.

package com.vecvel.danaview.editor.engine.export

import androidx.media3.transformer.ExportException
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.FileNotFoundException
import java.io.IOException

class ExportErrorsTest {
    private fun codec(code: Int, video: Boolean = true, cause: Throwable = IllegalStateException("codec")) =
        ExportException.createForCodec(cause, code, ExportException.CodecInfo("format", video, false, "c2.test.encoder"))

    private fun loader(code: Int, cause: Throwable = IllegalStateException("x")) = ExportException.createForAssetLoader(cause, code)

    @Test
    fun codesMapAsArchitecture14_3Says() {
        val cases = mapOf(
            loader(ExportException.ERROR_CODE_IO_FILE_NOT_FOUND) to EngineErrorCode.mediaOffline,
            loader(ExportException.ERROR_CODE_IO_NO_PERMISSION) to EngineErrorCode.permissionDenied,
            codec(ExportException.ERROR_CODE_DECODER_INIT_FAILED) to EngineErrorCode.decoderInitFailed,
            codec(ExportException.ERROR_CODE_DECODING_FAILED) to EngineErrorCode.decodeFailed,
            codec(ExportException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED) to EngineErrorCode.unsupportedMedia,
            codec(ExportException.ERROR_CODE_ENCODER_INIT_FAILED) to EngineErrorCode.encoderUnavailable,
            codec(ExportException.ERROR_CODE_ENCODING_FORMAT_UNSUPPORTED) to EngineErrorCode.encoderUnavailable,
            codec(ExportException.ERROR_CODE_ENCODING_FAILED) to EngineErrorCode.encodingFailed,
            loader(ExportException.ERROR_CODE_VIDEO_FRAME_PROCESSING_FAILED) to EngineErrorCode.gpuUnavailable,
            loader(ExportException.ERROR_CODE_MUXING_FAILED) to EngineErrorCode.io,
            loader(ExportException.ERROR_CODE_IO_UNSPECIFIED) to EngineErrorCode.io,
            loader(ExportException.ERROR_CODE_UNSPECIFIED) to EngineErrorCode.internal,
            loader(ExportException.ERROR_CODE_FAILED_RUNTIME_CHECK) to EngineErrorCode.internal,
        )
        for ((e, code) in cases) {
            val m = ExportErrors.map(e)
            assertEquals(e.errorCodeName, code, m.code)
            assertSame(e, m.cause)
            assertEquals("export failed (${e.errorCodeName})", m.message)
        }
    }

    @Test
    fun encoderRefusalOfARefusedSizeIsEncoderSizeLimit() {
        assertEquals(EngineErrorCode.encoderSizeLimit, ExportErrors.map(codec(ExportException.ERROR_CODE_ENCODER_INIT_FAILED), sizeLimit = true).code)
        assertEquals(EngineErrorCode.encoderSizeLimit, ExportErrors.map(codec(ExportException.ERROR_CODE_ENCODING_FORMAT_UNSUPPORTED), sizeLimit = true).code)
        // sizeLimit only changes encoder refusals.
        assertEquals(EngineErrorCode.decodeFailed, ExportErrors.map(codec(ExportException.ERROR_CODE_DECODING_FAILED), sizeLimit = true).code)
    }

    @Test
    fun noSpaceAnywhereInTheCauseChainIsDiskFull() {
        val enospc = IOException("write failed: ENOSPC (No space left on device)")
        assertEquals(EngineErrorCode.diskFull, ExportErrors.map(loader(ExportException.ERROR_CODE_MUXING_FAILED, RuntimeException(enospc))).code)
        assertEquals(EngineErrorCode.diskFull, ExportErrors.map(codec(ExportException.ERROR_CODE_ENCODING_FAILED, cause = enospc)).code)
        assertEquals(EngineErrorCode.diskFull, ExportErrors.map(loader(ExportException.ERROR_CODE_IO_UNSPECIFIED, IOException("No space left on device"))).code)
    }

    @Test
    fun nestedIoErrorsKeepTheirMeaning() {
        assertEquals(EngineErrorCode.mediaOffline, ExportErrors.map(loader(ExportException.ERROR_CODE_IO_UNSPECIFIED, FileNotFoundException("gone"))).code)
        assertEquals(EngineErrorCode.io, ExportErrors.map(loader(ExportException.ERROR_CODE_MUXING_FAILED, IOException("broken pipe"))).code)
    }

    @Test
    fun messagesNeverCarryPaths() {
        val e = ExportErrors.map(loader(ExportException.ERROR_CODE_IO_FILE_NOT_FOUND, FileNotFoundException("/data/user/0/app/cache/x.mp4")))
        assertFalse(e.message!!.contains("/data"))
    }

    @Test
    fun otherThrowablesGoThroughEngineErrors() {
        val engine = EngineException(EngineErrorCode.cancelled, "cancelled")
        assertSame(engine, ExportErrors.map(engine))
        assertEquals(EngineErrorCode.permissionDenied, ExportErrors.map(SecurityException("no")).code)
        assertEquals(EngineErrorCode.internal, ExportErrors.map(IllegalStateException("x")).code)
    }

    @Test
    fun portraitRetryOnlyForAFirstRefusedPortraitConfiguration() {
        val portrait = Settings.of(1080, 1920)
        val landscape = Settings.of(1920, 1080)
        val refused = codec(ExportException.ERROR_CODE_ENCODER_INIT_FAILED)
        val unsupported = codec(ExportException.ERROR_CODE_ENCODING_FORMAT_UNSUPPORTED)
        assertTrue(ExportErrors.shouldRetryLandscape(refused, portrait, 0))
        assertTrue(ExportErrors.shouldRetryLandscape(unsupported, portrait, 0))
        assertFalse("only once", ExportErrors.shouldRetryLandscape(refused, portrait, 1))
        assertFalse("landscape output", ExportErrors.shouldRetryLandscape(refused, landscape, 0))
        assertFalse("audio encoder", ExportErrors.shouldRetryLandscape(codec(ExportException.ERROR_CODE_ENCODER_INIT_FAILED, video = false), portrait, 0))
        assertFalse("decoder failure", ExportErrors.shouldRetryLandscape(codec(ExportException.ERROR_CODE_DECODER_INIT_FAILED), portrait, 0))
    }
}
