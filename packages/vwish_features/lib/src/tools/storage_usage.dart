import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vwish_data/vwish_data.dart';
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import '../controllers/providers.dart';

/// How many files a folder holds and how much space they take.
@immutable
class FolderUsage {
  const FolderUsage({this.files = 0, this.bytes = 0, this.complete = true});

  final int files;
  final int bytes;

  /// False when part of the folder couldn't be read, so the real figures may be higher.
  final bool complete;

  @override
  bool operator ==(Object other) =>
      other is FolderUsage && files == other.files && bytes == other.bytes && complete == other.complete;

  @override
  int get hashCode => Object.hash(files, bytes, complete);

  @override
  String toString() => 'FolderUsage($files files, $bytes bytes${complete ? '' : ', incomplete'})';
}

/// Space the app itself takes up on this device.
@immutable
class StorageUsage {
  const StorageUsage({this.deviceVideos, this.cache});

  /// Videos in the app's own Documents folder (imported or added in the Files app) on iOS and
  /// Android; null on desktop, where videos play from their own folders and nothing is copied.
  final FolderUsage? deviceVideos;

  /// The app's disposable cache folder; null when the platform gives the app none.
  final FolderUsage? cache;

  int get totalBytes => (deviceVideos?.bytes ?? 0) + (cache?.bytes ?? 0);
}

/// What [StorageUsageService.clearCache] removed.
@immutable
class CacheClearResult {
  const CacheClearResult({this.files = 0, this.bytes = 0, this.kept = 0});

  final int files;
  final int bytes;

  /// Entries left in place because they are in use or couldn't be deleted.
  final int kept;
}

/// Measures the app's videos and cache, and empties the cache.
///
/// Only the app's own cache folders are ever deleted from; videos (imported or not) are never
/// touched (§7.0). Folders a [StorageContributor] owns ([excludedPaths], e.g. the video editor's
/// cache with its in-progress work) are left out of the cache figures and never deleted by
/// [clearCache]: their contributor measures and clears them itself.
class StorageUsageService {
  const StorageUsageService({
    required this.deviceDirectory,
    required this.cacheDirectories,
    this.excludedPaths = const {},
  });

  /// The app's Documents folder on iOS/Android; resolves to null on desktop.
  final Future<Directory?> Function() deviceDirectory;

  /// The app's disposable folders, counted together as its cache. On iOS that is Library/Caches
  /// and tmp, where picked files are copied.
  final Future<List<Directory>> Function() cacheDirectories;

  /// Absolute paths inside the cache folders that belong to a [StorageContributor]: not counted as
  /// cache and kept by [clearCache].
  final Set<String> excludedPaths;

  /// Stops counting after this many entries so a huge folder can't stall the page.
  static const int maxEntries = 100000;

  Future<StorageUsage> measure() async {
    final (device, caches) = await (_resolve(deviceDirectory), _cacheFolders()).wait;
    final excluded = {for (final path in excludedPaths) _canonicalLoose(path)};
    final (videos, cached) = await (
      device == null ? Future<FolderUsage?>.value() : _walk(device, include: LibraryRepository.isVideoPath),
      Future.wait([for (final path in caches) _walkExcluding(Directory(path), excluded)]),
    ).wait;
    return StorageUsage(deviceVideos: videos, cache: caches.isEmpty ? null : _sum(cached));
  }

  /// Deletes everything inside the cache folders except the paths in [keep] (e.g. the video that
  /// is playing) and [excludedPaths]. Never throws; entries that can't be deleted are counted in
  /// [CacheClearResult.kept].
  Future<CacheClearResult> clearCache({Set<String> keep = const {}}) async {
    final caches = await _cacheFolders();
    if (caches.isEmpty) return const CacheClearResult();
    final device = await _resolve(deviceDirectory);
    final documents = device == null ? null : _canonical(device.path);
    final kept = {
      for (final path in keep) _canonical(path),
      for (final path in excludedPaths) _canonicalLoose(path),
    };
    final result = _CacheClearCounter();
    for (final root in caches) {
      // A misconfigured cache folder must never take the user's videos (or a whole disk) with it.
      if (_segments(root).length < 2) continue;
      if (documents != null &&
          (_samePath(root, documents) || _isWithin(root, documents) || _isWithin(documents, root))) {
        continue;
      }
      await _clearInside(Directory(root), kept, result);
    }
    return CacheClearResult(files: result.files, bytes: result.bytes, kept: result.kept);
  }

