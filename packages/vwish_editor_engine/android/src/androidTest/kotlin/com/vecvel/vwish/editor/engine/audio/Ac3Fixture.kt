// OWNER: AND-04
//
// A 0.5 s mono 440 Hz AC-3 track in Matroska (4,773 bytes), embedded so the instrumented tests can
// check the "no decoder for this codec -> unsupportedMedia" path: the Android emulator (and most
// phones) have no AC-3 decoder. Generated locally on the Windows lane (ffmpeg 7.1.1, 2026-10-11),
// nothing downloaded:
//   ffmpeg -f lavfi -i "sine=frequency=440:duration=0.5:sample_rate=48000" -c:a ac3 -b:a 64k -f matroska ac3_tone.mka
//   base64 -w 0 ac3_tone.mka

package com.vecvel.vwish.editor.engine.audio

import android.util.Base64
import java.io.File

/** The embedded AC-3/Matroska file. */
object Ac3Fixture {
    private val BASE64 = listOf(
        "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",
        "ahLEHruPs4EAt4r3gQHxggHQ8IEJ",
    ).joinToString("")

    /** Writes the file into [dir] and returns it. */
    fun write(dir: File): File {
        dir.mkdirs()
        return File(dir, "ac3_tone.mka").apply { writeBytes(Base64.decode(BASE64, Base64.DEFAULT)) }
    }
}
