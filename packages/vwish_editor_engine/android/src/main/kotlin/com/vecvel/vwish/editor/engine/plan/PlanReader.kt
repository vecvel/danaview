// OWNER: AND-08
//
// RenderPlan / Patch / Transient v1 decoder (ARCH §11.1 rule 4, §11.2), mirroring core's
// `plan_json.dart` (CORE-29): unknown keys are ignored, omitted optional keys take their defaults,
// JSON null equals an omitted key, integral reals are accepted where integers are expected, and a
// malformed document fails with a [PlanFormatException] whose `path` names the same JSON location
// the Dart codec reports (`layers[0].map[0]`, `assets.<id>.kind`, …; the contract corpus
// `invalid_format/` checks it). Decoding streams through android.util.JsonReader ([JsonTokens]) on
// the caller's thread (vwish-preview / vwish-export, never main). Nothing here logs plan content.

package com.vecvel.vwish.editor.engine.plan

import java.io.IOException

/** A malformed plan, patch or transient; [path] is the JSON location (empty for the document). */
class PlanFormatException(message: String, val path: String = "") :
    Exception(if (path.isEmpty()) message else "$path: $message")

/** Decoder for the RenderPlan wire format (UTF-8 JSON). */
object PlanReader {
    /** Decodes a plan from UTF-8 JSON [bytes]. */
    fun readPlan(bytes: ByteArray): RenderPlan = decodeBytes(bytes) { readPlan(it) }

    /** Decodes a patch from UTF-8 JSON [bytes]. */
    fun readPatch(bytes: ByteArray): RenderPlanPatch = decodeBytes(bytes) { readPatch(it) }

    /** Decodes a transient from UTF-8 JSON [bytes]. */
    fun readTransient(bytes: ByteArray): PlanTransient = decodeBytes(bytes) { readTransient(it) }

    /** Decodes a plan from [tokens] (the whole document). */
    fun readPlan(tokens: JsonTokens): RenderPlan = guarded(tokens) { Decoder(it).plan() }

    /** Decodes a patch from [tokens]. */
    fun readPatch(tokens: JsonTokens): RenderPlanPatch = guarded(tokens) { Decoder(it).patch() }

    /** Decodes a transient from [tokens]. */
    fun readTransient(tokens: JsonTokens): PlanTransient = guarded(tokens) { Decoder(it).transient() }

    /** `"#RRGGBBAA"` (or `"#RRGGBB"`, alpha FF) to ARGB; [path] names the field on failure. */
    fun decodeColor(s: String, path: String): Int {
        if (!COLOR.matches(s)) throw PlanFormatException("expected \"#RRGGBBAA\"", path)
        val rgb = s.substring(1, 7).toInt(16)
        val a = if (s.length == 9) s.substring(7, 9).toInt(16) else 0xFF
        return (a shl 24) or rgb
    }

    private val COLOR = Regex("^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$")

    private inline fun <T> decodeBytes(bytes: ByteArray, block: (JsonTokens) -> T): T =
        AndroidJsonTokens.of(bytes).use { block(it) }

    private inline fun <T> guarded(tokens: JsonTokens, block: (JsonTokens) -> T): T {
        try {
            val value = block(tokens)
            if (tokens.peek() != JsonTokenKind.END_DOCUMENT) throw PlanFormatException("invalid JSON: trailing content")
            return value
        } catch (e: PlanFormatException) {
            throw e
        } catch (e: IOException) {
            throw PlanFormatException("invalid JSON: ${e.javaClass.simpleName}")
        } catch (e: IllegalStateException) {
            throw PlanFormatException("invalid JSON: ${e.javaClass.simpleName}")
        } catch (e: NumberFormatException) {
            throw PlanFormatException("invalid JSON: malformed number")
        }
    }
}

/** One element of a scalar array (`t`, map segments, keys, crop, base). */
private class Scalar(val kind: JsonTokenKind, val text: String?)

/** The streaming decoder; field paths follow plan_json.dart exactly. */
private class Decoder(private val r: JsonTokens) {
    private fun fail(message: String, path: String): Nothing = throw PlanFormatException(message, path)

    private fun sub(parent: String, key: String): String = if (parent.isEmpty()) key else "$parent.$key"

    // ---------------------------------------------------------------- primitives

    /** Consumes a JSON null and returns true, or returns false. */
    private fun nullNext(): Boolean {
        if (r.peek() != JsonTokenKind.NULL) return false
        r.nextNull()
        return true
    }

