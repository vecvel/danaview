// OWNER: HOM-17
//
// retryOnSharingViolation, the one path every rename and delete of an import part takes: on
// Windows a part another handle still holds (an antivirus scanner, the indexer) fails with
// ERROR_SHARING_VIOLATION (32) for a moment, so the call is retried a few times with a short
// backoff; any other error, and every error on another host, is rethrown at once.

import 'dart:io';

import 'package:danaview_library/testing.dart';
import 'package:test/test.dart';

FileSystemException _err(int code) => PathAccessException('/lib/imports/j.part', OSError('in use', code), 'Cannot rename file');

void main() {
  group('retryOnSharingViolation', () {
    test('retries a sharing violation with growing waits, then returns the result', () {
      var calls = 0;
      final waits = <Duration>[];
      final r = retryOnSharingViolation(() {
        if (++calls < 3) throw _err(32);
        return 'moved';
      }, windows: true, sleep: waits.add);
      expect(r, 'moved');
      expect(calls, 3);
      expect(waits, sharingViolationBackoff.take(2));
    });

    test('a lock violation (33) is retried too', () {
      var calls = 0;
      retryOnSharingViolation(() {
        if (++calls == 1) throw _err(33);
      }, windows: true, sleep: (_) {});
      expect(calls, 2);
    });

    test('gives up after the backoff and rethrows the last failure', () {
      var calls = 0;
      final waits = <Duration>[];
      expect(
        () => retryOnSharingViolation<void>(() {
          calls++;
          throw _err(32);
        }, windows: true, sleep: waits.add),
        throwsA(isA<PathAccessException>().having((e) => e.osError?.errorCode, 'errno', 32)),
      );
      expect(calls, sharingViolationBackoff.length + 1);
      expect(waits, sharingViolationBackoff);
      final total = waits.fold(Duration.zero, (a, b) => a + b);
      expect(total, lessThan(const Duration(seconds: 2)), reason: 'the writer is blocked meanwhile');
    });

    test('any other error is rethrown at once', () {
      var calls = 0;
      expect(
        () => retryOnSharingViolation<void>(() {
          calls++;
          throw _err(2); // not found
        }, windows: true, sleep: (_) => fail('no wait')),
        throwsA(isA<FileSystemException>()),
      );
      expect(calls, 1);
      expect(() => retryOnSharingViolation<void>(() => throw StateError('x'), windows: true, sleep: (_) => fail('no wait')), throwsStateError);
    });

    test('off Windows errno 32 (EPIPE there) is not retried: the call runs exactly once', () {
      var calls = 0;
      expect(
        () => retryOnSharingViolation<void>(() {
          calls++;
          throw _err(32);
        }, windows: false, sleep: (_) => fail('no wait')),
        throwsA(isA<FileSystemException>()),
      );
      expect(calls, 1);
    });

    test('a call that succeeds runs once without waiting', () {
      var calls = 0;
      expect(retryOnSharingViolation(() => ++calls, windows: true, sleep: (_) => fail('no wait')), 1);
    });
  });

  group('LibraryFs part files', () {
    late Directory dir;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('hom17_fs_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
    });

    test('deletePart and movePartIntoEntry work on a closed part (and deletePart of a missing one is a no-op)', () {
      final fs = LibraryFs(LibraryPaths(dir.path))..ensureLayout();
      final id = EntryId.random();
      File(fs.paths.resolve('imports/a.part')).writeAsBytesSync([1, 2, 3]);
      fs.createEntryDir(id);
      fs.movePartIntoEntry('imports/a.part', id, 'a.bin');
      expect(fs.entryFileSize(id, 'a.bin'), 3);
      expect(fs.partExists('imports/a.part'), isFalse);
      File(fs.paths.resolve('imports/b.part')).writeAsBytesSync([1]);
      fs.deletePart('imports/b.part');
      expect(fs.partExists('imports/b.part'), isFalse);
      fs.deletePart('imports/missing.part');
    });
  });
}
