// OWNER: AND-09
//
// Pure Kotlin (JVM-tested) translation of one layer's evaluated parameters (AND-08 LayerParams at
// timeOfFrame(k), D-35) into the uniforms of the GL passes (ARCH §11.6, D-08):
//   look  (dv_look.glsl):  crop + footprint resample of the source onto the layer raster, chroma
//                          key + spill, grade, LUT;
//   blur  (dv_blur.glsl):  σ = blur·0.03·min(W, H) plan-canvas px, converted to raster px;
//   place (dv_place.glsl): inverse placement matrix (render px → base-local px), sharpen,
//                          vignette, item mask, opacity, canvas masks, 1 px antialiased edge;
//   sprite (dv_look.glsl with DV_REVEAL, then dv_place.glsl): the sprite resampled onto its
//                          raster with the reveal map, then placed like a picture raster.
// It mirrors API-03's reference renderer (packages/danaview_editor_engine_api, ReferenceRenderer
// and RenderMath): a layer raster at round(base·|s|·renderScale) px ("footprint" sizing; sprites
// always), box-filtered by ≤ 8×8 bilinear taps per texel, then placed with one bilinear sample per
// output pixel; the Media3 effects instead size a picture raster once in
// `configure` for the layer's largest animated scale (ARCH §13.3: min(source, render size ÷ (item
// scale × max animated scale)) so 4K sources downscale first without softening keyframed zooms),
// and the place pass averages the minified raster over each output pixel. Interpretations of
// API-03 are kept (vectors/README.md): blur and sharpen work on premultiplied colour, a missing
// `base` is the canvas (or sprite) size, `bg` alpha is ignored.

package com.vecvel.danaview.editor.engine.effects

import com.vecvel.danaview.editor.engine.plan.CanvasMask
import com.vecvel.danaview.editor.engine.plan.LayerParams
import com.vecvel.danaview.editor.engine.plan.PlanAdjust
import com.vecvel.danaview.editor.engine.plan.PlanAsset
import com.vecvel.danaview.editor.engine.plan.PlanChroma
import com.vecvel.danaview.editor.engine.plan.PlanCrop
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import com.vecvel.danaview.editor.engine.plan.PlanMask
import com.vecvel.danaview.editor.engine.plan.PlanMaskShape
import com.vecvel.danaview.editor.engine.plan.PlanSize
import com.vecvel.danaview.editor.engine.plan.PlanTransform
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToLong
import kotlin.math.sin

/** How the look pass sizes the layer raster. */
enum class RasterSizing {
    /** `round(base·|s|·renderScale)` at the frame's own scale (API-03 reference; paused frames). */
    FOOTPRINT,

    /** `min(source crop, round(base·maxScale·renderScale))`, fixed per item (Media3 `configure`). */
    MAX_SCALE,

    /** The crop at source resolution (look stills, no placement). */
    SOURCE,
}

/** The canvas (plan px) and the render target (px) a layer is drawn into. */
data class RenderGeometry(val canvasW: Int, val canvasH: Int, val renderW: Int, val renderH: Int) {
    init {
        require(canvasW > 0 && canvasH > 0 && renderW > 0 && renderH > 0) { "bad geometry" }
    }

    /** Render px per canvas px, horizontally (the reference's `renderScale`). */
    val kx: Double get() = renderW.toDouble() / canvasW

    /** Render px per canvas px, vertically. */
    val ky: Double get() = renderH.toDouble() / canvasH
}

/** An affine map `(x, y) → (a·x + c·y + tx, b·x + d·y + ty)` (y down). */
data class Affine(val a: Double, val b: Double, val c: Double, val d: Double, val tx: Double, val ty: Double) {
    /** Applies the map. */
    fun apply(x: Double, y: Double): Pair<Double, Double> = Pair(a * x + c * y + tx, b * x + d * y + ty)

    /** The determinant of the linear part. */
    val det: Double get() = a * d - b * c

