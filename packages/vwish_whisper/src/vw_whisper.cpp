// OWNER: AI-03
//
// C ABI surface of the vwish whisper shim (vw_whisper.h, ABI 1; ai.md §4.5/§4.6).
//
// Every entry point:
//  * is extern "C" with default visibility (VW_API in the header),
//  * catches every C++ exception (std::bad_alloc -> VW_ERR_OOM, anything else -> VW_ERR_INTERNAL, or a
//    null / no-op result where the signature has no status),
//  * validates its vw_model / vw_job handle against the process registry (vw_registry.h), so a stale,
//    released or foreign pointer is ignored instead of crashing the app,
//  * copies every string it is given (vw_job_start copies the params; vw_model_load copies the path).
// Handles must not be freed on one thread while another thread is still inside a call that uses them
// (Dart drives everything from the UI isolate, so this never happens in the app).
#include "vw_whisper.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <new>
#include <string>

#include "vw_cpu.h"
#include "vw_job.h"
#include "vw_log.h"
#include "vw_model.h"
#include "vw_registry.h"
#include "whisper.h"

namespace vw {
namespace abi_detail {

std::once_flag g_system_info_once;
std::string *g_system_info = nullptr;  // never freed: returned pointers stay valid for the process

template <typename F>
int32_t guard_status(F &&f) {
  try {
    return f();
  } catch (const std::bad_alloc &) {
    return VW_ERR_OOM;
  } catch (...) {
    return VW_ERR_INTERNAL;
  }
}

template <typename F>
void guard_void(F &&f) {
  try {
    f();
  } catch (...) {
    // Nothing to report through a void entry point; the handle state stays as it was.
  }
}

}  // namespace abi_detail
}  // namespace vw

using vw::abi_detail::guard_status;
using vw::abi_detail::guard_void;

