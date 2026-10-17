// OWNER: AND-16
//
// HardwareBuffer -> EGLImage -> external OES texture import for AND-16's slot decks (ARCH §13.3
// "Decks", AND-01.md §2). Each deck decodes into its own PRIVATE ImageReader so it can hold several
// frames and the compositor can pick the one whose pts is the output frame's rule frame (a
// SurfaceTexture only latches its newest frame, which showed wrong frames at cuts in AND-01).
// Every call runs on danaview-gl with the backend's EGL context current (eglGetCurrentDisplay).
// Never logs anything.
#define EGL_EGLEXT_PROTOTYPES
#define GL_GLEXT_PROTOTYPES
#include <jni.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <android/hardware_buffer_jni.h>

extern "C" JNIEXPORT jlong JNICALL
Java_com_vecvel_danaview_editor_engine_preview_fallback_HwbImport_nativeCreateImage(JNIEnv* env, jclass, jobject buffer) {
    if (buffer == nullptr) return 0;
    AHardwareBuffer* hb = AHardwareBuffer_fromHardwareBuffer(env, buffer);
    if (hb == nullptr) return 0;
    EGLClientBuffer client = eglGetNativeClientBufferANDROID(hb);
    if (client == nullptr) return 0;
    EGLDisplay display = eglGetCurrentDisplay();
    if (display == EGL_NO_DISPLAY) return 0;
    const EGLint attrs[] = {EGL_IMAGE_PRESERVED_KHR, EGL_TRUE, EGL_NONE};
    EGLImageKHR image = eglCreateImageKHR(display, EGL_NO_CONTEXT, EGL_NATIVE_BUFFER_ANDROID, client, attrs);
    return image == EGL_NO_IMAGE_KHR ? 0 : reinterpret_cast<jlong>(image);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_vecvel_danaview_editor_engine_preview_fallback_HwbImport_nativeBindOes(JNIEnv*, jclass, jint texture, jlong image) {
    if (image == 0) return JNI_FALSE;
    while (glGetError() != GL_NO_ERROR) {
    }
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, static_cast<GLuint>(texture));
    glEGLImageTargetTexture2DOES(GL_TEXTURE_EXTERNAL_OES, reinterpret_cast<GLeglImageOES>(image));
    const bool ok = glGetError() == GL_NO_ERROR;
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, 0);
    return ok ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT void JNICALL
Java_com_vecvel_danaview_editor_engine_preview_fallback_HwbImport_nativeDestroyImage(JNIEnv*, jclass, jlong image) {
    if (image == 0) return;
    EGLDisplay display = eglGetCurrentDisplay();
    if (display == EGL_NO_DISPLAY) return;
    eglDestroyImageKHR(display, reinterpret_cast<EGLImageKHR>(image));
}
