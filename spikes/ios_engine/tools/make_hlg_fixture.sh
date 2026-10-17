#!/usr/bin/env bash
# IOS-01 spike: fallback HLG fixture for TextureAndRedrawTests.testHLGClipArrivesAsSDR, used only
# when the destination has no HEVC Main10 encoder for MediaFactory.hlgClip. Generated locally with
# the dev-only ffmpeg (no download): 640×360, 30 fps, 1 s, HEVC Main10 (hvc1) BT.2020 / ARIB
# STD-B67 (HLG); left half HLG signal 0.50, right half 0.75, neutral chroma.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
FFMPEG="${FFMPEG:-/opt/homebrew/bin/ffmpeg}"
OUT="$HERE/DVSpikeTests/Fixtures/hlg_bars_640x360.mov"
mkdir -p "$(dirname "$OUT")"
# 10-bit video-range luma codes: 64 + s·876 → 502 (0.50) and 721 (0.75); 8-bit-equivalent inputs
# 125.5/180.25 are expressed through a 16-bit gray source so the 10-bit codes are exact.
"$FFMPEG" -hide_banner -loglevel error -y \
  -f lavfi -i "color=c=0x7D7D7D:s=320x360:r=30:d=1,format=gray16le" \
  -f lavfi -i "color=c=0xB4B4B4:s=320x360:r=30:d=1,format=gray16le" \
  -filter_complex "[0][1]hstack=inputs=2,format=yuv420p10le,setparams=color_primaries=bt2020:color_trc=arib-std-b67:colorspace=bt2020nc:range=tv[v]" \
  -map "[v]" -c:v libx265 -tag:v hvc1 -pix_fmt yuv420p10le \
  -x265-params "colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc:range=limited:log-level=error" \
  -color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc -color_range tv \
  "$OUT"
echo "wrote $OUT"
