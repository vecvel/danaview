// OWNER: AND-04
//
// D-33 placeholder created by ENG-08 (BUILD_PLAN ENG-08, ARCH §4.4). It holds only the names the
// glue calls; every call fails with `notSupportedOnDevice` (the Dart side maps that to the editor's
// unsupported state). The owner ticket replaces this file and keeps the signatures the glue uses.
// AND-04: MediaExtractorCompat + async MediaCodec to float PCM with sample-accurate ranges
// (MP4 edit lists, AAC priming).

package com.vecvel.vwish.editor.engine.media

import com.vecvel.vwish.editor.engine.core.EngineContext

/** PCM decoder (ARCH §15; AND-04). */
class PcmDecoder(private val ctx: EngineContext)
