# Downloads for the Windows / Android lane (owner-approved 2026-10-22)

The owner approved these downloads **on the Windows laptop**. Nothing here goes into the repo.
Keep the files outside it, in `C:/dev/models/` (the folder `soak_host.py -m` already uses), and
write a `SHA256SUMS` file and a `LICENSES.md` file next to them. Download each file once, then
verify it; never re-download a file that is already there and verified.

## 1. Speaker diarization models (AIS-44 Android half)

Folder: `C:/dev/models/diarization/`. Source: the official sherpa-onnx GitHub releases. The
SHA-256 values are the Mac's; your files must match them.

| File | URL | Bytes | SHA-256 |
|---|---|---|---|
| `sherpa-onnx-pyannote-segmentation-3-0.tar.bz2` | https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2 | 6,958,444 | `24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488` |
| `nemo_en_titanet_small.onnx` (recommended embedding) | https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/nemo_en_titanet_small.onnx | 40,257,283 | `ad4a1802485d8b34c722d2a9d04249662f2ece5d28a7a039063ca22f515a789e` |
| `wespeaker_en_voxceleb_resnet34_LM.onnx` (fallback) | https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/wespeaker_en_voxceleb_resnet34_LM.onnx | 26,530,550 | `e9848563da86f263117134dfd7ad63c92355b37de492b55e325400c9d9c39012` |
| `3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx` (rejected on the Mac; optional, for parity only) | https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx | 29,596,978 | `357a834f702b80161e5b981182c038e18553c1f2ca752ed6cec2052365d4129b` |

The `speaker-recongition-models` spelling in the URLs is the release tag's own. After you extract
the tarball into `segmentation/`, these files must match:

- `segmentation/sherpa-onnx-pyannote-segmentation-3-0/model.int8.onnx`: `d582f4b4c6b48205de7e0643c57df0df5615a3c176189be3fc461e9d18827b5d`
- `segmentation/sherpa-onnx-pyannote-segmentation-3-0/model.onnx`: `220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079`

The Mac's report and eval set are `docs/v1.2/ai-studio/spikes/AIS-44-diarization.md` and
`docs/v1.2/ai-studio/qa/diarization_eval.md`. The 4 small clips are tracked in
`spikes/ais-44-diarization/data/`; the larger ones are regenerated from the scripts there, which
use macOS `say`. On Windows, use the tracked clips and say in your section which clips you used.

## 2. Face fixtures (VED-33A, later VED-33)

Folder: `C:/dev/models/faces/` with `stills/` and `clips/`. 17 files, 28,370,200 bytes in total.
Sizes are from HEAD requests. Record each file's SHA-256 in `faces/SHA256SUMS` after you download
it, and commit that list into your VED-33A report. The Mac downloads the same list when VED-33
starts, and the hashes let it check that both machines have identical files.

### Licences

