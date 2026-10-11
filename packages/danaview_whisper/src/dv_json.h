// OWNER: AI-03
//
// Minimal JSON writer for the segment (schema 1) and language payloads (ai.md §4.5). Strings are
// emitted as valid UTF-8 (invalid sequences become U+FFFD) with `"`, `\` and every control character
// < 0x20 escaped; numbers are locale independent (no printf %f/%g, which follow LC_NUMERIC).
#ifndef DV_JSON_H
#define DV_JSON_H

#include <cstdint>
#include <string>
#include <vector>

namespace dv {

class JsonWriter {
 public:
  JsonWriter &begin_object();
  JsonWriter &end_object();
  JsonWriter &begin_array();
  JsonWriter &end_array();
  /// Object key (ASCII keys only; written verbatim).
  JsonWriter &key(const char *k);
  JsonWriter &value_string(const std::string &s);
  JsonWriter &value_int(int64_t v);
  /// Fixed-point number with up to [decimals] digits after the point, trailing zeros trimmed.
  /// Non-finite values are written as 0.
  JsonWriter &value_number(double v, int decimals = 4);
  /// Appends an already serialized JSON value.
  JsonWriter &value_raw(const std::string &json);

  const std::string &str() const { return out_; }

 private:
  void before_value();
  std::string out_;
  std::vector<bool> first_;  // per open container: no element written yet
  bool after_key_ = false;
};

/// Appends the JSON string literal for [s] (quotes included) to [out].
void json_append_string(std::string *out, const std::string &s);

/// Formats [v] as fixed point with up to [decimals] digits (trailing zeros trimmed, "-0" -> "0").
std::string json_format_number(double v, int decimals);

/// malloc()ed NUL-terminated copy (freed by dv_free); nullptr on allocation failure.
char *json_dup_c(const std::string &s);

}  // namespace dv

#endif  // DV_JSON_H
