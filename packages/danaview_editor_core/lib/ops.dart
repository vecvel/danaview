// OWNER: CORE-01
// EXTENDED: AIS-01 (export lines for the 1.2.0 files)
//
// Public barrel: editing commands, rejections, outcomes, clipboard, selection, snapping and the
// snapshot-history session (ARCH §7). Pure Dart.

library;

export 'src/ops/clipboard.dart';
export 'src/ops/dry_run.dart';
export 'src/ops/edit_command.dart';
export 'src/ops/edit_context.dart';
export 'src/ops/limits.dart';
export 'src/ops/outcome.dart';
export 'src/ops/placement.dart';
export 'src/ops/rejections.dart';
export 'src/ops/requantize.dart';
export 'src/ops/selection.dart';
export 'src/ops/snapping.dart';
export 'src/session/session.dart';

// 1.2.0 (AIS-01, AI_STUDIO_PLAN §3.2).
export 'src/ops/speech_snap.dart';
