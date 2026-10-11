# Vendored: whisper.cpp

<!-- BEGIN GENERATED (tool/vendor_whisper.sh) -->
<!-- Do not edit between the markers; re-run the script. -->

| Field | Value |
|---|---|
| Upstream | https://github.com/ggml-org/whisper.cpp (MIT) |
| Tag | v1.9.4 |
| Commit | `927cfce34f31707e17f2bff35c349632fb9e2c3a` |
| ggml version | 0.23.0 |
| Tarball | https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v1.9.4.tar.gz |
| Tarball size | 9353438 bytes |
| Tarball sha256 | `57e280cee375ab02425b806ad5146b99f6eb9357e3c2b31357c8a6af2e2e44ae` |
| Vendored on | 2026-10-08 |
| Pruned tree | 194 files, 8145823 bytes (7.77 MiB) under `third_party/whisper.cpp/` |
| Tree digest | `ef776faa224dece8284ccd09da70ae11d683448e67b0798b575ea8e69ad1037a` |

Tree digest = sha256 of the sorted `sha256  ./path` lines of the pruned tree
(`cd third_party/whisper.cpp && find . -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256`).

### Pruning rules

Kept (everything else from the tarball is dropped):

- `CMakeLists.txt`
- `LICENSE`
- `ggml/CMakeLists.txt`
- `ggml/src/CMakeLists.txt`
- `ggml/src/ggml-version.h.in`
- `samples/jfk.wav`
- `bindings/javascript/package-tmpl.json`
- `cmake/` (recursive)
- `include/` (recursive)
- `src/` (recursive)
- `ggml/cmake/` (recursive)
- `ggml/include/` (recursive)
- `ggml/src/ggml-cpu/` (recursive)
- `ggml/src/ggml-metal/` (recursive)
- `ggml/src/ggml-blas/` (recursive)
- `ggml/src/*.{c,cpp,h}` (top level of `ggml/src` only)

Dropped, notably: `examples/`, `tests/`, `bindings/` (except the one template above), `models/`,
`samples/` (except `jfk.wav`), `scripts/`, `ci/`, `.github/`, `.devops/`, `grammars/`, `media/`, docs and
`ggml/src/ggml-{cuda,hip,musa,vulkan,opencl,sycl,cann,hexagon,openvino,rpc,webgpu,zdnn,zendnn,et,virtgpu}`.
`ggml/src/ggml-cpu`, `ggml-metal` and `ggml-blas` are kept whole. Selecting a pruned backend at configure time fails.
<!-- END GENERATED -->

## Local changes

None. `third_party/whisper.cpp/` is a byte-for-byte subset of the upstream tarball; never edit it by hand.
Fixes go upstream or into the shim (`src/`), and a re-vendor must reproduce the tree exactly:

    tool/vendor_whisper.sh --check      # downloads the tarball, verifies sha256 + commit, diffs the tree

Measured numbers differ slightly from the early estimate in ai.md §4.2 (192 files / 7.8 MB): the tree is
194 files / 7.77 MiB because it also needs `ggml/src/CMakeLists.txt`, `ggml/src/ggml-version.h.in`
(configure_file) and `bindings/javascript/package-tmpl.json` (see below).

Notes on the pruning:

- Top-level `CMakeLists.txt` does `configure_file(bindings/javascript/package-tmpl.json ...)` whenever whisper.cpp
  is the top-level project (our `ExternalProject_Add` builds, ai.md §4.3/§4.4). That one template is kept and the
  generated `package.json` is git-ignored (`third_party/.gitignore`).
- `tests/` and `examples/` are pruned, but `WHISPER_BUILD_TESTS` / `WHISPER_BUILD_EXAMPLES` / `WHISPER_BUILD_SERVER`
  default to ON for a standalone top-level build. Every build of this tree must pass them `OFF` (the option sets in
  ai.md §4.3/§4.4 already do), otherwise configure fails on `add_subdirectory(tests|examples)`.
- ggml's own tests/examples are guarded by `GGML_STANDALONE`, which is OFF when ggml is added from whisper.cpp.
- Only the CPU, Metal and BLAS backends are kept. GPU backends we do not ship (CUDA, Vulkan, OpenCL, ...) are gone,
  so enabling one fails at configure time instead of silently doing something else.
