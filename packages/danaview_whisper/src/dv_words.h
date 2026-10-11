// OWNER: AI-03
//
// Token -> word assembly and UTF-8 safety (ai.md §4.6 "Word assembly").
//  * Raw token bytes are concatenated. A new word starts at a token that begins with ' ' and, for
//    no-space scripts (zh, ja, yue, th, lo, km, my, bo), after every token at which the accumulated bytes
//    end on a complete UTF-8 character.
//  * A word is emitted only once its bytes are valid UTF-8 (multi-byte characters often span BPE
//    tokens); a trailing incomplete or invalid sequence becomes U+FFFD.
//  * Pure-punctuation tokens attach to the previous word.
//  * t0/t1 are the min/max of the member token times, clamped to the segment and forced monotonic
//    (no overlaps); p is the minimum member token probability. Without token timestamps the segment span
//    is shared out by byte length.
#ifndef DV_WORDS_H
#define DV_WORDS_H

#include <cstdint>
#include <string>
#include <vector>

namespace dv {

/// One text token of a segment (special and timestamp tokens are skipped before this).
struct TokenPiece {
  std::string bytes;
  int64_t t0 = -1;  // ms, or -1 when unknown
  int64_t t1 = -1;
  float p = 0.0f;
};

/// An assembled word.
struct Word {
  std::string text;  // valid UTF-8, no leading/trailing spaces
  int64_t t0 = 0;
  int64_t t1 = 0;
  float p = 0.0f;
};

/// Whether [lang] (a whisper code) is written without spaces between words.
bool is_no_space_language(const char *lang);

/// Assembles words for a segment spanning [seg_t0, seg_t1] ms.
std::vector<Word> assemble_words(const std::vector<TokenPiece> &tokens, bool no_space_script, int64_t seg_t0,
                                 int64_t seg_t1);

/// True if [s] is entirely valid UTF-8 (no overlongs, no surrogates, <= U+10FFFF).
bool utf8_valid(const std::string &s);

/// Length of the longest prefix of [s] that ends on a complete character, given that [s] is a valid
/// sequence possibly followed by an incomplete one. Returns s.size() when [s] ends on a boundary.
size_t utf8_complete_prefix(const std::string &s);

/// Replaces each invalid byte sequence of [s] with U+FFFD.
std::string utf8_sanitize(const std::string &s);

/// True if every code point of the valid UTF-8 string [s] (ignoring spaces) is punctuation.
bool is_punctuation_only(const std::string &s);

/// Trims ASCII whitespace at both ends.
std::string trim_ascii_space(const std::string &s);

}  // namespace dv

#endif  // DV_WORDS_H
