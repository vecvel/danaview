// OWNER: AND-15
//
// INT-07 review D4: names of copied drops and picks are capped in UTF-8 bytes (ext4 and f2fs allow
// 255 bytes per name), not only in characters, keep a short extension, and are never cut inside a
// surrogate pair or a multi-byte sequence. A 100-character CJK or emoji name used to exceed the
// limit and fail the copy as mediaOffline.

package com.vecvel.danaview.editor.engine.platform

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SanitizedNameBytesTest {
    private fun utf8(s: String): Int = s.toByteArray(Charsets.UTF_8).size

    /** Fits both caps and survives a UTF-8 round trip (no unpaired surrogate turned into `?`). */
    private fun assertValidName(name: String) {
        assertTrue("bytes ${utf8(name)}", utf8(name) <= DropTarget.MAX_NAME_BYTES)
        assertTrue("chars ${name.length}", name.length <= DropTarget.MAX_NAME_CHARS)
        assertEquals(name, String(name.toByteArray(Charsets.UTF_8), Charsets.UTF_8))
        for (i in name.indices) {
            val c = name[i]
            if (c.isHighSurrogate()) assertTrue("pair at $i", i + 1 < name.length && name[i + 1].isLowSurrogate())
            if (c.isLowSurrogate()) assertTrue("pair at $i", i > 0 && name[i - 1].isHighSurrogate())
        }
    }

    @Test
    fun shortNamesAreKept() {
        assertEquals("clip.mp4", DropTarget.sanitize("clip.mp4"))
        assertEquals("旅行の動画.mp4", DropTarget.sanitize("旅行の動画.mp4"))
        assertEquals("a_b_c.mp4", DropTarget.sanitize("a/b:c.mp4"))
        assertEquals("hidden", DropTarget.sanitize(".hidden"))
        assertEquals("drop", DropTarget.sanitize("..."))
    }

    @Test
    fun longAsciiNamesKeepTheCharacterCapAndTheExtension() {
        val name = DropTarget.sanitize("x".repeat(300) + ".mp4")
        assertEquals(DropTarget.MAX_NAME_CHARS, name.length)
        assertTrue(name.endsWith(".mp4"))
        assertValidName(name)
    }

    @Test
    fun longCjkNamesAreCappedInBytes() {
        val raw = "日".repeat(100) + ".mp4" // 304 bytes, 104 characters
        assertTrue(utf8(raw) > 255)
        val name = DropTarget.sanitize(raw)
        assertValidName(name)
        assertTrue(name.endsWith(".mp4"))
        // 3 bytes per character: (200 − 4) / 3 = 65 whole characters, nothing cut in between.
        assertEquals("日".repeat(65) + ".mp4", name)
    }

    @Test
    fun longEmojiNamesAreCutBetweenSurrogatePairs() {
        val name = DropTarget.sanitize("😀".repeat(100) + ".mov") // 404 bytes
        assertValidName(name)
        assertEquals("😀".repeat(49) + ".mov", name) // (200 − 4) / 4 = 49
        // Mixed widths: the cut lands before the first code point that would not fit.
        val mixed = DropTarget.sanitize("a" + "😀".repeat(60) + "é".repeat(10) + ".png")
        assertValidName(mixed)
        assertTrue(mixed.endsWith(".png"))
        assertTrue(utf8(mixed) > DropTarget.MAX_NAME_BYTES - 4)
    }

    @Test
    fun longExtensionsAreNotKeptButStillFit() {
        val asciiExt = DropTarget.sanitize("日".repeat(100) + "." + "x".repeat(30))
        assertValidName(asciiExt)
        assertTrue(asciiExt.startsWith("日"))
        val emojiExt = DropTarget.sanitize("😀".repeat(50) + "." + "😀".repeat(20))
        assertValidName(emojiExt)
        val cjkExt = DropTarget.sanitize("映".repeat(90) + ".動画ファイル") // 6-character extension kept
        assertValidName(cjkExt)
        assertTrue(cjkExt.endsWith(".動画ファイル"))
    }

    @Test
    fun unpairedSurrogatesAreReplaced() {
        val name = DropTarget.sanitize("a\uD83Db\uDE00c.mp4")
        assertEquals("a_b_c.mp4", name)
        assertValidName(name)
        assertFalse(DropTarget.sanitize("\uD83D".repeat(300)).contains('\uD83D'))
    }

    @Test
    fun pickNamesUseTheSameByteCap() {
        val pick = PickMaterializer.sanitizedName("動".repeat(100) + ".mp4", "video/mp4")
        assertValidName(pick)
        assertTrue(pick.endsWith(".mp4"))
        // Without an extension, the MIME extension (when the platform maps it) still fits 255 bytes.
        val bare = PickMaterializer.sanitizedName("🎬".repeat(100), "video/mp4")
        assertTrue(utf8(bare) <= DropTarget.MAX_NAME_BYTES + 1 + 10)
        assertEquals(bare, String(bare.toByteArray(Charsets.UTF_8), Charsets.UTF_8))
    }
}
