// OWNER: INT-101
//
// Public barrel of danaview_library (ARCH v1.2 §4.3, §5): item model, classifier, library.db,
// Danaview folders and Recently deleted, references, import, inbox, organise, file actions and
// desktop discovery. Pure Dart. Each directory has one public entry file owned by its ticket, which
// re-exports that ticket's public files, so this barrel never changes after INT-101. Fakes are in
// `testing.dart`.

library;

export 'src/actions/actions.dart';
export 'src/classify/classify.dart';
export 'src/db/db.dart';
export 'src/desktop/desktop.dart';
export 'src/import/import.dart';
export 'src/inbox/inbox.dart';
export 'src/model/document_item.dart';
export 'src/model/file_entry.dart';
export 'src/model/file_kind.dart';
export 'src/model/ids.dart';
export 'src/model/media_item.dart';
export 'src/model/media_ref_bridge.dart';
export 'src/model/source_hint.dart';
export 'src/organise/organise.dart';
export 'src/refs/refs.dart';
export 'src/store/store.dart';
