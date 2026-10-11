// OWNER: ENG-08
//
// Error codes and their mapping (ARCH §12.5, §12.6, §19): the Kotlin enum equals the Dart
// EngineErrorCode, throwables map to the right codes, Pigeon errors carry the details map, and
// messages lose paths and URIs exactly like error_mapper.dart's scrubPaths.

package com.vecvel.vwish.editor.engine.glue

import com.vecvel.vwish.editor.engine.core.EngineErrorCode
import com.vecvel.vwish.editor.engine.core.EngineErrors
import com.vecvel.vwish.editor.engine.core.EngineException
import com.vecvel.vwish.editor.engine.harness.FixtureTree
import com.vecvel.vwish.editor.engine.harness.JvmFixtures
import com.vecvel.vwish.editor.engine.pigeon.EnginePigeonError
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.util.concurrent.CancellationException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ErrorCodesTest {
    @Test
    fun kotlinCodesEqualTheDartEnum() {
        val failures = File(JvmFixtures.root(FixtureTree.ENGINE_API).parentFile, "lib/src/failures.dart")
        assertTrue("failures.dart not found", failures.isFile)
        val dartNames = mutableListOf<String>()
        for (raw in failures.readText().substringAfter("enum EngineErrorCode {").lines()) {
            val line = raw.trim()
            if (line.isEmpty() || line.startsWith("//")) continue
            val name = line.trimEnd(',', ';')
            assertTrue("unexpected line in the enum: $line", name.matches(Regex("[a-zA-Z]+")))
            dartNames.add(name)
            if (line.endsWith(";") || line.endsWith("}")) break
        }
        assertEquals(dartNames, EngineErrorCode.entries.map { it.name })
    }

    @Test
    fun scrubRemovesPathsAndUrisLikeTheDartMapper() {
        assertEquals("cannot read <path>", EngineErrors.scrub("cannot read content://media/external/video/42"))
        assertEquals("open <path> failed", EngineErrors.scrub("open file:///data/user/0/app/files/a.mp4 failed"))
        assertEquals("weird: <path> x", EngineErrors.scrub("weird: /var/mobile/Containers/Data/a.mov x"))
        assertEquals("ratio 16/9 and v1.2/3", EngineErrors.scrub("ratio 16/9 and v1.2/3"))
        assertEquals("plain text", EngineErrors.scrub("plain text"))
    }

    @Test
    fun throwablesMapToEngineCodes() {
        fun codeOf(t: Throwable) = EngineErrors.from(t).code
        assertEquals(EngineErrorCode.planOutOfSync, codeOf(EngineException(EngineErrorCode.planOutOfSync, "x")))
        assertEquals(EngineErrorCode.encoderUnavailable, codeOf(EnginePigeonError("encoderUnavailable", "m")))
        assertEquals(EngineErrorCode.internal, codeOf(EnginePigeonError("someUnknownCode", "m")))
        assertEquals(EngineErrorCode.cancelled, codeOf(CancellationException()))
        assertEquals(EngineErrorCode.permissionDenied, codeOf(SecurityException("no")))
        assertEquals(EngineErrorCode.mediaOffline, codeOf(FileNotFoundException("/sdcard/a.mp4")))
        assertEquals(EngineErrorCode.diskFull, codeOf(IOException("write failed: ENOSPC (No space left on device)")))
        assertEquals(EngineErrorCode.io, codeOf(IOException("broken pipe")))
        assertEquals(EngineErrorCode.interrupted, codeOf(InterruptedException()))
        assertEquals(EngineErrorCode.internal, codeOf(IllegalStateException("/data/secret/path")))
    }

    @Test
    fun unexpectedExceptionsNeverLeakTheirMessage() {
        val e = EngineErrors.from(IllegalStateException("failed at /data/user/0/app/files/x.mp4"))
        assertEquals("unexpected IllegalStateException", e.message)
        val io = EngineErrors.from(IOException("cannot open /data/user/0/app/files/x.mp4"))
        assertFalse(io.message!!.contains("/data"))
    }

    @Test
    fun pigeonErrorsCarryCodeScrubbedMessageAndDetails() {
        val error = EngineErrors.toPigeon(
            EngineException(EngineErrorCode.mediaOffline, "missing file:///x/y.mp4", itemId = "item-1", mediaFingerprint = "fp", retryable = true),
        )
        assertEquals("mediaOffline", error.code)
        assertEquals("missing <path>", error.message)
        val details = error.details as Map<*, *>
        assertEquals("item-1", details["itemId"])
        assertEquals("fp", details["mediaFingerprint"])
        assertEquals(true, details["retryable"])

        val plain = EngineErrors.toPigeon(RuntimeException("boom"))
        assertEquals("internal", plain.code)
        val plainDetails = plain.details as Map<*, *>
        assertNull(plainDetails["itemId"])
        assertEquals(false, plainDetails["retryable"])
    }

    @Test
    fun failureMessagesForEvents() {
        val msg = EngineErrors.toFailureMsg(EngineException(EngineErrorCode.decodeFailed, "bad frame in content://a/b", itemId = "i"))
        assertEquals("decodeFailed", msg.code)
        assertEquals("bad frame in <path>", msg.message)
        assertEquals("i", msg.itemId)
        assertFalse(msg.retryable)
    }

    @Test
    fun placeholderAndArgumentErrors() {
        assertEquals(EngineErrorCode.notSupportedOnDevice, EngineErrors.notSupported("probe").code)
        assertEquals(EngineErrorCode.internal, EngineErrors.invalidArgument("x", "y").code)
        assertEquals(EngineErrorCode.planInvalid, EngineErrors.invalidPlan("empty").code)
        assertEquals(EngineErrorCode.internal, EngineErrors.notInitialized().code)
    }
}
