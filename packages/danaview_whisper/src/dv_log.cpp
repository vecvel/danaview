// OWNER: AI-03
//
// Log routing and sanitizing for the whisper shim (see dv_log.h for the policy).
#include "dv_log.h"

#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <mutex>

#include "whisper.h"

#if defined(__ANDROID__)
#include <android/log.h>
#elif defined(__APPLE__)
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE && !defined(DV_HOST_BUILD)
#include <os/log.h>
#define DV_LOG_USE_OS_LOG 1
#endif
#endif

namespace dv {
namespace log_detail {

std::atomic<int32_t> g_level{kLogWarn};
std::once_flag g_init_once;
std::mutex g_sink_mutex;
LogSink g_sink = nullptr;
void *g_sink_user = nullptr;
constexpr size_t kMaxLine = 512;

// Per-thread line assembly: ggml/whisper may emit a line in several calls (GGML_LOG_LEVEL_CONT).
thread_local std::string t_line;
thread_local int32_t t_line_level = kLogInfo;

void emit_line(int32_t level, const std::string &raw) {
  if (level <= kLogOff || level > g_level.load(std::memory_order_relaxed)) return;
  std::string line = log_sanitize(raw);
  if (line.empty()) return;
  {
    std::lock_guard<std::mutex> lock(g_sink_mutex);
    if (g_sink != nullptr) {
      g_sink(level, line.c_str(), g_sink_user);
      return;
    }
  }
#if defined(__ANDROID__)
  int prio = level == kLogError ? ANDROID_LOG_ERROR
             : level == kLogWarn ? ANDROID_LOG_WARN
             : level == kLogInfo ? ANDROID_LOG_INFO
                                 : ANDROID_LOG_DEBUG;
  __android_log_print(prio, "DanaviewWhisper", "%s", line.c_str());
#elif defined(DV_LOG_USE_OS_LOG)
  static os_log_t log = os_log_create("com.vecvel.danaview.whisper", "shim");
  os_log_type_t type = level == kLogError ? OS_LOG_TYPE_ERROR
                       : level == kLogWarn ? OS_LOG_TYPE_DEFAULT
                       : level == kLogInfo ? OS_LOG_TYPE_INFO
                                           : OS_LOG_TYPE_DEBUG;
  // The line is sanitized (no text, no paths), so it may be public.
  os_log_with_type(log, type, "%{public}s", line.c_str());
#else
  std::fprintf(stderr, "[danaview_whisper] %s\n", line.c_str());
#endif
}

int32_t map_ggml_level(ggml_log_level level) {
  switch (level) {
    case GGML_LOG_LEVEL_ERROR: return kLogError;
    case GGML_LOG_LEVEL_WARN: return kLogWarn;
    case GGML_LOG_LEVEL_INFO: return kLogInfo;
    case GGML_LOG_LEVEL_DEBUG: return kLogDebug;
    default: return kLogInfo;
  }
}

void on_whisper_log(ggml_log_level level, const char *text, void * /*user*/) {
  if (text == nullptr) return;
  if (level != GGML_LOG_LEVEL_CONT) {
    if (!t_line.empty()) {
      emit_line(t_line_level, t_line);
      t_line.clear();
    }
    t_line_level = map_ggml_level(level);
  }
  // whisper prints decoder prompts (previous transcript text) at debug level: never forwarded.
  const bool drop = t_line_level >= kLogDebug;
  for (const char *p = text; *p != '\0'; ++p) {
    if (*p == '\n') {
      if (!drop) emit_line(t_line_level, t_line);
      t_line.clear();
    } else if (!drop && t_line.size() < kMaxLine) {
      t_line.push_back(*p);
    }
  }
}

bool is_path_like(const std::string &word) {
  if (word.find('/') != std::string::npos || word.find('\\') != std::string::npos) return true;
  static const char *kExt[] = {".bin", ".wav", ".gguf", ".mlmodelc", ".json", ".m4a", ".mp4", ".mov"};
  for (const char *ext : kExt) {
    if (word.find(ext) != std::string::npos) return true;
  }
  return false;
}

}  // namespace log_detail

void log_init() {
  std::call_once(log_detail::g_init_once, [] { whisper_log_set(&log_detail::on_whisper_log, nullptr); });
}

void log_set_level(int32_t level) {
  if (level < kLogOff) level = kLogOff;
  if (level > kLogDebug) level = kLogDebug;
  log_detail::g_level.store(level, std::memory_order_relaxed);
}

int32_t log_level() { return log_detail::g_level.load(std::memory_order_relaxed); }

void log_printf(int32_t level, const char *fmt, ...) {
  if (fmt == nullptr || level <= kLogOff || level > log_level()) return;
  char buf[log_detail::kMaxLine];
  va_list args;
  va_start(args, fmt);
  std::vsnprintf(buf, sizeof(buf), fmt, args);
  va_end(args);
  log_detail::emit_line(level, std::string(buf));
}

std::string log_sanitize(const std::string &line) {
  // 1. Quoted substrings ('...' or "...") are replaced as a whole: whisper quotes every path it logs.
  std::string unquoted;
  unquoted.reserve(line.size());
  for (size_t i = 0; i < line.size(); ++i) {
    const char c = line[i];
    if (c == '\'' || c == '"') {
      const size_t close = line.find(c, i + 1);
      if (close != std::string::npos) {
        unquoted += "<redacted>";
        i = close;
        continue;
      }
      unquoted += "<redacted>";
      break;  // unterminated quote: drop the rest
    }
    unquoted.push_back(c);
  }
  // 2. Path-like words; 3. control and non-ASCII bytes (never expected in diagnostics).
  std::string out;
  out.reserve(unquoted.size());
  size_t i = 0;
  while (i < unquoted.size()) {
    if (unquoted[i] == ' ') {
      out.push_back(' ');
      ++i;
      continue;
    }
    size_t j = i;
    while (j < unquoted.size() && unquoted[j] != ' ') ++j;
    std::string word = unquoted.substr(i, j - i);
    if (log_detail::is_path_like(word)) {
      out += "<redacted>";
    } else {
      for (char ch : word) {
        const unsigned char u = static_cast<unsigned char>(ch);
        if (u == '\t') {
          out.push_back(' ');
        } else if (u < 0x20 || u >= 0x7f) {
          out.push_back('?');
        } else {
          out.push_back(ch);
        }
      }
    }
    i = j;
  }
  while (!out.empty() && out.back() == ' ') out.pop_back();
  if (out.size() > log_detail::kMaxLine) out.resize(log_detail::kMaxLine);
  return out;
}

void log_set_sink_for_tests(LogSink sink, void *user) {
  std::lock_guard<std::mutex> lock(log_detail::g_sink_mutex);
  log_detail::g_sink = sink;
  log_detail::g_sink_user = user;
}

}  // namespace dv
