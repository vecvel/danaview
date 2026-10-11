// OWNER: AND-09
//
// D-33 placeholder created by ENG-08 (BUILD_PLAN ENG-08, ARCH §4.4). It holds only the names the
// glue calls; every call fails with `notSupportedOnDevice` (the Dart side maps that to the editor's
// unsupported state). The owner ticket replaces this file and keeps the signatures the glue uses.
// AND-09 owns effects/ and src/main/assets/danaview_shaders/; it exposes a ShaderPrograms API for
// AND-17's layer compositor.

package com.vecvel.danaview.editor.engine.effects

/** GL shader programs of the render math (ARCH §11.6; AND-09). */
class ShaderPrograms
