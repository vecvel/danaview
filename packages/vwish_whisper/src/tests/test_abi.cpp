// OWNER: AI-03
//
// C ABI surface: library calls, handle validation, model loading and job argument checks.
#include <cstring>
#include <string>

#include "vw_test.h"
#include "vw_test_support.h"
#include "vw_whisper.h"

using namespace vwt_support;

TEST(Abi, library_entry_points) {
  EXPECT_EQ(vw_abi_version(), 1);
  EXPECT_EQ(std::string(vw_engine_version()), std::string("1.9.4"));
  EXPECT_TRUE(std::strlen(vw_system_info()) > 0);
  EXPECT_EQ(vw_system_info(), vw_system_info());  // stable pointer
  EXPECT_GE(vw_lang_max_id(), 98);
  EXPECT_EQ(std::string(vw_lang_code(0)), std::string("en"));
  EXPECT_EQ(std::string(vw_lang_code(2)), std::string("de"));
  EXPECT_TRUE(vw_lang_code(-1) == nullptr);
  EXPECT_TRUE(vw_lang_code(vw_lang_max_id() + 1) == nullptr);
  EXPECT_GE(vw_perf_core_count(), 0);
#if defined(__APPLE__)
  EXPECT_EQ(vw_cpu_features(), static_cast<uint64_t>(0));
#endif
  vw_free(nullptr);
}

TEST(Abi, stale_and_null_handles_are_ignored) {
  // Never registered: every call must be a safe no-op / error.
  alignas(16) unsigned char fake[256] = {0};
  auto *m = reinterpret_cast<vw_model *>(fake);
  auto *j = reinterpret_cast<vw_job *>(fake);
  EXPECT_EQ(vw_model_get_state(m), VW_MODEL_FAILED);
  EXPECT_EQ(vw_model_get_state(nullptr), VW_MODEL_FAILED);
  char buf[32];
  EXPECT_EQ(vw_model_error(m, buf, sizeof(buf)), VW_ERR_INVALID_ARG);
  EXPECT_EQ(buf[0], '\0');
  vw_model_info info;
  std::memset(&info, 0, sizeof(info));
  info.struct_size = sizeof(info);
  EXPECT_EQ(vw_model_info_get(m, &info), VW_ERR_INVALID_ARG);
  vw_model_release(m);
  vw_model_release(nullptr);
  vw_job_status st;
  std::memset(&st, 0, sizeof(st));
  st.struct_size = sizeof(st);
  vw_job_status_get(j, &st);
  EXPECT_EQ(st.state, VW_JOB_FAILED);
  EXPECT_EQ(st.error, VW_ERR_INVALID_ARG);
  vw_job_status_get(j, nullptr);
  EXPECT_TRUE(vw_job_take_segments_json(j, 0, 10) == nullptr);
  EXPECT_TRUE(vw_job_language_probs_json(j, 3) == nullptr);
  vw_job_cancel(j);
  vw_job_pause(j, 1);
  vw_job_resume(j);
  vw_job_set_threads(j, 2);
  vw_job_free(j);
  vw_job_free(nullptr);
  int32_t status = -1;
  vw_job_params p = default_job_params(temp_path("x.wav"));
  EXPECT_TRUE(vw_job_start(m, &p, &status) == nullptr);
  EXPECT_EQ(status, VW_ERR_INVALID_ARG);
  EXPECT_TRUE(vw_job_start(nullptr, &p, nullptr) == nullptr);
  for (unsigned char c : fake) ASSERT_EQ(c, 0);  // nothing wrote through the fake handle
}

