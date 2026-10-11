// OWNER: AI-03
//
// Strict reader for the speech WAV the engines extract (ai.md §4.6, §7): RIFF/WAVE, PCM s16le, mono,
// 16 kHz, with a data chunk whose declared size fits in the file. Anything else is DV_ERR_WAV_FORMAT
// (never sent to whisper: GGML_ASSERT aborts the process). Samples are read in ranges, so a 1 h file
// never needs more than one chunk in memory.
#ifndef DV_WAV_H
#define DV_WAV_H

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

namespace dv {

constexpr int32_t kSampleRate = 16000;
constexpr int64_t kSamplesPerMs = kSampleRate / 1000;

inline int64_t ms_to_samples(int64_t ms) { return ms * kSamplesPerMs; }
inline int64_t samples_to_ms(int64_t samples) { return samples / kSamplesPerMs; }

/// Header facts of a validated WAV file.
struct WavInfo {
  int64_t data_offset = 0;  // byte offset of the first sample
  int64_t n_samples = 0;    // number of 16-bit mono samples
};

/// Validates [path]'s header. Returns DV_OK, DV_ERR_IO (cannot open or read) or DV_ERR_WAV_FORMAT.
int32_t wav_probe(const std::string &path, WavInfo *out);

/// Validates an in-memory header prefix (used by wav_probe and the tests). [file_size] is the size of
/// the whole file; [bytes] holds at least the chunks up to the data chunk header.
int32_t wav_parse_header(const uint8_t *bytes, size_t n, int64_t file_size, WavInfo *out);

/// Range reader over a validated WAV file. One reader per job thread (not shared).
class WavReader {
 public:
  WavReader() = default;
  ~WavReader();
  WavReader(const WavReader &) = delete;
  WavReader &operator=(const WavReader &) = delete;

  /// Opens and validates; DV_OK, DV_ERR_IO or DV_ERR_WAV_FORMAT.
  int32_t open(const std::string &path);
  int64_t n_samples() const { return info_.n_samples; }

  /// Reads samples [start, start + count) (clamped to the file) as floats in [-1, 1).
  /// Returns DV_OK or DV_ERR_IO.
  int32_t read(int64_t start, int64_t count, std::vector<float> *out);

 private:
  std::FILE *file_ = nullptr;
  WavInfo info_;
  std::vector<uint8_t> scratch_;
};

}  // namespace dv

#endif  // DV_WAV_H
