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