extern "C" {

// ---------------------------------------------------------------------------------------------------
// library

VW_API int32_t vw_abi_version(void) { return VW_ABI_VERSION; }

VW_API const char *vw_engine_version(void) {
  try {
    const char *v = whisper_version();
    return v != nullptr ? v : "";
  } catch (...) {
    return "";
  }
}

VW_API const char *vw_system_info(void) {
  try {
    std::call_once(vw::abi_detail::g_system_info_once, [] {
      const char *info = whisper_print_system_info();
      vw::abi_detail::g_system_info = new std::string(info != nullptr ? info : "");
    });
    return vw::abi_detail::g_system_info != nullptr ? vw::abi_detail::g_system_info->c_str() : "";
  } catch (...) {
    return "";
  }
}

VW_API uint64_t vw_cpu_features(void) {
  try {
    return vw::cpu_features();
  } catch (...) {
    return 0;
  }
}

VW_API int32_t vw_perf_core_count(void) {
  try {
    return vw::perf_core_count();
  } catch (...) {
    return 0;
  }
}

VW_API void vw_set_log_level(int32_t level) {
  guard_void([&] {
    vw::log_init();
    vw::log_set_level(level);
  });
}

VW_API int32_t vw_lang_max_id(void) {
  try {
    return whisper_lang_max_id();
  } catch (...) {
    return -1;
  }
}

VW_API const char *vw_lang_code(int32_t id) {
  try {
    if (id < 0 || id > whisper_lang_max_id()) return nullptr;
    return whisper_lang_str(id);
  } catch (...) {
    return nullptr;
  }
}

VW_API void vw_shutdown_all(void) {
  guard_void([] {
    vw::Registry &reg = vw::Registry::get();
    // 1. Jobs first: cancel, join, free (each drops its model reference).
    for (vw_job *j : reg.take_all_jobs()) vw::job_destroy(j);
    // 2. Then the callers' model references.
    for (vw_model *m : reg.take_all_models()) vw::model_unref(m);
    // 3. Loader threads cannot be interrupted inside whisper; wait until they have dropped their
    //    references so no native thread outlives the call.
    reg.wait_loaders_idle();
    VW_LOGI("shutdown_all complete");
  });
}

VW_API void vw_free(void *p) { std::free(p); }

// ---------------------------------------------------------------------------------------------------
// model

VW_API vw_model *vw_model_load(const char *model_path, const vw_model_params *params) {
  try {
    return vw::model_load(model_path, params);
  } catch (...) {
    return nullptr;
  }
}

VW_API int32_t vw_model_get_state(const vw_model *m) {
  try {
    if (!vw::Registry::get().has_model(m)) return VW_MODEL_FAILED;
    return m->state.load(std::memory_order_acquire);
  } catch (...) {
    return VW_MODEL_FAILED;
  }
}

VW_API int32_t vw_model_error(const vw_model *m, char *buf, int32_t buf_len) {
  return guard_status([&]() -> int32_t {
    if (buf != nullptr && buf_len > 0) buf[0] = '\0';
    if (!vw::Registry::get().has_model(m)) return VW_ERR_INVALID_ARG;
    return vw::model_error(const_cast<vw_model *>(m), buf, buf_len);
  });
}

VW_API int32_t vw_model_info_get(const vw_model *m, vw_model_info *out) {
  return guard_status([&]() -> int32_t {
    if (out == nullptr || out->struct_size <= 0 || !vw::Registry::get().has_model(m)) return VW_ERR_INVALID_ARG;
    const int32_t state = m->state.load(std::memory_order_acquire);
    if (state == VW_MODEL_LOADING) return VW_ERR_BUSY;
    if (state != VW_MODEL_READY) return vw::model_error(const_cast<vw_model *>(m), nullptr, 0);
    vw_model_info info = m->info;  // immutable once READY
    const size_t n = std::min(static_cast<size_t>(out->struct_size), sizeof(info));
    info.struct_size = out->struct_size;
    std::memcpy(out, &info, n);
    return VW_OK;
  });
}

VW_API void vw_model_release(vw_model *m) {
  guard_void([&] {
    if (vw::Registry::get().remove_model(m)) vw::model_unref(m);
  });
}

// ---------------------------------------------------------------------------------------------------
// job

VW_API vw_job *vw_job_start(vw_model *m, const vw_job_params *params, int32_t *out_status) {
  vw_job *job = nullptr;
  const int32_t rc = guard_status([&]() -> int32_t {
    if (!vw::Registry::get().has_model(m)) return VW_ERR_INVALID_ARG;
    int32_t status = VW_ERR_INTERNAL;
    job = vw::job_start(m, params, &status);
    return status;
  });
  if (out_status != nullptr) *out_status = rc;
  return rc == VW_OK ? job : nullptr;
}

VW_API void vw_job_status_get(const vw_job *j, vw_job_status *out) {
  guard_void([&] {
    if (out == nullptr) return;
    if (!vw::Registry::get().has_job(j)) {
      const int32_t size = out->struct_size;
      const size_t n = size <= 0 ? sizeof(vw_job_status) : std::min(static_cast<size_t>(size), sizeof(vw_job_status));
      vw_job_status s;
      std::memset(&s, 0, sizeof(s));
      s.struct_size = size <= 0 ? static_cast<int32_t>(sizeof(s)) : size;
      s.state = VW_JOB_FAILED;
      s.error = VW_ERR_INVALID_ARG;
      std::memcpy(out, &s, n);
      return;
    }
    vw::job_status(const_cast<vw_job *>(j), out);
  });
}

VW_API char *vw_job_take_segments_json(vw_job *j, int32_t from_index, int32_t max_count) {
  try {
    if (!vw::Registry::get().has_job(j)) return nullptr;
    return vw::job_take_segments_json(j, from_index, max_count);
  } catch (...) {
    return nullptr;
  }
}

VW_API char *vw_job_language_probs_json(vw_job *j, int32_t top_n) {
  try {
    if (!vw::Registry::get().has_job(j)) return nullptr;
    return vw::job_language_json(j, top_n);
  } catch (...) {
    return nullptr;
  }
}

VW_API void vw_job_cancel(vw_job *j) {
  guard_void([&] {
    if (vw::Registry::get().has_job(j)) vw::job_cancel(j);
  });
}

VW_API void vw_job_pause(vw_job *j, int32_t abort_current_chunk) {
  guard_void([&] {
    if (vw::Registry::get().has_job(j)) vw::job_pause(j, abort_current_chunk != 0);
  });
}

VW_API void vw_job_resume(vw_job *j) {
  guard_void([&] {
    if (vw::Registry::get().has_job(j)) vw::job_resume(j);
  });
}

VW_API void vw_job_set_threads(vw_job *j, int32_t n_threads) {
  guard_void([&] {
    if (vw::Registry::get().has_job(j)) vw::job_set_threads(j, n_threads);
  });
}

VW_API void vw_job_free(vw_job *j) {
  guard_void([&] {
    if (vw::Registry::get().remove_job(j)) vw::job_destroy(j);
  });
}

}  // extern "C"