    private inline fun obj(path: String, field: (String) -> Unit) {
        if (r.peek() != JsonTokenKind.BEGIN_OBJECT) fail("expected an object", path)
        r.beginObject()
        while (r.hasNext()) field(r.nextName())
        r.endObject()
    }

    private inline fun arr(path: String, element: (Int) -> Unit) {
        if (r.peek() != JsonTokenKind.BEGIN_ARRAY) fail("expected an array", path)
        r.beginArray()
        var i = 0
        while (r.hasNext()) element(i++)
        r.endArray()
    }

    private fun literalToLong(text: String, path: String): Long {
        text.toLongOrNull()?.let { return it }
        val d = text.toDoubleOrNull() ?: fail("expected an integer", path)
        if (d.isFinite() && d == Math.floor(d) && Math.abs(d) < 9.223372036854776E18) return d.toLong()
        fail("expected an integer", path)
    }

    private fun int(path: String): Long {
        if (r.peek() != JsonTokenKind.NUMBER) fail("expected an integer", path)
        return literalToLong(r.nextNumberLiteral(), path)
    }

    private fun dbl(path: String): Double {
        if (r.peek() != JsonTokenKind.NUMBER) fail("expected a number", path)
        return r.nextNumberLiteral().toDoubleOrNull() ?: fail("expected a number", path)
    }

    private fun str(path: String): String {
        if (r.peek() != JsonTokenKind.STRING) fail("expected a string", path)
        return r.nextString()
    }

    private fun bool(path: String): Boolean {
        if (r.peek() != JsonTokenKind.BOOLEAN) fail("expected a boolean", path)
        return r.nextBoolean()
    }

    private fun optInt(path: String): Long? = if (nullNext()) null else int(path)
    private fun optDbl(path: String): Double? = if (nullNext()) null else dbl(path)
    private fun optStr(path: String): String? = if (nullNext()) null else str(path)
    private fun optBool(path: String): Boolean? = if (nullNext()) null else bool(path)

    private fun <T> required(value: T?, message: String, path: String): T = value ?: fail(message, path)

    private fun scalars(path: String): List<Scalar> {
        val out = ArrayList<Scalar>(4)
        arr(path) {
            out += when (val k = r.peek()) {
                JsonTokenKind.NUMBER -> Scalar(k, r.nextNumberLiteral())
                JsonTokenKind.STRING -> Scalar(k, r.nextString())
                JsonTokenKind.BOOLEAN -> Scalar(k, r.nextBoolean().toString())
                JsonTokenKind.NULL -> { r.nextNull(); Scalar(k, null) }
                else -> { r.skipValue(); Scalar(k, null) }
            }
        }
        return out
    }

    private fun Scalar.asLong(path: String): Long {
        if (kind != JsonTokenKind.NUMBER) fail("expected an integer", path)
        return literalToLong(text!!, path)
    }

    private fun Scalar.asDouble(path: String): Double {
        if (kind != JsonTokenKind.NUMBER) fail("expected a number", path)
        return text!!.toDoubleOrNull() ?: fail("expected a number", path)
    }

    private fun strings(path: String): List<String> {
        if (nullNext()) return emptyList()
        val out = ArrayList<String>()
        arr(path) { i -> out += str("$path[$i]") }
        return out
    }

    private fun <E : Enum<E>> enumOf(values: Array<E>, wire: (E) -> String, name: String, path: String): E =
        values.firstOrNull { wire(it) == name } ?: fail("unknown value \"$name\"", path)

    private fun checkVersion(v: Long, what: String) {
        if (v != RENDER_PLAN_VERSION.toLong()) fail("unsupported $what version $v", "v")
    }

    // ---------------------------------------------------------------- documents

