<!-- Scaffold stub; owners: AI-01 (vendoring), AI-02 (package, C ABI), AI-03 (shim), AI-04/AI-05 (native builds), AI-06 (device channel), AI-07 (runtime). -->
# danaview_whisper

FFI plugin (iOS + Android only) exposing on-device whisper.cpp through the C ABI in
`src/dv_whisper.h` (version 1; ai.md §4.5, with `dv_model_get_state` renamed from the design's
`dv_model_state`, which collided with the enum typedef). Bindings: `dart run ffigen --config
ffigen.yaml` → `lib/src/ffi/dv_whisper_bindings.g.dart` (committed). See `third_party/README.md`.
