// OWNER: CORE-01
// EXTENDED: AIS-01 (export lines for the 1.2.0 files)
//
// Public barrel: time, ids and the immutable domain model (ARCH §5, §6). Pure Dart; no dart:io.
// Barrels never change after CORE-01 (BUILD_PLAN §2): a ticket that needs more public files
// re-exports them from one of its own files.

library;

export 'src/ids/ids.dart';
export 'src/model/keyframes/keyframes.dart';
export 'src/model/model.dart';
export 'src/model/pool/pool.dart';
export 'src/time/time.dart';

// 1.2.0 (AIS-01, AI_STUDIO_PLAN §3.2).
export 'src/model/cue_rich.dart';
export 'src/model/subtitle_presets.dart';