    fun plan(): RenderPlan {
        var v: Long? = null
        var rev: Long? = null
        var target: PlanTarget? = null
        var canvas: PlanCanvas? = null
        var durUs: Long? = null
        var assets: Map<String, PlanAsset>? = null
        var layers: List<PlanLayer>? = null
        var audio: List<AudioSeg>? = null
        var req: PlanRequirements? = null
        obj("") { name ->
            when (name) {
                "v" -> v = optInt("v")?.also { checkVersion(it, "plan") }
                "rev" -> rev = optInt("rev")
                "target" -> target = optStr("target")?.let { enumOf(PlanTarget.entries.toTypedArray(), { e -> e.wire }, it, "target") }
                "canvas" -> canvas = if (nullNext()) null else canvas("canvas")
                "durUs" -> durUs = optInt("durUs")
                "assets" -> assets = if (nullNext()) null else assets("assets")
                "layers" -> layers = if (nullNext()) null else layerList("layers")
                "audio" -> audio = if (nullNext()) null else audioList("audio")
                "req" -> req = if (nullNext()) null else requirements()
                else -> r.skipValue()
            }
        }
        checkVersion(required(v, "expected an integer", "v"), "plan")
        return RenderPlan(
            v = RENDER_PLAN_VERSION,
            rev = required(rev, "expected an integer", "rev"),
            target = required(target, "expected a string", "target"),
            canvas = required(canvas, "expected an object", "canvas"),
            durUs = required(durUs, "expected an integer", "durUs"),
            assets = required(assets, "expected an object", "assets"),
            layers = required(layers, "expected an array", "layers"),
            audio = required(audio, "expected an array", "audio"),
            req = req,
        )
    }

    fun patch(): RenderPlanPatch {
        var v: Long? = null
        var from: Long? = null
        var to: Long? = null
        var canvas: PlanCanvas? = null
        var durUs: Long? = null
        var assetUpserts: Map<String, PlanAsset> = emptyMap()
        var assetRemovals: List<String> = emptyList()
        var layers = PatchSet<PlanLayer>()
        var audio = PatchSet<AudioSeg>()
        obj("") { name ->
            when (name) {
                "v" -> v = optInt("v")?.also { checkVersion(it, "patch") }
                "from" -> from = optInt("from")
                "to" -> to = optInt("to")
                "canvas" -> canvas = if (nullNext()) null else canvas("canvas")
                "durUs" -> durUs = optInt("durUs")
                "assets" -> if (!nullNext()) {
                    obj("assets") { key ->
                        when (key) {
                            "upsert" -> assetUpserts = if (nullNext()) emptyMap() else assets("assets.upsert")
                            "remove" -> assetRemovals = strings("assets.remove")
                            else -> r.skipValue()
                        }
                    }
                }
                "layers" -> if (!nullNext()) {
                    var upsert: List<PlanLayer> = emptyList()
                    var remove: List<String> = emptyList()
                    obj("layers") { key ->
                        when (key) {
                            "upsert" -> upsert = if (nullNext()) emptyList() else layerList("layers.upsert")
                            "remove" -> remove = strings("layers.remove")
                            else -> r.skipValue()
                        }
                    }
                    layers = PatchSet(upsert, remove)
                }
                "audio" -> if (!nullNext()) {
                    var upsert: List<AudioSeg> = emptyList()
                    var remove: List<String> = emptyList()
                    obj("audio") { key ->
                        when (key) {
                            "upsert" -> upsert = if (nullNext()) emptyList() else audioList("audio.upsert")
                            "remove" -> remove = strings("audio.remove")
                            else -> r.skipValue()
                        }
                    }
                    audio = PatchSet(upsert, remove)
                }
                else -> r.skipValue()
            }
        }
        checkVersion(required(v, "expected an integer", "v"), "patch")
        return RenderPlanPatch(
            v = RENDER_PLAN_VERSION,
            from = required(from, "expected an integer", "from"),
            to = required(to, "expected an integer", "to"),
            canvas = canvas,
            durUs = durUs,
            assetUpserts = assetUpserts,
            assetRemovals = assetRemovals,
            layers = layers,
            audio = audio,
        )
    }

    fun transient(): PlanTransient {
        var v: Long? = null
        var item: String? = null
        var layers: List<TransientLayer>? = null
        obj("") { name ->
            when (name) {
                "v" -> v = optInt("v")?.also { checkVersion(it, "transient") }
                "item" -> item = optStr("item")
                "layers" -> layers = if (nullNext()) null else {
                    val out = ArrayList<TransientLayer>()
                    arr("layers") { i -> out += transientLayer("layers[$i]") }
                    out
                }
                else -> r.skipValue()
            }
        }
        checkVersion(required(v, "expected an integer", "v"), "transient")
        return PlanTransient(
            v = RENDER_PLAN_VERSION,
            item = required(item, "expected a string", "item"),
            layers = required(layers, "expected an array", "layers"),
        )
    }

    // ---------------------------------------------------------------- pieces

