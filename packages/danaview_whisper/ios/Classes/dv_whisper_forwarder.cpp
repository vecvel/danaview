// OWNER: AI-05
//
// iOS: compiles the whole C ABI shim (src/dv_*.cpp, AI-03) into the danaview_whisper pod, the way the
// Flutter FFI plugin template forwards ../../src. CocoaPods only compiles files under ios/, so the
// shared sources are #included here as ONE translation unit; src/tests/dv_unity_check.cpp builds the
// same list on the host so a clash between file-local helpers fails CI there too. Keep both lists
// in sync with DV_SHIM_SOURCES in src/CMakeLists.txt.
//
// Linking: whisper.cpp/ggml come from the static WhisperCore.xcframework (tool/build_ios_xcframework.sh)
// built with -fvisibility=hidden, so the pod's binary exports only the dv_* entry points. Each entry
// point is DV_API = visibility("default") + used, which keeps it alive through -dead_strip and
// "Strip Linked Product" (non-global), so Dart finds it with
//   DynamicLibrary.open('danaview_whisper.framework/danaview_whisper')   (use_frameworks!, the app's setup)
//   DynamicLibrary.process()                                      (static linkage)
// With static linkage nothing references this object file, so a host would force-load it with
// `-Wl,-u,_dv_abi_version` (no -all_load needed); the app uses use_frameworks! and does not need that.
//
// Metal policy at load (the only logic in this file): ggml creates its Metal device, and compiles the
// whole EMBEDDED Metal library from source, the first time anything touches its backend registry,
// even when the shim asks whisper for use_gpu = false. Measured with the AI-05 probe on the iOS 26.5
// simulator: 31 s on the first model load; on devices the GPU policy (src/dv_cpu.cpp gpu_allowed:
// not simulator, iOS >= 16.4, Apple GPU family >= 6) rejects, that compile is pure waste. ggml reads
// GGML_METAL_DEVICES once, when the registry is created, so this constructor sets it to 0 where the
// policy can be decided without touching Metal: the simulator and iOS < 16.4. It never overrides a
// value set by the developer. The Apple GPU family < 6 case on iOS >= 16.4 needs a Metal device and
// belongs in the shim's model loader (handoff to AI-03).
//
// Rules for this file: no Objective-C (the shim reaches Metal through the objc runtime in dv_cpu.cpp),
// and it must compile with -Werror=unguarded-availability-new (pod_target_xcconfig).

#include "../../src/dv_whisper.cpp"
#include "../../src/dv_log.cpp"
#include "../../src/dv_cpu.cpp"
#include "../../src/dv_wav.cpp"
#include "../../src/dv_chunker.cpp"
#include "../../src/dv_words.cpp"
#include "../../src/dv_json.cpp"
#include "../../src/dv_vad.cpp"
#include "../../src/dv_registry.cpp"
#include "../../src/dv_model.cpp"
#include "../../src/dv_job.cpp"

static_assert(DV_ABI_VERSION == 1, "the iOS forwarder was written against dv_whisper.h ABI 1");

#include <TargetConditionals.h>
#include <stdlib.h>

namespace {

__attribute__((constructor)) void dv_ios_metal_device_policy() {
#if TARGET_OS_SIMULATOR
  setenv("GGML_METAL_DEVICES", "0", 0);
#else
  if (__builtin_available(iOS 16.4, *)) {
    return;  // Metal allowed if the GPU family is >= 6 (decided per model load by the shim).
  }
  setenv("GGML_METAL_DEVICES", "0", 0);
#endif
}

}  // namespace
