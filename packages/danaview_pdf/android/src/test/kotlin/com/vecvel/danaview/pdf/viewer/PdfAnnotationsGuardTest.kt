// OWNER: HOM-25
//
// The getPageAnnotations() guard (HOM-27 finding, lead 4173f441). `PdfRenderer.Page
// .getPageAnnotations()` (API 36.1 / S-ext 18) throws "NullPointerException: Page object should not
// be null" inside its native call on pages with Ink, FreeText or Stamp annotations
// (annotated_2p.pdf page 2). The exception is raised across JNI, so it can't be caught: on the API 37
// emulator the process aborts ("JNI DETECTED ERROR IN APPLICATION ... called with pending
// exception"). The only safe guard is never to call it (or the other annotation readers of the same
// family). This JVM test keeps those calls out of the plugin's sources.

package com.vecvel.danaview.pdf.viewer

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class PdfAnnotationsGuardTest {
    private val forbidden = listOf("getPageAnnotations", "pageAnnotations", "getPageImageObjects", "getPageObjects", "pageObjects")

    private fun sources(): List<File> {
        // Unit tests run in the module directory (packages/danaview_pdf/android).
        val root = File("src/main/kotlin")
        assertTrue("sources not found from ${File(".").absolutePath}", root.isDirectory)
        return root.walkTopDown().filter { it.isFile && it.extension == "kt" }.toList()
    }

    @Test
    fun noPlatformAnnotationReaderIsCalled() {
        val files = sources()
        assertTrue(files.size > 10)
        val offenders = files.flatMap { file ->
            file.readLines().mapIndexedNotNull { i, line ->
                val code = line.substringBefore("//").trim()
                if (code.startsWith("*") || code.startsWith("/*")) return@mapIndexedNotNull null
                if (forbidden.any { code.contains(it) }) "${file.name}:${i + 1}: $code" else null
            }
        }
        assertTrue("platform annotation readers called:\n" + offenders.joinToString("\n"), offenders.isEmpty())
    }
}
