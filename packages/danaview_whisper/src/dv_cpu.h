// OWNER: AI-03
//
// Platform probes of the shim: CPU features (dv_cpu_features), performance cores (dv_perf_core_count)
// and the iOS GPU policy applied at model load (ai.md §4.4): Metal only on a device (not the simulator)
// running iOS >= 16.4 whose GPU supports MTLGPUFamilyApple6 (A13+). Everywhere else the request is
// passed through (host and Android builds have no GPU backend, so whisper runs on the CPU).
#ifndef DV_CPU_H
#define DV_CPU_H

#include <cstdint>

namespace dv {

/// Android arm64: the raw getauxval(AT_HWCAP) bits (the Dart loader picks the v8.2 shim when
/// HWCAP_FPHP (1 << 9), HWCAP_ASIMDHP (1 << 10) and HWCAP_ASIMDDP (1 << 20) are all set).
/// Every other platform: 0.
uint64_t cpu_features();

/// iOS/macOS: hw.perflevel0.physicalcpu (0 when unknown); Android/Linux: 0.
int32_t perf_core_count();

/// Applies the platform GPU policy to a GPU request.
bool gpu_allowed(bool requested);

}  // namespace dv

#endif  // DV_CPU_H
