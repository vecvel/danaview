// OWNER: AI-03
//
// Strict 16 kHz / mono / s16le WAV validation and range reading (see dv_wav.h).
#include "dv_wav.h"

#include <cstring>

#include "dv_whisper.h"

namespace dv {
namespace wav_detail {

uint16_t rd_u16(const uint8_t *p) { return static_cast<uint16_t>(p[0] | (p[1] << 8)); }
uint32_t rd_u32(const uint8_t *p) {
  return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) | (static_cast<uint32_t>(p[2]) << 16) |
         (static_cast<uint32_t>(p[3]) << 24);
}

// KSDATAFORMAT_SUBTYPE_PCM after the 2-byte format code.
const uint8_t kPcmGuidTail[14] = {0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71};

constexpr size_t kMaxHeaderBytes = 64 * 1024;  // chunks before "data" (LIST, fact, ...) must fit here

bool seek64(std::FILE *f, int64_t off) {
#if defined(_WIN32)
  return _fseeki64(f, off, SEEK_SET) == 0;
#else
  return fseeko(f, static_cast<off_t>(off), SEEK_SET) == 0;
#endif
}

int64_t file_size64(std::FILE *f) {
#if defined(_WIN32)
  if (_fseeki64(f, 0, SEEK_END) != 0) return -1;
  return _ftelli64(f);
#else
  if (fseeko(f, 0, SEEK_END) != 0) return -1;
  return static_cast<int64_t>(ftello(f));
#endif
}

}  // namespace wav_detail

int32_t wav_parse_header(const uint8_t *b, size_t n, int64_t file_size, WavInfo *out) {
  using namespace wav_detail;
  if (b == nullptr || out == nullptr) return DV_ERR_INVALID_ARG;
  if (n < 12 || file_size < 12) return DV_ERR_WAV_FORMAT;
  if (std::memcmp(b, "RIFF", 4) != 0 || std::memcmp(b + 8, "WAVE", 4) != 0) return DV_ERR_WAV_FORMAT;

  bool have_fmt = false;
  size_t pos = 12;
  while (true) {
    if (pos + 8 > n) return DV_ERR_WAV_FORMAT;  // no data chunk within the header window / truncated
    const uint8_t *id = b + pos;
    const uint32_t size = rd_u32(b + pos + 4);
    const size_t body = pos + 8;
    if (std::memcmp(id, "fmt ", 4) == 0) {
      if (have_fmt || size < 16 || body + size > n) return DV_ERR_WAV_FORMAT;
      const uint16_t format = rd_u16(b + body);
      const uint16_t channels = rd_u16(b + body + 2);
      const uint32_t rate = rd_u32(b + body + 4);
      const uint32_t byte_rate = rd_u32(b + body + 8);
      const uint16_t block_align = rd_u16(b + body + 12);
      const uint16_t bits = rd_u16(b + body + 14);
      bool pcm = format == 1;
      if (format == 0xFFFE) {  // WAVE_FORMAT_EXTENSIBLE carrying plain PCM
        if (size < 40) return DV_ERR_WAV_FORMAT;
        const uint16_t valid_bits = rd_u16(b + body + 18);
        pcm = rd_u16(b + body + 24) == 1 && std::memcmp(b + body + 26, kPcmGuidTail, 14) == 0 &&
              (valid_bits == 0 || valid_bits == 16);
      }
      if (!pcm || channels != 1 || rate != static_cast<uint32_t>(kSampleRate) || bits != 16 || block_align != 2 ||
          byte_rate != static_cast<uint32_t>(kSampleRate) * 2) {
        return DV_ERR_WAV_FORMAT;
      }
      have_fmt = true;
    } else if (std::memcmp(id, "data", 4) == 0) {
      if (!have_fmt) return DV_ERR_WAV_FORMAT;  // canonical files put fmt first
      if ((size & 1u) != 0) return DV_ERR_WAV_FORMAT;  // half a sample: truncated or not 16-bit
      const int64_t data_offset = static_cast<int64_t>(body);
      if (data_offset + static_cast<int64_t>(size) > file_size) return DV_ERR_WAV_FORMAT;  // truncated
      out->data_offset = data_offset;
      out->n_samples = static_cast<int64_t>(size) / 2;
      return DV_OK;
    }
    // Skip any other chunk (LIST, fact, FLLR, ...); chunks are word aligned.
    const uint64_t next = static_cast<uint64_t>(body) + size + (size & 1u);
    if (static_cast<int64_t>(next) > file_size) return DV_ERR_WAV_FORMAT;
    pos = static_cast<size_t>(next);
  }
}

int32_t wav_probe(const std::string &path, WavInfo *out) {
  WavReader reader;
  const int32_t rc = reader.open(path);
  if (rc != DV_OK) return rc;
  out->n_samples = reader.n_samples();
  return DV_OK;
}

WavReader::~WavReader() {
  if (file_ != nullptr) std::fclose(file_);
}

int32_t WavReader::open(const std::string &path) {
  using namespace wav_detail;
  if (file_ != nullptr) {
    std::fclose(file_);
    file_ = nullptr;
  }
  if (path.empty()) return DV_ERR_INVALID_ARG;
  file_ = std::fopen(path.c_str(), "rb");
  if (file_ == nullptr) return DV_ERR_IO;
  const int64_t size = file_size64(file_);
  if (size < 0 || !seek64(file_, 0)) return DV_ERR_IO;
  std::vector<uint8_t> head(static_cast<size_t>(size < static_cast<int64_t>(kMaxHeaderBytes) ? size : kMaxHeaderBytes));
  if (!head.empty() && std::fread(head.data(), 1, head.size(), file_) != head.size()) return DV_ERR_IO;
  return wav_parse_header(head.data(), head.size(), size, &info_);
}

int32_t WavReader::read(int64_t start, int64_t count, std::vector<float> *out) {
  using namespace wav_detail;
  out->clear();
  if (file_ == nullptr) return DV_ERR_IO;
  if (start < 0) start = 0;
  if (start >= info_.n_samples || count <= 0) return DV_OK;
  if (count > info_.n_samples - start) count = info_.n_samples - start;
  if (!seek64(file_, info_.data_offset + start * 2)) return DV_ERR_IO;
  out->resize(static_cast<size_t>(count));
  constexpr int64_t kBlock = 64 * 1024;  // samples per fread
  scratch_.resize(static_cast<size_t>(kBlock * 2));
  int64_t done = 0;
  while (done < count) {
    const int64_t n = (count - done) < kBlock ? (count - done) : kBlock;
    if (std::fread(scratch_.data(), 2, static_cast<size_t>(n), file_) != static_cast<size_t>(n)) {
      out->clear();
      return DV_ERR_IO;
    }
    float *dst = out->data() + done;
    for (int64_t i = 0; i < n; ++i) {
      const int16_t s = static_cast<int16_t>(rd_u16(scratch_.data() + i * 2));
      dst[i] = static_cast<float>(s) / 32768.0f;
    }
    done += n;
  }
  return DV_OK;
}

}  // namespace dv
