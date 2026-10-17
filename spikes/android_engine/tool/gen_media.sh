#!/usr/bin/env bash
# AND-01 spike media, generated locally (no downloads). Dev-only: needs /opt/homebrew/bin/ffmpeg.
# Output goes to spikes/android_engine/media/ (git-ignored) and is packaged into the androidTest
# APK as assets (see app/build.gradle.kts).
#
# Pattern (every video, 32x18 cells upscaled with nearest-neighbour so every cell is a flat block):
#   rows 0-5   barcode: 16 columns; col 0 = white marker, col 15 = black marker, cols 1..14 = the
#              14-bit source frame number N (MSB first; white = 1).
#   rows 6-11  mid grey (128) for alpha / tint checks.
#   rows 12-17 orientation marker: left half green, right half blue.
# Sources have no B-frames (no edit lists) unless the name says `_bf`.
set -euo pipefail

FFMPEG=${FFMPEG:-/opt/homebrew/bin/ffmpeg}
FFPROBE=${FFPROBE:-/opt/homebrew/bin/ffprobe}
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/media"
mkdir -p "$OUT"

BIT='if(eq(floor(X/2),0),1,if(eq(floor(X/2),15),0,bitand(floor(N/pow(2,14-floor(X/2))),1)))'
R="if(lt(Y,6),255*$BIT,if(lt(Y,12),128,0))"
G="if(lt(Y,6),255*$BIT,if(lt(Y,12),128,if(lt(X,16),255,0)))"
B="if(lt(Y,6),255*$BIT,if(lt(Y,12),128,if(lt(X,16),0,255)))"
PATTERN="format=gbrp,geq=r='$R':g='$G':b='$B'"
TAGS=(-color_primaries bt709 -color_trc bt709 -colorspace bt709 -color_range tv)

# barcode_<fps>.mp4: 1280x720 H.264 High, 1 s closed GOP, no B-frames, 12 s.
gen_barcode() {
  local fps=$1 secs=$2 name=$3 extra=("${@:4}")
  "$FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=black:s=32x18:r=$fps:d=$secs" \
    -vf "$PATTERN,scale=1280:720:flags=neighbor:out_color_matrix=bt709:out_range=tv,format=yuv420p" \
    -c:v libx264 -preset veryfast -crf 16 -g "$fps" -keyint_min "$fps" -sc_threshold 0 \
    "${extra[@]}" -profile:v high "${TAGS[@]}" -movflags +faststart "$OUT/$name"
}

gen_barcode 24 12 barcode_24.mp4 -bf 0
gen_barcode 30 12 barcode_30.mp4 -bf 0
gen_barcode 60 12 barcode_60.mp4 -bf 0
# Same content with B-frames (edit list / composition offsets) for the source-frame rule test.
gen_barcode 30 12 barcode_30_bf.mp4 -bf 2

# rotated_30.mp4: stored 720x1280 (pixels turned 90 degrees counter-clockwise) with a display
# matrix asking for a 90 degree clockwise rotation, so the upright display is the 1280x720 pattern.
"$FFMPEG" -hide_banner -loglevel error -y \
  -f lavfi -i "color=c=black:s=32x18:r=30:d=4" \
  -vf "$PATTERN,scale=1280:720:flags=neighbor,transpose=2,scale=out_color_matrix=bt709:out_range=tv,format=yuv420p" \
  -c:v libx264 -preset veryfast -crf 16 -g 30 -bf 0 -profile:v high "${TAGS[@]}" \
  -movflags +faststart "$OUT/rotated_30_raw.mp4"
"$FFMPEG" -hide_banner -loglevel error -y -display_rotation 270 -i "$OUT/rotated_30_raw.mp4" \
  -c copy -movflags +faststart "$OUT/rotated_30.mp4"
rm -f "$OUT/rotated_30_raw.mp4"

