<!-- OWNER: CORE-29 -->
# RenderPlan v1 contract corpus

Hand-written fixtures decoded by the Dart tests (`test/plan/schema/`), the iOS XCTest suite (IOS-08)
and the Android JUnit suite (AND-08). Every file in this directory is in **canonical form**
(one line, fixed key order, defaults omitted; see `lib/src/plan/plan_json.dart`) so a decoder
that re-encodes must reproduce it byte for byte. Times are integer microseconds on the plan's
`canvas.gridFps` grid (D-35).

| Folder or file | Contract |
|---|---|
| `*.json` (top level) | Valid plans, patches (`from`/`to`) and transients (`item`): schema-valid, validator-clean, byte-identical round trip |
| `grid_cuts_30fps.json` + `.expected_active.json` | Layer edges at frames k ≡ 1 and 2 (mod 3), among them 31, 32, 61 and 62; `expected_active.json` lists the active layer ids for every frame k = 0…89. Decoders map platform times with `frameIndexNearest` before testing activity (IOS-08: instruction lookup at `CMTime(k, 30)`; AND-08: sequence boundaries equal `P(k)`) |
| `invalid/*.json` | Decodable plans that break exactly one invariant of ARCH §11.3. `_expect: {code, id}` names the `PlanViolationCode` and the offending layer, segment or asset id (null for plan-level violations). Native validators must report the same id |
| `invalid_format/*.json` | Documents that cannot be decoded. `_expect: {path}` is the JSON location of the error |
| `tolerant/*.json` | Non-canonical input that decoders must accept: unknown keys everywhere, explicit defaults, `#RRGGBB` colours, integral doubles. They decode to the same value as the canonical sibling named in `test/plan/schema/contract_fixtures_test.dart` |

## Valid corpus

| Fixture | Covers |
|---|---|
| `minimal_preview` | smallest useful plan: one clip, its audio |
| `no_audio_export` | export with an empty `audio` array (no-audio export, D-38) |
| `export_24_from_30`, `export_48_from_24` | `gridFps` ≠ `fps`, LUT asset, sprite with `reveal`, gain 2.0 |
| `grid_cuts_30fps` | D-35 grid cuts, two sequence slots |
| `speed_ramp_multi_segment` | multi-segment maps shared by the video layer and the audio segment, `pitch: false` |
| `reversed_rendition` | increasing map into a reversed rendition asset |
| `hold_pending_still` | `hold: true` plus `req.pendingStill` and `req.pendingReverse` |
| `offline_placeholder` | dark-grey `solid` placeholder plus `req.offline` |
| `transition_cross_dissolve`, `transition_fade`, `transition_dip_to_white`, `transition_slide`, `transition_wipe`, `transition_wipe_down_inverted`, `transition_zoom` | transitions as lowered windows: two layers per `z` with distinct `seq`, `#tx` helper solid, `xf.op`/`xf.cx`/`xf.s` channels, canvas masks with animated `cx`, `cy`, `w`, `h` |
| `effects_every_static_key` | every static key: `xf`, `crop`, `adj`, `detail`, `lut`, `chroma`, `mask`, assets with `bookmark`, `proxyUri`, `rot`, `transfer: hlg/pq`, audio `stream` |
| `anim_every_channel` | every animatable channel except `reveal` |
| `sprites_export_reveal` | text and burned-cue sprites in bands 2 and 3, `reveal` channel, animated scale and opacity |
| `audio_gain_envelopes` | gain 0 … 2.0 (+6 dB), music and voice assets (`content://`), a varispeed segment |
| `backdrop_blur_portrait` | `#bd` backdrop layer, 1080×1920 canvas |
| `image_solid_layers` | image layer (crop, rotation, animated scale) and a translucent solid |
| `overlay_pip_chroma_mask` | overlay band, chroma key, ellipse mask, canvas mask |
| `uhd_60fps` | 3840×2160 at 60 fps |
| `empty_plan` | no assets, layers or audio, `durUs` 0 |
| `patch_structural`, `patch_gain_only`, `patch_header_only`, `patch_assets_only` | patches |
| `transient_all_fields`, `transient_minimal`, `transient_clear_fx`, `transient_move` | transients (empty `fx`/`anim`/`cmasks` clear the layer's value) |
