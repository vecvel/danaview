// OWNER: AI-03
//
// Transcription / language-detection jobs (ai.md §4.6 "Job thread state machine").
//
// Each job runs on its own std::thread. Dart polls with leaf calls: dv_job_status_get copies a
// mutex-guarded status, dv_job_take_segments_json serializes final segments (by absolute index).
// Cancel and pause are atomics read by whisper's abort_callback and encoder_begin_callback, so they act
// within one ggml graph; pause(abort_current_chunk = 1) aborts the running chunk and redoes it on resume,
// pause(0) waits for the next chunk boundary. Thread-count changes apply at the next chunk.
//
// TRANSCRIBE: PREPARING (chunk plan from RMS, dv_chunker.h) -> for each chunk: [VAD (dv_vad.h)] ->
// whisper_full_with_state (ENCODING/DECODING) -> words (dv_words.h) -> segment JSON appended under the
// mutex. Segment times are ms relative to the WAV start. A chunk shorter than 1 s is skipped.
// DETECT: first speech after range_start (Silero VAD, or the RMS fallback when VAD is off), up to
// detect_max_speech_ms of audio from there, one encoder pass, all language probabilities kept.
#ifndef DV_JOB_H
#define DV_JOB_H

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "dv_vad.h"
#include "dv_whisper.h"

struct dv_model;

namespace dv {

/// Copy of dv_job_params with defaults applied and strings owned.
struct JobConfig {
  int32_t mode = DV_MODE_TRANSCRIBE;
  std::string wav_path;
  int64_t range_start_ms = 0;
  int64_t range_end_ms = -1;
  std::string language;
  int32_t n_threads = 4;
  int64_t chunk_target_ms = 180000;
  int64_t chunk_search_ms = 15000;
  int64_t chunk_min_ms = 10000;
  bool vad_enabled = false;
  std::string vad_model_path;
  VadParams vad;
  bool token_timestamps = true;
  float no_speech_thold = 0.6f;
  float entropy_thold = 2.4f;
  float logprob_thold = -1.0f;
  float temperature_inc = 0.2f;
  int32_t beam_size = 1;
  int32_t best_of = 5;
  bool suppress_nst = true;
  int32_t carry_prompt_words = 0;
  std::string initial_prompt;
  int64_t detect_max_speech_ms = 30000;
  int64_t detect_search_ms = 600000;
};

/// Validates [p] and fills [out]; returns DV_OK or the dv_status to report from dv_job_start.
int32_t job_config_from_params(const dv_job_params *p, JobConfig *out);

}  // namespace dv

struct dv_job {
  dv_model *model = nullptr;  // holds a reference until dv_job_free
  dv::JobConfig cfg;
  int64_t wav_samples = 0;    // validated at start
  std::thread thread;

  // Control (any thread).
  std::atomic<bool> cancel{false};
  std::atomic<bool> pause_requested{false};
  std::atomic<bool> abort_chunk{false};
  std::atomic<int32_t> threads_requested{4};

  // Written by whisper callbacks on the job thread / ggml threads.
  std::atomic<bool> chunk_aborted{false};
  std::atomic<int32_t> phase{DV_PHASE_PREPARING};
  std::atomic<int32_t> chunk_percent{0};

  // Status and results, guarded by mu.
  std::mutex mu;
  std::condition_variable cv;
  int32_t state = DV_JOB_RUNNING;
  int32_t error = DV_OK;
  int32_t chunk_index = 0;
  int32_t chunk_count = 0;
  int32_t chunks_completed = 0;
  int64_t range_start_samples = 0;
  int64_t range_samples = 0;       // length of [range_start, range_end)
  int64_t processed_samples = 0;   // completed work, from range_start
  int64_t current_chunk_samples = 0;
  int32_t progress_fixed = -1;     // >= 0 overrides the computed permille (DETECT, terminal states)
  int64_t compute_us_done = 0;
  int64_t call_started_us = 0;     // != 0 while inside a whisper call
  int32_t threads_in_use = 4;
  std::string language;
  float language_p = 0.0f;
  std::vector<std::string> segments;  // serialized segment objects (schema 1)
  bool has_language_result = false;
  std::vector<std::pair<std::string, float>> language_probs;  // sorted, all languages
  int64_t speech_start_ms = -1;
};

namespace dv {

/// Validates, acquires the model and starts the thread. On failure returns nullptr and sets *status.
dv_job *job_start(dv_model *m, const dv_job_params *params, int32_t *status);

void job_status(dv_job *j, dv_job_status *out);
char *job_take_segments_json(dv_job *j, int32_t from_index, int32_t max_count);
char *job_language_json(dv_job *j, int32_t top_n);
void job_cancel(dv_job *j);
void job_pause(dv_job *j, bool abort_current_chunk);
void job_resume(dv_job *j);
void job_set_threads(dv_job *j, int32_t n_threads);
/// Cancels, joins and frees (the handle must already be out of the registry).
void job_destroy(dv_job *j);

/// Monotonic microseconds (compute time accounting).
int64_t now_us();

}  // namespace dv

#endif  // DV_JOB_H
