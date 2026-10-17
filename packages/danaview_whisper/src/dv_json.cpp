// OWNER: AI-03
//
// JSON writer (see dv_json.h).
#include "dv_json.h"

#include <cmath>
#include <cstdlib>
#include <cstring>

#include "dv_words.h"

namespace dv {

void json_append_string(std::string *out, const std::string &raw) {
  static const char kHex[] = "0123456789abcdef";
  const std::string s = utf8_valid(raw) ? raw : utf8_sanitize(raw);
  out->push_back('"');
  for (char ch : s) {
    const auto c = static_cast<unsigned char>(ch);
    switch (c) {
      case '"': *out += "\\\""; break;
      case '\\': *out += "\\\\"; break;
      case '\b': *out += "\\b"; break;
      case '\f': *out += "\\f"; break;
      case '\n': *out += "\\n"; break;
      case '\r': *out += "\\r"; break;
      case '\t': *out += "\\t"; break;
      default:
        if (c < 0x20) {
          *out += "\\u00";
          out->push_back(kHex[c >> 4]);
          out->push_back(kHex[c & 0xF]);
        } else {
          out->push_back(ch);
        }
    }
  }
  out->push_back('"');
}

std::string json_format_number(double v, int decimals) {
  if (!std::isfinite(v)) return "0";
  if (decimals < 0) decimals = 0;
  if (decimals > 9) decimals = 9;
  int64_t scale = 1;
  for (int i = 0; i < decimals; ++i) scale *= 10;
  // Keep the scaled value inside int64 (values here are probabilities and log-probabilities).
  const double limit = 9.0e18 / static_cast<double>(scale);
  if (v > limit) v = limit;
  if (v < -limit) v = -limit;
  const long long scaled = std::llround(v * static_cast<double>(scale));
  if (scaled == 0) return "0";
  const bool neg = scaled < 0;
  const unsigned long long mag = neg ? static_cast<unsigned long long>(-(scaled + 1)) + 1ULL
                                     : static_cast<unsigned long long>(scaled);
  const unsigned long long ip = mag / static_cast<unsigned long long>(scale);
  unsigned long long fp = mag % static_cast<unsigned long long>(scale);
  std::string out = neg ? "-" : "";
  out += std::to_string(ip);
  if (fp != 0) {
    std::string frac(static_cast<size_t>(decimals), '0');
    for (int i = decimals - 1; i >= 0; --i) {
      frac[static_cast<size_t>(i)] = static_cast<char>('0' + fp % 10);
      fp /= 10;
    }
    while (!frac.empty() && frac.back() == '0') frac.pop_back();
    out += '.';
    out += frac;
  }
  return out;
}

char *json_dup_c(const std::string &s) {
  char *p = static_cast<char *>(std::malloc(s.size() + 1));
  if (p == nullptr) return nullptr;
  std::memcpy(p, s.data(), s.size());
  p[s.size()] = '\0';
  return p;
}

void JsonWriter::before_value() {
  if (after_key_) {
    after_key_ = false;
    return;
  }
  if (!first_.empty()) {
    if (!first_.back()) out_.push_back(',');
    first_.back() = false;
  }
}

JsonWriter &JsonWriter::begin_object() {
  before_value();
  out_.push_back('{');
  first_.push_back(true);
  return *this;
}

JsonWriter &JsonWriter::end_object() {
  out_.push_back('}');
  if (!first_.empty()) first_.pop_back();
  return *this;
}

JsonWriter &JsonWriter::begin_array() {
  before_value();
  out_.push_back('[');
  first_.push_back(true);
  return *this;
}

JsonWriter &JsonWriter::end_array() {
  out_.push_back(']');
  if (!first_.empty()) first_.pop_back();
  return *this;
}

JsonWriter &JsonWriter::key(const char *k) {
  before_value();
  out_.push_back('"');
  out_ += k;
  out_ += "\":";
  after_key_ = true;
  return *this;
}

JsonWriter &JsonWriter::value_string(const std::string &s) {
  before_value();
  json_append_string(&out_, s);
  return *this;
}

JsonWriter &JsonWriter::value_int(int64_t v) {
  before_value();
  out_ += std::to_string(v);
  return *this;
}

JsonWriter &JsonWriter::value_number(double v, int decimals) {
  before_value();
  out_ += json_format_number(v, decimals);
  return *this;
}

JsonWriter &JsonWriter::value_raw(const std::string &json) {
  before_value();
  out_ += json;
  return *this;
}

}  // namespace dv
