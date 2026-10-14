// OWNER: QA-06
//
// dv_eval_runner: host CLI over the danaview whisper shim (ai.md §16.5). The Dart eval harness
// (tool/eval/src/runner.dart) calls it once per clip and tier and parses the single JSON document it
// prints on stdout. The decode parameters are passed explicitly by the harness (it reads them from
// SpeechTuning), so the eval measures exactly the constants the app ships.
//
//   dv_eval_runner transcribe --model M --wav W --language L [options]
//   dv_eval_runner detect --model M --wav W [--vad-model V] [--threads N]
//   dv_eval_runner write-fixture-model --out PATH [--vad-out PATH]
//
// Options of `transcribe`: --threads N, --gpu 0|1, --vad-model PATH, --vad-threshold F,
// --vad-min-speech-ms N, --vad-min-silence-ms N, --vad-speech-pad-ms N, --no-speech-thold F,
// --entropy-thold F, --logprob-thold F, --temperature-inc F, --chunk-target-ms N, --chunk-search-ms N,
// --carry-prompt-words N, --suppress-nst 0|1, --timeout-s N.
//
// Output (transcribe):
//   {"abi":1,"engine":"1.9.4","model":{"loadMs":..,"gpu":0,"gpuFallback":0,"type":..},
//    "job":{"state":"succeeded","error":0,"wallMs":..,"computeMs":..,"processedMs":..,"chunks":..,
//           "language":"en","languageP":..},"peakRssBytes":..,"segments":[<schema-1 shim segments>]}
// Exit status: 0 on a finished job (also NO_SPEECH), 2 on bad arguments, 3 on a model load failure,
// 4 on a failed or timed-out job. Transcript text goes to stdout only (it is the eval's data); the
// shim's own log lines (numbers only) go to stderr.
#include <sys/resource.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <thread>

#include "dv_test_support.h"
#include "dv_whisper.h"

namespace {

using Clock = std::chrono::steady_clock;

struct Args {
  std::string command;
  std::map<std::string, std::string> opts;

