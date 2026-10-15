// TEMPORARY DIAGNOSTIC (AND-18 off-by-one investigation); delete before finishing.
package com.vecvel.danaview.editor.engine.effects

object DiagTmpDump {
    @Volatile @JvmStatic var dir: java.io.File? = null
    @Volatile @JvmStatic var tag: String = "x"
    @JvmStatic val seq = java.util.concurrent.atomic.AtomicInteger()
}
