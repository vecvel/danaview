// OWNER: INT-101
//
// Public barrel of Still Photo Mode in the core (ARCH v1.2 §4.4, §5.7, §6.2): photo recipes, still
// lowering, colour (recipe LUT, HSL, curves), geometry, masks, overlays, export, presets and batch,
// and the photo-clip lowering of the timeline. Pure Dart; no dart:io (ARCH v1.2 rule 25).
//
// Barrels never change after INT-101: a ticket that needs more public files re-exports them from one
// of its own files exported here (VED-02 from photo/model/model.dart and photo/codec/codec.dart,
// and so on).

library;

export 'src/color/curves/curves.dart';
export 'src/color/hsl/hsl.dart';
export 'src/color/recipe_lut.dart';
export 'src/photo/batch/batch.dart';
export 'src/photo/codec/codec.dart';
export 'src/photo/color_space.dart';
export 'src/photo/export/export.dart';
export 'src/photo/geometry/geometry.dart';
export 'src/photo/ken_burns.dart';
export 'src/photo/lowering/stages.dart';
export 'src/photo/lowering/still_compiler.dart';
export 'src/photo/masks/masks.dart';
export 'src/photo/metadata_policy.dart';
export 'src/photo/model/model.dart';
export 'src/photo/overlays/overlays.dart';
export 'src/photo/presets/presets.dart';
export 'src/photo/tone/tone.dart';
export 'src/plan/lowering_photo_clip.dart';
