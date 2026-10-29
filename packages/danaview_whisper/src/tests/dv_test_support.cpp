// OWNER: AI-03
//
// Helpers of the shim host tests (see dv_test_support.h).
#include "dv_test_support.h"

#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <set>
#include <thread>

#include "ggml.h"
#include "dv_log.h"
#include "dv_registry.h"
#include "dv_wav.h"

#ifndef DV_TEST_JFK_WAV
#define DV_TEST_JFK_WAV ""
#endif

namespace dvt_support {
namespace {

// ---------------------------------------------------------------------------------------------------
// Log capture

std::mutex g_log_mu;
std::vector<std::string> g_log_lines;
std::vector<std::string> g_secrets;

void capture_sink(int32_t level, const char *line, void *) {
  std::lock_guard<std::mutex> lock(g_log_mu);
  g_log_lines.emplace_back(std::to_string(level) + " " + (line != nullptr ? line : ""));
  if (std::getenv("DV_TEST_VERBOSE") != nullptr) std::fprintf(stderr, "  log: %s\n", line);
}

// ---------------------------------------------------------------------------------------------------
// Files

void remove_tree(const std::string &dir) {
  // Only files directly inside our own temp dir are created by the tests.
  std::string cmd = "rm -rf '" + dir + "'";
  if (std::system(cmd.c_str()) != 0) std::fprintf(stderr, "warning: could not remove the test temp dir\n");
}

struct TempDir {
  std::string path;
  TempDir() {
    const char *base = std::getenv("TMPDIR");
    std::string tmpl = std::string(base != nullptr && base[0] != '\0' ? base : "/tmp");
    if (tmpl.back() == '/') tmpl.pop_back();
    tmpl += "/dvtest_pathsecret_XXXXXX";
    std::vector<char> buf(tmpl.begin(), tmpl.end());
    buf.push_back('\0');
    if (mkdtemp(buf.data()) == nullptr) {
      std::perror("mkdtemp");
      std::abort();
    }
    path = buf.data();
  }
  ~TempDir() {
    if (std::getenv("DV_TEST_KEEP_TMP") == nullptr) remove_tree(path);
  }
};

void put_u16(std::vector<uint8_t> *b, uint16_t v) {
  b->push_back(static_cast<uint8_t>(v & 0xFF));
  b->push_back(static_cast<uint8_t>(v >> 8));
}
void put_u32(std::vector<uint8_t> *b, uint32_t v) {
  for (int i = 0; i < 4; ++i) b->push_back(static_cast<uint8_t>((v >> (8 * i)) & 0xFF));
}
void put_i32(std::vector<uint8_t> *b, int32_t v) { put_u32(b, static_cast<uint32_t>(v)); }
void put_f32(std::vector<uint8_t> *b, float f) {
  uint32_t u;
  std::memcpy(&u, &f, 4);
  put_u32(b, u);
}
void put_str(std::vector<uint8_t> *b, const std::string &s) { b->insert(b->end(), s.begin(), s.end()); }

int16_t to_s16(double v) {
  const double c = std::max(-1.0, std::min(1.0, v));
  return static_cast<int16_t>(std::lround(c * 32767.0));
}

// ---------------------------------------------------------------------------------------------------
// ggml model writer

struct Tensor {
  std::string name;
  std::vector<int32_t> ne;  // ne[0] is the contiguous dimension
  bool f16 = false;
  std::vector<float> data;  // nelements values (row-major, ne[0] fastest)

