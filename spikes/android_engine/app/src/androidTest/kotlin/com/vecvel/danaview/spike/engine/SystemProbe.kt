package com.vecvel.danaview.spike.engine

import android.os.ParcelFileDescriptor
import android.os.Process
import androidx.test.platform.app.InstrumentationRegistry
import java.io.FileInputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONObject

/**
 * Process-level resource sampling for V-N25 through the instrumentation's shell: codec instances
 * from `dumpsys media.resource_manager` (event log, union of samples) and memory from
 * `dumpsys meminfo <pid>` (TOTAL PSS, Graphics, GL mtrack).
 */
class SystemProbe(private val periodMs: Long = 400) : AutoCloseable {
    private val pid = Process.myPid()
    private val events = ConcurrentHashMap.newKeySet<String>()
    private val running = AtomicBoolean(true)
    @Volatile var peakPssKb = 0L
    @Volatile var peakGraphicsKb = 0L
    @Volatile var peakGlMtrackKb = 0L
    private val baselineEvents: Set<String> = sampleEvents().toSet()
    private val thread = Thread {
        while (running.get()) {
            sampleOnce()
            Thread.sleep(periodMs)
        }
    }.apply { start() }

    private fun sampleOnce() {
        events += sampleEvents()
        val mem = shell("dumpsys meminfo $pid")
        fun kb(label: String): Long? = Regex("""(?m)^\s*$label:?\s+(\d+)""").find(mem)?.groupValues?.get(1)?.toLongOrNull()
        kb("TOTAL PSS")?.let { if (it > peakPssKb) peakPssKb = it }
        kb("Graphics")?.let { if (it > peakGraphicsKb) peakGraphicsKb = it }
        kb("GL mtrack")?.let { if (it > peakGlMtrackKb) peakGlMtrackKb = it }
    }

    private fun sampleEvents(): List<String> =
        shell("dumpsys media.resource_manager").lines().map { it.trim() }
            .filter { it.contains("pid $pid") && EVENT.containsMatchIn(it) }

    /** Video decoder/encoder client ids added since construction, and the peak number alive at once. */
    fun codecStats(): JSONObject {
        sampleOnce()
        val fresh = events.filter { it !in baselineEvents }.sorted() // "MM-DD HH:MM:SS ..." sorts chronologically
        val video = HashSet<String>()
        val audio = HashSet<String>()
        val alive = HashSet<String>()
        var peak = 0
        val idRe = Regex("""clientId (-?\d+)""")
        for (e in fresh) {
            val id = idRe.find(e)?.groupValues?.get(1) ?: continue
            when {
                e.contains("addResource") && e.contains("video-codec") -> {
                    video += id
                    alive += id
                    peak = maxOf(peak, alive.size)
                }
                e.contains("addResource") && e.contains("audio-codec") -> audio += id
                e.contains("removeResource") -> alive -= id
            }
        }
        return JSONObject().put("videoCodecInstances", video.size).put("peakVideoCodecsAlive", peak)
            .put("audioCodecInstances", audio.size).put("events", fresh.size)
    }

    fun memory(): JSONObject = JSONObject().put("peakTotalPssKb", peakPssKb).put("peakGraphicsKb", peakGraphicsKb).put("peakGlMtrackKb", peakGlMtrackKb)

    override fun close() {
        running.set(false)
        thread.join(2000)
    }

    companion object {
        private val EVENT = Regex("""^\d\d-\d\d \d\d:\d\d:\d\d """)

        fun shell(cmd: String): String {
            val pfd: ParcelFileDescriptor = InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(cmd)
            return FileInputStream(pfd.fileDescriptor).use { it.readBytes().decodeToString() }.also { pfd.close() }
        }
    }
}
