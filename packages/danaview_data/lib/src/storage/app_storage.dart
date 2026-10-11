import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Structured AppStorage service.
/// Enforces §7.0 Non-destructive Invariant:
/// "The player has exactly one writable location: its own app-data directory.
/// It never writes to, moves, renames, reorganises, or deletes anything inside
/// the user's media folders."
class AppStorage {
  static Directory? _appDataDir;
  static Directory? _cacheDir;

  static Future<void> initialize() async {
    try {
      _appDataDir = await getApplicationSupportDirectory();
    } catch (_) {
      _appDataDir = Directory('${Directory.systemTemp.path}/danaview_app_data');
    }

    try {
      _cacheDir = await getTemporaryDirectory();
    } catch (_) {
      _cacheDir = Directory('${Directory.systemTemp.path}/danaview_cache');
    }

    if (!await _appDataDir!.exists()) {
      await _appDataDir!.create(recursive: true);
    }
    if (!await _cacheDir!.exists()) {
      await _cacheDir!.create(recursive: true);
    }
  }

  static Directory get appDataDirectory {
    return _appDataDir ?? Directory('${Directory.systemTemp.path}/danaview_app_data');
  }

  static Directory get cacheDirectory {
    return _cacheDir ?? Directory('${Directory.systemTemp.path}/danaview_cache');
  }

  /// The app's own disposable folders; empty when the platform gives the app none.
  ///
  /// - Android: the app's cache folder, which also holds the copies the file picker makes.
  /// - iOS: Library/Caches (what `getTemporaryDirectory` returns there) and the app's tmp folder,
  ///   where the document picker copies picked files (`tmp/<bundle id>-Inbox`).
  /// - Desktop: the per-app cache folder only; the system temporary folder can be shared with other
  ///   apps, and picked files are opened where they are rather than copied.
  static Future<List<Directory>> appCacheDirectories() async {
    final folders = <Directory>[];
    Future<void> add(Future<Directory> Function() locate) async {
      try {
        folders.add(await locate());
      } catch (_) {
        // Not available on this platform.
      }
    }

    if (Platform.isAndroid) {
      await add(getTemporaryDirectory);
    } else if (Platform.isIOS) {
      await add(getTemporaryDirectory);
      // NSTemporaryDirectory: iOS points TMPDIR at the app's own tmp folder.
      await add(() async => Directory.systemTemp);
    } else {
      await add(getApplicationCacheDirectory);
    }
    return folders;
  }

  static Future<File> getCacheFile(String filename) async {
    final path = p.join(cacheDirectory.path, filename);
    return File(path);
  }

  static Future<File> getAppDataFile(String filename) async {
    final path = p.join(appDataDirectory.path, filename);
    return File(path);
  }
}
