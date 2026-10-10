// OWNER: AI-03
//
// Process-wide registry of live handles. Every C entry point validates its vw_model / vw_job handle
// against it (a stale or foreign pointer is ignored instead of crashing the app), vw_shutdown_all()
// drains it, and model loader threads (detached) are counted so shutdown can wait for them.
// The registry is intentionally never destroyed (detached loaders may outlive static destructors).
#ifndef VW_REGISTRY_H
#define VW_REGISTRY_H

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <unordered_set>
#include <vector>

struct vw_model;
struct vw_job;

namespace vw {

class Registry {
 public:
  static Registry &get();

  void add_model(vw_model *m);
  bool has_model(const vw_model *m);
  /// Removes [m]; false when it was not registered.
  bool remove_model(vw_model *m);
  std::vector<vw_model *> take_all_models();

  void add_job(vw_job *j);
  bool has_job(const vw_job *j);
  bool remove_job(vw_job *j);
  std::vector<vw_job *> take_all_jobs();

  void loader_started();
  void loader_finished();
  void wait_loaders_idle();

  /// Live object counts (allocated, not yet freed): leak checks in the host tests.
  std::atomic<int64_t> live_models{0};
  std::atomic<int64_t> live_jobs{0};

 private:
  Registry() = default;
  std::mutex mu_;
  std::condition_variable loaders_cv_;
  int64_t loaders_ = 0;
  std::unordered_set<const vw_model *> models_;
  std::unordered_set<const vw_job *> jobs_;
};

/// Test/diagnostic accessor for the live counters.
void debug_live_objects(int64_t *models, int64_t *jobs);

/// Serializes whisper.cpp's context/state/VAD initialisation across threads. Those paths write
/// process-wide ggml state without synchronisation (whisper_backend_init -> ggml_log_set, ggml_time_init),
/// which ThreadSanitizer reports when two jobs or a job and a model loader start at the same time.
/// Held only around whisper_init_* calls, never around inference. Never destroyed.
std::mutex &whisper_init_mutex();

}  // namespace vw

#endif  // VW_REGISTRY_H