TEST(Model, load_rejects_null_empty_and_small_params) {
  EXPECT_TRUE(vw_model_load(nullptr, nullptr) == nullptr);
  EXPECT_TRUE(vw_model_load("", nullptr) == nullptr);
  vw_model_params small;
  std::memset(&small, 0, sizeof(small));
  small.struct_size = 4;
  EXPECT_TRUE(vw_model_load(fixture_whisper_model().c_str(), &small) == nullptr);
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
    vw_model *m = load_model_blocking(path, &state);
    ASSERT_TRUE(m != nullptr);
    EXPECT_EQ(state, VW_MODEL_FAILED);
    char msg[128];
    EXPECT_EQ(vw_model_error(m, msg, sizeof(msg)), VW_ERR_MODEL_LOAD);
    EXPECT_TRUE(std::strlen(msg) > 0);
    EXPECT_TRUE(std::string(msg).find(c.name) == std::string::npos);  // never a path
    vw_model_info info;
    std::memset(&info, 0, sizeof(info));
    info.struct_size = sizeof(info);
    EXPECT_EQ(vw_model_info_get(m, &info), VW_ERR_MODEL_LOAD);
    int32_t status = -1;
    vw_job_params p = default_job_params(jfk_wav_path());
    EXPECT_TRUE(vw_job_start(m, &p, &status) == nullptr);
    EXPECT_EQ(status, VW_ERR_MODEL_LOAD);
    vw_model_release(m);
    vw_model_release(m);  // double release: ignored
  }
}

TEST(Model, unsupported_dtw_preset_fails_fast) {
  int32_t state = -1;
  vw_model *m = load_model_blocking(fixture_whisper_model(), &state, /*dtw_preset=*/2 /* CUSTOM */);
  ASSERT_TRUE(m != nullptr);
  EXPECT_EQ(state, VW_MODEL_FAILED);
  EXPECT_EQ(vw_model_error(m, nullptr, 0), VW_ERR_INVALID_ARG);
  vw_model_release(m);
}

TEST(Model, fixture_loads_with_info_and_release_frees_everything) {
  int64_t models0 = 0, jobs0 = 0;
  live_objects(&models0, &jobs0);
  int32_t state = -1;
  vw_model *m = load_model_blocking(fixture_whisper_model(), &state);
  ASSERT_TRUE(m != nullptr);
  ASSERT_EQ(state, VW_MODEL_READY);
  vw_model_info info;
  std::memset(&info, 0, sizeof(info));
  info.struct_size = sizeof(info);
  ASSERT_EQ(vw_model_info_get(m, &info), VW_OK);
  EXPECT_EQ(info.multilingual, 1);
  EXPECT_EQ(info.n_vocab, 51865);
  EXPECT_EQ(info.ftype, 1);
  EXPECT_EQ(info.gpu_used, 0);
  EXPECT_EQ(info.gpu_fallback, 0);
  // A caller with an older, smaller struct gets only its prefix.
  int32_t prefix[3] = {static_cast<int32_t>(sizeof(int32_t) * 2), -7, -7};
  ASSERT_EQ(vw_model_info_get(m, reinterpret_cast<vw_model_info *>(prefix)), VW_OK);
  EXPECT_EQ(prefix[1], 1);   // multilingual
  EXPECT_EQ(prefix[2], -7);  // untouched
  char msg[16] = "x";
  EXPECT_EQ(vw_model_error(m, msg, sizeof(msg)), VW_OK);
  EXPECT_EQ(msg[0], '\0');
  int64_t models1 = 0;
  live_objects(&models1, nullptr);
  EXPECT_EQ(models1, models0 + 1);
  vw_model_release(m);
  live_objects(&models1, nullptr);
  EXPECT_EQ(models1, models0);
}

TEST(Model, release_while_loading_is_safe) {
  int64_t models0 = 0;
  live_objects(&models0, nullptr);
  for (int i = 0; i < 5; ++i) {
    vw_model_params mp;
    std::memset(&mp, 0, sizeof(mp));
    mp.struct_size = sizeof(mp);
    mp.flash_attn = 1;
    vw_model *m = vw_model_load(fixture_whisper_model().c_str(), &mp);
    ASSERT_TRUE(m != nullptr);
    vw_model_release(m);  // the loader thread still holds its reference
    EXPECT_EQ(vw_model_get_state(m), VW_MODEL_FAILED);  // no longer a valid handle for the caller
  }
  vw_shutdown_all();  // waits for the detached loaders
  int64_t models1 = 0;
  live_objects(&models1, nullptr);
  EXPECT_EQ(models1, models0);
}

