package com.vecvel.danaview.spike.face

import android.graphics.Bitmap
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.framework.image.ByteBufferExtractor
import com.google.mediapipe.framework.image.MPImage
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.core.Delegate
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.facelandmarker.FaceLandmarker
import com.google.mediapipe.tasks.vision.imagesegmenter.ImageSegmenter
import com.google.mediapipe.tasks.vision.poselandmarker.PoseLandmarker
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel

/** MediaPipe Tasks Vision (CPU delegate) with the .task bundles and the .tflite segmenters as shipped. */
class MediaPipeCandidate(private val ctx: android.content.Context) : Candidate {
    override val name = "mediapipe"
    private var face: FaceLandmarker? = null
    private var pose: PoseLandmarker? = null
    private var seg: ImageSegmenter? = null
    private val extraSegs = HashMap<String, ImageSegmenter>()
    private var video = false

    private fun buf(f: File): ByteBuffer = RandomAccessFile(f, "r").use { it.channel.map(FileChannel.MapMode.READ_ONLY, 0, it.length()) }

    private fun base(f: File) = BaseOptions.builder().setModelAssetBuffer(buf(f)).setDelegate(Delegate.CPU).build()

    override fun open(models: File, video: Boolean, maxFaces: Int, maxPoses: Int) {
        closeTrackers()
        this.video = video
        val mode = if (video) RunningMode.VIDEO else RunningMode.IMAGE
        face = FaceLandmarker.createFromOptions(
            ctx,
            FaceLandmarker.FaceLandmarkerOptions.builder()
                .setBaseOptions(base(File(models, "face_landmarker.task")))
                .setRunningMode(mode).setNumFaces(maxFaces).build(),
        )
        val poseTask = System.getProperty("ved33a.pose", "pose_landmarks_full")!!.replace("pose_landmarks_", "pose_landmarker_")
        pose = PoseLandmarker.createFromOptions(
            ctx,
            PoseLandmarker.PoseLandmarkerOptions.builder()
                .setBaseOptions(base(File(models, "$poseTask.task")))
                .setRunningMode(mode).setNumPoses(maxPoses).build(),
        )
        if (seg == null) {
            seg = segmenter(File(models, "selfie_multiclass_256x256.tflite"))
            extraSegs["selfie_segmenter"] = segmenter(File(models, "selfie_segmenter.tflite"))
            extraSegs["hair_segmenter"] = segmenter(File(models, "hair_segmenter.tflite"))
        }
    }

    private fun segmenter(f: File) = ImageSegmenter.createFromOptions(
        ctx,
        ImageSegmenter.ImageSegmenterOptions.builder()
            .setBaseOptions(base(f)).setRunningMode(RunningMode.IMAGE)
            .setOutputConfidenceMasks(true).setOutputCategoryMask(false).build(),
    )

    private fun mp(frame: Bitmap): MPImage = BitmapImageBuilder(frame).build()

    override fun faces(frame: Bitmap, tsMs: Long): List<Face> {
        val img = mp(frame)
        val r = if (video) face!!.detectForVideo(img, tsMs) else face!!.detect(img)
        return r.faceLandmarks().map { lms ->
            val pts = FloatArray(lms.size * 2)
            lms.forEachIndexed { i, p -> pts[2 * i] = p.x() * frame.width; pts[2 * i + 1] = p.y() * frame.height }
            Face(pts, 1f)
        }
    }

    override fun poses(frame: Bitmap, tsMs: Long): List<Pose> {
        val img = mp(frame)
        val r = if (video) pose!!.detectForVideo(img, tsMs) else pose!!.detect(img)
        return r.landmarks().map { lms ->
            val pts = FloatArray(66)
            val vis = FloatArray(33)
            for (i in 0 until 33) {
                pts[2 * i] = lms[i].x() * frame.width
                pts[2 * i + 1] = lms[i].y() * frame.height
                vis[i] = lms[i].visibility().orElse(0f)
            }
            Pose(pts, vis)
        }
    }

    /** Confidence masks come back at frame size; they are sampled onto the same 256 x 256 grid the raw path uses. */
    override fun segment(frame: Bitmap): Seg {
        val masks = seg!!.segment(mp(frame)).confidenceMasks().get()
        val bg = floats(masks[0]); val hairM = floats(masks[1])
        val w = masks[0].width; val h = masks[0].height
        val n = 256
        val person = FloatArray(n * n)
        val hair = FloatArray(n * n)
        for (y in 0 until n) for (x in 0 until n) {
            val sx = ((x + 0.5f) * w / n).toInt().coerceIn(0, w - 1)
            val sy = ((y + 0.5f) * h / n).toInt().coerceIn(0, h - 1)
            person[y * n + x] = 1f - bg[sy * w + sx]
            hair[y * n + x] = hairM[sy * w + sx]
        }
        masks.forEach { it.close() }
        return Seg(n, n, person, hair)
    }

    private fun floats(m: MPImage): FloatArray {
        val b = ByteBufferExtractor.extract(m).order(ByteOrder.nativeOrder())
        b.rewind()
        val fb = b.asFloatBuffer()
        return FloatArray(fb.remaining()).also { fb.get(it) }
    }

    override fun extras() = listOf("selfie_segmenter", "hair_segmenter")

    override fun runExtra(which: String, frame: Bitmap) {
        extraSegs.getValue(which).segment(mp(frame)).confidenceMasks().ifPresent { l -> l.forEach { it.close() } }
    }

    private fun closeTrackers() {
        face?.close(); pose?.close()
        face = null; pose = null
    }

    override fun close() {
        closeTrackers()
        seg?.close(); seg = null
        extraSegs.values.forEach { it.close() }; extraSegs.clear()
    }
}
