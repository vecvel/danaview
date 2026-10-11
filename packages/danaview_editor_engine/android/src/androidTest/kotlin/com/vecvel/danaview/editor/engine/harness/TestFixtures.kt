// OWNER: ENG-09
//
// Fixture access for the plugin's instrumented tests (src/androidTest). The example host's
// danaview_test_harness.gradle packs the shared fixture trees into the test APK's assets:
//
//   fixtures/engine/      packages/danaview_editor_engine/test_fixtures      (media/, manifest.json)
//   fixtures/core/        packages/danaview_editor_core/test/fixtures
//   fixtures/engine_api/  packages/danaview_editor_engine_api/test_fixtures
//
// Media services need real file paths, so copyToCache() materialises a fixture in the target
// app's cache directory (deleted with the app data).

package com.vecvel.danaview.editor.engine.harness

import android.content.Context
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.io.InputStream

/** The shared test fixture trees, as packed into the test APK. */
enum class FixtureTree(val assetDir: String) {
    ENGINE("fixtures/engine"),
    CORE("fixtures/core"),
    ENGINE_API("fixtures/engine_api"),
}

/** Opens and copies fixtures from the test APK. */
object TestFixtures {
    /** The test APK's context (its assets hold the fixtures). */
    val testContext: Context get() = InstrumentationRegistry.getInstrumentation().context

    /** The context of the app under test (the example host). */
    val targetContext: Context get() = InstrumentationRegistry.getInstrumentation().targetContext

    /** Asset path of [relativePath] inside [tree]. */
    fun assetPath(tree: FixtureTree, relativePath: String): String = "${tree.assetDir}/${relativePath.trimStart('/')}"

    /** Lists the entries of a directory of [tree] ("" for its root). */
    fun list(tree: FixtureTree, relativeDir: String = ""): List<String> =
        testContext.assets.list(assetPath(tree, relativeDir).trimEnd('/'))?.toList().orEmpty()

    /** Opens [relativePath] of [tree]; the caller closes the stream. */
    fun open(tree: FixtureTree, relativePath: String): InputStream = testContext.assets.open(assetPath(tree, relativePath))

    /** Reads [relativePath] of [tree] as UTF-8 text. */
    fun readText(tree: FixtureTree, relativePath: String): String = open(tree, relativePath).use { it.readBytes().toString(Charsets.UTF_8) }

    /**
     * Copies [relativePath] of [tree] to `<target cache>/danaview_test_fixtures/<tree>/<relativePath>`
     * (once per process run; the copy is refreshed when the sizes differ) and returns the file.
     */
    fun copyToCache(tree: FixtureTree, relativePath: String): File {
        val out = File(targetContext.cacheDir, "danaview_test_fixtures/${tree.name.lowercase()}/${relativePath.trimStart('/')}")
        open(tree, relativePath).use { input ->
            val bytes = input.readBytes()
            if (!out.isFile || out.length() != bytes.size.toLong()) {
                out.parentFile?.mkdirs()
                out.writeBytes(bytes)
            }
        }
        return out
    }
}
