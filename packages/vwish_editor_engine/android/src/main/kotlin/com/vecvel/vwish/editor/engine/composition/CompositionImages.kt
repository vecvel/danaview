// OWNER: AND-08
//
// The generated images a composition needs (ARCH §13.3 "Sequence stack"): the 2×2 transparent
// clock band, canvas-size transparent gap fills (AND-01 V-N18/V-N25: never `addGap`), the
// canvas-size opaque background and the white source of solid layers. They are written once per
// size/colour as PNG into the engine's generated-assets directory (`Paths.engineAssets`, under the
// Dart cache root) and referenced by `file://` URI.

package com.vecvel.vwish.editor.engine.composition

import android.graphics.Bitmap
import androidx.core.graphics.createBitmap
import java.io.File

/** URIs of generated images (file header). */
interface CompositionImages {
    /** A fully transparent [w] × [h] image. */
    fun transparent(w: Int, h: Int): String

    /** An opaque [w] × [h] image of [argb] (alpha forced to FF). */
    fun opaque(argb: Int, w: Int, h: Int): String

    companion object {
        /** Clock band edge (ARCH: one 2×2 transparent image item). */
        const val CLOCK_BAND_SIZE = 2

        /** Edge of the white source of solid layers (scaled to `base` by LayerPlaceEffect). */
        const val SOLID_SOURCE_SIZE = 16
    }
}

/** [CompositionImages] writing PNGs into [dir] (created on demand; atomic rename). */
class PngCompositionImages(private val dir: File) : CompositionImages {
    override fun transparent(w: Int, h: Int): String = png("vw_transparent_${w}x$h.png", w, h, 0)

    override fun opaque(argb: Int, w: Int, h: Int): String {
        val color = argb or 0xFF000000.toInt()
        return png("vw_opaque_${Integer.toHexString(color)}_${w}x$h.png", w, h, color)
    }

    @Synchronized
    private fun png(name: String, w: Int, h: Int, color: Int): String {
        val file = File(dir, name)
        if (!file.isFile) {
            dir.mkdirs()
            val tmp = File(dir, "$name.tmp")
            val bmp = createBitmap(w, h, Bitmap.Config.ARGB_8888)
            try {
                bmp.eraseColor(color)
                tmp.outputStream().use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
            } finally {
                bmp.recycle()
            }
            if (!tmp.renameTo(file)) {
                tmp.delete()
                check(file.isFile) { "cannot write a generated image" }
            }
        }
        return "file://" + file.absolutePath
    }
}
