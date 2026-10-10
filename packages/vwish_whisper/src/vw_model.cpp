// OWNER: AI-03
//
// Asynchronous model loading and refcounted model handles (see vw_model.h).
#include "vw_model.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <new>
#include <stdexcept>
#include <thread>

#include "ggml-backend.h"
#include "vw_cpu.h"
#include "vw_log.h"
#include "vw_registry.h"
#include "whisper.h"

namespace vw {
namespace model_detail {

struct LoadRequest {
  std::string path;
  bool use_gpu = true;
  bool flash_attn = true;
  int32_t dtw_preset = 0;
};

void fail(vw_model *m, int32_t status, const char *message) {
  {
    std::lock_guard<std::mutex> lock(m->mu);
    m->error = status;
    m->error_msg = message;
  }
  m->state.store(VW_MODEL_FAILED, std::memory_order_release);
  VW_LOGW("model load failed (status %d)", status);
}

// The minimum a ggml whisper file needs before whisper_init touches it: magic + 11 hparams.
bool file_looks_like_ggml(const std::string &path, int32_t *status, const char **message) {
  std::FILE *f = std::fopen(path.c_str(), "rb");
  if (f == nullptr) {
    *status = VW_ERR_MODEL_LOAD;
    *message = "model file cannot be opened";
    return false;
  }
  unsigned char head[48];
  const size_t n = std::fread(head, 1, sizeof(head), f);
  std::fclose(f);
  if (n < sizeof(head)) {
    *status = VW_ERR_MODEL_LOAD;
    *message = "model file is too short";
    return false;
  }
  if (!(head[0] == 0x6c && head[1] == 0x6d && head[2] == 0x67 && head[3] == 0x67)) {
    *status = VW_ERR_MODEL_LOAD;
    *message = "not a ggml model (bad magic)";
    return false;
  }
  return true;
}

bool has_gpu_device() {
  for (size_t i = 0; i < ggml_backend_dev_count(); ++i) {
    const enum ggml_backend_dev_type type = ggml_backend_dev_type(ggml_backend_dev_get(i));
    if (type == GGML_BACKEND_DEVICE_TYPE_GPU || type == GGML_BACKEND_DEVICE_TYPE_IGPU) return true;
  }
  return false;
}

whisper_context *init_ctx(const LoadRequest &req, bool use_gpu) {
  whisper_context_params cp = whisper_context_default_params();
  cp.use_gpu = use_gpu;
  cp.flash_attn = req.flash_attn;
  if (req.dtw_preset != 0) {
    cp.dtw_token_timestamps = true;
    cp.dtw_aheads_preset = static_cast<whisper_alignment_heads_preset>(req.dtw_preset);
    cp.flash_attn = false;  // DTW needs the attention weights
  }
  std::lock_guard<std::mutex> lock(whisper_init_mutex());
  return whisper_init_from_file_with_params_no_state(req.path.c_str(), cp);
}

void load_body(vw_model *m, const LoadRequest &req) {
  int32_t status = VW_OK;
  const char *message = "";
  if (!file_looks_like_ggml(req.path, &status, &message)) {
    fail(m, status, message);
    return;
  }
  const bool want_gpu = gpu_allowed(req.use_gpu);
  bool gpu_fallback = false;
  whisper_context *ctx = nullptr;
  try {
    ctx = init_ctx(req, want_gpu);
    if (ctx == nullptr && want_gpu) {
      VW_LOGW("GPU model init failed; retrying on the CPU");
      gpu_fallback = true;
      ctx = init_ctx(req, false);
    }
  } catch (const std::bad_alloc &) {
    fail(m, VW_ERR_OOM, "out of memory while loading the model");
    return;
  } catch (...) {
    fail(m, VW_ERR_MODEL_LOAD, "whisper could not load the model");
    return;
  }
  if (ctx == nullptr) {
    fail(m, VW_ERR_MODEL_LOAD, "whisper could not load the model");
    return;
  }
  vw_model_info info{};
  info.struct_size = sizeof(vw_model_info);
  info.multilingual = whisper_is_multilingual(ctx);
  info.n_vocab = whisper_model_n_vocab(ctx);
  info.model_type = whisper_model_type(ctx);
  info.ftype = whisper_model_ftype(ctx);
  info.gpu_used = (want_gpu && !gpu_fallback && has_gpu_device()) ? 1 : 0;
  info.gpu_fallback = gpu_fallback ? 1 : 0;
  m->ctx = ctx;
  m->info = info;
  m->state.store(VW_MODEL_READY, std::memory_order_release);
  VW_LOGI("model ready (type %d, multilingual %d, gpu %d, fallback %d)", info.model_type, info.multilingual,
          info.gpu_used, info.gpu_fallback);
}

}  // namespace model_detail

vw_model *model_load(const char *path, const vw_model_params *params) {
  using namespace model_detail;
  if (path == nullptr || path[0] == '\0') return nullptr;
  LoadRequest req;
  req.path = path;
  if (params != nullptr) {
    if (params->struct_size < static_cast<int32_t>(sizeof(vw_model_params))) return nullptr;
    req.use_gpu = params->use_gpu != 0;
    req.flash_attn = params->flash_attn != 0;
    req.dtw_preset = params->dtw_preset;
  }
  log_init();
  auto *m = new vw_model();
  Registry &reg = Registry::get();
  reg.live_models.fetch_add(1);
  reg.add_model(m);
  // Valid DTW presets: N_TOP_MOST (1) and the per-model presets (3..14); CUSTOM needs heads we do not take.
  const bool dtw_ok = req.dtw_preset == 0 || req.dtw_preset == WHISPER_AHEADS_N_TOP_MOST ||
                      (req.dtw_preset >= WHISPER_AHEADS_TINY_EN && req.dtw_preset <= WHISPER_AHEADS_LARGE_V3_TURBO);
  if (!dtw_ok) {
    fail(m, VW_ERR_INVALID_ARG, "unsupported dtw_preset");
    return m;
  }
  model_retain(m);  // the loader's reference
  reg.loader_started();
  try {
    std::thread([m, req]() {
      try {
        load_body(m, req);
      } catch (const std::bad_alloc &) {
        fail(m, VW_ERR_OOM, "out of memory while loading the model");
      } catch (...) {
        fail(m, VW_ERR_INTERNAL, "internal error while loading the model");
      }
      Registry &r = Registry::get();
      model_unref(m);
      r.loader_finished();
    }).detach();
  } catch (...) {
    reg.loader_finished();
    model_unref(m);
    fail(m, VW_ERR_INTERNAL, "could not start the loader thread");
  }
  return m;
}

void model_retain(vw_model *m) { m->refs.fetch_add(1, std::memory_order_relaxed); }

void model_unref(vw_model *m) {
  if (m->refs.fetch_sub(1, std::memory_order_acq_rel) != 1) return;
  if (m->ctx != nullptr) whisper_free(m->ctx);
  delete m;
  Registry::get().live_models.fetch_sub(1);
}

bool model_try_acquire(vw_model *m) {
  bool expected = false;
  return m->busy.compare_exchange_strong(expected, true, std::memory_order_acq_rel);
}

void model_release_busy(vw_model *m) { m->busy.store(false, std::memory_order_release); }

int32_t model_error(vw_model *m, char *buf, int32_t len) {
  std::lock_guard<std::mutex> lock(m->mu);
  if (buf != nullptr && len > 0) {
    const size_t n = std::min(static_cast<size_t>(len - 1), m->error_msg.size());
    std::memcpy(buf, m->error_msg.data(), n);
    buf[n] = '\0';
  }
  return m->error;
}

}  // namespace vw
