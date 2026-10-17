<!-- OWNER: AI-01 -->
# Third-party licences (danaview_whisper)

`danaview_whisper` ships the sources below inside this package (`third_party/whisper.cpp/`, a pruned copy of
whisper.cpp v1.9.4, commit `927cfce34f31707e17f2bff35c349632fb9e2c3a`; see `third_party/VENDORED.md`).
The licence texts are reproduced here so that binary distributions of the app can include them
(app-level "Open source licences" screen).

Speech models are **not** part of this package or of the app binary. They are downloaded on first use after
consent, each under its own licence, which the app shows next to the model.

## whisper.cpp and ggml (MIT)

Source: https://github.com/ggml-org/whisper.cpp (whisper.cpp, and the ggml tensor library it bundles under `ggml/`).
Both are covered by one licence file, `third_party/whisper.cpp/LICENSE`:

```
MIT License

Copyright (c) 2023-2026 The ggml authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Code with its own notice inside the vendored tree

All of it is MIT (or MIT-compatible), carries its notice in the source file, and is covered by the vendored
tree's own headers; listed here for completeness.

| Path | Notice |
|---|---|
| `ggml/src/ggml-cpu/llamafile/sgemm.{cpp,h}` | MIT, Copyright 2024 Mozilla Foundation (tinyBLAS / llamafile). Compiled into the CPU backend. |
| `ggml/src/ggml-cpu/kleidiai/*` | MIT, SPDX-FileCopyrightText: Copyright 2025-2026 Arm Limited and/or its affiliates. Present in the tree but **disabled** in our builds (`GGML_CPU_KLEIDIAI=OFF`). |
| `ggml/src/ggml-cpu/ops.cpp`, `ggml/src/ggml-metal/kernels/rope.metal` | RoPE YaRN helpers, MIT, Copyright (c) 2023 Jeffrey Quesnelle and Bowen Peng. |
| `ggml/include/ggml-sycl.h` | MIT, Copyright (C) 2024 Intel Corporation. Header only; the SYCL backend is pruned. |
| `cmake/FindFFmpeg.cmake` | BSD licence, Copyright (c) 2006 Matthias Kretz, 2008 Alexander Neundorf, 2011 Michael Jansen (via snikulov/cmake-modules). CMake find-module only; never used by our builds and never shipped in a binary. |

## Test audio

`third_party/whisper.cpp/samples/jfk.wav` is a US-government (public domain) speech excerpt. It is used only by
tests and is not part of any shipped binary.