TEST(Model, job_start_validates_arguments) {
  int32_t state = -1;
  vw_model *m = load_model_blocking(fixture_whisper_model(), &state);
  ASSERT_EQ(state, VW_MODEL_READY);
  const std::string wav = temp_path("abi-2s.wav");
  std::vector<int16_t> pcm;
  append_noise(&pcm, 2.0, 0.1, 7);
  ASSERT_TRUE(write_wav16(wav, pcm));
  const std::string bad_wav = temp_path("abi-stereo.wav");
  ASSERT_TRUE(write_file(bad_wav, make_wav_bytes(pcm, 16000, 2, 16)));

  struct Case {
    const char *what;
    void (*mutate)(vw_job_params *);
    int32_t expect;
  };
  static std::string s_bad_wav;
  static std::string s_missing;
  s_bad_wav = bad_wav;
  s_missing = temp_path("missing.wav");
  const Case cases[] = {
      {"small struct", [](vw_job_params *p) { p->struct_size = 8; }, VW_ERR_INVALID_ARG},
      {"bad mode", [](vw_job_params *p) { p->mode = 7; }, VW_ERR_INVALID_ARG},
      {"null wav", [](vw_job_params *p) { p->wav_path = nullptr; }, VW_ERR_INVALID_ARG},
      {"negative start", [](vw_job_params *p) { p->range_start_ms = -1; }, VW_ERR_INVALID_ARG},
      {"end before start", [](vw_job_params *p) { p->range_start_ms = 500; p->range_end_ms = 100; }, VW_ERR_INVALID_ARG},
      {"start past end of file", [](vw_job_params *p) { p->range_start_ms = 60000; }, VW_ERR_INVALID_ARG},
      {"zero threads", [](vw_job_params *p) { p->n_threads = 0; }, VW_ERR_INVALID_ARG},
      {"nine threads", [](vw_job_params *p) { p->n_threads = 9; }, VW_ERR_INVALID_ARG},
      {"unknown language", [](vw_job_params *p) { p->language = "xx"; }, VW_ERR_INVALID_ARG},
      {"auto in transcribe", [](vw_job_params *p) { p->language = "auto"; }, VW_ERR_INVALID_ARG},
      {"null language", [](vw_job_params *p) { p->language = nullptr; }, VW_ERR_INVALID_ARG},
      {"negative chunk", [](vw_job_params *p) { p->chunk_target_ms = -5; }, VW_ERR_INVALID_ARG},
      {"negative carry", [](vw_job_params *p) { p->carry_prompt_words = -1; }, VW_ERR_INVALID_ARG},
      {"vad without model", [](vw_job_params *p) { p->vad_enabled = 1; p->vad_model_path = nullptr; }, VW_ERR_VAD_MODEL},
      {"stereo wav", [](vw_job_params *p) { p->wav_path = s_bad_wav.c_str(); }, VW_ERR_WAV_FORMAT},
      {"missing wav", [](vw_job_params *p) { p->wav_path = s_missing.c_str(); }, VW_ERR_IO},
  };
  for (const Case &c : cases) {
    vw_job_params p = default_job_params(wav);
    c.mutate(&p);
    int32_t status = -1;
    vw_job *j = vw_job_start(m, &p, &status);
    if (j != nullptr || status != c.expect) std::fprintf(stderr, "  case: %s\n", c.what);
    EXPECT_TRUE(j == nullptr);
    EXPECT_EQ(status, c.expect);
    if (j != nullptr) vw_job_free(j);
  }
  EXPECT_TRUE(vw_job_start(m, nullptr, nullptr) == nullptr);
  // The model is still free for a valid job afterwards.
  vw_job_params ok = default_job_params(wav);
  int32_t status = -1;
  vw_job *j = vw_job_start(m, &ok, &status);
  ASSERT_EQ(status, VW_OK);
  const vw_job_status st = wait_job(j);
  EXPECT_EQ(st.state, VW_JOB_SUCCEEDED);
  vw_job_free(j);
  vw_model_release(m);
}
