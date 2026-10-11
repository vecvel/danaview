// OWNER: AI-03
//
// Logging for the whisper shim (ai.md §4.6 "Logging"). Policy: transcript text, prompts and file paths
// are never logged.
//  * The shim's own messages go through DV_LOG*(fmt, ...) with numeric arguments only: a `%s` in a
//    DV_LOG format string is rejected by scripts/ci/editor/whisper_host.sh (static check).
//  * whisper.cpp/ggml messages arrive through whisper_log_set (installed by log_init()). DEBUG-level
//    messages are dropped (whisper prints prompt tokens at debug level), and every forwarded line is
//    sanitized: quoted substrings and path-like words are replaced by <redacted>.
// Sinks: iOS os_log (subsystem com.vecvel.danaview.whisper), Android logcat (tag DanaviewWhisper), host stderr.
#ifndef DV_LOG_H
#define DV_LOG_H

#include <cstdint>
#include <string>

namespace dv {

enum LogLevel : int32_t { kLogOff = 0, kLogError = 1, kLogWarn = 2, kLogInfo = 3, kLogDebug = 4 };

/// Installs the whisper/ggml log callback once. Every entry point that can make whisper log calls it.
void log_init();

/// 0 off ... 4 debug (dv_set_log_level). Values outside the range are clamped.
void log_set_level(int32_t level);
int32_t log_level();

/// printf-style message from the shim itself; numeric arguments only (see the header comment).
void log_printf(int32_t level, const char *fmt, ...)
#if defined(__GNUC__) || defined(__clang__)
    __attribute__((format(printf, 2, 3)))
#endif
    ;

/// Replaces quoted substrings and path-like words with <redacted>; strips control characters.
std::string log_sanitize(const std::string &line);

/// Test hook: when set, every emitted line (after filtering and sanitizing) goes to [sink] instead of
/// the platform sink. Not part of the C ABI.
using LogSink = void (*)(int32_t level, const char *line, void *user);
void log_set_sink_for_tests(LogSink sink, void *user);

}  // namespace dv

#define DV_LOGE(...) ::dv::log_printf(::dv::kLogError, __VA_ARGS__)
#define DV_LOGW(...) ::dv::log_printf(::dv::kLogWarn, __VA_ARGS__)
#define DV_LOGI(...) ::dv::log_printf(::dv::kLogInfo, __VA_ARGS__)
#define DV_LOGD(...) ::dv::log_printf(::dv::kLogDebug, __VA_ARGS__)

#endif  // DV_LOG_H
