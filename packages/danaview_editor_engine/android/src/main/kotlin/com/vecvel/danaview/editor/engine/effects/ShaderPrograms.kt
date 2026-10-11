// OWNER: AND-09
//
// ShaderPrograms: the small GL API of the render math (ARCH §11.6, §13.3 "GL effects") shared by
// the Media3 effects of this package (LayerLookEffect, SeparableBlurEffect, LayerPlaceEffect,
// SpriteBandEffect), AND-17's LayerCompositorGl / PausedFrameRenderer and AND-16's compositor.
// One instance per EGL context ([acquire] / [release], reference counted), confined to the GL thread
// that created it (GlThreadPolicy). Programs compile lazily from the dv_*.glsl assets.
//
// Conventions of every pass:
// - It draws a full-screen quad into the CURRENTLY BOUND framebuffer; the caller binds the target
//   and sets the viewport to its whole size (Media3's BaseGlShaderProgram does this before
//   drawFrame; [GlTarget.bind] does it for our own targets).
// - Textures are GL-oriented (row 0 = bottom of the image, Media3's convention); positions inside
//   the shaders are top-down pixel centres, so outputs are GL-oriented too. A source with another
//   orientation passes its own [SourceTexture.transform].
// - Look and blur outputs are premultiplied; place and sprite outputs are STRAIGHT alpha and
//   transparent outside the layer, ready for the compositor blend [setSourceOverBlend]
//   (glBlendFuncSeparate(SRC_ALPHA, ONE_MINUS_SRC_ALPHA, ONE, ONE_MINUS_SRC_ALPHA) = premultiplied
//   source-over of a straight source onto a premultiplied destination).
// Typical AND-17 use, on danaview-gl with its EGL context current:
//   val programs = ShaderPrograms.acquire(context); val renderer = LayerRenderer(programs)
//   compositeTarget.bind(); programs.clearOpaque(bg)
//   for (layer in bottomToTop) renderer.draw(LayerFrames.frame(...), source, lut, sprite, compositeTarget, blend = true)
//   renderer.release(); programs.release()

package com.vecvel.danaview.editor.engine.effects

import android.content.Context
import android.opengl.EGL14
import android.opengl.EGLContext
import android.opengl.GLES11Ext
import android.opengl.GLES20
import com.vecvel.danaview.editor.engine.plan.PlanMaskShape
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.EnumMap
import java.util.concurrent.atomic.AtomicLong

/** A source texture of the look pass. [transform] maps top-down normalized source positions to texture coordinates (column-major mat3). */
data class SourceTexture(
    val id: Int,
    val width: Int,
    val height: Int,
    val target: Int = GLES20.GL_TEXTURE_2D,
    val transform: FloatArray = GL_ORIENTED,
    val premultiplied: Boolean = false,
) {
    override fun equals(other: Any?): Boolean = other is SourceTexture && other.id == id && other.width == width && other.height == height &&
        other.target == target && other.transform.contentEquals(transform) && other.premultiplied == premultiplied

    override fun hashCode(): Int = ((id * 31 + width) * 31 + height) * 31 + target

    companion object {
        /** Media3 / GL convention: row 0 = bottom (`tc = (u, 1 − v)`). */
        val GL_ORIENTED: FloatArray = floatArrayOf(1f, 0f, 0f, 0f, -1f, 0f, 0f, 1f, 1f)

        /** Row 0 = top (`tc = (u, v)`), e.g. EGLImages of HardwareBuffers. */
        val TOP_DOWN: FloatArray = floatArrayOf(1f, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 1f)

        /** OES textures sample through samplerExternalOES. */
        const val EXTERNAL_OES: Int = GLES11Ext.GL_TEXTURE_EXTERNAL_OES
    }
}

/** Clear / draw counters of one [ShaderPrograms] (the "a gated frame costs one clear" check). */
class GlFrameStats {
    private val clears = AtomicLong()
    private val draws = AtomicLong()

    /** glClear calls so far. */
    val clearCount: Long get() = clears.get()

    /** Draw calls (passes) so far. */
    val drawCount: Long get() = draws.get()

    internal fun clear() = clears.incrementAndGet()

    internal fun draw() = draws.incrementAndGet()
}

/** A linked program with cached uniform locations. */
class GlShader internal constructor(val id: Int, val label: String) {
    private val locations = HashMap<String, Int>()

