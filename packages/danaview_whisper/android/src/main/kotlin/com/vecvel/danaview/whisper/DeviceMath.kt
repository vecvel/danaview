// OWNER: AI-06
//
// Pure helpers of the device plugin (ai.md §4.8, §6): thermal mapping, memory-trim classification,
// CPU feature and cluster parsing, free-memory headroom. No android.* imports, so they run as
// plain JVM unit tests (android/src/test/kotlin/.../DeviceMathTest.kt). The Android constants are
// copied as literals (documented per use) for the same reason.

package com.vecvel.danaview.whisper

/** Maps `PowerManager.THERMAL_STATUS_*` to the four names the Dart side knows. */
object ThermalMapper {
    // PowerManager.THERMAL_STATUS_NONE .. SHUTDOWN
    const val STATUS_NONE = 0
    const val STATUS_LIGHT = 1
    const val STATUS_MODERATE = 2
    const val STATUS_SEVERE = 3
    const val STATUS_CRITICAL = 4
    const val STATUS_EMERGENCY = 5
    const val STATUS_SHUTDOWN = 6

    /**
     * NONE and LIGHT are `nominal`, MODERATE `fair`, SEVERE `serious`, CRITICAL and anything worse
     * (EMERGENCY, SHUTDOWN, unknown future values) `critical`. A negative status means "no signal"
     * (`PowerManager.THERMAL_STATUS_UNKNOWN`-style sentinels) and maps to null: no event.
     */
    fun map(status: Int): String? = when {
        status < 0 -> null
        status <= STATUS_LIGHT -> "nominal"
        status == STATUS_MODERATE -> "fair"
        status == STATUS_SEVERE -> "serious"
        else -> "critical"
    }
}

/** Classifies `ComponentCallbacks2.onTrimMemory` levels. */
object TrimLevels {
    const val RUNNING_MODERATE = 5
    const val RUNNING_LOW = 10
    const val RUNNING_CRITICAL = 15
    const val UI_HIDDEN = 20
    const val BACKGROUND = 40
    const val MODERATE = 60
    const val COMPLETE = 80

    /**
     * True when the system is short of memory while we run (RUNNING_LOW, RUNNING_CRITICAL) or
     * when the process sits in the LRU list about to be killed (BACKGROUND and above). UI_HIDDEN
     * (20) only reports that the UI went to the background and is NOT a memory warning, and
     * RUNNING_MODERATE (5) is too mild to act on.
     */
    fun isMemoryWarning(level: Int): Boolean =
        level == RUNNING_LOW || level == RUNNING_CRITICAL || level >= BACKGROUND
}

/** Free-memory headroom as the Dart side expects it: positive bytes, or 1 when there is none. */
object MemoryMath {
    /**
     * `availMem - threshold`, or 1 byte when the device reports `lowMemory` or the difference is
     * not positive. The Dart side treats 0 as "unknown, assume OK", so "no headroom" must stay
     * positive and tiny to fail the 1.3 x peak-budget preflight.
     */
    fun headroom(availMem: Long, threshold: Long, lowMemory: Boolean): Long {
        if (lowMemory) return 1L
        val d = availMem - threshold
        return if (d > 0) d else 1L
    }
}

/** CPU topology and feature parsing for `deviceProfile`. */
object CpuInfo {
    /**
     * Performance ("big") core count from per-core max frequencies (kHz): cores within 80 % of
     * the fastest core. 1+3+4 designs report prime and gold cores, 4+4 designs the big four,
     * homogeneous chips all cores (the thread policy clamps to 2..4 anyway). 0 = unknown.
     */
    fun perfCoreCount(maxFreqKhz: List<Long>): Int {
        val freqs = maxFreqKhz.filter { it > 0 }
        if (freqs.isEmpty()) return 0
        val max = freqs.max()
        return freqs.count { it * 10 >= max * 8 }
    }

    /**
     * Features present on EVERY core listed in `/proc/cpuinfo` (a kernel may print one
     * `Features` line per processor; the shim variant must run on all of them), as the names the
     * Dart `CpuFeature` enum knows: `dotprod` (`asimddp`), `fp16` (`asimdhp`, the vector half
     * precision flag; `fphp` alone is scalar only), `i8mm`, `bf16`.
     */
    fun featuresFromCpuInfo(text: String): List<String> {
        val perCore = text.lineSequence()
            .map { it.trim() }
            .filter { it.startsWith("Features") }
            .map { line -> line.substringAfter(':', "").trim().split(Regex("\\s+")).toSet() }
            .toList()
        if (perCore.isEmpty()) return emptyList()
        val common = perCore.reduce { a, b -> a intersect b }
        val out = ArrayList<String>(4)
        if ("asimddp" in common) out += "dotprod"
        if ("asimdhp" in common) out += "fp16"
        if ("i8mm" in common) out += "i8mm"
        if ("bf16" in common) out += "bf16"
        return out
    }
}

/** Builders for the event maps (`{type, value}`) the Dart `WhisperDeviceEvent.tryParse` reads. */
object DeviceEvents {
    fun thermal(status: Int): Map<String, Any>? = ThermalMapper.map(status)?.let { mapOf("type" to "thermal", "value" to it) }
    fun memoryWarning(): Map<String, Any> = mapOf("type" to "memoryWarning")
    fun lowPower(enabled: Boolean): Map<String, Any> = mapOf("type" to "lowPower", "value" to enabled)
    fun lifecycle(background: Boolean): Map<String, Any> =
        mapOf("type" to "lifecycle", "value" to if (background) "background" else "foreground")
}