  bool has(const std::string &k) const { return opts.count(k) != 0; }
  std::string str(const std::string &k, const std::string &fallback = "") const {
    auto it = opts.find(k);
    return it == opts.end() ? fallback : it->second;
  }
  long num(const std::string &k, long fallback) const {
    auto it = opts.find(k);
    return it == opts.end() ? fallback : std::strtol(it->second.c_str(), nullptr, 10);
  }
  float real(const std::string &k, float fallback) const {
    auto it = opts.find(k);
    return it == opts.end() ? fallback : std::strtof(it->second.c_str(), nullptr);
  }
};

bool parse_args(int argc, char **argv, Args *out) {
  if (argc < 2) return false;
  out->command = argv[1];
  for (int i = 2; i < argc; ++i) {
    std::string k = argv[i];
    if (k.rfind("--", 0) != 0 || i + 1 >= argc) return false;
    out->opts[k.substr(2)] = argv[++i];
  }
  return true;
}

void usage() {
  std::fprintf(stderr,
               "usage:\n"
               "  dv_eval_runner transcribe --model M --wav W --language L [options]\n"
               "  dv_eval_runner detect --model M --wav W [--vad-model V] [--threads N]\n"
               "  dv_eval_runner write-fixture-model --out PATH [--vad-out PATH]\n");
}

std::string escape(const char *s) {
  std::string out;
  for (const char *p = s == nullptr ? "" : s; *p != '\0'; ++p) {
    const unsigned char c = static_cast<unsigned char>(*p);
    if (c == '"' || c == '\\') {
      out += '\\';
      out += static_cast<char>(c);
    } else if (c < 0x20) {
      char buf[8];
      std::snprintf(buf, sizeof(buf), "\\u%04x", c);
      out += buf;
    } else {
      out += static_cast<char>(c);
    }
  }
  return out;
}

const char *state_name(int32_t s) {
  switch (s) {
    case DV_JOB_RUNNING: return "running";
    case DV_JOB_PAUSED: return "paused";
    case DV_JOB_SUCCEEDED: return "succeeded";
    case DV_JOB_FAILED: return "failed";
    case DV_JOB_CANCELLED: return "cancelled";
    default: return "unknown";
  }
}

long long peak_rss_bytes() {
  struct rusage ru;
  std::memset(&ru, 0, sizeof(ru));
  if (getrusage(RUSAGE_SELF, &ru) != 0) return 0;
#if defined(__APPLE__)
  return static_cast<long long>(ru.ru_maxrss);  // bytes on macOS
#else
  return static_cast<long long>(ru.ru_maxrss) * 1024;  // KiB on Linux
#endif
}

dv_model *load(const Args &a, long long *load_ms, int32_t *state) {
  dv_model_params mp;
  std::memset(&mp, 0, sizeof(mp));
  mp.struct_size = sizeof(mp);
  mp.use_gpu = static_cast<int32_t>(a.num("gpu", 0));
  mp.flash_attn = 1;
  mp.dtw_preset = 0;
  const auto t0 = Clock::now();
  dv_model *m = dv_model_load(a.str("model").c_str(), &mp);
  *state = DV_MODEL_FAILED;
  if (m != nullptr) {
    const auto deadline = t0 + std::chrono::seconds(300);
    while ((*state = dv_model_get_state(m)) == DV_MODEL_LOADING && Clock::now() < deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
  }
  *load_ms = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - t0).count();
  return m;
}

dv_job_params job_params(const Args &a, int32_t mode, const std::string &wav, const std::string &language,
                         const std::string &vad) {
  dv_job_params p;
  std::memset(&p, 0, sizeof(p));
  p.struct_size = sizeof(p);
  p.mode = mode;
  p.wav_path = wav.c_str();
  p.range_start_ms = 0;
  p.range_end_ms = -1;
  p.language = language.c_str();
  p.n_threads = static_cast<int32_t>(a.num("threads", 4));
  p.chunk_target_ms = static_cast<int32_t>(a.num("chunk-target-ms", 180000));
  p.chunk_search_ms = static_cast<int32_t>(a.num("chunk-search-ms", 15000));
  p.chunk_min_ms = 10000;
  p.vad_enabled = vad.empty() ? 0 : 1;
  p.vad_model_path = vad.empty() ? nullptr : vad.c_str();
  p.vad_threshold = a.real("vad-threshold", 0.5f);
  p.vad_min_speech_ms = static_cast<int32_t>(a.num("vad-min-speech-ms", 250));
  p.vad_min_silence_ms = static_cast<int32_t>(a.num("vad-min-silence-ms", 300));
  p.vad_speech_pad_ms = static_cast<int32_t>(a.num("vad-speech-pad-ms", 100));
  p.vad_samples_overlap_s = a.real("vad-samples-overlap-s", 0.1f);
  p.token_timestamps = 1;
  p.no_speech_thold = a.real("no-speech-thold", 0.6f);
  p.entropy_thold = a.real("entropy-thold", 2.4f);
  p.logprob_thold = a.real("logprob-thold", -1.0f);
  p.temperature_inc = a.real("temperature-inc", 0.2f);
  p.beam_size = 1;
  p.best_of = 5;
  p.suppress_nst = static_cast<int32_t>(a.num("suppress-nst", 1));
  p.carry_prompt_words = static_cast<int32_t>(a.num("carry-prompt-words", 24));
  p.initial_prompt = nullptr;
  p.detect_max_speech_ms = 30000;
  p.detect_search_ms = 600000;
  return p;
}

int run_job(const Args &a, int32_t mode) {
  if (!a.has("model") || !a.has("wav") || (mode == DV_MODE_TRANSCRIBE && !a.has("language"))) {
    usage();
    return 2;
  }
  long long load_ms = 0;
  int32_t mstate = DV_MODEL_FAILED;
  dv_model *m = load(a, &load_ms, &mstate);
  if (m == nullptr || mstate != DV_MODEL_READY) {
    std::printf("{\"abi\":%d,\"error\":\"model_load\",\"model\":{\"loadMs\":%lld}}\n", dv_abi_version(), load_ms);
    if (m != nullptr) dv_model_release(m);
    return 3;
  }
  dv_model_info info;
  std::memset(&info, 0, sizeof(info));
  info.struct_size = sizeof(info);
  dv_model_info_get(m, &info);

  const std::string wav = a.str("wav");
  const std::string language = mode == DV_MODE_TRANSCRIBE ? a.str("language") : std::string("auto");
  const std::string vad = a.str("vad-model");
  const dv_job_params p = job_params(a, mode, wav, language, vad);
  int32_t start_status = DV_OK;
  const auto t0 = Clock::now();
  dv_job *j = dv_job_start(m, &p, &start_status);
  if (j == nullptr) {
    std::printf("{\"abi\":%d,\"error\":\"job_start\",\"status\":%d}\n", dv_abi_version(), start_status);
    dv_model_release(m);
    return 4;
  }
  dv_job_status s;
  std::memset(&s, 0, sizeof(s));
  const auto deadline = t0 + std::chrono::seconds(a.num("timeout-s", 3600));
  bool timed_out = false;
  while (true) {
    s.struct_size = sizeof(s);
    dv_job_status_get(j, &s);
    if (s.state == DV_JOB_SUCCEEDED || s.state == DV_JOB_FAILED || s.state == DV_JOB_CANCELLED) break;
    if (Clock::now() >= deadline) {
      timed_out = true;
      dv_job_cancel(j);
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
  }
  const long long wall_ms = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - t0).count();

  std::string payload;
  if (mode == DV_MODE_TRANSCRIBE) {
    char *raw = dv_job_take_segments_json(j, 0, 1 << 30);
    payload = std::string("\"segments\":") + (raw != nullptr ? raw : "[]");
    if (raw != nullptr) dv_free(raw);
  } else {
    char *raw = dv_job_language_probs_json(j, 5);
    payload = std::string("\"detect\":") + (raw != nullptr ? raw : "null");
    if (raw != nullptr) dv_free(raw);
  }

  char lang[sizeof(s.language) + 1];
  std::memcpy(lang, s.language, sizeof(s.language));
  lang[sizeof(s.language)] = '\0';
  std::printf(
      "{\"abi\":%d,\"engine\":\"%s\","
      "\"model\":{\"loadMs\":%lld,\"gpu\":%d,\"gpuFallback\":%d,\"type\":%d,\"ftype\":%d,\"multilingual\":%d},"
      "\"job\":{\"state\":\"%s\",\"error\":%d,\"timedOut\":%s,\"wallMs\":%lld,\"computeMs\":%lld,"
      "\"processedMs\":%lld,\"chunks\":%d,\"threads\":%d,\"language\":\"%s\",\"languageP\":%.4f},"
      "\"peakRssBytes\":%lld,%s}\n",
      dv_abi_version(), escape(dv_engine_version()).c_str(), load_ms, info.gpu_used, info.gpu_fallback,
      info.model_type, info.ftype, info.multilingual, state_name(s.state), s.error, timed_out ? "true" : "false",
      wall_ms, static_cast<long long>(s.compute_ms), static_cast<long long>(s.processed_ms), s.chunk_count,
      s.threads, escape(lang).c_str(), static_cast<double>(s.language_p), peak_rss_bytes(), payload.c_str());
  std::fflush(stdout);

  const bool ok = s.state == DV_JOB_SUCCEEDED || (s.state == DV_JOB_FAILED && s.error == DV_ERR_NO_SPEECH);
  dv_job_free(j);
  dv_model_release(m);
  dv_shutdown_all();
  return ok && !timed_out ? 0 : 4;
}

int write_fixture(const Args &a) {
  if (!a.has("out")) {
    usage();
    return 2;
  }
  if (!dvt_support::write_fixture_whisper_model(a.str("out"), true)) return 4;
  if (a.has("vad-out") && !dvt_support::write_fixture_vad_model(a.str("vad-out"))) return 4;
  return 0;
}

}  // namespace

int main(int argc, char **argv) {
  Args a;
  if (!parse_args(argc, argv, &a)) {
    usage();
    return 2;
  }
  dv_set_log_level(static_cast<int32_t>(a.num("log-level", 1)));
  if (a.command == "transcribe") return run_job(a, DV_MODE_TRANSCRIBE);
  if (a.command == "detect") return run_job(a, DV_MODE_DETECT_LANGUAGE);
  if (a.command == "write-fixture-model") return write_fixture(a);
  usage();
  return 2;
}
