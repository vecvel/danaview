package com.vecvel.danaview.spike.engine

import android.hardware.HardwareBuffer

/** JNI shim (src/main/cpp/hwb_import.cpp): HardwareBuffer → EGLImage → OES texture, on the GL thread. */
object HwbImport {
    init {
        System.loadLibrary("dvspike_hwb")
    }

    /** EGLImage handle for [buffer] on the current EGL display, or 0. */
    @JvmStatic external fun nativeCreateImage(buffer: HardwareBuffer): Long

    /** Binds [image] to the external OES [texture]; false on a GL error. */
    @JvmStatic external fun nativeBindOes(texture: Int, image: Long): Boolean

    @JvmStatic external fun nativeDestroyImage(image: Long)
}
