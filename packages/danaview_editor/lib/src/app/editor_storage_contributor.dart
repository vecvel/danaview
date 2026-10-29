// OWNER: UX-04
//
// The editor's Settings › Storage contributors (ARCH §17.10, ux.md §4.8, D-17):
//
// * "Video editor projects": bytes from `ProjectRepository.storageReport()` (bundles, managed copies
//   and reversed renditions), re-measured whenever the project list changes. No clear action:
//   projects are deleted in the Projects screen, which the row opens.
// * "Editor cache": the regenerable folders under `<cache>/danaview/editor` (thumbs, waves, proxies,
//   sprites, looks, and the render-preview files in renders/, D-45; ARCH §8.1). Clearing asks the
//   engine to drop its caches, then deletes the folders' contents through `OwnedFileDeleter` (the
//   only delete path, D-44). It never touches `work/` (in-progress picks, drops and exports) or
//   anything under `<support>` (projects and media), and it is disabled while a project is open or a job runs. The contributor owns the whole
//   `<cache>/danaview/editor` folder, so the app's own "Clear cache" leaves it alone.
// * "Export files" (FIX-QA05-D8-2): `<support>/danaview/editor/exports`, where exports are written
//   before they are saved. Clearing runs `ExportOutputSweeper.clear`: every file no export job
//   references (running, resumable, kept or detached records, and the export flow's own files) is
//   deleted, whatever its age; it is blocked like the cache while a project is open or a job runs.
//
// The router (INT-02) builds them through [EditorStorageContributor.all] and lists them in
// `storageContributorsProvider` on iOS/Android only (D-17).

import 'dart:async';
import 'dart:isolate';

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:danaview_editor_core/store.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_features/storage.dart';
import 'package:danaview_transcription/danaview_transcription.dart' show TranscriptionService;

import 'export_output_sweeper.dart';
import 'strings/settings_strings.dart';

/// What keeps the editor cache in use (ARCH §17.10: clearing is disabled while a session or job is
/// active).
enum EditorCacheUse {
  /// Nothing: the cache may be cleared.
  none,

  /// A project is open in the editor.
  projectOpen,

  /// An export runs (or waits to be reattached).
  exportRunning,

  /// An Auto captions job runs.
  captionsRunning,

  /// Another editor job (proxy, reverse, freeze) runs.
  jobRunning,
}

/// Reports what uses the editor cache right now.
typedef EditorCacheUseCheck = Future<EditorCacheUse> Function();

/// Builds the usual [EditorCacheUseCheck]: a project is open ([openProjects], e.g.
/// `FileProjectRepository.openIds`), an export is running or resumable ([exporter]), an Auto captions
/// job runs ([transcription]), or [otherJobs] says so. Failing probes count as "in use", so a
/// broken check can never let the cache be cleared under a live session.
EditorCacheUseCheck editorCacheUseOf({
  required Iterable<Object?> Function() openProjects,
  ExportService? exporter,
  TranscriptionService? transcription,
  bool Function()? otherJobs,
}) {
  return () async {
    try {
      if (openProjects().isNotEmpty) return EditorCacheUse.projectOpen;
      if (exporter != null) {
        final jobs = await exporter.activeJobs();
        if (jobs.any((job) => job is ExportRunning || job is ExportResumable)) return EditorCacheUse.exportRunning;
      }
      if (transcription?.activeJob != null) return EditorCacheUse.captionsRunning;
      if (otherJobs?.call() ?? false) return EditorCacheUse.jobRunning;
      return EditorCacheUse.none;
    } on Object catch (e) {
      debugPrint('[EditorStorage] Activity check failed: ${e.runtimeType}');
      return EditorCacheUse.jobRunning;
    }
  };
}

/// Measures and clears the regenerable editor caches (ARCH §8.1, §17.10).
final class EditorCacheCleaner {
  /// Creates the cleaner over [roots]. [fs] defaults to the real file system (measured in an
  /// isolate); [deleter] to an `OwnedFileDeleter` over [roots]; [trimEngine] (usually
  /// `engine.trimCaches(CacheTrimLevel.clearAll)`) runs first so native caches drop open handles.
  EditorCacheCleaner({
    required this.roots,
    StoreFs fs = const LocalStoreFs(),
    OwnedFileDeleter? deleter,
    this.trimEngine,
  })  : _fs = fs,
        _deleter = deleter ?? OwnedFileDeleter(roots, fs: fs);

  /// Folders under `<cache>/danaview/editor` that "Clear editor cache" empties. `work/` (picks, drops,
  /// in-progress exports) and `engine/` are never cleared from here.
  /// `renders/` holds the render-preview cache (D-45): its files and `index.json` go together, so a
  /// reopened index finds no renders.
  static const List<String> folders = ['thumbs', 'waves', 'proxies', 'sprites', 'looks', 'renders'];

