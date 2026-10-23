package com.vecvel.danaview.spike.face

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import java.io.File
import kotlin.math.atan2
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * The MediaPipe face / pose landmarker graphs re-implemented over bare models, for runtimes that only
 * run a model (LiteRT Interpreter, ONNX Runtime). Follows the MediaPipe calculators: SSD anchors,
 * weighted NMS, rotated ROI from detection keypoints (face: eyes at 0 deg, x1.5; pose: hip centre and
 * scale point at 90 deg, x1.25), landmark projection, and ROI from the previous landmarks in video mode.
 * All geometry is in frame pixels.
 */
class RawPipeline(override val name: String, private val factory: RawModel.Factory) : Candidate {
    private var faceDet: RawModel? = null
    private var faceLm: RawModel? = null
    private var poseDet: RawModel? = null
    private var poseLm: RawModel? = null
    private var seg: RawModel? = null
    private var video = false
    private var maxFaces = 1
    private var maxPoses = 1
    private var faceRois = listOf<Roi>()
    private var poseRois = listOf<Roi>()
    private val paint = Paint(Paint.FILTER_BITMAP_FLAG)

    override fun open(models: File, video: Boolean, maxFaces: Int, maxPoses: Int) {
        if (faceDet == null) {
            faceDet = factory.open(models, "face_detector")
            faceLm = factory.open(models, "face_landmarks_detector")
            poseDet = factory.open(models, "pose_detector")
            poseLm = factory.open(models, System.getProperty("ved33a.pose", "pose_landmarks_full")!!)
            seg = factory.open(models, "selfie_multiclass")
        }
        this.video = video
        this.maxFaces = maxFaces
        this.maxPoses = maxPoses
        faceRois = emptyList()
        poseRois = emptyList()
    }

    override fun close() {
        listOf(faceDet, faceLm, poseDet, poseLm, seg).forEach { it?.close() }
        faceDet = null; faceLm = null; poseDet = null; poseLm = null; seg = null
    }

    /** Rotated square region: centre, side and rotation (radians) in frame pixels. */
    class Roi(val cx: Float, val cy: Float, val size: Float, val rot: Float)

    private class Det(
        var score: Float,
        var x0: Float, var y0: Float, var x1: Float, var y1: Float, // box in frame pixels
        val kp: FloatArray,
    )

    // ---- Face -------------------------------------------------------------------------------------

    override fun faces(frame: Bitmap, tsMs: Long): List<Face> {
        val rois = ArrayList<Roi>()
        if (video) rois += faceRois
        if (!video || rois.size < maxFaces) {
            val dets = detect(frame, faceDet!!, 128, FACE_ANCHORS, 6, 0.5f)
            for (d in dets) {
                if (rois.size >= maxFaces) break
                val roi = faceRoiFromDet(d)
                if (rois.none { overlap(it, roi) > 0.5f }) rois += roi
            }
        }
        val out = ArrayList<Face>()
        val next = ArrayList<Roi>()
        for (roi in rois) {
            val o = faceLm!!.run(crop(frame, roi, 256, 0f, 1f))
            val lm = o.first { it.size == 1434 }
            val flag = sigmoid(o.first { it.size == 1 }[0])
            if (flag < 0.5f) continue
            val pts = FloatArray(478 * 2)
            for (i in 0 until 478) project(roi, lm[3 * i], lm[3 * i + 1], 256, pts, i)
            out += Face(pts, flag)
            next += faceRoiFromLandmarks(pts)
        }
        faceRois = next
        return out
    }

    private fun faceRoiFromDet(d: Det): Roi {
        val rot = rotation(d.kp[0], d.kp[1], d.kp[2], d.kp[3], 0f)
        val side = max(d.x1 - d.x0, d.y1 - d.y0) * 1.5f
        return Roi((d.x0 + d.x1) / 2, (d.y0 + d.y1) / 2, side, rot)
    }

    private fun faceRoiFromLandmarks(p: FloatArray): Roi {
        var x0 = Float.MAX_VALUE; var y0 = Float.MAX_VALUE; var x1 = -Float.MAX_VALUE; var y1 = -Float.MAX_VALUE
        for (i in 0 until p.size / 2) {
            x0 = min(x0, p[2 * i]); x1 = max(x1, p[2 * i]); y0 = min(y0, p[2 * i + 1]); y1 = max(y1, p[2 * i + 1])
        }
        val rot = rotation(p[2 * 33], p[2 * 33 + 1], p[2 * 263], p[2 * 263 + 1], 0f)
        return Roi((x0 + x1) / 2, (y0 + y1) / 2, max(x1 - x0, y1 - y0) * 1.5f, rot)
    }

