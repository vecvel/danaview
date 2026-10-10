// OWNER: ENG-09
//
// Fixture roots for the plugin's JVM unit tests (src/test). The example host's
// vwish_test_harness.gradle passes them as system properties; when a test runs without them
// (an IDE run from another Gradle root) the roots are found by walking up from user.dir.

package com.vecvel.vwish.editor.engine.harness

import java.io.File

/** The shared test fixture trees (BUILD_PLAN ENG-05, CORE fixtures, API fixtures). */
enum class FixtureTree(val property: String, val relativeToPackages: String) {
    /** packages/vwish_editor_engine/test_fixtures (media/ with manifest.json). */
    ENGINE("vwish.fixtures.engine", "vwish_editor_engine/test_fixtures"),

    /** packages/vwish_editor_core/test/fixtures (vectors, luts, render_plans, ...). */
    CORE("vwish.fixtures.core", "vwish_editor_core/test/fixtures"),

    /** packages/vwish_editor_engine_api/test_fixtures (vectors, images). */
    ENGINE_API("vwish.fixtures.engine_api", "vwish_editor_engine_api/test_fixtures"),
}

/** Resolves fixture files for JVM tests. */
object JvmFixtures {
    /** The root directory of [tree]; throws when it cannot be found. */
    fun root(tree: FixtureTree): File {
        System.getProperty(tree.property)?.let { path ->
            val dir = File(path)
            if (dir.isDirectory) return dir
        }
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            val inRepo = File(dir, "packages/${tree.relativeToPackages}")
            if (inRepo.isDirectory) return inRepo
            val inPackages = File(dir, tree.relativeToPackages)
            if (dir.name == "packages" && inPackages.isDirectory) return inPackages
            dir = dir.parentFile
        }
        error("fixture tree ${tree.name} not found (set -D${tree.property})")
    }

    /** A file inside [tree], e.g. `file(ENGINE, "media/manifest.json")`. */
    fun file(tree: FixtureTree, relativePath: String): File = File(root(tree), relativePath)
}
