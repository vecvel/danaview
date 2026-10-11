// OWNER: AI-03
//
// Word assembly and UTF-8 safety (ai.md §4.6 "Word assembly", §16.3 items 2 and 9).
#include "dv_test.h"
#include "dv_test_support.h"
#include "dv_words.h"

namespace {

dv::TokenPiece tok(const std::string &bytes, int64_t t0, int64_t t1, float p = 0.9f) {
  dv::TokenPiece t;
  t.bytes = bytes;
  t.t0 = t0;
  t.t1 = t1;
  t.p = p;
  return t;
}

void expect_monotonic_inside(const std::vector<dv::Word> &words, int64_t s0, int64_t s1) {
  int64_t prev = s0;
  for (const dv::Word &w : words) {
    EXPECT_LE(prev, w.t0);
    EXPECT_LE(w.t0, w.t1);
    EXPECT_LE(s0, w.t0);
    EXPECT_LE(w.t1, s1);
    EXPECT_TRUE(dv::utf8_valid(w.text));
    EXPECT_FALSE(w.text.empty());
    prev = w.t1;
  }
}

}  // namespace

TEST(Words, space_delimited_with_punctuation_attached) {
  const auto words = dv::assemble_words(
      {tok(" Hello", 0, 300, 0.9f), tok(",", 300, 320, 0.5f), tok(" wor", 400, 500), tok("ld", 500, 640), tok("!", 640, 660)},
      false, 0, 1000);
  ASSERT_EQ(words.size(), static_cast<size_t>(2));
  EXPECT_EQ(words[0].text, std::string("Hello,"));
  EXPECT_EQ(words[1].text, std::string("world!"));
  EXPECT_EQ(words[0].t0, 0);
  EXPECT_EQ(words[0].t1, 320);
  EXPECT_EQ(words[1].t0, 400);
  EXPECT_EQ(words[1].t1, 660);
  EXPECT_TRUE(words[0].p < 0.51f && words[0].p > 0.49f);  // minimum member probability
  expect_monotonic_inside(words, 0, 1000);
}

TEST(Words, cjk_tokens_splitting_characters_yield_complete_characters_only) {
  // 日 = E6 97 A5, 本 = E6 9C AC, 語 = E8 AA 9E; BPE splits the first two across three tokens.
  const auto words = dv::assemble_words({tok("\xE6\x97", 0, 100), tok("\xA5\xE6", 100, 200), tok("\x9C\xAC", 200, 300),
                                         tok("\xE8\xAA\x9E", 300, 400), tok("\xE3\x80\x82", 400, 420)},
                                        true, 0, 500);
  ASSERT_EQ(words.size(), static_cast<size_t>(2));
  EXPECT_EQ(words[0].text, std::string("\xE6\x97\xA5\xE6\x9C\xAC"));  // 日本 (shared a token)
  EXPECT_EQ(words[1].text, std::string("\xE8\xAA\x9E\xE3\x80\x82"));  // 語。 (punctuation attached)
  for (const dv::Word &w : words) EXPECT_EQ(dv::utf8_complete_prefix(w.text), w.text.size());
  expect_monotonic_inside(words, 0, 500);
}

TEST(Words, cjk_one_character_per_token_gives_one_word_each) {
  const auto words = dv::assemble_words({tok("\xE4\xBD\xA0", 0, 100), tok("\xE5\xA5\xBD", 100, 200)}, true, 0, 300);
  ASSERT_EQ(words.size(), static_cast<size_t>(2));
  EXPECT_EQ(words[0].text, std::string("\xE4\xBD\xA0"));
  EXPECT_EQ(words[1].text, std::string("\xE5\xA5\xBD"));
}

TEST(Words, trailing_incomplete_sequence_becomes_replacement_char) {
  const auto words = dv::assemble_words({tok(" caf", 0, 100), tok("\xC3", 100, 200)}, false, 0, 300);
  ASSERT_EQ(words.size(), static_cast<size_t>(1));
  EXPECT_EQ(words[0].text, std::string("caf\xEF\xBF\xBD"));
  EXPECT_TRUE(dv::utf8_valid(words[0].text));
}

TEST(Words, untimed_tokens_share_the_segment_by_length) {
  const auto words = dv::assemble_words({tok(" ab", -1, -1), tok(" cdef", -1, -1)}, false, 1000, 1600);
  ASSERT_EQ(words.size(), static_cast<size_t>(2));
  EXPECT_EQ(words[0].t0, 1000);
  EXPECT_EQ(words[0].t1, 1200);  // 2 of 6 bytes
  EXPECT_EQ(words[1].t0, 1200);
  EXPECT_EQ(words[1].t1, 1600);
}

TEST(Words, overlapping_and_out_of_segment_times_are_clamped_monotonic) {
  const auto words =
      dv::assemble_words({tok(" a", 50, 300), tok(" b", 200, 250), tok(" c", 900, 2000)}, false, 100, 1000);
  ASSERT_EQ(words.size(), static_cast<size_t>(3));
  EXPECT_EQ(words[0].t0, 100);
  EXPECT_EQ(words[1].t0, 300);
  EXPECT_EQ(words[1].t1, 300);
  EXPECT_EQ(words[2].t1, 1000);
  expect_monotonic_inside(words, 100, 1000);
}

TEST(Words, utf8_helpers) {
  EXPECT_TRUE(dv::utf8_valid("plain"));
  EXPECT_TRUE(dv::utf8_valid("\xF0\x9F\x98\x80"));
  EXPECT_FALSE(dv::utf8_valid("\xC0\xAF"));          // overlong
  EXPECT_FALSE(dv::utf8_valid("\xED\xA0\x80"));      // surrogate
  EXPECT_FALSE(dv::utf8_valid("\xF4\x90\x80\x80"));  // > U+10FFFF
  EXPECT_EQ(dv::utf8_complete_prefix("ab\xE6\x97"), static_cast<size_t>(2));
  EXPECT_EQ(dv::utf8_sanitize("a\xFF" "b"), std::string("a\xEF\xBF\xBD" "b"));
  EXPECT_TRUE(dv::is_punctuation_only(" ,!"));
  EXPECT_FALSE(dv::is_punctuation_only("a,"));
  EXPECT_TRUE(dv::is_no_space_language("ja"));
  EXPECT_FALSE(dv::is_no_space_language("en"));
  EXPECT_EQ(dv::trim_ascii_space("  x y \n"), std::string("x y"));
}
