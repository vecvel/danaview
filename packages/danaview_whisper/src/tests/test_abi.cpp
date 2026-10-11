// OWNER: AI-03
//
// C ABI surface: library calls, handle validation, model loading and job argument checks.
#include <cstring>
#include <string>

#include "dv_test.h"
#include "dv_test_support.h"
#include "dv_whisper.h"

using namespace dvt_support;

TEST(Abi, library_entry_points) {
  EXPECT_EQ(dv_abi_version(), 1);
  EXPECT_EQ(std::string(dv_engine_version()), std::string("1.9.4"));
  EXPECT_TRUE(std::strlen(dv_system_info()) > 0);
  EXPECT_EQ(dv_system_info(), dv_system_info());  // stable pointer
  EXPECT_GE(dv_lang_max_id(), 98);
  EXPECT_EQ(std::string(dv_lang_code(0)), std::string("en"));
  EXPECT_EQ(std::string(dv_lang_code(2)), std::string("de"));
  EXPECT_TRUE(dv_lang_code(-1) == nullptr);
  EXPECT_TRUE(dv_lang_code(dv_lang_max_id() + 1) == nullptr);
  EXPECT_GE(dv_perf_core_count(), 0);
#if defined(__APPLE__)
  EXPECT_EQ(dv_cpu_features(), static_cast<uint64_t>(0));
#endif
  dv_free(nullptr);
}

TEST(Abi, stale_and_null_handles_are_ignored) {
  // Never registered: every call must be a safe no-op / error.
  alignas(16) unsigned char fake[256] = {0};
  auto *m = reinterpret_cast<dv_model *>(fake);
  auto *j = reinterpret_cast<dv_job *>(fake);
  EXPECT_EQ(dv_model_get_state(m), DV_MODEL_FAILED);
  EXPECT_EQ(dv_model_get_state(nullptr), DV_MODEL_FAILED);
  char buf[32];
  EXPECT_EQ(dv_model_error(m, buf, sizeof(buf)), DV_ERR_INVALID_ARG);
  EXPECT_EQ(buf[0], '\0');
  dv_model_info info;
  std::memset(&info, 0, sizeof(info));
  info.struct_size = sizeof(info);
  EXPECT_EQ(dv_model_info_get(m, &info), DV_ERR_INVALID_ARG);
  dv_model_release(m);
  dv_model_release(nullptr);
  dv_job_status st;
  std::memset(&st, 0, sizeof(st));
  st.struct_size = sizeof(st);
  dv_job_status_get(j, &st);
  EXPECT_EQ(st.state, DV_JOB_FAILED);
  EXPECT_EQ(st.error, DV_ERR_INVALID_ARG);
  dv_job_status_get(j, nullptr);
  EXPECT_TRUE(dv_job_take_segments_json(j, 0, 10) == nullptr);
  EXPECT_TRUE(dv_job_language_probs_json(j, 3) == nullptr);
  dv_job_cancel(j);
  dv_job_pause(j, 1);
  dv_job_resume(j);
  dv_job_set_threads(j, 2);
  dv_job_free(j);
  dv_job_free(nullptr);
  int32_t status = -1;
  dv_job_params p = default_job_params(temp_path("x.wav"));
  EXPECT_TRUE(dv_job_start(m, &p, &status) == nullptr);
  EXPECT_EQ(status, DV_ERR_INVALID_ARG);
  EXPECT_TRUE(dv_job_start(nullptr, &p, nullptr) == nullptr);
  for (unsigned char c : fake) ASSERT_EQ(c, 0);  // nothing wrote through the fake handle
}

TEST(Model, load_rejects_null_empty_and_small_params) {
  EXPECT_TRUE(dv_model_load(nullptr, nullptr) == nullptr);
  EXPECT_TRUE(dv_model_load("", nullptr) == nullptr);
  dv_model_params small;
  std::memset(&small, 0, sizeof(small));
  small.struct_size = 4;
  EXPECT_TRUE(dv_model_load(fixture_whisper_model().c_str(), &small) == nullptr);
}

