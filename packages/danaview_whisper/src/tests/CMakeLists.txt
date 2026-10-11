# OWNER: AI-03
#
# Host tests of the whisper shim (ai.md §16.3). One runner, `dv_tests`, registered with CTest as several
# test groups so each can time out on its own. Real-model tests read DV_TEST_WHISPER_MODEL /
# DV_TEST_VAD_MODEL and skip when they are unset (scripts/ci/editor/whisper_host.sh sets them in CI).

add_executable(dv_tests
  dv_test_main.cpp
  dv_test_support.cpp
  test_wav.cpp
  test_json.cpp
  test_words.cpp
  test_chunker.cpp
  test_vad.cpp
  test_log.cpp
  test_abi.cpp
  test_jobs.cpp
  test_real_model.cpp
)
if(APPLE AND DV_SANITIZER STREQUAL "thread")
  # ggml's vm_allocate-backed buffers are invisible to TSan on macOS (see the file comment).
  target_sources(dv_tests PRIVATE dv_tsan_vm_shim.cpp)
endif()
target_include_directories(dv_tests PRIVATE "${CMAKE_CURRENT_LIST_DIR}")
target_link_libraries(dv_tests PRIVATE dv_shim)
target_compile_options(dv_tests PRIVATE -Wall -Wextra -Wno-unused-parameter ${DV_SAN_FLAGS})
target_link_options(dv_tests PRIVATE ${DV_SAN_FLAGS})
target_compile_definitions(dv_tests PRIVATE
  DV_HOST_BUILD=1
  DV_TEST_JFK_WAV="${DV_WHISPER_SOURCE_DIR}/samples/jfk.wav")

# The iOS forwarder compiles every dv_*.cpp as one translation unit; this object library proves the
# sources still do (no clashing file-local names).
add_library(dv_unity_check OBJECT dv_unity_check.cpp)
target_include_directories(dv_unity_check PRIVATE "${DV_SHIM_INCLUDE_DIR}")
target_link_libraries(dv_unity_check PRIVATE whisper)
target_compile_definitions(dv_unity_check PRIVATE DV_HOST_BUILD=1)
target_compile_options(dv_unity_check PRIVATE -Wall -Wextra -Wno-unused-parameter)
add_dependencies(dv_tests dv_unity_check)

set(DV_TEST_GROUPS Wav Json Words Chunker Vad Log Abi Model Jobs Detect Shutdown Real)
foreach(group ${DV_TEST_GROUPS})
  add_test(NAME dv_${group} COMMAND dv_tests "${group}.")
  set_tests_properties(dv_${group} PROPERTIES TIMEOUT 1800)
endforeach()
