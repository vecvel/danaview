# OWNER: AI-04
#
# Android native build of the danaview whisper shim (ai.md §4.3, BUILD_PLAN AI-04).
# Included by src/CMakeLists.txt (AI-03) when ANDROID or DV_ANDROID is set, after it has defined
# DV_SHIM_SOURCES, DV_SHIM_INCLUDE_DIR and DV_WHISPER_SOURCE_DIR. Gradle drives it through
# android/build.gradle.kts (externalNativeBuild, SDK CMake 3.22.1, Ninja).
#
# Outputs per ABI:
#   arm64-v8a  libdanaview_whisper.so      whisper/ggml built with -march=armv8-a (baseline, always safe)
#              libdanaview_whisper_v82.so  whisper/ggml built with -march=armv8.2-a+fp16+dotprod
#   x86_64     libdanaview_whisper.so      ggml defaults with GGML_NATIVE=OFF (emulators)
# armeabi-v7a and x86 are refused (owner default D-43(b): no auto captions on 32-bit ABIs).
#
# whisper.cpp + ggml are configured as static libraries through ExternalProject, once per variant,
# because two ggml builds with different -march cannot live in one CMake project (same target names).
# Both variants link the same 11 shim translation units into a self-contained shared library:
#   * c++_static (media_kit ships libc++_shared.so; a second shared STL could collide in packaging),
#   * only dv_* exported (dv_exports.map), everything else local, --gc-sections,
#   * 16 KB page alignment (-z max-page-size=16384; explicit so it also holds on NDK r27),
#   * -O3, no OpenMP, no KleidiAI (it downloads sources at build time), no dynamic backends.
# The Dart loader (AI-07) opens libdanaview_whisper.so, calls dv_cpu_features() (raw getauxval(AT_HWCAP))
# and switches to libdanaview_whisper_v82.so when HWCAP_FPHP, HWCAP_ASIMDHP and HWCAP_ASIMDDP are set.
#
# Native jobs are capped (DV_NATIVE_JOBS, default 8): the two arm64 ExternalProjects build one after
# the other with -j DV_NATIVE_JOBS, and the shim compiles and links share a Ninja pool of the same size
# after both have finished.

include(ExternalProject)

if(NOT DEFINED DV_SHIM_SOURCES OR NOT DEFINED DV_SHIM_INCLUDE_DIR OR NOT DEFINED DV_WHISPER_SOURCE_DIR)
  message(FATAL_ERROR "android.cmake must be included from packages/danaview_whisper/src/CMakeLists.txt")
endif()

set(DV_ABI "${ANDROID_ABI}")
if(NOT DV_ABI)
  set(DV_ABI "${CMAKE_ANDROID_ARCH_ABI}")
endif()
if(DV_ABI STREQUAL "arm64-v8a")
  set(DV_VARIANTS v80 v82)
elseif(DV_ABI STREQUAL "x86_64")
  set(DV_VARIANTS x64)
else()
  message(FATAL_ERROR "danaview_whisper builds arm64-v8a and x86_64 only (D-43(b)); got ABI '${DV_ABI}'. "
                      "Check abiFilters in packages/danaview_whisper/android/build.gradle.kts.")
endif()

set(DV_PLATFORM "${ANDROID_PLATFORM}")
if(NOT DV_PLATFORM)
  set(DV_PLATFORM "android-${CMAKE_SYSTEM_VERSION}")
endif()

# AGP passes Windows paths with backslashes; forwarded as-is they become invalid escapes in the
# ExternalProject scripts.
file(TO_CMAKE_PATH "${CMAKE_TOOLCHAIN_FILE}" DV_TOOLCHAIN_FILE)
file(TO_CMAKE_PATH "${CMAKE_MAKE_PROGRAM}" DV_MAKE_PROGRAM)

set(DV_NATIVE_JOBS 8 CACHE STRING "Maximum parallel native compile jobs for the whisper Android build")
set(DV_EXPORTS_MAP "${DV_SHIM_INCLUDE_DIR}/dv_exports.map")
get_filename_component(DV_EXPORTS_MAP "${DV_EXPORTS_MAP}" ABSOLUTE)

# One Ninja pool for every shim compile and link, so the outer build never exceeds DV_NATIVE_JOBS.
set_property(GLOBAL APPEND PROPERTY JOB_POOLS dv_native_pool=${DV_NATIVE_JOBS})
set(CMAKE_JOB_POOL_COMPILE dv_native_pool)
set(CMAKE_JOB_POOL_LINK dv_native_pool)

# whisper/ggml are always optimized (also in Debug app builds: an -O0 ggml is unusably slow), hidden by
# default and split into sections so --gc-sections drops what the shim does not reach.
set(DV_DEP_FLAGS "-fvisibility=hidden -fvisibility-inlines-hidden -ffunction-sections -fdata-sections")
set(DV_DEP_FLAGS_RELEASE "-O3 -DNDEBUG")

set(DV_PAGE_FLAGS "")
if(DEFINED ANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES)
  list(APPEND DV_PAGE_FLAGS "-DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=${ANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES}")
endif()