    /** glUseProgram. */
    fun use() = GLES20.glUseProgram(id)

    /** The location of [name] (−1 when inactive; setting it is then a no-op). */
    fun location(name: String): Int = locations.getOrPut(name) { GLES20.glGetUniformLocation(id, name) }

    fun f1(name: String, v: Float) = GLES20.glUniform1f(location(name), v)
    fun f2(name: String, x: Float, y: Float) = GLES20.glUniform2f(location(name), x, y)
    fun f3(name: String, x: Float, y: Float, z: Float) = GLES20.glUniform3f(location(name), x, y, z)
    fun f4(name: String, x: Float, y: Float, z: Float, w: Float) = GLES20.glUniform4f(location(name), x, y, z, w)
    fun f4v(name: String, values: FloatArray, count: Int) = GLES20.glUniform4fv(location(name), count, values, 0)
    fun mat3(name: String, m: FloatArray) = GLES20.glUniformMatrix3fv(location(name), 1, false, m, 0)

    /** Binds [texture] of [target] to [unit] and points sampler [name] at it. */
    fun sampler(name: String, unit: Int, target: Int, texture: Int) {
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0 + unit)
        GLES20.glBindTexture(target, texture)
        GLES20.glUniform1i(location(name), unit)
    }
}

/** The effects' GL programs for one EGL context (file header). */
class ShaderPrograms private constructor(private val read: (String) -> String, private val key: EGLContext?) {
    private val confinement = GlThreadConfinement()
    private val programs = EnumMap<ShaderSources.Program, GlShader>(ShaderSources.Program::class.java)
    private val quad: Int
    private var refs = 1
    private var released = false

    /** Capabilities of this context. */
    val caps: GlCaps = GlCaps.query()

    /** Clear / draw counters. */
    val stats = GlFrameStats()

    /** The GL thread that owns this instance. */
    val threadName: String get() = confinement.ownerName

    init {
        val data = ByteBuffer.allocateDirect(QUAD.size * 4).order(ByteOrder.nativeOrder())
        data.asFloatBuffer().put(QUAD)
        quad = GlResources.createArrayBuffer(data, QUAD.size * 4)
    }

    /** Throws unless called on the owning GL thread with the instance alive. */
    fun checkThread() {
        confinement.check()
        check(!released) { "ShaderPrograms released" }
    }

    /** The compiled [program] (compiled on first use). */
    fun program(program: ShaderSources.Program): GlShader {
        checkThread()
        return programs.getOrPut(program) {
            val id = GlResources.createProgram(ShaderSources.vertexSource(read), ShaderSources.fragmentSource(program, read), program.name)
            GlShader(id, program.name)
        }
    }

    /** Compiles every program now (startup cost measurement, tests). */
    fun compileAll() {
        for (p in ShaderSources.Program.values()) {
            if (p.externalTexture && !caps.isEs3) continue
            program(p)
        }
    }

