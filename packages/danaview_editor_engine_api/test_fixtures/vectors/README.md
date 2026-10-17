<!-- OWNER: API-03 -->
# Render-math, keyframe and audio vectors

Shared vectors of ARCH §11.6 (render math), §5 / D-35 (frame mapping), §11.1 (keyframes), §11.7
(fades, crossfades, typewriter) and the D-37 audio gain row. They are **generated** by
`packages/danaview_editor_engine_api/tool/regen_goldens.dart` from the Dart reference implementation
(core geometry and evaluation plus `lib/src/math/`) and read by:

| Reader | Files |
|---|---|
| Dart (`test/reference/`) | all; also replays every file from the JSON alone, the way a foreign reader does |
| core joint test (`test/reference/joint_core_vectors_test.dart`) | `keyframes.json`, `transform.json`, `typewriter.json` against core `FrameRate`, `evaluate`, `boxAt`, `evaluateTextAnimation` |
| iOS (IOS-08 ParamSnapshot, IOS-09 kernels on 8×8 images, IOS-18 gain tap) | `keyframes.json`, `render_math.json`, `luts/`, `gain.json`, `typewriter.json` |
| Android (AND-08, AND-09) | same as iOS |
| QA-03 / QA-11 | `text_scale_8x.json`, `audio_mix.json`, `gain.json` |

Never edit these files by hand: change the inputs in
`lib/src/reference/fixtures/reference_vectors.dart`, run `dart run tool/regen_goldens.dart` and review
the diff. `dart run tool/regen_goldens.dart --check` (and `test/reference/regen_check_test.dart`)
fail when the committed files are stale.

## Conventions (all files)

- UTF-8 JSON, two-space indentation, arrays of numbers on one line. Unknown keys must be ignored.
- Every file starts with `schema` (1), `generatedBy`, `spec` (the ARCH sections) and `rule` (the
  formula in one paragraph).
- Times are integer µs; frame rates are integers. A **frame k** of rate `fps` starts at
  `timeOfFrame(k) = ceil(k·10⁶/fps)`; a platform time τ maps to `k = floor((τ·fps + 500000)/10⁶)`
  (`frameIndexNearest`, D-35).
- Real numbers are rounded to 1e-9. Colours are `[r, g, b, a]` in [0, 1], gamma-encoded BT.709, no
  colour management. `space` says whether RGB is straight or premultiplied by alpha.
- `tol` is the CPU (double) tolerance. Float32/half-float GPU implementations compare with the
  ARCH §11.6 parity tolerance (mean |Δ| ≤ 1.5/255, 99th percentile ≤ 6/255 per channel).

## keyframes.json

`cases[]`: `{name, channel (plan anim channel), property (domain property id), fps, itemStartUs,
itemDurationUs, keys: [[tUs, v], …] (absolute µs), samples: [{k, tau, t, v}]}`. For each sample:
`frameIndexNearest(tau) == k`, `t == timeOfFrame(k)` and the channel (linear between keys, held
outside) evaluates to `v` at `t`. `tau` is `floor(k·10⁶/fps)`, up to 1 µs before the plan edge, so a
reader that evaluates at the raw platform time fails. As item-local domain keyframes
(`local = tUs − itemStartUs`) the same keys give `v` at `t − itemStartUs`.

## transform.json

`cases[]`: `{name, canvas: [W, H], domain: {aspect, baseShortSide, source: [w, h], fit, crop: [l, t, r, b],
position: [x, y], scale, rotation, flipH, flipV}, base: [w, h], xf: {cx, cy, s, r, fx, fy},
M: [a, b, c, d, tx, ty], points: [{local: [x, y], canvas: [x, y]}]}`.
`M = T(cx, cy)·R(r° clockwise, y down)·S(s·(fx ? −1 : 1), s·(fy ? −1 : 1))·T(−base.w/2, −base.h/2)` maps
base-local `(x, y)` to `(a·x + c·y + tx, b·x + d·y + ty)`. `points` are the four corners, the centre and
`(0.25·w, 0.75·h)`. Domain: `base = baseSize(fit, crop, source, canvas)`,
`(cx, cy) = (W/2 + position.x·W, H/2 + position.y·H)`.

