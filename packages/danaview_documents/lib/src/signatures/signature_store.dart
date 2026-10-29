// OWNER: HOM-30
//
// Saved signatures (HOM plan §8.5: "saved signatures stay on the device in app-private storage,
// behind the device's normal app protection; the user can delete them"; ARCH v1.2 V2-29). Each
// signature is one transparent PNG in its own folder `<app support>/signatures/`, next to (never
// inside) the Danaview folders' library root, so it never shows in the library, the Files app or a
// share; the folder is marked excluded from iCloud and device backups. At most [maxCount] are kept:
// adding one more is refused (the user deletes one first), never a silent delete. The file name
// carries what the list needs (`sig-<created µs>-<kind>.png`); the size comes from the PNG header.
// Writes go to a temporary name and are renamed into place, so a crash leaves no half signature.
// Nothing here logs a path, a name or the image (rule 30): there is no print or debugPrint, and
// [SavedSignature.toString] shows only the id.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// How a signature was made.
enum SignatureKind {
  /// Drawn with a finger, Apple Pencil or the pointer.
  drawn,

  /// The name typed in a script font.
  typed,

  /// A photo of a signature, background removed.
  imported,
}

/// One saved signature.
@immutable
final class SavedSignature {
  /// A signature [id] stored at [path].
  const SavedSignature({required this.id, required this.path, required this.kind, required this.createdAt, required this.width, required this.height});

  /// Its id (the file name without `.png`).
  final String id;

  /// The PNG (app-private).
  final String path;

  /// How it was made.
  final SignatureKind kind;

  /// When it was saved.
  final DateTime createdAt;

  /// Pixel width (0 when unreadable).
  final int width;

  /// Pixel height (0 when unreadable).
  final int height;

  /// Width over height (3 when unknown).
  double get aspectRatio => width > 0 && height > 0 ? width / height : 3;

  @override
  bool operator ==(Object other) => other is SavedSignature && other.id == id && other.path == path;

  @override
  int get hashCode => Object.hash(id, path);

  // Never prints the path (rule 30).
  @override
  String toString() => 'SavedSignature($id)';
}

/// Adding failed because [SignatureStore.maxCount] signatures are saved already.
final class SignatureStoreFullException implements Exception {
  /// The exception.
  const SignatureStoreFullException();

  @override
  String toString() => 'SignatureStoreFullException';
}

/// Marks a folder excluded from backups (iCloud and device backups on Apple).
typedef BackupExcluder = Future<void> Function(String path);

/// Saved signatures: [FileSignatureStore] in the app; tests use an in-memory one. Listeners hear
/// every add and delete.
abstract class SignatureStore extends ChangeNotifier {
  /// The signatures folder under [appSupport].
  static String signaturesPathIn(String appSupport) => '$appSupport${Platform.pathSeparator}$folderName';

  /// The folder's name.
  static const String folderName = 'signatures';

  /// At most this many signatures are kept.
  static const int maxCount = 10;

  /// The saved signatures, newest first.
  Future<List<SavedSignature>> list();

  /// How many are saved.
  Future<int> count() async => (await list()).length;

  /// Saves [png] (a transparent PNG) as a [kind] signature. Throws [SignatureStoreFullException]
  /// when [maxCount] are saved, [ArgumentError] when [png] isn't a PNG.
  Future<SavedSignature> add(Uint8List png, {required SignatureKind kind});

  /// Deletes signature [id] (nothing when it isn't there).
  Future<void> delete(String id);

  /// Deletes every saved signature (Settings › Privacy "Delete all").
  Future<void> deleteAll();

  /// [bytes] start with the PNG signature and an IHDR chunk.
  static bool isPng(Uint8List bytes) =>
      bytes.length > 24 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 && bytes[12] == 0x49 && bytes[13] == 0x48;

  /// The pixel size in a PNG's IHDR, or (0, 0).
  static (int, int) pngSize(Uint8List bytes) {
    if (!isPng(bytes)) return (0, 0);
    final d = ByteData.sublistView(bytes, 16, 24);
    return (d.getUint32(0), d.getUint32(4));
  }
}