TEST(Model, missing_short_and_bad_magic_files_fail_without_crashing) {
  struct Case {
    std::string name;
    std::vector<uint8_t> bytes;
    bool create;
  };
  std::vector<uint8_t> bad_magic(4096, 0x00);
  std::vector<uint8_t> short_file = {0x6c, 0x6d, 0x67, 0x67, 1, 2, 3};
  const Case cases[] = {{"missing-model.bin", {}, false}, {"short-model.bin", short_file, true},
                        {"badmagic-model.bin", bad_magic, true}};
  for (const Case &c : cases) {
    const std::string path = temp_path(c.name);
    if (c.create) ASSERT_TRUE(write_file(path, c.bytes));
    int32_t state = -1;
    dv_model *m = load_model_blocking(path, &state);
    ASSERT_TRUE(m != nullptr);
    EXPECT_EQ(state, DV_MODEL_FAILED);
    char msg[128];
    EXPECT_EQ(dv_model_error(m, msg, sizeof(msg)), DV_ERR_MODEL_LOAD);
    EXPECT_TRUE(std::strlen(msg) > 0);
    EXPECT_TRUE(std::string(msg).find(c.name) == std::string::npos);  // never a path
    dv_model_info info;
    std::memset(&info, 0, sizeof(info));
    info.struct_size = sizeof(info);
    EXPECT_EQ(dv_model_info_get(m, &info), DV_ERR_MODEL_LOAD);
    int32_t status = -1;
    dv_job_params p = default_job_params(jfk_wav_path());
    EXPECT_TRUE(dv_job_start(m, &p, &status) == nullptr);
    EXPECT_EQ(status, DV_ERR_MODEL_LOAD);
    dv_model_release(m);
    dv_model_release(m);  // double release: ignored
  }
}

TEST(Model, unsupported_dtw_preset_fails_fast) {
  int32_t state = -1;
  dv_model *m = load_model_blocking(fixture_whisper_model(), &state, /*dtw_preset=*/2 /* CUSTOM */);
  ASSERT_TRUE(m != nullptr);
  EXPECT_EQ(state, DV_MODEL_FAILED);
  EXPECT_EQ(dv_model_error(m, nullptr, 0), DV_ERR_INVALID_ARG);
  dv_model_release(m);
}

TEST(Model, fixture_loads_with_info_and_release_frees_everything) {
  int64_t models0 = 0, jobs0 = 0;
  live_objects(&models0, &jobs0);
  int32_t state = -1;
  dv_model *m = load_model_blocking(fixture_whisper_model(), &state);
  ASSERT_TRUE(m != nullptr);
  ASSERT_EQ(state, DV_MODEL_READY);
  dv_model_info info;
  std::memset(&info, 0, sizeof(info));
  info.struct_size = sizeof(info);
  ASSERT_EQ(dv_model_info_get(m, &info), DV_OK);
  EXPECT_EQ(info.multilingual, 1);
  EXPECT_EQ(info.n_vocab, 51865);
  EXPECT_EQ(info.ftype, 1);
  EXPECT_EQ(info.gpu_used, 0);
  EXPECT_EQ(info.gpu_fallback, 0);
  // A caller with an older, smaller struct gets only its prefix.
  int32_t prefix[3] = {static_cast<int32_t>(sizeof(int32_t) * 2), -7, -7};
  ASSERT_EQ(dv_model_info_get(m, reinterpret_cast<dv_model_info *>(prefix)), DV_OK);
  EXPECT_EQ(prefix[1], 1);   // multilingual
  EXPECT_EQ(prefix[2], -7);  // untouched
  char msg[16] = "x";
  EXPECT_EQ(dv_model_error(m, msg, sizeof(msg)), DV_OK);
  EXPECT_EQ(msg[0], '\0');
  int64_t models1 = 0;
  live_objects(&models1, nullptr);
  EXPECT_EQ(models1, models0 + 1);
  dv_model_release(m);
  live_objects(&models1, nullptr);
  EXPECT_EQ(models1, models0);
}

TEST(Model, release_while_loading_is_safe) {
  int64_t models0 = 0;
  live_objects(&models0, nullptr);
  for (int i = 0; i < 5; ++i) {
    dv_model_params mp;
    std::memset(&mp, 0, sizeof(mp));
    mp.struct_size = sizeof(mp);
    mp.flash_attn = 1;
    dv_model *m = dv_model_load(fixture_whisper_model().c_str(), &mp);
    ASSERT_TRUE(m != nullptr);
    dv_model_release(m);  // the loader thread still holds its reference
    EXPECT_EQ(dv_model_get_state(m), DV_MODEL_FAILED);  // no longer a valid handle for the caller
  }
  dv_shutdown_all();  // waits for the detached loaders
  int64_t models1 = 0;
  live_objects(&models1, nullptr);
  EXPECT_EQ(models1, models0);
}

