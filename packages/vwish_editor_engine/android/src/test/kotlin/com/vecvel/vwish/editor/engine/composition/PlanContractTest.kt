// OWNER: AND-08
//
// RenderPlan contract corpus on the JVM (ARCH §11.9; packages/vwish_editor_core/test/fixtures/
// render_plans/contract, CORE-29): every valid fixture decodes, passes the validator and
// re-encodes byte-identically; every invalid/ fixture reports exactly the expected code on the
// expected id; every invalid_format/ fixture fails at the expected JSON path; tolerant/ inputs
// decode to their canonical siblings. The same corpus runs through android.util.JsonReader in
// PlanReaderInstrumentedTest.

package com.vecvel.vwish.editor.engine.composition

import com.vecvel.vwish.editor.engine.plan.PlanFormatException
import com.vecvel.vwish.editor.engine.plan.PlanReader
import com.vecvel.vwish.editor.engine.plan.PlanValidator
import com.vecvel.vwish.editor.engine.plan.PlanViolationCode
import com.vecvel.vwish.editor.engine.plan.PlanWriter
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class PlanContractTest {
    private fun reencode(text: String): String {
        val json = JSONObject(text)
        return when {
            json.has("rev") -> PlanWriter.planJson(PlanFixtures.plan(text))
            json.has("from") -> PlanWriter.patchJson(PlanFixtures.patch(text))
            else -> PlanWriter.transientJson(PlanFixtures.transient(text))
        }
    }

    @Test
    fun corpusCoversPlansPatchesAndTransients() {
        val files = PlanFixtures.contractFiles()
        assertTrue("at least 25 valid fixtures, got ${files.size}", files.size >= 25)
        val kinds = files.map { JSONObject(PlanFixtures.text(it)).let { j -> if (j.has("rev")) "plan" else if (j.has("from")) "patch" else "transient" } }.toSet()
        assertEquals(setOf("plan", "patch", "transient"), kinds)
    }

    @Test
    fun validFixturesValidateAndRoundTripByteIdentically() {
        var checked = 0
        for (f in PlanFixtures.contractFiles()) {
            val text = PlanFixtures.text(f).trimEnd()
            if (JSONObject(text).has("rev")) {
                val plan = PlanFixtures.plan(text)
                assertEquals("${f.name}: validator", emptyList<Any>(), PlanValidator.validate(plan))
                assertEquals("${f.name}: typed equality after a round trip", plan, PlanFixtures.plan(PlanWriter.planJson(plan)))
            }
            assertEquals("${f.name}: canonical re-encoding", text, reencode(text))
            checked++
        }
        assertTrue(checked >= 25)
    }

    @Test
    fun invalidFixturesReportTheExpectedCodeAndIdOnly() {
        val files = PlanFixtures.contractFiles("invalid")
        assertTrue("invalid corpus present", files.size >= 50)
        val codes = HashSet<String>()
        for (f in files) {
            val json = JSONObject(PlanFixtures.text(f))
            val expect = json.getJSONObject("_expect")
            val code = expect.getString("code")
            val id = if (expect.isNull("id")) null else expect.getString("id")
            codes += code
            val violations = PlanValidator.validate(PlanFixtures.plan(PlanFixtures.text(f)))
            assertTrue(
                "${f.name}: expected $code on $id, got $violations",
                violations.any { it.code.name == code && it.id == id },
            )
            assertTrue("${f.name}: isolates one invariant, got $violations", violations.all { it.code.name == code })
        }
        assertEquals(
            "a fixture for every code but version",
            PlanViolationCode.entries.filter { it != PlanViolationCode.version }.map { it.name }.toSet(),
            codes,
        )
    }

    @Test
    fun malformedDocumentsFailAtTheExpectedPath() {
        val files = PlanFixtures.contractFiles("invalid_format")
        assertTrue(files.size >= 15)
        for (f in files) {
            val text = PlanFixtures.text(f)
            val expected = JSONObject(text).getJSONObject("_expect").getString("path")
            try {
                PlanFixtures.plan(text)
                fail("${f.name}: decoded")
            } catch (e: PlanFormatException) {
                assertEquals("${f.name}: path", expected, e.path)
            }
        }
    }

    @Test
    fun patchesAndTransientsCheckTheirVersion() {
        for (doc in listOf("""{"v":2,"from":1,"to":2}""")) {
            try {
                PlanFixtures.patch(doc)
                fail("decoded")
            } catch (e: PlanFormatException) {
                assertEquals("v", e.path)
            }
        }
        try {
            PlanFixtures.transient("""{"v":0,"item":"x","layers":[]}""")
            fail("decoded")
        } catch (e: PlanFormatException) {
            assertEquals("v", e.path)
        }
        try {
            PlanFixtures.plan("[]")
            fail("decoded")
        } catch (e: PlanFormatException) {
            assertEquals("", e.path)
        }
    }

    @Test
    fun tolerantInputsDecodeToTheirCanonicalSiblings() {
        val loose = PlanFixtures.plan(PlanFixtures.text(PlanFixtures.core("${PlanFixtures.CONTRACT}/tolerant/plan_unknown_keys.json")))
        val minimal = PlanFixtures.text(PlanFixtures.core("${PlanFixtures.CONTRACT}/minimal_preview.json")).trimEnd()
        assertEquals(PlanFixtures.plan(minimal), loose)
        assertEquals(minimal, PlanWriter.planJson(loose))

        val p = PlanFixtures.patch(PlanFixtures.text(PlanFixtures.core("${PlanFixtures.CONTRACT}/tolerant/patch_unknown_keys.json")))
        assertEquals(7L, p.from)
        assertEquals(8L, p.to)
        assertEquals(listOf("it_x#v"), p.layers.remove)
        assertTrue(p.layers.upsert.isEmpty())

        val t = PlanFixtures.transient(PlanFixtures.text(PlanFixtures.core("${PlanFixtures.CONTRACT}/tolerant/transient_timing_fields_ignored.json")))
        assertEquals(PlanFixtures.transient(PlanFixtures.text(PlanFixtures.core("${PlanFixtures.CONTRACT}/transient_move.json"))), t)
    }

    @Test
    fun coloursAndNumbersEncodeLikeTheDartCodec() {
        assertEquals("#12AB34FF", PlanWriter.encodeColor(PlanReader.decodeColor("#12ab34", "x")))
        assertEquals("#00000080", PlanWriter.encodeColor(PlanReader.decodeColor("#00000080", "x")))
        val cases = mapOf(
            1.0 to "1", -2.0 to "-2", 0.5 to "0.5", 607.5 to "607.5", 0.1 to "0.1", -15.5 to "-15.5",
            1.0E-7 to "1e-7", 1.5E-7 to "1.5e-7", 0.000001 to "0.000001", 0.0000015 to "0.0000015",
            1.9833335 to "1.9833335", 0.30000000000000004 to "0.30000000000000004",
            1.0E21 to "1e+21", 1.5E22 to "1.5e+22", 9007199254740993.0 to "9007199254740992.0", 123456.789 to "123456.789",
        )
        for ((d, s) in cases) assertEquals("format $d", s, PlanWriter.formatNumber(d))
    }
}