    /** The inverse, or null when singular. */
    fun inverse(): Affine? {
        val det = det
        if (det == 0.0 || !det.isFinite()) return null
        val ia = d / det
        val ib = -b / det
        val ic = -c / det
        val id = a / det
        return Affine(ia, ib, ic, id, -(ia * tx + ic * ty), -(ib * tx + id * ty))
    }

    /** `this ∘ other` (applies [other] first). */
    fun then(other: Affine): Affine = Affine(
        a = a * other.a + c * other.b,
        b = b * other.a + d * other.b,
        c = a * other.c + c * other.d,
        d = b * other.c + d * other.d,
        tx = a * other.tx + c * other.ty + tx,
        ty = b * other.tx + d * other.ty + ty,
    )

    /** `[a, b, c, d, tx, ty]`. */
    fun toArray(): DoubleArray = doubleArrayOf(a, b, c, d, tx, ty)
}

/** Look pass uniforms (dv_look.glsl). */
data class LookFrame(
    val rasterW: Int,
    val rasterH: Int,
    /** Crop origin in source px (top-down) and source px per raster px. */
    val cropX0: Double,
    val cropY0: Double,
    val stepX: Double,
    val stepY: Double,
    val tapsX: Int,
    val tapsY: Int,
    val chroma: ChromaUniforms?,
    val adj: PlanAdjust?,
    /** LUT asset id and intensity (null or 0 intensity: no LUT). */
    val lutAsset: String?,
    val lutIntensity: Double,
    val matte: Boolean,
)

/** Chroma key uniforms: key (Cb, Cr), smoothstep edges, normalized key direction, spill. */
data class ChromaUniforms(
    val keyCb: Double,
    val keyCr: Double,
    val edge0: Double,
    val edge1: Double,
    val dirCb: Double,
    val dirCr: Double,
    val spill: Double,
    val spillOn: Boolean,
)

/** Blur pass uniforms per direction, in raster px. */
data class BlurFrame(val sigmaX: Double, val sigmaY: Double) {
    /** Horizontal kernel. */
    val x: GaussianKernel get() = GaussianKernel.of(sigmaX)

    /** Vertical kernel. */
    val y: GaussianKernel get() = GaussianKernel.of(sigmaY)
}

/** One Gaussian direction: σ, radius `ceil(3σ)` and the tap step (≤ 64 taps per side). */
data class GaussianKernel(val sigma: Double, val radius: Int, val step: Int) {
    /** The normalized weights at offsets `i·step`, `|i·step| ≤ radius` (what the shader computes). */
    fun weights(): DoubleArray {
        val n = radius / step
        val w = DoubleArray(2 * n + 1)
        var sum = 0.0
        for (i in -n..n) {
            val x = (i * step).toDouble()
            val v = if (sigma > 0) kotlin.math.exp(-(x * x) / (2 * sigma * sigma)) else if (i == 0) 1.0 else 0.0
            w[i + n] = v
            sum += v
        }
        for (i in w.indices) w[i] /= sum
        return w
    }

    companion object {
        /** Taps per side the shader loops over. */
        const val MAX_TAPS_PER_SIDE = 64

        /** σ below which the blur is skipped (ARCH §11.6). */
        const val MIN_SIGMA = 0.5

        /** The kernel of [sigma] (radius 0 = identity when σ ≤ 0). */
        fun of(sigma: Double): GaussianKernel {
            if (!(sigma > 0)) return GaussianKernel(0.0, 0, 1)
            val radius = ceil(3 * sigma).toInt()
            val step = max(1, ceil(radius.toDouble() / MAX_TAPS_PER_SIDE).toInt())
            return GaussianKernel(sigma, radius, step)
        }

        /** Whether a blur of [sigma] (reference raster px) is skipped. */
        fun isSkipped(sigma: Double): Boolean = !(sigma >= MIN_SIGMA)

        /** `σ = blur·0.03·min(W, H)` in plan-canvas px. */
        fun sigmaCanvasPx(blur: Double, canvasW: Int, canvasH: Int): Double = blur * 0.03 * min(canvasW, canvasH)
    }
}

