// OWNER: CORE-24
//
// OwnedFileDeleter (ARCH §9.6): the only delete path. Fixed cases for each rule, then a fuzz over
// symlinks, `..`, case variants, Unicode normalization, Documents paths and external assets that
// asserts nothing outside the editor roots is ever deleted.

import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/store.dart';

import 'support/harness.dart';

MediaAsset _asset(MediaLocator locator, MediaOwnership own, {String name = 'clip.mov'}) => MediaAsset(
      id: const MediaId('md_test'),
      kind: MediaKind.video,
      displayName: name,
      locator: locator,
      ownership: own,
      fingerprint: const MediaFingerprint(sizeBytes: 10, quickHash: 'aaaa'),
      probe: MediaProbe(kind: MediaKind.video, duration: 1000000, hasVideo: true),
      origin: MediaOrigin.files,
      addedAt: DateTime.utc(2026),
    );

/// A populated container: editor files, protected files and links.
final class World {
  World(this.c) {
    final r = c.roots;
    editorFile = c.put(p.join(r.mediaDir, 'ab', 'abcdef', 'clip.mov'), [1, 2, 3]);
    projectFile = c.put(p.join(r.projectDir('pr_a'), 'project.dnproj'), [4]);
    cacheFile = c.put(p.join(r.editorCache, 'thumbs', 't.jpg'), [5]);
    workPick = c.put(p.join(r.picksDir, 'u1', 'IMG.MOV'), [6]);
    workDrop = c.put(p.join(r.dropsDir, 'u2', 'drop.mp4'), [7]);
    workExport = c.put(p.join(r.workDir, 'export-j1.mp4'), [8]);
    workExportPart = c.put(p.join(r.workDir, 'export-j1', 'v-0.mp4'), [9]);
    docFile = c.put(p.join(r.documents, 'Movie.mp4'), List.filled(64, 0xD0));
    docExport = c.put(p.join(r.documentsExportsDir, 'Out.mp4'), List.filled(64, 0xE0));
    outside = c.put(c.at('outside/secret.txt'), List.filled(64, 0x5E));
    supportOther = c.put(p.join(r.support, 'other', 'keep.db'), List.filled(64, 0x5D));
    speech = c.put(p.join(r.speechSupport, 'models', 'm.bin'), List.filled(64, 0xA1));
    // Links planted inside the editor tree.
    Link(p.join(r.projectDir('pr_a'), 'to_doc_file')).createSync(docFile);
    Link(p.join(r.projectDir('pr_a'), 'to_documents')).createSync(r.documents);
    Link(p.join(r.projectDir('pr_a'), 'to_outside_dir')).createSync(c.at('outside'));
    Link(p.join(r.projectDir('pr_a'), 'to_outside_file')).createSync(outside);
    Link(p.join(r.projectDir('pr_a'), 'to_inside_file')).createSync(editorFile);
    Link(p.join(r.projectDir('pr_a'), 'dangling_outside')).createSync(c.at('outside/not-there'));
    Link(p.join(r.projectDir('pr_a'), 'loop')).createSync(p.join(r.projectDir('pr_a'), 'loop'));
    Link(p.join(r.workDir, 'picks', 'escape')).createSync(r.documents);
  }

  final Container c;
  late final String editorFile, projectFile, cacheFile, workPick, workDrop, workExport, workExportPart;
  late final String docFile, docExport, outside, supportOther, speech;

  /// Files that must survive every attempt: (path, content).
  Map<String, List<int>> get protectedFiles => {
        for (final f in [docFile, docExport, outside, supportOther, speech]) f: File(f).readAsBytesSync(),
      };

  void expectProtectedIntact(Map<String, List<int>> before, String reason) {
    for (final e in before.entries) {
      expect(File(e.key).existsSync(), isTrue, reason: '$reason: ${p.basename(e.key)} deleted');
      expect(File(e.key).readAsBytesSync(), e.value, reason: '$reason: ${p.basename(e.key)} modified');
    }
    for (final d in [c.roots.documents, c.roots.documentsExportsDir, c.at('outside'), c.roots.support, c.roots.cache, c.roots.editorSupport, c.roots.editorCache]) {
      expect(Directory(d).existsSync(), isTrue, reason: '$reason: directory ${p.basename(d)} deleted');
    }
  }
}

