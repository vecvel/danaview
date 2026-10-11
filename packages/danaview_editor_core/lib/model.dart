// OWNER: CORE-01
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
