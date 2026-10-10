// OWNER: AI-03
//
// Real-model host tests (ai.md §16.3 items 1-6 with ggml-tiny-q5_1 and jfk.wav). They need the pinned
// catalog files, which nothing in this repository downloads on a developer machine:
// scripts/ci/editor/whisper_host.sh fetches them in CI only (sha256-checked, cached) and exports
//   VW_TEST_WHISPER_MODEL = ggml-tiny-q5_1.bin     (ARCH §16.2: 32,152,673 bytes, sha256 818710...c3d7)
//   VW_TEST_VAD_MODEL     = ggml-silero-v6.2.0.bin (885,098 bytes, sha256 2aa269...6987)
// Without them every test here is SKIPPED with the reason. The fixture-model suites (test_jobs.cpp)
// cover the same mechanics deterministically on every run.
#include <chrono>
#include <cmath>
#include <cstring>
#include <thread>

#include "vw_test.h"
#include "vw_test_support.h"
#include "vw_whisper.h"

using namespace vwt_support;

namespace {

const char *const kPhrase = "ask not what your country can do for you";

vw_model *real_model(std::string *skip) {
  const std::string path = env_model_path("VW_TEST_WHISPER_MODEL");
  if (path.empty()) {
    *skip = "VW_TEST_WHISPER_MODEL not set (real-model tests run in CI via scripts/ci/editor/whisper_host.sh)";
    return nullptr;
  }
  int32_t state = -1;
  vw_model *m = load_model_blocking(path, &state);
  if (state != VW_MODEL_READY) {
    if (m != nullptr) vw_model_release(m);
    return nullptr;
  }
  return m;
}

struct Result {
  vw_job_status status;
  std::vector<Seg> segs;
  std::string text;  // normalized concatenation
};

Result transcribe(vw_model *m, const vw_job_params &p) {
  Result r;
  std::memset(&r.status, 0, sizeof(r.status));
  int32_t rc = -1;
  vw_job *j = vw_job_start(m, &p, &rc);
  if (j == nullptr) {
    r.status.state = VW_JOB_FAILED;
    r.status.error = rc;
    return r;
  }
  r.status = wait_job(j, 600000);
  parse_segments(take_all_segments_json(j), &r.segs);
  vw_job_free(j);
  std::string all;
  for (const Seg &s : r.segs) all += " " + s.text;
  r.text = normalize_text(all);
  return r;
}

size_t count_occurrences(const std::string &hay, const std::string &needle) {
  size_t n = 0;
  for (size_t pos = hay.find(needle); pos != std::string::npos; pos = hay.find(needle, pos + needle.size())) ++n;
  return n;
}

// 20 x jfk.wav separated by 1-4 s of silence (ai.md §16.3 item 5).
std::string jfk_x20() {
  const std::string path = temp_path("jfk-x20.wav");
  if (file_exists(path)) return path;
  const std::vector<int16_t> jfk = read_wav16(jfk_wav_path());
  std::vector<int16_t> pcm;
  for (int k = 0; k < 20; ++k) {
    append_silence(&pcm, 1.0 + (k % 4));
    pcm.insert(pcm.end(), jfk.begin(), jfk.end());
  }
  append_silence(&pcm, 1.0);
  write_wav16(path, pcm);
  return path;
}

}  // namespace

#define REAL_MODEL_OR_SKIP(m)                                              \
  std::string vwt_skip_reason;                                             \
  vw_model *m = real_model(&vwt_skip_reason);                              \
  if (m == nullptr && !vwt_skip_reason.empty()) SKIP(vwt_skip_reason);     \
  ASSERT_TRUE(m != nullptr)

TEST(Real, jfk_transcript_words_and_schema) {
  REAL_MODEL_OR_SKIP(m);
  const Result r = transcribe(m, default_job_params(jfk_wav_path()));
  ASSERT_EQ(r.status.state, VW_JOB_SUCCEEDED);
  EXPECT_TRUE(r.text.find(kPhrase) != std::string::npos);
  if (r.text.find(kPhrase) == std::string::npos) std::fprintf(stderr, "  transcript: %s\n", r.text.c_str());
  int64_t prev = 0;
  for (const Seg &s : r.segs) {
    EXPECT_LE(s.t0, s.t1);
    EXPECT_LE(s.t1, 11000);
    for (const Seg::W &w : s.w) {
      EXPECT_LE(prev, w.t0);
      EXPECT_LE(w.t0, w.t1);
      EXPECT_LE(s.t0, w.t0);
      EXPECT_LE(w.t1, s.t1);
      prev = w.t1;
    }
  }
  vw_model_release(m);
}

