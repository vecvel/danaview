// OWNER: AND-08
//
// JVM test support for the plan reader and the composition mapper: a [JsonTokens] source over
// org.json (android.jar's android.util.JsonReader is a stub in JVM tests; the instrumented
// PlanReaderInstrumentedTest runs the same corpus through the real JsonReader), fixture access and
// a deterministic fake [SourceTimeline] (constant-rate sample tables).

package com.vecvel.danaview.editor.engine.composition

import com.vecvel.danaview.editor.engine.harness.FixtureTree
import com.vecvel.danaview.editor.engine.harness.JvmFixtures
import com.vecvel.danaview.editor.engine.plan.JsonTokenKind
import com.vecvel.danaview.editor.engine.plan.JsonTokens
import com.vecvel.danaview.editor.engine.plan.PlanReader
import com.vecvel.danaview.editor.engine.plan.PlanTransient
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import com.vecvel.danaview.editor.engine.plan.RenderPlanPatch
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener
import java.io.File

/** [JsonTokens] replaying a parsed org.json tree (key order within an object is not preserved). */
class JsonTreeTokens(text: String) : JsonTokens {
    private data class Tok(val kind: JsonTokenKind, val text: String? = null)

    private val toks = ArrayList<Tok>()
    private var pos = 0

    init {
        emit(JSONTokener(text).nextValue())
        toks += Tok(JsonTokenKind.END_DOCUMENT)
    }

    private fun emit(v: Any?) {
        when (v) {
            is JSONObject -> {
                toks += Tok(JsonTokenKind.BEGIN_OBJECT)
                for (k in v.keys()) {
                    toks += Tok(JsonTokenKind.NAME, k)
                    emit(v.get(k))
                }
                toks += Tok(JsonTokenKind.END_OBJECT)
            }
            is JSONArray -> {
                toks += Tok(JsonTokenKind.BEGIN_ARRAY)
                for (i in 0 until v.length()) emit(v.get(i))
                toks += Tok(JsonTokenKind.END_ARRAY)
            }
            is String -> toks += Tok(JsonTokenKind.STRING, v)
            is Boolean -> toks += Tok(JsonTokenKind.BOOLEAN, v.toString())
            is Number -> toks += Tok(JsonTokenKind.NUMBER, v.toString())
            null, JSONObject.NULL -> toks += Tok(JsonTokenKind.NULL)
            else -> error("unexpected JSON value ${v.javaClass}")
        }
    }

    private fun take(kind: JsonTokenKind): Tok {
        val t = toks[pos]
        check(t.kind == kind) { "expected $kind, found ${t.kind}" }
        pos++
        return t
    }

    override fun peek(): JsonTokenKind = toks[pos].kind
    override fun beginObject() { take(JsonTokenKind.BEGIN_OBJECT) }
    override fun endObject() { take(JsonTokenKind.END_OBJECT) }
    override fun beginArray() { take(JsonTokenKind.BEGIN_ARRAY) }
    override fun endArray() { take(JsonTokenKind.END_ARRAY) }
    override fun hasNext(): Boolean = toks[pos].kind != JsonTokenKind.END_OBJECT && toks[pos].kind != JsonTokenKind.END_ARRAY
    override fun nextName(): String = take(JsonTokenKind.NAME).text!!
    override fun nextString(): String = take(JsonTokenKind.STRING).text!!
    override fun nextNumberLiteral(): String = take(JsonTokenKind.NUMBER).text!!
    override fun nextBoolean(): Boolean = take(JsonTokenKind.BOOLEAN).text!!.toBoolean()
    override fun nextNull() { take(JsonTokenKind.NULL) }

    override fun skipValue() {
        var depth = 0
        do {
            when (toks[pos++].kind) {
                JsonTokenKind.BEGIN_OBJECT, JsonTokenKind.BEGIN_ARRAY -> depth++
                JsonTokenKind.END_OBJECT, JsonTokenKind.END_ARRAY -> depth--
                else -> Unit
            }
        } while (depth > 0)
    }

    override fun close() = Unit
}

/** Plan fixtures for JVM tests. */
object PlanFixtures {
    const val CONTRACT = "render_plans/contract"

    /** The core fixture file [relative] (under packages/danaview_editor_core/test/fixtures). */
    fun core(relative: String): File = JvmFixtures.file(FixtureTree.CORE, relative)

    /** The engine_api fixture file [relative]. */
    fun engineApi(relative: String): File = JvmFixtures.file(FixtureTree.ENGINE_API, relative)

    /** `*.json` files of a contract sub-directory ("" for the valid corpus), sorted by name. */
    fun contractFiles(sub: String = ""): List<File> =
        (core(if (sub.isEmpty()) CONTRACT else "$CONTRACT/$sub").listFiles() ?: emptyArray())
            .filter { it.isFile && it.name.endsWith(".json") && !it.name.endsWith(".expected_active.json") }
            .sortedBy { it.name }

    fun text(f: File): String = f.readText(Charsets.UTF_8)

    fun plan(text: String): RenderPlan = PlanReader.readPlan(JsonTreeTokens(text))
    fun patch(text: String): RenderPlanPatch = PlanReader.readPatch(JsonTreeTokens(text))
    fun transient(text: String): PlanTransient = PlanReader.readTransient(JsonTreeTokens(text))

    /** The valid contract plans (documents with `rev`) by file name. */
    fun contractPlans(): Map<String, RenderPlan> =
        contractFiles().filter { JSONObject(text(it)).has("rev") }.associate { it.name to plan(text(it)) }
}

/**
 * A fake source: every video has frames at `round(i·1e6/fps) + offsetUs` (a constant-rate sample
 * table), and every source lasts [durationUs] unless listed in [durations].
 */
class FakeSourceTimeline(
    private val fps: Int = 30,
    private val offsetUs: Long = 0L,
    private val durationUs: Long? = 3_600_000_000L,
    private val durations: Map<String, Long> = emptyMap(),
) : SourceTimeline {
    val ruleQueries = ArrayList<Pair<String, Long>>()

    /** PTS of sample i. */
    fun pts(i: Long): Long = Math.floorDiv(2 * i * 1_000_000L + fps, 2L * fps) + offsetUs

    override fun ruleFramePtsUs(uri: String, sourceUs: Long): Long {
        ruleQueries += uri to sourceUs
        val target = sourceUs + SourceTimeline.EPSILON_US
        if (target < pts(0)) return pts(0)
        // Greatest i with pts(i) <= target.
        var i = Math.floorDiv((target - offsetUs) * fps, 1_000_000L)
        while (pts(i + 1) <= target) i++
        while (i > 0 && pts(i) > target) i--
        return pts(i)
    }

    override fun durationUs(uri: String): Long? = durations[uri] ?: durationUs
}
