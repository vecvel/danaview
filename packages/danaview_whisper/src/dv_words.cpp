// OWNER: AI-03
//
// Word assembly and UTF-8 helpers (see dv_words.h).
#include "dv_words.h"

#include <algorithm>
#include <cstring>

namespace dv {
namespace words_detail {

enum DecodeResult { kValid = 1, kIncomplete = 0, kInvalid = -1 };

// Decodes the code point at s[i]. On kValid sets *cp and *len; on kInvalid *len = 1.
DecodeResult decode_cp(const std::string &s, size_t i, uint32_t *cp, size_t *len) {
  const auto b0 = static_cast<unsigned char>(s[i]);
  *len = 1;
  if (b0 < 0x80) {
    *cp = b0;
    return kValid;
  }
  size_t need;
  uint32_t min_cp;
  uint32_t value;
  if (b0 >= 0xC2 && b0 <= 0xDF) {
    need = 1;
    min_cp = 0x80;
    value = b0 & 0x1F;
  } else if (b0 >= 0xE0 && b0 <= 0xEF) {
    need = 2;
    min_cp = 0x800;
    value = b0 & 0x0F;
  } else if (b0 >= 0xF0 && b0 <= 0xF4) {
    need = 3;
    min_cp = 0x10000;
    value = b0 & 0x07;
  } else {
    return kInvalid;
  }
  for (size_t k = 1; k <= need; ++k) {
    if (i + k >= s.size()) {
      // Truncated: incomplete only if every byte present so far could still start a valid sequence.
      if (k >= 2) {
        const auto b1 = static_cast<unsigned char>(s[i + 1]);
        if ((b0 == 0xE0 && b1 < 0xA0) || (b0 == 0xED && b1 > 0x9F) || (b0 == 0xF0 && b1 < 0x90) ||
            (b0 == 0xF4 && b1 > 0x8F)) {
          return kInvalid;
        }
      }
      return kIncomplete;
    }
    const auto bk = static_cast<unsigned char>(s[i + k]);
    if ((bk & 0xC0) != 0x80) return kInvalid;
    value = (value << 6) | (bk & 0x3F);
  }
  if (value < min_cp || value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF)) return kInvalid;
  *cp = value;
  *len = need + 1;
  return kValid;
}

bool is_punct_cp(uint32_t c) {
  if ((c >= 0x21 && c <= 0x2F) || (c >= 0x3A && c <= 0x40) || (c >= 0x5B && c <= 0x60) || (c >= 0x7B && c <= 0x7E)) {
    return true;
  }
  switch (c) {
    case 0xA1: case 0xA7: case 0xAB: case 0xB6: case 0xB7: case 0xBB: case 0xBF:
    case 0x060C: case 0x061B: case 0x061F: case 0x06D4: case 0x0964: case 0x0965: case 0x30FB:
      return true;
    default:
      break;
  }
  return (c >= 0x2010 && c <= 0x2027) || (c >= 0x2030 && c <= 0x205E) || (c >= 0x3000 && c <= 0x3003) ||
         (c >= 0x3008 && c <= 0x3011) || (c >= 0x3014 && c <= 0x301F) || (c >= 0xFF01 && c <= 0xFF0F) ||
         (c >= 0xFF1A && c <= 0xFF20) || (c >= 0xFF3B && c <= 0xFF40) || (c >= 0xFF5B && c <= 0xFF65);
}

struct Builder {
  std::string bytes;
  int64_t t0 = -1;
  int64_t t1 = -1;
  float p = 1.0f;
  bool has_token = false;
  bool timed = true;

  void add(const std::string &b, const TokenPiece &tok) {
    bytes += b;
    merge(tok);
  }
  void merge(const TokenPiece &tok) {
    if (tok.t0 < 0 || tok.t1 < 0) {
      timed = false;
    } else {
      t0 = t0 < 0 ? tok.t0 : std::min(t0, tok.t0);
      t1 = std::max(t1, tok.t1);
    }
    p = has_token ? std::min(p, tok.p) : tok.p;
    has_token = true;
  }
};

struct RawWord {
  std::string text;
  int64_t t0, t1;
  float p;
  bool timed;
};

void flush(Builder *cur, std::vector<RawWord> *out) {
  if (cur->bytes.empty()) {
    *cur = Builder();
    return;
  }
  std::string text = trim_ascii_space(utf8_sanitize(cur->bytes));
  if (!text.empty()) out->push_back({text, cur->t0, cur->t1, cur->p, cur->timed && cur->t0 >= 0});
  *cur = Builder();
}

}  // namespace words_detail

bool is_no_space_language(const char *lang) {
  if (lang == nullptr) return false;
  static const char *kNoSpace[] = {"zh", "ja", "yue", "th", "lo", "km", "my", "bo"};
  for (const char *code : kNoSpace) {
    if (std::strcmp(lang, code) == 0) return true;
  }
  return false;
}