  size_t n() const {
    size_t k = 1;
    for (int32_t e : ne) k *= static_cast<size_t>(e);
    return k;
  }
};

Tensor make_tensor(const std::string &name, std::vector<int32_t> ne, bool f16, float fill = 0.0f) {
  Tensor t;
  t.name = name;
  t.ne = std::move(ne);
  t.f16 = f16;
  t.data.assign(t.n(), fill);
  return t;
}

void put_tensor(std::vector<uint8_t> *b, const Tensor &t) {
  put_i32(b, static_cast<int32_t>(t.ne.size()));
  put_i32(b, static_cast<int32_t>(t.name.size()));
  put_i32(b, t.f16 ? 1 : 0);  // GGML_TYPE_F16 = 1, GGML_TYPE_F32 = 0
  for (int32_t e : t.ne) put_i32(b, e);
  put_str(b, t.name);
  if (t.f16) {
    for (float v : t.data) put_u16(b, ggml_fp32_to_fp16(v));
  } else {
    for (float v : t.data) put_f32(b, v);
  }
}

// Fixture whisper geometry.
constexpr int32_t kAudioCtx = 150;  // 3 s of mel per window (like whisper's audio_ctx speed-up); timestamps stay 20 ms units
constexpr int32_t kState = 64;
constexpr int32_t kTextCtx = 448;
constexpr int32_t kMels = 80;
constexpr int32_t kTokHello = 1000;
constexpr int32_t kTokWorld = 1001;

// Special tokens of whisper.cpp's whisper_vocab: multilingual (n_vocab 51865, 99 languages) or
// English-only (n_vocab 51864).
struct FixtureVocab {
  int32_t n_vocab, in_file, eot, sot, transcribe, beg, lang_de;
  explicit FixtureVocab(bool multilingual)
      : n_vocab(multilingual ? 51865 : 51864),
        in_file(multilingual ? 50257 : 50256),
        eot(multilingual ? 50257 : 50256),
        sot(eot + 1),
        transcribe(multilingual ? 50359 : 50358),
        beg(multilingual ? 50364 : 50363),
        lang_de(multilingual ? sot + 1 + 2 : -1) {}  // whisper_lang_id("de") == 2
};

}  // namespace

// ---------------------------------------------------------------------------------------------------
// Log capture API

void install_log_capture() {
  temp_dir();  // registers the path secret before anything logs
  dv_set_log_level(4);
  dv::log_set_sink_for_tests(&capture_sink, nullptr);
}

void register_log_secret(const std::string &s) {
  if (s.empty()) return;
  std::lock_guard<std::mutex> lock(g_log_mu);
  g_secrets.push_back(s);
}

std::vector<std::string> captured_log_lines() {
  std::lock_guard<std::mutex> lock(g_log_mu);
  return g_log_lines;
}

int finish_log_capture() {
  dv_shutdown_all();
  dv::log_set_sink_for_tests(nullptr, nullptr);
  std::lock_guard<std::mutex> lock(g_log_mu);
  if (const char *file = std::getenv("DV_TEST_LOG_FILE")) {
    if (std::FILE *f = std::fopen(file, "w")) {
      for (const std::string &l : g_log_lines) std::fprintf(f, "%s\n", l.c_str());
      std::fclose(f);
    }
  }
  int leaks = 0;
  for (const std::string &l : g_log_lines) {
    for (const std::string &s : g_secrets) {
      if (l.find(s) != std::string::npos) {
        ++leaks;
        std::fprintf(stderr, "LOG PRIVACY VIOLATION: a log line contains a registered secret: %s\n", l.c_str());
      }
    }
  }
  std::printf("log capture: %zu lines checked against %zu secrets, %d violations\n", g_log_lines.size(),
              g_secrets.size(), leaks);
  return leaks == 0 ? 0 : 1;
}

// ---------------------------------------------------------------------------------------------------
// Files

const std::string &temp_dir() {
  static TempDir dir;  // removed by its destructor at exit (after dv_shutdown_all in finish_log_capture)
  static const bool registered = [] {
    register_log_secret(dir.path);
    register_log_secret("dvtest_pathsecret");
    return true;
  }();
  (void)registered;
  return dir.path;
}

std::string temp_path(const std::string &name) { return temp_dir() + "/" + name; }

bool write_file(const std::string &path, const std::vector<uint8_t> &bytes) {
  std::FILE *f = std::fopen(path.c_str(), "wb");
  if (f == nullptr) return false;
  const bool ok = bytes.empty() || std::fwrite(bytes.data(), 1, bytes.size(), f) == bytes.size();
  return std::fclose(f) == 0 && ok;
}

std::vector<uint8_t> read_file(const std::string &path) {
  std::vector<uint8_t> out;
  std::FILE *f = std::fopen(path.c_str(), "rb");
  if (f == nullptr) return out;
  uint8_t buf[65536];
  size_t n;
  while ((n = std::fread(buf, 1, sizeof(buf), f)) > 0) out.insert(out.end(), buf, buf + n);
  std::fclose(f);
  return out;
}

bool file_exists(const std::string &path) {
  struct stat st;
  return ::stat(path.c_str(), &st) == 0;
}

std::vector<uint8_t> make_wav_bytes(const std::vector<int16_t> &samples, uint32_t rate, uint16_t channels,
                                    uint16_t bits, uint16_t format) {
  const uint16_t bytes_per_sample = static_cast<uint16_t>(bits / 8);
  const uint32_t data_size = static_cast<uint32_t>(samples.size()) * bytes_per_sample;
  std::vector<uint8_t> b;
  put_str(&b, "RIFF");
  put_u32(&b, 36 + data_size);
  put_str(&b, "WAVE");
  put_str(&b, "fmt ");
  put_u32(&b, 16);
  put_u16(&b, format);
  put_u16(&b, channels);
  put_u32(&b, rate);
  put_u32(&b, rate * channels * bytes_per_sample);
  put_u16(&b, static_cast<uint16_t>(channels * bytes_per_sample));
  put_u16(&b, bits);
  put_str(&b, "data");
  put_u32(&b, data_size);
  for (int16_t s : samples) {
    if (bits == 24) {
      const int32_t v = static_cast<int32_t>(s) * 256;
      b.push_back(static_cast<uint8_t>(v & 0xFF));
      b.push_back(static_cast<uint8_t>((v >> 8) & 0xFF));
      b.push_back(static_cast<uint8_t>((v >> 16) & 0xFF));
    } else {
      put_u16(&b, static_cast<uint16_t>(s));
    }
  }
  return b;
}

bool write_wav16(const std::string &path, const std::vector<int16_t> &samples) {
  return write_file(path, make_wav_bytes(samples, 16000, 1, 16));
}

std::vector<int16_t> read_wav16(const std::string &path) {
  dv::WavReader r;
  std::vector<int16_t> out;
  if (r.open(path) != DV_OK) return out;
  std::vector<float> f;
  if (r.read(0, r.n_samples(), &f) != DV_OK) return out;
  out.reserve(f.size());
  for (float v : f) out.push_back(static_cast<int16_t>(std::lround(v * 32768.0f)));
  return out;
}

void append_silence(std::vector<int16_t> *pcm, double seconds) {
  pcm->insert(pcm->end(), static_cast<size_t>(std::llround(seconds * 16000.0)), 0);
}

void append_tone(std::vector<int16_t> *pcm, double seconds, double hz, double amplitude) {
  const size_t n = static_cast<size_t>(std::llround(seconds * 16000.0));
  const size_t base = pcm->size();
  for (size_t i = 0; i < n; ++i) {
    const double t = static_cast<double>(base + i) / 16000.0;
    pcm->push_back(to_s16(amplitude * std::sin(2.0 * M_PI * hz * t)));
  }
}

void append_noise(std::vector<int16_t> *pcm, double seconds, double amplitude, uint32_t seed) {
  const size_t n = static_cast<size_t>(std::llround(seconds * 16000.0));
  uint32_t x = seed != 0 ? seed : 0x9E3779B9u;
  for (size_t i = 0; i < n; ++i) {
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    const double u = static_cast<double>(x) / 4294967295.0 * 2.0 - 1.0;
    pcm->push_back(to_s16(amplitude * u));
  }
}

// ---------------------------------------------------------------------------------------------------
// Whisper fixture
//
// All encoder weights are zero (its output is zero, so the audio never matters) and every decoder
// attention weight is zero, so each position's output depends only on its input token:
//   x   = token_embedding[tok]                        (one-hot rows, value 1, for the 8 tokens below)
//   x  += W2 * gelu(W1 * LN(x))                       (W1 = identity into the first 64 hidden units,
//                                                      W2[next(d)][d] = 10: a dimension permutation)
//   h   = 4 * LN(x);  logits = token_embedding * h    (tied output projection)
// so the next token's logit is ~31.8 and every other logit is <= ~0.5. The chain is
//   transcribe -> <|0.00|> -> " hello" -> " world" -> <|1.98|> -> <|2.00|> -> <|endoftext|>,
//   <|sot|> -> <|de|>   (language detection).
// whisper's timestamp rules accept it as-is (initial timestamp <= 1 s, text after a lone initial
// timestamp, timestamps forced when their mass dominates, increasing timestamps, EOT after a timestamp
// pair), so every window yields the segment [seek, seek + 1.98 s] "hello world" and seeks 2 s forward
// (the pair avoids whisper's "single timestamp ending" rule, which would skip the whole 30 s window).
// The last window of a file ends early (end of audio) and its segment is clamped by the shim.

bool write_fixture_whisper_model(const std::string &path, bool multilingual) {
  const FixtureVocab v(multilingual);
  std::vector<uint8_t> b;
  b.reserve(8u << 20);
  put_u32(&b, 0x67676d6c);  // GGML_FILE_MAGIC
  for (int32_t h : {v.n_vocab, kAudioCtx, kState, 1, 1, kTextCtx, kState, 1, 1, kMels, 1 /* ftype f16 */}) put_i32(&b, h);
  // mel filters
  put_i32(&b, kMels);
  put_i32(&b, 201);
  for (int i = 0; i < kMels * 201; ++i) put_f32(&b, (i % 201) == (i / 201) * 2 ? 1.0f : 0.0f);
  // vocabulary (ids >= v.in_file are named by whisper itself)
  put_i32(&b, v.in_file);
  for (int32_t i = 0; i < v.in_file; ++i) {
    std::string w;
    if (i == kTokHello) {
      w = " hello";
    } else if (i == kTokWorld) {
      w = " world";
    } else if (i == 220) {
      w = " ";  // suppress_blank looks this token up with .at()
    } else if (i < 94) {
      w = std::string(1, static_cast<char>('!' + i));
    } else {
      w = " w" + std::to_string(i);
    }
    put_u32(&b, static_cast<uint32_t>(w.size()));
    put_str(&b, w);
  }

  const int32_t s = kState;
  std::vector<Tensor> ts;
  // encoder
  ts.push_back(make_tensor("encoder.positional_embedding", {s, kAudioCtx}, false));
  ts.push_back(make_tensor("encoder.conv1.weight", {3, kMels, s}, true));
  ts.push_back(make_tensor("encoder.conv1.bias", {1, s}, false));
  ts.push_back(make_tensor("encoder.conv2.weight", {3, s, s}, true));
  ts.push_back(make_tensor("encoder.conv2.bias", {1, s}, false));
  ts.push_back(make_tensor("encoder.ln_post.weight", {s}, false));
  ts.push_back(make_tensor("encoder.ln_post.bias", {s}, false));
  const std::string e = "encoder.blocks.0.";
  ts.push_back(make_tensor(e + "mlp_ln.weight", {s}, false));
  ts.push_back(make_tensor(e + "mlp_ln.bias", {s}, false));
  ts.push_back(make_tensor(e + "mlp.0.weight", {s, 4 * s}, true));
  ts.push_back(make_tensor(e + "mlp.0.bias", {4 * s}, false));
  ts.push_back(make_tensor(e + "mlp.2.weight", {4 * s, s}, true));
  ts.push_back(make_tensor(e + "mlp.2.bias", {s}, false));
  ts.push_back(make_tensor(e + "attn_ln.weight", {s}, false));
  ts.push_back(make_tensor(e + "attn_ln.bias", {s}, false));
  ts.push_back(make_tensor(e + "attn.query.weight", {s, s}, true));
  ts.push_back(make_tensor(e + "attn.query.bias", {s}, false));
  ts.push_back(make_tensor(e + "attn.key.weight", {s, s}, true));
  ts.push_back(make_tensor(e + "attn.value.weight", {s, s}, true));
  ts.push_back(make_tensor(e + "attn.value.bias", {s}, false));
  ts.push_back(make_tensor(e + "attn.out.weight", {s, s}, true));
  ts.push_back(make_tensor(e + "attn.out.bias", {s}, false));

  // decoder
  ts.push_back(make_tensor("decoder.positional_embedding", {s, kTextCtx}, false));
  Tensor te = make_tensor("decoder.token_embedding.weight", {s, v.n_vocab}, true);
  // token -> one-hot dimension. The last prompt token is <|transcribe|> (multilingual) or <|sot|>.
  std::vector<std::pair<int32_t, int32_t>> dims = {
      {multilingual ? v.transcribe : v.sot, 0}, {v.beg, 1}, {kTokHello, 2}, {kTokWorld, 3},
      {v.beg + 99, 4} /* <|1.98|> */,           {v.beg + 100, 5} /* <|2.00|> */, {v.eot, 6},
  };
  if (multilingual) {
    dims.push_back({v.sot, 7});
    dims.push_back({v.lang_de, 8});
  }
  for (const auto &d : dims) te.data[static_cast<size_t>(d.first) * s + static_cast<size_t>(d.second)] = 1.0f;
  ts.push_back(std::move(te));
  ts.push_back(make_tensor("decoder.ln.weight", {s}, false, 4.0f));
  ts.push_back(make_tensor("decoder.ln.bias", {s}, false));
  const std::string d = "decoder.blocks.0.";
  ts.push_back(make_tensor(d + "mlp_ln.weight", {s}, false, 1.0f));
  ts.push_back(make_tensor(d + "mlp_ln.bias", {s}, false));
  Tensor w1 = make_tensor(d + "mlp.0.weight", {s, 4 * s}, true);  // [out j][in i] at j * s + i
  for (int32_t i = 0; i < s; ++i) w1.data[static_cast<size_t>(i) * s + static_cast<size_t>(i)] = 1.0f;
  ts.push_back(std::move(w1));
  ts.push_back(make_tensor(d + "mlp.0.bias", {4 * s}, false));
  Tensor w2 = make_tensor(d + "mlp.2.weight", {4 * s, s}, true);  // [out k][in j] at k * 4s + j
  const std::vector<std::pair<int32_t, int32_t>> next = {{0, 1}, {1, 2}, {2, 3}, {3, 4}, {4, 5}, {5, 6}, {7, 8}};
  for (const auto &p : next) w2.data[static_cast<size_t>(p.second) * 4 * s + static_cast<size_t>(p.first)] = 10.0f;
  ts.push_back(std::move(w2));
  ts.push_back(make_tensor(d + "mlp.2.bias", {s}, false));
  for (const std::string &pre : {d + "attn", d + "cross_attn"}) {
    ts.push_back(make_tensor(pre + "_ln.weight", {s}, false));
    ts.push_back(make_tensor(pre + "_ln.bias", {s}, false));
    ts.push_back(make_tensor(pre + ".query.weight", {s, s}, true));
    ts.push_back(make_tensor(pre + ".query.bias", {s}, false));
    ts.push_back(make_tensor(pre + ".key.weight", {s, s}, true));
    ts.push_back(make_tensor(pre + ".value.weight", {s, s}, true));
    ts.push_back(make_tensor(pre + ".value.bias", {s}, false));
    ts.push_back(make_tensor(pre + ".out.weight", {s, s}, true));
    ts.push_back(make_tensor(pre + ".out.bias", {s}, false));
  }
  for (const Tensor &t : ts) put_tensor(&b, t);
  return write_file(path, b);
}

// ---------------------------------------------------------------------------------------------------
// VAD fixture (Silero v5/v6 layout, whisper.cpp whisper_vad_init_with_params)
//
// STFT basis: only bin 7 (437.5 Hz) is non-zero, so channel 7 of the magnitude is ~128 * amplitude for
// the test tone. Each encoder conv passes that channel through to channel 0 (centre tap = 1). The LSTM's
// unit 0 has i = o = 1, f = 0 and g = tanh(M - 5), so h0 = tanh(g) is +0.76 for the tone and -0.76 for
// silence; the final conv gives sigmoid(20 * relu(h0) - 5): ~1 for the tone, 0.007 otherwise.

bool write_fixture_vad_model(const std::string &path) {
  std::vector<uint8_t> b;
  put_u32(&b, 0x67676d6c);
  const std::string type = "silero-16k";
  put_i32(&b, static_cast<int32_t>(type.size()));
  put_str(&b, type);
  put_i32(&b, 6);
  put_i32(&b, 2);
  put_i32(&b, 0);
  put_i32(&b, 512);  // n_window
  put_i32(&b, 64);   // n_context
  put_i32(&b, 4);    // encoder layers
  const int32_t enc[4][3] = {{129, 128, 3}, {128, 64, 3}, {64, 64, 3}, {64, 128, 3}};
  for (const auto &l : enc) {
    put_i32(&b, l[0]);
    put_i32(&b, l[1]);
    put_i32(&b, l[2]);
  }
  put_i32(&b, 128);  // lstm_input_size
  put_i32(&b, 128);  // lstm_hidden_size
  put_i32(&b, 128);  // final_conv_in
  put_i32(&b, 1);    // final_conv_out

  std::vector<Tensor> ts;
  Tensor basis = make_tensor("_model.stft.forward_basis_buffer", {256, 1, 258}, true);
  for (int n = 0; n < 256; ++n) {
    const double a = 2.0 * M_PI * 7.0 * n / 256.0;
    basis.data[7 * 256 + static_cast<size_t>(n)] = static_cast<float>(std::cos(a));
    basis.data[(129 + 7) * 256 + static_cast<size_t>(n)] = static_cast<float>(-std::sin(a));
  }
  ts.push_back(std::move(basis));
  for (int l = 0; l < 4; ++l) {
    const int32_t in = enc[l][0], out = enc[l][1], k = enc[l][2];
    Tensor w = make_tensor("_model.encoder." + std::to_string(l) + ".reparam_conv.weight", {k, in, out}, true);
    const int32_t src = l == 0 ? 7 : 0;  // index k + K * (ic + IC * oc)
    w.data[static_cast<size_t>(1 + k * (src + in * 0))] = 1.0f;
    ts.push_back(std::move(w));
    ts.push_back(make_tensor("_model.encoder." + std::to_string(l) + ".reparam_conv.bias", {out}, false));
  }
  Tensor ih = make_tensor("_model.decoder.rnn.weight_ih", {128, 512}, false);  // [out][in] at out * 128 + in
  ih.data[static_cast<size_t>(256) * 128 + 0] = 1.0f;                          // g0 += M
  ts.push_back(std::move(ih));
  ts.push_back(make_tensor("_model.decoder.rnn.weight_hh", {128, 512}, false));
  Tensor bih = make_tensor("_model.decoder.rnn.bias_ih", {512}, false);
  bih.data[0] = 10.0f;     // i0
  bih.data[128] = -10.0f;  // f0
  bih.data[256] = -5.0f;   // g0 threshold
  bih.data[384] = 10.0f;   // o0
  ts.push_back(std::move(bih));
  ts.push_back(make_tensor("_model.decoder.rnn.bias_hh", {512}, false));
  Tensor fw = make_tensor("_model.decoder.decoder.2.weight", {128, 1}, true);
  fw.data[0] = 20.0f;
  ts.push_back(std::move(fw));
  ts.push_back(make_tensor("_model.decoder.decoder.2.bias", {1}, false, -5.0f));
  for (const Tensor &t : ts) put_tensor(&b, t);
  return write_file(path, b);
}

const std::string &fixture_whisper_model(bool multilingual) {
  static const std::string path_ml = [] {
    const std::string p = temp_path("fixture-whisper.bin");
    if (!write_fixture_whisper_model(p, true)) {
      std::fprintf(stderr, "could not write the whisper fixture\n");
      std::abort();
    }
    return p;
  }();
  if (multilingual) return path_ml;
  static const std::string path = [] {
    const std::string p = temp_path("fixture-whisper-en.bin");
    if (!write_fixture_whisper_model(p, false)) {
      std::fprintf(stderr, "could not write the whisper fixture\n");
      std::abort();
    }
    return p;
  }();
  return path;
}

const std::string &fixture_vad_model() {
  static const std::string path = [] {
    const std::string p = temp_path("fixture-vad.bin");
    if (!write_fixture_vad_model(p)) {
      std::fprintf(stderr, "could not write the VAD fixture\n");
      std::abort();
    }
    return p;
  }();
  return path;
}

std::string env_model_path(const char *env_name) {
  const char *v = std::getenv(env_name);
  if (v == nullptr || v[0] == '\0' || !file_exists(v)) return std::string();
  register_log_secret(v);
  return v;
}

std::string jfk_wav_path() {
  const std::string p = DV_TEST_JFK_WAV;
  if (!p.empty()) register_log_secret(p);
  return p;
}

// ---------------------------------------------------------------------------------------------------
// Shim helpers

dv_model *load_model_blocking(const std::string &path, int32_t *state, int dtw_preset, int timeout_ms) {
  register_log_secret(path);
  dv_model_params mp;
  std::memset(&mp, 0, sizeof(mp));
  mp.struct_size = sizeof(mp);
  mp.use_gpu = 0;
  mp.flash_attn = 1;
  mp.dtw_preset = dtw_preset;
  dv_model *m = dv_model_load(path.c_str(), &mp);
  int32_t st = DV_MODEL_FAILED;
  if (m != nullptr) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
    while ((st = dv_model_get_state(m)) == DV_MODEL_LOADING && std::chrono::steady_clock::now() < deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
  }
  if (state != nullptr) *state = st;
  return m;
}

const char *intern(const std::string &s) {
  static std::mutex mu;
  static std::set<std::string> *pool = new std::set<std::string>();
  std::lock_guard<std::mutex> lock(mu);
  return pool->insert(s).first->c_str();
}

dv_job_params default_job_params(const std::string &wav, const std::string &language) {
  register_log_secret(wav);
  dv_job_params p;
  std::memset(&p, 0, sizeof(p));
  p.struct_size = sizeof(p);
  p.mode = DV_MODE_TRANSCRIBE;
  p.wav_path = intern(wav);
  p.range_start_ms = 0;
  p.range_end_ms = -1;
  p.language = language.empty() ? nullptr : intern(language);
  // ai.md §4.5 uses 4 threads; capped to the host's cores so a 3-vCPU CI runner is not
  // oversubscribed (whisper's compute threads spin, so 4 on 3 cores runs 20-50x slower).
  // Tests that set n_threads explicitly keep their own value.
  const unsigned hw = std::thread::hardware_concurrency();
  p.n_threads = (hw == 0 || hw >= 4) ? 4 : static_cast<int32_t>(hw);
  p.chunk_target_ms = 180000;
  p.chunk_search_ms = 15000;
  p.chunk_min_ms = 10000;
  p.vad_enabled = 0;
  p.vad_model_path = nullptr;
  p.vad_threshold = 0.5f;
  p.vad_min_speech_ms = 250;
  p.vad_min_silence_ms = 300;
  p.vad_speech_pad_ms = 100;
  p.vad_samples_overlap_s = 0.1f;
  p.token_timestamps = 1;
  p.no_speech_thold = 0.6f;
  p.entropy_thold = 2.4f;
  p.logprob_thold = -1.0f;
  p.temperature_inc = 0.2f;
  p.beam_size = 1;
  p.best_of = 5;
  p.suppress_nst = 1;
  p.carry_prompt_words = 0;
  p.initial_prompt = nullptr;
  p.detect_max_speech_ms = 30000;
  p.detect_search_ms = 600000;
  return p;
}

bool is_terminal(int32_t state) {
  return state == DV_JOB_SUCCEEDED || state == DV_JOB_FAILED || state == DV_JOB_CANCELLED;
}

dv_job_status wait_job(dv_job *j, int timeout_ms, int poll_ms) {
  dv_job_status s;
  std::memset(&s, 0, sizeof(s));
  s.struct_size = sizeof(s);
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
  while (true) {
    s.struct_size = sizeof(s);
    dv_job_status_get(j, &s);
    if (is_terminal(s.state) || std::chrono::steady_clock::now() >= deadline) return s;
    std::this_thread::sleep_for(std::chrono::milliseconds(poll_ms));
  }
}

std::string take_all_segments_json(dv_job *j) {
  char *raw = dv_job_take_segments_json(j, 0, 1 << 30);
  if (raw == nullptr) return std::string();
  std::string out(raw);
  dv_free(raw);
  return out;
}

void live_objects(int64_t *models, int64_t *jobs) { dv::debug_live_objects(models, jobs); }

void wait_loaders_idle() { dv::Registry::get().wait_loaders_idle(); }

// ---------------------------------------------------------------------------------------------------
// JSON

const Json *Json::get(const std::string &key) const {
  for (const auto &kv : obj) {
    if (kv.first == key) return &kv.second;
  }
  return nullptr;
}

double Json::number(const std::string &key, double fallback) const {
  const Json *v = get(key);
  return v != nullptr && v->type == kNumber ? v->num : fallback;
}

std::string Json::string(const std::string &key) const {
  const Json *v = get(key);
  return v != nullptr && v->type == kString ? v->str : std::string();
}

namespace {

class Parser {
 public:
  explicit Parser(const std::string &s) : s_(s) {}