    /** Clears the bound framebuffer to transparent (the early exit: one clear, no sampling). */
    fun clearTransparent() {
        checkThread()
        GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
        GLES20.glClearColor(0f, 0f, 0f, 0f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        stats.clear()
    }

    /** Clears the bound framebuffer to the opaque straight ARGB [argb] (the canvas `bg`; alpha ignored). */
    fun clearOpaque(argb: Int) {
        checkThread()
        GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
        GLES20.glClearColor(((argb shr 16) and 0xFF) / 255f, ((argb shr 8) and 0xFF) / 255f, (argb and 0xFF) / 255f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        stats.clear()
    }

    /** Enables (or disables) the compositor blend: straight source over premultiplied destination. */
    fun setSourceOverBlend(enabled: Boolean) {
        checkThread()
        if (enabled) {
            GLES20.glEnable(GLES20.GL_BLEND)
            GLES20.glBlendFuncSeparate(GLES20.GL_SRC_ALPHA, GLES20.GL_ONE_MINUS_SRC_ALPHA, GLES20.GL_ONE, GLES20.GL_ONE_MINUS_SRC_ALPHA)
        } else {
            GLES20.glDisable(GLES20.GL_BLEND)
        }
    }

    /**
     * dv_look: the [look].rasterW × rasterH layer raster into the top-left of the bound framebuffer
     * of height [targetHeight] (default: exactly the raster). The caller sets the viewport to
     * `(0, targetHeight − rasterH, rasterW, rasterH)` (a whole-target viewport when they match).
     */
    fun drawLook(source: SourceTexture, look: LookFrame, lut: LutTexture?, targetHeight: Int = look.rasterH) {
        val external = source.target == SourceTexture.EXTERNAL_OES
        val sh = program(if (external) ShaderSources.Program.LOOK_EXTERNAL else ShaderSources.Program.LOOK_2D)
        sh.use()
        setLookUniforms(sh, source, look, lut, targetHeight)
        drawQuad()
    }

    /**
     * dv_look with DV_REVEAL (SpriteBandEffect pass 1): [sprite] resampled onto a [rasterW] ×
     * [rasterH] raster (each texel the average of ≤ 8 × 8 taps over its sprite footprint, a tap
     * dropped when its glyph ≥ [revealShown]), premultiplied, into the TOP-LEFT [rasterW] × [rasterH]
     * px of the bound framebuffer of height [targetHeight]. The caller sets the viewport to
     * `(0, targetHeight − rasterH, rasterW, rasterH)`.
     */
    fun drawSpriteRaster(sprite: SpriteTexture, rasterW: Int, rasterH: Int, targetHeight: Int, revealShown: Double?) {
        val sh = program(ShaderSources.Program.SPRITE_RASTER)
        sh.use()
        val stepX = sprite.width.toDouble() / rasterW
        val stepY = sprite.height.toDouble() / rasterH
        val look = LookFrame(rasterW, rasterH, 0.0, 0.0, stepX, stepY, LayerFrames.taps(stepX), LayerFrames.taps(stepY), null, null, null, 0.0, false)
        setLookUniforms(sh, SourceTexture(sprite.color, sprite.width, sprite.height, premultiplied = true), look, null, targetHeight)
        sh.sampler("uGlyphs", 2, GLES20.GL_TEXTURE_2D, sprite.glyphs)
        if (revealShown != null && sprite.hasGlyphs) sh.f2("uReveal", 1f, revealShown.toFloat()) else sh.f2("uReveal", 0f, 0f)
        drawQuad()
    }

    private fun setLookUniforms(sh: GlShader, source: SourceTexture, look: LookFrame, lut: LutTexture?, outHeight: Int) {
        GLES20.glDisable(GLES20.GL_BLEND)
        GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
        sh.sampler("uTex", 0, source.target, source.id)
        sh.mat3("uSrcXform", source.transform)
        sh.f2("uSrcSize", source.width.toFloat(), source.height.toFloat())
        sh.f1("uSrcPremultiplied", if (source.premultiplied) 1f else 0f)
        sh.f4("uCrop", look.cropX0.toFloat(), look.cropY0.toFloat(), look.stepX.toFloat(), look.stepY.toFloat())
        sh.f2("uOutSize", look.rasterW.toFloat(), outHeight.toFloat())
        sh.f2("uTaps", look.tapsX.toFloat(), look.tapsY.toFloat())
        val ch = look.chroma
        if (ch != null) {
            sh.f1("uChromaOn", 1f)
            sh.f4("uChroma", ch.keyCb.toFloat(), ch.keyCr.toFloat(), ch.edge0.toFloat(), ch.edge1.toFloat())
            sh.f4("uSpill", ch.dirCb.toFloat(), ch.dirCr.toFloat(), ch.spill.toFloat(), if (ch.spillOn) 1f else 0f)
        } else {
            sh.f1("uChromaOn", 0f)
        }
        val adj = look.adj
        if (adj != null) {
            sh.f1("uGradeOn", 1f)
            sh.f4("uAdjA", adj.exposure.toFloat(), adj.brightness.toFloat(), adj.contrast.toFloat(), adj.highlights.toFloat())
            sh.f4("uAdjB", adj.shadows.toFloat(), adj.saturation.toFloat(), adj.temperature.toFloat(), adj.tint.toFloat())
        } else {
            sh.f1("uGradeOn", 0f)
        }
        // uLut always sits on unit 1 so it never shares a unit with an external sampler.
        if (lut != null && look.lutIntensity != 0.0) {
            sh.sampler("uLut", 1, GLES20.GL_TEXTURE_2D, lut.texture)
            val info = lut.info
            sh.f4("uLutInfo", info[0], info[1], info[2], info[3])
            sh.f1("uLutI", look.lutIntensity.toFloat())
        } else {
            sh.sampler("uLut", 1, GLES20.GL_TEXTURE_2D, 0)
            sh.f1("uLutI", 0f)
        }
        sh.f1("uMatte", if (look.matte) 1f else 0f)
    }

    /**
     * One dv_blur direction over the top-left [rasterW] × [rasterH] raster of [texture]
     * ([width] × [height]; reads clamped to the raster = clamp-to-edge) into the top-left of the
     * bound framebuffer of height [targetHeight]. The caller sets the viewport to that raster
     * (defaults: the whole texture into a target of the same size).
     */
    fun drawBlur(
        texture: Int,
        width: Int,
        height: Int,
        horizontal: Boolean,
        kernel: GaussianKernel,
        rasterW: Int = width,
        rasterH: Int = height,
        targetHeight: Int = height,
    ) {
        val sh = program(ShaderSources.Program.BLUR)
        sh.use()
        GLES20.glDisable(GLES20.GL_BLEND)
        GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
        sh.sampler("uTex", 0, GLES20.GL_TEXTURE_2D, texture)
        sh.f2("uTexSize", width.toFloat(), height.toFloat())
        sh.f2("uRasterSize", rasterW.toFloat(), rasterH.toFloat())
        sh.f1("uOutHeight", targetHeight.toFloat())
        sh.f2("uDir", if (horizontal) 1f else 0f, if (horizontal) 0f else 1f)
        sh.f3("uKernel", kernel.sigma.toFloat(), kernel.radius.toFloat(), kernel.step.toFloat())
        drawQuad()
    }

    /**
     * dv_place with DV_DETAIL: sharpen, vignette and item mask of [place] on the [rasterW] ×
     * [rasterH] raster in the top-left of [texture] ([texW] × [texH]), at its texel centres, into
     * the top-left of the bound framebuffer of height [targetHeight] (premultiplied).
     */
    fun drawDetail(texture: Int, texW: Int, texH: Int, rasterW: Int, rasterH: Int, place: PlaceFrame, targetHeight: Int) {
        val sh = program(ShaderSources.Program.DETAIL)
        sh.use()
        GLES20.glDisable(GLES20.GL_BLEND)
        GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
        sh.sampler("uTex", 0, GLES20.GL_TEXTURE_2D, texture)
        sh.f2("uTexSize", texW.toFloat(), texH.toFloat())
        sh.f2("uRasterSize", rasterW.toFloat(), rasterH.toFloat())
        sh.f2("uOutSize", rasterW.toFloat(), targetHeight.toFloat())
        sh.f2("uBase", place.baseW.toFloat(), place.baseH.toFloat())
        sh.f1("uSharpen", place.sharpenGain.toFloat())
        sh.f2("uVignette", place.vignette.toFloat(), place.aspect.toFloat())
        val m = place.mask
        if (m != null) {
            sh.f4("uMaskA", m.cx.toFloat(), m.cy.toFloat(), m.hx.toFloat(), m.hy.toFloat())
            sh.f4("uMaskB", m.cos.toFloat(), m.sin.toFloat(), m.radius.toFloat(), m.feather.toFloat())
            sh.f4("uMaskC", if (m.shape == PlanMaskShape.RECT) 1f else 2f, m.op.toFloat(), if (m.inv) 1f else 0f, 0f)
        } else {
            sh.f4("uMaskC", 0f, 1f, 0f, 0f)
        }
        drawQuad()
    }

    /**
     * dv_place of the layer raster [texture] ([texW] × [texH], premultiplied; the raster fills its
     * top-left [rasterW] × [rasterH] px; ignored for solids) into the bound [renderW] × [renderH]
     * framebuffer, sampled bilinearly; [blend] composites onto it instead of overwriting. Sharpen,
     * vignette and mask are not applied here ([drawDetail] runs first when [PlaceFrame.needsDetail]).
     */
    fun drawPlace(
        texture: Int,
        texW: Int,
        texH: Int,
        place: PlaceFrame,
        renderW: Int,
        renderH: Int,
        blend: Boolean = false,
        rasterW: Int = texW,
        rasterH: Int = texH,
    ) {
        val sh = program(ShaderSources.Program.PLACE)
        sh.use()
        setSourceOverBlend(blend)
        GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
        val solid = place.solid
        sh.sampler("uTex", 0, GLES20.GL_TEXTURE_2D, if (solid != null) 0 else texture)
        sh.f2("uTexSize", (if (solid != null) 1 else texW).toFloat(), (if (solid != null) 1 else texH).toFloat())
        sh.f2("uRasterSize", (if (solid != null) 1 else rasterW).toFloat(), (if (solid != null) 1 else rasterH).toFloat())
        sh.f2("uOutSize", renderW.toFloat(), renderH.toFloat())
        val inv = place.inverse
        sh.f4("uInv", inv.a.toFloat(), inv.b.toFloat(), inv.c.toFloat(), inv.d.toFloat())
        sh.f2("uInvT", inv.tx.toFloat(), inv.ty.toFloat())
        sh.f2("uBase", place.baseW.toFloat(), place.baseH.toFloat())
        sh.f1("uOpacity", place.opacity.toFloat())
        sh.f2("uCanvasPerRender", place.canvasPerRenderX.toFloat(), place.canvasPerRenderY.toFloat())
        val n = place.canvasMasks.size
        if (n > 0) {
            val a = FloatArray(LayerFrames.MAX_CANVAS_MASKS * 4)
            val b = FloatArray(LayerFrames.MAX_CANVAS_MASKS * 4)
            place.canvasMasks.forEachIndexed { i, m ->
                a[i * 4] = m.cx.toFloat(); a[i * 4 + 1] = m.cy.toFloat(); a[i * 4 + 2] = m.hx.toFloat(); a[i * 4 + 3] = m.hy.toFloat()
                b[i * 4] = m.cos.toFloat(); b[i * 4 + 1] = m.sin.toFloat(); b[i * 4 + 2] = m.feather.toFloat(); b[i * 4 + 3] = if (m.inv) 1f else 0f
            }
            sh.f4v("uCm", a, LayerFrames.MAX_CANVAS_MASKS)
            sh.f4v("uCmB", b, LayerFrames.MAX_CANVAS_MASKS)
        }
        sh.f1("uCmCount", n.toFloat())
        sh.f2("uAa", if (place.antialias) 1f else 0f, place.edgeScale.toFloat())
        if (solid != null) {
            sh.f1("uSolidOn", 1f)
            sh.f4("uSolid", solid[0], solid[1], solid[2], solid[3])
        } else {
            sh.f1("uSolidOn", 0f)
        }
        drawQuad()
        if (blend) setSourceOverBlend(false)
    }

    private fun drawQuad() {
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, quad)
        GLES20.glEnableVertexAttribArray(0)
        GLES20.glVertexAttribPointer(0, 2, GLES20.GL_FLOAT, false, 0, 0)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glDisableVertexAttribArray(0)
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, 0)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        stats.draw()
        val err = GLES20.glGetError()
        check(err == GLES20.GL_NO_ERROR) { "GL error 0x${Integer.toHexString(err)} in a draw" }
    }

