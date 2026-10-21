// OWNER: CORE-01
// EXTENDED: AIS-01 (export lines for the 1.2.0 files)
//
// Public barrel: evaluation, geometry, time maps, transition limits, visual packing and the
// project validator (ARCH §6.4, §6.7, §6.9, §11.6, §13.5). Pure Dart.

library;

export 'src/eval/clip_time_map.dart';
export 'src/eval/evaluate.dart';
export 'src/eval/geometry.dart';
export 'src/eval/speed_math.dart';
export 'src/eval/text_animation_eval.dart';
export 'src/eval/text_layout_spec.dart';
export 'src/eval/transition_limits.dart';
export 'src/eval/visual_packing.dart';
export 'src/validate/validate.dart';

// 1.2.0 (AIS-01, AI_STUDIO_PLAN §3.2).
export 'src/eval/cue_text_ops.dart';
export 'src/eval/karaoke_eval.dart';