    private fun canvas(path: String): PlanCanvas {
        var w: Long? = null
        var h: Long? = null
        var fps: Long? = null
        var gridFps: Long? = null
        var bg: Int? = null
        obj(path) { name ->
            when (name) {
                "w" -> w = optInt("$path.w")
                "h" -> h = optInt("$path.h")
                "fps" -> fps = optInt("$path.fps")
                "gridFps" -> gridFps = optInt("$path.gridFps")
                "bg" -> bg = optStr("$path.bg")?.let { PlanReader.decodeColor(it, "$path.bg") }
                else -> r.skipValue()
            }
        }
        val f = required(fps, "expected an integer", "$path.fps").toInt()
        return PlanCanvas(
            w = required(w, "expected an integer", "$path.w").toInt(),
            h = required(h, "expected an integer", "$path.h").toInt(),
            fps = f,
            gridFps = gridFps?.toInt() ?: f,
            bg = bg ?: PlanCanvas.OPAQUE_BLACK,
        )
    }

    private fun assets(path: String): Map<String, PlanAsset> {
        val out = LinkedHashMap<String, PlanAsset>()
        obj(path) { id -> out[id] = asset("$path.$id") }
        return out
    }

    private fun asset(p: String): PlanAsset {
        var kind: PlanAssetKind? = null
        var uri: String? = null
        var bookmark: String? = null
        var fp: String? = null
        var proxyUri: String? = null
        var w: Long? = null
        var h: Long? = null
        var rot: Long? = null
        var durUs: Long? = null
        var transfer: PlanTransfer? = null
        var hasAudio: Boolean? = null
        var n: Long? = null
        var sw: Long? = null
        var sh: Long? = null
        var sscale: Double? = null
        var reveal: Boolean? = null
        obj(p) { name ->
            when (name) {
                "kind" -> kind = optStr("$p.kind")?.let { enumOf(PlanAssetKind.entries.toTypedArray(), { e -> e.wire }, it, "$p.kind") }
                "uri" -> uri = optStr("$p.uri")
                "bookmark" -> bookmark = optStr("$p.bookmark")
                "fp" -> fp = optStr("$p.fp")
                "proxyUri" -> proxyUri = optStr("$p.proxyUri")
                "w" -> w = optInt("$p.w")
                "h" -> h = optInt("$p.h")
                "rot" -> rot = optInt("$p.rot")
                "durUs" -> durUs = optInt("$p.durUs")
                "transfer" -> transfer = optStr("$p.transfer")?.let { enumOf(PlanTransfer.entries.toTypedArray(), { e -> e.wire }, it, "$p.transfer") }
                "hasAudio" -> hasAudio = optBool("$p.hasAudio")
                "n" -> n = optInt("$p.n")
                "sw" -> sw = optInt("$p.sw")
                "sh" -> sh = optInt("$p.sh")
                "sscale" -> sscale = optDbl("$p.sscale")
                "reveal" -> reveal = optBool("$p.reveal")
                else -> r.skipValue()
            }
        }
        return PlanAsset(
            kind = required(kind, "expected a string", "$p.kind"),
            uri = required(uri, "expected a string", "$p.uri"),
            bookmark = bookmark,
            fp = fp ?: "",
            proxyUri = proxyUri,
            w = w?.toInt(),
            h = h?.toInt(),
            rot = rot?.toInt(),
            durUs = durUs,
            transfer = transfer ?: PlanTransfer.SDR,
            hasAudio = hasAudio,
            n = n?.toInt(),
            sw = sw?.toInt(),
            sh = sh?.toInt(),
            sscale = sscale,
            reveal = reveal,
        )
    }

    private fun layerList(path: String): List<PlanLayer> {
        val out = ArrayList<PlanLayer>()
        arr(path) { i -> out += layer("$path[$i]") }
        return out
    }

    private fun range(p: String): Pair<Long, Long>? {
        if (nullNext()) return null
        val t = scalars("$p.t")
        if (t.size != 2) fail("expected [t0, t1]", "$p.t")
        return t[0].asLong("$p.t[0]") to t[1].asLong("$p.t[1]")
    }

