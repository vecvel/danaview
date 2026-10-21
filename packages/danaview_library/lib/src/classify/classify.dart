// OWNER: HOM-16
//
// The public entry of lib/src/classify/ (ARCH v1.2 §5.1, V2-114): the type table and the
// classifier. The package barrel exports this file; it re-exports the directory's public files.

/// The classifier: the type table (HOM plan §8.1) and `classify(uti?, mime?, fileName)`.
library;

export 'classifier.dart';
export 'type_table.dart';
