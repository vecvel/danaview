// OWNER: AND-09
//
// The GLSL ES 1.00 sources of the effects (ARCH §13.3 "GL effects"), shipped as library assets in
// src/main/assets/danaview_shaders/. A fragment program is assembled as
//   [#extension GL_OES_EGL_image_external : require]   (external-texture variants only)
//   #define <DEFINE> 1 …
//   dv_common.glsl
//   <program>.glsl
// so every program shares the §11.6 helpers. The external-texture variant of the look pass is made
// by rewriting `uniform sampler2D uTex;` to the external sampler type: the shader files never
// contain that type's name, not even in an inactive #ifdef branch, because the Android emulator's
// GLES encoder scans shader text for it (ignoring the preprocessor) and then rebinds the sampler's
// unit as an external texture at every draw, which made the 2D look pass sample the wrong texture
// on Pixel_9_Pro_XL_API_35 (measured 2026-10-11). The assembly is pure (JVM-tested);
// [assetReader] reads the files through the app's AssetManager.

package com.vecvel.danaview.editor.engine.effects

import android.content.Context

/** Shader file names and program assembly (file header). */
object ShaderSources {
    /** Asset directory of the shader files. */
    const val DIR = "danaview_shaders"

    /** The full-screen quad vertex shader. */
    const val VERTEX = "dv_vertex.glsl"

    /** Shared helpers prepended to every fragment shader. */
    const val COMMON = "dv_common.glsl"

    /** LayerLookEffect: crop, footprint resample, chroma + spill, grade, LUT; with DV_REVEAL the sprite raster pass. */
    const val LOOK = "dv_look.glsl"

    /** SeparableBlurEffect: one Gaussian direction. */
    const val BLUR = "dv_blur.glsl"

    /** LayerPlaceEffect, and the placement pass of SpriteBandEffect. */
    const val PLACE = "dv_place.glsl"

    /** The programs of the effects package. */
    enum class Program(val fragment: String, val defines: List<String>, val externalTexture: Boolean) {
        /** Look pass over a GL_TEXTURE_2D source (Media3 effect inputs, uploaded bitmaps). */
        LOOK_2D(LOOK, emptyList(), false),

        /** Look pass over a GL_TEXTURE_EXTERNAL_OES source (HardwareBuffer / SurfaceTexture frames). */
        LOOK_EXTERNAL(LOOK, emptyList(), true),

        /** One direction of the separable Gaussian blur. */
        BLUR(ShaderSources.BLUR, emptyList(), false),

        /** Placement of a layer raster or solid onto the canvas (bilinear, opacity, canvas masks, AA edge). */
        PLACE(ShaderSources.PLACE, emptyList(), false),

        /** Sharpen, vignette and item mask on the layer raster (LayerPlaceEffect's raster pass). */
        DETAIL(ShaderSources.PLACE, listOf("DV_DETAIL"), false),

        /** A sprite resampled onto its layer raster with the reveal map (SpriteBandEffect pass 1). */
        SPRITE_RASTER(LOOK, listOf("DV_REVEAL"), false),
    }

    /** Every file the programs read. */
    val FILES: List<String> = listOf(VERTEX, COMMON, LOOK, BLUR, PLACE)

    /** The vertex source. */
    fun vertexSource(read: (String) -> String): String = read(VERTEX)

    /** The 2D source declaration the external variant rewrites. */
    const val SOURCE_SAMPLER_2D = "uniform sampler2D uTex;"

    /** Its external-texture replacement. */
    const val SOURCE_SAMPLER_EXTERNAL = "uniform samplerExternalOES uTex;"

    /** The assembled fragment source of [program] (file header). */
    fun fragmentSource(program: Program, read: (String) -> String): String = buildString {
        if (program.externalTexture) append("#extension GL_OES_EGL_image_external : require\n")
        for (d in program.defines) append("#define ").append(d).append(" 1\n")
        append(read(COMMON))
        append('\n')
        val body = read(program.fragment)
        if (program.externalTexture) {
            check(body.contains(SOURCE_SAMPLER_2D)) { "${program.fragment} has no rewritable source sampler" }
            append(body.replace(SOURCE_SAMPLER_2D, SOURCE_SAMPLER_EXTERNAL))
        } else {
            append(body)
        }
    }

    /** Reads `danaview_shaders/<name>` from [context]'s assets (UTF-8). */
    fun assetReader(context: Context): (String) -> String {
        val assets = context.applicationContext?.assets ?: context.assets
        return { name -> assets.open("$DIR/$name").use { it.readBytes().toString(Charsets.UTF_8) } }
    }

    /** Uniform names declared by [source] (`uniform <type> <name>[N];`), for the JVM checks. */
    fun declaredUniforms(source: String): Set<String> =
        Regex("""^\s*uniform\s+\w+\s+(\w+)\s*(\[\s*\d+\s*])?\s*;""", RegexOption.MULTILINE).findAll(source).map { it.groupValues[1] }.toSet()
}