    // ---- Pose -------------------------------------------------------------------------------------

    override fun poses(frame: Bitmap, tsMs: Long): List<Pose> {
        val rois = ArrayList<Roi>()
        if (video) rois += poseRois
        if (!video || rois.size < maxPoses) {
            val dets = detect(frame, poseDet!!, 224, POSE_ANCHORS, 4, 0.5f)
            for (d in dets) {
                if (rois.size >= maxPoses) break
                val roi = alignedRoi(d.kp[0], d.kp[1], d.kp[2], d.kp[3])
                if (rois.none { overlap(it, roi) > 0.5f }) rois += roi
            }
        }
        val out = ArrayList<Pose>()
        val next = ArrayList<Roi>()
        for (roi in rois) {
            // MediaPipe crops pose ROIs with BORDER_REPLICATE (the ROI often reaches past the frame).
            val o = poseLm!!.run(cropReplicate(frame, roi, 256))
            val lm = o.first { it.size == 195 }.copyOf()
            refineFromHeatmap(lm, o.first { it.size == 64 * 64 * 39 })
            val flag = o.first { it.size == 1 }[0] // already a probability in this model
            if (flag < 0.5f) continue
            val all = FloatArray(39 * 2)
            for (i in 0 until 39) project(roi, lm[5 * i], lm[5 * i + 1], 256, all, i)
            val vis = FloatArray(33) { sigmoid(lm[5 * it + 3]) }
            out += Pose(all.copyOf(66), vis)
            next += alignedRoi(all[66], all[67], all[68], all[69])
        }
        poseRois = next
        return out
    }

    /**
     * MediaPipe RefineLandmarksFromHeatmap (kernel 7, min confidence 0.5): each landmark moves to the
     * confidence-weighted mean of the 7 x 7 heatmap cells around it.
     */
    private fun refineFromHeatmap(lm: FloatArray, hm: FloatArray) {
        val n = 64; val ch = 39
        for (i in 0 until ch) {
            val cc = (lm[5 * i] / 256f * n).toInt(); val cr = (lm[5 * i + 1] / 256f * n).toInt()
            if (cc < 0 || cc >= n || cr < 0 || cr >= n) continue
            var sum = 0f; var wc = 0f; var wr = 0f; var mx = 0f
            for (r in max(0, cr - 3)..min(n - 1, cr + 3)) for (c in max(0, cc - 3)..min(n - 1, cc + 3)) {
                val conf = sigmoid(hm[(r * n + c) * ch + i])
                sum += conf; wc += c * conf; wr += r * conf; mx = max(mx, conf)
            }
            if (mx < 0.5f || sum <= 0f) continue
            lm[5 * i] = wc / sum / n * 256f
            lm[5 * i + 1] = wr / sum / n * 256f
        }
    }

    /** MediaPipe AlignmentPointsRects: centre = start, side = 2 x |end - start|, 90 deg target, x1.25. */
    private fun alignedRoi(x0: Float, y0: Float, x1: Float, y1: Float): Roi {
        val side = 2f * hypot(x1 - x0, y1 - y0) * 1.25f
        return Roi(x0, y0, side, rotation(x0, y0, x1, y1, (Math.PI / 2).toFloat()))
    }

    // ---- Segmentation -----------------------------------------------------------------------------

    override fun segment(frame: Bitmap): Seg {
        val o = seg!!.run(stretch(frame, 256, -1f, 1f)).first()
        val n = 256 * 256
        val person = FloatArray(n)
        val hair = FloatArray(n)
        for (i in 0 until n) {
            var m = o[6 * i]
            for (c in 1 until 6) m = max(m, o[6 * i + c])
            var sum = 0f
            val e0 = exp(o[6 * i] - m)
            sum += e0
            val e1 = exp(o[6 * i + 1] - m)
            sum += e1
            for (c in 2 until 6) sum += exp(o[6 * i + c] - m)
            person[i] = 1f - e0 / sum
            hair[i] = e1 / sum
        }
        return Seg(256, 256, person, hair)
    }

    // ---- Shared geometry --------------------------------------------------------------------------