    /** Drops one reference; the last one deletes every program and the quad. */
    fun release() {
        checkThread()
        synchronized(registry) {
            if (--refs > 0) return
            if (key != null) registry.remove(key)
        }
        released = true
        for (p in programs.values) GlResources.deleteProgram(p.id)
        programs.clear()
        GlResources.deleteBuffer(quad)
    }

    companion object {
        private val QUAD = floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f)
        private val registry = HashMap<EGLContext, ShaderPrograms>()

        /**
         * The programs of the current EGL context (shared and reference counted per context), read
         * from [context]'s assets. Call on a GL thread with the context current; pair with [release].
         */
        fun acquire(context: Context): ShaderPrograms = acquire(ShaderSources.assetReader(context))

        /** [acquire] with an explicit shader reader. */
        fun acquire(read: (String) -> String): ShaderPrograms {
            GlThreadPolicy.checkCurrent()
            val egl = EGL14.eglGetCurrentContext()
            check(egl != null && egl != EGL14.EGL_NO_CONTEXT) { "no current EGL context" }
            synchronized(registry) {
                val existing = registry[egl]
                if (existing != null && !existing.released) {
                    existing.confinement.check()
                    existing.refs++
                    return existing
                }
                val created = ShaderPrograms(read, egl)
                registry[egl] = created
                return created
            }
        }
    }
}
