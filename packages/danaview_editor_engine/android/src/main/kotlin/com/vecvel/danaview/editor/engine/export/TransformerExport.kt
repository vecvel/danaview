// OWNER: AND-11
//
// D-33 placeholder created by ENG-08 (BUILD_PLAN ENG-08, ARCH §4.4). It holds only the names the
// glue calls; every call fails with `notSupportedOnDevice` (the Dart side maps that to the editor's
// unsupported state). The owner ticket replaces this file and keeps the signatures the glue uses.

package com.vecvel.danaview.editor.engine.export

/** One Transformer per export job on danaview-export (ARCH §14.3; AND-11). */
class TransformerExport
