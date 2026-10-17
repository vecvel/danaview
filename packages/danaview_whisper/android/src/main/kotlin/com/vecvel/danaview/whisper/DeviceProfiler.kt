// OWNER: AI-06
//
// Android device queries for the `danaview_whisper/device` channel (ai.md §4.8): RAM, available
// memory, core clusters, CPU features, free disk, metered network. Heavy reads (cpufreq, cpuinfo)
// are cached; nothing here logs paths.

package com.vecvel.danaview.whisper

import android.app.ActivityManager
import android.content.Context
import android.net.ConnectivityManager
import android.os.Build
import android.os.PowerManager
import android.os.Process
import android.os.StatFs
import java.io.File

class DeviceProfiler(private val context: Context) {
    private val activityManager get() = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
    private val powerManager get() = context.getSystemService(Context.POWER_SERVICE) as PowerManager

    @Volatile private var staticFacts: Map<String, Any>? = null

    /** The `deviceProfile` map: static facts cached, power and thermal state read fresh. */
    fun profile(): Map<String, Any> {
        val facts = staticFacts ?: readStaticFacts().also { staticFacts = it }
        val out = HashMap(facts)
        out["lowPowerMode"] = powerManager.isPowerSaveMode
        out["thermal"] = currentThermal()
        return out
    }

    private fun readStaticFacts(): Map<String, Any> {
        val mem = ActivityManager.MemoryInfo().also { activityManager.getMemoryInfo(it) }
        val freqs = readMaxFrequencies()
        val total = Runtime.getRuntime().availableProcessors()
        val perf = CpuInfo.perfCoreCount(freqs)
        return mapOf(
            "os" to "android",
            "osVersion" to Build.VERSION.RELEASE,
            "apiLevel" to Build.VERSION.SDK_INT,
            "model" to "${Build.MANUFACTURER} ${Build.MODEL}".trim(),
            "physicalRam" to mem.totalMem,
            "isLowRam" to activityManager.isLowRamDevice,
            "perfCores" to perf,
            "efficiencyCores" to (if (perf in 1 until total) total - perf else 0),
            "totalCores" to total,
            "is64Bit" to Process.is64Bit(),
            "cpuFeatures" to readCpuFeatures(),
            "gpuFamily" to 0,
            "isSimulator" to isEmulator(),
        )
    }

    /** Bytes the app can still allocate before the system starts killing (see [MemoryMath.headroom]). */
    fun availableMemory(): Long {
        val mem = ActivityManager.MemoryInfo().also { activityManager.getMemoryInfo(it) }
        return MemoryMath.headroom(mem.availMem, mem.threshold, mem.lowMemory)
    }

    /** Free bytes on the volume of [path] (the nearest existing parent when it does not exist yet). */
    fun freeDiskBytes(path: String): Long {
        var f: File? = File(path)
        while (f != null && !f.exists()) f = f.parentFile
        val target = f ?: context.filesDir
        return StatFs(target.absolutePath).availableBytes
    }

    fun isNetworkMetered(): Boolean = try {
        (context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager).isActiveNetworkMetered
    } catch (_: SecurityException) {
        false
    }

    fun currentThermal(): String =
        if (Build.VERSION.SDK_INT >= 29) ThermalMapper.map(powerManager.currentThermalStatus) ?: "nominal" else "nominal"

    private fun readMaxFrequencies(): List<Long> = try {
        File("/sys/devices/system/cpu").listFiles { f -> f.isDirectory && f.name.matches(Regex("cpu\\d+")) }
            .orEmpty()
            .mapNotNull { dir ->
                try {
                    File(dir, "cpufreq/cpuinfo_max_freq").readText().trim().toLongOrNull()
                } catch (_: Exception) {
                    null
                }
            }
    } catch (_: Exception) {
        emptyList()
    }

    private fun readCpuFeatures(): List<String> = try {
        CpuInfo.featuresFromCpuInfo(File("/proc/cpuinfo").readText())
    } catch (_: Exception) {
        emptyList()
    }

    private fun isEmulator(): Boolean =
        Build.FINGERPRINT.startsWith("generic") || Build.FINGERPRINT.contains("emulator") || Build.HARDWARE.contains("ranchu") ||
            Build.HARDWARE.contains("goldfish")
}
