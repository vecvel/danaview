// OWNER: AI-03
//
// Job threads with the deterministic fixture model (dv_test_support.h): transcription output and
// schema, chunking, progress, cancel latency, pause/resume (both modes), thread changes, concurrency,
// BUSY, DETECT, VAD, range resume, leak checks and dv_shutdown_all.
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <functional>
#include <thread>

#include "dv_test.h"
#include "dv_test_support.h"
#include "dv_whisper.h"

using namespace dvt_support;

namespace {

using Clock = std::chrono::steady_clock;

int64_t ms_since(Clock::time_point t) {
  return std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - t).count();
}

dv_model *fixture_model() {
  int32_t state = -1;
  dv_model *m = load_model_blocking(fixture_whisper_model(), &state);
  if (m == nullptr || state != DV_MODEL_READY) {
    if (m != nullptr) dv_model_release(m);
    return nullptr;
  }
  return m;
}

// Noise with a 600 ms quiet gap every [gap_every_s] seconds (gives the chunker clean cut points).
std::string make_noise_wav(const std::string &name, double seconds, double gap_every_s = 0.0) {
  const std::string path = temp_path(name);
  if (file_exists(path)) return path;
  std::vector<int16_t> pcm;
  append_noise(&pcm, seconds, 0.2, 99);
  if (gap_every_s > 0.0) {
    for (double g = gap_every_s; g < seconds; g += gap_every_s) {
      const int64_t c = static_cast<int64_t>(g * 16000);
      for (int64_t i = c - 4800; i < c + 4800 && i < static_cast<int64_t>(pcm.size()); ++i) pcm[static_cast<size_t>(i)] = 0;
    }
  }
  write_wav16(path, pcm);
  return path;
}

struct RunResult {
  dv_job_status status;
  std::string json;
  std::vector<Seg> segs;
};

RunResult run_to_end(dv_model *m, const dv_job_params &p, int timeout_ms = 300000) {
  RunResult r;
  std::memset(&r.status, 0, sizeof(r.status));
  int32_t rc = -1;
  dv_job *j = dv_job_start(m, &p, &rc);
  if (j == nullptr) {
    r.status.state = DV_JOB_FAILED;
    r.status.error = rc;
    return r;
  }
  r.status = wait_job(j, timeout_ms);
  r.json = take_all_segments_json(j);
  parse_segments(r.json, &r.segs);
  dv_job_free(j);
  return r;
}

void expect_segments_well_formed(const std::vector<Seg> &segs, int64_t wav_ms) {
  int64_t prev_t0 = -1;
  for (size_t k = 0; k < segs.size(); ++k) {
    const Seg &s = segs[k];
    EXPECT_EQ(s.i, static_cast<int64_t>(k));
    EXPECT_LE(prev_t0, s.t0);
    EXPECT_LE(s.t0, s.t1);
    EXPECT_LE(s.t1, wav_ms);
    int64_t prev_w = s.t0;
    for (const Seg::W &w : s.w) {
      EXPECT_LE(prev_w, w.t0);
      EXPECT_LE(w.t0, w.t1);
      EXPECT_LE(s.t0, w.t0);
      EXPECT_LE(w.t1, s.t1);
      EXPECT_TRUE(w.p >= 0.0 && w.p <= 1.0);
      prev_w = w.t1;
    }
    prev_t0 = s.t0;
    if (dvt::state().failures > 0) return;
  }
}

}  // namespace

// ---------------------------------------------------------------------------------------------------

TEST(Jobs, fixture_transcribes_jfk_deterministically) {
  dv_model *m = fixture_model();
  ASSERT_TRUE(m != nullptr);
  register_log_secret("hello world");
  register_log_secret("hello");
  const dv_job_params p = default_job_params(jfk_wav_path());
  const RunResult r = run_to_end(m, p);
  ASSERT_EQ(r.status.state, DV_JOB_SUCCEEDED);
  EXPECT_EQ(r.status.error, DV_OK);
  EXPECT_EQ(r.status.progress_permille, 1000);
  EXPECT_EQ(r.status.chunk_count, 1);
  EXPECT_EQ(r.status.chunks_completed, 1);
  EXPECT_EQ(r.status.processed_ms, 11000);
  EXPECT_EQ(std::string(r.status.language), std::string("en"));
  Json parsed;
  ASSERT_TRUE(json_parse(r.json, &parsed));
  if (r.segs.size() != 6) std::fprintf(stderr, "  segments: %s\n", r.json.c_str());
  ASSERT_EQ(r.segs.size(), static_cast<size_t>(6));  // 11 s: windows at 0, 2, ..., 10 s
  for (size_t k = 0; k < r.segs.size(); ++k) {
    const Seg &s = r.segs[k];
    EXPECT_EQ(s.text, std::string("hello world"));
    EXPECT_EQ(s.c, 0);
    EXPECT_EQ(s.t0, static_cast<int64_t>(k) * 2000);  // one segment per 2 s window seek
    EXPECT_EQ(s.t1, std::min<int64_t>(static_cast<int64_t>(k) * 2000 + 1980, 11000));
    ASSERT_EQ(s.w.size(), static_cast<size_t>(2));
    EXPECT_EQ(s.w[0].t, std::string("hello"));
    EXPECT_EQ(s.w[1].t, std::string("world"));
    EXPECT_GT(s.w[0].p, 0.9);
  }
  expect_segments_well_formed(r.segs, 11000);
  dv_model_release(m);
}

