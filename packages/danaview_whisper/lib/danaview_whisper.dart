// OWNER: AI-02
//
// On-device whisper.cpp for Danaview Auto captions (ARCH §16.1). Public API only; the generated FFI
// bindings stay private to the package.

library;

export 'src/device/device.dart';
export 'src/runtime/runtime.dart';
export 'src/support.dart';

/// The C ABI version this Dart package was generated against (`DV_ABI_VERSION`).
const int dvAbiVersion = 1;