  /// The existing cache folders, canonical, each once; a folder inside another listed one is left
  /// to its parent so nothing is counted twice.
  Future<List<String>> _cacheFolders() async {
    final List<Directory> listed;
    try {
      listed = await cacheDirectories();
    } catch (e) {
      debugPrint('[Storage] Folder lookup failed: $e');
      return const [];
    }
    final paths = <String>[];
    for (final dir in listed) {
      final resolved = await _resolve(() async => dir);
      if (resolved != null) paths.add(_canonical(resolved.path));
    }
    return [
      for (final (i, path) in paths.indexed)
        if (!paths.take(i).any((other) => _samePath(other, path)) &&
            !paths.any((other) => _isWithin(other, path)))
          path,
    ];
  }

  static FolderUsage _sum(List<FolderUsage> parts) => FolderUsage(
        files: parts.fold(0, (total, part) => total + part.files),
        bytes: parts.fold(0, (total, part) => total + part.bytes),
        complete: parts.every((part) => part.complete),
      );

  Future<void> _clearInside(Directory dir, Set<String> keep, _CacheClearCounter result) async {
    final List<FileSystemEntity> children;
    try {
      children = await dir.list(followLinks: false).toList();
    } catch (e) {
      debugPrint('[Storage] Could not list ${dir.path}: $e');
      result.kept++;
      return;
    }
    for (final child in children) {
      final path = child.path;
      if (keep.any((k) => _samePath(k, path))) {
        result.kept++;
        continue;
      }
      // A folder holding something in use is emptied around it instead of being deleted.
      if (child is Directory && keep.any((k) => _isWithin(path, k))) {
        await _clearInside(child, keep, result);
        continue;
      }
      final usage = child is Directory ? await _walk(child, skipHidden: false) : await _fileUsage(child);
      try {
        // Links are removed themselves; their targets are never followed.
        await child.delete(recursive: child is Directory);
        result
          ..files += usage.files
          ..bytes += usage.bytes;
      } catch (e) {
        debugPrint('[Storage] Could not delete $path: $e');
        result.kept++;
      }
    }
  }

  static Future<Directory?> _resolve(Future<Directory?> Function() locate) async {
    try {
      final dir = await locate();
      return dir != null && await dir.exists() ? dir : null;
    } catch (e) {
      debugPrint('[Storage] Folder lookup failed: $e');
      return null;
    }
  }

  static Future<FolderUsage> _fileUsage(FileSystemEntity entity) async {
    if (entity is! File) return const FolderUsage();
    try {
      return FolderUsage(files: 1, bytes: await entity.length());
    } catch (_) {
      return const FolderUsage(files: 1, complete: false);
    }
  }

  /// Sizes of the files under [dir] that [include] accepts, by default skipping hidden entries as
  /// the Files app does. Links are not followed.
  static Future<FolderUsage> _walk(
    Directory dir, {
    bool Function(String path)? include,
    bool skipHidden = true,
  }) async {
    var files = 0;
    var bytes = 0;
    var seen = 0;
    var complete = true;
    try {
      final entries = dir.list(recursive: true, followLinks: false).handleError((Object _) => complete = false);
      await for (final entity in entries) {
        if (++seen > maxEntries) {
          complete = false;
          break;
        }
        if (entity is! File) continue;
        if (skipHidden && _segments(entity.path.substring(dir.path.length)).any((s) => s.startsWith('.'))) continue;
        if (include != null && !include(entity.path)) continue;
        try {
          bytes += await entity.length();
          files++;
        } catch (_) {
          complete = false;
        }
      }
    } catch (_) {
      complete = false;
    }
    return FolderUsage(files: files, bytes: bytes, complete: complete);
  }

