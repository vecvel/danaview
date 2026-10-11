// OWNER: AND-09
//
// Static checks of the GLSL assets (ARCH §13.3 "GL effects" in GLSL ES 1.00): every file exists,
// is ASCII (GLSL ES 1.00's character set), has no `#version` (1.00 is the default) and only the
// assembled external variant starts with the OES extension; every uniform ShaderPrograms sets is
// declared by the program it sets it on, and every declared uniform is set (none left at its
// default by accident).

package com.vecvel.danaview.editor.engine.effects

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class ShaderSourcesTest {
    private val moduleDir: File by lazy {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            if (File(dir, "src/main/assets/${ShaderSources.DIR}").isDirectory) return@lazy dir
            val nested = File(dir, "packages/danaview_editor_engine/android")
            if (File(nested, "src/main/assets/${ShaderSources.DIR}").isDirectory) return@lazy nested
            dir = dir.parentFile
        }
        error("module dir not found")
    }

    private val read: (String) -> String = { File(moduleDir, "src/main/assets/${ShaderSources.DIR}/$it").readText() }

    @Test
    fun filesAreGlslEs100() {
        for (name in ShaderSources.FILES) {
            val text = read(name)
            assertTrue("$name is ASCII", text.all { it.code in 9..126 || it == '\n' || it == '\r' })
            assertFalse("$name has no #version", text.contains("#version"))
            assertFalse("$name has no #extension (added by the assembly)", text.contains("#extension"))
            // The emulator's GLES encoder scans shader text for the external sampler type, even in
            // inactive #ifdef branches; only the assembled external variant may name it.
            assertFalse("$name never names the external sampler type", text.contains("samplerExternalOES"))
            assertTrue("$name owner header", text.startsWith("// OWNER: AND-09"))
        }
        assertTrue(read(ShaderSources.COMMON).contains("precision highp float"))
    }

    @Test
    fun assemblyOrdersExtensionDefinesCommonBody() {
        val ext = ShaderSources.fragmentSource(ShaderSources.Program.LOOK_EXTERNAL, read)
        assertTrue(ext.startsWith("#extension GL_OES_EGL_image_external : require\n// OWNER: AND-09"))
        val sprite = ShaderSources.fragmentSource(ShaderSources.Program.SPRITE_RASTER, read)
        assertTrue(sprite.startsWith("#define DV_REVEAL 1\n// OWNER: AND-09"))
        // GLSL ES 1.00 shaders that loop after an early return were miscompiled on the emulator.
        for (p in ShaderSources.Program.values()) {
            val src = active(p)
            val main = src.substring(src.indexOf("void main()"))
            assertFalse("$p main has no return", Regex("""\breturn\b""").containsMatchIn(main.replace(Regex("//[^\n]*"), "")))
        }
        val look = ShaderSources.fragmentSource(ShaderSources.Program.LOOK_2D, read)
        assertTrue(look.indexOf("dvSmooth") < look.indexOf("void main"))
        assertTrue(look.contains("uniform sampler2D uTex;"))
        assertFalse(look.contains("samplerExternalOES"))
        assertTrue(ext.contains("uniform samplerExternalOES uTex;"))
        assertFalse(ext.contains("uniform sampler2D uTex;"))
        for (p in ShaderSources.Program.values()) {
            if (!p.externalTexture) assertFalse("$p", ShaderSources.fragmentSource(p, read).contains("samplerExternalOES"))
        }
    }

    /** Uniforms the program effectively declares (preprocessor branches of its defines resolved). */
    private fun declared(program: ShaderSources.Program): Set<String> = ShaderSources.declaredUniforms(active(program))

    /** The program's source with the preprocessor branches of its defines resolved. */
    private fun active(program: ShaderSources.Program): String {
        val src = ShaderSources.fragmentSource(program, read)
        val defined = program.defines.toSet()
        val out = StringBuilder()
        val stack = ArrayList<Boolean>()
        for (line in src.lines()) {
            val t = line.trim()
            when {
                t.startsWith("#ifdef") -> stack += t.removePrefix("#ifdef").trim() in defined
                t.startsWith("#ifndef") -> stack += t.removePrefix("#ifndef").trim() !in defined
                t.startsWith("#else") -> stack[stack.size - 1] = !stack.last()
                t.startsWith("#endif") -> stack.removeAt(stack.size - 1)
                stack.all { it } -> out.append(line).append('\n')
            }
        }
        return out.toString()
    }

    /** Uniform names ShaderPrograms sets inside [function] (from its Kotlin source). */
    private fun setIn(function: String): Set<String> {
        val src = File(moduleDir, "src/main/kotlin/com/vecvel/danaview/editor/engine/effects/ShaderPrograms.kt").readText()
        val start = src.indexOf("fun $function(")
        check(start >= 0) { function }
        val next = src.indexOf("\n    fun ", start + 1).let { if (it < 0) src.length else it }
        val private = src.indexOf("\n    private fun ", start + 1).let { if (it < 0) src.length else it }
        val body = src.substring(start, minOf(next, private))
        return Regex("""sh\.(?:f1|f2|f3|f4|f4v|mat3|sampler)\("(\w+)"""").findAll(body).map { it.groupValues[1] }.toSet()
    }

    @Test
    fun everyUniformIsDeclaredAndSet() {
        val look = setIn("setLookUniforms")
        val cases = mapOf(
            ShaderSources.Program.LOOK_2D to setIn("drawLook") + look,
            ShaderSources.Program.LOOK_EXTERNAL to setIn("drawLook") + look,
            ShaderSources.Program.SPRITE_RASTER to setIn("drawSpriteRaster") + look,
            ShaderSources.Program.BLUR to setIn("drawBlur"),
            ShaderSources.Program.PLACE to setIn("drawPlace"),
            ShaderSources.Program.DETAIL to setIn("drawDetail"),
        )
        for ((program, set) in cases) {
            val decl = declared(program)
            assertTrue("$program declares uniforms", decl.isNotEmpty())
            assertEquals("$program: set but not declared", emptySet<String>(), set - decl)
            assertEquals("$program: declared but never set", emptySet<String>(), decl - set)
        }
    }
}
