// OWNER: AI-03
//
// Shared helpers of the shim host tests: temp files, WAV writers, the handmade model fixtures, a strict
// JSON parser and the log capture behind the "logs never contain segment text or paths" check.
//
// Fixtures (generated at run time; nothing is downloaded):
//  * write_fixture_whisper_model(): a 1-layer, 64-dim multilingual ggml whisper model (~7 MB, f16) whose
//    weights are set by hand so that decoding is deterministic and independent of the audio: every 30 s
//    window decodes to "<|0.00|> hello world <|1.98|><|2.00|> <|endoftext|>" (one segment per 2 s of
//    audio: [k * 2000, k * 2000 + 1980] ms, the last one clamped to the end) and language detection returns "de"
//    with p ~ 1. The decoder's MLP implements a fixed token -> next-token permutation (see the .cpp).
//  * write_fixture_vad_model(): a Silero-shaped ggml VAD model whose probability is ~1 while the 512-sample
//    frame contains a 437.5 Hz tone above ~0.05 amplitude and ~0 otherwise.
// Real-model tests (ai.md §16.3, items 1, 5, 6) use VW_TEST_WHISPER_MODEL / VW_TEST_VAD_MODEL when set
// (scripts/ci/editor/whisper_host.sh downloads and caches the pinned files in CI) and skip otherwise.
#ifndef VW_TEST_SUPPORT_H
#define VW_TEST_SUPPORT_H

#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "vw_whisper.h"

namespace vwt_support {

// ---------------------------------------------------------------------------------------------------
// Log capture (installed by main before any test runs)

/// Routes every shim/whisper log line (level forced to debug) into an in-memory list.
void install_log_capture();
/// Checks the captured lines against every registered secret; returns 0 when clean, 1 otherwise.
/// Also writes the lines to $VW_TEST_LOG_FILE when set (whisper_host.sh greps that file again).
int finish_log_capture();
/// A string that must never appear in a log line (segment text, file paths, prompts).
void register_log_secret(const std::string &s);
/// Snapshot of the captured lines.
std::vector<std::string> captured_log_lines();

// ---------------------------------------------------------------------------------------------------
// Files

/// Per-process temporary directory (its name contains a registered secret marker); removed at exit.
const std::string &temp_dir();
/// temp_dir() + "/" + name.
std::string temp_path(const std::string &name);
bool write_file(const std::string &path, const std::vector<uint8_t> &bytes);
std::vector<uint8_t> read_file(const std::string &path);
bool file_exists(const std::string &path);

/// Canonical 16 kHz mono s16le WAV.
bool write_wav16(const std::string &path, const std::vector<int16_t> &samples);
/// Generic PCM WAV writer for the validator tests (bits 16 or 24; interleaved samples).
std::vector<uint8_t> make_wav_bytes(const std::vector<int16_t> &samples, uint32_t rate, uint16_t channels,
                                    uint16_t bits, uint16_t format = 1);
/// Reads a WAV with the shim's reader (16 kHz mono s16 only) into int16 samples; empty on failure.
std::vector<int16_t> read_wav16(const std::string &path);

/// Audio builders (16 kHz). Amplitudes are in [0, 1].
void append_silence(std::vector<int16_t> *pcm, double seconds);
void append_tone(std::vector<int16_t> *pcm, double seconds, double hz, double amplitude);
/// Deterministic white noise (xorshift) at [amplitude].
void append_noise(std::vector<int16_t> *pcm, double seconds, double amplitude, uint32_t seed);

/// Frequency of the fixture VAD's detector (FFT bin 7 of a 256-point window at 16 kHz).
constexpr double kVadToneHz = 437.5;

// ---------------------------------------------------------------------------------------------------
// Model fixtures

/// Writes the deterministic whisper fixture (see the header comment). Returns false on I/O failure.
bool write_fixture_whisper_model(const std::string &path, bool multilingual = true);
/// Writes the tone-detecting Silero-shaped VAD fixture.
bool write_fixture_vad_model(const std::string &path);
/// Cached fixture paths (written once per process into temp_dir()).
const std::string &fixture_whisper_model(bool multilingual = true);
const std::string &fixture_vad_model();

/// Real models for the opt-in tests; empty when the env var is unset or the file is missing.
std::string env_model_path(const char *env_name);
/// Path of the vendored whisper.cpp samples/jfk.wav.
std::string jfk_wav_path();

// ---------------------------------------------------------------------------------------------------
// Shim helpers

/// vw_model_load + wait until READY or FAILED (timeout -> FAILED). *state receives the final state.
vw_model *load_model_blocking(const std::string &path, int32_t *state, int dtw_preset = 0, int timeout_ms = 60000);

/// Returns a process-lifetime copy of [s] (for the const char * fields of vw_job_params).
const char *intern(const std::string &s);

/// Defaults matching ai.md §4.5 (language "en", 4 threads, greedy, token timestamps, suppress_nst).
vw_job_params default_job_params(const std::string &wav, const std::string &language = "en");

/// Polls vw_job_status_get every [poll_ms] until a terminal state or [timeout_ms]; returns the last status.
vw_job_status wait_job(vw_job *j, int timeout_ms = 120000, int poll_ms = 5);
bool is_terminal(int32_t state);

/// Takes every segment JSON object (vw_job_take_segments_json from 0) as one JSON array string.
std::string take_all_segments_json(vw_job *j);

// ---------------------------------------------------------------------------------------------------
// Strict JSON (RFC 8259) parser used to validate the shim's payloads.

struct Json {
  enum Type { kNull, kBool, kNumber, kString, kArray, kObject } type = kNull;
  bool b = false;
  double num = 0.0;
  std::string str;
  std::vector<Json> arr;
  std::vector<std::pair<std::string, Json>> obj;

  const Json *get(const std::string &key) const;
  double number(const std::string &key, double fallback = -1e300) const;
  std::string string(const std::string &key) const;
};

/// Parses [text]; returns false (and sets *error) on any syntax error, invalid UTF-8 or trailing data.
bool json_parse(const std::string &text, Json *out, std::string *error = nullptr);

/// Decoded segment (schema 1).
struct Seg {
  int64_t i = 0, c = 0, t0 = 0, t1 = 0;
  std::string text;
  double nsp = 0.0, lp = 0.0;
  struct W {
    std::string t;
    int64_t t0 = 0, t1 = 0;
    double p = 0.0;
  };
  std::vector<W> w;
};
/// Parses a segments array; false on schema violations (missing keys, wrong types).
bool parse_segments(const std::string &json, std::vector<Seg> *out, std::string *error = nullptr);

/// Lower-cases ASCII letters and replaces every non-alphanumeric ASCII byte by a space, collapsing runs.
std::string normalize_text(const std::string &s);

/// Test-only access to the shim's live object counters (vw_registry.h).
void live_objects(int64_t *models, int64_t *jobs);

}  // namespace vwt_support

#endif  // VW_TEST_SUPPORT_H