## render_math.json

`luts`: named tables `{n, rgb: [n³·3 floats, red fastest]}` or `{n, file}` (a `.vlut` under `luts/`).

`rows[]`: one stage on a `w × h` (8 × 8) image:

| Key | Meaning |
|---|---|
| `stage` | see below |
| `space` | `straight` or `premultiplied` |
| `params` | stage parameters in plan units (ARCH §11.2) |
| `in` / `inImage` | uniform input texel, or `w·h` texels row-major |
| `out` / `outImage` | uniform expected texel, or `w·h` texels row-major |

| `stage` | `params` | Formula (ARCH §11.6) |
|---|---|---|
| `chromaKey` | `key "#RRGGBB", sim, smooth, spill` | `Cb = (B−Y)/1.8556`, `Cr = (R−Y)/1.5748`; `a = smoothstep(sim·0.25, sim·0.25 + max(0.001, smooth·0.25), ‖CbCr − key‖)`; spill `CbCr −= k·max(0, dot(CbCr, k))·spill` with `k = normalize(key CbCr)`, RGB rebuilt keeping Y **then clamped to [0, 1]**; `alpha *= a` |
| `exposure` | `exposure` | `pow(pow(c, 2.2)·2^(2·exposure), 1/2.2)` |
| `brightnessContrast` | `brightness, contrast` | `c += b/4`; `c = (c − 0.5)·(1 + contrast) + 0.5` (no clamp) |
| `highlightsShadows` | `highlights, shadows` | `c += h/4·smoothstep(0.5, 1, Y) + s/4·(1 − smoothstep(0, 0.5, Y))`, Y of the input (no clamp) |
| `saturation` | `saturation` | `mix(Y, c, 1 + s)` (no clamp) |
| `temperatureTint` | `temperature, tint` | `r *= 1 + t/10`, `b *= 1 − t/10`, `g *= 1 − tint/10`, clamp [0, 1] |
| `grade` | `adj {exposure … tint}` | the five steps above in order |
| `lut` | `lut` (name in `luts`), `i` | trilinear lookup of `clamp(c, 0, 1)`; `mix(c, lut(c), i)`; alpha unchanged |
| `gaussianBlur` | `sigma` (px of this image) | separable, weights `exp(−x²/2σ²)` for `x = −⌈3σ⌉…⌈3σ⌉`, normalized; clamp-to-edge; all four **premultiplied** channels; skipped (identity) when σ < 0.5 |
| `sharpen` | `amount` | premultiplied RGB `+= amount·1.5·(c − box3×3(c))` (clamp-to-edge box), clamped to [0, alpha]; alpha unchanged |
| `vignette` | `amount, aspect` | RGB `*= 1 − amount·smoothstep(0.35, 1, d)`, `d = ‖(uv − 0.5)·(aspect, 1)‖ / ‖(aspect, 1)·0.5‖`, `uv = ((x + 0.5)/w, (y + 0.5)/h)` |
| `mask` | `mask {shape, cx, cy, w, h, r, corner, feather, op, inv}`, `base [bw, bh]` | in **base px**: `p = R(−r)·((u − cx)·bw, (v − cy)·bh)`, half `(w·bw/2, h·bh/2)`; rect: rounded-box SDF with radius `corner·min(w·bw, h·bh)`; ellipse: `(‖p/half‖ − 1)·min(half)`; `f = feather·0.25·min(w·bw, h·bh)`; `a = 1 − smoothstep(−f, f, sd)` or `sd < 0 ? 1 : 0` when f = 0; `inv → 1 − a`; all premultiplied channels `*= mix(1, a, op)` |
| `canvasMask` | `cmask {cx, cy, w, h, r, feather, inv}` | the rect SDF (no corner) at canvas px `(x + 0.5, y + 0.5)`, `f = feather` px; inverted when `inv`; premultiplied channels `*= a` |
| `place` | `base, xf, M` | onto a transparent 8 × 8 canvas: pixel centre `p` → `M⁻¹·p` → `(u, v) = local/base`; inside `[0, 1)²` sample `inImage` bilinearly (texel centres at `i + 0.5`, clamp-to-edge) at `(u·8, v·8)`, `× xf.op`, source-over |
| `composite` | `dst` (premultiplied) | `in + dst·(1 − in.a)` |
| `spriteReveal` | `reveal` (null = not animated), `glyphs` (64 ids, 65535 = background) | a texel is drawn iff `reveal == null` or `glyph < floor(reveal)`; hidden texels become transparent |

