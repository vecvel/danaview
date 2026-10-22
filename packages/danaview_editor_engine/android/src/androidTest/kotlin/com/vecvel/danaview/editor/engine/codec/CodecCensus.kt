// OWNER: QA-05 D9
//
// What the process holds in codecs, for the D9 regression tests: the codec clients the platform's
// ResourceManagerService lists for this pid (`dumpsys media.resource_manager`, run as the shell
// through UiAutomation), the codec clients it marked "pending removal" (released, release not
// finished) and the threads by name (/proc/self/task/*/comm: Media3 playback and Transformer
// threads, MediaCodec and CCodec loopers, the app's HwBinder threads).

package com.vecvel.danaview.editor.engine.codec

import android.os.ParcelFileDescriptor
import android.os.Process
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File

data class CodecCensus(
    /** Codec clients of this pid (one per live MediaCodec). */
    val clients: List<String>,
    /** Threads by comm name (names the kernel truncated to 15 chars). */
    val threads: Map<String, Int>,
) {
    fun threads(prefix: String): Int = threads.filterKeys { it.startsWith(prefix) }.values.sum()

    /** ExoPlayer playback threads (preview decks, Transformer asset loaders, FrameExtractor). */
    val playbackThreads: Int get() = threads("ExoPlayer:Playb")

    /** MediaCodec's own loopers ("MediaCodec_looper", truncated). */
    val codecLoopers: Int get() = threads("MediaCodec_loop")

    val transformerThreads: Int get() = threads("Transformer:Int")

    override fun toString(): String =
        "codecs=${clients.size} $clients playback=$playbackThreads codecLoopers=$codecLoopers transformer=$transformerThreads " +
            "CodecLooper=${threads("CodecLooper")} HwBinder=${threads("HwBinder")}"

    companion object {
        fun take(): CodecCensus = CodecCensus(clientsOf(Process.myPid()), threadNames())

        /** Polls until [ok] holds or [timeoutMs] passes; returns the last census. */
        fun settle(timeoutMs: Long, ok: (CodecCensus) -> Boolean): CodecCensus {
            val deadline = System.currentTimeMillis() + timeoutMs
            var c = take()
            while (!ok(c) && System.currentTimeMillis() < deadline) {
                Thread.sleep(250)
                c = take()
            }
            return c
        }

        fun threadNames(): Map<String, Int> {
            val names = HashMap<String, Int>()
            File("/proc/self/task").listFiles()?.forEach { t ->
                val name = runCatching { File(t, "comm").readText().trim() }.getOrNull() ?: return@forEach
                names[name] = (names[name] ?: 0) + 1
            }
            return names
        }

        fun shell(command: String): String {
            val pfd = InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(command)
            return ParcelFileDescriptor.AutoCloseInputStream(pfd).use { it.readBytes().toString(Charsets.UTF_8) }
        }

        /** The codec names ResourceManagerService lists under "Pid: [pid]" (its Processes section). */
        fun clientsOf(pid: Int): List<String> {
            val dump = shell("dumpsys media.resource_manager")
            val lines = dump.lines()
            val out = ArrayList<String>()
            var inPid = false
            var section = false
            for (raw in lines) {
                val line = raw.trim()
                if (line == "Processes:") {
                    section = true
                    continue
                }
                if (!section) continue
                if (line.startsWith("Process Pid override") || line.startsWith("Events logs")) break
                if (line.startsWith("Pid: ")) {
                    inPid = line.removePrefix("Pid: ").trim() == pid.toString()
                    continue
                }
                if (inPid && line.startsWith("Name: ")) out += line.removePrefix("Name: ").trim()
            }
            return out
        }
    }
}