/// The app-private store of saved signatures: one PNG per signature in [directory].
class FileSignatureStore extends SignatureStore {
  /// A store in [directory] (the app uses [FileSignatureStore.inAppSupport]).
  FileSignatureStore(this.directory, {BackupExcluder? excludeFromBackup, DateTime Function()? clock})
      : _exclude = excludeFromBackup,
        _clock = clock ?? DateTime.now;

  /// The store of the app: `<appSupport>/signatures`, a sibling of the Danaview folders' library
  /// root (`<appSupport>/DanaviewLibrary`, `<appSupport>/library` on Android), never inside it.
  factory FileSignatureStore.inAppSupport(String appSupport, {BackupExcluder? excludeFromBackup, DateTime Function()? clock}) =>
      FileSignatureStore(Directory(SignatureStore.signaturesPathIn(appSupport)), excludeFromBackup: excludeFromBackup, clock: clock);

  /// The folder (app-private).
  final Directory directory;

  final BackupExcluder? _exclude;
  final DateTime Function() _clock;
  bool _prepared = false;
  int _last = 0;

  static final RegExp _name = RegExp(r'^sig-(\d+)-(drawn|typed|imported)\.png$');

  Future<void> _prepare() async {
    if (_prepared) return;
    await directory.create(recursive: true);
    final exclude = _exclude;
    if (exclude != null) {
      try {
        await exclude(directory.path);
      } on Object {
        // Backups keep the folder where the flag can't be set; the store still works.
      }
    }
    _prepared = true;
  }

  @override
  Future<List<SavedSignature>> list() async {
    if (!await directory.exists()) return const [];
    final out = <SavedSignature>[];
    await for (final f in directory.list(followLinks: false)) {
      if (f is! File) continue;
      final name = f.uri.pathSegments.isEmpty ? '' : f.uri.pathSegments.last;
      final m = _name.firstMatch(name);
      if (m == null) continue;
      final (w, h) = await _pngSize(f);
      out.add(SavedSignature(
        id: name.substring(0, name.length - 4),
        path: f.path,
        kind: SignatureKind.values.byName(m.group(2)!),
        createdAt: DateTime.fromMicrosecondsSinceEpoch(int.parse(m.group(1)!)),
        width: w,
        height: h,
      ));
    }
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }

  @override
  Future<SavedSignature> add(Uint8List png, {required SignatureKind kind}) async {
    if (!SignatureStore.isPng(png)) throw ArgumentError('not a PNG');
    await _prepare();
    if (await count() >= SignatureStore.maxCount) throw const SignatureStoreFullException();
    var micros = _clock().microsecondsSinceEpoch;
    if (micros <= _last) micros = _last + 1;
    _last = micros;
    final name = 'sig-$micros-${kind.name}.png';
    final target = File('${directory.path}${Platform.pathSeparator}$name');
    final temp = File('${target.path}.part');
    try {
      await temp.writeAsBytes(png, flush: true);
      await temp.rename(target.path);
    } on Object {
      if (await temp.exists()) await temp.delete();
      rethrow;
    }
    notifyListeners();
    final (w, h) = SignatureStore.pngSize(png);
    return SavedSignature(id: name.substring(0, name.length - 4), path: target.path, kind: kind, createdAt: DateTime.fromMicrosecondsSinceEpoch(micros), width: w, height: h);
  }

  @override
  Future<void> delete(String id) async {
    if (!_name.hasMatch('$id.png')) return;
    final f = File('${directory.path}${Platform.pathSeparator}$id.png');
    if (await f.exists()) {
      await f.delete();
      notifyListeners();
    }
  }

  /// Also removes the leftovers of interrupted saves.
  @override
  Future<void> deleteAll() async {
    if (!await directory.exists()) return;
    await for (final f in directory.list(followLinks: false)) {
      if (f is File) await f.delete();
    }
    notifyListeners();
  }

  static Future<(int, int)> _pngSize(File f) async {
    try {
      final raf = await f.open();
      try {
        return SignatureStore.pngSize(await raf.read(25));
      } finally {
        await raf.close();
      }
    } on FileSystemException {
      return (0, 0);
    }
  }
}
