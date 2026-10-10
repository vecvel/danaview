// OWNER: CORE-25
//
// The writer isolate and the per-project LatestWinsQueue.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:vwish_editor_core/store.dart';

import '../fs/support/harness.dart';

void main() {
  group('LatestWinsQueue', () {
    test('runs one task at a time in order', () async {
      final q = LatestWinsQueue<int>();
      final log = <String>[];
      Future<int> task(int n) async {
        log.add('start $n');
        await Future<void>.delayed(const Duration(milliseconds: 5));
        log.add('end $n');
        return n;
      }

      final r = await Future.wait([q.enqueue('a', () => task(1)), q.enqueue('b', () => task(2))]);
      expect(r, [1, 2]);
      expect(log, ['start 1', 'end 1', 'start 2', 'end 2']);
      expect(q.isIdle, isTrue);
    });

    test('a newer request replaces pending ones it supersedes, transitively', () async {
      final q = LatestWinsQueue<int>();
      final ran = <int>[];
      Future<int> task(int n) async {
        ran.add(n);
        await Future<void>.delayed(const Duration(milliseconds: 2));
        return n;
      }

      final f = [
        for (var i = 1; i <= 5; i++) q.enqueue('main', () => task(i), supersedes: const {'main'}),
      ];
      expect(await Future.wait(f), [1, 5, 5, 5, 5]);
      expect(ran, [1, 5]);
    });

    test('kinds outside supersedes are kept; errors reach followers', () async {
      final q = LatestWinsQueue<int>();
      final blocker = Completer<void>();
      final first = q.enqueue('main', () async {
        await blocker.future;
        return 0;
      });
      final journal = q.enqueue('journal', () async => 1, supersedes: const {'journal'});
      final main = q.enqueue('main', () async => throw const StoreFailure(StoreFailureKind.diskFull), supersedes: const {'main'});
      final journal2 = q.enqueue('journal', () async => 3, supersedes: const {'journal'});
      final mainFails = expectLater(main, throwsA(isA<StoreFailure>()));
      blocker.complete();
      expect(await first, 0);
      expect(await journal, 3, reason: 'superseded by the later journal request');
      await mainFails;
      expect(await journal2, 3);
      await q.idle();
    });
  });

  group('IsolateProjectWriter', () {
    late Container c;
    late IsolateProjectWriter w;
    setUp(() async {
      c = Container.create();
      w = await IsolateProjectWriter.spawn(c.roots);
    });
    tearDown(() async {
      await w.close();
      c.dispose();
    });

    DocumentStamp stamp(int rev, {String? base}) =>
        DocumentStamp(app: '1.1.0+3', savedAt: DateTime.utc(2026, 10, 10), docRevision: rev, saveId: 'sv_$rev', baseSaveId: base);

    test('hashes and writes documents (atomic and direct) and files', () async {
      final body = Uint8List.fromList(utf8.encode('{"id":"pr_x"}'));
      final main = p.join(c.roots.projectDir('pr_x'), 'project.vwproj');
      final header = await w.writeDocument(main, body, stamp(3));
      expect(header.docRevision, 3);
      expect(header.matchesBody(body), isTrue);
      final read = await VwprojFiles().read(main);
      expect(read.document.body, body);
      await w.writeDocument(main, body, stamp(4));
      expect(File(AtomicFile.backupPath(main)).existsSync(), isTrue, reason: 'atomic write keeps .bak');

      final slot = p.join(c.roots.projectDir('pr_x'), 'journal', 'a.vwproj');
      final jh = await w.writeDocument(slot, body, stamp(5, base: 'sv_4'), atomic: false);
      expect(jh.baseSaveId, 'sv_4');
      expect(VwprojFormat.parse(File(slot).readAsBytesSync()).header.docRevision, 5);
      expect(File(AtomicFile.backupPath(slot)).existsSync(), isFalse);

      final meta = p.join(c.roots.projectDir('pr_x'), 'meta.json');
      await w.writeFile(meta, Uint8List.fromList([1, 2, 3]));
      expect(File(meta).readAsBytesSync(), [1, 2, 3]);

      // Same bytes as the inline writer.
      final inline = InlineProjectWriter();
      final other = p.join(c.roots.projectDir('pr_y'), 'project.vwproj');
      await inline.writeDocument(other, body, stamp(3));
      final mainAt3 = VwprojFormat.encode(header, body);
      expect(File(other).readAsBytesSync(), mainAt3);
    });

    test('failures come back as StoreFailure; the writer keeps working', () async {
      final blocker = c.put(p.join(c.roots.editorSupport, 'file'), [1]);
      await expectLater(
        w.writeFile(p.join(blocker, 'below', 'x.json'), Uint8List.fromList([1])),
        throwsA(isA<StoreFailure>()),
      );
      final ok = p.join(c.roots.editorSupport, 'ok.json');
      await w.writeFile(ok, Uint8List.fromList([7]));
      expect(File(ok).readAsBytesSync(), [7]);
    });

    test('after close requests fail', () async {
      await w.close();
      await expectLater(w.writeFile(p.join(c.roots.editorSupport, 'x'), Uint8List(1)), throwsA(isA<StoreFailure>()));
    });
  });
}
