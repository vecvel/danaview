// OWNER: AND-02
//
// D-33 placeholder created by ENG-08 (BUILD_PLAN ENG-08, ARCH §4.4). It holds only the names the
// glue calls; every call fails with `notSupportedOnDevice` (the Dart side maps that to the editor's
// unsupported state). The owner ticket replaces this file and keeps the signatures the glue uses.
// AND-02: RAM, isLowRamDevice, SoC, codec max instances, and the thermal listener
// (PowerManager.OnThermalStatusChangedListener -> ctx.events.signal(thermal)).

package com.vecvel.vwish.editor.engine.core

/** Device profile used by capabilities and tiers (ARCH §3.2, §12.5; AND-02). */
class DeviceProfile(private val ctx: EngineContext)
