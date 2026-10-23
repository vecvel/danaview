package com.vecvel.danaview.spike.face

import android.app.Activity
import android.app.Instrumentation
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Bundle
import android.os.Debug
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/**
 * VED-33A bench, run with `am instrument -w [-e key value] com.vecvel.danaview.spike.face/.FaceBench`.
 *
 * Inputs (pushed by tool/run_bench.sh to the app's external files dir and deleted after the run):
 * `models/` (the Beauty-pack candidates) and `faces/stills`, `faces/clips` (the licensed fixtures).
 *
 * Output: `results/results.jsonl` with latency, counts and parity AGGREGATES only. Landmarks and masks
 * never leave memory: every cross-runtime comparison is made here, on the device (fixture licence rules).
 *
 * Args: runtimes (csv of candidate names), sections (stills,clips), res (720,1080), repeats (5),
 * frames (max frames per clip, 250), segEvery (segment every Nth clip frame, 5), pose (pose_landmarks_full).
 */
class FaceBench : Instrumentation() {
    private lateinit var args: Bundle
    private lateinit var out: File

    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        args = arguments ?: Bundle()
        start()
    }

    override fun onStart() {
        val result = Bundle()
        try {
            bench()
            result.putString("VED33A", "done")
            finish(Activity.RESULT_OK, result)
        } catch (t: Throwable) {
            Log.e(TAG, "bench failed", t)
            if (::out.isInitialized) emit(JSONObject().put("type", "error").put("error", Log.getStackTraceString(t).take(4000)))
            result.putString("VED33A", "error: $t")
            finish(Activity.RESULT_CANCELED, result)
        }
    }

    private fun arg(k: String, d: String) = args.getString(k) ?: d

    private fun bench() {
        val root = targetContext.getExternalFilesDir(null)!!
        if (arg("prepare", "") == "1") {
            // Let the app own its external dirs so the shell can push into them and the app can write results.
            for (d in listOf("models", "faces", "results")) File(root, d).mkdirs()
            return
        }
        val models = File(root, "models")
        val faces = File(root, "faces")
        out = File(root, "results").apply { mkdirs() }.resolve(arg("out", "results.jsonl"))
        System.setProperty("ved33a.pose", arg("pose", "pose_landmarks_full"))
        val wanted = arg("runtimes", "").split(',').filter { it.isNotBlank() }.toSet()
        val cands = Registry.candidates(targetContext).filter { wanted.isEmpty() || it.name in wanted }
        val sections = arg("sections", "stills,clips").split(',')
        val resList = arg("res", "720,1080").split(',').map { it.trim().toInt() }
        emit(
            JSONObject().put("type", "env")
                .put("device", "${Build.MANUFACTURER} ${Build.MODEL}").put("sdk", Build.VERSION.SDK_INT)
                .put("abi", Build.SUPPORTED_ABIS.first()).put("cores", Runtime.getRuntime().availableProcessors())
                .put("candidates", JSONArray(cands.map { it.name })).put("pose", arg("pose", "pose_landmarks_full"))
                .put("args", JSONObject(args.keySet().associateWith { args.getString(it) })),
        )
        for (c in cands) {
            val t = System.nanoTime()
            c.open(models, video = false, maxFaces = 4, maxPoses = 2)
            emit(JSONObject().put("type", "init").put("cand", c.name).put("ms", ms(t)))
        }
        if ("stills" in sections) {
            val stills = File(faces, "stills").listFiles()!!.filter { it.name.endsWith(".jpg") }.sortedBy { it.name }
            for (res in resList) for (f in stills) still(cands, models, f, res)
        }
        if ("clips" in sections) {
            val clips = File(faces, "clips").listFiles()!!.filter { it.name.endsWith(".mp4") }.sortedBy { it.name }
            for (res in resList) for (f in clips) clip(cands, models, f, res)
        }
        cands.forEach { it.close() }
        val mi = Debug.MemoryInfo().also { Debug.getMemoryInfo(it) }
        emit(JSONObject().put("type", "end").put("pssKb", mi.totalPss))
    }

    /** Long side of a "720p" / "1080p" frame. */
    private fun longSide(res: Int) = if (res == 720) 1280 else 1920

    private fun still(cands: List<Candidate>, models: File, f: File, res: Int) {
        val frame = loadScaled(f, longSide(res))
        val repeats = arg("repeats", "5").toInt()
        val results = LinkedHashMap<String, Triple<List<Face>, List<Pose>, Seg>>()
        for (c in cands) {
            c.open(models, video = false, maxFaces = 4, maxPoses = 2)
            val tf = ArrayList<Double>(); val tp = ArrayList<Double>(); val ts = ArrayList<Double>()
            val extra = LinkedHashMap<String, ArrayList<Double>>()
            var last: Triple<List<Face>, List<Pose>, Seg>? = null
            for (r in 0..repeats) { // r == 0 is the warm-up
                var t = System.nanoTime(); val fa = c.faces(frame, 0); val dFace = ms(t)
                t = System.nanoTime(); val po = c.poses(frame, 0); val dPose = ms(t)
                t = System.nanoTime(); val se = c.segment(frame); val dSeg = ms(t)
                for (x in c.extras()) {
                    t = System.nanoTime(); c.runExtra(x, frame)
                    if (r > 0) extra.getOrPut(x) { ArrayList() } += ms(t)
                }
                if (r > 0) { tf += dFace; tp += dPose; ts += dSeg }
                last = Triple(fa, po, se)
            }
            results[c.name] = last!!
            emit(
                JSONObject().put("type", "still").put("fixture", f.name).put("res", res).put("cand", c.name)
                    .put("w", frame.width).put("h", frame.height)
                    .put("face_ms", median(tf)).put("pose_ms", median(tp)).put("seg_ms", median(ts))
                    .put("extras_ms", JSONObject(extra.mapValues { median(it.value) }))
                    .put("faces", last.first.size).put("poses", last.second.size),
            )
        }
        val names = results.keys.toList()
        for (i in names.indices) for (j in i + 1 until names.size) {
            val a = results.getValue(names[i]); val b = results.getValue(names[j])
            val fp = FaceParity().apply { add(a.first, b.first) }
            val pp = PoseParity().apply { add(a.second, b.second) }
            val sp = SegParity().apply { add(a.third, b.third) }
            emit(
                JSONObject().put("type", "parity_still").put("fixture", f.name).put("res", res)
                    .put("pair", "${names[i]}~${names[j]}")
                    .put("face", fp.json()).put("pose", pp.json()).put("seg", sp.json()),
            )
        }
        frame.recycle()
    }

    private fun clip(cands: List<Candidate>, models: File, f: File, res: Int) {
        val maxFrames = arg("frames", "250").toInt()
        val segEvery = arg("segEvery", "5").toInt()
        // Tracking budget per clip: the number of people the clip shows.
        val people = if (f.name.startsWith("02_")) 2 else 1
        val mmr = MediaMetadataRetriever().apply { setDataSource(f.absolutePath) }
        val durMs = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)!!.toLong()
        val count = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT)?.toIntOrNull()
            ?: (durMs * (mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_CAPTURE_FRAMERATE)?.toFloatOrNull() ?: 25f) / 1000).toInt()
        val n = min(count, maxFrames)
        val stepMs = durMs.toDouble() / count
        for (c in cands) c.open(models, video = true, maxFaces = people, maxPoses = people)
        val lat = cands.associate { it.name to Triple(ArrayList<Double>(), ArrayList<Double>(), ArrayList<Double>()) }
        val faceFrames = cands.associate { it.name to IntArray(1) }
        val names = cands.map { it.name }
        val pairs = names.indices.flatMap { i -> (i + 1 until names.size).map { j -> i to j } }
        val fpar = pairs.associateWith { FaceParity() }
        val ppar = pairs.associateWith { PoseParity() }
        val spar = pairs.associateWith { SegParity() }
        val params = MediaMetadataRetriever.BitmapParams().apply { preferredConfig = Bitmap.Config.ARGB_8888 }
        var idx = 0
        var skipped = 0
        while (idx < n) {
            // Some files make the batch call return nulls; fall back to one frame by time.
            val batch: List<Bitmap?> = try { mmr.getFramesAtIndex(idx, min(5, n - idx), params) } catch (e: Exception) { listOf(null) }
            for (maybe in batch) {
                val raw = maybe ?: mmr.getFrameAtTime((idx * stepMs * 1000).toLong(), MediaMetadataRetriever.OPTION_CLOSEST, params)
                if (raw == null) { idx++; skipped++; continue }
                val frame = scaleTo(raw, longSide(res))
                val ts = (idx * stepMs).toLong()
                val doSeg = idx % segEvery == 0
                val fr = ArrayList<List<Face>>(); val pr = ArrayList<List<Pose>>(); val sr = ArrayList<Seg?>()
                for (c in cands) {
                    val l = lat.getValue(c.name)
                    var t = System.nanoTime(); val fa = c.faces(frame, ts); l.first += ms(t)
                    t = System.nanoTime(); val po = c.poses(frame, ts); l.second += ms(t)
                    var se: Seg? = null
                    if (doSeg) { t = System.nanoTime(); se = c.segment(frame); l.third += ms(t) }
                    if (fa.isNotEmpty()) faceFrames.getValue(c.name)[0]++
                    fr += fa; pr += po; sr += se
                }
                for (p in pairs) {
                    fpar.getValue(p).add(fr[p.first], fr[p.second])
                    ppar.getValue(p).add(pr[p.first], pr[p.second])
                    val sa = sr[p.first]; val sb = sr[p.second]
                    if (sa != null && sb != null) spar.getValue(p).add(sa, sb)
                }
                if (frame !== raw) frame.recycle()
                raw.recycle()
                idx++
            }
        }
        mmr.release()
        for (c in cands) {
            val l = lat.getValue(c.name)
            emit(
                JSONObject().put("type", "clip").put("fixture", f.name).put("res", res).put("cand", c.name)
                    .put("frames", n - skipped).put("framesWithFace", faceFrames.getValue(c.name)[0])
                    .put("face_ms", stats(l.first)).put("pose_ms", stats(l.second)).put("seg_ms", stats(l.third)),
            )
        }
        for (p in pairs) {
            emit(
                JSONObject().put("type", "parity_clip").put("fixture", f.name).put("res", res)
                    .put("pair", "${names[p.first]}~${names[p.second]}")
                    .put("face", fpar.getValue(p).json()).put("pose", ppar.getValue(p).json()).put("seg", spar.getValue(p).json()),
            )
        }
    }

    // ---- Parity accumulators (aggregates only) -----------------------------------------------------

    /** Faces matched by landmark centroid; mean / max per-point distance in px and normalised by IOD. */
    private class FaceParity {
        val perFace = ArrayList<Double>(); var maxPx = 0.0; val nme = ArrayList<Double>()
        var onlyA = 0; var onlyB = 0; var matched = 0
        fun add(a: List<Face>, b: List<Face>) {
            val used = BooleanArray(b.size)
            for (fa in a) {
                val ca = centroid(fa.pts); val iod = hypot(fa.x(33) - fa.x(263), fa.y(33) - fa.y(263)).toDouble()
                var best = -1; var bestD = Double.MAX_VALUE
                b.forEachIndexed { k, fb ->
                    if (used[k]) return@forEachIndexed
                    val cb = centroid(fb.pts)
                    val d = hypot(ca.first - cb.first, ca.second - cb.second)
                    if (d < bestD) { bestD = d; best = k }
                }
                if (best < 0 || bestD > iod) { onlyA++; continue }
                used[best] = true; matched++
                val fb = b[best]
                var sum = 0.0
                for (i in 0 until min(fa.n, fb.n)) {
                    val d = hypot((fa.x(i) - fb.x(i)).toDouble(), (fa.y(i) - fb.y(i)).toDouble())
                    sum += d; maxPx = max(maxPx, d)
                }
                val mean = sum / min(fa.n, fb.n)
                perFace += mean; nme += mean / max(iod, 1e-6)
            }
            onlyB += used.count { !it }
        }
        fun json() = JSONObject().put("matched", matched).put("onlyA", onlyA).put("onlyB", onlyB)
            .put("meanPx", mean(perFace)).put("p90Px", pct(perFace, 0.9)).put("maxPointPx", maxPx).put("nme", mean(nme))
    }

    /** Poses matched by the hip centre; mean distance over points the first runtime sees (visibility > 0.5). */
    private class PoseParity {
        val perPose = ArrayList<Double>(); var onlyA = 0; var onlyB = 0; var matched = 0
        fun add(a: List<Pose>, b: List<Pose>) {
            val used = BooleanArray(b.size)
            for (pa in a) {
                val ha = Pair((pa.x(23) + pa.x(24)) / 2.0, (pa.y(23) + pa.y(24)) / 2.0)
                val torso = hypot(pa.x(11) - pa.x(23), pa.y(11) - pa.y(23)).toDouble()
                var best = -1; var bestD = Double.MAX_VALUE
                b.forEachIndexed { k, pb ->
                    if (used[k]) return@forEachIndexed
                    val d = hypot(ha.first - (pb.x(23) + pb.x(24)) / 2.0, ha.second - (pb.y(23) + pb.y(24)) / 2.0)
                    if (d < bestD) { bestD = d; best = k }
                }
                if (best < 0 || bestD > max(torso, 50.0)) { onlyA++; continue }
                used[best] = true; matched++
                val pb = b[best]
                var sum = 0.0; var cnt = 0
                for (i in 0 until 33) if (pa.vis[i] > 0.5f) {
                    sum += hypot((pa.x(i) - pb.x(i)).toDouble(), (pa.y(i) - pb.y(i)).toDouble()); cnt++
                }
                if (cnt > 0) perPose += sum / cnt
            }
            onlyB += used.count { !it }
        }
        fun json() = JSONObject().put("matched", matched).put("onlyA", onlyA).put("onlyB", onlyB)
            .put("meanPx", mean(perPose)).put("p90Px", pct(perPose, 0.9))
    }

    /** IoU at 0.5 of person and hair, and mean absolute probability difference, on the 256 x 256 grid. */
    private class SegParity {
        val iouP = ArrayList<Double>(); val iouH = ArrayList<Double>(); val mae = ArrayList<Double>()
        fun add(a: Seg, b: Seg) {
            iouP += iou(a.person, b.person); iouH += iou(a.hair, b.hair)
            var s = 0.0
            for (i in a.person.indices) s += kotlin.math.abs(a.person[i] - b.person[i]) + kotlin.math.abs(a.hair[i] - b.hair[i])
            mae += s / (2 * a.person.size)
        }
        private fun iou(x: FloatArray, y: FloatArray): Double {
            var i = 0; var u = 0
            for (k in x.indices) { val p = x[k] > 0.5f; val q = y[k] > 0.5f; if (p && q) i++; if (p || q) u++ }
            return if (u == 0) 1.0 else i.toDouble() / u
        }
        fun json() = JSONObject().put("n", iouP.size).put("iouPerson", mean(iouP)).put("iouHair", mean(iouH))
            .put("minIouPerson", iouP.minOrNull() ?: JSONObject.NULL).put("minIouHair", iouH.minOrNull() ?: JSONObject.NULL)
            .put("mae", mean(mae))
    }

    // ---- Helpers -----------------------------------------------------------------------------------

    private fun loadScaled(f: File, long: Int): Bitmap {
        val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(f.absolutePath, o)
        var sample = 1
        while (max(o.outWidth, o.outHeight) / (sample * 2) >= long) sample *= 2
        val raw = BitmapFactory.decodeFile(
            f.absolutePath,
            BitmapFactory.Options().apply { inSampleSize = sample; inPreferredConfig = Bitmap.Config.ARGB_8888 },
        )
        val s = scaleTo(raw, long)
        if (s !== raw) raw.recycle()
        return s
    }

    private fun scaleTo(b: Bitmap, long: Int): Bitmap {
        val k = long.toFloat() / max(b.width, b.height)
        if (k == 1f) return b
        return Bitmap.createScaledBitmap(b, Math.round(b.width * k), Math.round(b.height * k), true)
    }

    private fun emit(o: JSONObject) {
        out.appendText(o.toString() + "\n")
        Log.i(TAG, o.toString().take(3000))
    }

    companion object {
        const val TAG = "VED33A"
        fun ms(t0: Long) = (System.nanoTime() - t0) / 1e6
        fun median(l: List<Double>) = pct(l, 0.5)
        fun pct(l: List<Double>, q: Double): Any {
            if (l.isEmpty()) return JSONObject.NULL
            val s = l.sorted()
            return s[min(s.size - 1, (q * (s.size - 1) + 0.5).toInt())]
        }
        fun mean(l: List<Double>): Any = if (l.isEmpty()) JSONObject.NULL else l.average()
        fun stats(l: List<Double>) = JSONObject().put("n", l.size).put("median", median(l)).put("p90", pct(l, 0.9))
            .put("mean", mean(l))
        fun centroid(p: FloatArray): Pair<Double, Double> {
            var x = 0.0; var y = 0.0
            for (i in 0 until p.size / 2) { x += p[2 * i]; y += p[2 * i + 1] }
            return Pair(x / (p.size / 2), y / (p.size / 2))
        }
    }
}