/** Item mask uniforms in base px. */
data class MaskUniforms(
    val shape: PlanMaskShape,
    val cx: Double,
    val cy: Double,
    val hx: Double,
    val hy: Double,
    val cos: Double,
    val sin: Double,
    val radius: Double,
    val feather: Double,
    val op: Double,
    val inv: Boolean,
)

/** Canvas mask uniforms in canvas px. */
data class CanvasMaskUniforms(
    val cx: Double,
    val cy: Double,
    val hx: Double,
    val hy: Double,
    val cos: Double,
    val sin: Double,
    val feather: Double,
    val inv: Boolean,
)

/** Place / sprite pass uniforms (dv_place.glsl). */
data class PlaceFrame(
    /** Render px (pixel centre, top-down) → base-local px. */
    val inverse: Affine,
    val baseW: Double,
    val baseH: Double,
    /** Render px per local px (|s|·kx, |s|·ky). */
    val pxPerLocalX: Double,
    val pxPerLocalY: Double,
    /** The reference raster size round(base·|s|·renderScale) (sharpen step, sprite raster size). */
    val refRasterW: Int,
    val refRasterH: Int,
    val sharpenGain: Double,
    val vignette: Double,
    val aspect: Double,
    val mask: MaskUniforms?,
    val opacity: Double,
    val canvasPerRenderX: Double,
    val canvasPerRenderY: Double,
    val canvasMasks: List<CanvasMaskUniforms>,
    val antialias: Boolean,
    /** Premultiplied solid colour (solid layers), else null. */
    val solid: FloatArray?,
    /** Sprite reveal: glyphs shown (`floor(reveal)`), or null when every texel is drawn. */
    val revealShown: Double?,
) {
    /** Edge AA scale: render px per local px (min of both axes). */
    val edgeScale: Double get() = min(pxPerLocalX, pxPerLocalY)

    /** Whether the raster pass (sharpen, vignette, item mask) runs. */
    val needsDetail: Boolean get() = sharpenGain > 0 || vignette > 0 || mask != null

    /**
     * Whether a [rasterW] × [rasterH] raster is first resampled to the reference raster size: it is
     * larger than the reference in some axis (a Media3 raster sized for a larger animated scale).
     */
    fun needsResample(rasterW: Int, rasterH: Int): Boolean =
        (rasterW > refRasterW || rasterH > refRasterH) && (rasterW != refRasterW || rasterH != refRasterH)

    override fun equals(other: Any?): Boolean = other is PlaceFrame && other.inverse == inverse && other.baseW == baseW && other.baseH == baseH &&
        other.opacity == opacity && other.canvasMasks == canvasMasks && other.mask == mask && other.solid.contentEquals(solid)

    override fun hashCode(): Int = inverse.hashCode() * 31 + opacity.hashCode()
}

/** Everything one layer needs at one frame. */
data class LayerFrame(
    val kind: PlanLayerKind,
    val layerId: String,
    /** Media and image layers only. */
    val look: LookFrame?,
    /** Present when the blur pass runs (σ ≥ 0.5 reference px). */
    val blur: BlurFrame?,
    val place: PlaceFrame,
)

/** Options of an editing mode (AND-17: normal, cropSource, matte). */
data class LayerFrameOptions(
    /** Show the keyed alpha as opaque grey (matte editing mode). */
    val matte: Boolean = false,
    /** Crop used instead of the layer's (cropSource editing mode shows the full source). */
    val cropOverride: PlanCrop? = null,
    /** Antialiased box edges (production on; the vector tests turn it off). */
    val antialias: Boolean = true,
)

/** Uniform computation (file header). */
object LayerFrames {
    /** Most taps per axis of the footprint resample (API-03 `maxSupersample`). */
    const val MAX_TAPS = 8

    /** Largest raster side (API-03 `maxLayerRasterSide`). */
    const val MAX_RASTER_SIDE = 4096

    /** Canvas masks a layer may carry (the shader's uniform array). */
    const val MAX_CANVAS_MASKS = 8

