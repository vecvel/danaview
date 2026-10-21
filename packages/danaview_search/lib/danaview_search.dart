// OWNER: INT-101
//
// Public barrel of danaview_search (ARCH v1.2 §5.10, §7.6): the index store (AIS-50), the query
// engine (AIS-51) and the AI search levels (AIS-52, AIS-53). Pure Dart. Each directory has one
// public entry file owned by its ticket, which re-exports that ticket's public files, so this barrel
// never changes after INT-101. Fakes are in `testing.dart`.

library;

export 'src/ai/deep_index/deep_index.dart';
export 'src/ai/filters_contract.dart';
export 'src/index/index.dart';
export 'src/query/query.dart';
