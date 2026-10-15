// OWNER: AND-16
//
// Kotlin side of the JNI shim in src/main/cpp/ (ARCH §13.3 "Decks", AND-01.md §2): a deck's
// ImageReader frame (HardwareBuffer) becomes an EGLImage bound to an external OES texture. The
// library is loaded only behind the API 29 editor gate (`available`); below it, or when loading
// fails, the contingency backend plays through AND-10's StillFramesBackend instead. Every call runs
// on danaview-gl with the backend's EGL context current.

package com.vecvel.danaview.editor.engine.preview.fallback

import android.hardware.HardwareBuffer
import android.os.Build
import android.util.Log
import com.vecvel.danaview.editor.engine.core.EngineContext

/** HardwareBuffer → EGLImage → OES texture (file header). */
object HwbImport {
    /** The shim's library name (src/main/cpp/CMakeLists.txt). */
    const val LIBRARY = "danaview_hwb"

    /** Whether the shim is loaded (API 29+ and the library present for this ABI). */
    val available: Boolean by lazy {
        if (Build.VERSION.SDK_INT < MIN_API) {
            false
        } else {
            try {
                System.loadLibrary(LIBRARY)
                true
            } catch (e: UnsatisfiedLinkError) {
                Log.w(EngineContext.TAG, "contingency preview: native shim unavailable (${e.javaClass.simpleName})")
                false
            } catch (e: SecurityException) {
                Log.w(EngineContext.TAG, "contingency preview: native shim unavailable (${e.javaClass.simpleName})")
                false
            }
        }
    }

    /** The editor gate's API level; the shim is compiled for it. */
    const val MIN_API = 29

    /** EGLImage handle for [buffer] on the current EGL display, or 0. */
    @JvmStatic external fun nativeCreateImage(buffer: HardwareBuffer): Long

    /** Binds [image] to the external OES [texture]; false on a GL error. */
    @JvmStatic external fun nativeBindOes(texture: Int, image: Long): Boolean

    /** Destroys [image] (0 is ignored). */
    @JvmStatic external fun nativeDestroyImage(image: Long)
}
