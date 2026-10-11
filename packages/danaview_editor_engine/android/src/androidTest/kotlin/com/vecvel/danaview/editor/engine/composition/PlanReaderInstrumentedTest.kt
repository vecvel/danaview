// OWNER: AND-08
//
// The RenderPlan contract corpus through the production decoder, android.util.JsonReader
// (ARCH §11.1 rule 4, §11.9): every valid fixture decodes, validates and re-encodes byte for byte;
// invalid/ reports exactly the expected code on the expected id; invalid_format/ fails at the
// expected JSON path; tolerant/ decodes to the canonical siblings; PlanDecoding turns failures into
// planInvalid / planOutOfSync and classifies patches.

package com.vecvel.danaview.editor.engine.composition

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.plan.PatchClass
import com.vecvel.danaview.editor.engine.plan.PlanDecoding
import com.vecvel.danaview.editor.engine.plan.PlanFormatException
import com.vecvel.danaview.editor.engine.plan.PlanReader
import com.vecvel.danaview.editor.engine.plan.PlanValidator
import com.vecvel.danaview.editor.engine.plan.PlanWriter
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PlanReaderInstrumentedTest {
    private fun trimmed(sub: String, name: String): ByteArray = ContractAssets.text(sub, name).trimEnd().toByteArray(Charsets.UTF_8)

    @Test
    fun validCorpusRoundTripsByteIdentically() {
        val names = ContractAssets.names()
        assertTrue("corpus packed into the test APK: $names", names.size >= 25)
        for (name in names) {
            val bytes = trimmed("", name)
            val text = bytes.toString(Charsets.UTF_8)
            val json = JSONObject(text)
            val again = when {
                json.has("rev") -> {
                    val plan = PlanReader.readPlan(bytes)
                    assertEquals("$name: validator", emptyList<Any>(), PlanValidator.validate(plan))
                    assertEquals("$name: typed equality", plan, PlanReader.readPlan(PlanWriter.planBytes(plan)))
                    PlanWriter.planJson(plan)
                }
                json.has("from") -> PlanWriter.patchJson(PlanReader.readPatch(bytes))
                else -> PlanWriter.transientJson(PlanReader.readTransient(bytes))
            }
            assertEquals("$name: canonical re-encoding", text, again)
        }
    }

    @Test
    fun invalidCorpusReportsTheExpectedCodeAndId() {
        val names = ContractAssets.names("invalid")
        assertTrue(names.size >= 50)
        for (name in names) {
            val expect = JSONObject(ContractAssets.text("invalid", name)).getJSONObject("_expect")
            val code = expect.getString("code")
            val id = if (expect.isNull("id")) null else expect.getString("id")
            val violations = PlanValidator.validate(PlanReader.readPlan(ContractAssets.bytes("invalid", name)))
            assertTrue("$name: $code on $id, got $violations", violations.any { it.code.name == code && it.id == id })
            assertTrue("$name: one invariant, got $violations", violations.all { it.code.name == code })
            try {
                PlanDecoding.plan(ContractAssets.bytes("invalid", name))
                fail("$name: accepted")
            } catch (e: EngineException) {
                assertEquals(EngineErrorCode.planInvalid, e.code)
            }
        }
    }

    @Test
    fun malformedCorpusFailsAtTheExpectedPath() {
        val names = ContractAssets.names("invalid_format")
        assertTrue(names.size >= 15)
        for (name in names) {
            val path = JSONObject(ContractAssets.text("invalid_format", name)).getJSONObject("_expect").getString("path")
            try {
                PlanReader.readPlan(ContractAssets.bytes("invalid_format", name))
                fail("$name: decoded")
            } catch (e: PlanFormatException) {
                assertEquals("$name: path", path, e.path)
            }
        }
        for (bad in listOf("{\"v\":", "[]", "{\"v\":1} trailing", "")) {
            try {
                PlanReader.readPlan(bad.toByteArray())
                fail("decoded <$bad>")
            } catch (e: PlanFormatException) {
                // expected
            }
        }
    }

    @Test
    fun tolerantInputsAndEngineErrors() {
        val loose = PlanReader.readPlan(ContractAssets.bytes("tolerant", "plan_unknown_keys.json"))
        assertEquals(PlanReader.readPlan(trimmed("", "minimal_preview.json")), loose)
        assertEquals(ContractAssets.text("", "minimal_preview.json").trimEnd(), PlanWriter.planJson(loose))
        assertEquals(
            PlanReader.readTransient(ContractAssets.bytes("", "transient_move.json")),
            PlanReader.readTransient(ContractAssets.bytes("tolerant", "transient_timing_fields_ignored.json")),
        )
        val patch = PlanReader.readPatch(ContractAssets.bytes("tolerant", "patch_unknown_keys.json"))
        assertEquals(listOf("it_x#v"), patch.layers.remove)

        // PlanDecoding: patches classify, stale patches are planOutOfSync, malformed bytes planInvalid.
        val plan = PlanDecoding.plan(ContractAssets.bytes("", "minimal_preview.json"))
        val gain = """{"v":1,"from":1,"to":2,"audio":{"upsert":[{"id":"it_clip00000001#a","asset":"md_clipA00000001","t":[0,3000000],"map":[[0,3000000,0,3000000]],"gain":[[0,0.5]]}]}}"""
        val applied = PlanDecoding.applyPatch(plan, gain.toByteArray())
        assertEquals(PatchClass.PARAM_ONLY, applied.patchClass)
        assertEquals(2L, applied.plan.rev)
        try {
            PlanDecoding.applyPatch(applied.plan, gain.toByteArray())
            fail("stale patch applied")
        } catch (e: EngineException) {
            assertEquals(EngineErrorCode.planOutOfSync, e.code)
        }
        try {
            PlanDecoding.plan("{\"v\":1".toByteArray())
            fail("malformed accepted")
        } catch (e: EngineException) {
            assertEquals(EngineErrorCode.planInvalid, e.code)
        }
    }
}