bool utf8_valid(const std::string &s) {
  using namespace words_detail;
  size_t i = 0;
  while (i < s.size()) {
    uint32_t cp;
    size_t len;
    if (decode_cp(s, i, &cp, &len) != kValid) return false;
    i += len;
  }
  return true;
}

size_t utf8_complete_prefix(const std::string &s) {
  using namespace words_detail;
  size_t i = 0;
  while (i < s.size()) {
    uint32_t cp;
    size_t len;
    const DecodeResult r = decode_cp(s, i, &cp, &len);
    if (r == kIncomplete) return i;
    i += len;  // invalid bytes count as complete: no later byte can repair them
  }
  return s.size();
}

std::string utf8_sanitize(const std::string &s) {
  using namespace words_detail;
  std::string out;
  out.reserve(s.size());
  size_t i = 0;
  while (i < s.size()) {
    uint32_t cp;
    size_t len;
    const DecodeResult r = decode_cp(s, i, &cp, &len);
    if (r == kValid) {
      out.append(s, i, len);
      i += len;
    } else if (r == kIncomplete) {
      out += "\xEF\xBF\xBD";  // trailing partial character
      break;
    } else {
      out += "\xEF\xBF\xBD";
      i += 1;
    }
  }
  return out;
}

bool is_punctuation_only(const std::string &s) {
  using namespace words_detail;
  bool any = false;
  size_t i = 0;
  while (i < s.size()) {
    uint32_t cp;
    size_t len;
    if (decode_cp(s, i, &cp, &len) != kValid) return false;
    if (cp != ' ') {
      if (!is_punct_cp(cp)) return false;
      any = true;
    }
    i += len;
  }
  return any;
}

std::string trim_ascii_space(const std::string &s) {
  size_t b = 0;
  size_t e = s.size();
  auto space = [](char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v'; };
  while (b < e && space(s[b])) ++b;
  while (e > b && space(s[e - 1])) --e;
  return s.substr(b, e - b);
}

std::vector<Word> assemble_words(const std::vector<TokenPiece> &tokens, bool no_space_script, int64_t seg_t0,
                                 int64_t seg_t1) {
  using namespace words_detail;
  if (seg_t1 < seg_t0) seg_t1 = seg_t0;
  std::vector<RawWord> raw;
  Builder cur;
  for (const TokenPiece &tok : tokens) {
    if (tok.bytes.empty()) continue;
    const bool starts_space = tok.bytes[0] == ' ';
    const std::string stripped = trim_ascii_space(tok.bytes);
    if (!stripped.empty() && utf8_valid(stripped) && is_punctuation_only(stripped) &&
        (!cur.bytes.empty() || !raw.empty())) {
      if (!cur.bytes.empty()) {
        cur.add(stripped, tok);
      } else {
        RawWord &prev = raw.back();
        prev.text += stripped;
        if (tok.t0 >= 0 && tok.t1 >= 0 && prev.timed) {
          prev.t0 = std::min(prev.t0, tok.t0);
          prev.t1 = std::max(prev.t1, tok.t1);
        } else if (tok.t0 < 0 || tok.t1 < 0) {
          prev.timed = false;
        }
        prev.p = std::min(prev.p, tok.p);
      }
      continue;
    }
    if (!cur.bytes.empty() && (starts_space || (no_space_script && utf8_complete_prefix(cur.bytes) == cur.bytes.size()))) {
      flush(&cur, &raw);
    }
    cur.add(tok.bytes, tok);
  }
  flush(&cur, &raw);

  std::vector<Word> words;
  words.reserve(raw.size());
  const bool all_timed = std::all_of(raw.begin(), raw.end(), [](const RawWord &w) { return w.timed; });
  if (!all_timed) {
    // Share the segment span by byte length.
    size_t total = 0;
    for (const RawWord &w : raw) total += w.text.size();
    const int64_t span = seg_t1 - seg_t0;
    size_t acc = 0;
    for (const RawWord &w : raw) {
      const int64_t a = total == 0 ? seg_t0 : seg_t0 + span * static_cast<int64_t>(acc) / static_cast<int64_t>(total);
      acc += w.text.size();
      const int64_t b = total == 0 ? seg_t1 : seg_t0 + span * static_cast<int64_t>(acc) / static_cast<int64_t>(total);
      words.push_back({w.text, a, b, w.p});
    }
  } else {
    for (const RawWord &w : raw) words.push_back({w.text, w.t0, w.t1, w.p});
  }
  int64_t prev_t1 = seg_t0;
  for (Word &w : words) {
    w.t0 = std::min(std::max(w.t0, prev_t1), seg_t1);
    w.t1 = std::min(std::max(w.t1, w.t0), seg_t1);
    prev_t1 = w.t1;
  }
  return words;
}

}  // namespace dv
