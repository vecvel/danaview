#!/usr/bin/env bash
# OWNER: S2-Q
#
# Generates the local test media of the S2 E2E scenarios (integration_test/v12/s2): nothing is
# downloaded. Writes into <out> (default build/e2e/s2_media, ignored by git):
#
#   s2_photo.jpg   2400 x 1600 JPEG with EXIF (make, model, lens, date taken, exposure, aperture,
#                  focal length, ISO), drawn by Pillow
#   s2_clip.mp4    4 s 1280 x 720 H.264 + AAC (ffmpeg testsrc2 and a 440 Hz sine)
#   stress/p00..p23.jpg  24 JPEG variants (1600 x 1200 and 1200 x 1600, gradients) and
#   stress/v0..v3.mp4    4 short 480 x 270 H.264 clips: the sources the S2 Home stress probe
#                  (s2_home_stress_test.dart) copies into a generated Danaview-folder library
#
# Usage: integration_test/v12/s2/tool/make_s2_media.sh [out]
# Needs python3 with Pillow and ffmpeg (both local tools). bash 3.2 compatible.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
OUT="${1:-$ROOT/build/e2e/s2_media}"
mkdir -p "$OUT"

python3 - "$OUT/s2_photo.jpg" <<'PY'
import sys
from PIL import Image, ImageDraw

out = sys.argv[1]
w, h = 2400, 1600
img = Image.new("RGB", (w, h))
d = ImageDraw.Draw(img)
for y in range(0, h, 8):
    d.rectangle([0, y, w, y + 8], fill=(20 + y * 120 // h, 60 + y * 80 // h, 140 - y * 60 // h))
d.ellipse([w // 2 - 300, h // 2 - 300, w // 2 + 300, h // 2 + 300], fill=(240, 200, 60))
d.rectangle([200, 1200, 2200, 1350], fill=(30, 30, 30))

exif = Image.Exif()
exif[0x010F] = "Danaview QA"          # Make
exif[0x0110] = "S2 Test Cam"          # Model
exif[0x0132] = "2026:10:21 09:05:00"  # DateTime
ifd = exif.get_ifd(0x8769)            # Exif IFD
ifd[0x9003] = "2026:10:21 09:05:00"   # DateTimeOriginal
ifd[0x829A] = (1, 120)                # ExposureTime
ifd[0x829D] = (18, 10)                # FNumber
ifd[0x920A] = (26, 1)                 # FocalLength
ifd[0x8827] = 100                     # ISO
ifd[0xA434] = "QA Lens 26mm"          # LensModel
img.save(out, "JPEG", quality=88, exif=exif)
PY

ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc2=size=1280x720:rate=30:duration=4" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=4" \
  -c:v libx264 -pix_fmt yuv420p -profile:v high -c:a aac -b:a 128k -shortest -movflags +faststart \
  "$OUT/s2_clip.mp4"

mkdir -p "$OUT/stress"
python3 - "$OUT/stress" <<'PY'
import sys
from PIL import Image, ImageDraw

out = sys.argv[1]
for i in range(24):
    w, h = (1600, 1200) if i % 3 else (1200, 1600)
    img = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(img)
    for y in range(0, h, 10):
        d.rectangle([0, y, w, y + 10], fill=((i * 37 + y // 7) % 256, (i * 91 + y // 5) % 256, (200 - i * 7) % 256))
    d.ellipse([w // 4, h // 4, w // 4 + 300 + i * 10, h // 4 + 300], fill=(250 - i * 5, 220, 40 + i * 8))
    img.save(f"{out}/p{i:02d}.jpg", "JPEG", quality=80)
PY
for i in 0 1 2 3; do
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=480x270:rate=30:duration=$((i + 1))" \
    -c:v libx264 -pix_fmt yuv420p -an -movflags +faststart "$OUT/stress/v$i.mp4"
done

ls -l "$OUT" "$OUT/stress"
