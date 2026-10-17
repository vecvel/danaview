// OWNER: AI-03
//
// WAV validator and range reader (ai.md §16.3 item 7).
#include <cstring>

#include "dv_test.h"
#include "dv_test_support.h"
#include "dv_wav.h"

using namespace dvt_support;

namespace {

std::vector<int16_t> ramp(size_t n) {
  std::vector<int16_t> s(n);
  for (size_t i = 0; i < n; ++i) s[i] = static_cast<int16_t>(static_cast<int32_t>(i % 2000) - 1000);
  return s;
}

int32_t probe_bytes(const std::vector<uint8_t> &bytes, dv::WavInfo *info = nullptr) {
  dv::WavInfo tmp;
  return dv::wav_parse_header(bytes.data(), bytes.size(), static_cast<int64_t>(bytes.size()), info ? info : &tmp);
}

int32_t probe_file(const std::string &name, const std::vector<uint8_t> &bytes) {
  const std::string p = temp_path(name);
  if (!write_file(p, bytes)) return -1;
  dv::WavInfo info;
  return dv::wav_probe(p, &info);
}

}  // namespace

TEST(Wav, accepts_canonical_16k_mono_s16) {
  dv::WavInfo info;
  const auto bytes = make_wav_bytes(ramp(16000), 16000, 1, 16);
  ASSERT_EQ(probe_bytes(bytes, &info), DV_OK);
  EXPECT_EQ(info.n_samples, 16000);
  EXPECT_EQ(info.data_offset, 44);
  EXPECT_EQ(probe_file("ok.wav", bytes), DV_OK);
}

TEST(Wav, rejects_wrong_rate) {
  EXPECT_EQ(probe_bytes(make_wav_bytes(ramp(4410), 44100, 1, 16)), DV_ERR_WAV_FORMAT);
  EXPECT_EQ(probe_bytes(make_wav_bytes(ramp(4800), 48000, 1, 16)), DV_ERR_WAV_FORMAT);
  EXPECT_EQ(probe_bytes(make_wav_bytes(ramp(800), 8000, 1, 16)), DV_ERR_WAV_FORMAT);
}

TEST(Wav, rejects_stereo) { EXPECT_EQ(probe_bytes(make_wav_bytes(ramp(3200), 16000, 2, 16)), DV_ERR_WAV_FORMAT); }

TEST(Wav, rejects_24_bit) { EXPECT_EQ(probe_bytes(make_wav_bytes(ramp(1600), 16000, 1, 24)), DV_ERR_WAV_FORMAT); }

TEST(Wav, rejects_float_and_other_codecs) {
  EXPECT_EQ(probe_bytes(make_wav_bytes(ramp(1600), 16000, 1, 16, 3)), DV_ERR_WAV_FORMAT);  // IEEE float tag
  EXPECT_EQ(probe_bytes(make_wav_bytes(ramp(1600), 16000, 1, 16, 6)), DV_ERR_WAV_FORMAT);  // A-law
}

TEST(Wav, rejects_truncated_files) {
  const auto full = make_wav_bytes(ramp(16000), 16000, 1, 16);
  // Data chunk declares more bytes than the file holds.
  std::vector<uint8_t> cut(full.begin(), full.end() - 1000);
  EXPECT_EQ(probe_bytes(cut), DV_ERR_WAV_FORMAT);
  EXPECT_EQ(probe_file("truncated.wav", cut), DV_ERR_WAV_FORMAT);
  // Header cut inside the fmt chunk / before "data".
  EXPECT_EQ(probe_bytes(std::vector<uint8_t>(full.begin(), full.begin() + 30)), DV_ERR_WAV_FORMAT);
  EXPECT_EQ(probe_bytes(std::vector<uint8_t>(full.begin(), full.begin() + 40)), DV_ERR_WAV_FORMAT);
  EXPECT_EQ(probe_bytes(std::vector<uint8_t>(full.begin(), full.begin() + 8)), DV_ERR_WAV_FORMAT);
  // Odd data size (half a sample).
  auto odd = make_wav_bytes(ramp(10), 16000, 1, 16);
  odd[40] = 19;
  odd.pop_back();
  EXPECT_EQ(probe_bytes(odd), DV_ERR_WAV_FORMAT);
}

TEST(Wav, rejects_non_riff_and_missing_fmt) {
  auto bytes = make_wav_bytes(ramp(100), 16000, 1, 16);
  auto rifx = bytes;
  std::memcpy(rifx.data(), "RIFX", 4);
  EXPECT_EQ(probe_bytes(rifx), DV_ERR_WAV_FORMAT);
  auto avi = bytes;
  std::memcpy(avi.data() + 8, "AVI ", 4);
  EXPECT_EQ(probe_bytes(avi), DV_ERR_WAV_FORMAT);
  // "data" before "fmt ": rename the fmt chunk so the first known chunk is data.
  auto nofmt = bytes;
  std::memcpy(nofmt.data() + 12, "junk", 4);
  EXPECT_EQ(probe_bytes(nofmt), DV_ERR_WAV_FORMAT);
  EXPECT_EQ(probe_bytes(std::vector<uint8_t>{'R', 'I', 'F', 'F'}), DV_ERR_WAV_FORMAT);
  EXPECT_EQ(dv::wav_parse_header(nullptr, 0, 0, nullptr), DV_ERR_INVALID_ARG);
}

TEST(Wav, skips_list_chunks_and_reads_jfk) {
  const std::string jfk = jfk_wav_path();
  dv::WavInfo info;
  ASSERT_EQ(dv::wav_probe(jfk, &info), DV_OK);  // has a LIST/INFO chunk before data
  EXPECT_EQ(info.n_samples, 176000);
}

TEST(Wav, missing_file_is_io_error) {
  dv::WavInfo info;
  EXPECT_EQ(dv::wav_probe(temp_path("does-not-exist.wav"), &info), DV_ERR_IO);
}

TEST(Wav, range_reads_are_exact_and_clamped) {
  const auto samples = ramp(50000);
  const std::string p = temp_path("ramp.wav");
  ASSERT_TRUE(write_wav16(p, samples));
  dv::WavReader r;
  ASSERT_EQ(r.open(p), DV_OK);
  EXPECT_EQ(r.n_samples(), 50000);
  std::vector<float> out;
  ASSERT_EQ(r.read(12345, 1000, &out), DV_OK);
  ASSERT_EQ(out.size(), static_cast<size_t>(1000));
  for (size_t i = 0; i < out.size(); ++i) {
    EXPECT_EQ(static_cast<int>(out[i] * 32768.0f), static_cast<int>(samples[12345 + i]));
    if (dvt::state().failures > 0) break;
  }
  ASSERT_EQ(r.read(49900, 1000, &out), DV_OK);  // clamped at the end
  EXPECT_EQ(out.size(), static_cast<size_t>(100));
  ASSERT_EQ(r.read(60000, 10, &out), DV_OK);  // past the end
  EXPECT_EQ(out.size(), static_cast<size_t>(0));
  // Large read crossing the reader's 64k-sample block size.
  ASSERT_EQ(r.read(0, 50000, &out), DV_OK);
  EXPECT_EQ(out.size(), static_cast<size_t>(50000));
  EXPECT_EQ(static_cast<int>(out[49999] * 32768.0f), static_cast<int>(samples[49999]));
}
