// OWNER: AI-03
//
// Silero VAD wrapper, speech-only buffer and time map, and the RMS fallback (see dv_vad.h).
#include "dv_vad.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>

#include "dv_registry.h"
#include "dv_whisper.h"
#include "dv_wav.h"
#include "whisper.h"

namespace dv {
namespace vad_detail {

// Same rounding as whisper.cpp's static cs_to_samples / samples_to_cs.
int64_t cs_to_samples_w(int64_t cs) { return static_cast<int64_t>((static_cast<double>(cs) / 100.0) * kSampleRate + 0.5); }
int64_t samples_to_cs_w(int64_t samples) {
  return static_cast<int64_t>((static_cast<double>(samples) / static_cast<double>(kSampleRate)) * 100.0 + 0.5);
}

bool has_ggml_magic(const std::string &path) {
  std::FILE *f = std::fopen(path.c_str(), "rb");
  if (f == nullptr) return false;
  unsigned char m[4] = {0, 0, 0, 0};
  const size_t n = std::fread(m, 1, 4, f);
  std::fclose(f);
  // GGML_FILE_MAGIC 0x67676d6c stored little endian.
  return n == 4 && m[0] == 0x6c && m[1] == 0x6d && m[2] == 0x67 && m[3] == 0x67;
}

}  // namespace vad_detail

void vad_filter(const float *samples, int64_t n_samples, const std::vector<SpeechSpan> &spans, float overlap_s,
                VadFiltered *out) {
  using namespace vad_detail;
  out->samples.clear();
  out->segments.clear();
  if (n_samples <= 0 || spans.empty()) return;
  const int64_t overlap = static_cast<int64_t>(overlap_s * kSampleRate);
  const int64_t silence = kSampleRate / 10;  // 0.1 s between spans
  int64_t total = 0;
  for (size_t i = 0; i < spans.size(); ++i) {
    int64_t s0 = std::min(cs_to_samples_w(spans[i].t0_cs), n_samples - 1);
    int64_t s1 = cs_to_samples_w(spans[i].t1_cs);
    if (i + 1 < spans.size()) s1 += overlap;
    s1 = std::min(s1, n_samples - 1);
    if (s1 > s0) total += s1 - s0;
    if (i + 1 < spans.size()) total += silence;
  }
  out->samples.reserve(static_cast<size_t>(std::max<int64_t>(total, 0)));
  int64_t offset = 0;
  for (size_t i = 0; i < spans.size(); ++i) {
    const int64_t s0 = std::min(cs_to_samples_w(spans[i].t0_cs), n_samples - 1);
    const int64_t s1_orig = std::min(cs_to_samples_w(spans[i].t1_cs), n_samples - 1);
    const int64_t original_len = s1_orig - s0;
    int64_t s1 = s1_orig;
    if (i + 1 < spans.size()) s1 = std::min(s1_orig + overlap, n_samples - 1);
    const int64_t len = s1 - s0;
    if (len <= 0) continue;
    VadMapSegment seg;
    seg.orig_start = spans[i].t0_cs;
    seg.orig_end = spans[i].t1_cs;
    seg.vad_start = samples_to_cs_w(offset);
    seg.vad_end = samples_to_cs_w(offset + original_len);
    out->segments.push_back(seg);
    out->samples.insert(out->samples.end(), samples + s0, samples + s1);
    offset += len;
    if (i + 1 < spans.size()) {
      out->samples.insert(out->samples.end(), static_cast<size_t>(silence), 0.0f);
      offset += silence;
    }
  }
}

int64_t vad_map_time_cs(int64_t t, const std::vector<VadMapSegment> &segs) {
  if (segs.empty()) return t;
  if (t <= segs.front().vad_start) return segs.front().orig_start;
  if (t >= segs.back().vad_end) return segs.back().orig_end;
  for (size_t i = 0; i < segs.size(); ++i) {
    const VadMapSegment &s = segs[i];
    if (t >= s.vad_start && t <= s.vad_end) {
      const int64_t vd = s.vad_end - s.vad_start;
      const int64_t od = s.orig_end - s.orig_start;
      if (vd <= 0) return s.orig_start;
      return s.orig_start + (t - s.vad_start) * od / vd;
    }
    if (i + 1 < segs.size() && t > s.vad_end && t < segs[i + 1].vad_start) {
      const int64_t mid = (s.vad_end + segs[i + 1].vad_start) / 2;
      return t <= mid ? s.orig_end : segs[i + 1].orig_start;
    }
  }
  return t;
}

VadModel::~VadModel() {
  if (ctx_ != nullptr) whisper_vad_free(ctx_);
}

int32_t VadModel::load(const std::string &path, int32_t n_threads) {
  if (ctx_ != nullptr) {
    whisper_vad_free(ctx_);
    ctx_ = nullptr;
  }
  // The magic check keeps garbage away from whisper's loader (GGML_ASSERT would abort the process).
  if (path.empty() || !vad_detail::has_ggml_magic(path)) return DV_ERR_VAD_MODEL;
  whisper_vad_context_params cparams = whisper_vad_default_context_params();
  cparams.n_threads = std::max(1, n_threads);
  cparams.use_gpu = false;
  {
    std::lock_guard<std::mutex> lock(whisper_init_mutex());
    ctx_ = whisper_vad_init_from_file_with_params(path.c_str(), cparams);
  }
  return ctx_ != nullptr ? DV_OK : DV_ERR_VAD_MODEL;
}

int32_t VadModel::detect(const float *samples, int64_t n_samples, const VadParams &params,
                         std::vector<SpeechSpan> *out) {
  out->clear();
  if (ctx_ == nullptr) return DV_ERR_VAD_MODEL;
  if (n_samples <= 0) return DV_OK;
  whisper_vad_params vp = whisper_vad_default_params();
  vp.threshold = params.threshold;
  vp.min_speech_duration_ms = params.min_speech_ms;
  vp.min_silence_duration_ms = params.min_silence_ms;
  vp.speech_pad_ms = params.speech_pad_ms;
  vp.samples_overlap = params.samples_overlap_s;
  whisper_vad_segments *segs = whisper_vad_segments_from_samples(ctx_, vp, samples, static_cast<int>(n_samples));
  if (segs == nullptr) return DV_ERR_INFERENCE;
  const int n = whisper_vad_segments_n_segments(segs);
  out->reserve(static_cast<size_t>(std::max(n, 0)));
  for (int i = 0; i < n; ++i) {
    SpeechSpan span;
    span.t0_cs = static_cast<int64_t>(std::llround(whisper_vad_segments_get_segment_t0(segs, i)));
    span.t1_cs = static_cast<int64_t>(std::llround(whisper_vad_segments_get_segment_t1(segs, i)));
    if (span.t1_cs > span.t0_cs) out->push_back(span);
  }
  whisper_vad_free_segments(segs);
  return DV_OK;
}

int32_t rms_first_speech(const SampleReadFn &read, int64_t start, int64_t end, int64_t min_speech, int64_t *out) {
  *out = -1;
  if (end <= start) return DV_OK;
  const int64_t frame = kRmsFrameSamples;
  const int64_t need_frames = std::max<int64_t>(1, (min_speech + frame - 1) / frame);
  const double thr2 = static_cast<double>(kRmsSpeechThreshold) * kRmsSpeechThreshold;
  constexpr int64_t kBlock = 10 * kSampleRate;  // multiple of the frame size
  std::vector<float> buf;
  int64_t run = 0;
  int64_t run_start = -1;
  for (int64_t pos = start; pos < end; pos += kBlock) {
    const int64_t n = std::min(kBlock, end - pos);
    const int32_t rc = read(pos, n, &buf);
    if (rc != DV_OK) return rc;
    for (int64_t f = 0; f * frame < static_cast<int64_t>(buf.size()); ++f) {
      const int64_t a = f * frame;
      const int64_t b = std::min<int64_t>(a + frame, static_cast<int64_t>(buf.size()));
      double e = 0.0;
      for (int64_t i = a; i < b; ++i) e += static_cast<double>(buf[i]) * buf[i];
      const double mean = e / static_cast<double>(b - a);
      if (mean >= thr2) {
        if (run == 0) run_start = pos + a;
        if (++run >= need_frames) {
          *out = run_start;
          return DV_OK;
        }
      } else {
        run = 0;
      }
    }
  }
  return DV_OK;
}

}  // namespace dv