    /** Letterboxed SSD detector, decoded to frame pixels, weighted NMS at IoU 0.3. */
    private fun detect(frame: Bitmap, model: RawModel, size: Int, anchors: FloatArray, nKp: Int, thr: Float): List<Det> {
        val scale = min(size.toFloat() / frame.width, size.toFloat() / frame.height)
        val padX = (size - frame.width * scale) / 2
        val padY = (size - frame.height * scale) / 2
        val m = Matrix().apply { postScale(scale, scale); postTranslate(padX, padY) }
        val o = model.run(draw(frame, m, size, -1f, 1f))
        val nA = anchors.size / 2
        val cls = o.first { it.size == nA }
        val reg = o.first { it.size != nA }
        val stride = reg.size / nA
        val cands = ArrayList<Det>()
        for (i in 0 until nA) {
            val s = sigmoid(cls[i].coerceIn(-100f, 100f))
            if (s < thr) continue
            val ax = anchors[2 * i]; val ay = anchors[2 * i + 1]
            val b = i * stride
            fun px(v: Float) = (v * size - padX) / scale
            fun py(v: Float) = (v * size - padY) / scale
            val cx = reg[b] / size + ax; val cy = reg[b + 1] / size + ay
            val w = reg[b + 2] / size; val h = reg[b + 3] / size
            val kp = FloatArray(nKp * 2)
            for (k in 0 until nKp) {
                kp[2 * k] = px(reg[b + 4 + 2 * k] / size + ax)
                kp[2 * k + 1] = py(reg[b + 5 + 2 * k] / size + ay)
            }
            cands += Det(s, px(cx - w / 2), py(cy - h / 2), px(cx + w / 2), py(cy + h / 2), kp)
        }
        return weightedNms(cands, 0.3f)
    }

    private fun weightedNms(input: List<Det>, iouThr: Float): List<Det> {
        val left = input.sortedByDescending { it.score }.toMutableList()
        val out = ArrayList<Det>()
        while (left.isNotEmpty()) {
            val top = left[0]
            val group = left.filter { iou(top, it) > iouThr }
            left.removeAll(group)
            val wsum = group.sumOf { it.score.toDouble() }.toFloat()
            fun avg(f: (Det) -> Float) = group.sumOf { (f(it) * it.score).toDouble() }.toFloat() / wsum
            val kp = FloatArray(top.kp.size) { k -> avg { it.kp[k] } }
            out += Det(top.score, avg { it.x0 }, avg { it.y0 }, avg { it.x1 }, avg { it.y1 }, kp)
        }
        return out
    }

    private fun iou(a: Det, b: Det): Float {
        val iw = min(a.x1, b.x1) - max(a.x0, b.x0)
        val ih = min(a.y1, b.y1) - max(a.y0, b.y0)
        if (iw <= 0 || ih <= 0) return 0f
        val inter = iw * ih
        return inter / ((a.x1 - a.x0) * (a.y1 - a.y0) + (b.x1 - b.x0) * (b.y1 - b.y0) - inter)
    }

    /** IoU of the axis-aligned squares of two ROIs (MediaPipe's association of tracked and new rects). */
    private fun overlap(a: Roi, b: Roi): Float {
        val da = Det(1f, a.cx - a.size / 2, a.cy - a.size / 2, a.cx + a.size / 2, a.cy + a.size / 2, FloatArray(0))
        val db = Det(1f, b.cx - b.size / 2, b.cy - b.size / 2, b.cx + b.size / 2, b.cy + b.size / 2, FloatArray(0))
        return iou(da, db)
    }

    /** Landmark (lx, ly) in crop pixels -> frame pixels. */
    private fun project(roi: Roi, lx: Float, ly: Float, size: Int, out: FloatArray, i: Int) {
        val u = (lx / size - 0.5f) * roi.size
        val v = (ly / size - 0.5f) * roi.size
        val c = cos(roi.rot); val s = sin(roi.rot)
        out[2 * i] = roi.cx + c * u - s * v
        out[2 * i + 1] = roi.cy + s * u + c * v
    }

    private fun crop(frame: Bitmap, roi: Roi, size: Int, lo: Float, hi: Float): FloatArray {
        val m = Matrix().apply {
            postTranslate(-roi.cx, -roi.cy)
            postRotate(-Math.toDegrees(roi.rot.toDouble()).toFloat())
            postScale(size / roi.size, size / roi.size)
            postTranslate(size / 2f, size / 2f)
        }
        return draw(frame, m, size, lo, hi)
    }

    private var framePx = IntArray(0)
    private var frameKey: Bitmap? = null
    private var frameGen = -1

