// OWNER: AI-03
//
// RMS-based chunk planning (see dv_chunker.h).
#include "dv_chunker.h"

#include <algorithm>
#include <cmath>

#include "dv_whisper.h"

namespace dv {
namespace chunker_detail {

int64_t floor_to_frame(int64_t s) {
  return (s >= 0 ? s / kRmsFrameSamples : -((-s + kRmsFrameSamples - 1) / kRmsFrameSamples)) * kRmsFrameSamples;
}
int64_t ceil_to_frame(int64_t s) { return -floor_to_frame(-s); }

}  // namespace chunker_detail

int32_t find_quiet_cut(int64_t lo, int64_t hi, int64_t target, int64_t data_start, int64_t data_end,
                       const SampleReadFn &read, int64_t *cut) {
  using namespace chunker_detail;
  *cut = -1;
  const int64_t c0 = ceil_to_frame(lo);
  const int64_t c1 = floor_to_frame(hi);
  if (c0 > c1) return DV_OK;
  const int64_t half = (kQuietWindowFrames / 2) * kRmsFrameSamples;  // 200 ms
  const int64_t region_start = std::max(c0 - half, data_start);
  const int64_t region_end = std::min(c1 + half, data_end);
  std::vector<float> samples;
  if (region_end > region_start) {
    const int32_t rc = read(region_start, region_end - region_start, &samples);
    if (rc != DV_OK) return rc;
  }
  // Energy per absolute frame index in [f0, f1).
  const int64_t f0 = (c0 - half) / kRmsFrameSamples;
  const int64_t f1 = (c1 + half) / kRmsFrameSamples;
  std::vector<double> energy(static_cast<size_t>(f1 - f0), 0.0);
  for (size_t i = 0; i < samples.size(); ++i) {
    const int64_t abs = region_start + static_cast<int64_t>(i);
    const int64_t f = abs / kRmsFrameSamples - f0;
    if (f < 0 || f >= static_cast<int64_t>(energy.size())) continue;
    const double v = samples[i];
    energy[static_cast<size_t>(f)] += v * v;
  }
  // Sliding sums of kQuietWindowFrames frames; candidate centre c has its window start at frame
  // c / frame - kQuietWindowFrames / 2.
  double best = 0.0;
  int64_t best_c = -1;
  double window = 0.0;
  const int64_t first_c_frame = c0 / kRmsFrameSamples;
  for (int64_t k = 0; k < kQuietWindowFrames && k < static_cast<int64_t>(energy.size()); ++k) window += energy[k];
  for (int64_t c = c0; c <= c1; c += kRmsFrameSamples) {
    const int64_t w0 = c / kRmsFrameSamples - first_c_frame;  // window start offset into energy[]
    if (c > c0) {
      window -= energy[static_cast<size_t>(w0 - 1)];
      const int64_t add = w0 + kQuietWindowFrames - 1;
      if (add < static_cast<int64_t>(energy.size())) window += energy[static_cast<size_t>(add)];
    }
    const double e = std::max(window, 0.0);
    const bool better = best_c < 0 || e < best - 1e-12 ||
                        (std::fabs(e - best) <= 1e-12 && std::llabs(c - target) < std::llabs(best_c - target));
    if (better) {
      best = e;
      best_c = c;
    }
  }
  *cut = best_c;
  return DV_OK;
}

int32_t plan_chunks(int64_t start, int64_t end, const ChunkParams &params, const SampleReadFn &read,
                    std::vector<SampleRange> *out) {
  out->clear();
  if (end <= start) return DV_OK;
  const int64_t target = std::max<int64_t>(params.target, kRmsFrameSamples);
  const int64_t search = std::max<int64_t>(params.search, 0);
  const int64_t min_len = std::max<int64_t>(params.min, 0);
  const int64_t forward = std::min(search, kForwardReachCapSamples);
  int64_t pos = start;
  while (true) {
    if (end - pos <= target) {
      out->push_back({pos, end});
      return DV_OK;
    }
    const int64_t t = pos + target;
    const int64_t lo = std::max(t - search, pos + std::max(min_len, kRmsFrameSamples));
    const int64_t hi = std::min(t + forward, end - min_len);
    int64_t cut = -1;
    if (lo <= hi) {
      const int32_t rc = find_quiet_cut(lo, hi, t, start, end, read, &cut);
      if (rc != DV_OK) return rc;
    }
    if (cut < 0 && t > pos && end - t >= min_len) {
      cut = t;  // no frame-aligned candidate in the window (search 0): cut at the target itself
    }
    if (cut <= pos || cut >= end) {
      // No admissible cut: the tail is too short to stand alone, so it merges into this chunk.
      out->push_back({pos, end});
      return DV_OK;
    }
    out->push_back({pos, cut});
    pos = cut;
  }
}

}  // namespace dv