    /** Exact cos/sin of [deg] for multiples of 90 (core `cosSinDeg`). */
    fun cosSinDeg(deg: Double): Pair<Double, Double> {
        val r = ((deg % 360.0) + 360.0) % 360.0
        if (r == 0.0) return Pair(1.0, 0.0)
        if (r == 90.0) return Pair(0.0, 1.0)
        if (r == 180.0) return Pair(-1.0, 0.0)
        if (r == 270.0) return Pair(0.0, -1.0)
        val rad = Math.toRadians(deg)
        return Pair(cos(rad), sin(rad))
    }

    /**
     * The placement matrix (base-local px → canvas px), ARCH §11.6 Place, core
     * `planPlacementMatrix`: `T(cx, cy)·R(r)·S(s·(fx ? −1 : 1), s·(fy ? −1 : 1))·T(−base/2)`; a
     * null centre is the canvas centre.
     */
    fun placement(xf: PlanTransform, base: PlanSize, canvasW: Int, canvasH: Int): Affine {
        val (c, s) = cosSinDeg(xf.r)
        val sx = if (xf.fx) -xf.s else xf.s
        val sy = if (xf.fy) -xf.s else xf.s
        val a = c * sx
        val b = s * sx
        val cc = -s * sy
        val d = c * sy
        val hw = base.w / 2
        val hh = base.h / 2
        val cx = xf.cx ?: (canvasW / 2.0)
        val cy = xf.cy ?: (canvasH / 2.0)
        return Affine(a, b, cc, d, cx - (a * hw + cc * hh), cy - (b * hw + d * hh))
    }

    /** `clamp(ceil(footprint − 1e-9), 1, 8)`: taps per axis for a footprint of [footprint] texels. */
    fun taps(footprint: Double): Int {
        if (!footprint.isFinite()) return MAX_TAPS
        return ceil(footprint - 1e-9).toInt().coerceIn(1, MAX_TAPS)
    }

    /** A raster side: `round(px)` clamped to [1, min(4096, maxTextureSize)]. */
    fun rasterSide(px: Double, maxTextureSize: Int): Int {
        val cap = min(MAX_RASTER_SIDE, maxTextureSize)
        if (!px.isFinite()) return cap
        return px.roundToLong().coerceIn(1L, cap.toLong()).toInt()
    }

    /**
     * The look raster size of a media/image layer with [base], [scale] (|xf.s| at the frame, or the
     * largest animated scale for [RasterSizing.MAX_SCALE]) and [crop] of a [sourceW] × [sourceH]
     * source.
     */
    fun rasterSize(
        sizing: RasterSizing,
        base: PlanSize,
        scale: Double,
        crop: PlanCrop,
        sourceW: Int,
        sourceH: Int,
        geometry: RenderGeometry,
        maxTextureSize: Int,
    ): Pair<Int, Int> {
        val cropW = (crop.r - crop.l) * sourceW
        val cropH = (crop.b - crop.t) * sourceH
        return when (sizing) {
            RasterSizing.FOOTPRINT -> Pair(
                rasterSide(base.w * abs(scale) * geometry.kx, maxTextureSize),
                rasterSide(base.h * abs(scale) * geometry.ky, maxTextureSize),
            )
            RasterSizing.MAX_SCALE -> Pair(
                min(rasterSide(base.w * abs(scale) * geometry.kx, maxTextureSize), rasterSide(cropW, maxTextureSize)),
                min(rasterSide(base.h * abs(scale) * geometry.ky, maxTextureSize), rasterSide(cropH, maxTextureSize)),
            )
            RasterSizing.SOURCE -> Pair(rasterSide(cropW, maxTextureSize), rasterSide(cropH, maxTextureSize))
        }
    }

    /** Chroma uniforms of [chroma] (ARCH §11.6 Chroma key). */
    fun chroma(chroma: PlanChroma): ChromaUniforms {
        val r = ((chroma.key shr 16) and 0xFF) / 255.0
        val g = ((chroma.key shr 8) and 0xFF) / 255.0
        val b = (chroma.key and 0xFF) / 255.0
        val y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        val kb = (b - y) / 1.8556
        val kr = (r - y) / 1.5748
        val s0 = chroma.sim * 0.25
        val s1 = max(0.001, chroma.smooth * 0.25)
        val len = hypot(kb, kr)
        val on = len > 0 && chroma.spill > 0
        return ChromaUniforms(kb, kr, s0, s0 + s1, if (on) kb / len else 0.0, if (on) kr / len else 0.0, chroma.spill, on)
    }

