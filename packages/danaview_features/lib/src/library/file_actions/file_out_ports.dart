// OWNER: HOM-22
//
// The platform ports of getting files out (ARCH v1.2 §8 "Getting files out", rule 26, V2-117;
// HOM plan §8.3):
//
// * [NativeFileOut]: iOS, macOS and Android over danaview_library_native (Save to Files / Save to
//   Downloads, Save to Photos add-only, the share sheet, Open in another app). The platform makes
//   the temporary read-only copies and writes create-new only.
// * [DesktopFileOut]: Windows and Linux. The app root passes its `file_selector` save dialog and
//   default-app launcher (the features package doesn't depend on either); the copy is created new
//   (`Name (2).ext` when the chosen name is taken) and the library file is only read.
//
// Nothing here logs (rule 30).

import 'dart:io';

import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_library_native/danaview_library_native.dart';

FileOutError _errorOf(LibraryNativeErrorCode code) => switch (code) {
      LibraryNativeErrorCode.notSupportedOnDevice => FileOutError.unsupported,
      LibraryNativeErrorCode.permissionDenied => FileOutError.denied,
      LibraryNativeErrorCode.notFound => FileOutError.missing,
      LibraryNativeErrorCode.busy => FileOutError.busy,
      _ => FileOutError.failed,
    };

Future<T> _guard<T>(Future<T> Function() call) async {
  try {
    return await call();
  } on LibraryNativeException catch (e) {
    throw FileOutException(_errorOf(e.code));
  }
}

NativeOutFile _native(OutFile f) => NativeOutFile(path: f.path, displayName: f.displayName, mimeType: f.mime, uti: f.uti);

NativeAnchor? _anchor(OutAnchor? a) => a == null ? null : NativeAnchor(a.left, a.top, a.width, a.height);

/// Getting files out through danaview_library_native (iOS, macOS, Android).
final class NativeFileOut implements FileOutPort {
  /// The port for [platform]; tests pass fakes of the three wrappers.
  NativeFileOut(FileOutPlatform platform, {NativeExportOut? exportOut, NativeShare? share, NativeOpenIn? openIn})
      : capabilities = FileOutCapabilities.of(platform),
        _export = exportOut ?? NativeExportOut(),
        _share = share ?? NativeShare(),
        _openIn = openIn ?? NativeOpenIn();

  @override
  final FileOutCapabilities capabilities;

  final NativeExportOut _export;
  final NativeShare _share;
  final NativeOpenIn _openIn;

  @override
  Future<SaveOutOutcome> saveOut(List<OutFile> files, SaveOutTarget target, {OutAnchor? anchor}) => _guard(() async {
        final r = await _export.saveOut(
          [for (final f in files) _native(f)],
          destination: NativeSaveDestination.values[target.index],
          anchor: _anchor(anchor),
        );
        return r.cancelled ? SaveOutOutcome.userCancelled : SaveOutOutcome(cancelled: false, saved: r.savedCount, failed: r.failedCount);
      });

  @override
  Future<ShareOutcome> share(List<OutFile> files, {String? subject, OutAnchor? anchor}) => _guard(() async {
        final r = await _share.share([for (final f in files) _native(f)], subject: subject, anchor: _anchor(anchor));
        return ShareOutcome(completed: r.completed);
      });

  @override
  Future<bool> openIn(OutFile file, {OutAnchor? anchor}) => _guard(() => _openIn.openIn(_native(file), anchor: _anchor(anchor)));
}

/// Asks where to save one file (the dialog's suggested name is [suggestedName]); null when
/// cancelled.
typedef PickSaveFile = Future<String?> Function(String suggestedName);

/// Asks for a folder to save several files into; null when cancelled.
typedef PickSaveDirectory = Future<String?> Function();

/// Opens [path] in the default app; false when none took it.
typedef OpenWithDefaultApp = Future<bool> Function(String path);

