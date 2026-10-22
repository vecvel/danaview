@file:OptIn(UnstableApi::class)
// OWNER: AND-08 (QA-05 D8, Android half)
//
// Loading of the engine's generated images (CompositionImages.kt) in Transformer runs. Media3's
// ImageAssetLoader opens an image item's file only when the sequence reaches the item, long after
// the composition was built, and the system may have purged the cache root in between (QA-05 D8:
// ENOENT on `engine/dv_opaque_*.png`, which failed the export). Every exporter of a
// Media3Composition (AND-11 export and its precompose passes, AND-18 render previews) therefore
// installs [GeneratedImageAssetLoaderFactory]: items whose URI is a generated image of the
// composition's [PngCompositionImages] get an ImageAssetLoader over [GeneratedImageBitmapLoader];
// everything else goes to the base factory unchanged (the exporter's own, or Transformer's default
// DefaultAssetLoaderFactory as TransformerInternal builds it, minus the metrics log session id).
//
// GeneratedImageBitmapLoader writes a missing image again before Media3's DataSourceBitmapLoader
// (configured as DefaultAssetLoaderFactory configures it) opens it. When it cannot be written (the
// volume is full) or vanishes again before it is read, the loader answers the same pixels from
// memory, so a purge of generated images never fails a job.

package com.vecvel.danaview.editor.engine.composition

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ColorSpace
import android.net.Uri
import android.os.Build
import android.os.Looper
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.util.BitmapLoader
import androidx.media3.common.util.Clock
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSourceBitmapLoader
import androidx.media3.transformer.AssetLoader
import androidx.media3.transformer.DefaultAssetLoaderFactory
import androidx.media3.transformer.DefaultDecoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.ImageAssetLoader
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.google.common.util.concurrent.MoreExecutors
import com.vecvel.danaview.editor.engine.core.EngineContext
import java.io.FileNotFoundException
import java.io.IOException

/** A [BitmapLoader] that restores purged generated images of [images] (file header). */
class GeneratedImageBitmapLoader(
    private val images: PngCompositionImages,
    private val base: BitmapLoader,
) : BitmapLoader {
    override fun supportsMimeType(mimeType: String): Boolean = base.supportsMimeType(mimeType)

    override fun decodeBitmap(data: ByteArray): ListenableFuture<Bitmap> = base.decodeBitmap(data)

    override fun loadBitmap(uri: Uri): ListenableFuture<Bitmap> {
        val g = images.generated(uri.toString()) ?: return base.loadBitmap(uri)
        if (!images.restore(g)) return Futures.immediateFuture(images.bitmap(g))
        return Futures.catching(
            base.loadBitmap(uri),
            IOException::class.java,
            { e ->
                if (!isMissing(e)) throw e
                Log.w(EngineContext.TAG, "generated image ${g.w}x${g.h} vanished before it was read; using its pixels from memory")
                images.bitmap(g)
            },
            MoreExecutors.directExecutor(),
        )
    }

    private companion object {
        /** Whether [e] (or a cause) says the file is not there. */
        fun isMissing(e: Throwable): Boolean = generateSequence(e) { it.cause }.take(8).any {
            it is FileNotFoundException || it.message.orEmpty().contains("ENOENT")
        }
    }
}

/** Routes generated-image items to [GeneratedImageBitmapLoader] and the rest to [base] (file header). */
class GeneratedImageAssetLoaderFactory(
    context: Context,
    private val images: PngCompositionImages,
    /** Everything else (null: Transformer's default DefaultAssetLoaderFactory). */
    base: AssetLoader.Factory?,
) : AssetLoader.Factory {
    private val context = context.applicationContext
    private val base: AssetLoader.Factory by lazy {
        base ?: DefaultAssetLoaderFactory(this.context, DefaultDecoderFactory.Builder(this.context).build(), Clock.DEFAULT, null)
    }
    private val imageFactory: AssetLoader.Factory by lazy {
        ImageAssetLoader.Factory(this.context, GeneratedImageBitmapLoader(images, defaultBitmapLoader(this.context)))
    }

    /** Whether [item] is a generated image of [images] (an image item with an image duration). */
    fun isGenerated(item: EditedMediaItem): Boolean {
        val local = item.mediaItem.localConfiguration ?: return false
        return local.imageDurationMs != C.TIME_UNSET && images.generated(local.uri.toString()) != null
    }

    override fun createAssetLoader(
        editedMediaItem: EditedMediaItem,
        looper: Looper,
        listener: AssetLoader.Listener,
        compositionSettings: AssetLoader.CompositionSettings,
    ): AssetLoader {
        val factory = if (isGenerated(editedMediaItem)) imageFactory else base
        return factory.createAssetLoader(editedMediaItem, looper, listener, compositionSettings)
    }

    companion object {
        /**
         * The bitmap loader DefaultAssetLoaderFactory 1.11.1 builds for images (sRGB decoding,
         * outputs up to 4096 px), on Media3's shared bitmap executor instead of a new thread per
         * factory.
         */
        fun defaultBitmapLoader(context: Context): BitmapLoader {
            val builder = DataSourceBitmapLoader.Builder(context.applicationContext)
                .setExecutorService(DataSourceBitmapLoader.DEFAULT_EXECUTOR_SERVICE.get())
                .setMaximumOutputDimension(MAX_OUTPUT_DIMENSION)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                builder.setBitmapFactoryOptions(BitmapFactory.Options().apply { inPreferredColorSpace = ColorSpace.get(ColorSpace.Named.SRGB) })
            }
            return builder.build()
        }

        /** DefaultAssetLoaderFactory's maximum image output dimension. */
        const val MAX_OUTPUT_DIMENSION = 4096
    }
}