TEST(Model, job_start_validates_arguments) {
  int32_t state = -1;
  dv_model *m = load_model_blocking(fixture_whisper_model(), &state);
  ASSERT_EQ(state, DV_MODEL_READY);
  const std::string wav = temp_path("abi-2s.wav");
  std::vector<int16_t> pcm;
  append_noise(&pcm, 2.0, 0.1, 7);
  ASSERT_TRUE(write_wav16(wav, pcm));
  const std::string bad_wav = temp_path("abi-stereo.wav");
  ASSERT_TRUE(write_file(bad_wav, make_wav_bytes(pcm, 16000, 2, 16)));

  struct Case {
    const char *what;
    void (*mutate)(dv_job_params *);
    int32_t expect;
  };
  static std::string s_bad_wav;
  static std::string s_missing;
  s_bad_wav = bad_wav;
  s_missing = temp_path("missing.wav");
  const Case cases[] = {
      {"small struct", [](dv_job_params *p) { p->struct_size = 8; }, DV_ERR_INVALID_ARG},
      {"bad mode", [](dv_job_params *p) { p->mode = 7; }, DV_ERR_INVALID_ARG},
      {"null wav", [](dv_job_params *p) { p->wav_path = nullptr; }, DV_ERR_INVALID_ARG},
      {"negative start", [](dv_job_params *p) { p->range_start_ms = -1; }, DV_ERR_INVALID_ARG},
      {"end before start", [](dv_job_params *p) { p->range_start_ms = 500; p->range_end_ms = 100; }, DV_ERR_INVALID_ARG},
      {"start past end of file", [](dv_job_params *p) { p->range_start_ms = 60000; }, DV_ERR_INVALID_ARG},
      {"zero threads", [](dv_job_params *p) { p->n_threads = 0; }, DV_ERR_INVALID_ARG},
      {"nine threads", [](dv_job_params *p) { p->n_threads = 9; }, DV_ERR_INVALID_ARG},
      {"unknown language", [](dv_job_params *p) { p->language = "xx"; }, DV_ERR_INVALID_ARG},
      {"auto in transcribe", [](dv_job_params *p) { p->language = "auto"; }, DV_ERR_INVALID_ARG},
      {"null language", [](dv_job_params *p) { p->language = nullptr; }, DV_ERR_INVALID_ARG},
      {"negative chunk", [](dv_job_params *p) { p->chunk_target_ms = -5; }, DV_ERR_INVALID_ARG},
      {"negative carry", [](dv_job_params *p) { p->carry_prompt_words = -1; }, DV_ERR_INVALID_ARG},
      {"vad without model", [](dv_job_params *p) { p->vad_enabled = 1; p->vad_model_path = nullptr; }, DV_ERR_VAD_MODEL},
      {"stereo wav", [](dv_job_params *p) { p->wav_path = s_bad_wav.c_str(); }, DV_ERR_WAV_FORMAT},
      {"missing wav", [](dv_job_params *p) { p->wav_path = s_missing.c_str(); }, DV_ERR_IO},
  };
  for (const Case &c : cases) {
    dv_job_params p = default_job_params(wav);
    c.mutate(&p);
    int32_t status = -1;
    dv_job *j = dv_job_start(m, &p, &status);
    if (j != nullptr || status != c.expect) std::fprintf(stderr, "  case: %s\n", c.what);
    EXPECT_TRUE(j == nullptr);
    EXPECT_EQ(status, c.expect);
    if (j != nullptr) dv_job_free(j);
  }
  EXPECT_TRUE(dv_job_start(m, nullptr, nullptr) == nullptr);
  // The model is still free for a valid job afterwards.
  dv_job_params ok = default_job_params(wav);
  int32_t status = -1;
  dv_job *j = dv_job_start(m, &ok, &status);
  ASSERT_EQ(status, DV_OK);
  const dv_job_status st = wait_job(j);
  EXPECT_EQ(st.state, DV_JOB_SUCCEEDED);
  dv_job_free(j);
  dv_model_release(m);
}
