// OWNER: API-03
//
// Render math of ARCH §11.6 (normative restatement: danaview_editor_core `schema/effects_reference.md`):
// every per-layer stage on straight-alpha gamma-encoded BT.709 values, the layer parameter
// snapshot, LUT tables, a float raster and the audio gain math. Implemented identically by the
// Metal kernels (IOS-09), the GLSL shaders (AND-09) and the Dart reference renderer
// (`../reference/`, exported from `lib/testing.dart`).

library;

export 'audio_math.dart';
export 'layer_params.dart';
export 'lut_table.dart';
export 'raster.dart';
export 'render_math.dart';
