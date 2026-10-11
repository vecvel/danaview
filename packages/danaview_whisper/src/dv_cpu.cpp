// OWNER: AI-03
//
// CPU feature / core probes and the GPU policy (see dv_cpu.h).
#include "dv_cpu.h"

#if defined(__ANDROID__) || defined(__linux__)
#include <sys/auxv.h>
#endif

#if defined(__APPLE__)
#include <TargetConditionals.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR && !defined(DV_HOST_BUILD)
#include <objc/message.h>
#include <objc/runtime.h>
#define DV_IOS_DEVICE 1
// Metal's C entry point; the pod links Metal.framework (AI-05).
extern "C" void *MTLCreateSystemDefaultDevice(void);
#endif
#endif

namespace dv {

uint64_t cpu_features() {
#if (defined(__ANDROID__) || defined(__linux__)) && defined(__aarch64__)
  return static_cast<uint64_t>(getauxval(AT_HWCAP));
#else
  return 0;
#endif
}

int32_t perf_core_count() {
#if defined(__APPLE__)
  int value = 0;
  size_t size = sizeof(value);
  if (sysctlbyname("hw.perflevel0.physicalcpu", &value, &size, nullptr, 0) == 0 && value > 0) return value;
  return 0;
#else
  return 0;
#endif
}

namespace cpu_detail {

#if defined(DV_IOS_DEVICE)
// [MTLCreateSystemDefaultDevice() supportsFamily:MTLGPUFamilyApple6] through the Objective-C runtime, so
// the shim stays plain C++ (the iOS forwarder compiles it as a .cpp file).
bool metal_supports_apple6() {
  void *device = MTLCreateSystemDefaultDevice();
  if (device == nullptr) return false;
  constexpr long kMTLGPUFamilyApple6 = 1006;
  using SupportsFn = signed char (*)(void *, SEL, long);
  const SEL supports = sel_registerName("supportsFamily:");
  const bool ok = reinterpret_cast<SupportsFn>(objc_msgSend)(device, supports, kMTLGPUFamilyApple6) != 0;
  using ReleaseFn = void (*)(void *, SEL);
  reinterpret_cast<ReleaseFn>(objc_msgSend)(device, sel_registerName("release"));
  return ok;
}
#endif

}  // namespace cpu_detail

bool gpu_allowed(bool requested) {
  if (!requested) return false;
#if defined(__APPLE__) && TARGET_OS_IPHONE
#if TARGET_OS_SIMULATOR || defined(DV_HOST_BUILD)
  return false;
#else
  if (__builtin_available(iOS 16.4, *)) {
    return cpu_detail::metal_supports_apple6();
  }
  return false;
#endif
#else
  return true;
#endif
}

}  // namespace dv
