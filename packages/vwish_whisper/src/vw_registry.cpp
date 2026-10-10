// OWNER: AI-03
//
// Handle registry (see vw_registry.h).
#include "vw_registry.h"

namespace vw {

Registry &Registry::get() {
  static Registry *instance = new Registry();  // never destroyed, see the header
  return *instance;
}

void Registry::add_model(vw_model *m) {
  std::lock_guard<std::mutex> lock(mu_);
  models_.insert(m);
}

bool Registry::has_model(const vw_model *m) {
  if (m == nullptr) return false;
  std::lock_guard<std::mutex> lock(mu_);
  return models_.count(m) != 0;
}

bool Registry::remove_model(vw_model *m) {
  if (m == nullptr) return false;
  std::lock_guard<std::mutex> lock(mu_);
  return models_.erase(m) != 0;
}

std::vector<vw_model *> Registry::take_all_models() {
  std::lock_guard<std::mutex> lock(mu_);
  std::vector<vw_model *> out;
  out.reserve(models_.size());
  for (const vw_model *m : models_) out.push_back(const_cast<vw_model *>(m));
  models_.clear();
  return out;
}

void Registry::add_job(vw_job *j) {
  std::lock_guard<std::mutex> lock(mu_);
  jobs_.insert(j);
}

bool Registry::has_job(const vw_job *j) {
  if (j == nullptr) return false;
  std::lock_guard<std::mutex> lock(mu_);
  return jobs_.count(j) != 0;
}

bool Registry::remove_job(vw_job *j) {
  if (j == nullptr) return false;
  std::lock_guard<std::mutex> lock(mu_);
  return jobs_.erase(j) != 0;
}

std::vector<vw_job *> Registry::take_all_jobs() {
  std::lock_guard<std::mutex> lock(mu_);
  std::vector<vw_job *> out;
  out.reserve(jobs_.size());
  for (const vw_job *j : jobs_) out.push_back(const_cast<vw_job *>(j));
  jobs_.clear();
  return out;
}

void Registry::loader_started() {
  std::lock_guard<std::mutex> lock(mu_);
  ++loaders_;
}

void Registry::loader_finished() {
  std::lock_guard<std::mutex> lock(mu_);
  --loaders_;
  loaders_cv_.notify_all();
}

void Registry::wait_loaders_idle() {
  std::unique_lock<std::mutex> lock(mu_);
  loaders_cv_.wait(lock, [this] { return loaders_ <= 0; });
}

void debug_live_objects(int64_t *models, int64_t *jobs) {
  Registry &r = Registry::get();
  if (models != nullptr) *models = r.live_models.load();
  if (jobs != nullptr) *jobs = r.live_jobs.load();
}

std::mutex &whisper_init_mutex() {
  static std::mutex *mu = new std::mutex();  // never destroyed (detached loaders may outlive statics)
  return *mu;
}

}  // namespace vw