  /// [dir]'s usage without the entries in [excluded] (canonical paths). Only the branches that lead
  /// to an excluded path are listed level by level; everything else is walked as usual.
  static Future<FolderUsage> _walkExcluding(Directory dir, Set<String> excluded) async {
    final base = dir.path;
    if (excluded.any((e) => _samePath(e, base))) return const FolderUsage();
    if (!excluded.any((e) => _isWithin(base, e))) return _walk(dir, skipHidden: false);
    final List<FileSystemEntity> children;
    try {
      children = await dir.list(followLinks: false).toList();
    } catch (_) {
      return const FolderUsage(complete: false);
    }
    final parts = <FolderUsage>[];
    for (final child in children) {
      if (child is Directory) {
        parts.add(await _walkExcluding(child, excluded));
      } else if (!excluded.any((e) => _samePath(e, child.path))) {
        parts.add(await _fileUsage(child));
      }
    }
    return _sum(parts);
  }

  /// [path] made canonical even when it doesn't exist yet: the nearest existing ancestor is resolved
  /// and the rest appended, so an owned folder created later still matches its cache folder.
  static String _canonicalLoose(String path) {
    final absolute = _trimSeparators(File(path).absolute.path);
    final tail = <String>[];
    var current = absolute;
    while (true) {
      try {
        if (FileSystemEntity.typeSync(current, followLinks: false) != FileSystemEntityType.notFound) {
          final resolved = _canonical(current);
          return tail.isEmpty ? resolved : [resolved, ...tail.reversed].join(Platform.pathSeparator);
        }
      } catch (_) {
        break;
      }
      final cut = current.lastIndexOf(_separators);
      if (cut <= 0) break;
      tail.add(current.substring(cut + 1));
      current = current.substring(0, cut);
    }
    return absolute;
  }

  /// [path] with links resolved (iOS reaches the same folder through /var and /private/var).
  static String _canonical(String path) {
    try {
      return _trimSeparators(File(path).resolveSymbolicLinksSync());
    } catch (_) {
      return _trimSeparators(File(path).absolute.path);
    }
  }

  static final _separators = RegExp(r'[/\\]');

  static List<String> _segments(String path) => [for (final s in path.split(_separators)) if (s.isNotEmpty) s];

  static String _trimSeparators(String path) {
    var end = path.length;
    while (end > 1 && _separators.hasMatch(path[end - 1])) {
      end--;
    }
    return path.substring(0, end);
  }

  static bool _samePath(String a, String b) => _trimSeparators(a) == _trimSeparators(b);

  /// Whether [child] is strictly inside [parent].
  static bool _isWithin(String parent, String child) {
    final base = _trimSeparators(parent);
    final candidate = _trimSeparators(child);
    return candidate.length > base.length + 1 &&
        candidate.startsWith(base) &&
        _separators.hasMatch(candidate[base.length]);
  }
}

class _CacheClearCounter {
  int files = 0;
  int bytes = 0;
  int kept = 0;
}

/// Finds the app's videos and cache; override with temporary folders or a fake in tests.
final storageUsageServiceProvider = Provider<StorageUsageService>((ref) {
  final library = ref.watch(libraryRepositoryProvider);
  return StorageUsageService(
    deviceDirectory: () async {
      final folder = await library.getDeviceFolder();
      return folder == null ? null : Directory(folder.path);
    },
    cacheDirectories: AppStorage.appCacheDirectories,
    excludedPaths: {
      for (final contributor in ref.watch(storageContributorsProvider)) ...contributor.ownedPaths,
    },
  );
});

// -------------------------------------------------------------------------------------------------
// Storage contributors (ARCH §17.10, ux.md §4.8)
// -------------------------------------------------------------------------------------------------

/// What a [StorageContributor] currently holds.
@immutable
class StorageContributorUsage {
  const StorageContributorUsage({required this.bytes, this.detail, this.complete = true, this.clearBlockedReason});

  /// Bytes on this device.
  final int bytes;

  /// A short count shown before the size, e.g. `3 projects`; null shows the size alone.
  final String? detail;

  /// False when part of it couldn't be read, so the real figure may be higher.
  final bool complete;

  /// Why the contributor's clear action can't run right now (e.g. a project is open), shown instead
  /// of the action; null when it can run.
  final String? clearBlockedReason;

  @override
  bool operator ==(Object other) =>
      other is StorageContributorUsage &&
      other.bytes == bytes &&
      other.detail == detail &&
      other.complete == complete &&
      other.clearBlockedReason == clearBlockedReason;

