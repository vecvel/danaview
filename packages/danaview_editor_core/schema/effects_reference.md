<!-- OWNER: CORE-29. Normative together with render_plan.v1.schema.json; must agree with ARCH §11.6. -->
# RenderPlan v1: render math reference

Implemented identically by the Metal Core Image kernels (iOS, IOS-09/IOS-10), the GLSL ES 1.00
shaders (Android, AND-09/AND-17) and the Dart CPU reference renderer (API-03). Parity tolerance
against the Dart reference and between platforms: mean absolute error ≤ 1.5/255 per channel,
99th percentile ≤ 6/255, SSIM ≥ 0.98 on transform fixtures with edge pixels excluded.

## 1. Which frame is rendered (D-35)

1. An output frame's platform time τ (iOS `compositionTime`, item time, output-buffer PTS; Media3
   effect/compositor `pts`, `onVideoFrameAboutToBeRendered` pts) becomes
   `k = frameIndexNearest(τ) = floorDiv(τ·fps + 500000, 1000000)` for the **output** rate.
2. Every evaluation uses `t = timeOfFrame(k) = ceil(k·10⁶/fps)`: layer activity `t0 ≤ t < t1`,
   Android gating, `anim` channels, `reveal`, `ParamSnapshot` lookup, seek acks.
3. Plans carry `canvas.gridFps` (the project rate). Layer edges, map breakpoints, audio edges and
   `durUs` lie on the `gridFps` grid; output frames on the `fps` grid.

## 2. Sampling

- Media layer at timeline time `t` ∈ `[t0, t1)`: on the containing segment
  `s = s0 + (t − t0)·(s1 − s0)/(t1 − t0)`. The displayed source frame is the sample with the
  **greatest PTS ≤ s + 500 µs** (PTS on the presentation timeline with edit lists applied, D-04).
  `hold: true` uses `s = map[0].s0` for the whole range. Images ignore `map`.
- Audio: sample-accurate `s(t)` with no ε. A clip's video layer and audio segment share map
  boundaries (A/V sync ≤ 1 frame and ≤ 20 ms on export).
- Mixed-rate sources: iOS floor, Android nearest; each platform is consistent between preview and
  export.

## 3. Colour space

All maths runs on **straight-alpha, gamma-encoded BT.709 RGB in [0, 1]** with colour management
off (iOS `CIContext` working/output colour space `NSNull`; Android `WORKING_COLOR_SPACE_ORIGINAL`).
HDR sources arrive tone-mapped to SDR. `Y(c) = dot(c, (0.2126, 0.7152, 0.0722))`. Values are the
plan's model units: `adj` ∈ [−1, 1]; `detail`, `chroma`, `mask`, `lut.i` ∈ [0, 1].

## 4. Per-layer order (D-08)

**sample → crop → chroma key + spill → grade → LUT → blur → sharpen → vignette → mask → place →
canvas masks → composite.** Sprites and solids skip crop through mask.

| Stage | Formula |
|---|---|
| Crop | sample the normalized, display-oriented source rectangle `[l, t, r, b]` |
| Chroma key | `Cb = (B − Y)/1.8556`, `Cr = (R − Y)/1.5748` for pixel and key; `d = ‖(Cb, Cr) − (Cbk, Crk)‖`; `a = smoothstep(s0, s0 + s1, d)` with `s0 = sim·0.25`, `s1 = max(0.001, smooth·0.25)`; `alpha *= a` |
| Spill | `k = normalize(Cbk, Crk)`; `(Cb, Cr) −= k·max(0, dot((Cb, Cr), k))·spill`; rebuild RGB keeping Y |
| Exposure | `c = pow(pow(c, 2.2)·exp2(2·exposure), 1/2.2)` (±2 EV) |
| Brightness, contrast | `c += brightness/4`; `c = (c − 0.5)·(1 + contrast) + 0.5` |
| Highlights, shadows | `c += highlights/4 · smoothstep(0.5, 1, Y)`; `c += shadows/4 · (1 − smoothstep(0, 0.5, Y))` |
| Saturation | `c = mix(vec3(Y), c, 1 + saturation)` |
| Temperature, tint | `c.r *= 1 + temperature/10`; `c.b *= 1 − temperature/10`; `c.g *= 1 − tint/10`; then `clamp(c, 0, 1)` |
| LUT | trilinear lookup in the N³ `.vlut` table (tiled 2D texture: N tiles of N×N in a ⌈√N⌉ grid); `c = mix(c, lut(c), i)` |
| Blur | separable Gaussian, `σ = blur·0.03·min(W, H)` in **plan-canvas px**, converted to source px by the layer's current scale and to render px by the render scale; radius `ceil(3σ)`, clamp-to-edge; skipped when σ < 0.5 |
| Sharpen | `c += sharpen·1.5·(c − box3x3(c))` at render resolution, clamp |
| Vignette | `d = ‖(uv − 0.5)·(aspect, 1)‖ / ‖(aspect, 1)·0.5‖` over the layer box; `c *= 1 − vignette·smoothstep(0.35, 1, d)` |
| Mask | signed distance `sd` of a rotated rounded box (`corner` = fraction of min(w, h)) or an ellipse in layer-normalized space over `base`; `f = feather·0.25·min(w, h)`; `a = 1 − smoothstep(−f, f, sd)` (step when f = 0); `inv → 1 − a`; `alpha *= mix(1, a, op)` |
| Place | rotate the source to display orientation (`rot`), crop, scale to `base`; `M = T(cx, cy)·R(r° clockwise, y down)·S(s·(fx ? −1 : 1), s·(fy ? −1 : 1))·T(−base.w/2, −base.h/2)`; `alpha *= op`. Dart `boxAt` (CORE-07) uses the same M |
| Canvas mask | the Mask SDF evaluated in canvas px after placement (`feather` in px); multiplies alpha |
| Composite | premultiplied source-over, bottom → top in (`z`, `t0`) order, onto the opaque `bg` |
| Sprite | premultiplied RGBA8 (sRGB-encoded) sampled with M at `sscale`; if `reveal` is animated, a pixel is drawn iff `glyph < floor(reveal(t))` |

## 5. Audio

`out = Σ seg(t)·gain(t)`, `gain` linearly interpolated (0–2, i.e. up to +6.02 dB) and applied
**per sample** (iOS `MTAudioProcessingTap`, D-37; Android `GainProcessor`). 48 kHz stereo; mono is
duplicated; more than two channels are downmixed with ITU coefficients. The mix is hard-clipped to
[−1, 1] (no limiter in v1; the iOS export pump clamps Float32 samples before AAC). `pitch: true`
time-stretches keeping pitch (iOS `.spectral`, Android Sonic `shouldMaintainPitch`); `false`
resamples (varispeed). Every export carries an AAC 48 kHz stereo track, silent when nothing is
audible (D-38).

## 6. Z order

`z = band·10000 + (laneIndexInBand + 1)·10 + sub`; bands video 0, overlay 1, text 2, subtitle 3;
`sub` 0 for clip layers, +5 for transition helper solids, −5 for `#bd` backdrops. Engines treat
`z` as an opaque sort key; within one `z` a later `t0` draws on top. `seq` (media layers only) is
the visual sequence / composition-track slot from core packing (CORE-36, ARCH §13.5); layers
sharing a `seq` never overlap in time.
