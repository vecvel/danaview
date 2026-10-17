# OWNER: AND-16
#
# The editor engine's only native code (ARCH §13.3 "Decks" and "Build", AND-01.md §2, §7): the
# HardwareBuffer -> EGLImage -> external OES texture import of AND-16's slot decks. API 29 has no
# SDK call that turns a HardwareBuffer into an EGLClientBuffer, so the decks' ImageReader frames go
# through this shim (port of spikes/android_engine/app/src/main/cpp/). ENG-06's frozen
# build.gradle.kts switches the CMake build on when this file exists and sets the ABIs
# (arm64-v8a, armeabi-v7a, x86_64), ANDROID_PLATFORM=android-29, the static C++ runtime,
# 16 KB page alignment, NDK 28.2.13676358 and the SDK's CMake 3.22.1. Kotlin side:
# preview/fallback/HwbImport.kt (System.loadLibrary only behind the API 29 editor gate).
cmake_minimum_required(VERSION 3.22.1)
project(danaview_hwb CXX)

add_library(danaview_hwb SHARED hwb_import.cpp)
target_compile_options(danaview_hwb PRIVATE -Wall -Wextra -Werror -fvisibility=hidden)
target_link_libraries(danaview_hwb EGL GLESv2 android nativewindow log)
