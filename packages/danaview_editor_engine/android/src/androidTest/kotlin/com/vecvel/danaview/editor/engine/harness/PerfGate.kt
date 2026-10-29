// OWNER: ENG-09
//
// DV_PERF_STRICT for instrumented tests (CI rounds 5 and 6, the Dart and iOS suites' rule): every
// absolute timing, frame-count, throughput or GPU-speed limit applies only with DV_PERF_STRICT=1
// (a quiet dev machine or a real device), passed by android_emulator.sh as the instrumentation
// argument DV_PERF_STRICT. Without it (a loaded CI emulator with a software GPU and encoder) the
// limits become a generous floor ([bound], [boundMs]) or a non-vacuity minimum ([atLeast]).
// Correctness checks never go through PerfGate: a wrong frame, a wrong colour or a crash fails in
// both modes, and no test is skipped. Lives in harness/ (androidTest only): support/ is also
// compiled into the unit tests, which have no InstrumentationRegistry.

package com.vecvel.danaview.editor.engine.harness

import androidx.test.platform.app.InstrumentationRegistry

object PerfGate {
    /** Whether absolute performance limits apply (instrumentation argument DV_PERF_STRICT=1). */
    val strict: Boolean by lazy { InstrumentationRegistry.getArguments().getString("DV_PERF_STRICT") == "1" }

    /** How much slower than the device limit a loaded emulator may be without DV_PERF_STRICT. */
    const val LOOSE_FACTOR = 4

    /** An upper time or speed limit: [limit] with DV_PERF_STRICT=1, else [LOOSE_FACTOR] times it. */
    fun bound(limit: Double): Double = if (strict) limit else limit * LOOSE_FACTOR

    /** [bound] for milliseconds (limits, waits and timeouts). */
    fun boundMs(limit: Long): Long = if (strict) limit else limit * LOOSE_FACTOR

    /**
     * A minimum count of presented frames, samples or updates: [strictMin] with DV_PERF_STRICT=1,
     * else [looseMin] (enough that the correctness checks on them are not vacuous).
     */
    fun atLeast(strictMin: Int, looseMin: Int): Int = if (strict) strictMin else looseMin

    /** "strict" or "loose", for log lines and assertion messages. */
    val mode: String get() = if (strict) "DV_PERF_STRICT=1" else "loose (no DV_PERF_STRICT)"
}
