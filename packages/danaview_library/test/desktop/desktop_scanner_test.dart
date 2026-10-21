// OWNER: HOM-03
//
// The desktop scanner (V2-109) over real temporary fixture trees: kinds, skipped packages and
// hidden entries, link loops, a removed drive, incremental rescans by modification time, and a
// read-only tree that is byte- and timestamp-identical after scanning (rule 27).

import 'dart:io';

// Direct imports keep this suite independent of the other directories behind the package barrel.
import 'package:danaview_library/src/desktop/desktop.dart';
import 'package:danaview_library/src/model/document_item.dart';
import 'package:danaview_library/src/model/file_kind.dart';
import 'package:danaview_library/src/model/media_item.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'desktop_test_fs.dart';

final bool _posix = !Platform.isWindows;

void main() {
  late Directory tmp;
  late String rootPath;
  late DesktopRoot root;

  void write(String rel, [String content = 'x']) {
    final f = File(p.join(rootPath, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  void ln(String rel, String target) {
    final l = Link(p.join(rootPath, rel));
    l.parent.createSync(recursive: true);
    l.createSync(target);
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hom03_');
    rootPath = tmp.resolveSymbolicLinksSync();
    root = DesktopRoot.at(DesktopRootKind.pictures, rootPath, label: 'Pictures');
  });

  tearDown(() {
    if (_posix && tmp.existsSync()) Process.runSync('chmod', ['-R', 'u+w', tmp.path]);
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  void buildFixture() {
    write('IMG_0001.JPG');
    write('holiday/beach.heic');
    write('holiday/day 2/sunset.png');
    write('raw/DSC_0042.NEF');
    write('clips/trip.mov');
    write('docs/notes.pdf');
    write('docs/readme.txt');
    write('unknown.xyz');
    write('.hidden.jpg');
    write('.thumbs/cached.jpg');
    write('Photos Library.photoslibrary/originals/A/a.jpg');
    write('Lightroom Catalog Previews.lrdata/p.jpg');
  }

  group('fixture trees', () {
    test('photos only by default, with kinds, linked ids, sizes and RAW flags', () async {
      buildFixture();
      final result = await DesktopScanner().scan(root);
      expect(result.available, isTrue);
      expect(result.items.map((i) => i.id.value), [
        'lk:${root.id}/IMG_0001.JPG',
        'lk:${root.id}/holiday/beach.heic',
        'lk:${root.id}/holiday/day 2/sunset.png',
        'lk:${root.id}/raw/DSC_0042.NEF',
      ]);
      expect(result.items, everyElement(isA<PhotoMediaItem>()));
      final raw = result.items.whereType<PhotoMediaItem>().singleWhere((i) => i.name == 'DSC_0042.NEF');
      expect(raw.isRaw, isTrue);
      expect(raw.uri, p.join(rootPath, 'raw', 'DSC_0042.NEF'));
      expect(raw.sizeBytes, 1);
      expect(result.items.whereType<PhotoMediaItem>().singleWhere((i) => i.name == 'beach.heic').mimeType, 'image/heic');
      expect(result.diff.added, hasLength(4));
      expect(result.diff.removed, isEmpty);
    });

    test('videos and documents on request, each with the right kind', () async {
      buildFixture();
      final result = await DesktopScanner(kinds: {FileKind.photo, FileKind.video, FileKind.document}).scan(root);
      final byName = {for (final i in result.items) i.name: i};
      expect(byName.keys.toSet(), {'IMG_0001.JPG', 'beach.heic', 'sunset.png', 'DSC_0042.NEF', 'trip.mov', 'notes.pdf', 'readme.txt'});
      expect(byName['trip.mov'], isA<VideoMediaItem>());
      expect(byName['trip.mov']!.kind, FileKind.video);
      expect((byName['notes.pdf']! as DocumentItem).docKind, DocumentKind.pdf);
      expect((byName['readme.txt']! as DocumentItem).docKind, DocumentKind.text);
      expect(byName.containsKey('unknown.xyz'), isFalse, reason: 'unclassified files are not listed');
    });

    test('a depth limit stops the walk; an item limit truncates', () async {
      write('a/b/c/deep.jpg');
      write('top.jpg');
      write('a/mid.jpg');
      expect((await DesktopScanner(maxDepth: 1).scan(root)).items.map((i) => i.name), ['mid.jpg', 'top.jpg']);
      final limited = await DesktopScanner(maxItems: 2).scan(root);
      expect(limited.items, hasLength(2));
      expect(limited.truncated, isTrue);
    });
  });

  group('other platforms', () {
    test('Windows paths: drive roots, backslash joins, system folders skipped, ids use "/"', () async {
      final fs = MemoryDesktopFs(p.windows)
        ..file(r'E:\DCIM\100CANON\IMG_0001.CR3')
        ..file(r'E:\$RECYCLE.BIN\old.jpg')
        ..file(r'E:\System Volume Information\x.jpg')
        ..file(r'E:\clip.MP4');
      final drive = DesktopRoot.at(DesktopRootKind.volume, r'E:\', label: 'E:');
      final result = await DesktopScanner(fs: fs, pathContext: p.windows, kinds: {FileKind.photo, FileKind.video}).scan(drive);
      expect(result.items.map((i) => (i.id.value, i.uri)), [
        ('lk:${drive.id}/DCIM/100CANON/IMG_0001.CR3', r'E:\DCIM\100CANON\IMG_0001.CR3'),
        ('lk:${drive.id}/clip.MP4', r'E:\clip.MP4'),
      ]);
      expect((result.items.first as PhotoMediaItem).isRaw, isTrue);
    });

    test('Linux media mount: lost+found skipped', () async {
      final fs = MemoryDesktopFs(p.posix)
        ..file('/media/ana/SD/DCIM/a.jpg')
        ..file('/media/ana/SD/lost+found/b.jpg');
      final sd = DesktopRoot.at(DesktopRootKind.volume, '/media/ana/SD', label: 'SD');
      final result = await DesktopScanner(fs: fs, pathContext: p.posix).scan(sd);
      expect(result.items.map((i) => i.name), ['a.jpg']);
    });
  });

  group('links', () {
    test('link loops are ignored and the scan ends', () async {
      write('a/one.jpg');
      ln('a/loop', rootPath); // back to the root
      ln('a/self', p.join(rootPath, 'a')); // to its own directory
      ln('b', 'b'); // a link to itself
      ln('dangling.jpg', p.join(rootPath, 'missing.jpg'));
      final result = await DesktopScanner().scan(root).timeout(const Duration(seconds: 10));
      expect(result.items.map((i) => i.name), ['one.jpg']);
    }, skip: _posix ? false : 'links need POSIX permissions');

    test('a link leaving the root is followed once, loops through it end', () async {
      final outside = Directory.systemTemp.createTempSync('hom03_out_');
      addTearDown(() => outside.deleteSync(recursive: true));
      final out = outside.resolveSymbolicLinksSync();
      File(p.join(out, 'shared.jpg')).writeAsStringSync('x');
      Directory(p.join(out, 'sub')).createSync();
      File(p.join(out, 'sub', 'deeper.jpg')).writeAsStringSync('x');
      Link(p.join(out, 'sub', 'back')).createSync(out);
      ln('external', out);
      ln('external again', out);
      final result = await DesktopScanner().scan(root);
      expect(result.items.map((i) => i.id.value), [
        'lk:${root.id}/external/shared.jpg',
        'lk:${root.id}/external/sub/deeper.jpg',
      ]);
    }, skip: _posix ? false : 'links need POSIX permissions');
  });

  group('removed drives', () {
    test('a volume that is gone scans as unavailable, reports its items removed, and never throws', () async {
      write('DCIM/100/IMG_1.JPG');
      final volume = DesktopRoot.at(DesktopRootKind.volume, rootPath, label: 'Card');
      final first = await DesktopScanner().scan(volume);
      expect(first.items, hasLength(1));
      tmp.deleteSync(recursive: true);
      final second = await DesktopScanner().scan(volume, previous: first.cache);
      expect(second.available, isFalse);
      expect(second.items, isEmpty);
      expect(second.diff.removed, [first.items.single.id]);
    });

    test('the volume disappears from discovery once unmounted', () async {
      final mounts = Directory(p.join(rootPath, 'Volumes'))..createSync();
      Directory(p.join(mounts.path, 'Card')).createSync();
      Directory(p.join(mounts.path, 'Stick')).createSync();
      final resolver = DesktopRootResolver(
        platform: DesktopPlatform.macos,
        environment: const {'HOME': '/nonexistent-home'},
        volumeMountDirs: [mounts.path],
      );
      expect((await resolver.volumes()).map((r) => r.label), ['Card', 'Stick']);
      Directory(p.join(mounts.path, 'Stick')).deleteSync();
      expect((await resolver.volumes()).map((r) => r.label), ['Card']);
      mounts.deleteSync(recursive: true);
      expect(await resolver.volumes(), isEmpty);
    });

    test('a directory removed during the walk is skipped', () async {
      write('a/one.jpg');
      write('b/two.jpg');
      final fs = _RemovingFs(const IoDesktopFs(), removeOnFirstList: p.join(rootPath, 'b'));
      final result = await DesktopScanner(fs: fs).scan(root);
      expect(result.available, isTrue);
      expect(result.items.map((i) => i.name), ['one.jpg']);
    });
  });

  group('incremental rescan by modification time', () {
    test('unchanged settled directories are not listed again; changes are diffed', () async {
      write('IMG_1.JPG');
      write('a/IMG_2.JPG');
      write('a/b/IMG_3.JPG');
      final old = DateTime.now().subtract(const Duration(hours: 1));
      for (final d in [rootPath, p.join(rootPath, 'a'), p.join(rootPath, 'a', 'b')]) {
        _touchDir(d, old);
      }
      final fs = CountingDesktopFs(const IoDesktopFs());
      final scanner = DesktopScanner(fs: fs);
      final first = await scanner.scan(root);
      expect(first.listedDirectories, 3);
      expect(first.cache.fileCount, 3);

      fs.reset();
      final second = await scanner.scan(root, previous: first.cache);
      expect(second.listedDirectories, 0);
      expect(second.reusedDirectories, 3);
      expect(fs.calls['list'], isNull);
      expect(second.diff.isEmpty, isTrue);
      expect(identical(second.items.first, first.items.first), isTrue, reason: 'unchanged items are reused');

      // A new file changes only its directory's modification time.
      write('a/IMG_4.JPG');
      File(p.join(rootPath, 'IMG_1.JPG')).writeAsStringSync('longer content');
      File(p.join(rootPath, 'a', 'b', 'IMG_3.JPG')).deleteSync();
      fs.reset();
      final third = await scanner.scan(root, previous: second.cache);
      expect(fs.listed.toSet(), {p.join(rootPath, 'a'), p.join(rootPath, 'a', 'b')});
      expect(third.diff.added.map((i) => i.name), ['IMG_4.JPG']);
      expect(third.diff.changed.map((i) => i.name), ['IMG_1.JPG']);
      expect(third.diff.removed.map((i) => i.value), ['lk:${root.id}/a/b/IMG_3.JPG']);
      expect(third.items.map((i) => i.name), ['IMG_1.JPG', 'IMG_2.JPG', 'IMG_4.JPG']);
    });

    test('a directory modified within the settle window is listed again', () async {
      write('IMG_1.JPG');
      final first = await DesktopScanner().scan(root);
      final fs = CountingDesktopFs(const IoDesktopFs());
      await DesktopScanner(fs: fs).scan(root, previous: first.cache);
      expect(fs.calls['list'], 1, reason: 'mtime not older than the listing by the settle window');
    });

    test('a cache from another root is ignored', () async {
      write('IMG_1.JPG');
      final other = DesktopRoot.at(DesktopRootKind.custom, rootPath, label: 'x');
      final first = await DesktopScanner().scan(other);
      final result = await DesktopScanner().scan(root, previous: first.cache);
      expect(result.diff.added, hasLength(1));
      expect(result.diff.removed, isEmpty);
    });
  });

  group('read-only (rule 27)', () {
    test('a read-only tree scans fully and is byte- and timestamp-identical afterwards', () async {
      buildFixture();
      ln('loop', rootPath);
      Process.runSync('chmod', ['-R', 'a-w', rootPath]);
      final before = _snapshot(rootPath);
      final scanner = DesktopScanner(kinds: {FileKind.photo, FileKind.video, FileKind.document});
      final first = await scanner.scan(root);
      await scanner.scan(root, previous: first.cache);
      expect(first.items, hasLength(7));
      expect(_snapshot(rootPath), before);
      // The tree really is read-only: a write fails.
      expect(() => File(p.join(rootPath, 'probe.jpg')).writeAsStringSync('x'), throwsA(isA<FileSystemException>()));
    }, skip: _posix ? false : 'chmod is POSIX');

    test('the desktop sources contain no write, rename, delete or create call', () {
      final dir = Directory(p.join(Directory.current.path, 'lib', 'src', 'desktop'));
      final writeApi = RegExp(
        r'\.\s*(?:writeAsBytes|writeAsBytesSync|writeAsString|writeAsStringSync|openWrite|rename|renameSync|delete|deleteSync|copy|copySync|create|createSync|setLastModified|setLastModifiedSync|setLastAccessed|truncate|writeFrom|writeString|writeByte|flush)\s*\(|FileMode\s*\.|Process\s*\.',
      );
      final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.dart')).toList();
      expect(files, isNotEmpty);
      for (final f in files) {
        final code = f.readAsLinesSync().where((l) => !l.trimLeft().startsWith('//')).join('\n');
        expect(writeApi.hasMatch(code), isFalse, reason: '${p.basename(f.path)} calls a write API');
      }
    });
  });
}

void _touchDir(String path, DateTime time) {
  final stamp = '${time.year.toString().padLeft(4, '0')}${_pad2(time.month)}${_pad2(time.day)}${_pad2(time.hour)}${_pad2(time.minute)}';
  final r = Process.runSync('touch', ['-t', stamp, path]);
  if (r.exitCode != 0) throw StateError('touch failed');
}

String _pad2(int v) => v.toString().padLeft(2, '0');

/// Every path under [root] with its type, size, modification time and bytes (links: target).
Map<String, String> _snapshot(String root) {
  final out = <String, String>{};
  for (final e in Directory(root).listSync(recursive: true, followLinks: false)) {
    final rel = p.relative(e.path, from: root);
    if (e is Link) {
      out[rel] = 'link ${e.targetSync()}';
    } else {
      final s = e.statSync();
      out[rel] = '${s.type} ${s.size} ${s.modified.microsecondsSinceEpoch} ${s.mode}'
          '${e is File ? ' ${e.readAsBytesSync().join(',')}' : ''}';
    }
  }
  final rs = Directory(root).statSync();
  out['.'] = '${rs.modified.microsecondsSinceEpoch} ${rs.mode}';
  return out;
}

/// Simulates a directory vanishing (a drive pulled) between its parent's listing and its own.
final class _RemovingFs implements DesktopFs {
  _RemovingFs(this.inner, {required this.removeOnFirstList});

  final DesktopFs inner;
  final String removeOnFirstList;
  bool _removed = false;

  @override
  Future<List<DesktopDirEntry>?> list(String path) async {
    final out = await inner.list(path);
    if (!_removed) {
      _removed = true;
      Directory(removeOnFirstList).deleteSync(recursive: true);
    }
    return out;
  }

  @override
  Future<DesktopStat?> stat(String path) => inner.stat(path);

  @override
  Future<DesktopStat?> statLink(String path) => inner.statLink(path);

  @override
  Future<String?> resolve(String path) => inner.resolve(path);

  @override
  Future<String?> readText(String path, {int maxBytes = 65536}) => inner.readText(path, maxBytes: maxBytes);
}