  bool parse(Json *out, std::string *error) {
    ws();
    if (!value(out, 0)) {
      if (error != nullptr) *error = err_ + " at offset " + std::to_string(i_);
      return false;
    }
    ws();
    if (i_ != s_.size()) {
      if (error != nullptr) *error = "trailing data at offset " + std::to_string(i_);
      return false;
    }
    return true;
  }

 private:
  bool fail(const char *m) {
    err_ = m;
    return false;
  }
  void ws() {
    while (i_ < s_.size() && (s_[i_] == ' ' || s_[i_] == '\t' || s_[i_] == '\n' || s_[i_] == '\r')) ++i_;
  }
  bool lit(const char *w) {
    const size_t n = std::strlen(w);
    if (s_.compare(i_, n, w) != 0) return fail("bad literal");
    i_ += n;
    return true;
  }
  bool value(Json *v, int depth) {
    if (depth > 64) return fail("too deep");
    if (i_ >= s_.size()) return fail("unexpected end");
    const char c = s_[i_];
    if (c == '{') return object(v, depth);
    if (c == '[') return array(v, depth);
    if (c == '"') {
      v->type = Json::kString;
      return string(&v->str);
    }
    if (c == 't') {
      v->type = Json::kBool;
      v->b = true;
      return lit("true");
    }
    if (c == 'f') {
      v->type = Json::kBool;
      return lit("false");
    }
    if (c == 'n') {
      v->type = Json::kNull;
      return lit("null");
    }
    return number(v);
  }
  bool object(Json *v, int depth) {
    v->type = Json::kObject;
    ++i_;
    ws();
    if (i_ < s_.size() && s_[i_] == '}') {
      ++i_;
      return true;
    }
    while (true) {
      ws();
      if (i_ >= s_.size() || s_[i_] != '"') return fail("expected key");
      std::string k;
      if (!string(&k)) return false;
      ws();
      if (i_ >= s_.size() || s_[i_] != ':') return fail("expected ':'");
      ++i_;
      ws();
      Json child;
      if (!value(&child, depth + 1)) return false;
      v->obj.emplace_back(std::move(k), std::move(child));
      ws();
      if (i_ < s_.size() && s_[i_] == ',') {
        ++i_;
        continue;
      }
      if (i_ < s_.size() && s_[i_] == '}') {
        ++i_;
        return true;
      }
      return fail("expected ',' or '}'");
    }
  }
  bool array(Json *v, int depth) {
    v->type = Json::kArray;
    ++i_;
    ws();
    if (i_ < s_.size() && s_[i_] == ']') {
      ++i_;
      return true;
    }
    while (true) {
      ws();
      Json child;
      if (!value(&child, depth + 1)) return false;
      v->arr.push_back(std::move(child));
      ws();
      if (i_ < s_.size() && s_[i_] == ',') {
        ++i_;
        continue;
      }
      if (i_ < s_.size() && s_[i_] == ']') {
        ++i_;
        return true;
      }
      return fail("expected ',' or ']'");
    }
  }
  static void append_utf8(std::string *o, uint32_t cp) {
    if (cp < 0x80) {
      o->push_back(static_cast<char>(cp));
    } else if (cp < 0x800) {
      o->push_back(static_cast<char>(0xC0 | (cp >> 6)));
      o->push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    } else if (cp < 0x10000) {
      o->push_back(static_cast<char>(0xE0 | (cp >> 12)));
      o->push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
      o->push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    } else {
      o->push_back(static_cast<char>(0xF0 | (cp >> 18)));
      o->push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
      o->push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
      o->push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    }
  }
  bool hex4(uint32_t *out) {
    if (i_ + 4 > s_.size()) return fail("short \\u escape");
    uint32_t v = 0;
    for (int k = 0; k < 4; ++k) {
      const char h = s_[i_++];
      v <<= 4;
      if (h >= '0' && h <= '9') {
        v |= static_cast<uint32_t>(h - '0');
      } else if (h >= 'a' && h <= 'f') {
        v |= static_cast<uint32_t>(h - 'a' + 10);
      } else if (h >= 'A' && h <= 'F') {
        v |= static_cast<uint32_t>(h - 'A' + 10);
      } else {
        return fail("bad hex digit");
      }
    }
    *out = v;
    return true;
  }
  // Validates one UTF-8 sequence starting at i_ and appends it.
  bool utf8_char(std::string *o) {
    const auto b0 = static_cast<unsigned char>(s_[i_]);
    size_t need;
    uint32_t cp, min;
    if (b0 >= 0xC2 && b0 <= 0xDF) {
      need = 1;
      cp = b0 & 0x1F;
      min = 0x80;
    } else if (b0 >= 0xE0 && b0 <= 0xEF) {
      need = 2;
      cp = b0 & 0x0F;
      min = 0x800;
    } else if (b0 >= 0xF0 && b0 <= 0xF4) {
      need = 3;
      cp = b0 & 0x07;
      min = 0x10000;
    } else {
      return fail("invalid UTF-8 lead byte");
    }
    if (i_ + need >= s_.size()) return fail("truncated UTF-8");
    for (size_t k = 1; k <= need; ++k) {
      const auto bk = static_cast<unsigned char>(s_[i_ + k]);
      if ((bk & 0xC0) != 0x80) return fail("invalid UTF-8 continuation");
      cp = (cp << 6) | (bk & 0x3F);
    }
    if (cp < min || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return fail("invalid UTF-8 code point");
    o->append(s_, i_, need + 1);
    i_ += need + 1;
    return true;
  }
  bool string(std::string *o) {
    ++i_;  // opening quote
    while (true) {
      if (i_ >= s_.size()) return fail("unterminated string");
      const auto c = static_cast<unsigned char>(s_[i_]);
      if (c == '"') {
        ++i_;
        return true;
      }
      if (c < 0x20) return fail("unescaped control character");
      if (c == '\\') {
        ++i_;
        if (i_ >= s_.size()) return fail("bad escape");
        const char e = s_[i_++];
        switch (e) {
          case '"': o->push_back('"'); break;
          case '\\': o->push_back('\\'); break;
          case '/': o->push_back('/'); break;
          case 'b': o->push_back('\b'); break;
          case 'f': o->push_back('\f'); break;
          case 'n': o->push_back('\n'); break;
          case 'r': o->push_back('\r'); break;
          case 't': o->push_back('\t'); break;
          case 'u': {
            uint32_t cp;
            if (!hex4(&cp)) return false;
            if (cp >= 0xD800 && cp <= 0xDBFF) {
              if (i_ + 2 > s_.size() || s_[i_] != '\\' || s_[i_ + 1] != 'u') return fail("lone high surrogate");
              i_ += 2;
              uint32_t lo;
              if (!hex4(&lo)) return false;
              if (lo < 0xDC00 || lo > 0xDFFF) return fail("bad low surrogate");
              cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
            } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
              return fail("lone low surrogate");
            }
            append_utf8(o, cp);
            break;
          }
          default:
            return fail("bad escape");
        }
        continue;
      }
      if (c < 0x80) {
        o->push_back(static_cast<char>(c));
        ++i_;
        continue;
      }
      if (!utf8_char(o)) return false;
    }
  }
  bool number(Json *v) {
    const size_t start = i_;
    if (i_ < s_.size() && s_[i_] == '-') ++i_;
    if (i_ >= s_.size()) return fail("bad number");
    if (s_[i_] == '0') {
      ++i_;
    } else if (s_[i_] >= '1' && s_[i_] <= '9') {
      while (i_ < s_.size() && s_[i_] >= '0' && s_[i_] <= '9') ++i_;
    } else {
      return fail("bad number");
    }
    if (i_ < s_.size() && s_[i_] == '.') {
      ++i_;
      if (i_ >= s_.size() || s_[i_] < '0' || s_[i_] > '9') return fail("bad fraction");
      while (i_ < s_.size() && s_[i_] >= '0' && s_[i_] <= '9') ++i_;
    }
    if (i_ < s_.size() && (s_[i_] == 'e' || s_[i_] == 'E')) {
      ++i_;
      if (i_ < s_.size() && (s_[i_] == '+' || s_[i_] == '-')) ++i_;
      if (i_ >= s_.size() || s_[i_] < '0' || s_[i_] > '9') return fail("bad exponent");
      while (i_ < s_.size() && s_[i_] >= '0' && s_[i_] <= '9') ++i_;
    }
    v->type = Json::kNumber;
    v->num = std::strtod(s_.substr(start, i_ - start).c_str(), nullptr);
    return true;
  }