  /// App roots.
  final StoreRoots roots;

  /// Asks the engine to drop its caches before the files go.
  final Future<void> Function()? trimEngine;

  final StoreFs _fs;
  final OwnedFileDeleter _deleter;

  /// Absolute paths of [folders].
  List<String> get paths => [for (final folder in folders) p.join(roots.editorCache, folder)];

  /// Bytes in [folders].
  Future<int> measure() {
    final fs = _fs;
    final targets = paths;
    if (fs is LocalStoreFs) return Isolate.run(() => _bytesOf(const LocalStoreFs(), targets));
    return _bytesOf(fs, targets);
  }

  /// Deletes the contents of [folders] (the folders themselves stay) and returns the bytes freed.
  /// Entries the guard refuses (a link pointing outside the editor roots, for example) are left in
  /// place.
  Future<int> clear() async {
    final before = await measure();
    final trim = trimEngine;
    if (trim != null) {
      try {
        await trim();
      } on Object catch (e) {
        debugPrint('[EditorStorage] Engine cache trim failed: ${e.runtimeType}');
      }
    }
    for (final folder in paths) {
      if ((await _fs.stat(folder)).type != StoreEntityType.directory) continue;
      for (final entry in await _fs.list(folder)) {
        try {
          await _deleter.delete(entry.path, recursive: entry.type == StoreEntityType.directory);
        } on OwnershipViolation {
          // Reported by the guard; nothing was deleted.
        } on StoreFailure catch (e) {
          debugPrint('[EditorStorage] Could not delete a cache entry: ${e.kind.name}');
        }
      }
    }
    final after = await measure();
    return before > after ? before - after : 0;
  }

  static Future<int> _bytesOf(StoreFs fs, List<String> targets) async {
    var total = 0;
    for (final path in targets) {
      total += await _treeBytes(fs, path);
    }
    return total;
  }

  static Future<int> _treeBytes(StoreFs fs, String path) async {
    final stat = await fs.stat(path);
    if (stat.type == StoreEntityType.file) return stat.size;
    if (stat.type != StoreEntityType.directory) return 0;
    var total = 0;
    for (final entry in await fs.list(path)) {
      total += await _treeBytes(fs, entry.path);
    }
    return total;
  }
}

/// Settings › Storage rows for editor projects and the editor cache (ARCH §17.10). The router lists
/// them through [EditorStorageContributor.all].
sealed class EditorStorageContributor extends StorageContributor {
  const EditorStorageContributor();

  /// The editor's contributors in display order: projects, cache, then (with [exports]) the
  /// export files. [onOpenProjects] opens the Projects screen (the router pushes `/projects`).
  static List<EditorStorageContributor> all({
    required ProjectRepository repository,
    required EditorCacheCleaner cache,
    required EditorCacheUseCheck cacheUse,
    required void Function(BuildContext context) onOpenProjects,
    ExportOutputSweeper? exports,
  }) =>
      [
        EditorProjectsStorageContributor(repository: repository, onOpenProjects: onOpenProjects),
        EditorCacheStorageContributor(cleaner: cache, cacheUse: cacheUse),
        if (exports != null) EditorExportsStorageContributor(sweeper: exports, cacheUse: cacheUse),
      ];

  @override
  String get section => StorageStrings.section;
}

/// "Video editor projects": what only deleting projects frees. No clear action; opens Projects.
final class EditorProjectsStorageContributor extends EditorStorageContributor {
  /// Creates the contributor.
  const EditorProjectsStorageContributor({required this.repository, required this.onOpenProjects});

  /// The project store.
  final ProjectRepository repository;

  /// Opens the Projects screen.
  final void Function(BuildContext context) onOpenProjects;

  @override
  String get id => 'editor.projects';

  @override
  String get title => StorageStrings.projectsTitle;

  @override
  String get subtitle => StorageStrings.projectsSubtitle;

  @override
  IconData get icon => Icons.movie_edit;

  @override
  StorageOpenAction get openAction => StorageOpenAction(label: StorageStrings.openProjects, onOpen: onOpenProjects);

  /// Measured now, and again whenever the project list changes (rename, duplicate, delete, save).
  @override
  Stream<StorageContributorUsage> watchUsage() {
    return repository.watchSummaries().asyncMap((_) => _measure()).distinct();
  }

  Future<StorageContributorUsage> _measure() async {
    final report = await repository.storageReport();
    return StorageContributorUsage(
      bytes: report.projectsTotalBytes,
      detail: StorageStrings.projectCount(report.projectCount),
    );
  }
}

/// "Editor cache": thumbnails, waveforms, proxies, sprites, look previews and rendered previews. Clearing is blocked
/// while a project is open or a job runs; projects and media are never touched.
final class EditorCacheStorageContributor extends EditorStorageContributor {
  /// Creates the contributor.
  EditorCacheStorageContributor({required this.cleaner, required this.cacheUse});

