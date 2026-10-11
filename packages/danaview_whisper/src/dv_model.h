// OWNER: AI-03
//
// Model handles (ai.md §4.6 "Model and state"): one whisper_context per model, created with
// whisper_init_from_file_with_params_no_state() on a native (detached) loader thread; jobs create their
// own whisper_state. The context is shared by sequential jobs, never concurrently: a model admits one
// active job at a time (DV_ERR_BUSY otherwise).
//
// Lifetime: refcounted. The caller's handle holds one reference (dropped by dv_model_release), the
// loader thread holds one while loading, and each job holds one until dv_job_free. The context is freed
// with the last reference. The loader checks the ggml magic before whisper sees the file, applies the
// platform GPU policy (dv_cpu.h) and retries once on the CPU when a GPU init fails (gpu_fallback = 1).
#ifndef DV_MODEL_H
#define DV_MODEL_H

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>

#include "dv_whisper.h"

struct whisper_context;

struct dv_model {
  std::atomic<int32_t> refs{1};
  std::atomic<int32_t> state{DV_MODEL_LOADING};
  std::atomic<bool> busy{false};
  std::mutex mu;               // guards error/error_msg
  int32_t error = DV_OK;       // dv_status when FAILED
  std::string error_msg;       // diagnostics without paths
  whisper_context *ctx = nullptr;  // valid once READY, immutable afterwards
  dv_model_info info{};            // valid once READY
};

namespace dv {

/// Starts loading [path] (copied) on a detached native thread. nullptr when [path] is null/empty or
/// [params] is too small (struct_size).
dv_model *model_load(const char *path, const dv_model_params *params);

void model_retain(dv_model *m);
/// Drops a reference; frees the context and the handle with the last one.
void model_unref(dv_model *m);

/// Marks the model busy for a new job; false if a job already holds it.
bool model_try_acquire(dv_model *m);
void model_release_busy(dv_model *m);

/// Writes the failure message (NUL terminated, truncated to [len]) and returns the error status.
int32_t model_error(dv_model *m, char *buf, int32_t len);

}  // namespace dv

#endif  // DV_MODEL_H