# hlg_30.mp4: HEVC Main10, BT.2020 primaries, HLG transfer, 1280x720, 3 s.
"$FFMPEG" -hide_banner -loglevel error -y \
  -f lavfi -i "color=c=black:s=32x18:r=30:d=3" \
  -vf "$PATTERN,scale=1280:720:flags=neighbor:out_color_matrix=bt2020:out_range=tv,format=yuv420p10le" \
  -c:v libx265 -preset fast -crf 18 -tag:v hvc1 \
  -x265-params "log-level=error:keyint=30:min-keyint=30:bframes=0:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc:range=limited" \
  -color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc -color_range tv \
  -movflags +faststart "$OUT/hlg_30.mp4"

# hlg8_30.mp4: the same pattern as 8-bit H.264 High tagged BT.2020 + HLG (decodable everywhere;
# probes whether Media3's OpenGL tone-mapping path runs when no HEVC Main10 decoder exists).
"$FFMPEG" -hide_banner -loglevel error -y \
  -f lavfi -i "color=c=black:s=32x18:r=30:d=3" \
  -vf "$PATTERN,scale=1280:720:flags=neighbor:out_color_matrix=bt2020:out_range=tv,format=yuv420p,setparams=color_primaries=bt2020:color_trc=arib-std-b67:colorspace=bt2020nc:range=tv" \
  -c:v libx264 -preset veryfast -crf 16 -g 30 -bf 0 -profile:v high \
  -x264-params "colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc" \
  -movflags +faststart "$OUT/hlg8_30.mp4"

# tone_<hz>.m4a: AAC-LC 48 kHz stereo sine, 12 s, -12 dBFS.
for hz in 440 880; do
  "$FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i "sine=frequency=$hz:sample_rate=48000:duration=12" \
    -af "volume=-3dB,aformat=channel_layouts=stereo" -c:a aac -b:a 128k "$OUT/tone_$hz.m4a"
done

# barcode_30_av.mp4: barcode video + 1 kHz tone bursts at every whole second (A/V latency probe).
"$FFMPEG" -hide_banner -loglevel error -y \
  -f lavfi -i "color=c=black:s=32x18:r=30:d=12" \
  -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=12" \
  -filter_complex "[0:v]$PATTERN,scale=1280:720:flags=neighbor:out_color_matrix=bt709:out_range=tv,format=yuv420p[v];[1:a]volume='if(lt(mod(t,1),0.05),1,0)':eval=frame,aformat=channel_layouts=stereo[a]" \
  -map "[v]" -map "[a]" -c:v libx264 -preset veryfast -crf 16 -g 30 -bf 0 -profile:v high "${TAGS[@]}" \
  -c:a aac -b:a 128k -movflags +faststart "$OUT/barcode_30_av.mp4"

# Self-checks: the rotated file displays upright (ffmpeg autorotates on decode).
"$FFPROBE" -v error -select_streams v:0 -show_entries stream=width,height:stream_side_data=rotation \
  -of default=nw=1 "$OUT/rotated_30.mp4"
"$FFMPEG" -hide_banner -loglevel error -y -i "$OUT/rotated_30.mp4" -frames:v 1 -vf "scale=32:18:flags=area" \
  -f rawvideo -pix_fmt rgb24 "$OUT/.rot_check.rgb"
python3 - "$OUT/.rot_check.rgb" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
px = lambda x, y: d[(y * 32 + x) * 3:(y * 32 + x) * 3 + 3]
assert px(0, 2)[0] > 200, ('col0 marker must be white (upright display)', px(0, 2))
assert px(31, 2)[0] < 60, ('col15 marker must be black', px(31, 2))
assert px(4, 15)[1] > 150 and px(28, 15)[2] > 150, ('bottom-left green, bottom-right blue', px(4, 15), px(28, 15))
print('rotated_30.mp4 displays upright')
PY
rm -f "$OUT/.rot_check.rgb"
ls -la "$OUT"