    private fun layer(p: String): PlanLayer {
        var id: String? = null
        var z: Long? = null
        var seq: Long? = null
        var t: Pair<Long, Long>? = null
        var kind: PlanLayerKind? = null
        var asset: String? = null
        var map: List<MapSegment> = emptyList()
        var hold = false
        var color: Int? = null
        var base: PlanSize? = null
        var crop = PlanCrop.FULL
        var xf = PlanTransform.IDENTITY
        var fx = PlanEffects.NONE
        var anim: Map<String, Keyframes> = emptyMap()
        var cmasks: List<CanvasMask> = emptyList()
        obj(p) { name ->
            when (name) {
                "id" -> id = optStr("$p.id")
                "z" -> z = optInt("$p.z")
                "seq" -> seq = optInt("$p.seq")
                "t" -> t = range(p)
                "kind" -> kind = optStr("$p.kind")?.let { enumOf(PlanLayerKind.entries.toTypedArray(), { e -> e.wire }, it, "$p.kind") }
                "asset" -> asset = optStr("$p.asset")
                "map" -> map = if (nullNext()) emptyList() else mapSegments("$p.map")
                "hold" -> hold = optBool("$p.hold") ?: false
                "color" -> color = optStr("$p.color")?.let { PlanReader.decodeColor(it, "$p.color") }
                "base" -> base = if (nullNext()) null else size("$p.base")
                "crop" -> crop = if (nullNext()) PlanCrop.FULL else crop("$p.crop")
                "xf" -> xf = if (nullNext()) PlanTransform.IDENTITY else transform("$p.xf")
                "fx" -> fx = if (nullNext()) PlanEffects.NONE else effects("$p.fx")
                "anim" -> anim = if (nullNext()) emptyMap() else anim("$p.anim")
                "cmasks" -> cmasks = if (nullNext()) emptyList() else canvasMasks("$p.cmasks")
                else -> r.skipValue()
            }
        }
        val range = t ?: fail("expected an array", "$p.t")
        return PlanLayer(
            id = required(id, "expected a string", "$p.id"),
            z = required(z, "expected an integer", "$p.z").toInt(),
            seq = seq?.toInt(),
            t0 = range.first,
            t1 = range.second,
            kind = required(kind, "expected a string", "$p.kind"),
            asset = asset,
            map = map,
            hold = hold,
            color = color,
            base = base,
            crop = crop,
            xf = xf,
            fx = fx,
            anim = anim,
            cmasks = cmasks,
        )
    }

    private fun audioList(path: String): List<AudioSeg> {
        val out = ArrayList<AudioSeg>()
        arr(path) { i -> out += audioSeg("$path[$i]") }
        return out
    }

    private fun audioSeg(p: String): AudioSeg {
        var id: String? = null
        var asset: String? = null
        var stream: Long? = null
        var t: Pair<Long, Long>? = null
        var map: List<MapSegment>? = null
        var gain: Keyframes? = null
        var pitch: Boolean? = null
        obj(p) { name ->
            when (name) {
                "id" -> id = optStr("$p.id")
                "asset" -> asset = optStr("$p.asset")
                "stream" -> stream = optInt("$p.stream")
                "t" -> t = range(p)
                "map" -> map = if (nullNext()) null else mapSegments("$p.map")
                "gain" -> gain = if (nullNext()) null else keys("$p.gain")
                "pitch" -> pitch = optBool("$p.pitch")
                else -> r.skipValue()
            }
        }
        val range = t ?: fail("expected an array", "$p.t")
        return AudioSeg(
            id = required(id, "expected a string", "$p.id"),
            asset = required(asset, "expected a string", "$p.asset"),
            stream = stream?.toInt() ?: 0,
            t0 = range.first,
            t1 = range.second,
            map = required(map, "expected an array", "$p.map"),
            gain = required(gain, "expected an array", "$p.gain"),
            pitch = pitch ?: true,
        )
    }

    private fun requirements(): PlanRequirements {
        var offline: List<String> = emptyList()
        var pendingReverse: List<String> = emptyList()
        var pendingStill: List<String> = emptyList()
        obj("req") { name ->
            when (name) {
                "offline" -> offline = strings("req.offline")
                "pendingReverse" -> pendingReverse = strings("req.pendingReverse")
                "pendingStill" -> pendingStill = strings("req.pendingStill")
                else -> r.skipValue()
            }
        }
        return PlanRequirements(offline, pendingReverse, pendingStill)
    }

