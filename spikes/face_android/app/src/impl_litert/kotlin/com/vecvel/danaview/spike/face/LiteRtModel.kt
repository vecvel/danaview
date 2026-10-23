package com.vecvel.danaview.spike.face

import org.tensorflow.lite.Interpreter
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.nio.channels.FileChannel

/** LiteRT Interpreter (CPU, XNNPACK on by default), 4 threads, model memory-mapped from the pack. */
class LiteRtModel(file: File) : RawModel {
    private val raf = RandomAccessFile(file, "r")
    private val interp = Interpreter(
        raf.channel.map(FileChannel.MapMode.READ_ONLY, 0, raf.length()),
        Interpreter.Options().setNumThreads(THREADS),
    )
    private val input: ByteBuffer = direct(interp.getInputTensor(0).numElements())
    private val outputs: Map<Int, ByteBuffer> =
        (0 until interp.outputTensorCount).associateWith { direct(interp.getOutputTensor(it).numElements()) }

    override fun run(input: FloatArray): List<FloatArray> {
        this.input.rewind()
        this.input.asFloatBuffer().put(input)
        outputs.values.forEach { it.rewind() }
        interp.runForMultipleInputsOutputs(arrayOf<Any>(this.input), outputs)
        return outputs.values.map { b ->
            b.rewind()
            val fb: FloatBuffer = b.asFloatBuffer()
            FloatArray(fb.remaining()).also { fb.get(it) }
        }
    }

    override fun close() {
        interp.close()
        raf.close()
    }

    companion object {
        const val THREADS = 4
        val Factory = RawModel.Factory { models, stem -> LiteRtModel(File(models, "tflite/$stem.tflite")) }
        private fun direct(floats: Int) = ByteBuffer.allocateDirect(floats * 4).order(ByteOrder.nativeOrder())
    }
}