  @override
  int get hashCode => Object.hash(bytes, detail, complete, clearBlockedReason);

  @override
  String toString() => 'StorageContributorUsage($bytes bytes${detail == null ? '' : ', $detail'}'
      '${complete ? '' : ', incomplete'}${clearBlockedReason == null ? '' : ', blocked'})';
}

/// What a contributor's clear action did.
@immutable
class StorageClearOutcome {
  /// The clean-up ran and freed [freedBytes]; [message] replaces the default "Freed …" toast.
  const StorageClearOutcome.done({this.freedBytes = 0, this.message}) : blockedReason = null;

  /// Nothing was deleted because something still uses the data ([blockedReason] is shown).
  const StorageClearOutcome.blocked(String this.blockedReason)
      : freedBytes = 0,
        message = null;

  /// Bytes freed.
  final int freedBytes;

  /// Toast text, or null for the default.
  final String? message;

  /// Why nothing was deleted, or null when the clean-up ran.
  final String? blockedReason;

  /// Whether the clean-up ran.
  bool get done => blockedReason == null;
}

/// A clean-up a contributor offers on the Storage screen. The screen always asks first, with the
/// contributor's own copy.
@immutable
class StorageClearAction {
  const StorageClearAction({
    required this.label,
    required this.confirmTitle,
    required this.confirmMessage,
    required this.run,
    this.confirmLabel = 'Clear',
    this.destructive = false,
    this.icon,
  });

  /// Row title, e.g. `Clear editor cache`.
  final String label;

  /// Confirmation title.
  final String confirmTitle;

  /// Confirmation message: what goes and what stays.
  final String confirmMessage;

  /// Confirmation button label.
  final String confirmLabel;

  /// Whether the confirmation is styled as destructive (deleting downloads rather than caches).
  final bool destructive;

  /// Row icon; null uses the Storage screen's clean-up icon.
  final IconData? icon;

  /// Performs the clean-up. It re-checks whatever blocks it and reports
  /// [StorageClearOutcome.blocked] instead of deleting data in use.
  final Future<StorageClearOutcome> Function() run;
}

/// Opens the place where this storage is managed (e.g. the editor's Projects screen).
@immutable
class StorageOpenAction {
  const StorageOpenAction({required this.label, required this.onOpen});

  /// Spoken after the row, e.g. `Opens Projects`.
  final String label;

  /// Navigates; called with the Storage screen's context.
  final void Function(BuildContext context) onOpen;
}

/// Storage that another package (the video editor, the speech model) keeps on this device, shown on
/// the Storage screen without `vwish_features` depending on that package (ARCH §17.10, ux.md §4.8).
///
/// The app root lists contributors by overriding [storageContributorsProvider]. Contributors that
/// share a [section] are shown together under that header.
abstract class StorageContributor {
  const StorageContributor();

  /// Stable id (widget keys, tests).
  String get id;

  /// Section header, e.g. `Video editor`.
  String get section;

  /// Row title, e.g. `Video editor projects`.
  String get title;

  /// One or two sentences on what it holds and what clearing does (shown under the section).
  String get subtitle;

  /// Row icon.
  IconData get icon;

  /// Icon tint.
  Color get color => VwishColors.primaryLight;

  /// The current usage first, then a new value whenever it changes (e.g. after [clearAction]). Each
  /// call starts a fresh measurement.
  Stream<StorageContributorUsage> watchUsage();

  /// The clean-up offered here, or null when it can't be cleared from Storage (editor projects are
  /// deleted in the editor's Projects screen).
  StorageClearAction? get clearAction => null;

  /// Opens the screen that manages this storage, or null.
  StorageOpenAction? get openAction => null;

  /// Absolute folders inside the app's cache folders that this contributor owns: the Storage
  /// screen's own cache figure leaves them out and its "Clear cache" never deletes them.
  Set<String> get ownedPaths => const {};
}

/// Contributors shown on the Storage screen; empty unless the app root overrides it (the editor and
/// speech contributors on iOS/Android when the editor is available, D-17).
final storageContributorsProvider = Provider<List<StorageContributor>>(
  (ref) => const [],
  name: 'storageContributorsProvider',
);
