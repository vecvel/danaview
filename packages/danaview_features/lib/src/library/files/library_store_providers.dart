// OWNER: HOM-17
//
// Riverpod providers of the library store (ARCH v1.2 §5.2–§5.4). The app root opens the store with
// [openDanaviewLibraryStore] (behind DANAVIEW_FILES_HOME) and overrides [libraryStoreProvider];
// with the flag off nothing opens it and every provider here yields null or empty, so the 1.1
// screens are untouched. [libraryRevisionProvider] ticks after every write, so folder screens,
// filters and the Settings sizes re-read in the same frame.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_library/danaview_library.dart';

export 'package:danaview_library/danaview_library.dart'
    show
        BackupFlagPort,
        FileKind,
        ImportedFileInfo,
        LibraryRootStyle,
        LibraryStorageUsage,
        LibraryStore,
        NoBackupFlagPort,
        TrashedItem,
        daysLeftUntil,
        libraryRootIn;

/// Opens the library under the platform's application-support directory [supportDir]
/// (`Library/Application Support` on iOS and macOS, `filesDir` on Android): the root is
/// `DanaviewLibrary/` there, `library/` on Android (ARCH §5.2). [backup] is the adapter of the
/// native plugin's backup-flag API (HOM-02); the default keeps everything included.
Future<LibraryStore> openDanaviewLibraryStore({
  required String supportDir,
  required LibraryRootStyle style,
  BackupFlagPort backup = const NoBackupFlagPort(),
}) =>
    LibraryStore.open(root: libraryRootIn(supportDir, style), backup: backup);

/// The open library store, or null (flag off, or not opened yet). The app root overrides it.
final libraryStoreProvider = Provider<LibraryStore?>((ref) => null);

/// Counts the writes since the store opened (0 without a store).
final libraryRevisionProvider = StreamProvider<int>((ref) async* {
  final store = ref.watch(libraryStoreProvider);
  var revision = 0;
  yield revision;
  if (store == null) return;
  await for (final _ in store.changes) {
    yield ++revision;
  }
});

/// Library sizes for Settings › Library storage (null without a store).
final libraryStorageUsageProvider = Provider<LibraryStorageUsage?>((ref) {
  final store = ref.watch(libraryStoreProvider);
  if (store == null) return null;
  ref.watch(libraryRevisionProvider);
  return store.reader.storageUsage();
});

/// The Recently deleted rows, newest deletion first (empty without a store).
final recentlyDeletedProvider = Provider<List<TrashedItem>>((ref) {
  final store = ref.watch(libraryStoreProvider);
  if (store == null) return const [];
  ref.watch(libraryRevisionProvider);
  return store.reader.recentlyDeleted();
});
