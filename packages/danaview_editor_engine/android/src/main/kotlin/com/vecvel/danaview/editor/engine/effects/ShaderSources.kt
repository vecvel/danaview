// OWNER: AND-09
//
// The GLSL ES 1.00 sources of the effects (ARCH §13.3 "GL effects"), shipped as library assets in
// src/main/assets/danaview_shaders/. A fragment program is assembled as
//   [#extension GL_OES_EGL_image_external : require]   (external-texture variants only)
//   #define <DEFINE> 1 …
//   dv_common.glsl
//   <program>.glsl
// so every program shares the §11.6 helpers. The assembly is pure (JVM-tested); [assetReader]
// reads the files through the app's AssetManager.

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

    /** LayerLookEffect: crop, footprint resample, chroma + spill, grade, LUT. */
    const val LOOK = "dv_look.glsl"

    /** SeparableBlurEffect: one Gaussian direction. */
    const val BLUR = "dv_blur.glsl"

    /** LayerPlaceEffect and (with DV_SPRITE) SpriteBandEffect. */
    const val PLACE = "dv_place.glsl"

    /** The programs of the effects package. */
    enum class Program(val fragment: String, val defines: List<String>, val externalTexture: Boolean) {
        /** Look pass over a GL_TEXTURE_2D source (Media3 effect inputs, uploaded bitmaps). */
        LOOK_2D(LOOK, emptyList(), false),

        /** Look pass over a GL_TEXTURE_EXTERNAL_OES source (HardwareBuffer / SurfaceTexture frames). */
        LOOK_EXTERNAL(LOOK, listOf("DV_EXTERNAL"), true),

        /** One direction of the separable Gaussian blur. */
        BLUR(ShaderSources.BLUR, emptyList(), false),

        /** Placement of a layer raster or solid onto the canvas. */
        PLACE(ShaderSources.PLACE, emptyList(), false),

        /** Placement of a sprite with its reveal map. */
        SPRITE(ShaderSources.PLACE, listOf("DV_SPRITE"), false),
    }

    /** Every file the programs read. */
    val FILES: List<String> = listOf(VERTEX, COMMON, LOOK, BLUR, PLACE)

    /** The vertex source. */
    fun vertexSource(read: (String) -> String): String = read(VERTEX)

    /** The assembled fragment source of [program] (file header). */
    fun fragmentSource(program: Program, read: (String) -> String): String = buildString {
        if (program.externalTexture) append("#extension GL_OES_EGL_image_external : require\n")
        for (d in program.defines) append("#define ").append(d).append(" 1\n")
        append(read(COMMON))
        append('\n')
        append(read(program.fragment))
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
