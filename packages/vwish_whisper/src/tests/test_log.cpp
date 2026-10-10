// OWNER: AI-03
//
// Logging policy (ai.md §4.6 "Logging"): no transcript text, prompts or paths. The process-wide check
// (every captured line vs every registered secret) runs in finish_log_capture() after all tests; these
// tests cover the sanitizer and the whisper/ggml forwarding rules directly.
#include <algorithm>

#include "ggml.h"
#include "vw_log.h"
#include "vw_test.h"
#include "vw_test_support.h"

using namespace vwt_support;

namespace vw {
namespace log_detail {
// Defined in vw_log.cpp (external linkage): the callback installed with whisper_log_set.
void on_whisper_log(ggml_log_level level, const char *text, void *user);
}  // namespace log_detail
}  // namespace vw

namespace {

bool any_line_contains(const std::vector<std::string> &lines, size_t from, const std::string &needle) {
  return std::any_of(lines.begin() + static_cast<long>(std::min(from, lines.size())), lines.end(),
                     [&](const std::string &l) { return l.find(needle) != std::string::npos; });
}

}  // namespace

TEST(Log, sanitize_redacts_quoted_strings_and_paths) {
  EXPECT_EQ(vw::log_sanitize("loading model from '/var/mobile/a b/ggml-base.bin'"),
            std::string("loading model from <redacted>"));
  EXPECT_EQ(vw::log_sanitize("open /data/user/0/x/speech.wav failed"), std::string("open <redacted> failed"));
  EXPECT_EQ(vw::log_sanitize("file model.bin missing"), std::string("file <redacted> missing"));
  EXPECT_EQ(vw::log_sanitize("C:\\Users\\x"), std::string("<redacted>"));
  EXPECT_EQ(vw::log_sanitize("text \"ask not what\" end"), std::string("text <redacted> end"));
  EXPECT_EQ(vw::log_sanitize("unterminated 'secret words"), std::string("unterminated <redacted>"));
  EXPECT_EQ(vw::log_sanitize("tab\there \x01\xC3\xA9"), std::string("tab here ???"));
  EXPECT_EQ(vw::log_sanitize("n_vocab = 51865"), std::string("n_vocab = 51865"));
  EXPECT_LE(vw::log_sanitize(std::string(5000, 'x')).size(), static_cast<size_t>(512));
}

TEST(Log, whisper_debug_lines_are_dropped_and_continuations_joined) {
  const size_t before = captured_log_lines().size();
  register_log_secret("decoder prompt secret");
  vw::log_detail::on_whisper_log(GGML_LOG_LEVEL_DEBUG, "decoder prompt secret words\n", nullptr);
  vw::log_detail::on_whisper_log(GGML_LOG_LEVEL_INFO, "whisper_model_load: n_mels", nullptr);
  vw::log_detail::on_whisper_log(GGML_LOG_LEVEL_CONT, " = 80\n", nullptr);
  vw::log_detail::on_whisper_log(GGML_LOG_LEVEL_WARN, "warn path /tmp/vwtest_pathsecret/x.bin\n", nullptr);
  const auto lines = captured_log_lines();
  EXPECT_FALSE(any_line_contains(lines, before, "decoder prompt"));
  EXPECT_TRUE(any_line_contains(lines, before, "whisper_model_load: n_mels = 80"));
  EXPECT_TRUE(any_line_contains(lines, before, "warn path <redacted>"));
}

TEST(Log, level_filter_and_shim_messages) {
  const size_t before = captured_log_lines().size();
  vw_set_log_level(1);
  VW_LOGW("dropped warning %d", 1);
  VW_LOGE("kept error %d", 2);
  vw_set_log_level(4);
  VW_LOGD("kept debug %d", 3);
  vw_set_log_level(99);  // clamped to 4
  EXPECT_EQ(vw::log_level(), 4);
  vw_set_log_level(-3);
  EXPECT_EQ(vw::log_level(), 0);
  VW_LOGE("dropped while off %d", 4);
  vw_set_log_level(4);
  const auto lines = captured_log_lines();
  EXPECT_FALSE(any_line_contains(lines, before, "dropped"));
  EXPECT_TRUE(any_line_contains(lines, before, "kept error 2"));
  EXPECT_TRUE(any_line_contains(lines, before, "kept debug 3"));
}

TEST(Log, model_load_logs_never_contain_the_path) {
  const size_t before = captured_log_lines().size();
  int32_t state = 0;
  vw_model *m = load_model_blocking(fixture_whisper_model(), &state);
  ASSERT_TRUE(m != nullptr);
  EXPECT_EQ(state, VW_MODEL_READY);
  vw_model_release(m);
  const auto lines = captured_log_lines();
  EXPECT_GT(lines.size(), before);                     // whisper logged the load at info level
  EXPECT_TRUE(any_line_contains(lines, before, "<redacted>"));  // ... including the quoted path, redacted
  EXPECT_FALSE(any_line_contains(lines, before, fixture_whisper_model()));
  EXPECT_FALSE(any_line_contains(lines, before, "fixture-whisper"));
}
