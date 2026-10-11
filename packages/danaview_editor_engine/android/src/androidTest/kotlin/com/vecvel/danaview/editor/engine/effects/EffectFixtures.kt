// OWNER: AND-09
//
// Fixture access shared by the effects' instrumented tests: API-03 plans (images/plans/), an
// EffectAssets that serves every `.vlut` URI from images/sources/lut_33.vlut and every `.vsprite`
// URI from sprites/text_typewriter_reveal.vsprite (API-04's codec fixture, reveal map included),
// and decoded PNG frames uploaded as GL-oriented RGBA8 textures.

package com.vecvel.danaview.editor.engine.effects

import com.vecvel.danaview.editor.engine.harness.FixtureTree
import com.vecvel.danaview.editor.engine.harness.TestFixtures
import com.vecvel.danaview.editor.engine.plan.PlanReader
import com.vecvel.danaview.editor.engine.plan.RenderPlan

/** Effects fixtures (file header). */
object EffectFixtures {
    /** Bytes of an API-03/API-04 fixture file. */
    fun bytes(path: String): ByteArray = TestFixtures.open(FixtureTree.ENGINE_API, path).use { it.readBytes() }

    /** The API-03 plan `images/plans/<name>.json`. */
    fun plan(name: String): RenderPlan = PlanReader.readPlan(bytes("images/plans/$name.json"))

    /** LUT and sprite assets of any URI (file header). */
    val assets: EffectAssets = EffectAssets { uri ->
        when {
            uri.endsWith(".vlut") -> TestFixtures.open(FixtureTree.ENGINE_API, "images/sources/lut_33.vlut")
            uri.endsWith(".vsprite") -> TestFixtures.open(FixtureTree.ENGINE_API, "sprites/text_typewriter_reveal.vsprite")
            else -> throw IllegalArgumentException("no fixture for this asset")
        }
    }

    /** A decoded PNG of images/sources/ as a GL-oriented RGBA8 texture: (texture, width, height). Call on the GL lane. */
    fun uploadSource(name: String): Triple<Int, Int, Int> {
        val img = PngDecoder.decode(bytes("images/sources/$name"))
        return Triple(GlTestEnv.uploadRgba8(img.toRgba8(), img.width, img.height), img.width, img.height)
    }
}