    /** Item mask uniforms (base px; API-03 interpretation: aspect-correct SDF over `base`). */
    fun mask(mask: PlanMask, baseW: Double, baseH: Double): MaskUniforms {
        val w = mask.w * baseW
        val h = mask.h * baseH
        val m = min(w, h)
        val (c, s) = cosSinDeg(mask.r)
        return MaskUniforms(
            shape = mask.shape,
            cx = mask.cx * baseW,
            cy = mask.cy * baseH,
            hx = w / 2,
            hy = h / 2,
            cos = c,
            sin = s,
            radius = if (mask.shape == PlanMaskShape.RECT) mask.corner * m else 0.0,
            feather = mask.feather * 0.25 * m,
            op = mask.op,
            inv = mask.inv,
        )
    }

    /** Canvas mask uniforms (already evaluated at the frame time). */
    fun canvasMask(m: CanvasMask): CanvasMaskUniforms {
        val (c, s) = cosSinDeg(m.r)
        return CanvasMaskUniforms(m.cx, m.cy, m.w / 2, m.h / 2, c, s, m.feather, m.inv)
    }

    /** Premultiplied RGBA floats of a straight ARGB colour (alpha honoured; `bg` callers pass it opaque). */
    fun premultipliedArgb(argb: Int): FloatArray {
        val a = ((argb ushr 24) and 0xFF) / 255f
        return floatArrayOf(((argb shr 16) and 0xFF) / 255f * a, ((argb shr 8) and 0xFF) / 255f * a, (argb and 0xFF) / 255f * a, a)
    }

    /**
     * The place uniforms of [p] (the reference renderer draws nothing when `xf.op ≤ 0`, `s = 0`, a
     * degenerate base or a singular matrix: null).
     */
    fun place(p: LayerParams, geometry: RenderGeometry, maxTextureSize: Int, options: LayerFrameOptions = LayerFrameOptions()): PlaceFrame? {
        if (!(p.xf.op > 0)) return null
        val s = abs(p.xf.s)
        val base = p.base
        if (!(s > 0 && base.w > 0 && base.h > 0)) return null
        val m = placement(p.xf, base, geometry.canvasW, geometry.canvasH)
        val toCanvas = Affine(1.0 / geometry.kx, 0.0, 0.0, 1.0 / geometry.ky, 0.0, 0.0)
        val inv = (m.inverse() ?: return null).then(toCanvas)
        val isPicture = p.kind == PlanLayerKind.MEDIA || p.kind == PlanLayerKind.IMAGE
        val detail = if (isPicture) p.detail else null
        val cmasks = p.cmasks.take(MAX_CANVAS_MASKS).map { canvasMask(it) }
        return PlaceFrame(
            inverse = inv,
            baseW = base.w,
            baseH = base.h,
            pxPerLocalX = s * geometry.kx,
            pxPerLocalY = s * geometry.ky,
            refRasterW = rasterSide(base.w * s * geometry.kx, maxTextureSize),
            refRasterH = rasterSide(base.h * s * geometry.ky, maxTextureSize),
            sharpenGain = (detail?.sharpen ?: 0.0) * 1.5,
            vignette = detail?.vignette ?: 0.0,
            aspect = base.w / base.h,
            mask = if (isPicture) p.mask?.let { mask(it, base.w, base.h) } else null,
            opacity = p.xf.op.coerceAtMost(1.0),
            canvasPerRenderX = 1.0 / geometry.kx,
            canvasPerRenderY = 1.0 / geometry.ky,
            canvasMasks = cmasks,
            antialias = options.antialias,
            solid = if (p.kind == PlanLayerKind.SOLID) premultipliedArgb(p.color ?: 0xFF000000.toInt()) else null,
            revealShown = null,
        )
    }

