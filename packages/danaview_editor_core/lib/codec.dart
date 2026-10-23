// OWNER: CORE-01
// EXTENDED: AIS-01 (export lines for the 1.2.0 files)
//
// Public barrel: project document codec, fragment cache, schema versions and migrations
// (ARCH §8.2, §8.5). Pure Dart.

library;

export 'src/codec/fragment_cache.dart';
export 'src/codec/migrations/migrations.dart';
export 'src/codec/project_json.dart';
export 'src/codec/schema_version.dart';

// 1.2.0 (AIS-01, AI_STUDIO_PLAN §3.2).
export 'src/codec/migrations/s1_to_s2.dart';