    /** Rotated crop with edge replication and bilinear sampling, done by hand (Canvas has no clamp mode). */
    private fun cropReplicate(frame: Bitmap, roi: Roi, size: Int): FloatArray {
        val w = frame.width; val h = frame.height
        if (frameKey !== frame || frameGen != frame.generationId || framePx.size != w * h) {
            if (framePx.size != w * h) framePx = IntArray(w * h)
            frame.getPixels(framePx, 0, w, 0, 0, w, h)
            frameKey = frame; frameGen = frame.generationId
        }
        val c = cos(roi.rot); val sn = sin(roi.rot); val k = roi.size / size
        val out = FloatArray(size * size * 3)
        for (j in 0 until size) for (i in 0 until size) {
            val u = (i + 0.5f - size / 2f) * k; val v = (j + 0.5f - size / 2f) * k
            val x = (roi.cx + c * u - sn * v - 0.5f).coerceIn(0f, (w - 1).toFloat())
            val y = (roi.cy + sn * u + c * v - 0.5f).coerceIn(0f, (h - 1).toFloat())
            val x0 = x.toInt(); val y0 = y.toInt(); val x1 = min(x0 + 1, w - 1); val y1 = min(y0 + 1, h - 1)
            val fx = x - x0; val fy = y - y0
            val p00 = framePx[y0 * w + x0]; val p10 = framePx[y0 * w + x1]; val p01 = framePx[y1 * w + x0]; val p11 = framePx[y1 * w + x1]
            val o = 3 * (j * size + i)
            for (ch in 0 until 3) {
                val sh = 16 - 8 * ch
                val a = ((p00 shr sh) and 0xFF) * (1 - fx) + ((p10 shr sh) and 0xFF) * fx
                val b = ((p01 shr sh) and 0xFF) * (1 - fx) + ((p11 shr sh) and 0xFF) * fx
                out[o + ch] = (a * (1 - fy) + b * fy) / 255f
            }
        }
        return out
    }

    private fun stretch(frame: Bitmap, size: Int, lo: Float, hi: Float): FloatArray {
        val m = Matrix().apply { postScale(size.toFloat() / frame.width, size.toFloat() / frame.height) }
        return draw(frame, m, size, lo, hi)
    }

    private val scratch = HashMap<Int, Pair<Bitmap, IntArray>>()

    /** Draws `frame` through `m` into a size x size tensor (NHWC, RGB) scaled to [lo, hi]; outside is black. */
    private fun draw(frame: Bitmap, m: Matrix, size: Int, lo: Float, hi: Float): FloatArray {
        val (bmp, px) = scratch.getOrPut(size) { Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888) to IntArray(size * size) }
        bmp.eraseColor(0xFF000000.toInt())
        Canvas(bmp).drawBitmap(frame, m, paint)
        bmp.getPixels(px, 0, size, 0, 0, size, size)
        val k = (hi - lo) / 255f
        val out = FloatArray(size * size * 3)
        for (i in px.indices) {
            val c = px[i]
            out[3 * i] = ((c shr 16) and 0xFF) * k + lo
            out[3 * i + 1] = ((c shr 8) and 0xFF) * k + lo
            out[3 * i + 2] = (c and 0xFF) * k + lo
        }
        return out
    }

    companion object {
        val FACE_ANCHORS = ssdAnchors(128, intArrayOf(8, 16, 16, 16))
        val POSE_ANCHORS = ssdAnchors(224, intArrayOf(8, 16, 32, 32, 32))

        /** MediaPipe SsdAnchorsCalculator, fixed anchor size, aspect 1.0 + interpolated scale per layer. */
        fun ssdAnchors(input: Int, strides: IntArray): FloatArray {
            val out = ArrayList<Float>()
            var layer = 0
            while (layer < strides.size) {
                var perCell = 0
                var last = layer
                while (last < strides.size && strides[last] == strides[layer]) { perCell += 2; last++ }
                val fm = ceil(input / strides[layer].toFloat()).toInt()
                for (y in 0 until fm) for (x in 0 until fm) repeat(perCell) {
                    out += (x + 0.5f) / fm; out += (y + 0.5f) / fm
                }
                layer = last
            }
            return out.toFloatArray()
        }

        fun sigmoid(v: Float) = 1f / (1f + exp(-v))

        /** MediaPipe DetectionsToRects rotation: target - atan2(-(y1 - y0), x1 - x0), normalised to [-pi, pi). */
        fun rotation(x0: Float, y0: Float, x1: Float, y1: Float, target: Float): Float {
            val r = target - atan2(-(y1 - y0), x1 - x0)
            val twoPi = (2 * Math.PI).toFloat()
            return r - twoPi * floor((r + Math.PI.toFloat()) / twoPi)
        }
    }
}