  const std::string &s_;
  size_t i_ = 0;
  std::string err_;
};

}  // namespace

bool json_parse(const std::string &text, Json *out, std::string *error) {
  Parser p(text);
  Json v;
  if (!p.parse(&v, error)) return false;
  *out = std::move(v);
  return true;
}

bool parse_segments(const std::string &json, std::vector<Seg> *out, std::string *error) {
  out->clear();
  Json root;
  if (!json_parse(json, &root, error)) return false;
  auto bad = [error](const std::string &m) {
    if (error != nullptr) *error = m;
    return false;
  };
  if (root.type != Json::kArray) return bad("segments payload is not an array");
  for (const Json &o : root.arr) {
    if (o.type != Json::kObject) return bad("segment is not an object");
    for (const char *k : {"i", "c", "t0", "t1", "nsp", "lp"}) {
      const Json *v = o.get(k);
      if (v == nullptr || v->type != Json::kNumber) return bad(std::string("segment key missing or not a number: ") + k);
    }
    const Json *text = o.get("text");
    const Json *w = o.get("w");
    if (text == nullptr || text->type != Json::kString) return bad("segment text missing");
    if (w == nullptr || w->type != Json::kArray) return bad("segment words missing");
    Seg s;
    s.i = static_cast<int64_t>(o.number("i"));
    s.c = static_cast<int64_t>(o.number("c"));
    s.t0 = static_cast<int64_t>(o.number("t0"));
    s.t1 = static_cast<int64_t>(o.number("t1"));
    s.nsp = o.number("nsp");
    s.lp = o.number("lp");
    s.text = text->str;
    for (const Json &wj : w->arr) {
      if (wj.type != Json::kObject) return bad("word is not an object");
      const Json *t = wj.get("t");
      if (t == nullptr || t->type != Json::kString) return bad("word text missing");
      for (const char *k : {"t0", "t1", "p"}) {
        const Json *v = wj.get(k);
        if (v == nullptr || v->type != Json::kNumber) return bad(std::string("word key missing: ") + k);
      }
      Seg::W word;
      word.t = t->str;
      word.t0 = static_cast<int64_t>(wj.number("t0"));
      word.t1 = static_cast<int64_t>(wj.number("t1"));
      word.p = wj.number("p");
      s.w.push_back(std::move(word));
    }
    out->push_back(std::move(s));
  }
  return true;
}

std::string normalize_text(const std::string &s) {
  std::string out;
  bool space = true;
  for (char ch : s) {
    const auto c = static_cast<unsigned char>(ch);
    if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c >= 0x80) {
      out.push_back(ch);
      space = false;
    } else if (c >= 'A' && c <= 'Z') {
      out.push_back(static_cast<char>(c - 'A' + 'a'));
      space = false;
    } else if (c == '\'') {
      // "that's" -> "thats"
    } else if (!space) {
      out.push_back(' ');
      space = true;
    }
  }
  while (!out.empty() && out.back() == ' ') out.pop_back();
  return out;
}

}  // namespace dvt_support
