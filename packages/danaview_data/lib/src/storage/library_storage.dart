import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../scanner/media_identity.dart';

/// On-device media storage for iOS/Android.
///
/// Mobile pickers hand back temporary copies inside the app container that the OS may
/// purge, so they are moved into `<Documents>/Imported`. Only files already inside the
/// app's own container are ever moved (§7.0); on desktop picked paths are returned untouched.
class LibraryStorage {
  LibraryStorage({
    bool? isMobile,
    Future<Directory> Function()? documentsDirectory,
    String? containerPath,
  })  : isMobile = isMobile ?? (!kIsWeb && (Platform.isIOS || Platform.isAndroid)),
        _documentsDirectory = documentsDirectory ?? getApplicationDocumentsDirectory,
        _containerOverride = containerPath;

  static const importFolderName = 'Imported';

  /// Where [deviceDirectory] shows in the iOS Files app: "On My iPad › Danaview" on an iPad
  /// ([tablet]), "On My iPhone › Danaview" otherwise.
  static String iosFilesLocation({required bool tablet}) => 'On My ${tablet ? 'iPad' : 'iPhone'} › Danaview';

  /// Whether a screen whose shortest side is [shortestSide] logical pixels is an iPad's, by the
  /// same 600 pt rule as the Storage screen.
  static bool isTabletWidth(double shortestSide) => shortestSide >= 600;

  final bool isMobile;
  final Future<Directory> Function() _documentsDirectory;
  final String? _containerOverride;

  static final _iosContainer = RegExp(r'^(.*/Containers/Data/Application/)([0-9A-Fa-f-]{36})(?=/)');

  late final RegExpMatch? _currentContainer =
      _iosContainer.firstMatch(_containerOverride ?? Directory.systemTemp.path);

  /// The app's Documents folder (created if missing) on iOS/Android; null on desktop.
  ///
  /// On iOS this is visible in the Files app under "On My iPhone › Danaview" ("On My iPad" on an
  /// iPad, see [iosFilesLocation]).
  Future<Directory?> deviceDirectory() async {
    if (!isMobile) return null;
    final dir = await _documentsDirectory();
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Moves picked temporary files into `<Documents>/Imported` on iOS/Android and returns
  /// the new paths in the same order. Never throws: a file that can't be moved keeps its
  /// original path. On desktop the input is returned unchanged.
  Future<List<String>> importPickedFiles(List<String> paths) async {
    if (!isMobile || paths.isEmpty) return List.of(paths);
    final docs = await deviceDirectory();
    if (docs == null) return List.of(paths);
    final importDir = Directory(p.join(docs.path, importFolderName));
    final container = _canonical(p.dirname(docs.path));
    final docsCanonical = _canonical(docs.path);

    final results = <String>[];
    for (final path in paths) {
      results.add(await _importOne(path, docs, importDir, container, docsCanonical));
    }
    return results;
  }

  /// Rebases a stored absolute path from a previous iOS app container onto the current one.
  ///
  /// iOS may move the app container (new UUID) on app updates, which would otherwise break
  /// every persisted path to imported files. Other paths are returned unchanged.
  String resolveStoredPath(String path) {
    final current = _currentContainer;
    if (current == null) return path;
    final stored = _iosContainer.firstMatch(path);
    if (stored == null || stored.group(2) == current.group(2)) return path;
    // Only the UUID changes; keeping the stored prefix ('/var' vs '/private/var') keeps the
    // result equal to paths listed from the Documents folder.
    return '${stored.group(1)}${current.group(2)}${path.substring(stored.end)}';
  }

  Future<String> _importOne(
    String source,
    Directory docs,
    Directory importDir,
    String container,
    String docsCanonical,
  ) async {
    try {
      final file = File(source);
      if (!await file.exists()) return source;
      final canonical = _canonical(source);
      if (!p.isWithin(container, canonical) || p.isWithin(docsCanonical, canonical)) return source;

      await importDir.create(recursive: true);
      final existing = await _findExistingCopy(file, [importDir, docs]);
      if (existing != null) {
        await file.delete();
        return existing;
      }

      final target = await _uniqueTarget(importDir.path, p.basename(source));
      try {
        return (await file.rename(target)).path;
      } on FileSystemException {
        try {
          await file.copy(target);
        } catch (_) {
          await _deleteQuietly(target);
          rethrow;
        }
        await file.delete();
        return target;
      }
    } catch (e) {
      debugPrint('[LibraryStorage] Import of $source failed: $e');
      return source;
    }
  }

  // Re-picking a file that was already imported must not create "name (2).mkv" duplicates.
  Future<String?> _findExistingCopy(File file, List<Directory> dirs) async {
    final name = p.basename(file.path);
    final size = await file.length();
    String? hash;
    for (final dir in dirs) {
      final candidate = File(p.join(dir.path, name));
      if (!await candidate.exists() || await candidate.length() != size) continue;
      hash ??= await MediaIdentityService.computeQuickHash(file.path);
      if (hash.isNotEmpty && await MediaIdentityService.computeQuickHash(candidate.path) == hash) {
        return candidate.path;
      }
    }
    return null;
  }

  static Future<String> _uniqueTarget(String dir, String fileName) async {
    final base = p.basenameWithoutExtension(fileName);
    final ext = p.extension(fileName);
    var candidate = p.join(dir, fileName);
    for (var n = 2; await FileSystemEntity.type(candidate) != FileSystemEntityType.notFound; n++) {
      candidate = p.join(dir, '$base ($n)$ext');
    }
    return candidate;
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      await File(path).delete();
    } catch (_) {}
  }

  static String _canonical(String path) {
    try {
      return File(path).resolveSymbolicLinksSync();
    } catch (_) {
      return p.normalize(p.absolute(path));
    }
  }
}
