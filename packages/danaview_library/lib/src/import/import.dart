// OWNER: HOM-20
//
// The public entry of lib/src/import/: the import pipeline (ARCH v1.2 §5.6, V2-116): the source
// descriptor, the byte copiers (local files on a worker isolate, read-only) and the import queue
// with resume, duplicate rules and hooks, the photo-facts reader and the
// document page count (FIX-S3Q-4) that fill `entry_meta`.

/// The public entry of lib/src/import/: the import pipeline (ARCH v1.2 §5.6).
library;

export 'document_facts.dart';
export 'import_copier.dart';
export 'import_service.dart';
export 'import_source.dart';
export 'photo_facts.dart';
