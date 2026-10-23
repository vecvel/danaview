package com.vecvel.danaview.spike.face

import android.graphics.Bitmap
import java.io.File

/** 478 face landmarks as x,y pairs in frame pixels (z is dropped: parity is 2D). */
class Face(val pts: FloatArray, val score: Float) {
    val n get() = pts.size / 2
    fun x(i: Int) = pts[2 * i]
    fun y(i: Int) = pts[2 * i + 1]
}

/** 33 pose landmarks as x,y pairs in frame pixels, with visibility (0..1). */
class Pose(val pts: FloatArray, val vis: FloatArray) {
    fun x(i: Int) = pts[2 * i]
    fun y(i: Int) = pts[2 * i + 1]
}

/** Person and hair probabilities on a w x h grid that covers the whole frame. */
class Seg(val w: Int, val h: Int, val person: FloatArray, val hair: FloatArray)

/**
 * One candidate runtime with the face landmarker (478), pose landmarker (33) and person + hair
 * segmentation (selfie_multiclass_256x256). [open] (re)creates every graph: `video` selects the tracking
 * mode (detector only when fewer than `maxFaces` / `maxPoses` are tracked).
 */
interface Candidate {
    val name: String
    fun open(models: File, video: Boolean, maxFaces: Int, maxPoses: Int)
    fun faces(frame: Bitmap, tsMs: Long): List<Face>
    fun poses(frame: Bitmap, tsMs: Long): List<Pose>
    fun segment(frame: Bitmap): Seg
    /** Extra segmenters only this candidate can run (MediaPipe custom ops), timed but not compared. */
    fun extras(): List<String> = emptyList()
    fun runExtra(which: String, frame: Bitmap) {}
    fun close()
}

/** A bare model runner (LiteRT or ONNX Runtime): NHWC float input, every output flattened. */
interface RawModel {
    fun run(input: FloatArray): List<FloatArray>
    fun close()

    fun interface Factory {
        /** `stem` is the model name without extension, e.g. "face_detector". */
        fun open(models: File, stem: String): RawModel
    }
}
