# OWNER: QA-06
#
# Host build of the eval runner (ai.md §16.5): the same danaview whisper shim and vendored whisper.cpp
# as the device builds, CPU backend only (danaview_whisper/src/CMakeLists.txt host branch), plus
# `dv_eval_runner`, a small CLI the Dart eval harness (tool/eval/) calls once per clip and tier.
#
# The runner also links AI-03's host-test support file for one thing only: writing the deterministic
# fixture whisper/VAD models, so the nightly job has a smoke mode that needs no download.
#
#   cmake -S packages/danaview_transcription/tool/eval/native -B <build> -DCMAKE_BUILD_TYPE=Release
#   cmake --build <build> --target dv_eval_runner
cmake_minimum_required(VERSION 3.14)
project(danaview_eval_runner C CXX)

set(DV_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(DV_SANITIZER "none" CACHE STRING "" FORCE)
set(DV_WHISPER_SRC "${CMAKE_CURRENT_LIST_DIR}/../../../../danaview_whisper/src")
get_filename_component(DV_WHISPER_SRC "${DV_WHISPER_SRC}" ABSOLUTE)
add_subdirectory("${DV_WHISPER_SRC}" dv_shim_build)

add_executable(dv_eval_runner
  dv_eval_runner.cpp
  "${DV_WHISPER_SRC}/tests/dv_test_support.cpp"
)
target_include_directories(dv_eval_runner PRIVATE "${DV_WHISPER_SRC}" "${DV_WHISPER_SRC}/tests")
target_link_libraries(dv_eval_runner PRIVATE dv_shim)
target_compile_features(dv_eval_runner PRIVATE cxx_std_17)
target_compile_options(dv_eval_runner PRIVATE -Wall -Wextra -Wno-unused-parameter)
# dv_test_support.cpp reads the jfk sample path from this define; the runner never uses it.
target_compile_definitions(dv_eval_runner PRIVATE DV_HOST_BUILD=1 DV_TEST_JFK_WAV="")
