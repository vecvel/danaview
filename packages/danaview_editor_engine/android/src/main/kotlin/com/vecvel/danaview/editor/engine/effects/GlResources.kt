// OWNER: AND-09
//
// GL object bookkeeping of the effects package (ARCH §13.3 "GL effects": resources are released on
// effect release). Every texture, framebuffer, buffer and program this package creates goes
// through [GlResources], which counts the live ones per kind; the GL leak test (androidTest
// effects/GlLeakTest) checks that the counts return to their baseline after create → draw →
// release cycles and that released names are no longer GL objects. Textures Media3 owns (effect
// input/output textures) are never created or deleted here.

package com.vecvel.danaview.editor.engine.effects

import android.opengl.GLES20
import android.opengl.GLES30
import java.nio.Buffer
import java.util.concurrent.atomic.AtomicInteger

/** Live GL object counts of this package. */
data class GlCounts(val textures: Int, val framebuffers: Int, val buffers: Int, val programs: Int) {
    /** Sum of all kinds. */
    val total: Int get() = textures + framebuffers + buffers + programs
}

/** Creates and deletes the package's GL objects and counts the live ones (file header). */
object GlResources {
    private val textures = AtomicInteger()
    private val framebuffers = AtomicInteger()
    private val buffers = AtomicInteger()
    private val programs = AtomicInteger()

    /** Current live counts. */
    fun counts(): GlCounts = GlCounts(textures.get(), framebuffers.get(), buffers.get(), programs.get())

    /**
     * A 2D texture of [width] × [height] with clamp-to-edge wrapping and [filter] (GL_LINEAR or
     * GL_NEAREST), allocated as [internalFormat]/[format]/[type] and filled from [pixels] (rows in
     * GL order, bottom row first) or left undefined when null.
     */
    fun createTexture(
        width: Int,
        height: Int,
        internalFormat: Int = GLES20.GL_RGBA,
        format: Int = GLES20.GL_RGBA,
        type: Int = GLES20.GL_UNSIGNED_BYTE,
        pixels: Buffer? = null,
        filter: Int = GLES20.GL_LINEAR,
    ): Int {
        require(width > 0 && height > 0) { "texture size ${width}x$height" }
        val ids = IntArray(1)
        GLES20.glGenTextures(1, ids, 0)
        val id = ids[0]
        check(id != 0) { "glGenTextures failed" }
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, id)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, filter)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, filter)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glPixelStorei(GLES20.GL_UNPACK_ALIGNMENT, 1)
        GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, internalFormat, width, height, 0, format, type, pixels)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
        textures.incrementAndGet()
        val err = GLES20.glGetError()
        if (err != GLES20.GL_NO_ERROR) {
            deleteTexture(id)
            throw IllegalStateException("glTexImage2D ${width}x$height format 0x${Integer.toHexString(internalFormat)} failed: 0x${Integer.toHexString(err)}")
        }
        return id
    }

    /** Deletes a texture created by [createTexture]. */
    fun deleteTexture(id: Int) {
        if (id == 0) return
        GLES20.glDeleteTextures(1, intArrayOf(id), 0)
        textures.decrementAndGet()
    }

    /** A framebuffer with [texture] as colour attachment 0 (checked complete). */
    fun createFramebuffer(texture: Int): Int {
        val ids = IntArray(1)
        GLES20.glGenFramebuffers(1, ids, 0)
        val fbo = ids[0]
        check(fbo != 0) { "glGenFramebuffers failed" }
        framebuffers.incrementAndGet()
        val previous = currentFramebuffer()
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo)
        GLES20.glFramebufferTexture2D(GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0, GLES20.GL_TEXTURE_2D, texture, 0)
        val status = GLES20.glCheckFramebufferStatus(GLES20.GL_FRAMEBUFFER)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, previous)
        if (status != GLES20.GL_FRAMEBUFFER_COMPLETE) {
            deleteFramebuffer(fbo)
            throw IllegalStateException("framebuffer incomplete: 0x${Integer.toHexString(status)}")
        }
        return fbo
    }

    /** Deletes a framebuffer created by [createFramebuffer]. */
    fun deleteFramebuffer(id: Int) {
        if (id == 0) return
        GLES20.glDeleteFramebuffers(1, intArrayOf(id), 0)
        framebuffers.decrementAndGet()
    }

    /** A GL_ARRAY_BUFFER filled with [data] (GL_STATIC_DRAW). */
    fun createArrayBuffer(data: Buffer, bytes: Int): Int {
        val ids = IntArray(1)
        GLES20.glGenBuffers(1, ids, 0)
        val id = ids[0]
        check(id != 0) { "glGenBuffers failed" }
        buffers.incrementAndGet()
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, id)
        GLES20.glBufferData(GLES20.GL_ARRAY_BUFFER, bytes, data, GLES20.GL_STATIC_DRAW)
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, 0)
        return id
    }

    /** Deletes a buffer created by [createArrayBuffer]. */
    fun deleteBuffer(id: Int) {
        if (id == 0) return
        GLES20.glDeleteBuffers(1, intArrayOf(id), 0)
        buffers.decrementAndGet()
    }

    /** Compiles and links a program; throws with the info log (no sources, no user content). */
    fun createProgram(vertexSource: String, fragmentSource: String, label: String): Int {
        val vs = compile(GLES20.GL_VERTEX_SHADER, vertexSource, label)
        val fs = try {
            compile(GLES20.GL_FRAGMENT_SHADER, fragmentSource, label)
        } catch (e: RuntimeException) {
            GLES20.glDeleteShader(vs)
            throw e
        }
        val program = GLES20.glCreateProgram()
        check(program != 0) { "glCreateProgram failed for $label" }
        GLES20.glAttachShader(program, vs)
        GLES20.glAttachShader(program, fs)
        GLES20.glBindAttribLocation(program, 0, "aPosition")
        GLES20.glLinkProgram(program)
        GLES20.glDeleteShader(vs)
        GLES20.glDeleteShader(fs)
        val status = IntArray(1)
        GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, status, 0)
        if (status[0] != GLES20.GL_TRUE) {
            val log = GLES20.glGetProgramInfoLog(program)
            GLES20.glDeleteProgram(program)
            throw IllegalStateException("link failed for $label: $log")
        }
        programs.incrementAndGet()
        return program
    }

    /** Deletes a program created by [createProgram]. */
    fun deleteProgram(id: Int) {
        if (id == 0) return
        GLES20.glDeleteProgram(id)
        programs.decrementAndGet()
    }

    /** The currently bound framebuffer. */
    fun currentFramebuffer(): Int {
        val v = IntArray(1)
        GLES20.glGetIntegerv(GLES20.GL_FRAMEBUFFER_BINDING, v, 0)
        return v[0]
    }

    /** The current viewport `[x, y, w, h]`. */
    fun currentViewport(): IntArray {
        val v = IntArray(4)
        GLES20.glGetIntegerv(GLES20.GL_VIEWPORT, v, 0)
        return v
    }

    private fun compile(type: Int, source: String, label: String): Int {
        val shader = GLES20.glCreateShader(type)
        check(shader != 0) { "glCreateShader failed for $label" }
        GLES20.glShaderSource(shader, source)
        GLES20.glCompileShader(shader)
        val status = IntArray(1)
        GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)
        if (status[0] != GLES20.GL_TRUE) {
            val log = GLES20.glGetShaderInfoLog(shader)
            GLES20.glDeleteShader(shader)
            val kind = if (type == GLES20.GL_VERTEX_SHADER) "vertex" else "fragment"
            throw IllegalStateException("$kind shader compile failed for $label: $log")
        }
        return shader
    }
}

