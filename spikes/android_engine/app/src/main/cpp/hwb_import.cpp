// AND-01 spike: imports an AHardwareBuffer (ImageReader image) as an EGLImage bound to an
// external OES texture, so the contingency compositor can hold several decoded frames per slot
// and pick the one whose pts matches the output frame (SurfaceTexture keeps only the latest).
#define EGL_EGLEXT_PROTOTYPES
#define GL_GLEXT_PROTOTYPES
#include <jni.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <android/hardware_buffer_jni.h>

extern "C" JNIEXPORT jlong JNICALL
Java_com_vecvel_danaview_spike_engine_HwbImport_nativeCreateImage(JNIEnv* env, jclass, jobject buffer) {
    AHardwareBuffer* hb = AHardwareBuffer_fromHardwareBuffer(env, buffer);
    if (hb == nullptr) return 0;
    EGLClientBuffer client = eglGetNativeClientBufferANDROID(hb);
    if (client == nullptr) return 0;
    const EGLint attrs[] = {EGL_IMAGE_PRESERVED_KHR, EGL_TRUE, EGL_NONE};
    EGLImageKHR image = eglCreateImageKHR(eglGetCurrentDisplay(), EGL_NO_CONTEXT, EGL_NATIVE_BUFFER_ANDROID, client, attrs);
    return image == EGL_NO_IMAGE_KHR ? 0 : reinterpret_cast<jlong>(image);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_vecvel_danaview_spike_engine_HwbImport_nativeBindOes(JNIEnv*, jclass, jint texture, jlong image) {
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, static_cast<GLuint>(texture));
    glEGLImageTargetTexture2DOES(GL_TEXTURE_EXTERNAL_OES, reinterpret_cast<GLeglImageOES>(image));
    return glGetError() == GL_NO_ERROR;
}

extern "C" JNIEXPORT void JNICALL
Java_com_vecvel_danaview_spike_engine_HwbImport_nativeDestroyImage(JNIEnv*, jclass, jlong image) {
    if (image != 0) eglDestroyImageKHR(eglGetCurrentDisplay(), reinterpret_cast<EGLImageKHR>(image));
}