namespace {

// Transcribed in ~[target_ms] chunks cut at the quiet gaps of make_noise_wav().
dv_job_params chunked_params(const std::string &wav, int32_t target_ms = 30000) {
  dv_job_params p = default_job_params(wav);
  p.chunk_target_ms = target_ms;
  p.chunk_search_ms = 3000;
  p.chunk_min_ms = 5000;
  p.n_threads = 2;
  return p;
}

// The workhorse of the job tests: 45 s with gaps every 15 s -> chunks [0, 15], [15, 30], [30, 45] s.
std::string small_wav() { return make_noise_wav("chunked-45s.wav", 45.0, 15.0); }
dv_job_params small_params() { return chunked_params(small_wav(), 15000); }

bool wait_until(const std::function<bool()> &pred, int timeout_ms) {
  const auto deadline = Clock::now() + std::chrono::milliseconds(timeout_ms);
  while (Clock::now() < deadline) {
    if (pred()) return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  return pred();
}

dv_job_status status_of(dv_job *j) {
  dv_job_status s;
  std::memset(&s, 0, sizeof(s));
  s.struct_size = sizeof(s);
  dv_job_status_get(j, &s);
  return s;
}

void expect_no_leaks(int64_t models0, int64_t jobs0) {
  int64_t models = -1, jobs = -1;
  live_objects(&models, &jobs);
  EXPECT_EQ(models, models0);
  EXPECT_EQ(jobs, jobs0);
}

size_t count_log_lines_with(const std::string &needle) {
  size_t n = 0;
  for (const std::string &l : captured_log_lines()) n += l.find(needle) != std::string::npos ? 1 : 0;
  return n;
}

}  // namespace

TEST(Jobs, chunked_file_segments_carry_chunk_index_and_absolute_times) {
  int64_t m0, j0;
  live_objects(&m0, &j0);
  dv_model *m = fixture_model();
  ASSERT_TRUE(m != nullptr);
  const std::string wav = make_noise_wav("chunked-95s.wav", 95.0, 30.0);
  dv_job_params p = chunked_params(wav);
  p.chunk_min_ms = 10000;  // no admissible cut near 90 s: the 35 s tail stays whole
  const RunResult r = run_to_end(m, p);
  ASSERT_EQ(r.status.state, DV_JOB_SUCCEEDED);
  ASSERT_EQ(r.status.chunk_count, 3);  // cuts at the 30 s and 60 s gaps; the 35 s tail stays whole
  EXPECT_EQ(r.status.chunks_completed, 3);
  EXPECT_EQ(r.status.progress_permille, 1000);
  EXPECT_EQ(r.status.processed_ms, 95000);
  EXPECT_EQ(r.status.segments_ready, static_cast<int32_t>(r.segs.size()));
  expect_segments_well_formed(r.segs, 95000);
  // Chunk boundaries (absolute ms) from the segment chunk indices: every chunk restarts whisper at its
  // start, so its first segment begins exactly there.
  int64_t chunk_start[3] = {-1, -1, -1};
  for (const Seg &s : r.segs) {
    ASSERT_TRUE(s.c >= 0 && s.c < 3);
    if (chunk_start[s.c] < 0) chunk_start[s.c] = s.t0;
    EXPECT_EQ((s.t0 - chunk_start[s.c]) % 2000, 0);
    EXPECT_EQ(s.text, std::string("hello world"));
  }
  EXPECT_EQ(chunk_start[0], 0);
  EXPECT_LT(std::llabs(chunk_start[1] - 30000), 200);
  EXPECT_LT(std::llabs(chunk_start[2] - 60000), 200);
  dv_model_release(m);
  expect_no_leaks(m0, j0);
}

TEST(Jobs, take_segments_pages_by_absolute_index) {
  dv_model *m = fixture_model();
  ASSERT_TRUE(m != nullptr);
  int32_t rc = -1;
  const dv_job_params p = default_job_params(jfk_wav_path());
  dv_job *j = dv_job_start(m, &p, &rc);
  ASSERT_EQ(rc, DV_OK);
  ASSERT_EQ(wait_job(j).state, DV_JOB_SUCCEEDED);
  auto take = [j](int32_t from, int32_t max) {
    char *raw = dv_job_take_segments_json(j, from, max);
    std::string out = raw != nullptr ? raw : "<null>";
    dv_free(raw);
    return out;
  };
  std::vector<Seg> page;
  ASSERT_TRUE(parse_segments(take(2, 3), &page));
  ASSERT_EQ(page.size(), static_cast<size_t>(3));
  EXPECT_EQ(page[0].i, 2);
  EXPECT_EQ(page[2].i, 4);
  ASSERT_TRUE(parse_segments(take(4, 100), &page));
  EXPECT_EQ(page.size(), static_cast<size_t>(2));
  EXPECT_EQ(take(6, 10), std::string("[]"));
  EXPECT_EQ(take(0, 0), std::string("[]"));
  EXPECT_EQ(take(-5, 1).substr(0, 7), std::string("[{\"i\":0"));
  // Taking does not consume: the same page twice is identical.
  EXPECT_EQ(take(1, 2), take(1, 2));
  EXPECT_TRUE(dv_job_language_probs_json(j, 3) == nullptr);  // TRANSCRIBE has no language result
  // An older caller's smaller status struct receives only its prefix.
  int32_t small[3] = {static_cast<int32_t>(sizeof(int32_t) * 2), -7, -7};
  dv_job_status_get(j, reinterpret_cast<dv_job_status *>(small));
  EXPECT_EQ(small[1], DV_JOB_SUCCEEDED);
  EXPECT_EQ(small[2], -7);
  dv_job_free(j);
  dv_model_release(m);
}

TEST(Jobs, progress_is_monotonic_and_reaches_1000_only_on_success) {
  dv_model *m = fixture_model();
  ASSERT_TRUE(m != nullptr);
  int32_t rc = -1;
  const dv_job_params p = small_params();
  dv_job *j = dv_job_start(m, &p, &rc);
  ASSERT_EQ(rc, DV_OK);
  int32_t last = -1;
  int64_t last_processed = -1;
  dv_job_status s;
  int polls = 0;
  do {
    s = status_of(j);
    EXPECT_GE(s.progress_permille, last);
    EXPECT_GE(s.processed_ms, last_processed);
    if (s.state == DV_JOB_RUNNING) EXPECT_LE(s.progress_permille, 999);
    EXPECT_GE(s.compute_ms, 0);
    last = s.progress_permille;
    last_processed = s.processed_ms;
    ++polls;
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  } while (!is_terminal(s.state));
  EXPECT_EQ(s.state, DV_JOB_SUCCEEDED);
  EXPECT_EQ(s.progress_permille, 1000);
  EXPECT_GT(s.compute_ms, 0);
  EXPECT_GT(polls, 3);
  dv_job_free(j);
  dv_model_release(m);
}

TEST(Jobs, cancel_latency_is_below_1500_ms) {
  int64_t m0, j0;
  live_objects(&m0, &j0);
  dv_model *m = fixture_model();
  ASSERT_TRUE(m != nullptr);
  const std::string wav = make_noise_wav("long-600s.wav", 600.0);
  int32_t rc = -1;
  const dv_job_params p = default_job_params(wav);
  dv_job *j = dv_job_start(m, &p, &rc);
  ASSERT_EQ(rc, DV_OK);
  ASSERT_TRUE(wait_until([j] { return status_of(j).progress_permille > 0; }, 60000));
  const auto t0 = Clock::now();
  dv_job_cancel(j);
  const dv_job_status s = wait_job(j, 10000, 1);
  const int64_t latency = ms_since(t0);
  std::printf("  cancel latency: %lld ms\n", static_cast<long long>(latency));
  EXPECT_EQ(s.state, DV_JOB_CANCELLED);
  EXPECT_EQ(s.error, DV_ERR_CANCELLED);
  EXPECT_LT(latency, 1500);
  // Cancel is idempotent; free joins at once.
  dv_job_cancel(j);
  const auto t1 = Clock::now();
  dv_job_free(j);
  EXPECT_LT(ms_since(t1), 1500);
  dv_model_release(m);
  expect_no_leaks(m0, j0);
}

TEST(Jobs, free_while_running_cancels_and_joins) {
  int64_t m0, j0;
  live_objects(&m0, &j0);
  dv_model *m = fixture_model();
  ASSERT_TRUE(m != nullptr);
  const std::string wav = make_noise_wav("long-600s.wav", 600.0);
  for (int i = 0; i < 3; ++i) {
    int32_t rc = -1;
    const dv_job_params p = default_job_params(wav);
    dv_job *j = dv_job_start(m, &p, &rc);
    ASSERT_EQ(rc, DV_OK);
    if (i > 0) std::this_thread::sleep_for(std::chrono::milliseconds(20 * i));
    const auto t0 = Clock::now();
    dv_job_free(j);  // immediately (i == 0) or mid-run
    EXPECT_LT(ms_since(t0), 1500);
    // The model is free again for the next job.
  }
  dv_model_release(m);
  expect_no_leaks(m0, j0);
}

TEST(Jobs, pause_at_chunk_boundary_then_resume_matches_uninterrupted_run) {
  dv_model *m = fixture_model();
  ASSERT_TRUE(m != nullptr);
  const RunResult ref = run_to_end(m, small_params());
  ASSERT_EQ(ref.status.state, DV_JOB_SUCCEEDED);

  int32_t rc = -1;
  const dv_job_params p = small_params();
  dv_job *j = dv_job_start(m, &p, &rc);
  ASSERT_EQ(rc, DV_OK);
  ASSERT_TRUE(wait_until([j] { return status_of(j).chunks_completed >= 1; }, 60000));
  dv_job_pause(j, 0);
  ASSERT_TRUE(wait_until([j] { return status_of(j).state == DV_JOB_PAUSED; }, 60000));
  const dv_job_status paused = status_of(j);
  EXPECT_GE(paused.chunks_completed, 1);
  EXPECT_LT(paused.chunks_completed, 3);
  EXPECT_EQ(paused.segments_ready, static_cast<int32_t>(std::count_if(ref.segs.begin(), ref.segs.end(), [&](const Seg &s) {
              return s.c < paused.chunks_completed;
            })));
  // Nothing moves while paused; compute time does not grow.
  std::this_thread::sleep_for(std::chrono::milliseconds(300));
  const dv_job_status still = status_of(j);
  EXPECT_EQ(still.state, DV_JOB_PAUSED);
  EXPECT_EQ(still.chunks_completed, paused.chunks_completed);
  EXPECT_EQ(still.compute_ms, paused.compute_ms);
  EXPECT_EQ(still.progress_permille, paused.progress_permille);
  dv_job_pause(j, 0);  // pausing twice is harmless
  dv_job_resume(j);
  const dv_job_status done = wait_job(j);
  EXPECT_EQ(done.state, DV_JOB_SUCCEEDED);
  EXPECT_EQ(take_all_segments_json(j), ref.json);
  dv_job_resume(j);  // resume after the end is harmless
  dv_job_free(j);
  dv_model_release(m);
}

TEST(Jobs, pause_with_abort_redoes_the_chunk_and_matches_uninterrupted_run) {
  dv_model *m = fixture_model();
  ASSERT_TRUE(m != nullptr);
  // 110 s in two chunks ([0, 60] and [60, 110] s, ~30 whisper windows each), so the pause lands inside one.
  const std::string wav = make_noise_wav("chunked-110s.wav", 110.0, 60.0);
  const dv_job_params p = chunked_params(wav, 60000);
  const RunResult ref = run_to_end(m, p);
  ASSERT_EQ(ref.status.state, DV_JOB_SUCCEEDED);
  ASSERT_EQ(ref.status.chunk_count, 2);

  const size_t aborted_before = count_log_lines_with("aborted; redone on resume");
  int32_t rc = -1;
  dv_job *j = dv_job_start(m, &p, &rc);
  ASSERT_EQ(rc, DV_OK);
  // Inside chunk 1 (its first whisper window has run).
  ASSERT_TRUE(wait_until(
      [j] {
        const dv_job_status s = status_of(j);
        return s.chunk_index == 1 && s.chunks_completed == 1 && s.progress_permille > 450;
      },
      60000));
  const auto t0 = Clock::now();
  dv_job_pause(j, 1);
  ASSERT_TRUE(wait_until([j] { return status_of(j).state == DV_JOB_PAUSED; }, 5000));
  const int64_t pause_latency = ms_since(t0);
  std::printf("  pause(abort) latency: %lld ms\n", static_cast<long long>(pause_latency));
  EXPECT_LT(pause_latency, 1500);
  const dv_job_status paused = status_of(j);
  EXPECT_EQ(paused.chunks_completed, 1);  // the aborted chunk is not counted
  EXPECT_EQ(count_log_lines_with("aborted; redone on resume"), aborted_before + 1);
  dv_job_resume(j);
  EXPECT_EQ(wait_job(j).state, DV_JOB_SUCCEEDED);
  EXPECT_EQ(take_all_segments_json(j), ref.json);  // no duplicate, no missing segment
  dv_job_free(j);
  dv_model_release(m);
}

TEST(Jobs, cancel_while_paused_ends_cancelled) {
  dv_model *m = fixture_model();
  ASSERT_TRUE(m != nullptr);
  int32_t rc = -1;
  const dv_job_params p = small_params();
  dv_job *j = dv_job_start(m, &p, &rc);
  ASSERT_EQ(rc, DV_OK);
  dv_job_pause(j, 1);
  ASSERT_TRUE(wait_until([j] { return status_of(j).state == DV_JOB_PAUSED; }, 10000));
  dv_job_cancel(j);
  EXPECT_EQ(wait_job(j, 5000).state, DV_JOB_CANCELLED);
  dv_job_free(j);
  // ... and free while paused (without cancel) joins too.
  j = dv_job_start(m, &p, &rc);
  ASSERT_EQ(rc, DV_OK);
  dv_job_pause(j, 0);
  ASSERT_TRUE(wait_until([j] { return status_of(j).state == DV_JOB_PAUSED; }, 60000));
  dv_job_free(j);
  dv_model_release(m);
}

TEST(Jobs, thread_count_changes_apply_at_the_next_chunk_and_clamp) {
  dv_model *m = fixture_model();
  ASSERT_TRUE(m != nullptr);
  int32_t rc = -1;
  dv_job_params p = small_params();
  p.n_threads = 3;
  dv_job *j = dv_job_start(m, &p, &rc);
  ASSERT_EQ(rc, DV_OK);
  EXPECT_EQ(status_of(j).threads, 3);
  dv_job_set_threads(j, 99);
  dv_job_set_threads(j, 0);  // clamps to 1; the last request wins
  EXPECT_EQ(wait_job(j).state, DV_JOB_SUCCEEDED);
  EXPECT_EQ(status_of(j).threads, 1);
  dv_job_free(j);
  j = dv_job_start(m, &p, &rc);
  ASSERT_EQ(rc, DV_OK);
  dv_job_set_threads(j, 99);
  EXPECT_EQ(wait_job(j).state, DV_JOB_SUCCEEDED);
  EXPECT_EQ(status_of(j).threads, 8);
  dv_job_free(j);
  dv_model_release(m);
}

TEST(Jobs, one_active_job_per_model_busy_then_sequential) {
  dv_model *m = fixture_model();
  ASSERT_TRUE(m != nullptr);
  int32_t rc = -1;
  const dv_job_params p = small_params();
  dv_job *a = dv_job_start(m, &p, &rc);
  ASSERT_EQ(rc, DV_OK);
  int32_t rc2 = -1;
  EXPECT_TRUE(dv_job_start(m, &p, &rc2) == nullptr);
  EXPECT_EQ(rc2, DV_ERR_BUSY);
  EXPECT_EQ(wait_job(a).state, DV_JOB_SUCCEEDED);
  // Terminal state visible -> the model is already free, even before dv_job_free(a).
  dv_job *b = dv_job_start(m, &p, &rc2);
  EXPECT_EQ(rc2, DV_OK);
  EXPECT_EQ(wait_job(b).state, DV_JOB_SUCCEEDED);
  EXPECT_EQ(take_all_segments_json(a), take_all_segments_json(b));
  dv_job_free(a);
  dv_job_free(b);
  dv_model_release(m);
}

TEST(Jobs, concurrent_jobs_on_separate_models_agree) {
  int64_t m0, j0;
  live_objects(&m0, &j0);
  dv_model *m1 = fixture_model();
  dv_model *m2 = fixture_model();
  ASSERT_TRUE(m1 != nullptr && m2 != nullptr);
  int32_t rc1 = -1, rc2 = -1;
  const dv_job_params p = small_params();
  dv_job *a = dv_job_start(m1, &p, &rc1);
  dv_job *b = dv_job_start(m2, &p, &rc2);
  ASSERT_EQ(rc1, DV_OK);
  ASSERT_EQ(rc2, DV_OK);
  // Poll both from two threads at once (Dart polls from one isolate; this also exercises the mutex).
  std::atomic<bool> stop{false};
  std::thread poller([&] {
    while (!stop.load()) {
      status_of(a);
      char *raw = dv_job_take_segments_json(b, 0, 1000);
      dv_free(raw);
    }
  });
  EXPECT_EQ(wait_job(a).state, DV_JOB_SUCCEEDED);
  EXPECT_EQ(wait_job(b).state, DV_JOB_SUCCEEDED);
  stop.store(true);
  poller.join();
  const std::string ja = take_all_segments_json(a);
  EXPECT_EQ(ja, take_all_segments_json(b));
  EXPECT_GT(ja.size(), static_cast<size_t>(10));
  dv_job_free(a);
  dv_job_free(b);
  dv_model_release(m1);
  dv_model_release(m2);
  expect_no_leaks(m0, j0);
}

TEST(Jobs, model_release_during_a_job_keeps_it_alive_until_free) {
  int64_t m0, j0;
  live_objects(&m0, &j0);
  dv_model *m = fixture_model();
  ASSERT_TRUE(m != nullptr);
  int32_t rc = -1;
  const dv_job_params p = small_params();
  dv_job *j = dv_job_start(m, &p, &rc);
  ASSERT_EQ(rc, DV_OK);
  dv_model_release(m);  // the job's reference keeps the context
  EXPECT_EQ(dv_model_get_state(m), DV_MODEL_FAILED);  // the caller's handle is gone
  EXPECT_EQ(wait_job(j).state, DV_JOB_SUCCEEDED);
  int64_t models = -1;
  live_objects(&models, nullptr);
  EXPECT_EQ(models, m0 + 1);
  dv_job_free(j);
  expect_no_leaks(m0, j0);
}

TEST(Jobs, range_start_and_end_bound_the_segments) {
  dv_model *m = fixture_model();
  ASSERT_TRUE(m != nullptr);
  dv_job_params p = default_job_params(jfk_wav_path());
  p.range_start_ms = 4000;
  RunResult r = run_to_end(m, p);
  ASSERT_EQ(r.status.state, DV_JOB_SUCCEEDED);
  ASSERT_EQ(r.segs.size(), static_cast<size_t>(4));  // windows at 4, 6, 8, 10 s
  EXPECT_EQ(r.segs.front().t0, 4000);
  EXPECT_EQ(r.status.processed_ms, 7000);
  p.range_end_ms = 7500;
  r = run_to_end(m, p);
  ASSERT_EQ(r.status.state, DV_JOB_SUCCEEDED);
  ASSERT_EQ(r.segs.size(), static_cast<size_t>(2));
  EXPECT_EQ(r.segs.front().t0, 4000);
  EXPECT_LE(r.segs.back().t1, 7500);
  // Empty range: nothing to do.
  p.range_start_ms = 5000;
  p.range_end_ms = 5000;
  r = run_to_end(m, p);
  EXPECT_EQ(r.status.state, DV_JOB_SUCCEEDED);
  EXPECT_TRUE(r.segs.empty());
  EXPECT_EQ(r.status.chunk_count, 0);
  dv_model_release(m);
}

TEST(Jobs, sub_second_audio_is_skipped_not_sent_to_whisper) {
  dv_model *m = fixture_model();
  ASSERT_TRUE(m != nullptr);
  const std::string wav = temp_path("short-0.8s.wav");
  std::vector<int16_t> pcm;
  append_noise(&pcm, 0.8, 0.3, 5);
  ASSERT_TRUE(write_wav16(wav, pcm));
  const RunResult r = run_to_end(m, default_job_params(wav));
  EXPECT_EQ(r.status.state, DV_JOB_SUCCEEDED);
  EXPECT_EQ(r.status.chunk_count, 1);
  EXPECT_TRUE(r.segs.empty());
  dv_model_release(m);
}

TEST(Jobs, carry_prompt_and_initial_prompt_are_accepted) {
  dv_model *m = fixture_model();
  ASSERT_TRUE(m != nullptr);
  const RunResult ref = run_to_end(m, small_params());
  dv_job_params p = small_params();
  p.carry_prompt_words = 40;
  p.initial_prompt = "prompt secret words";
  register_log_secret("prompt secret");
  const RunResult r = run_to_end(m, p);
  ASSERT_EQ(r.status.state, DV_JOB_SUCCEEDED);
  // The fixture's output depends only on the last prompt token, so prompts do not change it.
  EXPECT_EQ(r.json, ref.json);
  dv_model_release(m);
}

TEST(Jobs, english_only_model_transcribes_en_and_rejects_other_languages) {
  int32_t state = -1;
  dv_model *m = load_model_blocking(fixture_whisper_model(false), &state);
  ASSERT_EQ(state, DV_MODEL_READY);
  dv_model_info info;
  std::memset(&info, 0, sizeof(info));
  info.struct_size = sizeof(info);
  ASSERT_EQ(dv_model_info_get(m, &info), DV_OK);
  EXPECT_EQ(info.multilingual, 0);
  int32_t rc = -1;
  dv_job_params p = default_job_params(jfk_wav_path(), "de");
  EXPECT_TRUE(dv_job_start(m, &p, &rc) == nullptr);
  EXPECT_EQ(rc, DV_ERR_INVALID_ARG);
  p.mode = DV_MODE_DETECT_LANGUAGE;
  EXPECT_TRUE(dv_job_start(m, &p, &rc) == nullptr);
  EXPECT_EQ(rc, DV_ERR_INVALID_ARG);
  const RunResult r = run_to_end(m, default_job_params(jfk_wav_path(), "en"));
  EXPECT_EQ(r.status.state, DV_JOB_SUCCEEDED);
  EXPECT_EQ(r.segs.size(), static_cast<size_t>(6));
  dv_model_release(m);
}

TEST(Jobs, vad_keeps_segments_inside_speech) {
  dv_model *m = fixture_model();
  ASSERT_TRUE(m != nullptr);
  // 3 s silence | 6 s tone | 8 s silence | 6 s tone | 3 s silence.
  const std::string wav = temp_path("vad-bursts.wav");
  std::vector<int16_t> pcm;
  append_silence(&pcm, 3.0);
  append_tone(&pcm, 6.0, kVadToneHz, 0.3);
  append_silence(&pcm, 8.0);
  append_tone(&pcm, 6.0, kVadToneHz, 0.3);
  append_silence(&pcm, 3.0);
  ASSERT_TRUE(write_wav16(wav, pcm));
  dv_job_params p = default_job_params(wav);
  p.vad_enabled = 1;
  p.vad_model_path = intern(fixture_vad_model());
  const RunResult r = run_to_end(m, p);
  ASSERT_EQ(r.status.state, DV_JOB_SUCCEEDED);
  ASSERT_GE(r.segs.size(), static_cast<size_t>(2));
  expect_segments_well_formed(r.segs, 26000);
  // Speech (with 100 ms padding and a 32 ms frame): [2.9, 9.1] and [16.9, 23.1] s. whisper only sees the
  // concatenated speech, and the shim maps times back span by span, so every segment and word edge lies
  // inside a speech span (a segment may straddle the removed gap, as with whisper's own VAD).
  auto in_speech = [](int64_t t) { return (t >= 2850 && t <= 9150) || (t >= 16850 && t <= 23150); };
  bool first = false, second = false;
  for (const Seg &s : r.segs) {
    if (!in_speech(s.t0) || !in_speech(s.t1)) {
      std::fprintf(stderr, "  segment edge outside speech: %lld..%lld\n", static_cast<long long>(s.t0),
                   static_cast<long long>(s.t1));
    }
    EXPECT_TRUE(in_speech(s.t0));
    EXPECT_TRUE(in_speech(s.t1));
    for (const Seg::W &w : s.w) {
      EXPECT_TRUE(in_speech(w.t0));
      EXPECT_TRUE(in_speech(w.t1));
    }
    first = first || s.t0 <= 9150;
    second = second || s.t1 >= 16850;
  }
  EXPECT_TRUE(first);
  EXPECT_TRUE(second);
  // Silence only -> no segments, still a success.
  const std::string quiet = temp_path("vad-silence.wav");
  std::vector<int16_t> zeros;
  append_silence(&zeros, 10.0);
  ASSERT_TRUE(write_wav16(quiet, zeros));
  dv_job_params q = default_job_params(quiet);
  q.vad_enabled = 1;
  q.vad_model_path = p.vad_model_path;
  const RunResult rq = run_to_end(m, q);
  EXPECT_EQ(rq.status.state, DV_JOB_SUCCEEDED);
  EXPECT_TRUE(rq.segs.empty());
  // A broken VAD model fails the job with DV_ERR_VAD_MODEL.
  q.vad_model_path = intern(temp_path("missing-vad.bin"));
  const RunResult rb = run_to_end(m, q);
  EXPECT_EQ(rb.status.state, DV_JOB_FAILED);
  EXPECT_EQ(rb.status.error, DV_ERR_VAD_MODEL);
  dv_model_release(m);
}

// ---------------------------------------------------------------------------------------------------
// DETECT

TEST(Detect, finds_the_language_after_leading_silence) {
  dv_model *m = fixture_model();
  ASSERT_TRUE(m != nullptr);
  const std::string wav = temp_path("detect-2s-silence.wav");
  std::vector<int16_t> pcm;
  append_silence(&pcm, 2.0);
  append_noise(&pcm, 8.0, 0.3, 11);
  ASSERT_TRUE(write_wav16(wav, pcm));
  dv_job_params p = default_job_params(wav, "auto");
  p.mode = DV_MODE_DETECT_LANGUAGE;
  int32_t rc = -1;
  dv_job *j = dv_job_start(m, &p, &rc);
  ASSERT_EQ(rc, DV_OK);
  const dv_job_status s = wait_job(j);
  ASSERT_EQ(s.state, DV_JOB_SUCCEEDED);
  EXPECT_EQ(std::string(s.language), std::string("de"));
  EXPECT_GT(s.language_p, 0.8f);
  EXPECT_EQ(s.progress_permille, 1000);
  char *raw = dv_job_language_probs_json(j, 3);
  ASSERT_TRUE(raw != nullptr);
  Json doc;
  ASSERT_TRUE(json_parse(raw, &doc));
  dv_free(raw);
  const Json *lang = doc.get("lang");
  ASSERT_TRUE(lang != nullptr && lang->type == Json::kArray);
  ASSERT_EQ(lang->arr.size(), static_cast<size_t>(3));
  EXPECT_EQ(lang->arr[0].string("code"), std::string("de"));
  EXPECT_GT(lang->arr[0].number("p"), 0.8);
  EXPECT_GE(lang->arr[0].number("p"), lang->arr[1].number("p"));
  EXPECT_GE(lang->arr[1].number("p"), lang->arr[2].number("p"));
  EXPECT_EQ(doc.number("speechStartMs"), 2000.0);  // RMS fallback (VAD off)
  raw = dv_job_language_probs_json(j, 0);  // default top 3
  ASSERT_TRUE(json_parse(raw, &doc));
  dv_free(raw);
  EXPECT_EQ(doc.get("lang")->arr.size(), static_cast<size_t>(3));
  raw = dv_job_language_probs_json(j, 1000);  // capped at the number of languages
  ASSERT_TRUE(json_parse(raw, &doc));
  dv_free(raw);
  EXPECT_EQ(static_cast<int32_t>(doc.get("lang")->arr.size()), dv_lang_max_id() + 1);
  EXPECT_EQ(take_all_segments_json(j), std::string("[]"));
  dv_job_free(j);
  dv_model_release(m);
}

TEST(Detect, no_speech_on_silence_with_and_without_vad) {
  dv_model *m = fixture_model();
  ASSERT_TRUE(m != nullptr);
  const std::string wav = temp_path("detect-silence.wav");
  std::vector<int16_t> pcm;
  append_silence(&pcm, 20.0);
  ASSERT_TRUE(write_wav16(wav, pcm));
  for (int vad = 0; vad < 2; ++vad) {
    dv_job_params p = default_job_params(wav, "auto");
    p.mode = DV_MODE_DETECT_LANGUAGE;
    p.vad_enabled = vad;
    p.vad_model_path = vad ? intern(fixture_vad_model()) : nullptr;
    int32_t rc = -1;
    dv_job *j = dv_job_start(m, &p, &rc);
    ASSERT_EQ(rc, DV_OK);
    const dv_job_status s = wait_job(j);
    EXPECT_EQ(s.state, DV_JOB_FAILED);
    EXPECT_EQ(s.error, DV_ERR_NO_SPEECH);
    EXPECT_TRUE(dv_job_language_probs_json(j, 3) == nullptr);
    dv_job_free(j);
  }
  dv_model_release(m);
}

TEST(Detect, vad_locates_the_first_speech) {
  dv_model *m = fixture_model();
  ASSERT_TRUE(m != nullptr);
  const std::string wav = temp_path("detect-tone.wav");
  std::vector<int16_t> pcm;
  append_noise(&pcm, 0.1, 0.0005, 3);  // below the VAD threshold
  append_silence(&pcm, 64.9);          // crosses the 60 s VAD search window
  append_tone(&pcm, 5.0, kVadToneHz, 0.3);
  ASSERT_TRUE(write_wav16(wav, pcm));
  dv_job_params p = default_job_params(wav, "auto");
  p.mode = DV_MODE_DETECT_LANGUAGE;
  p.vad_enabled = 1;
  p.vad_model_path = intern(fixture_vad_model());
  int32_t rc = -1;
  dv_job *j = dv_job_start(m, &p, &rc);
  ASSERT_EQ(rc, DV_OK);
  ASSERT_EQ(wait_job(j).state, DV_JOB_SUCCEEDED);
  char *raw = dv_job_language_probs_json(j, 2);
  Json doc;
  ASSERT_TRUE(raw != nullptr && json_parse(raw, &doc));
  dv_free(raw);
  EXPECT_LT(std::fabs(doc.number("speechStartMs") - 64900.0), 150.0);  // speech_pad 100 ms + 32 ms frames
  EXPECT_EQ(doc.get("lang")->arr[0].string("code"), std::string("de"));
  // A search window that ends before the speech finds nothing.
  dv_job_free(j);
  p.detect_search_ms = 30000;
  j = dv_job_start(m, &p, &rc);
  ASSERT_EQ(rc, DV_OK);
  const dv_job_status s = wait_job(j);
  EXPECT_EQ(s.state, DV_JOB_FAILED);
  EXPECT_EQ(s.error, DV_ERR_NO_SPEECH);
  dv_job_free(j);
  dv_model_release(m);
}

// ---------------------------------------------------------------------------------------------------
// dv_shutdown_all (hot restart)

TEST(Shutdown, joins_active_jobs_and_frees_models_and_loaders) {
  int64_t m0, j0;
  live_objects(&m0, &j0);
  dv_model *m1 = fixture_model();
  dv_model *m2 = fixture_model();
  ASSERT_TRUE(m1 != nullptr && m2 != nullptr);
  const std::string wav = make_noise_wav("long-600s.wav", 600.0);
  int32_t rc = -1;
  const dv_job_params p = default_job_params(wav);
  dv_job *a = dv_job_start(m1, &p, &rc);
  ASSERT_EQ(rc, DV_OK);
  dv_job *b = dv_job_start(m2, &p, &rc);
  ASSERT_EQ(rc, DV_OK);
  dv_job_pause(b, 1);  // one paused, one running
  dv_model_params mp;
  std::memset(&mp, 0, sizeof(mp));
  mp.struct_size = sizeof(mp);
  dv_model *loading = dv_model_load(fixture_whisper_model().c_str(), &mp);  // still loading
  ASSERT_TRUE(loading != nullptr);
  std::this_thread::sleep_for(std::chrono::milliseconds(50));
  const auto t0 = Clock::now();
  dv_shutdown_all();
  EXPECT_LT(ms_since(t0), 3000);
  expect_no_leaks(m0, j0);
  // Every old handle is now stale and ignored.
  EXPECT_EQ(status_of(a).state, DV_JOB_FAILED);
  EXPECT_EQ(status_of(a).error, DV_ERR_INVALID_ARG);
  dv_job_free(a);
  dv_job_free(b);
  EXPECT_EQ(dv_model_get_state(m1), DV_MODEL_FAILED);
  dv_model_release(m1);
  dv_model_release(loading);
  dv_shutdown_all();  // idempotent
  // The library works again afterwards.
  dv_model *m3 = fixture_model();
  ASSERT_TRUE(m3 != nullptr);
  const RunResult r = run_to_end(m3, default_job_params(jfk_wav_path()));
  EXPECT_EQ(r.status.state, DV_JOB_SUCCEEDED);
  dv_model_release(m3);
  expect_no_leaks(m0, j0);
}

TEST(Shutdown, concurrent_callers_during_shutdown_do_not_crash) {
  int64_t m0, j0;
  live_objects(&m0, &j0);
  dv_model *m = fixture_model();
  ASSERT_TRUE(m != nullptr);
  const std::string wav = make_noise_wav("long-600s.wav", 600.0);
  int32_t rc = -1;
  const dv_job_params p = default_job_params(wav);
  dv_job *j = dv_job_start(m, &p, &rc);
  ASSERT_EQ(rc, DV_OK);
  std::atomic<bool> stop{false};
  std::thread poller([&] {
    // A poller that keeps using the (soon stale) handles, like a Dart timer firing during hot restart.
    while (!stop.load()) {
      status_of(j);
      dv_job_set_threads(j, 2);
      dv_model_get_state(m);
    }
  });
  std::this_thread::sleep_for(std::chrono::milliseconds(30));
  dv_shutdown_all();
  stop.store(true);
  poller.join();
  expect_no_leaks(m0, j0);
}
