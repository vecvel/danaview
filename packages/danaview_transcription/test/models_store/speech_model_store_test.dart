// OWNER: AI-09
//
// The model store: states, layout, atomic manifest, load-time integrity, recovery, deletion and
// the test-only installFromFile seam.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:danaview_transcription/danaview_transcription.dart';

import 'support/fake_model_server.dart';
import 'support/harness.dart';

Future<SpeechModelManifest> readManifest(Harness h) async =>
    SpeechModelManifest.tryDecode(await File(h.layout.manifest).readAsString())!;

void main() {
  late Harness h;

  setUp(() async {
    h = await Harness.create();
  });
  tearDown(() => h.dispose());

  Future<void> install() => h.store.download(h.consent()).done;

  group('layout', () {
    test('files live under <support>/danaview/speech/models/', () async {
      await install();
      expect(h.layout.dir, p.join(h.dir.path, 'danaview', 'speech', 'models'));
      expect(h.file(h.model).path, p.join(h.layout.dir, h.model.fileName));
      expect(h.part(h.model).path, '${h.file(h.model).path}.part');
      expect(h.sidecar(h.model).path, '${h.file(h.model).path}.part.json');
      expect(h.layout.manifest, p.join(h.layout.dir, 'manifest.json'));
      expect(h.platform.excluded, contains(h.layout.dir), reason: 'the folder is excluded from backup');
    });

    test('filesFor returns the model and VAD paths only when both are ready', () async {
      expect(await h.store.filesFor(h.model.id), isNull);
      await h.store.download(h.consent(withVad: false)).done;
      expect(await h.store.filesFor(h.model.id), isNull);
      await h.store.download(h.consent()).done;
      final files = (await h.store.filesFor(h.model.id))!;
      expect(files.modelPath, h.layout.fileOf(h.model));
      expect(files.vadPath, h.layout.fileOf(h.vad));
      expect(files.model.spec, h.model);
    });
  });

  group('states', () {
    test('absent -> downloading -> ready', () async {
      expect(await h.store.statusOf(h.model.id), isA<SpeechModelMissing>());
      expect(await h.store.statusOf('unknown-model'), isA<SpeechModelMissing>());
      h.server.cdnScript.add(const Cdn.stallAfter(1000));
      final dl = h.store.download(h.consent());
      final during = await h.store.statusOf(h.model.id);
      expect(during, isA<SpeechModelDownloading>());
      expect(await h.store.statusOf(h.vad.id), isA<SpeechModelDownloading>(), reason: 'the VAD is part of the running download');
      expect(await h.store.statusOf(h.model2.id), isA<SpeechModelMissing>());
      await waitFor(() => h.server.cdnRequests.isNotEmpty, reason: 'the stalled CDN request');
      dl.cancel(keepPartial: false);
      await expectFailure(dl.done, ModelDownloadFailureKind.cancelled);
      await install();
      final ready = await h.store.statusOf(h.model.id);
      expect(ready, isA<SpeechModelReady>());
      expect((ready as SpeechModelReady).model.spec, h.model);
      expect(await h.store.installed(h.model.id), isNotNull);
    });

    test('the status mirrors the phases, verifying included', () async {
      final dl = h.store.download(h.consent());
      final phases = <ModelDownloadPhase>[];
      dl.progress.listen((s) => phases.add(s.phase));
      final seen = <Type>{};
      final poll = Timer.periodic(const Duration(milliseconds: 1), (_) async {
        final s = await h.store.statusOf(h.model.id);
        seen.add(s.runtimeType);
      });
      await dl.done;
      poll.cancel();
      expect(phases, contains(ModelDownloadPhase.verifying));
      expect(seen, contains(SpeechModelDownloading));
    });

    test('corrupt: a damaged installed file is reported, not silently used', () async {
      await install();
      // Truncated.
      final bytes = await h.file(h.model).readAsBytes();
      await h.file(h.model).writeAsBytes(bytes.sublist(0, bytes.length - 1));
      expect(await h.store.statusOf(h.model.id), isA<SpeechModelCorrupt>());
      expect(await h.store.installed(h.model.id), isNull);
      expect((await h.store.inventory()).corruptIds, contains(h.model.id));
      // Wrong magic at the right size.
      final bad = Uint8List.fromList(bytes)..[0] = 0;
      await h.file(h.model).writeAsBytes(bad);
      expect(await h.store.statusOf(h.model.id), isA<SpeechModelCorrupt>());
      // Missing file with a manifest entry.
      await h.file(h.model).delete();
      expect(await h.store.statusOf(h.model.id), isA<SpeechModelCorrupt>());
    });

    test('markCorrupt (native load failed) deletes the file and reports corrupt until re-downloaded', () async {
      await install();
      await h.store.markCorrupt(h.model.id);
      expect(h.file(h.model).existsSync(), isFalse);
      expect(await h.store.statusOf(h.model.id), isA<SpeechModelCorrupt>());
      await install();
      expect(await h.store.statusOf(h.model.id), isA<SpeechModelReady>());
    });

    test('a manifest hash from an accepted legacy catalog still counts', () async {
      await install();
      final entry = (await readManifest(h)).entryOf(h.model.id)!;
      final legacy = ManifestEntry(
          id: entry.id, file: entry.file, sha256: 'feedbeef', bytes: entry.bytes, installedAt: entry.installedAt, verifiedAt: entry.verifiedAt);
      await File(h.layout.manifest).writeAsString((await readManifest(h)).upsert(legacy).encode());
      expect(await h.newStore().statusOf(h.model.id), isA<SpeechModelCorrupt>());
      expect(await h.newStore(legacy: {'feedbeef'}).statusOf(h.model.id), isA<SpeechModelReady>());
    });

    test('markUsed records lastUsedAt in the manifest', () async {
      await install();
      expect((await readManifest(h)).entryOf(h.model.id)!.lastUsedAt, isNull);
      await h.store.markUsed(h.model.id);
      expect((await readManifest(h)).entryOf(h.model.id)!.lastUsedAt, isNotNull);
      await h.store.markUsed('nothing-here');
    });
  });

  group('manifest', () {
    test('is written atomically (no temp file left) and survives a new store', () async {
      await install();
      expect(Directory(h.layout.dir).listSync().whereType<File>().where((f) => f.path.endsWith('.tmp')), isEmpty);
      expect(await h.newStore().statusOf(h.model.id), isA<SpeechModelReady>());
    });

    test('a lost manifest is rebuilt by hashing files whose size matches', () async {
      await install();
      await File(h.layout.manifest).delete();
      final fresh = h.newStore();
      expect(await fresh.statusOf(h.model.id), isA<SpeechModelReady>());
      expect(File(h.layout.manifest).existsSync(), isTrue);
      expect((await readManifest(h)).installed.map((e) => e.id), unorderedEquals([h.model.id, h.vad.id]));
    });

    test('a garbage manifest is treated as lost; a tampered file is deleted, not adopted', () async {
      await install();
      final bytes = await h.file(h.model).readAsBytes();
      await h.file(h.model).writeAsBytes(Uint8List.fromList(bytes)..[100] ^= 0xff);
      await File(h.layout.manifest).writeAsString('{"schema": 99');
      final fresh = h.newStore();
      expect(await fresh.statusOf(h.model.id), isA<SpeechModelMissing>());
      expect(h.file(h.model).existsSync(), isFalse);
      expect(await fresh.statusOf(h.vad.id), isA<SpeechModelReady>());
    });

    test('partials older than 7 days are swept, fresh ones kept', () async {
      await Directory(h.layout.dir).create(recursive: true);
      await h.part(h.model).writeAsBytes([1, 2, 3]);
      await h.sidecar(h.model).writeAsString('{}');
      await h.part(h.model2).writeAsBytes([1, 2, 3]);
      await h.part(h.model).setLastModified(DateTime.now().subtract(const Duration(days: 8)));
      await h.part(h.model2).setLastModified(DateTime.now().subtract(const Duration(days: 1)));
      final inv = await h.newStore().inventory();
      expect(h.part(h.model).existsSync(), isFalse);
      expect(h.sidecar(h.model).existsSync(), isFalse);
      expect(h.part(h.model2).existsSync(), isTrue);
      expect(inv.partials.map((e) => e.modelId), [h.model2.id]);
      expect(inv.partials.single.bytes, 3);
      expect(inv.partials.single.expectedBytes, h.model2.bytes);
    });
  });

  group('inventory, watch, measure', () {
    test('inventory lists installed files, partials and bytes; measure agrees', () async {
      await install();
      await seedPartialFor(h);
      final inv = await h.store.inventory();
      expect(inv.installed.map((m) => m.spec.id), unorderedEquals([h.model.id, h.vad.id]));
      expect(inv.has(h.model.id), isTrue);
      expect(inv.has(h.model2.id), isFalse);
      expect(inv.partials.single.modelId, h.model2.id);
      final usage = await h.store.measure();
      expect(usage.bytes, inv.totalBytes);
      expect(usage.bytes, greaterThanOrEqualTo(h.model.bytes + h.vad.bytes + 100));
      expect(usage.partialBytes, 100);
      expect(usage.files, greaterThanOrEqualTo(4));
    });

    test('measure of an empty store is zero', () async {
      expect((await h.store.measure()).bytes, 0);
    });

    test('watch emits inventories while a download runs', () async {
      final seen = <SpeechModelInventory>[];
      final sub = h.store.watch().listen(seen.add);
      await install();
      await waitFor(() => seen.any((i) => i.has(h.model.id)), reason: 'an inventory with the model');
      await sub.cancel();
    });
  });

  group('delete', () {
    test('is blocked while a job uses the models', () async {
      await install();
      h.jobRunning = true;
      expect(() => h.store.delete(h.model.id), throwsStateError);
      expect(() => h.store.deleteAll(), throwsStateError);
      expect(h.file(h.model).existsSync(), isTrue);
      h.jobRunning = false;
      await h.store.delete(h.model.id);
      expect(h.file(h.model).existsSync(), isFalse);
    });

    test('deleting the last model takes the VAD along; another model keeps it', () async {
      await install();
      await h.store.download(h.consent(spec: h.model2)).done;
      await h.store.delete(h.model.id);
      expect(h.file(h.model).existsSync(), isFalse);
      expect(h.file(h.vad).existsSync(), isTrue);
      expect(await h.store.statusOf(h.model2.id), isA<SpeechModelReady>());
      await h.store.delete(h.model2.id);
      expect(h.file(h.vad).existsSync(), isFalse);
      expect((await readManifest(h)).installed, isEmpty);
      expect(await h.store.statusOf(h.model.id), isA<SpeechModelMissing>());
    });

    test('deleteAll removes models, VAD, partials and sidecars', () async {
      await install();
      await seedPartialFor(h);
      await h.store.deleteAll();
      expect(Directory(h.layout.dir).listSync().whereType<File>(), isEmpty);
      expect((await h.store.inventory()).installed, isEmpty);
      expect((await h.store.measure()).bytes, 0);
    });

    test('after deletion the next use needs consent again (no consent memory)', () async {
      await install();
      await h.store.deleteAll();
      final dl = h.store.download(UserConsent.accepted(
        ConsentDisclosure.forTesting(
          modelId: h.model.id,
          fileName: h.model.fileName,
          host: 'other.example',
          cdnHost: SpeechModelCatalog.cdnHost,
          sha256: h.model.sha256,
          totalBytes: h.model.bytes + h.vad.bytes,
          includesVad: true,
        ),
        acceptedAt: DateTime.utc(2025),
      ));
      await expectFailure(dl.done, ModelDownloadFailureKind.consentMismatch);
    });

    test('deleting while that model downloads cancels the download and removes its partial', () async {
      h.server.cdnScript.add(const Cdn.stallAfter(5000));
      final dl = h.store.download(h.consent());
      await waitFor(() => h.part(h.model).existsSync() && h.part(h.model).lengthSync() >= 5000);
      await h.store.delete(h.model.id);
      await expectFailure(dl.done, ModelDownloadFailureKind.cancelled);
      expect(h.part(h.model).existsSync(), isFalse);
      expect(h.store.activeDownload, isNull);
    });

    test('deleteAll while downloading cancels without keeping the partial', () async {
      h.server.cdnScript.add(const Cdn.stallAfter(5000));
      final dl = h.store.download(h.consent());
      await waitFor(() => h.part(h.model).existsSync() && h.part(h.model).lengthSync() >= 5000);
      await h.store.deleteAll();
      await expectFailure(dl.done, ModelDownloadFailureKind.cancelled);
      expect(Directory(h.layout.dir).listSync().whereType<File>(), isEmpty);
    });
  });

  group('installFromFile (test-only, no network)', () {
    late File fixture;

    setUp(() async {
      fixture = File(p.join(h.dir.path, 'fixture.bin'));
    });

    test('installs a verified fixture and reports ready', () async {
      await fixture.writeAsBytes(h.modelData);
      final installed = await h.store.installFromFile(h.model, fixture.path);
      expect(installed.spec, h.model);
      await fixture.writeAsBytes(h.vadData);
      await h.store.installFromFile(h.vad, fixture.path);
      expect(await h.store.statusOf(h.model.id), isA<SpeechModelReady>());
      expect(await h.file(h.model).readAsBytes(), h.modelData);
      expect(h.server.requests, isEmpty);
      expect(h.platform.excluded, contains(h.layout.fileOf(h.model)));
    });

    test('asserts the sha256: same size, other content -> checksumMismatch, nothing installed', () async {
      await fixture.writeAsBytes(modelBytes(h.modelData.length, seed: 42));
      await expectFailure(h.store.installFromFile(h.model, fixture.path), ModelDownloadFailureKind.checksumMismatch);
      expect(h.file(h.model).existsSync(), isFalse);
      expect(h.part(h.model).existsSync(), isFalse);
      expect(await h.store.statusOf(h.model.id), isA<SpeechModelCorrupt>());
    });

    test('a wrong size -> sizeMismatch', () async {
      await fixture.writeAsBytes(h.modelData.sublist(0, 100));
      await expectFailure(h.store.installFromFile(h.model, fixture.path), ModelDownloadFailureKind.sizeMismatch);
    });
  });
}

Future<void> seedPartialFor(Harness h) async {
  await Directory(h.layout.dir).create(recursive: true);
  await h.part(h.model2).writeAsBytes(List.filled(100, 7));
  await h.sidecar(h.model2).writeAsString('{}');
}