- **MediaPipe images:** Apache-2.0, per Google's test-data folder
  (https://github.com/google-ai-edge/mediapipe/blob/master/mediapipe/tasks/testdata/vision/BUILD).
  Keep a copy of the Apache-2.0 text in `faces/`.
- **Everything else:** the Pexels License (https://www.pexels.com/license/). It allows commercial
  use and needs no credit. It does **not** allow:
  - showing a recognisable person in a bad light;
  - implying the person endorses Danaview, so these files never go into store screenshots or
    marketing;
  - selling unaltered copies.

  Pexels guarantees no model releases. It also bans bulk scraping and machine-learning training:
  downloading these 17 files by hand for on-device testing is fine, but **never train on them**.
- **Privacy:** these are real, identifiable people (laws such as BIPA and GDPR cover face
  geometry). Run the models on the device only, and never store landmarks or embeddings tied to
  these files outside a test run.
- **`faces/LICENSES.md`:** list each file's name, source page URL, licence, creator and download
  date.

### Stills (14)

Pexels files are the originals (`https://images.pexels.com/photos/<ID>/pexels-photo-<ID>.jpeg`).
If a test needs a smaller copy, add `?auto=compress&cs=tinysrgb&w=1920` to the URL (about 0.16–0.54
MB each) and record which form you used.

| # | Save as | Coverage | URL (licence page) | Creator | Bytes |
|---|---|---|---|---|---|
| 1 | `stills/01_frontal_mediapipe.jpg` | frontal (MediaPipe reference) | https://storage.googleapis.com/mediapipe-assets/portrait.jpg | Google, Apache-2.0 | 176,561 |
| 2 | `stills/02_pose_fullbody_mediapipe.jpg` | full-body pose (MediaPipe reference) | https://storage.googleapis.com/mediapipe-assets/pose.jpg | Google, Apache-2.0 | 44,100 |
| 3 | `stills/03_three_quarter_older.jpg` | three-quarter, looking away, older adult | https://images.pexels.com/photos/8145123/pexels-photo-8145123.jpeg (https://www.pexels.com/photo/elderly-woman-looking-away-8145123/) | Eman Genatilan | 2,990,269 |
| 4 | `stills/04_profile_dark_bg.jpg` | side profile, dark background | https://images.pexels.com/photos/7298898/pexels-photo-7298898.jpeg (https://www.pexels.com/photo/side-profile-of-a-serious-woman-7298898/) | Kindel Media | 1,314,036 |
| 5 | `stills/05_glasses_beard.jpg` | glasses + beard, lens reflections | https://images.pexels.com/photos/6450245/pexels-photo-6450245.jpeg (https://www.pexels.com/photo/a-man-wearing-black-framed-eyeglasses-6450245/) | Vasiliy Skuratov | 1,217,724 |
| 6 | `stills/06_frontal_older_studio.jpg` | frontal studio, older adult | https://images.pexels.com/photos/8727507/pexels-photo-8727507.jpeg (https://www.pexels.com/photo/elderly-woman-in-brown-shirt-8727507/) | Tima Miroshnichenko | 2,141,611 |
| 7 | `stills/07_mask_occlusion.jpg` | occlusion by a medical mask, leaf shadows | https://images.pexels.com/photos/4177640/pexels-photo-4177640.jpeg (https://www.pexels.com/photo/black-woman-in-medical-mask-against-white-wall-with-shadow-4177640/) | RF._.studio | 960,973 |
| 8 | `stills/08_hand_occlusion.jpg` | occlusion by a hand | https://images.pexels.com/photos/4309701/pexels-photo-4309701.jpeg (https://www.pexels.com/photo/a-man-covering-his-face-with-his-hand-4309701/) | The Black Lovster | 1,169,948 |
| 9 | `stills/09_low_light.jpg` | low light (also a side profile) | https://images.pexels.com/photos/35070445/pexels-photo-35070445.jpeg (https://www.pexels.com/photo/moody-portrait-of-a-woman-in-low-light-35070445/) | Fel. On_Film | 353,015 |
| 10 | `stills/10_backlit_sunset.jpg` | backlit at sunset (**check that the face is visible**) | https://images.pexels.com/photos/12981365/pexels-photo-12981365.jpeg (https://www.pexels.com/photo/a-woman-in-white-top-standing-against-the-sun-12981365/) | Kostiantyn Klymovets | 451,730 |
| 11 | `stills/11_backlit_silhouette.jpg` | backlit silhouette (hard edge case) | https://images.pexels.com/photos/14145640/pexels-photo-14145640.jpeg (https://www.pexels.com/photo/portrait-of-a-man-at-sunset-14145640/) | kübra zehra | 408,965 |
| 12 | `stills/12_two_people.jpg` | two people, close-up | https://images.pexels.com/photos/16032141/pexels-photo-16032141.jpeg (https://www.pexels.com/photo/portrait-of-smiling-interracial-couple-posing-on-grey-background-16032141/) | MC Production | 1,015,929 |
| 13 | `stills/13_four_people.jpg` | four people outdoors (**check that all four are adults**) | https://images.pexels.com/photos/3776833/pexels-photo-3776833.jpeg (https://www.pexels.com/photo/photo-of-four-people-smiling-3776833/) | Andrea Piacquadio | 938,863 |
| 14 | `stills/14_no_face_room.jpg` | negative: an empty room | https://images.pexels.com/photos/3935327/pexels-photo-3935327.jpeg (https://www.pexels.com/photo/photo-of-an-empty-room-3935327/) | Curtis Adams | 2,462,290 |

### Clips (3, 1080p)

| Save as | Coverage | URL (licence page) | Creator | Length | Bytes |
|---|---|---|---|---|---|
| `clips/01_head_turn.mp4` | head turning | https://videos.pexels.com/video-files/6968225/6968225-hd_1920_1080_25fps.mp4 (https://www.pexels.com/video/a-man-moving-his-head-6968225/) | SHVETS production | 10 s | 3,273,657 |
| `clips/02_two_people_talking.mp4` | two people talking, moving | https://videos.pexels.com/video-files/5977460/5977460-hd_1920_1080_25fps.mp4 (https://www.pexels.com/video/man-and-woman-talking-to-each-other-inside-the-office-5977460/) | Jack Sparrow | 13 s | 7,347,438 |
| `clips/03_low_light.mp4` | low light, heavy shadow | https://videos.pexels.com/video-files/34725793/14720141_1920_1080_50fps.mp4 (https://www.pexels.com/video/contemplative-close-up-of-man-in-shadowy-lighting-34725793/) | Özgür Sürmeli | 12 s | 2,103,091 |

### If a file is gone, or its size differs a lot

Don't hunt for a replacement on your own. Note it in your report; the Mac picks a replacement
with the same licence rules.

### Steps 10 and 13: check after download

- **Row 10:** if the backlit face is not visible, mark it as a second silhouette case.
- **Row 13:** if anyone looks under 18, delete the file, record that, and the Mac supplies a
  replacement.
