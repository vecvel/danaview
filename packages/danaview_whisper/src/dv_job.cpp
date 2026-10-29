// OWNER: AI-03
//
// Job threads: chunked transcription, language detection, pause/cancel, status and segment buffers
// (see dv_job.h).
#include "dv_job.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <new>

#include "dv_chunker.h"
#include "dv_json.h"
#include "dv_log.h"
#include "dv_model.h"
#include "dv_registry.h"
#include "dv_wav.h"
#include "dv_words.h"
#include "whisper.h"

namespace dv {

int64_t now_us() {
  return std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

namespace job_detail {

constexpr int32_t kMaxThreads = 8;
constexpr int64_t kMinChunkSamples = kSampleRate;              // chunks < 1 s are skipped
constexpr int64_t kMinWhisperSamples = kSampleRate / 10;      // whisper ignores < 100 ms
constexpr int64_t kDetectVadWindowSamples = 60LL * kSampleRate;
constexpr int32_t kMaxCarryWords = 40;
constexpr int32_t kChunkDone = -1000;
constexpr int32_t kChunkAborted = -1001;

std::string copy_str(const char *s) { return s != nullptr ? std::string(s) : std::string(); }

// Whisper callbacks: they only touch atomics (some run on ggml worker threads).
bool on_abort(void *data) {
  auto *j = static_cast<dv_job *>(data);
  if (j->cancel.load(std::memory_order_relaxed) || j->abort_chunk.load(std::memory_order_relaxed)) {
    j->chunk_aborted.store(true, std::memory_order_relaxed);
    return true;
  }
  return false;
}

bool on_encoder_begin(whisper_context *, whisper_state *, void *data) {
  auto *j = static_cast<dv_job *>(data);
  j->phase.store(DV_PHASE_ENCODING, std::memory_order_relaxed);
  if (j->cancel.load(std::memory_order_relaxed) || j->abort_chunk.load(std::memory_order_relaxed)) {
    j->chunk_aborted.store(true, std::memory_order_relaxed);
    return false;
  }
  return true;
}

void on_progress(whisper_context *, whisper_state *, int progress, void *data) {
  auto *j = static_cast<dv_job *>(data);
  j->chunk_percent.store(std::min(std::max(progress, 0), 100), std::memory_order_relaxed);
}

void on_logits(whisper_context *, whisper_state *, const whisper_token_data *, int, float *, void *data) {
  static_cast<dv_job *>(data)->phase.store(DV_PHASE_DECODING, std::memory_order_relaxed);
}

class Runner {
 public:
  explicit Runner(dv_job *j) : j_(j), ctx_(j->model->ctx) {}
  ~Runner() { release_state(); }

  void run() {
    int32_t state = DV_JOB_SUCCEEDED;
    int32_t error = DV_OK;
    try {
      const int32_t rc = j_->cfg.mode == DV_MODE_DETECT_LANGUAGE ? run_detect() : run_transcribe();
      if (rc == DV_ERR_CANCELLED) {
        state = DV_JOB_CANCELLED;
        error = DV_ERR_CANCELLED;
      } else if (rc != DV_OK) {
        state = DV_JOB_FAILED;
        error = rc;
      }
    } catch (const std::bad_alloc &) {
      state = DV_JOB_FAILED;
      error = DV_ERR_OOM;
    } catch (...) {
      state = DV_JOB_FAILED;
      error = DV_ERR_INTERNAL;
    }
    if (state != DV_JOB_SUCCEEDED && j_->cancel.load()) {
      state = DV_JOB_CANCELLED;
      error = DV_ERR_CANCELLED;
    }
    release_state();
    vad_.~VadModel();
    new (&vad_) VadModel();
    // Free the model for the next job before Dart can observe the terminal state.
    model_release_busy(j_->model);
    {
      std::lock_guard<std::mutex> lock(j_->mu);
      j_->state = state;
      j_->error = error;
      j_->call_started_us = 0;
      j_->current_chunk_samples = 0;
      if (state == DV_JOB_SUCCEEDED) {
        j_->progress_fixed = 1000;
        j_->processed_samples = j_->range_samples;
      }
    }
    j_->cv.notify_all();
    if (state == DV_JOB_FAILED) DV_LOGW("job failed (status %d)", error);
  }

 private:
  void release_state() {
    if (state_ != nullptr) {
      whisper_free_state(state_);
      state_ = nullptr;
    }
  }

  bool cancelled() const { return j_->cancel.load(std::memory_order_relaxed); }

  whisper_state *init_state() {
    std::lock_guard<std::mutex> lock(whisper_init_mutex());
    return whisper_init_state(ctx_);
  }

  template <typename F>
  auto timed(F &&f) -> decltype(f()) {
    {
      std::lock_guard<std::mutex> lock(j_->mu);
      j_->call_started_us = now_us();
    }
    auto rc = f();
    {
      std::lock_guard<std::mutex> lock(j_->mu);
      j_->compute_us_done += now_us() - j_->call_started_us;
      j_->call_started_us = 0;
    }
    return rc;
  }

  // false when cancelled while waiting.
  bool wait_while_paused() {
    std::unique_lock<std::mutex> lock(j_->mu);
    if (j_->cancel.load()) return false;
    if (!j_->pause_requested.load()) return true;
    j_->state = DV_JOB_PAUSED;
    j_->cv.notify_all();
    j_->cv.wait(lock, [this] { return !j_->pause_requested.load() || j_->cancel.load(); });
    if (j_->cancel.load()) return false;
    j_->state = DV_JOB_RUNNING;
    return true;
  }

  SampleReadFn reader_fn() {
    return [this](int64_t s, int64_t n, std::vector<float> *out) { return reader_.read(s, n, out); };
  }

  int32_t open_range(int64_t *start, int64_t *end) {
    const int32_t rc = reader_.open(j_->cfg.wav_path);
    if (rc != DV_OK) return rc;
    const int64_t total = reader_.n_samples();
    *start = std::min(ms_to_samples(j_->cfg.range_start_ms), total);
    *end = j_->cfg.range_end_ms < 0 ? total : std::min(total, ms_to_samples(j_->cfg.range_end_ms));
    if (*end < *start) *end = *start;
    return DV_OK;
  }

  whisper_full_params make_params(int32_t threads, const std::string &prompt) {
    const JobConfig &c = j_->cfg;
    whisper_full_params p =
        whisper_full_default_params(c.beam_size > 1 ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY);
    p.n_threads = threads;
    p.offset_ms = 0;
    p.duration_ms = 0;
    p.translate = false;
    // whisper keeps its rolling text context (prompt_past) in the whisper_state across calls. Clearing it
    // at the start of every chunk (no_context) keeps chunks independent of earlier calls, so a chunk
    // redone after pause(abort) decodes exactly like an uninterrupted run; cross-chunk context comes
    // only from the explicit carry prompt below. Inside a chunk, whisper still rolls context between
    // its 30 s windows.
    p.no_context = true;
    p.no_timestamps = false;
    p.single_segment = false;
    p.print_special = false;
    p.print_progress = false;
    p.print_realtime = false;
    p.print_timestamps = false;
    p.token_timestamps = c.token_timestamps;
    p.max_len = 0;
    p.split_on_word = false;
    p.max_tokens = 0;
    p.audio_ctx = 0;
    p.tdrz_enable = false;
    p.suppress_regex = nullptr;
    p.initial_prompt = prompt.empty() ? nullptr : prompt.c_str();
    p.carry_initial_prompt = false;
    p.prompt_tokens = nullptr;
    p.prompt_n_tokens = 0;
    p.language = c.language.c_str();
    p.detect_language = false;
    p.suppress_blank = true;
    p.suppress_nst = c.suppress_nst;
    p.temperature = 0.0f;
    p.temperature_inc = c.temperature_inc;
    p.entropy_thold = c.entropy_thold;
    p.logprob_thold = c.logprob_thold;
    p.no_speech_thold = c.no_speech_thold;
    p.greedy.best_of = std::max(1, c.best_of);
    if (c.beam_size > 1) p.beam_search.beam_size = c.beam_size;
    p.vad = false;  // the shim runs VAD itself (dv_vad.h)
    p.vad_model_path = nullptr;
    p.progress_callback = &on_progress;
    p.progress_callback_user_data = j_;
    p.encoder_begin_callback = &on_encoder_begin;
    p.encoder_begin_callback_user_data = j_;
    p.abort_callback = &on_abort;
    p.abort_callback_user_data = j_;
    p.logits_filter_callback = &on_logits;
    p.logits_filter_callback_user_data = j_;
    p.new_segment_callback = nullptr;
    return p;
  }

  // ---------------------------------------------------------------------------------------------
  // TRANSCRIBE

  int32_t run_transcribe() {
    j_->phase.store(DV_PHASE_PREPARING);
    int64_t start = 0;
    int64_t end = 0;
    int32_t rc = open_range(&start, &end);
    if (rc != DV_OK) return rc;
    {
      std::lock_guard<std::mutex> lock(j_->mu);
      j_->range_start_samples = start;
      j_->range_samples = end - start;
    }
    const JobConfig &c = j_->cfg;
    ChunkParams cp;
    cp.target = ms_to_samples(c.chunk_target_ms);
    cp.search = ms_to_samples(c.chunk_search_ms);
    cp.min = ms_to_samples(c.chunk_min_ms);
    std::vector<SampleRange> chunks;
    rc = plan_chunks(start, end, cp, reader_fn(), &chunks);
    if (rc != DV_OK) return rc;
    {
      std::lock_guard<std::mutex> lock(j_->mu);
      j_->chunk_count = static_cast<int32_t>(chunks.size());
    }
    if (cancelled()) return DV_ERR_CANCELLED;
    if (chunks.empty()) return DV_OK;
    state_ = init_state();
    if (state_ == nullptr) return DV_ERR_OOM;
    if (c.vad_enabled) {
      rc = vad_.load(c.vad_model_path);
      if (rc != DV_OK) return rc;
    }
    const bool no_space = is_no_space_language(c.language.c_str());
    std::string carry;
    for (size_t k = 0; k < chunks.size(); ++k) {
      const SampleRange chunk = chunks[k];
      while (true) {
        if (!wait_while_paused()) return DV_ERR_CANCELLED;
        int32_t threads;
        {
          std::lock_guard<std::mutex> lock(j_->mu);
          j_->chunk_index = static_cast<int32_t>(k);
          j_->current_chunk_samples = chunk.length();
          j_->threads_in_use = j_->threads_requested.load();
          threads = j_->threads_in_use;
        }
        j_->phase.store(DV_PHASE_PREPARING);
        j_->chunk_percent.store(0);
        j_->chunk_aborted.store(false);
        std::vector<std::string> seg_json;
        std::vector<Word> words;
        rc = process_chunk(static_cast<int32_t>(k), chunk, threads, carry, no_space, &seg_json, &words);
        if (cancelled()) return DV_ERR_CANCELLED;
        if (rc == kChunkAborted) {
          DV_LOGI("chunk %d aborted; redone on resume", static_cast<int>(k));
          continue;  // wait_while_paused() parks the job until resume, then the chunk is redone
        }
        if (rc != kChunkDone) return rc;
        {
          std::lock_guard<std::mutex> lock(j_->mu);
          for (std::string &s : seg_json) j_->segments.push_back(std::move(s));
          j_->chunks_completed = static_cast<int32_t>(k) + 1;
          j_->processed_samples = chunk.end - start;
          j_->current_chunk_samples = 0;
        }
        carry = make_carry(words, no_space);
        break;
      }
    }
    return DV_OK;
  }

  std::string make_carry(const std::vector<Word> &words, bool no_space) const {
    const int32_t n = std::min(j_->cfg.carry_prompt_words, kMaxCarryWords);
    if (n <= 0 || words.empty()) return std::string();
    const size_t first = words.size() > static_cast<size_t>(n) ? words.size() - static_cast<size_t>(n) : 0;
    std::string out;
    for (size_t i = first; i < words.size(); ++i) {
      if (!no_space) out.push_back(' ');
      out += words[i].text;
    }
    return out;
  }

  int32_t process_chunk(int32_t k, const SampleRange &chunk, int32_t threads, const std::string &carry,
                        bool no_space, std::vector<std::string> *seg_json, std::vector<Word> *chunk_words) {
    if (chunk.length() < kMinChunkSamples) return kChunkDone;  // never sent to whisper
    std::vector<float> pcm;
    int32_t rc = reader_.read(chunk.start, chunk.length(), &pcm);
    if (rc != DV_OK) return rc;
    const float *data = pcm.data();
    int64_t n = static_cast<int64_t>(pcm.size());
    VadFiltered filtered;
    bool mapped = false;
    if (vad_.loaded()) {
      j_->phase.store(DV_PHASE_VAD);
      std::vector<SpeechSpan> spans;
      rc = timed([&] { return vad_.detect(data, n, j_->cfg.vad, &spans); });
      if (rc != DV_OK) return rc;
      if (cancelled() || j_->abort_chunk.load()) return kChunkAborted;
      if (spans.empty()) return kChunkDone;
      vad_filter(data, n, spans, j_->cfg.vad.samples_overlap_s, &filtered);
      if (static_cast<int64_t>(filtered.samples.size()) < kMinWhisperSamples) return kChunkDone;
      data = filtered.samples.data();
      n = static_cast<int64_t>(filtered.samples.size());
      mapped = true;
    }
    std::string prompt = j_->cfg.initial_prompt;
    if (!carry.empty()) prompt += carry;
    const whisper_full_params wp = make_params(threads, prompt);
    rc = timed([&] { return whisper_full_with_state(ctx_, state_, wp, data, static_cast<int>(n)); });
    if (j_->chunk_aborted.load() || cancelled()) return kChunkAborted;
    if (rc != 0) return rc == -7 ? DV_ERR_OOM : DV_ERR_INFERENCE;
    collect_segments(k, chunk, mapped ? &filtered.segments : nullptr, no_space, seg_json, chunk_words);
    return kChunkDone;
  }

  void collect_segments(int32_t k, const SampleRange &chunk, const std::vector<VadMapSegment> *map, bool no_space,
                        std::vector<std::string> *seg_json, std::vector<Word> *chunk_words) {
    const int64_t c0 = samples_to_ms(chunk.start);
    const int64_t c1 = samples_to_ms(chunk.end);
    auto to_ms = [&](int64_t cs) -> int64_t {
      if (map != nullptr) cs = vad_map_time_cs(cs, *map);
      return std::min(std::max(c0 + cs * 10, c0), c1);
    };
    int64_t base;
    {
      std::lock_guard<std::mutex> lock(j_->mu);
      base = static_cast<int64_t>(j_->segments.size());
    }
    const whisper_token eot = whisper_token_eot(ctx_);
    const int n_seg = whisper_full_n_segments_from_state(state_);
    for (int i = 0; i < n_seg; ++i) {
      const int64_t t0 = to_ms(whisper_full_get_segment_t0_from_state(state_, i));
      int64_t t1 = to_ms(whisper_full_get_segment_t1_from_state(state_, i));
      if (t1 < t0) t1 = t0;
      const char *raw_text = whisper_full_get_segment_text_from_state(state_, i);
      const std::string text = trim_ascii_space(utf8_sanitize(copy_str(raw_text)));
      std::vector<TokenPiece> pieces;
      double plog_sum = 0.0;
      int plog_n = 0;
      const int n_tok = whisper_full_n_tokens_from_state(state_, i);
      for (int t = 0; t < n_tok; ++t) {
        const whisper_token_data td = whisper_full_get_token_data_from_state(state_, i, t);
        if (td.id >= eot) continue;  // special and timestamp tokens
        TokenPiece piece;
        piece.bytes = copy_str(whisper_token_to_str(ctx_, td.id));
        if (j_->cfg.token_timestamps && td.t0 >= 0 && td.t1 >= 0) {
          piece.t0 = to_ms(td.t0);
          piece.t1 = to_ms(td.t1);
        }
        piece.p = td.p;
        pieces.push_back(std::move(piece));
        plog_sum += td.plog;
        ++plog_n;
      }
      std::vector<Word> words = assemble_words(pieces, no_space, t0, t1);
      if (text.empty() && words.empty()) continue;
      const double lp = plog_n > 0 ? plog_sum / plog_n : 0.0;
      const double nsp = whisper_full_get_segment_no_speech_prob_from_state(state_, i);
      JsonWriter w;
      w.begin_object()
          .key("i").value_int(base + static_cast<int64_t>(seg_json->size()))
          .key("c").value_int(k)
          .key("t0").value_int(t0)
          .key("t1").value_int(t1)
          .key("text").value_string(text)
          .key("nsp").value_number(nsp)
          .key("lp").value_number(lp)
          .key("w").begin_array();
      for (const Word &word : words) {
        w.begin_object()
            .key("t").value_string(word.text)
            .key("t0").value_int(word.t0)
            .key("t1").value_int(word.t1)
            .key("p").value_number(word.p)
            .end_object();
      }
      w.end_array().end_object();
      seg_json->push_back(w.str());
      chunk_words->insert(chunk_words->end(), words.begin(), words.end());
    }
  }

  // ---------------------------------------------------------------------------------------------
  // DETECT

  int32_t run_detect() {
    j_->phase.store(DV_PHASE_PREPARING);
    int64_t start = 0;
    int64_t end = 0;
    int32_t rc = open_range(&start, &end);
    if (rc != DV_OK) return rc;
    const JobConfig &c = j_->cfg;
    const int64_t search_end = std::min(end, start + ms_to_samples(c.detect_search_ms));
    {
      std::lock_guard<std::mutex> lock(j_->mu);
      j_->range_start_samples = start;
      j_->range_samples = search_end - start;
      j_->chunk_count = 1;
      j_->progress_fixed = 0;
    }
    int64_t speech = -1;
    if (c.vad_enabled) {
      rc = vad_.load(c.vad_model_path);
      if (rc != DV_OK) return rc;
      j_->phase.store(DV_PHASE_VAD);
      std::vector<float> buf;
      std::vector<SpeechSpan> spans;
      for (int64_t pos = start; pos < search_end; pos += kDetectVadWindowSamples) {
        if (cancelled()) return DV_ERR_CANCELLED;
        const int64_t n = std::min(kDetectVadWindowSamples, search_end - pos);
        rc = reader_.read(pos, n, &buf);
        if (rc != DV_OK) return rc;
        rc = timed([&] { return vad_.detect(buf.data(), static_cast<int64_t>(buf.size()), c.vad, &spans); });
        if (rc != DV_OK) return rc;
        if (!spans.empty()) {
          speech = pos + spans.front().t0_cs * (kSampleRate / 100);
          break;
        }
        std::lock_guard<std::mutex> lock(j_->mu);
        j_->progress_fixed = static_cast<int32_t>((pos + n - start) * 500 / std::max<int64_t>(1, search_end - start));
      }
    } else {
      const int64_t min_speech = ms_to_samples(c.vad.min_speech_ms > 0 ? c.vad.min_speech_ms : 250);
      rc = rms_first_speech(reader_fn(), start, search_end, min_speech, &speech);
      if (rc != DV_OK) return rc;
    }
    if (cancelled()) return DV_ERR_CANCELLED;
    if (speech < 0) return DV_ERR_NO_SPEECH;
    const int64_t take_end = std::min(end, speech + ms_to_samples(c.detect_max_speech_ms));
    if (take_end - speech < kMinWhisperSamples) return DV_ERR_NO_SPEECH;
    std::vector<float> pcm;
    rc = reader_.read(speech, take_end - speech, &pcm);
    if (rc != DV_OK) return rc;
    {
      std::lock_guard<std::mutex> lock(j_->mu);
      j_->progress_fixed = 500;
      j_->threads_in_use = j_->threads_requested.load();
    }
    const int32_t threads = j_->threads_in_use;
    state_ = init_state();
    if (state_ == nullptr) return DV_ERR_OOM;
    j_->phase.store(DV_PHASE_ENCODING);
    rc = timed([&] {
      return whisper_pcm_to_mel_with_state(ctx_, state_, pcm.data(), static_cast<int>(pcm.size()), threads);
    });
    if (rc != 0) return DV_ERR_INFERENCE;
    if (cancelled()) return DV_ERR_CANCELLED;
    std::vector<float> probs(static_cast<size_t>(whisper_lang_max_id() + 1), 0.0f);
    const int top = timed([&] { return whisper_lang_auto_detect_with_state(ctx_, state_, 0, threads, probs.data()); });
    if (cancelled()) return DV_ERR_CANCELLED;
    if (top < 0) return DV_ERR_INFERENCE;
    std::vector<std::pair<std::string, float>> sorted;
    sorted.reserve(probs.size());
    for (size_t id = 0; id < probs.size(); ++id) {
      const char *code = whisper_lang_str(static_cast<int>(id));
      if (code != nullptr) sorted.emplace_back(code, std::isfinite(probs[id]) ? probs[id] : 0.0f);
    }
    std::stable_sort(sorted.begin(), sorted.end(),
                     [](const std::pair<std::string, float> &a, const std::pair<std::string, float> &b) {
                       return a.second > b.second;
                     });
    {
      std::lock_guard<std::mutex> lock(j_->mu);
      j_->language_probs = std::move(sorted);
      if (!j_->language_probs.empty()) {
        j_->language = j_->language_probs.front().first;
        j_->language_p = j_->language_probs.front().second;
      }
      j_->speech_start_ms = samples_to_ms(speech);
      j_->has_language_result = true;
      j_->chunks_completed = 1;
    }
    return DV_OK;
  }

  dv_job *j_;
  whisper_context *ctx_;
  whisper_state *state_ = nullptr;
  WavReader reader_;
  VadModel vad_;
};

void thread_main(dv_job *j) {
  Runner runner(j);
  runner.run();
}

}  // namespace job_detail

int32_t job_config_from_params(const dv_job_params *p, JobConfig *out) {
  using namespace job_detail;
  if (p == nullptr || p->struct_size < static_cast<int32_t>(sizeof(dv_job_params))) return DV_ERR_INVALID_ARG;
  JobConfig c;
  if (p->mode != DV_MODE_TRANSCRIBE && p->mode != DV_MODE_DETECT_LANGUAGE) return DV_ERR_INVALID_ARG;
  c.mode = p->mode;
  c.wav_path = copy_str(p->wav_path);
  if (c.wav_path.empty()) return DV_ERR_INVALID_ARG;
  if (p->range_start_ms < 0) return DV_ERR_INVALID_ARG;
  if (p->range_end_ms != -1 && p->range_end_ms < p->range_start_ms) return DV_ERR_INVALID_ARG;
  c.range_start_ms = p->range_start_ms;
  c.range_end_ms = p->range_end_ms;
  c.language = copy_str(p->language);
  if (p->n_threads < 1 || p->n_threads > kMaxThreads) return DV_ERR_INVALID_ARG;
  c.n_threads = p->n_threads;
  if (p->chunk_target_ms < 0 || p->chunk_search_ms < 0 || p->chunk_min_ms < 0) return DV_ERR_INVALID_ARG;
  if (p->chunk_target_ms > 0) c.chunk_target_ms = p->chunk_target_ms;
  if (p->chunk_search_ms > 0) c.chunk_search_ms = p->chunk_search_ms;
  if (p->chunk_min_ms > 0) c.chunk_min_ms = p->chunk_min_ms;
  c.vad_enabled = p->vad_enabled != 0;
  c.vad_model_path = copy_str(p->vad_model_path);
  if (p->vad_threshold > 0.0f && p->vad_threshold < 1.0f) c.vad.threshold = p->vad_threshold;
  c.vad.min_speech_ms = std::max(0, p->vad_min_speech_ms);
  c.vad.min_silence_ms = std::max(0, p->vad_min_silence_ms);
  c.vad.speech_pad_ms = std::max(0, p->vad_speech_pad_ms);
  c.vad.samples_overlap_s = std::isfinite(p->vad_samples_overlap_s) ? std::max(0.0f, p->vad_samples_overlap_s) : 0.1f;
  c.token_timestamps = p->token_timestamps != 0;
  c.no_speech_thold = p->no_speech_thold;
  c.entropy_thold = p->entropy_thold;
  c.logprob_thold = p->logprob_thold;
  c.temperature_inc = std::isfinite(p->temperature_inc) ? std::max(0.0f, p->temperature_inc) : 0.0f;
  c.beam_size = p->beam_size;
  c.best_of = p->best_of;
  c.suppress_nst = p->suppress_nst != 0;
  if (p->carry_prompt_words < 0) return DV_ERR_INVALID_ARG;
  c.carry_prompt_words = std::min(p->carry_prompt_words, kMaxCarryWords);
  c.initial_prompt = copy_str(p->initial_prompt);
  if (p->detect_max_speech_ms < 0 || p->detect_search_ms < 0) return DV_ERR_INVALID_ARG;
  if (p->detect_max_speech_ms > 0) c.detect_max_speech_ms = p->detect_max_speech_ms;
  if (p->detect_search_ms > 0) c.detect_search_ms = p->detect_search_ms;
  *out = std::move(c);
  return DV_OK;
}

dv_job *job_start(dv_model *m, const dv_job_params *params, int32_t *status) {
  auto result = [status](int32_t s) {
    if (status != nullptr) *status = s;
  };
  JobConfig cfg;
  int32_t rc = job_config_from_params(params, &cfg);
  if (rc != DV_OK) {
    result(rc);
    return nullptr;
  }
  const int32_t model_state = m->state.load(std::memory_order_acquire);
  if (model_state == DV_MODEL_LOADING) {
    result(DV_ERR_BUSY);
    return nullptr;
  }
  if (model_state != DV_MODEL_READY) {
    result(DV_ERR_MODEL_LOAD);
    return nullptr;
  }
  const bool multilingual = m->info.multilingual != 0;
  if (cfg.mode == DV_MODE_TRANSCRIBE) {
    const int id = whisper_lang_id(cfg.language.c_str());
    const char *code = id >= 0 ? whisper_lang_str(id) : nullptr;
    if (code == nullptr || cfg.language != code || (!multilingual && cfg.language != "en")) {
      result(DV_ERR_INVALID_ARG);
      return nullptr;
    }
  } else {
    if (!multilingual) {
      result(DV_ERR_INVALID_ARG);
      return nullptr;
    }
    cfg.language = "auto";
  }
  if (cfg.vad_enabled && cfg.vad_model_path.empty()) {
    result(DV_ERR_VAD_MODEL);
    return nullptr;
  }
  WavInfo info;
  rc = wav_probe(cfg.wav_path, &info);
  if (rc != DV_OK) {
    result(rc);
    return nullptr;
  }
  if (ms_to_samples(cfg.range_start_ms) > info.n_samples) {
    result(DV_ERR_INVALID_ARG);
    return nullptr;
  }
  if (!model_try_acquire(m)) {
    result(DV_ERR_BUSY);
    return nullptr;
  }
  log_init();
  auto *j = new dv_job();
  j->model = m;
  model_retain(m);
  j->wav_samples = info.n_samples;
  j->threads_requested.store(cfg.n_threads);
  j->threads_in_use = cfg.n_threads;
  j->language = cfg.mode == DV_MODE_TRANSCRIBE ? cfg.language : std::string();
  j->cfg = std::move(cfg);
  Registry &reg = Registry::get();
  reg.live_jobs.fetch_add(1);
  reg.add_job(j);
  try {
    j->thread = std::thread(&job_detail::thread_main, j);
  } catch (...) {
    reg.remove_job(j);
    model_release_busy(m);
    model_unref(m);
    delete j;
    reg.live_jobs.fetch_sub(1);
    result(DV_ERR_INTERNAL);
    return nullptr;
  }
  result(DV_OK);
  return j;
}

void job_status(dv_job *j, dv_job_status *out) {
  dv_job_status s;
  std::memset(&s, 0, sizeof(s));
  {
    std::lock_guard<std::mutex> lock(j->mu);
    s.state = j->state;
    s.error = j->error;
    s.phase = j->phase.load(std::memory_order_relaxed);
    s.chunk_index = j->chunk_index;
    s.chunk_count = j->chunk_count;
    s.chunks_completed = j->chunks_completed;
    s.segments_ready = static_cast<int32_t>(j->segments.size());
    s.processed_ms = samples_to_ms(j->processed_samples);
    int64_t compute = j->compute_us_done;
    if (j->call_started_us != 0) compute += now_us() - j->call_started_us;
    s.compute_ms = compute / 1000;
    s.threads = j->threads_in_use;
    if (j->progress_fixed >= 0) {
      s.progress_permille = j->progress_fixed;
    } else if (j->range_samples > 0) {
      const int64_t pct = j->chunk_percent.load(std::memory_order_relaxed);
      const int64_t done = j->processed_samples + j->current_chunk_samples * pct / 100;
      int64_t permille = done * 1000 / j->range_samples;
      if (j->state != DV_JOB_SUCCEEDED) permille = std::min<int64_t>(permille, 999);
      s.progress_permille = static_cast<int32_t>(std::max<int64_t>(0, permille));
    }
    std::strncpy(s.language, j->language.c_str(), sizeof(s.language) - 1);
    s.language_p = j->language_p;
  }
  const int32_t caller_size = out->struct_size;
  const size_t n = caller_size <= 0 ? sizeof(s) : std::min(static_cast<size_t>(caller_size), sizeof(s));
  s.struct_size = caller_size <= 0 ? static_cast<int32_t>(sizeof(s)) : caller_size;
  std::memcpy(out, &s, n);
}

char *job_take_segments_json(dv_job *j, int32_t from_index, int32_t max_count) {
  std::string out = "[";
  {
    std::lock_guard<std::mutex> lock(j->mu);
    const int64_t size = static_cast<int64_t>(j->segments.size());
    const int64_t from = std::max<int64_t>(0, from_index);
    const int64_t end = max_count <= 0 ? from : std::min<int64_t>(size, from + max_count);
    for (int64_t i = from; i < end; ++i) {
      if (i > from) out.push_back(',');
      out += j->segments[static_cast<size_t>(i)];
    }
  }
  out.push_back(']');
  return json_dup_c(out);
}

char *job_language_json(dv_job *j, int32_t top_n) {
  JsonWriter w;
  {
    std::lock_guard<std::mutex> lock(j->mu);
    if (!j->has_language_result) return nullptr;
    const size_t n = std::min(static_cast<size_t>(top_n <= 0 ? 3 : top_n), j->language_probs.size());
    w.begin_object().key("lang").begin_array();
    for (size_t i = 0; i < n; ++i) {
      w.begin_object()
          .key("code").value_string(j->language_probs[i].first)
          .key("p").value_number(j->language_probs[i].second)
          .end_object();
    }
    w.end_array().key("speechStartMs").value_int(j->speech_start_ms).end_object();
  }
  return json_dup_c(w.str());
}

void job_cancel(dv_job *j) {
  std::lock_guard<std::mutex> lock(j->mu);
  j->cancel.store(true);
  j->cv.notify_all();
}

void job_pause(dv_job *j, bool abort_current_chunk) {
  std::lock_guard<std::mutex> lock(j->mu);
  if (j->state != DV_JOB_RUNNING && j->state != DV_JOB_PAUSED) return;
  j->pause_requested.store(true);
  if (abort_current_chunk) j->abort_chunk.store(true);
}

void job_resume(dv_job *j) {
  std::lock_guard<std::mutex> lock(j->mu);
  j->abort_chunk.store(false);
  j->pause_requested.store(false);
  j->cv.notify_all();
}

void job_set_threads(dv_job *j, int32_t n_threads) {
  j->threads_requested.store(std::min(std::max(n_threads, 1), job_detail::kMaxThreads));
}

void job_destroy(dv_job *j) {
  job_cancel(j);
  if (j->thread.joinable()) j->thread.join();
  dv_model *m = j->model;
  delete j;
  model_unref(m);
  Registry::get().live_jobs.fetch_sub(1);
}

}  // namespace dv
