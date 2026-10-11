// OWNER: AI-03
//
// C ABI surface of the danaview whisper shim (dv_whisper.h, ABI 1; ai.md §4.5/§4.6).
//
// Every entry point:
//  * is extern "C" with default visibility (DV_API in the header),
//  * catches every C++ exception (std::bad_alloc -> DV_ERR_OOM, anything else -> DV_ERR_INTERNAL, or a
//    null / no-op result where the signature has no status),
//  * validates its dv_model / dv_job handle against the process registry (dv_registry.h), so a stale,
//    released or foreign pointer is ignored instead of crashing the app,
//  * copies every string it is given (dv_job_start copies the params; dv_model_load copies the path).
// Handles must not be freed on one thread while another thread is still inside a call that uses them
// (Dart drives everything from the UI isolate, so this never happens in the app).
#include "dv_whisper.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <new>
#include <string>

#include "dv_cpu.h"
#include "dv_job.h"
#include "dv_log.h"
#include "dv_model.h"
#include "dv_registry.h"
#include "whisper.h"

namespace dv {
namespace abi_detail {

std::once_flag g_system_info_once;
std::string *g_system_info = nullptr;  // never freed: returned pointers stay valid for the process

template <typename F>
int32_t guard_status(F &&f) {
  try {
    return f();
  } catch (const std::bad_alloc &) {
    return DV_ERR_OOM;
  } catch (...) {
    return DV_ERR_INTERNAL;
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
}  // namespace dv

using dv::abi_detail::guard_status;
using dv::abi_detail::guard_void;

extern "C" {

// ---------------------------------------------------------------------------------------------------
// library

DV_API int32_t dv_abi_version(void) { return DV_ABI_VERSION; }

DV_API const char *dv_engine_version(void) {
  try {
    const char *v = whisper_version();
    return v != nullptr ? v : "";
  } catch (...) {
    return "";
  }
}

DV_API const char *dv_system_info(void) {
  try {
    std::call_once(dv::abi_detail::g_system_info_once, [] {
      const char *info = whisper_print_system_info();
      dv::abi_detail::g_system_info = new std::string(info != nullptr ? info : "");
    });
    return dv::abi_detail::g_system_info != nullptr ? dv::abi_detail::g_system_info->c_str() : "";
  } catch (...) {
    return "";
  }
}

DV_API uint64_t dv_cpu_features(void) {
  try {
    return dv::cpu_features();
  } catch (...) {
    return 0;
  }
}

DV_API int32_t dv_perf_core_count(void) {
  try {
    return dv::perf_core_count();
  } catch (...) {
    return 0;
  }
}

DV_API void dv_set_log_level(int32_t level) {
  guard_void([&] {
    dv::log_init();
    dv::log_set_level(level);
  });
}

DV_API int32_t dv_lang_max_id(void) {
  try {
    return whisper_lang_max_id();
  } catch (...) {
    return -1;
  }
}

DV_API const char *dv_lang_code(int32_t id) {
  try {
    if (id < 0 || id > whisper_lang_max_id()) return nullptr;
    return whisper_lang_str(id);
  } catch (...) {
    return nullptr;
  }
}

DV_API void dv_shutdown_all(void) {
  guard_void([] {
    dv::Registry &reg = dv::Registry::get();
    // 1. Jobs first: cancel, join, free (each drops its model reference).
    for (dv_job *j : reg.take_all_jobs()) dv::job_destroy(j);
    // 2. Then the callers' model references.
    for (dv_model *m : reg.take_all_models()) dv::model_unref(m);
    // 3. Loader threads cannot be interrupted inside whisper; wait until they have dropped their
    //    references so no native thread outlives the call.
    reg.wait_loaders_idle();
    DV_LOGI("shutdown_all complete");
  });
}

DV_API void dv_free(void *p) { std::free(p); }

// ---------------------------------------------------------------------------------------------------
// model

DV_API dv_model *dv_model_load(const char *model_path, const dv_model_params *params) {
  try {
    return dv::model_load(model_path, params);
  } catch (...) {
    return nullptr;
  }
}

DV_API int32_t dv_model_get_state(const dv_model *m) {
  try {
    if (!dv::Registry::get().has_model(m)) return DV_MODEL_FAILED;
    return m->state.load(std::memory_order_acquire);
  } catch (...) {
    return DV_MODEL_FAILED;
  }
}

DV_API int32_t dv_model_error(const dv_model *m, char *buf, int32_t buf_len) {
  return guard_status([&]() -> int32_t {
    if (buf != nullptr && buf_len > 0) buf[0] = '\0';
    if (!dv::Registry::get().has_model(m)) return DV_ERR_INVALID_ARG;
    return dv::model_error(const_cast<dv_model *>(m), buf, buf_len);
  });
}

DV_API int32_t dv_model_info_get(const dv_model *m, dv_model_info *out) {
  return guard_status([&]() -> int32_t {
    if (out == nullptr || out->struct_size <= 0 || !dv::Registry::get().has_model(m)) return DV_ERR_INVALID_ARG;
    const int32_t state = m->state.load(std::memory_order_acquire);
    if (state == DV_MODEL_LOADING) return DV_ERR_BUSY;
    if (state != DV_MODEL_READY) return dv::model_error(const_cast<dv_model *>(m), nullptr, 0);
    dv_model_info info = m->info;  // immutable once READY
    const size_t n = std::min(static_cast<size_t>(out->struct_size), sizeof(info));
    info.struct_size = out->struct_size;
    std::memcpy(out, &info, n);
    return DV_OK;
  });
}

DV_API void dv_model_release(dv_model *m) {
  guard_void([&] {
    if (dv::Registry::get().remove_model(m)) dv::model_unref(m);
  });
}

// ---------------------------------------------------------------------------------------------------
// job

DV_API dv_job *dv_job_start(dv_model *m, const dv_job_params *params, int32_t *out_status) {
  dv_job *job = nullptr;
  const int32_t rc = guard_status([&]() -> int32_t {
    if (!dv::Registry::get().has_model(m)) return DV_ERR_INVALID_ARG;
    int32_t status = DV_ERR_INTERNAL;
    job = dv::job_start(m, params, &status);
    return status;
  });
  if (out_status != nullptr) *out_status = rc;
  return rc == DV_OK ? job : nullptr;
}

DV_API void dv_job_status_get(const dv_job *j, dv_job_status *out) {
  guard_void([&] {
    if (out == nullptr) return;
    if (!dv::Registry::get().has_job(j)) {
      const int32_t size = out->struct_size;
      const size_t n = size <= 0 ? sizeof(dv_job_status) : std::min(static_cast<size_t>(size), sizeof(dv_job_status));
      dv_job_status s;
      std::memset(&s, 0, sizeof(s));
      s.struct_size = size <= 0 ? static_cast<int32_t>(sizeof(s)) : size;
      s.state = DV_JOB_FAILED;
      s.error = DV_ERR_INVALID_ARG;
      std::memcpy(out, &s, n);
      return;
    }
    dv::job_status(const_cast<dv_job *>(j), out);
  });
}

DV_API char *dv_job_take_segments_json(dv_job *j, int32_t from_index, int32_t max_count) {
  try {
    if (!dv::Registry::get().has_job(j)) return nullptr;
    return dv::job_take_segments_json(j, from_index, max_count);
  } catch (...) {
    return nullptr;
  }
}

DV_API char *dv_job_language_probs_json(dv_job *j, int32_t top_n) {
  try {
    if (!dv::Registry::get().has_job(j)) return nullptr;
    return dv::job_language_json(j, top_n);
  } catch (...) {
    return nullptr;
  }
}

DV_API void dv_job_cancel(dv_job *j) {
  guard_void([&] {
    if (dv::Registry::get().has_job(j)) dv::job_cancel(j);
  });
}

DV_API void dv_job_pause(dv_job *j, int32_t abort_current_chunk) {
  guard_void([&] {
    if (dv::Registry::get().has_job(j)) dv::job_pause(j, abort_current_chunk != 0);
  });
}

DV_API void dv_job_resume(dv_job *j) {
  guard_void([&] {
    if (dv::Registry::get().has_job(j)) dv::job_resume(j);
  });
}

DV_API void dv_job_set_threads(dv_job *j, int32_t n_threads) {
  guard_void([&] {
    if (dv::Registry::get().has_job(j)) dv::job_set_threads(j, n_threads);
  });
}

DV_API void dv_job_free(dv_job *j) {
  guard_void([&] {
    if (dv::Registry::get().remove_job(j)) dv::job_destroy(j);
  });
}

}  // extern "C"
