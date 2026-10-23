package com.vecvel.danaview.spike.face

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** ONNX Runtime, CPU execution provider, 4 intra-op threads, full graph optimisation. */
class OrtModel(file: File) : RawModel {
    private val env = OrtEnvironment.getEnvironment()
    private val session: OrtSession = env.createSession(
        file.absolutePath,
        OrtSession.SessionOptions().apply {
            setIntraOpNumThreads(THREADS)
            setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
        },
    )
    private val inputName = session.inputNames.first()
    private val shape: LongArray = (session.inputInfo.getValue(inputName).info as ai.onnxruntime.TensorInfo).shape
        .map { if (it < 0) 1L else it }.toLongArray()
    private val buf = ByteBuffer.allocateDirect(shape.fold(4L) { a, b -> a * b }.toInt()).order(ByteOrder.nativeOrder())

    override fun run(input: FloatArray): List<FloatArray> {
        buf.rewind()
        val fb = buf.asFloatBuffer().apply { put(input); rewind() }
        OnnxTensor.createTensor(env, fb, shape).use { t ->
            session.run(mapOf(inputName to t)).use { res ->
                return (0 until res.size()).map { i ->
                    val o = (res.get(i) as OnnxTensor).floatBuffer
                    FloatArray(o.remaining()).also { o.get(it) }
                }
            }
        }
    }

    override fun close() = session.close()

    companion object {
        const val THREADS = 4
        val Factory = RawModel.Factory { models, stem -> OrtModel(File(models, "onnx/$stem.onnx")) }
    }
}
