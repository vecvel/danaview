// OWNER: AI-03
//
// Chunk planning (ai.md §4.6): boundaries come from 20 ms RMS frames. For a target T past the chunk
// start, the quietest 400 ms window whose centre lies in [T - search, T + min(search, 5 s)] is found and
// the cut is placed at its centre. A tail shorter than the minimum merges into the previous chunk. Frames
// are aligned to absolute sample positions and each cut depends only on the previous one, so a job
// resumed at a boundary re-plans identical chunks. Only the search windows are read (about 11% of the
// audio for 180 s chunks).
#ifndef DV_CHUNKER_H
#define DV_CHUNKER_H

#include <cstdint>
#include <functional>
#include <vector>

namespace dv {

/// A half-open sample range [start, end).
struct SampleRange {
  int64_t start = 0;
  int64_t end = 0;
  int64_t length() const { return end - start; }
};

/// Planning parameters in samples.
struct ChunkParams {
  int64_t target = 0;  // chunk_target_ms
  int64_t search = 0;  // chunk_search_ms (backwards reach; forwards reach is min(search, 5 s))
  int64_t min = 0;     // chunk_min_ms
};

constexpr int64_t kRmsFrameSamples = 320;   // 20 ms
constexpr int64_t kQuietWindowFrames = 20;  // 400 ms
constexpr int64_t kForwardReachCapSamples = 5 * 16000;

/// Reads samples [start, start + count) into the vector; returns DV_OK or an error status.
using SampleReadFn = std::function<int32_t(int64_t start, int64_t count, std::vector<float> *out)>;

/// Plans chunks over [start, end). Returns DV_OK (with at least one chunk when end > start) or the
/// read error.
int32_t plan_chunks(int64_t start, int64_t end, const ChunkParams &params, const SampleReadFn &read,
                    std::vector<SampleRange> *out);

/// The quietest 400 ms window whose centre lies in [lo, hi] (frame aligned); returns its centre.
/// Ties prefer the centre closest to [target], then the earliest.
int32_t find_quiet_cut(int64_t lo, int64_t hi, int64_t target, int64_t data_start, int64_t data_end,
                       const SampleReadFn &read, int64_t *cut);

}  // namespace dv

#endif  // DV_CHUNKER_H
