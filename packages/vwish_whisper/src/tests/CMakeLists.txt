# OWNER: AI-03
#
# Host tests of the whisper shim (ai.md §16.3). One runner, `vw_tests`, registered with CTest as several
# test groups so each can time out on its own. Real-model tests read VW_TEST_WHISPER_MODEL /
# VW_TEST_VAD_MODEL and skip when they are unset (scripts/ci/editor/whisper_host.sh sets them in CI).

add_executable(vw_tests
  vw_test_main.cpp
  vw_test_support.cpp
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
if(APPLE AND VW_SANITIZER STREQUAL "thread")
  # ggml's vm_allocate-backed buffers are invisible to TSan on macOS (see the file comment).
  target_sources(vw_tests PRIVATE vw_tsan_vm_shim.cpp)
endif()
target_include_directories(vw_tests PRIVATE "${CMAKE_CURRENT_LIST_DIR}")
target_link_libraries(vw_tests PRIVATE vw_shim)
target_compile_options(vw_tests PRIVATE -Wall -Wextra -Wno-unused-parameter ${VW_SAN_FLAGS})
target_link_options(vw_tests PRIVATE ${VW_SAN_FLAGS})
target_compile_definitions(vw_tests PRIVATE
  VW_HOST_BUILD=1
  VW_TEST_JFK_WAV="${VW_WHISPER_SOURCE_DIR}/samples/jfk.wav")

# The iOS forwarder compiles every vw_*.cpp as one translation unit; this object library proves the
# sources still do (no clashing file-local names).
add_library(vw_unity_check OBJECT vw_unity_check.cpp)
target_include_directories(vw_unity_check PRIVATE "${VW_SHIM_INCLUDE_DIR}")
target_link_libraries(vw_unity_check PRIVATE whisper)
target_compile_definitions(vw_unity_check PRIVATE VW_HOST_BUILD=1)
target_compile_options(vw_unity_check PRIVATE -Wall -Wextra -Wno-unused-parameter)
add_dependencies(vw_tests vw_unity_check)

set(VW_TEST_GROUPS Wav Json Words Chunker Vad Log Abi Model Jobs Detect Shutdown Real)
foreach(group ${VW_TEST_GROUPS})
  add_test(NAME vw_${group} COMMAND vw_tests "${group}.")
  set_tests_properties(vw_${group} PROPERTIES TIMEOUT 1800)
endforeach()
