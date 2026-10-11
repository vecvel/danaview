// OWNER: AND-08
//
// D-33 placeholder created by ENG-08 (BUILD_PLAN ENG-08, ARCH §4.4). It holds only the names the
// glue calls; every call fails with `notSupportedOnDevice` (the Dart side maps that to the editor's
// unsupported state). The owner ticket replaces this file and keeps the signatures the glue uses.
// AND-08 owns plan/ (plan reader, ParamSnapshot) and composition/ (mapper, gating, speed and gain
// providers); this file only marks the package.

package com.vecvel.vwish.editor.engine.plan

/** RenderPlan v1 reader (ARCH §11; AND-08). */
class PlanReader