String _join(String dir, String name) =>
    dir.endsWith('/') || dir.endsWith(r'\') ? '$dir$name' : '$dir${Platform.pathSeparator}$name';

(String, String) _split(String path) {
  final i = path.lastIndexOf(RegExp(r'[/\\]'));
  return i < 0 ? ('.', path) : (i == 0 ? path.substring(0, 1) : path.substring(0, i), path.substring(i + 1));
}

/// Getting files out on Windows and Linux: the save dialog and the default app (no share sheet,
/// no photo library). "Open in another app" hands the app a temporary copy under
/// `<temp>/danaview-out/`, so it can't change the library file; copies older than a day are
/// removed on the next open.
final class DesktopFileOut implements FileOutPort {
  /// A port over the app root's dialogs; [tempRoot] defaults to `<system temp>/danaview-out`.
  DesktopFileOut({
    required this.pickSaveFile,
    required this.pickSaveDirectory,
    required this.openWithDefaultApp,
    FileOutPlatform platform = FileOutPlatform.windows,
    String? tempRoot,
  })  : capabilities = FileOutCapabilities.of(platform),
        tempRoot = tempRoot ?? _join(Directory.systemTemp.path, 'danaview-out');

  @override
  final FileOutCapabilities capabilities;

  /// The save dialog for one file.
  final PickSaveFile pickSaveFile;

  /// The folder dialog for several files.
  final PickSaveDirectory pickSaveDirectory;

  /// The default-app launcher (`xdg-open`, the shell's open verb).
  final OpenWithDefaultApp openWithDefaultApp;

  /// Where open-in copies go.
  final String tempRoot;

  int _batches = 0;

  /// The first `Name (n).ext` in [dir] that doesn't exist.
  static String uniqueTarget(String dir, String name) {
    final dot = name.lastIndexOf('.');
    final ext = dot > 0 ? name.substring(dot) : '';
    final base = name.substring(0, name.length - ext.length);
    var candidate = _join(dir, name);
    for (var n = 2; FileSystemEntity.typeSync(candidate) != FileSystemEntityType.notFound; n++) {
      candidate = _join(dir, '$base ($n)$ext');
    }
    return candidate;
  }

  @override
  Future<SaveOutOutcome> saveOut(List<OutFile> files, SaveOutTarget target, {OutAnchor? anchor}) async {
    if (target != SaveOutTarget.files) throw const FileOutException(FileOutError.unsupported);
    if (files.isEmpty) return const SaveOutOutcome(cancelled: false, saved: 0, failed: 0);
    final List<(OutFile, String, String)> plan;
    if (files.length == 1) {
      final chosen = await pickSaveFile(files.single.displayName);
      if (chosen == null) return SaveOutOutcome.userCancelled;
      final (dir, name) = _split(chosen);
      plan = [(files.single, dir, name)];
    } else {
      final dir = await pickSaveDirectory();
      if (dir == null) return SaveOutOutcome.userCancelled;
      plan = [for (final f in files) (f, dir, f.displayName)];
    }
    var saved = 0, failed = 0;
    for (final (file, dir, name) in plan) {
      try {
        // Create-new: even when the dialog confirmed replacing a file, a new name is used.
        await File(file.path).copy(uniqueTarget(dir, name));
        saved++;
      } on FileSystemException {
        failed++;
      }
    }
    return SaveOutOutcome(cancelled: false, saved: saved, failed: failed);
  }

  @override
  Future<ShareOutcome> share(List<OutFile> files, {String? subject, OutAnchor? anchor}) async =>
      throw const FileOutException(FileOutError.unsupported);

  @override
  Future<bool> openIn(OutFile file, {OutAnchor? anchor}) async {
    if (!File(file.path).existsSync()) throw const FileOutException(FileOutError.missing);
    sweep();
    try {
      final batch = Directory(_join(tempRoot, '${DateTime.now().microsecondsSinceEpoch}-${++_batches}'));
      batch.createSync(recursive: true);
      final copy = await File(file.path).copy(_join(batch.path, file.displayName));
      return await openWithDefaultApp(copy.path);
    } on FileSystemException {
      throw const FileOutException(FileOutError.failed);
    }
  }

  /// Removes open-in copies older than [age].
  void sweep({Duration age = const Duration(days: 1)}) {
    final root = Directory(tempRoot);
    if (!root.existsSync()) return;
    final now = DateTime.now();
    for (final dir in root.listSync().whereType<Directory>()) {
      try {
        if (now.difference(dir.statSync().modified) > age) dir.deleteSync(recursive: true);
      } on FileSystemException {
        // In use (Windows); the next sweep retries.
      }
    }
  }
}
