// OWNER: AI-03
//
// Runner of the shim host tests (see dv_test.h).
#include <chrono>
#include <cstdlib>
#include <exception>

#include "dv_test.h"
#include "dv_test_support.h"

namespace dvt {

int run_all(int argc, char **argv) {
  std::vector<std::string> filters;
  bool list = false;
  for (int i = 1; i < argc; ++i) {
    if (std::strcmp(argv[i], "--list") == 0) {
      list = true;
    } else {
      filters.emplace_back(argv[i]);
    }
  }
  int passed = 0, failed = 0, skipped = 0;
  std::vector<std::string> failed_names;
  for (const TestCase &t : registry()) {
    const std::string full = std::string(t.suite) + "." + t.name;
    if (!filters.empty()) {
      bool match = false;
      for (const std::string &f : filters) match = match || full.find(f) != std::string::npos;
      if (!match) continue;
    }
    if (list) {
      std::printf("%s\n", full.c_str());
      continue;
    }
    state() = State();
    std::printf("[ RUN      ] %s\n", full.c_str());
    std::fflush(stdout);
    const auto t0 = std::chrono::steady_clock::now();
    try {
      t.fn();
    } catch (const SkipException &) {
    } catch (const AssertException &) {
    } catch (const std::exception &e) {
      report_failure(__FILE__, __LINE__, std::string("uncaught exception: ") + e.what());
    } catch (...) {
      report_failure(__FILE__, __LINE__, "uncaught non-standard exception");
    }
    // Every test releases what it creates: a live model or job afterwards is a leak (dv_job_free /
    // dv_model_release must free everything). Reset with dv_shutdown_all so one leak fails one test.
    dvt_support::wait_loaders_idle();  // a finished loader still holds its model reference briefly
    int64_t live_models = 0, live_jobs = 0;
    dvt_support::live_objects(&live_models, &live_jobs);
    if (live_models != 0 || live_jobs != 0) {
      report_failure(__FILE__, __LINE__,
                     "leaked " + std::to_string(live_models) + " model(s) and " + std::to_string(live_jobs) + " job(s)");
      dv_shutdown_all();
    }
    const long long ms =
        std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
    if (state().failures > 0) {
      ++failed;
      failed_names.push_back(full);
      std::printf("[  FAILED  ] %s (%lld ms)\n", full.c_str(), ms);
    } else if (state().skipped) {
      ++skipped;
      std::printf("[  SKIPPED ] %s: %s\n", full.c_str(), state().skip_reason.c_str());
    } else {
      ++passed;
      std::printf("[       OK ] %s (%lld ms)\n", full.c_str(), ms);
    }
    std::fflush(stdout);
  }
  if (list) return 0;
  std::printf("\n%d passed, %d failed, %d skipped\n", passed, failed, skipped);
  for (const std::string &n : failed_names) std::printf("  failed: %s\n", n.c_str());
  return failed == 0 ? 0 : 1;
}

}  // namespace dvt

int main(int argc, char **argv) {
  dvt_support::install_log_capture();
  const int rc = dvt::run_all(argc, argv);
  const int log_rc = dvt_support::finish_log_capture();
  return rc != 0 ? rc : log_rc;
}
