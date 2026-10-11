// OWNER: AND-08
//
// D-33 placeholder created by ENG-08 (BUILD_PLAN ENG-08, ARCH §4.4). It holds only the names the
// glue calls; every call fails with `notSupportedOnDevice` (the Dart side maps that to the editor's
// unsupported state). The owner ticket replaces this file and keeps the signatures the glue uses.
// AND-08: plan -> Media3 Composition (gaps as transparent image items at the output fps,
// SNAP_TO_RULE_FRAME starts, setFrameRate(gridFps) above 1x; AND-01 §6.7).

package com.vecvel.vwish.editor.engine.composition

/** Composition mapper (ARCH §13.3, §14.3; AND-08). */
class CompositionMapper
