// OWNER: HOM-20
//
// Riverpod side of import (ARCH v1.2 §5.6): the import service over the open library store (none
// with DANAVIEW_FILES_HOME off, so the 1.1 screens never see it), the picker and the extra copiers
// the app root installs, and the live queue the import sheet shows. Creating the service resumes
// any import an earlier run left half-done (the app was killed) and sweeps stale staged copies.

import 'dart:async';

import 'package:danaview_library/danaview_library.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../files/library_store_providers.dart';
import 'import_pickers.dart';

/// The picker of the import sheet; the app root overrides it ([NativeImportPicker] on iOS, macOS
/// and Android; [CallbackImportPicker] over `file_selector` on Windows and Linux). Null: the
/// sheet's source buttons are disabled.
final importPickerProvider = Provider<ImportPicker?>((ref) => null);

/// The app-owned staging directory pickers copy into (null: nothing is swept). The app root
/// overrides it with the directory it gives [NativeImportPicker].
final importStagingDirectoryProvider = Provider<String?>((ref) => null);

/// Copiers besides the local-file one ([NativeImportCopier] where the platform hands out URIs).
final importExtraCopiersProvider = Provider<List<ImportCopier>>((ref) => const []);

/// Hooks run for every imported entry (thumbnail request HOM-04, index request AIS-50).
final importHooksProvider = Provider<List<ImportHook>>((ref) => const []);

/// Reads a PDF's page count for the Documents rows (FIX-S3Q-4); the app root overrides it where
/// `danaview_pdf` runs (iOS, macOS, Android). Null: no page count is recorded.
final importPageCounterProvider = Provider<DocumentPageCounter?>((ref) => null);

/// The import service, or null without a library store. Creating it also fills in, in the
/// background, the page counts of PDFs imported before they were recorded.
final importServiceProvider = Provider<ImportService?>((ref) {
  final store = ref.watch(libraryStoreProvider);
  if (store == null || store.readOnly) return null;
  final extra = ref.watch(importExtraCopiersProvider);
  final hooks = ref.watch(importHooksProvider);
  final staging = ref.watch(importStagingDirectoryProvider);
  final countPages = ref.watch(importPageCounterProvider);
  final native = extra.whereType<NativeImportCopier>().firstOrNull;
  final service = ImportService(
    store: store,
    copiers: [const FileImportCopier(), ...extra],
    onImported: hooks,
    release: native == null ? null : (uri) => native.release(uri),
    countPages: countPages,
  );
  ref.onDispose(() => unawaited(service.dispose()));
  unawaited(() async {
    try {
      await service.resumePending();
      if (staging != null) await service.sweepStaging(staging);
      if (countPages != null) await backfillPageCounts(store, countPages);
    } on Object {
      // A store closing during start-up: the next launch resumes.
    }
  }());
  return service;
});

/// The import queue as the sheet shows it (empty without a service).
final importItemsProvider = StreamProvider<List<ImportItem>>((ref) async* {
  final service = ref.watch(importServiceProvider);
  if (service == null) {
    yield const [];
    return;
  }
  yield service.items;
  yield* service.updates;
});
