// OWNER: ENG-05
//
// Bitmap adapter of the frame barcode reader for instrumented tests (frames from
// MediaMetadataRetriever, PixelCopy of the preview surface, ImageReader).

package com.vecvel.danaview.editor.engine.support

import android.graphics.Bitmap

/** Reads the barcode band of [bitmap] (any config; converted to ARGB_8888 pixels). */
fun FrameBarcode.read(bitmap: Bitmap, region: FrameBarcodeRegion? = null): FrameBarcodeReading {
    val w = bitmap.width
    val h = bitmap.height
    val argb = IntArray(w * h)
    bitmap.getPixels(argb, 0, w, 0, 0, w, h)
    return readArgb(argb, w, h, region)
}

/** Decodes the frame index of [bitmap] or returns null. */
fun FrameBarcode.decode(bitmap: Bitmap, region: FrameBarcodeRegion? = null): Int? =
    read(bitmap, region).index