- `src/coreml/`, `src/openvino/`, `src/vitisai/` are kept inside `src/` (CMake references them); they stay disabled.
- `cmake/FindFFmpeg.cmake` (BSD-licensed, used only by upstream examples) comes along with the whole `cmake/`
  directory; see `LICENSE-THIRD-PARTY.md`.

Verification status (AI-01 acceptance): `--check` reproduces the tree with no diff. A CMake configure + build of
libwhisper with the ai.md §4.3 and §4.4 option sets (V-A9) was NOT run here, because CMake is not installed on the
machine that vendored it; the build tickets AI-04 (Android) and AI-05 (iOS) run it first. A static review of every
`add_subdirectory` / `configure_file` / `include()` in the kept CMake files found no reference to a pruned path
other than the guarded `tests` / `examples` ones above.

## Upstream review: v1.9.5 (decision: stay on v1.9.4)

- Released 2026-10-06, tag commit `d1be6fde11ac6e0407606b4e42fe72d34add8037`, "Maintenance release", ggml 0.23.0 -> 0.26.0.
- Range v1.9.4...v1.9.5 is 324 commits, 300 changed files. Reviewed with the GitHub release notes and compare API
  (metadata only, read on 2026-10-08; the v1.9.5 source was not downloaded). 92 changed files fall inside the pruned
  tree, so it is not a patch-level bump. Most upstream commits are for backends we prune (CUDA, Vulkan, OpenCL, SYCL,
  Hexagon, HIP, WebGPU, OpenVINO).
- What matters to us:
  - Metal (iOS, ai.md §4.4): flash-attention kernels were split into per-dtype files/libraries and `fa.metal` removed,
    new `ggml-metal-fusion.*`, new `mul_mv_mma.metal`; Metal-side fixes (NaN in `mul_mm_id`, FA mask bounds, bf16 math,
    macOS 27 SDK deprecation warnings). Our embedded-Metal-library build (AI-05) and the iOS >= 16.4 / GPU family >= 6
    gating are designed against the v1.9.4 layout.
  - CPU (Android NEON, §4.3): new `ggml-cpu/tiled/` sources, `ggml-cpu/iqp.*` removed, new Arm repack kernels, k-quant
    tiled mul_mat. These touch exactly the code the two-shim `armv8-a` / `armv8.2-a+fp16+dotprod` design builds.
  - ggml core: backend/allocator API changes (`alloc_buffer_n`, graph input collection, "model loading faster"),
    integer-overflow and bounds fixes in gguf and `ggml_permute`.
  - whisper: fix int overflow in `whisper_full_parallel` chunk offsets (#4044, we do not use parallel mode),
    `abort_callback` now honoured during language detection (#4077; relevant to cancel latency, see below),
    VAD model-load validation (#4064), tensor-type check at model load (#4091), optional ANEForge encoder backend
    (#3905, not used).
- Why v1.9.4 stays: it is the version ai.md and ARCH §16.1 were designed and measured against (Metal layout, CPU
  option sets, 7.8 MB tree, pinned ABI), v1.9.5 is a week old with a three-minor-version ggml jump and no soak
  time, and none of its whisper-level changes block the feature. Bumping now would invalidate the AI-04/AI-05 option
  sets and the eval baselines before they exist.
- Follow-ups (not blocking AI-01): (1) language detection on v1.9.4 does not poll `abort_callback`; the shim must
  run detection on a short slice (<= 30 s, one encoder pass) so cancel latency stays bounded, or pick up #4077 when
  we re-pin. (2) Re-evaluate v1.9.5 (or newer) after a soak and a re-run of the ai.md §16 eval suite: run
  `tool/vendor_whisper.sh v1.9.5 d1be6fde11ac6e0407606b4e42fe72d34add8037` with `VW_WHISPER_SHA256` set to the
  reviewed tarball hash, update `PIN_*` in the script, ai.md §4.2 and ARCH §16.1, then rerun AI-04/AI-05 builds.
