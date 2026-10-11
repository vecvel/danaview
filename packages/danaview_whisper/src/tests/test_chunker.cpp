// OWNER: AI-03
//
// RMS chunk planning (ai.md §4.6 "Chunk planning").
#include <cmath>

#include "dv_chunker.h"
#include "dv_test.h"
#include "dv_test_support.h"
#include "dv_wav.h"

using namespace dvt_support;

namespace {

constexpr int64_t kSr = 16000;

struct MemAudio {
  std::vector<float> s;
  int64_t reads = 0;
  int64_t read_samples = 0;
  dv::SampleReadFn fn() {
    return [this](int64_t start, int64_t count, std::vector<float> *out) {
      ++reads;
      out->clear();
      if (start < 0) start = 0;
      const int64_t end = std::min<int64_t>(static_cast<int64_t>(s.size()), start + count);
      if (end > start) out->assign(s.begin() + start, s.begin() + end);
      read_samples += end - start;
      return static_cast<int32_t>(DV_OK);
    };
  }
};

// Loud noise everywhere except 600 ms quiet gaps centred on [gaps_s].
MemAudio noisy_with_gaps(double seconds, const std::vector<double> &gaps_s) {
  std::vector<int16_t> pcm;
  append_noise(&pcm, seconds, 0.5, 1234);
  MemAudio a;
  a.s.resize(pcm.size());
  for (size_t i = 0; i < pcm.size(); ++i) a.s[i] = pcm[i] / 32768.0f;
  for (double g : gaps_s) {
    const int64_t c = static_cast<int64_t>(g * kSr);
    for (int64_t i = c - kSr * 3 / 10; i < c + kSr * 3 / 10; ++i) {
      if (i >= 0 && i < static_cast<int64_t>(a.s.size())) a.s[static_cast<size_t>(i)] = 0.0f;
    }
  }
  return a;
}

void expect_contiguous(const std::vector<dv::SampleRange> &chunks, int64_t start, int64_t end) {
  ASSERT_FALSE(chunks.empty());
  EXPECT_EQ(chunks.front().start, start);
  EXPECT_EQ(chunks.back().end, end);
  for (size_t i = 1; i < chunks.size(); ++i) EXPECT_EQ(chunks[i].start, chunks[i - 1].end);
  for (const auto &c : chunks) EXPECT_GT(c.length(), 0);
}

dv::ChunkParams params_s(double target, double search, double min) {
  dv::ChunkParams p;
  p.target = static_cast<int64_t>(target * kSr);
  p.search = static_cast<int64_t>(search * kSr);
  p.min = static_cast<int64_t>(min * kSr);
  return p;
}

}  // namespace

TEST(Chunker, cuts_at_the_quietest_window_near_each_target) {
  // Gaps 7 s before and 3 s after the 60 s targets; the planner must find them, not cut in noise.
  MemAudio a = noisy_with_gaps(200.0, {53.0, 116.0, 172.0});
  std::vector<dv::SampleRange> chunks;
  ASSERT_EQ(dv::plan_chunks(0, static_cast<int64_t>(a.s.size()), params_s(60, 15, 10), a.fn(), &chunks), DV_OK);
  expect_contiguous(chunks, 0, static_cast<int64_t>(a.s.size()));
  ASSERT_EQ(chunks.size(), static_cast<size_t>(4));
  const double expect[] = {53.0, 116.0, 172.0};
  for (int k = 0; k < 3; ++k) {
    const double cut = static_cast<double>(chunks[static_cast<size_t>(k)].end) / kSr;
    EXPECT_LT(std::fabs(cut - expect[k]), 0.11);  // inside the 600 ms gap, centred within 100 ms
  }
  // Only the search windows are read (not the whole file).
  EXPECT_LT(a.read_samples, static_cast<int64_t>(a.s.size()) / 2);
}

TEST(Chunker, resumed_planning_from_a_boundary_reproduces_the_same_chunks) {
  MemAudio a = noisy_with_gaps(400.0, {170.0, 355.0});
  std::vector<dv::SampleRange> full, resumed;
  const int64_t end = static_cast<int64_t>(a.s.size());
  ASSERT_EQ(dv::plan_chunks(0, end, params_s(180, 15, 10), a.fn(), &full), DV_OK);
  ASSERT_GE(full.size(), static_cast<size_t>(2));
  ASSERT_EQ(dv::plan_chunks(full[1].start, end, params_s(180, 15, 10), a.fn(), &resumed), DV_OK);
  ASSERT_EQ(resumed.size(), full.size() - 1);
  for (size_t i = 0; i < resumed.size(); ++i) {
    EXPECT_EQ(resumed[i].start, full[i + 1].start);
    EXPECT_EQ(resumed[i].end, full[i + 1].end);
  }
}

TEST(Chunker, short_tail_merges_into_the_previous_chunk) {
  MemAudio a = noisy_with_gaps(65.0, {});
  std::vector<dv::SampleRange> chunks;
  ASSERT_EQ(dv::plan_chunks(0, static_cast<int64_t>(a.s.size()), params_s(60, 15, 10), a.fn(), &chunks), DV_OK);
  // Every cut leaves >= chunk_min on both sides, so no chunk (in particular the tail) is shorter.
  expect_contiguous(chunks, 0, static_cast<int64_t>(a.s.size()));
  for (size_t i = 0; i + 1 < chunks.size(); ++i) EXPECT_GE(chunks[i].length(), 10 * kSr);
  EXPECT_GE(chunks.back().length(), 10 * kSr);
}

TEST(Chunker, single_chunk_when_shorter_than_target_and_empty_range) {
  MemAudio a = noisy_with_gaps(30.0, {});
  std::vector<dv::SampleRange> chunks;
  ASSERT_EQ(dv::plan_chunks(1000, 30 * kSr, params_s(180, 15, 10), a.fn(), &chunks), DV_OK);
  ASSERT_EQ(chunks.size(), static_cast<size_t>(1));
  EXPECT_EQ(chunks[0].start, 1000);
  EXPECT_EQ(chunks[0].end, 30 * kSr);
  ASSERT_EQ(dv::plan_chunks(500, 500, params_s(180, 15, 10), a.fn(), &chunks), DV_OK);
  EXPECT_TRUE(chunks.empty());
}

TEST(Chunker, zero_search_cuts_exactly_at_targets) {
  MemAudio a = noisy_with_gaps(100.0, {});
  std::vector<dv::SampleRange> chunks;
  ASSERT_EQ(dv::plan_chunks(0, 100 * kSr, params_s(30, 0, 1), a.fn(), &chunks), DV_OK);
  expect_contiguous(chunks, 0, 100 * kSr);
  ASSERT_EQ(chunks.size(), static_cast<size_t>(4));
  EXPECT_EQ(chunks[0].end, 30 * kSr);
  EXPECT_EQ(chunks[1].end, 60 * kSr);
  EXPECT_EQ(chunks[2].end, 90 * kSr);
}

TEST(Chunker, read_errors_propagate) {
  dv::SampleReadFn failing = [](int64_t, int64_t, std::vector<float> *) { return static_cast<int32_t>(DV_ERR_IO); };
  std::vector<dv::SampleRange> chunks;
  EXPECT_EQ(dv::plan_chunks(0, 400 * kSr, params_s(180, 15, 10), failing, &chunks), DV_ERR_IO);
}
