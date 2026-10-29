// OWNER: AI-03
//
// Voice activity detection for the shim (ai.md §4.6). whisper_full_with_state() ignores
// whisper_full_params.vad (only whisper_full(), which needs the context's default state, runs VAD), so
// the shim runs Silero itself through the public whisper_vad_* API and mirrors whisper's own filtering:
// speech spans (plus samples_overlap after every span but the last) are concatenated with 0.1 s of
// silence between them, and times are mapped back segment-aware (a time inside a removed gap snaps to
// the nearest speech boundary), exactly like whisper_full_get_token_t0_from_state().
#ifndef DV_VAD_H
#define DV_VAD_H

#include <cstdint>
#include <string>
#include <vector>

#include "dv_chunker.h"

struct whisper_vad_context;

namespace dv {

/// VAD tuning (dv_job_params).
struct VadParams {
  float threshold = 0.5f;
  int32_t min_speech_ms = 250;
  int32_t min_silence_ms = 300;
  int32_t speech_pad_ms = 100;
  float samples_overlap_s = 0.1f;
};

/// A detected speech span in centiseconds relative to the analysed buffer.
struct SpeechSpan {
  int64_t t0_cs = 0;
  int64_t t1_cs = 0;
};

/// One kept span: where it was (orig) and where it landed in the filtered buffer (vad), in cs.
struct VadMapSegment {
  int64_t orig_start = 0;
  int64_t orig_end = 0;
  int64_t vad_start = 0;
  int64_t vad_end = 0;
};

/// The filtered (speech only) buffer and its time map.
struct VadFiltered {
  std::vector<float> samples;
  std::vector<VadMapSegment> segments;
};

/// Builds the speech-only buffer from [spans] like whisper_vad() does.
void vad_filter(const float *samples, int64_t n_samples, const std::vector<SpeechSpan> &spans, float overlap_s,
                VadFiltered *out);

/// Maps a time in the filtered buffer (cs) back to the original buffer (cs).
int64_t vad_map_time_cs(int64_t t_cs, const std::vector<VadMapSegment> &segments);

/// A loaded Silero VAD model (one per job thread).
class VadModel {
 public:
  VadModel() = default;
  ~VadModel();
  VadModel(const VadModel &) = delete;
  VadModel &operator=(const VadModel &) = delete;

  /// DV_OK, or DV_ERR_VAD_MODEL when the file is missing or not a ggml VAD model. The model always runs
  /// on one thread (see dv_vad.cpp), whatever the job's thread count.
  int32_t load(const std::string &path);
  bool loaded() const { return ctx_ != nullptr; }

  /// Speech spans of [samples]; DV_OK or DV_ERR_INFERENCE.
  int32_t detect(const float *samples, int64_t n_samples, const VadParams &params, std::vector<SpeechSpan> *out);

 private:
  whisper_vad_context *ctx_ = nullptr;
};

/// Energy fallback used by DETECT when VAD is off: the first sample (absolute) of the first run of
/// 20 ms frames, at least [min_speech] samples long, whose RMS reaches -40 dBFS; -1 when none.
int32_t rms_first_speech(const SampleReadFn &read, int64_t start, int64_t end, int64_t min_speech, int64_t *out);

/// Speech threshold of the energy fallback (linear RMS, -40 dBFS).
constexpr float kRmsSpeechThreshold = 0.01f;

}  // namespace dv

#endif  // DV_VAD_H
