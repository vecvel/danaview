// OWNER: AI-03
//
// VAD: speech-only buffer + time map (pure), the energy fallback, and Silero through whisper's VAD API
// with the tone-detecting fixture model (vw_test_support.h).
#include <cmath>

#include "vw_test.h"
#include "vw_test_support.h"
#include "vw_vad.h"
#include "vw_wav.h"

using namespace vwt_support;

namespace {

std::vector<float> to_float(const std::vector<int16_t> &pcm) {
  std::vector<float> f(pcm.size());
  for (size_t i = 0; i < pcm.size(); ++i) f[i] = pcm[i] / 32768.0f;
  return f;
}

// 2 s silence, 3 s tone, 3 s silence, 2 s tone, 2 s silence.
std::vector<int16_t> two_bursts() {
  std::vector<int16_t> pcm;
  append_silence(&pcm, 2.0);
  append_tone(&pcm, 3.0, kVadToneHz, 0.3);
  append_silence(&pcm, 3.0);
  append_tone(&pcm, 2.0, kVadToneHz, 0.3);
  append_silence(&pcm, 2.0);
  return pcm;
}

}  // namespace

TEST(Vad, filter_concatenates_spans_with_overlap_and_silence) {
  std::vector<float> s(10 * 16000, 0.25f);
  vw::VadFiltered f;
  vw::vad_filter(s.data(), static_cast<int64_t>(s.size()), {{100, 200}, {500, 600}}, 0.1f, &f);
  ASSERT_EQ(f.segments.size(), static_cast<size_t>(2));
  EXPECT_EQ(f.samples.size(), static_cast<size_t>(17600 + 1600 + 16000));
  EXPECT_EQ(f.segments[0].vad_start, 0);
  EXPECT_EQ(f.segments[0].vad_end, 100);
  EXPECT_EQ(f.segments[1].vad_start, 120);
  EXPECT_EQ(f.segments[1].vad_end, 220);
  // The 0.1 s separator is silent.
  EXPECT_EQ(f.samples[17600 + 800], 0.0f);
  EXPECT_EQ(f.samples[100], 0.25f);
}

TEST(Vad, map_back_is_segment_aware) {
  const std::vector<vw::VadMapSegment> segs = {{100, 200, 0, 100}, {500, 600, 120, 220}};
  EXPECT_EQ(vw::vad_map_time_cs(0, segs), 100);
  EXPECT_EQ(vw::vad_map_time_cs(50, segs), 150);
  EXPECT_EQ(vw::vad_map_time_cs(110, segs), 200);  // inside the gap, nearer the first span
  EXPECT_EQ(vw::vad_map_time_cs(115, segs), 500);  // nearer the second span
  EXPECT_EQ(vw::vad_map_time_cs(170, segs), 550);
  EXPECT_EQ(vw::vad_map_time_cs(999, segs), 600);
  EXPECT_EQ(vw::vad_map_time_cs(42, {}), 42);
}

TEST(Vad, rms_fallback_finds_first_speech) {
  const auto pcm = two_bursts();
  const auto f = to_float(pcm);
  vw::SampleReadFn read = [&f](int64_t s, int64_t n, std::vector<float> *out) {
    out->assign(f.begin() + s, f.begin() + std::min<int64_t>(static_cast<int64_t>(f.size()), s + n));
    return static_cast<int32_t>(VW_OK);
  };
  int64_t at = -2;
  ASSERT_EQ(vw::rms_first_speech(read, 0, static_cast<int64_t>(f.size()), 250 * 16, &at), VW_OK);
  EXPECT_EQ(at, 2 * 16000);
  // Searching only inside the leading silence finds nothing.
  ASSERT_EQ(vw::rms_first_speech(read, 0, 2 * 16000, 250 * 16, &at), VW_OK);
  EXPECT_EQ(at, -1);
  // A burst shorter than min_speech is ignored.
  std::vector<int16_t> blip;
  append_silence(&blip, 1.0);
  append_tone(&blip, 0.1, 1000.0, 0.5);
  append_silence(&blip, 1.0);
  const auto fb = to_float(blip);
  vw::SampleReadFn read2 = [&fb](int64_t s, int64_t n, std::vector<float> *out) {
    out->assign(fb.begin() + s, fb.begin() + std::min<int64_t>(static_cast<int64_t>(fb.size()), s + n));
    return static_cast<int32_t>(VW_OK);
  };
  ASSERT_EQ(vw::rms_first_speech(read2, 0, static_cast<int64_t>(fb.size()), 250 * 16, &at), VW_OK);
  EXPECT_EQ(at, -1);
}

TEST(Vad, model_load_rejects_missing_and_non_ggml_files) {
  vw::VadModel m;
  EXPECT_EQ(m.load(temp_path("no-such-vad.bin"), 2), VW_ERR_VAD_MODEL);
  const std::string junk = temp_path("junk-vad.bin");
  ASSERT_TRUE(write_file(junk, std::vector<uint8_t>(4096, 0x42)));
  EXPECT_EQ(m.load(junk, 2), VW_ERR_VAD_MODEL);
  EXPECT_EQ(m.load("", 2), VW_ERR_VAD_MODEL);
  EXPECT_FALSE(m.loaded());
  std::vector<vw::SpeechSpan> spans;
  float x = 0.0f;
  EXPECT_EQ(m.detect(&x, 1, vw::VadParams(), &spans), VW_ERR_VAD_MODEL);
}

TEST(Vad, fixture_model_detects_tone_bursts) {
  vw::VadModel m;
  ASSERT_EQ(m.load(fixture_vad_model(), 2), VW_OK);
  ASSERT_TRUE(m.loaded());
  const auto f = to_float(two_bursts());
  std::vector<vw::SpeechSpan> spans;
  ASSERT_EQ(m.detect(f.data(), static_cast<int64_t>(f.size()), vw::VadParams(), &spans), VW_OK);
  ASSERT_EQ(spans.size(), static_cast<size_t>(2));
  // speech_pad_ms = 100 widens each burst; frames are 32 ms.
  EXPECT_LT(std::llabs(spans[0].t0_cs - 190), 15);
  EXPECT_LT(std::llabs(spans[0].t1_cs - 510), 15);
  EXPECT_LT(std::llabs(spans[1].t0_cs - 790), 15);
  EXPECT_LT(std::llabs(spans[1].t1_cs - 1010), 15);
  // Silence only: no spans. Empty input: no spans.
  std::vector<float> quiet(5 * 16000, 0.0f);
  ASSERT_EQ(m.detect(quiet.data(), static_cast<int64_t>(quiet.size()), vw::VadParams(), &spans), VW_OK);
  EXPECT_TRUE(spans.empty());
  ASSERT_EQ(m.detect(quiet.data(), 0, vw::VadParams(), &spans), VW_OK);
  EXPECT_TRUE(spans.empty());
}