/** A texture with a framebuffer: an offscreen render target of [width] × [height]. */
class GlTarget private constructor(val texture: Int, val framebuffer: Int, val width: Int, val height: Int, private val confinement: GlThreadConfinement) {
    private var released = false

    /** Binds the framebuffer and sets the viewport to the whole target. */
    fun bind() {
        confinement.check()
        check(!released) { "target released" }
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, framebuffer)
        GLES20.glViewport(0, 0, width, height)
    }

    /** Deletes the framebuffer and texture. */
    fun release() {
        confinement.check()
        if (released) return
        released = true
        GlResources.deleteFramebuffer(framebuffer)
        GlResources.deleteTexture(texture)
    }

    companion object {
        /** An RGBA8 target (the format of Media3's effect textures). */
        fun rgba8(width: Int, height: Int): GlTarget = create(width, height, GLES20.GL_RGBA, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE)

        /** An RGBA32F target (tests; needs ES 3 and EXT_color_buffer_float). */
        fun rgba32f(width: Int, height: Int): GlTarget = create(width, height, GLES30.GL_RGBA32F, GLES20.GL_RGBA, GLES20.GL_FLOAT)

        /** A target of the given texture format. */
        fun create(width: Int, height: Int, internalFormat: Int, format: Int, type: Int): GlTarget {
            val confinement = GlThreadConfinement()
            val tex = GlResources.createTexture(width, height, internalFormat, format, type, null, GLES20.GL_LINEAR)
            val fbo = try {
                GlResources.createFramebuffer(tex)
            } catch (e: RuntimeException) {
                GlResources.deleteTexture(tex)
                throw e
            }
            return GlTarget(tex, fbo, width, height, confinement)
        }
    }
}

/** Capabilities of the current GL context, read once per [ShaderPrograms]. */
data class GlCaps(
    /** Major version of the context (2 or 3). */
    val majorVersion: Int,
    /** GL_MAX_TEXTURE_SIZE. */
    val maxTextureSize: Int,
    /** GL_EXT_disjoint_timer_query is exposed (GPU timer queries). */
    val timerQuery: Boolean,
    /** Float colour buffers can be rendered to (EXT_color_buffer_float). */
    val floatColorBuffer: Boolean,
) {
    /** Whether ES 3 features (RGBA16F textures, GLES30 calls) are available. */
    val isEs3: Boolean get() = majorVersion >= 3

    companion object {
        /** Reads the capabilities of the current context. */
        fun query(): GlCaps {
            val version = GLES20.glGetString(GLES20.GL_VERSION) ?: ""
            val major = Regex("OpenGL ES (\\d+)").find(version)?.groupValues?.get(1)?.toIntOrNull() ?: 2
            val ext = GLES20.glGetString(GLES20.GL_EXTENSIONS) ?: ""
            val max = IntArray(1)
            GLES20.glGetIntegerv(GLES20.GL_MAX_TEXTURE_SIZE, max, 0)
            return GlCaps(
                majorVersion = major,
                maxTextureSize = if (max[0] > 0) max[0] else 2048,
                timerQuery = "GL_EXT_disjoint_timer_query" in ext,
                floatColorBuffer = "GL_EXT_color_buffer_float" in ext,
            )
        }
    }
}
