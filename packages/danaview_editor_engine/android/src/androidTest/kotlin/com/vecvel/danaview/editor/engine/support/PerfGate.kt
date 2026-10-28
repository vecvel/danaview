// OWNER: ENG-09
//
// DV_PERF_STRICT for instrumented tests (CI round 5, the Dart and iOS suites' rule): absolute
// throughput and timing limits apply only with DV_PERF_STRICT=1 (a quiet dev machine or a real
// device), passed by android_emulator.sh as the instrumentation argument DV_PERF_STRICT. On a
// loaded CI emulator the correctness checks stay on and the throughput limits only require the
// check to be non-vacuous.

package com.vecvel.danaview.editor.engine.support

import androidx.test.platform.app.InstrumentationRegistry

object PerfGate {
    /** Whether absolute performance limits apply (instrumentation argument DV_PERF_STRICT=1). */
    val strict: Boolean by lazy { InstrumentationRegistry.getArguments().getString("DV_PERF_STRICT") == "1" }
}
