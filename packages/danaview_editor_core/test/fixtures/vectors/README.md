<!-- OWNER: FIX-IOS-RANGE-VECTORS -->
# Shared vectors

Cross-language vectors. Dart writes them, and the native engines replay them. The files in this
folder reach the iOS RunnerTests through the `core` fixture tree (`TestFixtures.url(.core, "vectors/...")`).
They reach the Android JVM tests through `JvmFixtures.file(FixtureTree.CORE, "vectors/...")`.

| File | Written by | Replayed by |
|---|---|---|
| `frame_grid.json` | core frame-grid tests | iOS / Android frame-grid tests |
| `packing.json` | core packing tests | iOS / Android packing tests |
| `range_touch.json` | `test/plan/render_cache/range_rule_test.dart` (FIX-RANGE-RULE) | iOS `RangeTouchVectorTests.swift` (FIX-IOS-RANGE-VECTORS); Android `RangeTouchVectorTest.kt` (FIX-AND-18-1, Windows lane, still to write; see below) |

## `range_touch.json`

This file holds the rendered-range drop rule (ARCH §12.2 'Rendered ranges', D-45). The native
engines see only plans, so they drop a rendered range when the difference between two plans
touches it.

Regenerate the file with
`UPDATE_RANGE_VECTORS=1 dart test test/plan/render_cache/range_rule_test.dart`, run in
`packages/danaview_editor_core`. After a regeneration, run both native replays again.

Shape:

```
{ "v": 1, "about": "...",
  "cases": [ { "name": "...",
               "before": <RenderPlan v1>, "after": <RenderPlan v1>,
               "ranges": [ { "s": µs, "e": µs, "touched": bool, "sameHash": bool }, ... ] } ] }
```

- `touched` is the engine verdict for `[s, e)` of `before`. `true` means the range is dropped.
  Each native replay must reproduce it exactly.
- `sameHash` is the Dart `rangeHash` comparison at that span. `touched == false` implies
  `sameHash == true`, so a kept range is never stale.
- The `commands seed …` cases compile both plans at revision 0. Bump `after.rev` before you feed
  a pair to a swap that only reconciles another revision.

### iOS (done)

`packages/danaview_editor_engine/example/ios/RunnerTests/RenderPreview/RangeTouchVectorTests.swift`
asserts these points:

- `RenderedRangeRules.changeTouches(before:after:range:) == touched` for each range of each case.
- A `RenderedRangeSwap` bound to `before` keeps exactly the untouched ranges in
  `validRanges(for: after)`.

### Android (deferred to the Windows lane: FIX-AND-18-1)

The file is ready to write as
`packages/danaview_editor_engine/android/src/test/kotlin/com/vecvel/danaview/editor/engine/render/RangeTouchVectorTest.kt`.
It is a JVM unit test with header `// OWNER: AND-18`. A new file keeps `RangeTouchTest.kt`
unchanged. The tests can also go into that file. Write it like this:

```kotlin
// OWNER: AND-18
//
// FIX-AND-18-1: RangeTouch.changeTouches replays the shared vectors
// danaview_editor_core/test/fixtures/vectors/range_touch.json (Dart rangeTouched; iOS replays the
// same file in RangeTouchVectorTests.swift).

package com.vecvel.danaview.editor.engine.render

import com.vecvel.danaview.editor.engine.composition.PlanFixtures
import com.vecvel.danaview.editor.engine.preview.render.RangeTouch
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RangeTouchVectorTest {
    private val doc = JSONObject(PlanFixtures.text(PlanFixtures.core("vectors/range_touch.json")))

    @Test
    fun changeTouchesMatchesDartForEveryPlanPair() {
        assertEquals(1, doc.getInt("v"))
        val cases = doc.getJSONArray("cases")
        assertTrue(cases.length() >= 40)
        var checked = 0
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val name = c.getString("name")
            val before = PlanFixtures.plan(c.getJSONObject("before").toString())
            val after = PlanFixtures.plan(c.getJSONObject("after").toString())
            val ranges = c.getJSONArray("ranges")
            for (k in 0 until ranges.length()) {
                val r = ranges.getJSONObject(k)
                val s = r.getLong("s")
                val e = r.getLong("e")
                assertEquals("$name: [$s, $e)", r.getBoolean("touched"),
                    RangeTouch.changeTouches(before, after, s, e))
                checked++
            }
        }
        assertTrue(checked >= 200)
    }
}
```

Optional, and the same check as on iOS: bind the ranges to `before` in the Android swap
(`RenderedRangeSession` or its range holder). Bump `after.rev` when it equals `before.rev`, then
check that reconciling against `after` keeps exactly the ranges whose `touched` is `false`.

Run it with `./gradlew :danaview_editor_engine:testDebugUnitTest --tests '*RangeTouchVectorTest*'`
from `packages/danaview_editor_engine/example/android`.