    private fun mapSegments(p: String): List<MapSegment> {
        val out = ArrayList<MapSegment>()
        arr(p) { i ->
            val e = "$p[$i]"
            val s = scalars(e)
            if (s.size != 4) fail("expected [t0, t1, s0, s1]", e)
            val t0 = s[0].asLong("$e[0]")
            val t1 = s[1].asLong("$e[1]")
            val s0 = s[2].asLong("$e[2]")
            val s1 = s[3].asLong("$e[3]")
            if (t1 <= t0 || s1 < s0) fail("segment needs t1 > t0 and s1 >= s0", e)
            out += MapSegment(t0, t1, s0, s1)
        }
        return out
    }

    private fun keys(p: String): Keyframes {
        val times = ArrayList<Long>()
        val values = ArrayList<Double>()
        arr(p) { i ->
            val e = "$p[$i]"
            val k = scalars(e)
            if (k.size != 2) fail("expected [tUs, v]", e)
            times += k[0].asLong("$e[0]")
            values += k[1].asDouble("$e[1]")
        }
        return Keyframes(times.toLongArray(), values.toDoubleArray())
    }

    private fun crop(p: String): PlanCrop {
        val c = scalars(p)
        if (c.size != 4) fail("expected [l, t, r, b]", p)
        return PlanCrop(c[0].asDouble(p), c[1].asDouble(p), c[2].asDouble(p), c[3].asDouble(p))
    }

    private fun size(p: String): PlanSize {
        val c = scalars(p)
        if (c.size != 2) fail("expected [w, h]", p)
        return PlanSize(c[0].asDouble(p), c[1].asDouble(p))
    }

    private fun transform(p: String): PlanTransform {
        var cx: Double? = null
        var cy: Double? = null
        var s: Double? = null
        var rot: Double? = null
        var fx: Boolean? = null
        var fy: Boolean? = null
        var op: Double? = null
        obj(p) { name ->
            when (name) {
                "cx" -> cx = optDbl("$p.cx")
                "cy" -> cy = optDbl("$p.cy")
                "s" -> s = optDbl("$p.s")
                "r" -> rot = optDbl("$p.r")
                "fx" -> fx = optBool("$p.fx")
                "fy" -> fy = optBool("$p.fy")
                "op" -> op = optDbl("$p.op")
                else -> r.skipValue()
            }
        }
        return PlanTransform(cx, cy, s ?: 1.0, rot ?: 0.0, fx ?: false, fy ?: false, op ?: 1.0)
    }

    private fun effects(p: String): PlanEffects {
        var adj: PlanAdjust? = null
        var detail: PlanDetail? = null
        var lut: PlanLut? = null
        var chroma: PlanChroma? = null
        var mask: PlanMask? = null
        obj(p) { name ->
            when (name) {
                "adj" -> adj = if (nullNext()) null else {
                    val values = DoubleArray(8)
                    obj("$p.adj") { key ->
                        val i = PlanAdjust.NAMES.indexOf(key)
                        if (i < 0) r.skipValue() else values[i] = optDbl("$p.adj.$key") ?: 0.0
                    }
                    PlanAdjust.of(values.toList())
                }
                "detail" -> detail = if (nullNext()) null else {
                    var sharpen = 0.0
                    var blur = 0.0
                    var vignette = 0.0
                    obj("$p.detail") { key ->
                        when (key) {
                            "sharpen" -> sharpen = optDbl("$p.detail.sharpen") ?: 0.0
                            "blur" -> blur = optDbl("$p.detail.blur") ?: 0.0
                            "vignette" -> vignette = optDbl("$p.detail.vignette") ?: 0.0
                            else -> r.skipValue()
                        }
                    }
                    PlanDetail(sharpen, blur, vignette)
                }
                "lut" -> lut = if (nullNext()) null else {
                    var asset: String? = null
                    var i: Double? = null
                    obj("$p.lut") { key ->
                        when (key) {
                            "asset" -> asset = optStr("$p.lut.asset")
                            "i" -> i = optDbl("$p.lut.i")
                            else -> r.skipValue()
                        }
                    }
                    PlanLut(required(asset, "expected a string", "$p.lut.asset"), i ?: 1.0)
                }
                "chroma" -> chroma = if (nullNext()) null else {
                    var key: Int? = null
                    var sim: Double? = null
                    var smooth: Double? = null
                    var spill: Double? = null
                    obj("$p.chroma") { k ->
                        when (k) {
                            "key" -> key = optStr("$p.chroma.key")?.let { PlanReader.decodeColor(it, "$p.chroma.key") and 0xFFFFFF }
                            "sim" -> sim = optDbl("$p.chroma.sim")
                            "smooth" -> smooth = optDbl("$p.chroma.smooth")
                            "spill" -> spill = optDbl("$p.chroma.spill")
                            else -> r.skipValue()
                        }
                    }
                    PlanChroma(required(key, "expected a string", "$p.chroma.key"), sim ?: 0.4, smooth ?: 0.1, spill ?: 0.3)
                }
                "mask" -> mask = if (nullNext()) null else mask("$p.mask")
                else -> r.skipValue()
            }
        }
        return PlanEffects(adj, detail, lut, chroma, mask)
    }

