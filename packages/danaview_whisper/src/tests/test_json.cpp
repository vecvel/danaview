// OWNER: AI-03
//
// JSON writer: escaping fuzz (ai.md §16.3 item 8), numbers, structure.
#include <clocale>
#include <cmath>
#include <cstdint>

#include "dv_json.h"
#include "dv_test.h"
#include "dv_test_support.h"
#include "dv_words.h"

using namespace dvt_support;

namespace {

uint32_t xorshift(uint32_t *s) {
  uint32_t x = *s;
  x ^= x << 13;
  x ^= x >> 17;
  x ^= x << 5;
  *s = x;
  return x;
}

}  // namespace

TEST(Json, escaping_fuzz_random_bytes_always_valid_json) {
  uint32_t seed = 0xC0FFEEu;
  for (int iter = 0; iter < 20000; ++iter) {
    const size_t len = xorshift(&seed) % 48;
    std::string raw;
    for (size_t i = 0; i < len; ++i) {
      // Bias towards the interesting bytes: controls, quotes, backslashes, UTF-8 lead/continuation bytes.
      const uint32_t r = xorshift(&seed);
      static const unsigned char kSpecial[] = {'"', '\\', '\n', '\r', '\t', 0x00, 0x01, 0x1F, 0x7F,
                                               0x80, 0xBF, 0xC0, 0xC2, 0xE0, 0xED, 0xF0, 0xF4, 0xF5, 0xFF};
      raw.push_back(static_cast<char>((r & 3) == 0 ? kSpecial[(r >> 2) % sizeof(kSpecial)] : (r >> 8) & 0xFF));
    }
    std::string out;
    dv::json_append_string(&out, raw);
    Json parsed;
    std::string err;
    ASSERT_TRUE(json_parse(out, &parsed, &err));
    ASSERT_EQ(static_cast<int>(parsed.type), static_cast<int>(Json::kString));
    // Valid UTF-8 survives byte for byte; anything else is the sanitized form.
    const std::string expect = dv::utf8_valid(raw) ? raw : dv::utf8_sanitize(raw);
    ASSERT_EQ(parsed.str, expect);
    ASSERT_TRUE(dv::utf8_valid(parsed.str));
  }
}

TEST(Json, escapes_quotes_backslashes_and_controls) {
  std::string out;
  dv::json_append_string(&out, std::string("a\"b\\c\n\x01\x1f", 8));
  EXPECT_EQ(out, std::string("\"a\\\"b\\\\c\\n\\u0001\\u001f\""));
}

TEST(Json, numbers_are_locale_independent_fixed_point) {
  const char *old = std::setlocale(LC_NUMERIC, nullptr);
  const std::string saved = old != nullptr ? old : "C";
  // A comma-decimal locale when the host has one; the formatter must not care.
  if (std::setlocale(LC_NUMERIC, "de_DE.UTF-8") == nullptr) std::setlocale(LC_NUMERIC, "fr_FR.UTF-8");
  EXPECT_EQ(dv::json_format_number(0.5, 4), std::string("0.5"));
  EXPECT_EQ(dv::json_format_number(-0.21, 4), std::string("-0.21"));
  EXPECT_EQ(dv::json_format_number(0.98766, 4), std::string("0.9877"));
  EXPECT_EQ(dv::json_format_number(-0.00001, 4), std::string("0"));
  EXPECT_EQ(dv::json_format_number(12.0, 4), std::string("12"));
  EXPECT_EQ(dv::json_format_number(NAN, 4), std::string("0"));
  EXPECT_EQ(dv::json_format_number(INFINITY, 4), std::string("0"));
  EXPECT_EQ(dv::json_format_number(-3.25, 1), std::string("-3.3"));  // half away from zero
  std::setlocale(LC_NUMERIC, saved.c_str());
}

TEST(Json, writer_builds_nested_valid_documents) {
  dv::JsonWriter w;
  w.begin_object()
      .key("lang").begin_array()
      .begin_object().key("code").value_string("de").key("p").value_number(0.912345).end_object()
      .begin_object().key("code").value_string("en").key("p").value_number(0.05).end_object()
      .end_array()
      .key("speechStartMs").value_int(4120)
      .key("empty").begin_array().end_array()
      .key("raw").value_raw("{\"x\":1}")
      .end_object();
  EXPECT_EQ(w.str(), std::string("{\"lang\":[{\"code\":\"de\",\"p\":0.9123},{\"code\":\"en\",\"p\":0.05}],"
                                 "\"speechStartMs\":4120,\"empty\":[],\"raw\":{\"x\":1}}"));
  Json parsed;
  ASSERT_TRUE(json_parse(w.str(), &parsed));
  EXPECT_EQ(parsed.number("speechStartMs"), 4120.0);
}

TEST(Json, dup_c_round_trips) {
  char *p = dv::json_dup_c("[1,2]");
  ASSERT_TRUE(p != nullptr);
  EXPECT_EQ(std::string(p), std::string("[1,2]"));
  dv_free(p);
}

TEST(Json, test_parser_rejects_invalid_documents) {
  // Guards the guard: the strict parser used by the other tests must catch what it claims to.
  Json j;
  EXPECT_FALSE(json_parse("\"\x01\"", &j));
  EXPECT_FALSE(json_parse("\"\xC0\xAF\"", &j));
  EXPECT_FALSE(json_parse("\"\xED\xA0\x80\"", &j));
  EXPECT_FALSE(json_parse("\"\\ud800\"", &j));
  EXPECT_FALSE(json_parse("[1,]", &j));
  EXPECT_FALSE(json_parse("{\"a\":1} x", &j));
  EXPECT_FALSE(json_parse("01", &j));
  EXPECT_TRUE(json_parse("{\"a\":[true,false,null,-1.5e3,\"\\u00e9\\ud83d\\ude00\"]}", &j));
}
