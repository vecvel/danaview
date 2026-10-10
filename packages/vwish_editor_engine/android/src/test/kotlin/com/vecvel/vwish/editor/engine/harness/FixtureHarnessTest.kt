// OWNER: ENG-09
//
// Proves the example host's harness exposes the shared fixtures to the plugin's JVM tests and
// compiles the ENG-05 barcode reader into this source set.

package com.vecvel.vwish.editor.engine.harness

import com.vecvel.vwish.editor.engine.support.FrameBarcode
import com.vecvel.vwish.editor.engine.support.FrameBarcodeStatus
import javax.imageio.ImageIO
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FixtureHarnessTest {
    @Test
    fun harnessPassesEveryFixtureRootAsASystemProperty() {
        for (tree in FixtureTree.values()) {
            val path = System.getProperty(tree.property)
            assertNotNull("system property ${tree.property}", path)
            assertEquals(JvmFixtures.root(tree).canonicalPath, java.io.File(path!!).canonicalPath)
        }
    }

    @Test
    fun everyTreeResolves() {
        assertTrue(JvmFixtures.file(FixtureTree.ENGINE, "media/manifest.json").isFile)
        assertTrue(JvmFixtures.file(FixtureTree.ENGINE, "media/frame_counter_1080p30.mp4").isFile)
        assertTrue(JvmFixtures.file(FixtureTree.CORE, "vectors/frame_grid.json").isFile)
        assertTrue(JvmFixtures.root(FixtureTree.ENGINE_API).listFiles().orEmpty().isNotEmpty())
    }

    @Test
    fun barcodeReaderDecodesACommittedFrame() {
        val png = JvmFixtures.file(FixtureTree.ENGINE, "media/frames/frame_counter_1080p30_160.png")
        val image = ImageIO.read(png)
        val w = image.width
        val h = image.height
        val argb = image.getRGB(0, 0, w, h, null, 0, w)
        val reading = FrameBarcode.readArgb(argb, w, h)
        assertEquals(FrameBarcodeStatus.OK, reading.status)
        assertEquals(160, reading.index)
    }
}
