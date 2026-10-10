// OWNER: CORE-24
//
// Shared helpers of the store filesystem tests: a throw-away app container with the three roots
// (under the system temp directory, which on macOS is itself behind symbolic links, like iOS
// containers), and `.vwproj` documents of chosen revisions.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:vwish_editor_core/store.dart';

/// A temporary app container.
final class Container {
  Container._(this.dir, this.roots);

  /// Creates `<tmp>/container/{support,cache,documents}`.
  factory Container.create() {
    final dir = Directory.systemTemp.createTempSync('vwish_store_');
    for (final d in ['support', 'cache', 'documents']) {
      Directory(p.join(dir.path, d)).createSync();
    }
    return Container._(
      dir,
      StoreRoots(support: p.join(dir.path, 'support'), cache: p.join(dir.path, 'cache'), documents: p.join(dir.path, 'documents')),
    );
  }

  /// The container directory.
  final Directory dir;

  /// Its roots.
  final StoreRoots roots;

  /// A path inside the container.
  String at(String relative) => p.join(dir.path, relative);

  /// A project document path under the editor support root.
  String get projectFile => p.join(roots.projectDir('pr_test0000001'), 'project.vwproj');

  /// Creates a file (and parents) with [bytes].
  String put(String path, List<int> bytes) {
    File(path)
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes);
    return path;
  }

  /// Removes everything.
  void dispose() => dir.deleteSync(recursive: true);

  /// Every path under the container with its size and content hash-ish fingerprint, for before/after
  /// comparisons of "nothing changed".
  String snapshot() {
    final entries = dir.listSync(recursive: true, followLinks: false)..sort((a, b) => a.path.compareTo(b.path));
    return entries.map((e) {
      if (e is File) return '${e.path}|file|${e.lengthSync()}|${base64.encode(e.readAsBytesSync().take(64).toList())}';
      if (e is Link) return '${e.path}|link|${e.targetSync()}';
      return '${e.path}|dir';
    }).join('\n');
  }
}

/// A valid `.vwproj` document whose body is about [bodySize] bytes and whose revision is [revision].
Uint8List document(int revision, {int bodySize = 2000}) {
  final rnd = Random(revision);
  final filler = String.fromCharCodes(List.generate(bodySize, (_) => 0x61 + rnd.nextInt(26)));
  final body = utf8.encode('{"id":"pr_test0000001","rev":$revision,"pad":"$filler"}');
  return VwprojFormat.build(
    Uint8List.fromList(body),
    app: '1.1.0+3',
    savedAt: DateTime.utc(2026, 10, 9, 18, 0, revision % 60),
    docRevision: revision,
    saveId: 'sv_test${revision.toString().padLeft(8, '0')}',
  );
}

/// The `docRevision` of a valid document, or null.
int? revisionOf(Uint8List bytes) => VwprojFormat.tryParse(bytes)?.header.docRevision;
