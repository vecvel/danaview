# AND-01 spike: HardwareBuffer -> EGLImage -> OES texture import for the contingency prototype
# (ContingencyEngineProto, FrameSource.IMAGE_READER). Built by Gradle with the SDK's CMake 3.22.1.
cmake_minimum_required(VERSION 3.22.1)
project(dvspike_hwb CXX)
add_library(dvspike_hwb SHARED hwb_import.cpp)
target_link_libraries(dvspike_hwb EGL GLESv2 android nativewindow log)
