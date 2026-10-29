// OWNER: HOM-30
//
// The saved signatures store (lib/src/signatures/signature_store.dart) on a real temporary folder:
// add, list (newest first, kind and size from the file), delete, delete all, the cap of 10 (refused,
// never a silent delete), PNGs only, an app-private path beside (never inside) the Danaview
// folders' library root, the folder marked excluded from backups, no partial files, and nothing
// logged: no print or debugPrint and no path in toString.

import 'dart:async';
import 'dart:io';

import 'package:danaview_documents/danaview_documents.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'signature_fakes.dart';

void main() {
  late Directory support;
  late List<String> excluded;
  late int tick;
  late FileSignatureStore store;

  setUp(() {
    support = Directory.systemTemp.createTempSync('dv_sig_');
    excluded = [];
    tick = 0;
    store = FileSignatureStore.inAppSupport(
      support.path,
      excludeFromBackup: (p) async => excluded.add(p),
      clock: () => DateTime.utc(2026, 10, 30).add(Duration(seconds: tick++)),
    );
  });

  tearDown(() => support.deleteSync(recursive: true));

  test('the folder is app-private: <app support>/signatures beside the library root, excluded from backups', () async {
    expect(store.directory.path, '${support.path}${Platform.pathSeparator}signatures');
    final library = '${support.path}${Platform.pathSeparator}library';
    expect(store.directory.path.startsWith('$library${Platform.pathSeparator}'), isFalse, reason: 'never inside the Danaview folders');
    expect(excluded, isEmpty, reason: 'nothing happens before the first save');
    await store.add(fakePng(300, 100), kind: SignatureKind.drawn);
    expect(excluded, [store.directory.path], reason: 'the folder is marked once');
    await store.add(fakePng(300, 100), kind: SignatureKind.typed);
    expect(excluded, hasLength(1));
    expect(store.directory.existsSync(), isTrue);
  });

  test('add, list newest first with kind and size, delete one, delete all; listeners hear each change', () async {
    var changes = 0;
    store.addListener(() => changes++);
    expect(await store.list(), isEmpty, reason: 'no folder yet');
    final a = await store.add(fakePng(300, 100), kind: SignatureKind.drawn);
    final b = await store.add(fakePng(500, 125), kind: SignatureKind.typed);
    final c = await store.add(fakePng(400, 80), kind: SignatureKind.imported);
    final listed = await store.list();
    expect(listed.map((s) => s.id), [c.id, b.id, a.id]);
    expect(listed.map((s) => s.kind), [SignatureKind.imported, SignatureKind.typed, SignatureKind.drawn]);
    expect((listed[1].width, listed[1].height), (500, 125));
    expect(listed[1].aspectRatio, 4);
    expect(File(listed[0].path).existsSync(), isTrue);
    expect(listed.every((s) => File(s.path).parent.path == store.directory.path), isTrue);

    await store.delete(b.id);
    expect((await store.list()).map((s) => s.id), [c.id, a.id]);
    await store.delete(b.id);
    await store.delete('../escape');
    expect(await store.count(), 2);

    // A foreign file is ignored by the list and cleared by Delete all, with a leftover part.
    File('${store.directory.path}/notes.txt').writeAsStringSync('x');
    File('${store.directory.path}/sig-1-drawn.png.part').writeAsStringSync('x');
    expect(await store.count(), 2);
    await store.deleteAll();
    expect(await store.list(), isEmpty);
    expect(store.directory.listSync(), isEmpty);
    expect(changes, 3 + 1 + 1);
  });

  test('at most 10: the 11th is refused and nothing is deleted', () async {
    for (var i = 0; i < SignatureStore.maxCount; i++) {
      await store.add(fakePng(300, 100), kind: SignatureKind.drawn);
    }
    final before = (await store.list()).map((s) => s.id).toList();
    await expectLater(store.add(fakePng(300, 100), kind: SignatureKind.typed), throwsA(isA<SignatureStoreFullException>()));
    expect((await store.list()).map((s) => s.id), before);
    await store.delete(before.last);
    await store.add(fakePng(300, 100), kind: SignatureKind.typed);
    expect(await store.count(), SignatureStore.maxCount);
  });

  test('only PNGs are saved and no partial file stays behind', () async {
    await expectLater(store.add(Uint8List.fromList(List.filled(40, 7)), kind: SignatureKind.drawn), throwsArgumentError);
    await store.add(fakePng(10, 10), kind: SignatureKind.drawn);
    expect(store.directory.listSync().map((f) => f.path).where((p) => p.endsWith('.part')), isEmpty);
    expect(SignatureStore.pngSize(fakePng(640, 160)), (640, 160));
    expect(SignatureStore.pngSize(Uint8List(10)), (0, 0));
  });

  test('nothing is logged: no print, no debugPrint, no path in toString', () async {
    final printed = <String>[];
    final oldDebugPrint = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) => printed.add(m ?? '');
    addTearDown(() => debugPrint = oldDebugPrint);
    await runZoned(
      () async {
        final s = await store.add(fakePng(300, 100), kind: SignatureKind.drawn);
        await store.list();
        await store.delete(s.id);
        await store.add(fakePng(300, 100), kind: SignatureKind.typed);
        await expectLater(store.add(Uint8List(3), kind: SignatureKind.drawn), throwsArgumentError);
        await store.deleteAll();
      },
      zoneSpecification: ZoneSpecification(print: (self, parent, zone, line) => printed.add(line)),
    );
    expect(printed, isEmpty);
    final s = await store.add(fakePng(300, 100), kind: SignatureKind.drawn);
    expect(s.toString(), isNot(contains(support.path)));
    expect(s.toString(), isNot(contains('.png')));
    expect(const SignatureStoreFullException().toString(), isNot(contains('/')));
  });

  test('a backup flag that fails does not stop saving', () async {
    final failing = FileSignatureStore(Directory('${support.path}/other'), excludeFromBackup: (_) async => throw StateError('no'));
    final s = await failing.add(fakePng(30, 10), kind: SignatureKind.drawn);
    expect(File(s.path).existsSync(), isTrue);
  });
}