set(DV_PREVIOUS_EP "")
foreach(variant IN LISTS DV_VARIANTS)
  set(bin "${CMAKE_CURRENT_BINARY_DIR}/whisper_${variant}")
  set(arch_args "")
  if(variant STREQUAL "v80")
    set(arch_args "-DGGML_CPU_ARM_ARCH=armv8-a")
  elseif(variant STREQUAL "v82")
    set(arch_args "-DGGML_CPU_ARM_ARCH=armv8.2-a+fp16+dotprod")
  endif()

  # Static archives of one variant. lld resolves archives in any order.
  set(libs
    "${bin}/src/libwhisper.a"
    "${bin}/ggml/src/libggml.a"
    "${bin}/ggml/src/libggml-cpu.a"
    "${bin}/ggml/src/libggml-base.a")
  set(DV_LIBS_${variant} ${libs})

  set(ep_depends "")
  if(DV_PREVIOUS_EP)
    set(ep_depends DEPENDS ${DV_PREVIOUS_EP})
  endif()

  ExternalProject_Add(dv_whisper_${variant}_ep
    SOURCE_DIR "${DV_WHISPER_SOURCE_DIR}"
    BINARY_DIR "${bin}"
    ${ep_depends}
    CMAKE_ARGS
      "-DCMAKE_TOOLCHAIN_FILE=${DV_TOOLCHAIN_FILE}"
      "-DCMAKE_MAKE_PROGRAM=${DV_MAKE_PROGRAM}"
      "-DANDROID_ABI=${DV_ABI}"
      "-DANDROID_PLATFORM=${DV_PLATFORM}"
      "-DANDROID_STL=c++_static"
      ${DV_PAGE_FLAGS}
      "-DCMAKE_BUILD_TYPE=Release"
      "-DCMAKE_C_FLAGS=${DV_DEP_FLAGS}"
      "-DCMAKE_CXX_FLAGS=${DV_DEP_FLAGS}"
      "-DCMAKE_C_FLAGS_RELEASE=${DV_DEP_FLAGS_RELEASE}"
      "-DCMAKE_CXX_FLAGS_RELEASE=${DV_DEP_FLAGS_RELEASE}"
      "-DBUILD_SHARED_LIBS=OFF"
      "-DWHISPER_BUILD_IS_DEV=OFF"
      "-DWHISPER_BUILD_EXAMPLES=OFF"
      "-DWHISPER_BUILD_TESTS=OFF"
      "-DWHISPER_BUILD_SERVER=OFF"
      "-DWHISPER_CURL=OFF"
      "-DWHISPER_SDL2=OFF"
      "-DWHISPER_COREML=OFF"
      "-DWHISPER_OPENVINO=OFF"
      "-DWHISPER_ALL_WARNINGS=OFF"
      "-DGGML_NATIVE=OFF"
      "-DGGML_OPENMP=OFF"
      "-DGGML_CPU_KLEIDIAI=OFF"
      "-DGGML_BACKEND_DL=OFF"
      "-DGGML_CPU_ALL_VARIANTS=OFF"
      "-DGGML_METAL=OFF"
      "-DGGML_BLAS=OFF"
      "-DGGML_ACCELERATE=OFF"
      "-DGGML_VULKAN=OFF"
      "-DGGML_LLAMAFILE=OFF"
      "-DGGML_CCACHE=OFF"
      "-DGGML_ALL_WARNINGS=OFF"
      ${arch_args}
    BUILD_COMMAND ${CMAKE_COMMAND} --build <BINARY_DIR> --target whisper -j ${DV_NATIVE_JOBS}
    BUILD_BYPRODUCTS ${libs}
    INSTALL_COMMAND ""
    TEST_COMMAND ""
    # Rebuild when the vendored sources change (a no-op Ninja run otherwise; the byproducts keep their
    # timestamps, so the shim does not relink).
    BUILD_ALWAYS ON
    LOG_CONFIGURE ON
    LOG_OUTPUT_ON_FAILURE ON)
  set(DV_PREVIOUS_EP dv_whisper_${variant}_ep)
endforeach()

# All ExternalProjects finish before any shim compile starts (keeps the job cap).
set(DV_ALL_EPS "")
foreach(variant IN LISTS DV_VARIANTS)
  list(APPEND DV_ALL_EPS dv_whisper_${variant}_ep)
endforeach()

function(dv_add_shim target variant)
  add_library(${target} SHARED ${DV_SHIM_SOURCES})
  add_dependencies(${target} ${DV_ALL_EPS})
  target_include_directories(${target} PRIVATE
    "${DV_SHIM_INCLUDE_DIR}"
    "${DV_WHISPER_SOURCE_DIR}/include"
    "${DV_WHISPER_SOURCE_DIR}/ggml/include")
  set_target_properties(${target} PROPERTIES
    CXX_STANDARD 17
    CXX_STANDARD_REQUIRED ON
    CXX_EXTENSIONS OFF
    CXX_VISIBILITY_PRESET hidden
    C_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
    LINK_DEPENDS "${DV_EXPORTS_MAP}")
  # -O3 in every configuration (comes after the toolchain's -O0 in Debug, so it wins).
  target_compile_options(${target} PRIVATE
    -O3 -ffunction-sections -fdata-sections
    -Wall -Wextra -Werror=format -Wno-unused-parameter)
  target_link_options(${target} PRIVATE
    "-Wl,--version-script=${DV_EXPORTS_MAP}"
    "-Wl,--gc-sections"
    "-Wl,--exclude-libs,ALL"
    "-Wl,-z,max-page-size=16384"
    "-Wl,--no-undefined")
  target_link_libraries(${target} PRIVATE ${DV_LIBS_${variant}} log dl m)
endfunction()

if(DV_ABI STREQUAL "arm64-v8a")
  dv_add_shim(danaview_whisper v80)
  dv_add_shim(danaview_whisper_v82 v82)
else()
  dv_add_shim(danaview_whisper x64)
endif()