void main() {
  late Container c;
  late World w;
  late OwnedFileDeleter deleter;
  late List<OwnershipViolation> reported;

  setUp(() {
    c = Container.create();
    w = World(c);
    reported = [];
    deleter = OwnedFileDeleter(c.roots, assertOnViolation: false, onViolation: reported.add);
  });
  tearDown(() => c.dispose());

  Future<void> refused(String path, {bool recursive = false, String? why}) async {
    final before = w.protectedFiles;
    await expectLater(deleter.delete(path, recursive: recursive), throwsA(isA<OwnershipViolation>()), reason: path);
    w.expectProtectedIntact(before, path);
    if (why != null) expect(reported.last.reason, contains(why));
  }

  group('allowed', () {
    test('files and directories inside editorSupport and editorCache', () async {
      for (final f in [w.editorFile, w.projectFile, w.cacheFile, w.workPick, w.workExport]) {
        await deleter.delete(f);
        expect(File(f).existsSync(), isFalse, reason: f);
      }
      await deleter.delete(c.roots.projectDir('pr_a'), recursive: true);
      expect(Directory(c.roots.projectDir('pr_a')).existsSync(), isFalse);
      expect(Directory(c.roots.editorCache).existsSync(), isTrue);
      expect(reported, isEmpty);
    });

    test('a missing path inside the roots is a no-op; a missing path outside them is refused', () async {
      await deleter.delete(p.join(c.roots.mediaDir, 'nothing'));
      await refused(c.at('outside/not-there'));
    });

    test('a link inside the editor tree pointing inside is removed as a link only', () async {
      final link = p.join(c.roots.projectDir('pr_a'), 'to_inside_file');
      await deleter.delete(link);
      expect(Link(link).existsSync(), isFalse);
      expect(File(w.editorFile).existsSync(), isTrue);
    });

    test('recursive deletion of a tree that contains links never follows them', () async {
      final before = w.protectedFiles;
      await deleter.delete(c.roots.projectDir('pr_a'), recursive: true);
      w.expectProtectedIntact(before, 'project tree with links');
      expect(Directory(c.roots.projectDir('pr_a')).existsSync(), isFalse);
    });

    test('paths that use .. but stay inside are fine', () async {
      await deleter.delete(p.join(c.roots.projectsDir, 'pr_a', '..', 'pr_a', 'project.dnproj'));
      expect(File(w.projectFile).existsSync(), isFalse);
    });

    test('the roots may sit behind symbolic links (like /var -> /private/var)', () async {
      final alias = Link(c.at('alias'))..createSync(c.dir.path);
      final aliased = StoreRoots(
        support: p.join(alias.path, 'support'),
        cache: p.join(alias.path, 'cache'),
        documents: p.join(alias.path, 'documents'),
      );
      final d = OwnedFileDeleter(aliased, assertOnViolation: false);
      await d.delete(p.join(aliased.mediaDir, 'ab', 'abcdef', 'clip.mov'));
      expect(File(w.editorFile).existsSync(), isFalse);
      await expectLater(d.delete(p.join(alias.path, 'documents', 'Movie.mp4')), throwsA(isA<OwnershipViolation>()));
      await expectLater(d.delete(w.docFile), throwsA(isA<OwnershipViolation>()));
      expect(File(w.docFile).existsSync(), isTrue);
    });
  });

  group('refused', () {
    test('Documents, Documents/Exports, other support files, speech, outside, the roots themselves', () async {
      await refused(w.docFile, why: 'outside');
      await refused(w.docExport);
      await refused(c.roots.documentsExportsDir, recursive: true);
      await refused(c.roots.documents, recursive: true);
      await refused(w.supportOther, recursive: true);
      await refused(w.speech);
      await refused(c.roots.speechSupport, recursive: true);
      await refused(w.outside);
      await refused(c.at('outside'), recursive: true);
      await refused(c.roots.editorSupport, recursive: true, why: 'root');
      await refused(c.roots.editorCache, recursive: true, why: 'root');
      await refused('${c.roots.editorSupport}/', recursive: true);
      await refused('${c.roots.editorSupport}/.', recursive: true);
      await refused(p.join(c.roots.projectsDir, '..'), recursive: true);
      await refused(c.roots.support, recursive: true);
      await refused(c.dir.path, recursive: true);
      await refused('/', recursive: true);
      expect(reported, isNotEmpty);
    });

    test('empty, relative and NUL-containing paths', () async {
      await refused('');
      await refused('projects/pr_a/project.dnproj');
      await refused('${w.projectFile}\u0000../../x');
      expect(File(w.projectFile).existsSync(), isTrue);
    });

    test('.. escaping the editor root', () async {
      await refused(p.join(c.roots.projectsDir, '..', '..', '..', '..', 'documents', 'Movie.mp4'));
      await refused(p.join(c.roots.projectsDir, '..', '..', '..', 'documents', 'Movie.mp4'), why: 'outside');
      await refused('${c.roots.projectsDir}/pr_a/../../../../outside/secret.txt');
      await refused('${c.roots.editorSupport}/../other/keep.db');
      await refused('${c.roots.editorCache}/thumbs/../../../../documents/Exports/Out.mp4');
    });

    test('links planted in the editor tree that lead out', () async {
      final base = c.roots.projectDir('pr_a');
      await refused(p.join(base, 'to_doc_file'), why: 'link target');
      await refused(p.join(base, 'to_documents'), recursive: true, why: 'link target');
      await refused(p.join(base, 'to_outside_dir'), recursive: true);
      await refused(p.join(base, 'to_outside_file'));
      await refused(p.join(base, 'dangling_outside'));
      // Reaching through a link to a file outside.
      await refused(p.join(base, 'to_documents', 'Movie.mp4'));
      await refused(p.join(base, 'to_outside_dir', 'secret.txt'));
      await refused(p.join(base, 'to_documents', 'Exports'), recursive: true);
      await refused(p.join(c.roots.picksDir, 'escape', 'Movie.mp4'));
      expect(Link(p.join(base, 'to_doc_file')).existsSync(), isTrue, reason: 'refused links stay');
    });

    test('a link loop is refused or removed as a link, never followed', () async {
      final before = w.protectedFiles;
      final loop = p.join(c.roots.projectDir('pr_a'), 'loop');
      try {
        await deleter.delete(loop);
      } on OwnershipViolation {
        // refused: fine
      } on StoreFailure {
        // unresolvable: fine
      }
      w.expectProtectedIntact(before, 'loop');
    });

    test('Documents inside the editor roots (misconfiguration) still wins', () async {
      final odd = StoreRoots(support: c.roots.support, cache: c.roots.cache, documents: p.join(c.roots.editorSupport, 'docs'));
      c.put(p.join(odd.documents, 'Movie.mp4'), [1]);
      final d = OwnedFileDeleter(odd, assertOnViolation: false);
      await expectLater(d.delete(p.join(odd.documents, 'Movie.mp4')), throwsA(isA<OwnershipViolation>().having((e) => e.reason, 'reason', contains('Documents'))));
      await expectLater(d.delete(odd.documents, recursive: true), throwsA(isA<OwnershipViolation>()));
      expect(File(p.join(odd.documents, 'Movie.mp4')).existsSync(), isTrue);
      await d.delete(w.editorFile);
    });

    test('Documents as an ancestor of the editor roots: nothing is deletable', () async {
      final odd = StoreRoots(support: c.roots.support, cache: c.roots.cache, documents: c.dir.path);
      final d = OwnedFileDeleter(odd, assertOnViolation: false);
      await expectLater(d.delete(w.editorFile), throwsA(isA<OwnershipViolation>()));
      expect(File(w.editorFile).existsSync(), isTrue);
    });
  });

  group('case variants and Unicode normalization', () {
    test('case variants of editor and Documents paths never delete protected files', () async {
      final before = w.protectedFiles;
      for (final path in [
        p.join(c.roots.support, 'DANAVIEW', 'editor', 'media', 'ab', 'abcdef', 'clip.mov'),
        p.join(c.roots.support, 'danaview', 'EDITOR', 'projects', 'pr_a', 'project.dnproj'),
        c.at('support/danaview/editor/media/../../../DOCUMENTS/Movie.mp4'),
        c.at('DOCUMENTS/Movie.mp4'),
        c.at('Documents/EXPORTS/Out.mp4'),
        c.at('documents/exports/out.mp4'),
        c.at('SUPPORT/other/keep.db'),
        c.at('Outside/secret.txt'),
      ]) {
        try {
          await deleter.delete(path);
        } on OwnershipViolation {
          // expected on case-insensitive filesystems (spelling differs from the root)
        }
        w.expectProtectedIntact(before, path);
      }
      // On a case-insensitive volume the canonical spelling of a legit editor file is resolved by the
      // OS, so a case variant of an editor file may legitimately delete that very file; the
      // assertions above prove nothing outside the editor roots is affected either way.
    });

    test('NFC/NFD spellings of a root containing non-ASCII characters never reach protected files', () async {
      final nfc = 'Supporté'; // é precomposed
      final nfd = 'Supporté'; // e + combining acute
      final tmp = Directory.systemTemp.createTempSync('danaview_uni_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final roots = StoreRoots(support: p.join(tmp.path, nfc), cache: p.join(tmp.path, 'cache'), documents: p.join(tmp.path, 'Docsé'));
      final editorFile = File(p.join(roots.mediaDir, 'ab', 'x', 'clip.mov'))..createSync(recursive: true);
      final doc = File(p.join(roots.documents, 'Movie.mp4'))..createSync(recursive: true);
      doc.writeAsBytesSync([1, 2, 3]);
      final d = OwnedFileDeleter(roots, assertOnViolation: false);

      // NFD spelling of the Documents file: never deleted.
      for (final path in [
        p.join(tmp.path, 'Docsé', 'Movie.mp4'),
        p.join(roots.documents.replaceFirst('é', 'é'), 'Movie.mp4'),
        p.join(tmp.path, nfd, 'danaview', 'editor', '..', '..', '..', 'Docsé', 'Movie.mp4'),
      ]) {
        try {
          await d.delete(path);
        } on OwnershipViolation {
          // refused
        }
        expect(doc.existsSync(), isTrue, reason: path);
      }
      // NFD spelling of the legit editor file: either refused or deleted, nothing else changes.
      try {
        await d.delete(p.join(tmp.path, nfd, 'danaview', 'editor', 'media', 'ab', 'x', 'clip.mov'));
      } on OwnershipViolation {
        // refused (strict string comparison): fine
      }
      expect(doc.existsSync(), isTrue);
      // The exact spelling works.
      await d.delete(editorFile.path);
      expect(editorFile.existsSync(), isFalse);
    });
  });

  group('assets', () {
    test('external assets are refused whatever the locator', () async {
      final before = w.protectedFiles;
      final rel = AppRelativeLocator(AppRoot.support, p.posix.joinAll(p.split(p.relative(w.editorFile, from: c.roots.support))));
      for (final loc in [rel, FileLocator(w.editorFile), FileLocator(w.docFile), const BookmarkLocator('Ym9v'), const ContentUriLocator('content://x/1')]) {
        await expectLater(deleter.deleteAsset(_asset(loc, MediaOwnership.external)), throwsA(isA<OwnershipViolation>()));
      }
      expect(File(w.editorFile).existsSync(), isTrue, reason: 'even an external asset that happens to sit under the editor root');
      w.expectProtectedIntact(before, 'external');
    });

    test('managed and project-owned assets under the roots are deleted', () async {
      final rel = AppRelativeLocator(AppRoot.support, p.posix.joinAll(p.split(p.relative(w.editorFile, from: c.roots.support))));
      await deleter.deleteAsset(_asset(rel, MediaOwnership.managedCopy));
      expect(File(w.editorFile).existsSync(), isFalse);
      await deleter.deleteAsset(_asset(FileLocator(w.cacheFile), MediaOwnership.projectOwned));
      expect(File(w.cacheFile).existsSync(), isFalse);
    });

    test('non-external assets that point outside the editor roots or have no file are refused', () async {
      final before = w.protectedFiles;
      for (final loc in [
        const AppRelativeLocator(AppRoot.documents, 'Movie.mp4'),
        const AppRelativeLocator(AppRoot.documents, 'Exports/Out.mp4'),
        const AppRelativeLocator(AppRoot.support, 'danaview/editor/../../other/keep.db'),
        const AppRelativeLocator(AppRoot.support, '../outside/secret.txt'),
        const AppRelativeLocator(AppRoot.cache, '../documents/Movie.mp4'),
        FileLocator(w.outside),
        const BookmarkLocator('Ym9v', lastKnownPath: '/x'),
        const ContentUriLocator('content://x/1'),
      ]) {
        await expectLater(deleter.deleteAsset(_asset(loc, MediaOwnership.managedCopy)), throwsA(isA<OwnershipViolation>()), reason: '$loc');
      }
      w.expectProtectedIntact(before, 'assets');
    });
  });

  group('violations are reported', () {
    test('assertOnViolation trips an assert in debug builds, before the exception', () async {
      final strict = OwnedFileDeleter(c.roots, onViolation: reported.add);
      var asserts = false;
      assert(() {
        asserts = true;
        return true;
      }());
      if (asserts) {
        await expectLater(strict.delete(w.docFile), throwsA(isA<AssertionError>()));
        expect(reported, hasLength(1), reason: 'reported before the assert');
      } else {
        await expectLater(strict.delete(w.docFile), throwsA(isA<OwnershipViolation>()));
      }
      expect(File(w.docFile).existsSync(), isTrue);
    });

    test('OwnershipViolation carries path and reason', () async {
      await refused(w.docFile);
      expect(reported.single.path, w.docFile);
      expect(reported.single.toString(), contains('OwnershipViolation'));
    });
  });

  group('canConsume and consume (app-owned temporary files)', () {
    test('picks, drops and engine outputs only', () async {
      for (final f in [w.workPick, w.workDrop, w.workExport, w.workExportPart]) {
        expect(await deleter.canConsume(f), isTrue, reason: f);
      }
      for (final f in [
        w.editorFile,
        w.projectFile,
        w.cacheFile,
        w.docFile,
        w.docExport,
        w.outside,
        w.supportOther,
        p.join(c.roots.picksDir, 'u1'), // a directory
        p.join(c.roots.picksDir), // the directory itself
        p.join(c.roots.workDir, 'other.mp4'), // not an engine output
        p.join(c.roots.workDir, 'picks.txt'),
        p.join(c.roots.picksDir, 'u1', '..', '..', '..', '..', '..', 'documents', 'Movie.mp4'),
        p.join(c.roots.picksDir, 'escape', 'Movie.mp4'),
        p.join(c.roots.projectDir('pr_a'), 'to_doc_file'),
        'relative/path',
        '',
        p.join(c.roots.picksDir, 'u1', 'missing.mov'),
      ]) {
        expect(await deleter.canConsume(f), isFalse, reason: f);
      }
    });

    test('a symlink inside picks is not consumable, even to a file inside the roots', () async {
      final link = p.join(c.roots.picksDir, 'u1', 'lnk.mov');
      Link(link).createSync(w.editorFile);
      expect(await deleter.canConsume(link), isFalse);
    });

    test('custom engine prefixes', () async {
      final custom = OwnedFileDeleter(c.roots, engineOutputPrefixes: const ['rec-'], assertOnViolation: false);
      final rec = c.put(p.join(c.roots.workDir, 'rec-1.wav'), [1]);
      expect(await custom.canConsume(rec), isTrue);
      expect(await custom.canConsume(w.workExport), isFalse);
    });

    test('consume moves a pick into the managed store and refuses everything else', () async {
      final dest = p.join(c.roots.mediaDir, 'cd', 'cdef', 'IMG.MOV');
      await deleter.consume(w.workPick, destination: dest);
      expect(File(dest).readAsBytesSync(), [6]);
      expect(File(w.workPick).existsSync(), isFalse);

      final before = w.protectedFiles;
      // Source not consumable.
      await expectLater(deleter.consume(w.docFile, destination: p.join(c.roots.mediaDir, 'x')), throwsA(isA<OwnershipViolation>()));
      await expectLater(deleter.consume(w.editorFile, destination: p.join(c.roots.mediaDir, 'y')), throwsA(isA<OwnershipViolation>()));
      // Destination outside the editor roots, inside Documents, or already existing.
      await expectLater(deleter.consume(w.workDrop, destination: p.join(c.roots.documents, 'stolen.mp4')), throwsA(isA<OwnershipViolation>()));
      await expectLater(deleter.consume(w.workDrop, destination: c.at('outside/stolen.mp4')), throwsA(isA<OwnershipViolation>()));
      await expectLater(deleter.consume(w.workDrop, destination: p.join(c.roots.mediaDir, '..', '..', '..', 'outside', 'x')), throwsA(isA<OwnershipViolation>()));
      await expectLater(deleter.consume(w.workDrop, destination: dest), throwsA(isA<OwnershipViolation>().having((e) => e.reason, 'reason', contains('exists'))));
      expect(File(w.workDrop).existsSync(), isTrue, reason: 'refused consume leaves the source');
      expect(File(dest).readAsBytesSync(), [6]);
      w.expectProtectedIntact(before, 'consume');
    });
  });

  group('fuzz', () {
    test('2500 random attempts over traversal, links, case and Unicode never touch anything protected', () async {
      final rnd = Random(77);
      var protectedBefore = w.protectedFiles;
      final names = <String>[
        '..', '.', '', '..', '..',
        'support', 'cache', 'documents', 'outside', 'Documents', 'DOCUMENTS', 'SUPPORT', 'DANAVIEW', 'Danaview',
        'danaview', 'editor', 'EDITOR', 'speech', 'projects', 'pr_a', 'media', 'ab', 'abcdef', 'work', 'picks', 'drops', 'escape',
        'Movie.mp4', 'Exports', 'Out.mp4', 'secret.txt', 'keep.db', 'to_doc_file', 'to_documents', 'to_outside_dir', 'to_outside_file',
        'to_inside_file', 'dangling_outside', 'loop', 'project.dnproj', 'u1', 'thumbs', 'cafe\u0301', 'caf\u00E9', 'other',
      ];
      final insideNames = ['projects', 'pr_a', 'media', 'ab', 'abcdef', 'thumbs', 'work', 'picks', 'drops', 'u1', 'u2', 'project.dnproj', 'clip.mov', 'to_inside_file', 'to_doc_file', 'to_documents', 'to_outside_dir', 'loop', 'dangling_outside', '..'];
      List<String> bases() => [c.dir.path, c.roots.support, c.roots.cache, c.roots.documents, c.roots.editorSupport, c.roots.editorCache, c.roots.projectDir('pr_a'), c.roots.workDir, '/', 'rel'];
      List<String> inside() => [c.roots.editorSupport, c.roots.editorCache, c.roots.projectsDir, c.roots.projectDir('pr_a'), c.roots.mediaDir, c.roots.workDir];
      int editorEntries() => [c.roots.editorSupport, c.roots.editorCache].fold(0, (n, d) => n + Directory(d).listSync(recursive: true, followLinks: false).length);
      var refusedCount = 0, deletedCount = 0;
      for (var i = 0; i < 2500; i++) {
        if (i % 8 == 0 && i > 0) {
          // Rebuild the editor tree that legit deletions eat into.
          c.dispose();
          c = Container.create();
          w = World(c);
          deleter = OwnedFileDeleter(c.roots, assertOnViolation: false);
          protectedBefore = w.protectedFiles;
        }
        // Half of the attempts aim at a real entry of the editor tree (possibly spelled oddly) so
        // legitimate deletions happen too.
        var path = '';
        if (rnd.nextBool()) {
          final existing = [for (final d in inside()) if (Directory(d).existsSync()) ...Directory(d).listSync(recursive: true, followLinks: false)];
          if (existing.isNotEmpty) {
            final e = existing[rnd.nextInt(existing.length)].path;
            path = switch (rnd.nextInt(5)) {
              0 => p.join(p.dirname(e), '..', p.basename(p.dirname(e)), p.basename(e)),
              1 => p.join(e, insideNames[rnd.nextInt(insideNames.length)]),
              2 => p.join(e, '..', '..', insideNames[rnd.nextInt(insideNames.length)]),
              _ => e,
            };
          }
        }
        if (path.isEmpty) {
          final parts = List.generate(1 + rnd.nextInt(8), (_) => names[rnd.nextInt(names.length)]);
          final starts = bases();
          path = p.joinAll([starts[rnd.nextInt(starts.length)], ...parts]);
        }
        if (rnd.nextInt(8) == 0) path = '$path/';
        if (rnd.nextInt(30) == 0) path = path.replaceAll('/', '//');
        if (!path.startsWith('/') && rnd.nextInt(2) == 0) path = '/$path';
        // The names above exist nowhere at the filesystem root, so '/'-based paths resolve to nothing.
        try {
          final entries = editorEntries();
          await deleter.delete(path, recursive: rnd.nextBool());
          if (editorEntries() < entries) deletedCount++;
        } on OwnershipViolation {
          refusedCount++;
        } on StoreFailure {
          // unresolvable (loops, files used as directories): nothing deleted
        }
        w.expectProtectedIntact(protectedBefore, 'attempt $i: $path');
      }
      expect(refusedCount, greaterThan(500));
      expect(deletedCount, greaterThan(100), reason: 'the fuzz also exercises legitimate deletions');
    });
  });
}