    private fun mask(mp: String): PlanMask {
        var shape: PlanMaskShape? = null
        val v = HashMap<String, Double>()
        var inv: Boolean? = null
        obj(mp) { key ->
            when (key) {
                "shape" -> shape = optStr("$mp.shape")?.let { enumOf(PlanMaskShape.entries.toTypedArray(), { e -> e.wire }, it, "$mp.shape") }
                "cx", "cy", "w", "h", "r", "corner", "feather", "op" -> putOrRemove(v, key, optDbl("$mp.$key"))
                "inv" -> inv = optBool("$mp.inv")
                else -> r.skipValue()
            }
        }
        return PlanMask(
            shape = required(shape, "expected a string", "$mp.shape"),
            cx = v["cx"] ?: 0.5,
            cy = v["cy"] ?: 0.5,
            w = v["w"] ?: 1.0,
            h = v["h"] ?: 1.0,
            r = v["r"] ?: 0.0,
            corner = v["corner"] ?: 0.0,
            feather = v["feather"] ?: 0.0,
            op = v["op"] ?: 1.0,
            inv = inv ?: false,
        )
    }

    private fun putOrRemove(map: HashMap<String, Double>, key: String, value: Double?) {
        if (value == null) map.remove(key) else map[key] = value
    }

    private fun anim(p: String): Map<String, Keyframes> {
        val out = LinkedHashMap<String, Keyframes>()
        obj(p) { channel -> out[channel] = keys("$p.$channel") }
        return out
    }

    private fun canvasMasks(p: String): List<CanvasMask> {
        val out = ArrayList<CanvasMask>()
        arr(p) { i -> out += canvasMask("$p[$i]") }
        return out
    }

    private fun canvasMask(p: String): CanvasMask {
        val v = HashMap<String, Double>()
        var inv: Boolean? = null
        var anim: Map<String, Keyframes> = emptyMap()
        obj(p) { key ->
            when (key) {
                "cx", "cy", "w", "h", "r", "feather" -> putOrRemove(v, key, optDbl("$p.$key"))
                "inv" -> inv = optBool("$p.inv")
                "anim" -> anim = if (nullNext()) emptyMap() else anim("$p.anim")
                else -> r.skipValue()
            }
        }
        return CanvasMask(
            cx = required(v["cx"], "expected a number", "$p.cx"),
            cy = required(v["cy"], "expected a number", "$p.cy"),
            w = required(v["w"], "expected a number", "$p.w"),
            h = required(v["h"], "expected a number", "$p.h"),
            r = v["r"] ?: 0.0,
            feather = v["feather"] ?: 0.0,
            inv = inv ?: false,
            anim = anim,
        )
    }

    private fun transientLayer(p: String): TransientLayer {
        var id: String? = null
        var xf: PlanTransform? = null
        var crop: PlanCrop? = null
        var base: PlanSize? = null
        var fx: PlanEffects? = null
        var anim: Map<String, Keyframes>? = null
        var cmasks: List<CanvasMask>? = null
        obj(p) { name ->
            when (name) {
                "id" -> id = optStr("$p.id")
                "xf" -> xf = if (nullNext()) null else transform("$p.xf")
                "crop" -> crop = if (nullNext()) null else crop("$p.crop")
                "base" -> base = if (nullNext()) null else size("$p.base")
                "fx" -> fx = if (nullNext()) null else effects("$p.fx")
                "anim" -> anim = if (nullNext()) null else anim("$p.anim")
                "cmasks" -> cmasks = if (nullNext()) null else canvasMasks("$p.cmasks")
                // Timing fields are ignored (ARCH §11.2 Transient).
                else -> r.skipValue()
            }
        }
        return TransientLayer(required(id, "expected a string", "$p.id"), xf, crop, base, fx, anim, cmasks)
    }
}