    /**
     * The look uniforms of a media/image layer over a [sourceW] × [sourceH] source drawn into a
     * [rasterW] × [rasterH] raster.
     */
    fun look(p: LayerParams, sourceW: Int, sourceH: Int, rasterW: Int, rasterH: Int, options: LayerFrameOptions = LayerFrameOptions()): LookFrame {
        val crop = options.cropOverride ?: p.crop
        val x0 = crop.l * sourceW
        val y0 = crop.t * sourceH
        val stepX = (crop.r - crop.l) * sourceW / rasterW
        val stepY = (crop.b - crop.t) * sourceH / rasterH
        val lut = p.lut
        return LookFrame(
            rasterW = rasterW,
            rasterH = rasterH,
            cropX0 = x0,
            cropY0 = y0,
            stepX = stepX,
            stepY = stepY,
            tapsX = taps(stepX),
            tapsY = taps(stepY),
            chroma = p.chroma?.let { chroma(it) },
            adj = p.adj,
            lutAsset = if (lut != null && lut.i != 0.0) lut.asset else null,
            lutIntensity = if (lut != null) lut.i else 0.0,
            matte = options.matte,
        )
    }

    /**
     * The blur of [p] on a [rasterW] × [rasterH] look raster, or null when skipped: σ in reference
     * raster px is `σ_canvas·kx` (skip below 0.5), scaled by raster px per reference raster px.
     */
    fun blur(p: LayerParams, place: PlaceFrame, rasterW: Int, rasterH: Int, geometry: RenderGeometry, canvasW: Int, canvasH: Int): BlurFrame? {
        val amount = p.detail?.blur ?: return null
        if (!(amount > 0)) return null
        val sigmaRef = GaussianKernel.sigmaCanvasPx(amount, canvasW, canvasH) * geometry.kx
        if (GaussianKernel.isSkipped(sigmaRef)) return null
        return BlurFrame(sigmaRef * rasterW / place.refRasterW, sigmaRef * rasterH / place.refRasterH)
    }

    /**
     * The whole frame of one layer: [sourceW] × [sourceH] is the media/image source (ignored for
     * solids and sprites); [fixedRaster] is the raster size Media3 configured (MAX_SCALE), else the
     * raster is sized by [sizing].
     */
    fun frame(
        p: LayerParams,
        geometry: RenderGeometry,
        maxTextureSize: Int,
        sourceW: Int = 0,
        sourceH: Int = 0,
        sizing: RasterSizing = RasterSizing.FOOTPRINT,
        maxScale: Double = abs(p.xf.s),
        fixedRaster: Pair<Int, Int>? = null,
        reveal: Boolean = false,
        options: LayerFrameOptions = LayerFrameOptions(),
    ): LayerFrame? {
        var place = place(p, geometry, maxTextureSize, options) ?: return null
        return when (p.kind) {
            PlanLayerKind.SOLID -> LayerFrame(p.kind, p.id, null, null, place)
            PlanLayerKind.SPRITE -> {
                if (reveal && p.reveal != null) place = place.copy(revealShown = floor(p.reveal))
                LayerFrame(p.kind, p.id, null, null, place)
            }
            PlanLayerKind.MEDIA, PlanLayerKind.IMAGE -> {
                require(sourceW > 0 && sourceH > 0) { "source size unknown" }
                val crop = options.cropOverride ?: p.crop
                val (rw, rh) = fixedRaster ?: rasterSize(
                    sizing,
                    p.base,
                    if (sizing == RasterSizing.MAX_SCALE) max(maxScale, abs(p.xf.s)) else abs(p.xf.s),
                    crop,
                    sourceW,
                    sourceH,
                    geometry,
                    maxTextureSize,
                )
                val look = look(p, sourceW, sourceH, rw, rh, options)
                LayerFrame(p.kind, p.id, look, blur(p, place, rw, rh, geometry, geometry.canvasW, geometry.canvasH), place)
            }
        }
    }

    /** The plan asset of a layer's LUT, or null. */
    fun lutAssetOf(look: LookFrame?, assets: Map<String, PlanAsset>): PlanAsset? = look?.lutAsset?.let { assets[it] }
}
