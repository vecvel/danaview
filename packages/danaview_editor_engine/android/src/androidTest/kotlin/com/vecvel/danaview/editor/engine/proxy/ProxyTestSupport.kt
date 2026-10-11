@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-05
//
// Decoder choice for the AND-05 instrumented tests. The x86_64 emulator's default (goldfish,
// hardware-backed) H.264 decoder loses one B-frame of the ENG-05 fixtures' B-pyramid GOPs, so a
// proxy made through it has one frame fewer than the source (measured on Pixel_9_Pro_XL_API_35,
// 2026-10-11; AND-08 recorded the same defect). The PTS tests therefore run the proxy Transformer
// with software decoders first; `ProxyJobTest.defaultDecodersKeepTimestamps` shows that the
// production default still never changes a timestamp. The production decoder path is NOT shown to
// be frame-exact (API 29 emulator: frames 1-5 lost with both OMX decoders, including the software
// OMX.google.h264.decoder); see ProxyJob.kt "KNOWN LIMITATION".

package com.vecvel.danaview.editor.engine.proxy

import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.util.Clock
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSourceBitmapLoader
import androidx.media3.exoplayer.mediacodec.MediaCodecUtil
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.transformer.AssetLoader
import androidx.media3.transformer.DefaultAssetLoaderFactory
import androidx.media3.transformer.DefaultDecoderFactory

object ProxyTestDecoders {
    /** An asset loader whose decoder list puts software decoders first. */
    fun softwareFirst(context: Context): AssetLoader.Factory = DefaultAssetLoaderFactory(
        context,
        DefaultDecoderFactory.Builder(context)
            .setMediaCodecSelector { mime, secure, tunneling ->
                MediaCodecUtil.getDecoderInfos(mime, secure, tunneling).sortedBy { if (it.softwareOnly) 0 else 1 }
            }
            .build(),
        Clock.DEFAULT,
        DefaultMediaSourceFactory(context),
        DataSourceBitmapLoader.Builder(context).build(),
    )
}