  /// Measures and clears the cache folders.
  final EditorCacheCleaner cleaner;

  /// What uses the cache right now.
  final EditorCacheUseCheck cacheUse;

  final StreamController<void> _changed = StreamController<void>.broadcast();

  @override
  String get id => 'editor.cache';

  @override
  String get title => StorageStrings.cacheTitle;

  @override
  String get subtitle => StorageStrings.cacheSubtitle;

  @override
  IconData get icon => Icons.auto_awesome_motion_rounded;

  /// The whole `<cache>/danaview/editor` folder: the app's own "Clear cache" never deletes it.
  @override
  Set<String> get ownedPaths => {cleaner.roots.editorCache};

  @override
  StorageClearAction get clearAction => StorageClearAction(
        label: StorageStrings.clearCache,
        confirmTitle: StorageStrings.clearCache,
        confirmMessage: StorageStrings.clearCacheMessage,
        confirmLabel: StorageStrings.clearCacheConfirm,
        icon: Icons.cleaning_services_rounded,
        run: clear,
      );

  /// Measured now and again after every [clear].
  @override
  Stream<StorageContributorUsage> watchUsage() async* {
    yield await _measure();
    await for (final _ in _changed.stream) {
      yield await _measure();
    }
  }

  /// Clears the cache unless something uses it ([StorageClearOutcome.blocked] then).
  Future<StorageClearOutcome> clear() async {
    final use = await cacheUse();
    if (use != EditorCacheUse.none) return StorageClearOutcome.blocked(StorageStrings.cacheBlocked(use));
    final freed = await cleaner.clear();
    _changed.add(null);
    return StorageClearOutcome.done(freedBytes: freed, message: freed == 0 ? StorageStrings.cacheAlreadyEmpty : null);
  }

  Future<StorageContributorUsage> _measure() async {
    final (bytes, use) = await (cleaner.measure(), cacheUse()).wait;
    return StorageContributorUsage(
      bytes: bytes,
      clearBlockedReason: use == EditorCacheUse.none ? null : StorageStrings.cacheBlocked(use),
    );
  }
}

/// "Export files": exports written to `<support>/danaview/editor/exports` that no job still needs
/// (FIX-QA05-D8-2). Clearing deletes only unreferenced files and is blocked while a project is
/// open or a job runs.
final class EditorExportsStorageContributor extends EditorStorageContributor {
  /// Creates the contributor.
  EditorExportsStorageContributor({required this.sweeper, required this.cacheUse});

  /// Measures and clears the exports folder.
  final ExportOutputSweeper sweeper;

  /// What uses the editor right now.
  final EditorCacheUseCheck cacheUse;

  final StreamController<void> _changed = StreamController<void>.broadcast();

  @override
  String get id => 'editor.exports';

  @override
  String get title => StorageStrings.exportsTitle;

  @override
  String get subtitle => StorageStrings.exportsSubtitle;

  @override
  IconData get icon => Icons.ios_share_rounded;

  @override
  StorageClearAction get clearAction => StorageClearAction(
        label: StorageStrings.clearExports,
        confirmTitle: StorageStrings.clearExports,
        confirmMessage: StorageStrings.clearExportsMessage,
        confirmLabel: StorageStrings.clearCacheConfirm,
        icon: Icons.cleaning_services_rounded,
        run: clear,
      );

  /// Measured now and again after every [clear].
  @override
  Stream<StorageContributorUsage> watchUsage() async* {
    yield await _measure();
    await for (final _ in _changed.stream) {
      yield await _measure();
    }
  }

  /// Deletes the unreferenced export files unless something uses the editor
  /// ([StorageClearOutcome.blocked] then, or when a job record could not be read).
  Future<StorageClearOutcome> clear() async {
    final use = await cacheUse();
    if (use != EditorCacheUse.none) return StorageClearOutcome.blocked(StorageStrings.exportsBlocked(use));
    final report = await sweeper.clear();
    _changed.add(null);
    if (report.skipped) return const StorageClearOutcome.blocked(StorageStrings.exportsUnreadable);
    return StorageClearOutcome.done(
      freedBytes: report.freedBytes,
      message: report.deletedFiles == 0 ? StorageStrings.exportsAlreadyEmpty : null,
    );
  }

  Future<StorageContributorUsage> _measure() async {
    final (size, use) = await (sweeper.measure(), cacheUse()).wait;
    return StorageContributorUsage(
      bytes: size.bytes,
      detail: StorageStrings.exportFileCount(size.files),
      clearBlockedReason: use == EditorCacheUse.none ? null : StorageStrings.exportsBlocked(use),
    );
  }
}
