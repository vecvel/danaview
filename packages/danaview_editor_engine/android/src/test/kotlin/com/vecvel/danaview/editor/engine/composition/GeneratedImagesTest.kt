// OWNER: AND-08 (QA-05 D8, Android half)
//
// Generated-image names on the JVM: every name PngCompositionImages writes parses back to the size
// and colour it was drawn with (so a purged image can be drawn again from its URI alone); only
// files directly in the images directory with a generated name count as generated (user media and
// look-alike names elsewhere go to the normal loader). Drawing and writing need Android
// (GeneratedImagesInstrumentedTest).

package com.vecvel.danaview.editor.engine.composition

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class GeneratedImagesTest {
    @get:Rule
    val temp = TemporaryFolder()

    @Test
    fun namesRoundTrip() {
        assertEquals(Generated("dv_transparent_2x2.png", 2, 2, 0), Generated.parse(Generated.transparentName(2, 2)))
        assertEquals(Generated("dv_transparent_1920x1080.png", 1920, 1080, 0), Generated.parse("dv_transparent_1920x1080.png"))
        val black = 0xFF000000.toInt()
        assertEquals("dv_opaque_ff000000_1280x720.png", Generated.opaqueName(black, 1280, 720))
        assertEquals(Generated("dv_opaque_ff000000_1280x720.png", 1280, 720, black), Generated.parse("dv_opaque_ff000000_1280x720.png"))
        val white = 0xFFFFFFFF.toInt()
        assertEquals(white, Generated.parse(Generated.opaqueName(white, 16, 16))!!.color)
        val teal = 0xFF00897B.toInt()
        assertEquals(Generated(Generated.opaqueName(teal, 720, 1280), 720, 1280, teal), Generated.parse(Generated.opaqueName(teal, 720, 1280)))
    }

    @Test
    fun otherNamesAreNotGenerated() {
        for (name in listOf(
            "dv_transparent_2x2.png.tmp",
            "dv_transparent_0x2.png",
            "dv_transparent_2x99999.png",
            "dv_opaque_00000000_2x2.png", // opaque images always have alpha FF
            "dv_opaque_ff00_2x2.png",
            "dv_opaque_FF000000_2x2.png",
            "photo.png",
            "dv_transparent_2x2.jpg",
        )) {
            assertNull(name, Generated.parse(name))
        }
    }

    @Test
    fun onlyFilesOfTheImagesDirectoryCount() {
        val dir = temp.newFolder("cache", "engine")
        val images = PngCompositionImages(dir)
        val name = Generated.opaqueName(0xFF000000.toInt(), 1280, 720)
        assertEquals(name, images.generated("file://" + File(dir, name).absolutePath)!!.name)
        assertEquals(images.fileOf(images.generated("file://" + File(dir, name).absolutePath)!!), File(dir, name))
        assertNull("another directory", images.generated("file://" + File(temp.newFolder("media"), name).absolutePath))
        assertNull("a subdirectory", images.generated("file://" + File(File(dir, "x"), name).absolutePath))
        assertNull("not a file URI", images.generated("content://media/external/images/1"))
        assertNull("a plain path", images.generated(File(dir, name).absolutePath))
        assertNull("user media in the directory", images.generated("file://" + File(dir, "photo.png").absolutePath))
        assertNull(images.generated(null))
    }
}