`scalars`: `blurSigma` (σ in canvas, source and render px, `⌈3σ⌉` radii and skip flags),
`gaussianKernel` (normalized weights), `vignetteFactor`, `maskAlpha` / `canvasMaskAlpha` (single
points, bigger bases), `toByte` (`round(clamp(v, 0, 1)·255)`).

## gain.json

`envelopes[]`: `{name, keys: [[tUs, g], …], samples: [{i, tUs, g, db, ideal?, errDb?}]}`. Output
sample `i` (48 kHz, counted from timeline 0) is at `tUs = i·10⁶/48000` (exact rational, no ε); `g` is
the envelope there (linear, held outside) and `db = 20·log10(g)`. `boost_200pct` is +6.0206 dB. The
equal-power envelopes are `cos`/`sin(π·x/2)` sampled every 20 ms as the compiler lowers them;
`ideal` is the curve and `errDb` the sampling error (≤ 0.1 dB, ARCH §11.7). `db[]` lists
conversions.

## audio_mix.json

`cases[]`: `{name, description, plan (a canonical RenderPlan v1 object), sources, omitted?, startUs,
endUs, frames, windowSamples (960 = 20 ms), windows: [[rmsDbL, rmsDbR, peakL, peakR]], samples: [{i, l, r}]}`.
`sources` maps asset ids to `{type: "tones", durUs?, channels: [{freqHz, amplitude, phase} | null]}`:
channel `c` at source time `s` µs is `amplitude·sin(2π·freqHz·s/10⁶ + phase)` inside `[0, durUs)`.
The mix: for each sample `i` at `t = startUs + i·10⁶/48000`, every segment with `t0 ≤ t < t1` reads
its source at `s = s0 + (t − t0)·(s1 − s0)/(t1 − t0)` (varispeed), downmixes to stereo (mono
duplicated; 3–8 channels with ITU −3 dB for C and surrounds, LFE dropped; see `AudioMath.downmixMatrix`),
multiplies by `gain(t)`, sums and hard-clips to [−1, 1]. Window levels are `20·log10(RMS)` floored
at −120 dBFS (no +3 dB sine correction).

`three_lane_reference` is the QA-11 project: main lane A → B with a 400 ms equal-power cross
dissolve, music at 40 % with 1 s fades, voice with volume keyframes 100 → 200 → 50 → 100 %. The lanes
under `omitted` (one muted, one soloed out) are absent from the lowered plan; on a device their
tones must stay below −60 dBFS. Engines with `pitch: true` time-stretch instead of resampling; tone
RMS is unaffected, so the windows stay valid (pitch is checked by QA-11's FFT test instead).

## typewriter.json

`cases[]`: `{name, text, graphemes, fps, itemStartUs, itemDurationUs, inDurationUs, channel: [[t, v]],
frames: [{k, t, reveal, shown}]}`. The compiler's `reveal` channel is `[[start, 0], [start + in, n]]`;
`shown = floor(reveal(timeOfFrame(k)))` glyphs; a sprite texel of glyph `g` is drawn iff `g < shown`.

## text_scale_8x.json

The 8× scale-keyframed text parity case (ARCH §10.3): `plan` (relative path of the golden plan),
`layer`, `sprite {sw, sh, sscale}`, `output [w, h]`, `renderScale`, and per golden frame
`{k, t, xf.s, xf.r, M, texelsPerOutputPx, png}`. The PNGs are in `../images/goldens/`.

## luts/

`synthetic_17.vlut`: `.vlut` v1 (ARCH §10.2) of the synthetic warm/teal grade used by the `lut`
rows named `n17_synthetic_file` (and, at other sizes, by the golden plans).
