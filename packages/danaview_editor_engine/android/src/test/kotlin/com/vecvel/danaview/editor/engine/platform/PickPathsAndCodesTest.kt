// OWNER: INT-07
//
// M-20: `file://` pick URIs are percent-decoded like Dart's `Uri.toFilePath(windows: false)`
// (mobile_media_access.dart `_filePathOf`), plain paths are never decoded, and the URIs Dart's
// toFilePath refuses are refused. M-18: the shared error mapping tells an unreadable file
// (EACCES / EPERM) and a full disk apart from a missing one.

package com.vecvel.danaview.editor.engine.platform

import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineErrors
import com.vecvel.danaview.editor.engine.core.Paths
import java.io.FileNotFoundException
import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PickPathsAndCodesTest {
    private fun decoded(uri: String): String? = Paths.normalizeFileUriOrPath(uri)?.invariantSeparatorsPath

    @Test
    fun fileUrisAreDecodedLikeDart() {
        assertEquals("/storage/emulated/0/Movies/My Clip.mp4", decoded("file:///storage/emulated/0/Movies/My%20Clip.mp4"))
        assertEquals("/a/100% real.mp4", decoded("file:///a/100%25%20real.mp4"))
        assertEquals("/a/café 日本.mov", decoded("file:///a/caf%C3%A9%20%E6%97%A5%E6%9C%AC.mov"))
        assertEquals("/a/café.mov", decoded("file:///a/café.mov")) // unescaped non-ASCII as is
        assertEquals("/a/b+c.mp4", decoded("file:///a/b+c.mp4")) // `+` is not a space in a path
        assertEquals("/a/%zz.mp4", decoded("file:///a/%zz.mp4")) // not an escape: a literal %, as Dart
        assertEquals("/a/x%2.mp4", decoded("file:///a/x%2.mp4"))
        assertEquals("/a/b.mp4", decoded("file:/a/b.mp4"))
        assertEquals("/a/b.mp4", decoded("file:///a//./b.mp4"))
    }

    @Test
    fun plainPathsAreNeverDecoded() {
        assertEquals("/a/My%20Clip.mp4", decoded("/a/My%20Clip.mp4"))
        assertEquals("/a/100%25.mp4", decoded("/a/100%25.mp4"))
        // Decoding happens once: an escaped `%` stays a `%` followed by the rest.
        assertEquals("/a/My%20Clip.mp4", decoded("file:///a/My%2520Clip.mp4"))
    }

    @Test
    fun urisDartCannotTurnIntoAPathAreRefused() {
        assertNull(decoded("file://host/a/b.mp4")) // an authority
        assertNull(decoded("file://localhost/a/b.mp4"))
        assertNull(decoded("file:///a/b.mp4?x=1")) // a query
        assertNull(decoded("file:///a/b.mp4#t")) // a fragment
        assertNull(decoded("file:///a/b%2Fc.mp4")) // an escaped separator
        assertNull(decoded("file:///a/b%00.mp4")) // NUL
        assertNull(decoded("file:///a/b%FF.mp4")) // not UTF-8
        assertNull(decoded("file:///a/../b.mp4")) // `..` stays refused (Paths.normalize)
        assertNull(decoded("file:relative/b.mp4"))
    }

    @Test
    fun fileNotFoundIsOnlyMediaOfflineWhenTheFileIsGone() {
        fun code(e: Throwable) = EngineErrors.from(e).code
        assertEquals(EngineErrorCode.mediaOffline, code(FileNotFoundException("/s/a.mp4: open failed: ENOENT (No such file or directory)")))
        assertEquals(EngineErrorCode.mediaOffline, code(FileNotFoundException("gone")))
        assertEquals(EngineErrorCode.permissionDenied, code(FileNotFoundException("/s/a.mp4: open failed: EACCES (Permission denied)")))
        assertEquals(EngineErrorCode.permissionDenied, code(FileNotFoundException("/s/a.mp4 (Permission denied)")))
        assertEquals(EngineErrorCode.permissionDenied, code(FileNotFoundException("/s/a.mp4: open failed: EPERM (Operation not permitted)")))
        assertEquals(EngineErrorCode.diskFull, code(FileNotFoundException("/w/a.mp4: open failed: ENOSPC (No space left on device)")))
        assertEquals(EngineErrorCode.diskFull, code(IOException("write failed: EDQUOT (Disk quota exceeded)")))
        assertEquals(EngineErrorCode.io, code(IOException("write failed: EIO (I/O error)")))
    }
}