TEST(Real, pause_abort_resume_gives_the_same_text) {
  REAL_MODEL_OR_SKIP(m);
  const vw_job_params p = default_job_params(jfk_wav_path());
  const Result ref = transcribe(m, p);
  ASSERT_EQ(ref.status.state, VW_JOB_SUCCEEDED);
  int32_t rc = -1;
  vw_job *j = vw_job_start(m, &p, &rc);
  ASSERT_EQ(rc, VW_OK);
  std::this_thread::sleep_for(std::chrono::milliseconds(50));
  vw_job_pause(j, 1);
  vw_job_status s;
  do {
    std::memset(&s, 0, sizeof(s));
    s.struct_size = sizeof(s);
    vw_job_status_get(j, &s);
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  } while (s.state == VW_JOB_RUNNING);
  vw_job_resume(j);
  ASSERT_EQ(wait_job(j, 600000).state, VW_JOB_SUCCEEDED);
  std::vector<Seg> segs;
  ASSERT_TRUE(parse_segments(take_all_segments_json(j), &segs));
  std::string all;
  for (const Seg &seg : segs) all += " " + seg.text;
  EXPECT_EQ(normalize_text(all), ref.text);
  vw_job_free(j);
  vw_model_release(m);
}

TEST(Real, twenty_concatenations_across_chunk_boundaries_are_all_found_once) {
  REAL_MODEL_OR_SKIP(m);
  vw_job_params p = default_job_params(jfk_x20());
  p.chunk_target_ms = 60000;  // ~5 chunk boundaries, each cut in a silence
  p.chunk_search_ms = 15000;
  const Result r = transcribe(m, p);
  ASSERT_EQ(r.status.state, VW_JOB_SUCCEEDED);
  EXPECT_GE(r.status.chunk_count, 4);
  EXPECT_EQ(count_occurrences(r.text, kPhrase), static_cast<size_t>(20));
  vw_model_release(m);
}

TEST(Real, cancel_latency_below_1500_ms) {
  REAL_MODEL_OR_SKIP(m);
  const vw_job_params p = default_job_params(jfk_x20());
  int32_t rc = -1;
  vw_job *j = vw_job_start(m, &p, &rc);
  ASSERT_EQ(rc, VW_OK);
  std::this_thread::sleep_for(std::chrono::milliseconds(1500));
  const auto t0 = std::chrono::steady_clock::now();
  vw_job_cancel(j);
  const vw_job_status s = wait_job(j, 10000, 1);
  const auto ms =
      std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
  std::printf("  cancel latency (tiny): %lld ms\n", static_cast<long long>(ms));
  EXPECT_EQ(s.state, VW_JOB_CANCELLED);
  EXPECT_LT(ms, 1500);
  vw_job_free(j);
  vw_model_release(m);
}

TEST(Real, detect_finds_english_and_no_speech_on_silence) {
  REAL_MODEL_OR_SKIP(m);
  vw_job_params p = default_job_params(jfk_wav_path(), "auto");
  p.mode = VW_MODE_DETECT_LANGUAGE;
  int32_t rc = -1;
  vw_job *j = vw_job_start(m, &p, &rc);
  ASSERT_EQ(rc, VW_OK);
  const vw_job_status s = wait_job(j, 600000);
  ASSERT_EQ(s.state, VW_JOB_SUCCEEDED);
  EXPECT_EQ(std::string(s.language), std::string("en"));
  EXPECT_GT(s.language_p, 0.8f);
  vw_job_free(j);
  const std::string quiet = temp_path("real-silence.wav");
  std::vector<int16_t> zeros;
  append_silence(&zeros, 20.0);
  ASSERT_TRUE(write_wav16(quiet, zeros));
  vw_job_params q = default_job_params(quiet, "auto");
  q.mode = VW_MODE_DETECT_LANGUAGE;
  j = vw_job_start(m, &q, &rc);
  ASSERT_EQ(rc, VW_OK);
  const vw_job_status sq = wait_job(j, 600000);
  EXPECT_EQ(sq.state, VW_JOB_FAILED);
  EXPECT_EQ(sq.error, VW_ERR_NO_SPEECH);
  vw_job_free(j);
  vw_model_release(m);
}

TEST(Real, silero_vad_transcription_and_detection) {
  REAL_MODEL_OR_SKIP(m);
  const std::string vad = env_model_path("VW_TEST_VAD_MODEL");
  if (vad.empty()) {
    vw_model_release(m);
    SKIP("VW_TEST_VAD_MODEL not set");
  }
  vw_job_params p = default_job_params(jfk_x20());
  p.vad_enabled = 1;
  p.vad_model_path = intern(vad);
  p.chunk_target_ms = 60000;
  const Result r = transcribe(m, p);
  ASSERT_EQ(r.status.state, VW_JOB_SUCCEEDED);
  EXPECT_EQ(count_occurrences(r.text, kPhrase), static_cast<size_t>(20));
  p.mode = VW_MODE_DETECT_LANGUAGE;
  p.language = "auto";
  int32_t rc = -1;
  vw_job *j = vw_job_start(m, &p, &rc);
  ASSERT_EQ(rc, VW_OK);
  ASSERT_EQ(wait_job(j, 600000).state, VW_JOB_SUCCEEDED);
  char *raw = vw_job_language_probs_json(j, 3);
  Json doc;
  ASSERT_TRUE(raw != nullptr && json_parse(raw, &doc));
  vw_free(raw);
  EXPECT_EQ(doc.get("lang")->arr[0].string("code"), std::string("en"));
  EXPECT_LT(std::fabs(doc.number("speechStartMs") - 1000.0), 600.0);  // first jfk starts after 1 s of silence
  vw_job_free(j);
  vw_model_release(m);
}
