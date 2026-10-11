// OWNER: AI-09
//
// The downloader against a loopback fake server: every status path, resume, retry, verification
// and cancellation behaviour of ai.md §5.3. No real network.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_transcription/danaview_transcription.dart';
import 'package:danaview_whisper/danaview_whisper.dart' show AppStateChanged, BackgroundTaskExpiring, WhisperAppState;

import 'support/fake_model_server.dart';
import 'support/harness.dart';

/// Writes a partial download of [spec] holding the first [length] bytes of [data], as a killed
/// process would have left it.
Future<void> seedPartial(Harness h, SpeechModelSpec spec, Uint8List data, int length, {PartialSidecar? sidecar, bool writeSidecar = true}) async {
  await Directory(h.layout.dir).create(recursive: true);
  await h.part(spec).writeAsBytes(data.sublist(0, length));
  if (!writeSidecar) return;
  await h.sidecar(spec).writeAsString((sidecar ??
          PartialSidecar(
            url: spec.url,
            bytes: spec.bytes,
            sha256: spec.sha256,
            written: length,
            updatedAt: DateTime.now().toUtc(),
            catalogRevision: SpeechModelCatalog.revision,
          ))
      .encode());
}

int rangeStart(RecordedRequest r) => int.parse(RegExp(r'bytes=(\d+)-').firstMatch(r.range!)!.group(1)!);

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this.error);

  final Object error;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => throw error;

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  late Harness h;

  setUp(() async {
    h = await Harness.create();
  });
  tearDown(() => h.dispose());

  group('happy path', () {
    test('downloads the model and the VAD, verifies and installs atomically', () async {
      final dl = h.store.download(h.consent());
      final samples = <ModelDownloadProgress>[];
      dl.progress.listen(samples.add);
      final installed = await dl.done;

      expect(installed.spec, h.model);
      expect(await h.file(h.model).readAsBytes(), h.modelData);
      expect(await h.file(h.vad).readAsBytes(), h.vadData);
      expect(h.part(h.model).existsSync(), isFalse);
      expect(h.sidecar(h.model).existsSync(), isFalse);
      expect(File('${h.layout.manifest}.tmp').existsSync(), isFalse);

      final manifest = SpeechModelManifest.tryDecode(await File(h.layout.manifest).readAsString())!;
      expect(manifest.installed.map((e) => e.id), unorderedEquals([h.model.id, h.vad.id]));
      expect(manifest.entryOf(h.model.id)!.sha256, h.model.sha256);
      expect(manifest.entryOf(h.model.id)!.bytes, h.model.bytes);

      expect(samples.first.phase, ModelDownloadPhase.preparing);
      expect(samples.map((s) => s.phase).toSet(), {
        ModelDownloadPhase.preparing,
        ModelDownloadPhase.downloading,
        ModelDownloadPhase.verifying,
        ModelDownloadPhase.finishing,
      });
      expect(samples.last.received, h.model.bytes + h.vad.bytes);
      expect(samples.every((s) => s.total == h.model.bytes + h.vad.bytes), isTrue);
      for (var i = 1; i < samples.length; i++) {
        expect(samples[i].received, greaterThanOrEqualTo(samples[i - 1].received), reason: 'progress never goes backwards');
      }
      expect(h.wakelock.acquired, 1);
      expect(h.wakelock.released, 1);
      expect(h.platform.excluded, containsAll([h.layout.dir, h.layout.fileOf(h.model), h.layout.fileOf(h.vad)]));
    });

    test('requests carry only Danaview/<version> and no identifiers; the redirect is resolved first', () async {
      await h.store.download(h.consent()).done;
      expect(h.server.requests.map((r) => r.isResolve ? 'resolve' : 'cdn'), ['resolve', 'cdn', 'resolve', 'cdn']);
      for (final r in h.server.requests) {
        expect(r.method, 'GET');
        expect(r.headers['user-agent'], 'Danaview/9.9.9');
        expect(r.headers['accept-encoding'], 'identity');
        for (final forbidden in ['cookie', 'authorization', 'referer', 'x-device-id']) {
          expect(r.headers.containsKey(forbidden), isFalse, reason: forbidden);
        }
      }
      expect(h.server.cdnRequests.first.range, isNull, reason: 'a fresh download sends no Range');
    });

    test('the model alone (disclosure without VAD) fetches one file; the VAD can follow', () async {
      await h.store.download(h.consent(withVad: false)).done;
      expect(h.server.cdnRequests.map((r) => r.file), [h.model.fileName]);
      expect(await h.store.installed(h.model.id), isNull, reason: 'ready needs the VAD too');
      expect(await h.store.statusOf(h.model.id), isA<SpeechModelMissing>());

      await h.store.download(h.consent()).done;
      expect(h.server.cdnRequests.map((r) => r.file), [h.model.fileName, h.vad.fileName]);
      expect(await h.store.installed(h.model.id), isNotNull);
    });

    test('an already installed model completes without any request', () async {
      await h.store.download(h.consent()).done;
      final before = h.server.requests.length;
      final installed = await h.store.download(h.consent()).done;
      expect(installed.spec, h.model);
      expect(h.server.requests.length, before);
    });

    test('progress is throttled to 4 Hz', () async {
      final slow = await Harness.create(modelSize: 300 * 1024, config: (h) => ModelDownloaderConfig(
            appVersion: '1',
            urlFor: (s) => h.server.resolveUrl(s.fileName),
            isAllowedRedirect: (_) => true,
          ));
      addTearDown(slow.dispose);
      slow.server.chunkSize = 1024;
      final dl = slow.store.download(slow.consent());
      final samples = <ModelDownloadProgress>[];
      final watch = Stopwatch()..start();
      dl.progress.listen(samples.add);
      await dl.done;
      watch.stop();
      final downloading = samples.where((s) => s.phase == ModelDownloadPhase.downloading).length;
      expect(downloading, lessThanOrEqualTo(watch.elapsedMilliseconds ~/ 250 + 6), reason: '300 chunks, far fewer samples');
    });
  });

  group('redirect checks before any byte', () {
    test('x-linked-size mismatch -> sizeMismatch, no CDN request, nothing written', () async {
      h.server.advertisedSize[h.model.fileName] = h.model.bytes + 1;
      await expectFailure(h.store.download(h.consent()).done, ModelDownloadFailureKind.sizeMismatch);
      expect(h.server.cdnRequests, isEmpty);
      expect(h.server.resolves, hasLength(1), reason: 'a mismatch is not retried');
      expect(h.part(h.model).existsSync(), isFalse);
      expect(h.wakelock.released, 1);
    });

    test('x-linked-etag mismatch -> checksumMismatch, no CDN request', () async {
      h.server.advertisedEtag[h.model.fileName] = '0' * 64;
      await expectFailure(h.store.download(h.consent()).done, ModelDownloadFailureKind.checksumMismatch);
      expect(h.server.cdnRequests, isEmpty);
      expect(h.part(h.model).existsSync(), isFalse);
    });

    test('missing x-linked headers fail closed', () async {
      h.server.omitResolveHeaders.add('x-linked-size');
      await expectFailure(h.store.download(h.consent()).done, ModelDownloadFailureKind.sizeMismatch);
      h.server.omitResolveHeaders
        ..clear()
        ..add('x-linked-etag');
      await expectFailure(h.store.download(h.consent()).done, ModelDownloadFailureKind.checksumMismatch);
      expect(h.server.cdnRequests, isEmpty);
    });

    test('a weak or quoted etag is accepted', () async {
      h.server.advertisedEtag[h.model.fileName] = h.model.sha256.toUpperCase();
      await h.store.download(h.consent(withVad: false)).done;
      expect(await h.file(h.model).exists(), isTrue);
    });

    test('a missing Location, or one that leaves the CDN host, fails without a CDN request', () async {
      h.server.omitResolveHeaders.add('location');
      await expectFailure(h.store.download(h.consent()).done, ModelDownloadFailureKind.server);

      h.server.omitResolveHeaders.clear();
      // Default redirect policy: https on hf.co only; the fake server is http://127.0.0.1.
      final strict = h.newStore(config: ModelDownloaderConfig(appVersion: '1', urlFor: (s) => h.server.resolveUrl(s.fileName)));
      await expectFailure(strict.download(h.consent()).done, ModelDownloadFailureKind.server);
      expect(h.server.cdnRequests, isEmpty);
    });

    test('the default policy follows https hosts on the catalog CDN only', () {
      const c = ModelDownloaderConfig();
      expect(c.allowsRedirect(Uri.parse('https://cas-bridge.xethub.hf.co/x?Expires=1')), isTrue);
      expect(c.allowsRedirect(Uri.parse('https://hf.co/x')), isTrue);
      expect(c.allowsRedirect(Uri.parse('http://hf.co/x')), isFalse);
      expect(c.allowsRedirect(Uri.parse('https://evilhf.co/x')), isFalse);
      expect(c.allowsRedirect(Uri.parse('https://hf.co.evil.com/x')), isFalse);
      expect(c.allowsRedirect(Uri.parse('https://huggingface.co/x')), isFalse);
    });
  });

  group('status paths', () {
    test('resolve 404 / 403 / 200 (no redirect): server failure without retry', () async {
      for (final status in [404, 403, 200]) {
        h.server.requests.clear();
        h.server.resolveStatuses.add(status);
        await expectFailure(h.store.download(h.consent()).done, ModelDownloadFailureKind.server);
        expect(h.server.resolves, hasLength(1), reason: 'status $status');
      }
      expect(h.delays, isEmpty);
    });

    for (final status in [500, 503, 429]) {
      test('resolve $status four times: 3 retries with 2/4/8 s backoff + jitter, then server failure', () async {
        h.server.resolveStatuses.addAll([status, status, status, status]);
        await expectFailure(h.store.download(h.consent()).done, ModelDownloadFailureKind.server);
        expect(h.server.resolves, hasLength(4));
        expect(h.delays, hasLength(3));
        for (var i = 0; i < 3; i++) {
          final base = [2000, 4000, 8000][i];
          expect(h.delays[i].inMilliseconds, inInclusiveRange(base, (base * 1.25).ceil()), reason: 'retry ${i + 1}');
        }
        expect(h.server.cdnRequests, isEmpty);
      });
    }

    test('a transient 503 on the redirect then success re-resolves and completes', () async {
      h.server.resolveStatuses.add(503);
      await h.store.download(h.consent(withVad: false)).done;
      expect(h.server.resolves, hasLength(2));
      expect(h.delays, hasLength(1));
    });

    test('CDN 503 then success re-resolves the redirect', () async {
      h.server.cdnScript.addAll([const Cdn.status(503), const Cdn.normal()]);
      await h.store.download(h.consent(withVad: false)).done;
      expect(h.server.resolves, hasLength(2));
      expect(h.server.cdnRequests, hasLength(2));
      expect(await h.file(h.model).readAsBytes(), h.modelData);
    });

    test('CDN 404 / 403: server failure without retry', () async {
      h.server.cdnScript.add(const Cdn.status(404));
      await expectFailure(h.store.download(h.consent()).done, ModelDownloadFailureKind.server);
      expect(h.server.cdnRequests, hasLength(1));
      expect(h.delays, isEmpty);
    });

    test('CDN 200 with a wrong Content-Length -> sizeMismatch', () async {
      h.server.cdnScript.add(const Cdn.extraBytes(10));
      await expectFailure(h.store.download(h.consent()).done, ModelDownloadFailureKind.sizeMismatch);
    });
  });

  group('resume', () {
    test('a killed download resumes with Range from the partial length (206 appends)', () async {
      await seedPartial(h, h.model, h.modelData, 40000);
      final dl = h.store.download(h.consent(withVad: false));
      final samples = <ModelDownloadProgress>[];
      dl.progress.listen(samples.add);
      await dl.done;
      expect(h.server.cdnRequests.single.range, 'bytes=40000-');
      expect(await h.file(h.model).readAsBytes(), h.modelData);
      expect(samples.where((s) => s.phase == ModelDownloadPhase.downloading).first.received, greaterThanOrEqualTo(40000));
    });

    test('a server that ignores Range (200) restarts from zero', () async {
      await seedPartial(h, h.model, h.modelData, 40000);
      h.server.cdnScript.add(const Cdn.ignoreRange());
      await h.store.download(h.consent(withVad: false)).done;
      expect(h.server.cdnRequests.single.range, 'bytes=40000-');
      expect(await h.file(h.model).readAsBytes(), h.modelData);
    });

    test('416 on a short partial deletes it and restarts without Range', () async {
      await seedPartial(h, h.model, h.modelData, 40000);
      h.server.cdnScript.add(const Cdn.status(416));
      await h.store.download(h.consent(withVad: false)).done;
      expect(h.server.cdnRequests, hasLength(2));
      expect(h.server.cdnRequests.last.range, isNull);
      expect(await h.file(h.model).readAsBytes(), h.modelData);
    });

    test('a 206 whose Content-Range does not continue the partial restarts', () async {
      await seedPartial(h, h.model, h.modelData, 40000);
      h.server.cdnScript.add(const Cdn.badContentRange('bytes 0-99/102400'));
      await h.store.download(h.consent(withVad: false)).done;
      expect(h.server.cdnRequests.last.range, isNull);
      expect(await h.file(h.model).readAsBytes(), h.modelData);
    });

    test('a complete, verifiable partial goes straight to verification (no CDN request)', () async {
      await seedPartial(h, h.model, h.modelData, h.modelData.length);
      await h.store.download(h.consent(withVad: false)).done;
      expect(h.server.cdnRequests, isEmpty);
      expect(await h.file(h.model).readAsBytes(), h.modelData);
    });

    test('a complete but corrupt partial -> checksumMismatch and deletion', () async {
      final bad = modelBytes(h.modelData.length, seed: 77);
      await seedPartial(h, h.model, bad, bad.length);
      await expectFailure(h.store.download(h.consent(withVad: false)).done, ModelDownloadFailureKind.checksumMismatch);
      expect(h.part(h.model).existsSync(), isFalse);
      expect(h.sidecar(h.model).existsSync(), isFalse);
    });

    test('a partial without a valid sidecar is never resumed', () async {
      final stale = PartialSidecar(
        url: h.model.url,
        bytes: h.model.bytes,
        sha256: h.model.sha256,
        written: 40000,
        updatedAt: DateTime.now().toUtc(),
        catalogRevision: SpeechModelCatalog.revision + 1,
      );
      final variants = <String, Future<void> Function()>{
        'no sidecar': () => seedPartial(h, h.model, h.modelData, 40000, writeSidecar: false),
        'other catalog revision': () => seedPartial(h, h.model, h.modelData, 40000, sidecar: stale),
        'other sha': () => seedPartial(h, h.model, h.modelData, 40000,
            sidecar: PartialSidecar(url: h.model.url, bytes: h.model.bytes, sha256: '1' * 64, written: 40000, updatedAt: DateTime.now(), catalogRevision: SpeechModelCatalog.revision)),
        'truncated below the sidecar': () => seedPartial(h, h.model, h.modelData, 40000,
            sidecar: PartialSidecar(url: h.model.url, bytes: h.model.bytes, sha256: h.model.sha256, written: 50000, updatedAt: DateTime.now(), catalogRevision: SpeechModelCatalog.revision)),
        'garbage sidecar': () async {
          await seedPartial(h, h.model, h.modelData, 40000, writeSidecar: false);
          await h.sidecar(h.model).writeAsString('{not json');
        },
        'longer than the model': () async {
          await seedPartial(h, h.model, Uint8List(h.model.bytes + 10), h.model.bytes + 10, sidecar: null);
        },
      };
      for (final entry in variants.entries) {
        h.server.requests.clear();
        await entry.value();
        await h.newStore().download(h.consent(withVad: false)).done;
        expect(h.server.cdnRequests.first.range, isNull, reason: entry.key);
        expect(await h.file(h.model).readAsBytes(), h.modelData, reason: entry.key);
        await h.file(h.model).delete();
        await File(h.layout.manifest).delete();
      }
    });

    test('a connection reset mid-body resumes with Range and completes', () async {
      h.server.chunkSize = 4096;
      h.server.cdnScript.add(const Cdn.dropAfter(30000));
      await h.store.download(h.consent(withVad: false)).done;
      expect(h.server.cdnRequests, hasLength(2));
      final resumedAt = rangeStart(h.server.cdnRequests.last);
      expect(resumedAt, inInclusiveRange(1, 30000));
      expect(h.server.resolves, hasLength(2), reason: 'every retry re-resolves the redirect');
      expect(h.delays, hasLength(1));
      expect(await h.file(h.model).readAsBytes(), h.modelData);
    });

    test('retries are counted per stretch without progress: 5 drops that each advance still finish', () async {
      h.server.chunkSize = 4096;
      h.server.cdnScript.addAll(List.filled(5, const Cdn.dropAfter(20000)));
      await h.store.download(h.consent(withVad: false)).done;
      expect(h.server.cdnRequests, hasLength(6));
      expect(await h.file(h.model).readAsBytes(), h.modelData);
    });

    test('four drops without a single byte -> interrupted after 3 retries', () async {
      h.server.cdnScript.addAll(List.filled(4, const Cdn.dropAfter(0)));
      await expectFailure(h.store.download(h.consent(withVad: false)).done, ModelDownloadFailureKind.interrupted);
      expect(h.server.cdnRequests, hasLength(4));
      expect(h.delays, hasLength(3));
    });

    test('the sidecar is rewritten during the body, not just at the end', () async {
      final fine = await Harness.create(config: (h) => h.defaultConfig(sidecarEvery: 1000));
      addTearDown(fine.dispose);
      fine.server.chunkSize = 512;
      fine.server.cdnScript.add(const Cdn.stallAfter(5000));
      final dl = fine.store.download(fine.consent(withVad: false));
      await waitFor(() async {
        final s = await PartialSidecar.read(fine.layout.sidecarOf(fine.model));
        return s != null && s.written >= 1000;
      }, reason: 'a mid-body sidecar update');
      final side = (await PartialSidecar.read(fine.layout.sidecarOf(fine.model)))!;
      expect(side.url, fine.model.url);
      expect(side.bytes, fine.model.bytes);
      expect(side.sha256, fine.model.sha256);
      expect(side.catalogRevision, SpeechModelCatalog.revision);
      expect(side.written, lessThanOrEqualTo(5000));
      expect(jsonDecode(await fine.sidecar(fine.model).readAsString()), isA<Map<String, Object?>>(), reason: 'the signed CDN URL is never stored');
      expect(await fine.sidecar(fine.model).readAsString(), isNot(contains('/cdn/')));
      dl.cancel();
      await expectFailure(dl.done, ModelDownloadFailureKind.cancelled);
    });
  });

  group('multi-MiB file with production cadence', () {
    test('sidecar every 4 MiB, kill, resume from the sidecar-backed partial, hash in an isolate', () async {
      final big = await Harness.create(modelSize: 9 * 1024 * 1024);
      addTearDown(big.dispose);
      big.server.chunkSize = 256 * 1024;
      big.server.cdnScript.add(const Cdn.stallAfter(5 * 1024 * 1024));
      final dl = big.store.download(big.consent(withVad: false));
      await waitFor(() async {
        final s = await PartialSidecar.read(big.layout.sidecarOf(big.model));
        return s != null && s.written >= 4 * 1024 * 1024;
      }, reason: 'the 4 MiB sidecar');
      await waitFor(() => big.part(big.model).lengthSync() >= 5 * 1024 * 1024);
      dl.cancel();
      await expectFailure(dl.done, ModelDownloadFailureKind.cancelled);
      final kept = big.part(big.model).lengthSync();
      expect(kept, 5 * 1024 * 1024);

      big.server.requests.clear();
      await big.newStore().download(big.consent(withVad: false)).done;
      expect(big.server.cdnRequests.single.range, 'bytes=$kept-');
      expect(await big.file(big.model).readAsBytes(), big.modelData);
    });
  });

  group('timeouts and connectivity', () {
    test('an idle body times out after the idle limit; the retry resumes', () async {
      final quick = await Harness.create(config: (h) => h.defaultConfig(idle: const Duration(milliseconds: 300), backoff: const [Duration.zero]));
      addTearDown(quick.dispose);
      quick.server.chunkSize = 4096;
      quick.server.cdnScript.addAll([const Cdn.stallAfter(8000), const Cdn.normal()]);
      await quick.store.download(quick.consent(withVad: false)).done;
      expect(quick.server.cdnRequests, hasLength(2));
      expect(rangeStart(quick.server.cdnRequests.last), greaterThan(0));
      expect(await quick.file(quick.model).readAsBytes(), quick.modelData);
    });

    test('timeouts beyond the retry budget fail with timeout', () async {
      final quick = await Harness.create(config: (h) => h.defaultConfig(idle: const Duration(milliseconds: 200), backoff: const []));
      addTearDown(quick.dispose);
      quick.server.cdnScript.add(const Cdn.stallAfter(1000));
      await expectFailure(quick.store.download(quick.consent(withVad: false)).done, ModelDownloadFailureKind.timeout);
      expect(quick.part(quick.model).existsSync(), isTrue, reason: 'the partial stays for the next attempt');
    });

    test('no listener on the port -> offline, without retries', () async {
      await h.server.close();
      await expectFailure(h.store.download(h.consent()).done, ModelDownloadFailureKind.offline);
      expect(h.delays, isEmpty);
    });

    test('a TLS handshake failure -> secureConnection, without retries', () async {
      final tls = h.newStore(config: ModelDownloaderConfig(
        appVersion: '1',
        httpClientFactory: () => _FakeHttpClient(const HandshakeException('bad certificate')),
        delay: (d) async => h.delays.add(d),
      ));
      await expectFailure(tls.download(h.consent()).done, ModelDownloadFailureKind.secureConnection);
      expect(h.delays, isEmpty);
    });

    test('a connection reset before the redirect retries, then reports interrupted', () async {
      final reset = h.newStore(config: ModelDownloaderConfig(
        appVersion: '1',
        httpClientFactory: () => _FakeHttpClient(const SocketException('Connection reset by peer')),
        delay: (d) async => h.delays.add(d),
      ));
      await expectFailure(reset.download(h.consent()).done, ModelDownloadFailureKind.interrupted);
      expect(h.delays, hasLength(3));
    });
  });

  group('verification', () {
    test('hash mismatch after the download -> corrupt, partial deleted, nothing installed', () async {
      h.server.bodies[h.model.fileName] = modelBytes(h.modelData.length, seed: 99);
      await expectFailure(h.store.download(h.consent()).done, ModelDownloadFailureKind.checksumMismatch);
      expect(h.part(h.model).existsSync(), isFalse);
      expect(h.sidecar(h.model).existsSync(), isFalse);
      expect(h.file(h.model).existsSync(), isFalse);
      expect(await File(h.layout.manifest).exists() ? SpeechModelManifest.tryDecode(await File(h.layout.manifest).readAsString())!.installed : <ManifestEntry>[], isEmpty);
      expect(await h.store.statusOf(h.model.id), isA<SpeechModelCorrupt>());
      expect((await h.store.inventory()).corruptIds, contains(h.model.id));
      expect(h.wakelock.released, 1);

      // The next good download clears the corrupt state.
      h.server.bodies[h.model.fileName] = h.modelData;
      await h.store.download(h.consent()).done;
      expect(await h.store.statusOf(h.model.id), isA<SpeechModelReady>());
    });

    test('a file with the right hash but no ggml magic is rejected', () async {
      final noMagic = modelBytes(5000, seed: 5, magic: false);
      final spec = specFor('no-magic', noMagic);
      h.server.serve(spec, noMagic);
      final store = FileSpeechModelStore(
        supportDirectory: h.dir.path,
        platform: h.platform,
        config: h.defaultConfig(),
        models: [spec],
        vadSpec: h.vad,
      );
      await expectFailure(store.download(consentFor(spec)).done, ModelDownloadFailureKind.checksumMismatch);
      expect(File(store.layout.fileOf(spec)).existsSync(), isFalse);
    });

    test('the ggml magic is 6c 6d 67 67 on disk (0x67676d6c little-endian)', () {
      expect(ggmlMagicBytes, [0x6c, 0x6d, 0x67, 0x67]);
      expect(ByteData.sublistView(Uint8List.fromList(ggmlMagicBytes)).getUint32(0, Endian.little), 0x67676d6c);
    });
  });

  group('disk space', () {
    test('free space < remaining + 64 MiB -> diskFull before any request', () async {
      h.platform.freeBytes = 64 * 1024 * 1024 + h.model.bytes + h.vad.bytes - 1;
      await expectFailure(h.store.download(h.consent()).done, ModelDownloadFailureKind.diskFull);
      expect(h.server.requests, isEmpty);
      expect(h.part(h.model).existsSync(), isFalse);
      expect(h.wakelock.released, 1);
    });

    test('exactly remaining + 64 MiB passes', () async {
      h.platform.freeBytes = 64 * 1024 * 1024 + h.model.bytes + h.vad.bytes;
      await h.store.download(h.consent()).done;
    });

    test('an existing partial lowers the requirement; unknown free space passes', () async {
      await seedPartial(h, h.model, h.modelData, 90000);
      h.platform.freeBytes = 64 * 1024 * 1024 + (h.model.bytes - 90000);
      await h.store.download(h.consent(withVad: false)).done;
      await h.store.deleteAll();
      h.platform.freeBytes = null;
      await h.store.download(h.consent()).done;
    });
  });

  group('cancel and lifecycle', () {
    test('cancel keeps the partial and its sidecar; a new run resumes from there', () async {
      h.server.chunkSize = 4096;
      h.server.cdnScript.add(const Cdn.stallAfter(20000));
      final dl = h.store.download(h.consent(withVad: false));
      await waitFor(() => h.part(h.model).existsSync() && h.part(h.model).lengthSync() >= 20000, reason: 'the first 20000 bytes');
      dl.cancel();
      await expectFailure(dl.done, ModelDownloadFailureKind.cancelled);
      final kept = h.part(h.model).lengthSync();
      expect(kept, 20000);
      final side = (await PartialSidecar.read(h.layout.sidecarOf(h.model)))!;
      expect(side.written, kept);
      expect(h.store.activeDownload, isNull);
      expect(h.wakelock.released, 1);

      // "App restart": a new store over the same folder resumes with Range.
      h.server.requests.clear();
      await h.newStore().download(h.consent(withVad: false)).done;
      expect(h.server.cdnRequests.single.range, 'bytes=$kept-');
      expect(await h.file(h.model).readAsBytes(), h.modelData);
    });

    test('cancel(keepPartial: false) deletes the partial', () async {
      h.server.cdnScript.add(const Cdn.stallAfter(20000));
      final dl = h.store.download(h.consent(withVad: false));
      await waitFor(() => h.part(h.model).existsSync() && h.part(h.model).lengthSync() >= 20000);
      dl.cancel(keepPartial: false);
      await expectFailure(dl.done, ModelDownloadFailureKind.cancelled);
      expect(h.part(h.model).existsSync(), isFalse);
      expect(h.sidecar(h.model).existsSync(), isFalse);
    });

    test('cancelling right after start never installs anything', () async {
      final dl = h.store.download(h.consent());
      dl.cancel();
      await expectFailure(dl.done, ModelDownloadFailureKind.cancelled);
      expect(h.file(h.model).existsSync(), isFalse);
      expect(h.wakelock.acquired, h.wakelock.released);
    });

    test('one download at a time: the same model dedupes, another throws', () async {
      h.server.cdnScript.add(const Cdn.stallAfter(1000));
      final a = h.store.download(h.consent(withVad: false));
      expect(identical(h.store.download(h.consent(withVad: false)), a), isTrue);
      expect(h.store.activeDownload, same(a));
      expect(() => h.store.download(h.consent(spec: h.model2, withVad: false)), throwsStateError);
      expect(await h.store.statusOf(h.model.id), isA<SpeechModelDownloading>());
      a.cancel();
      await expectFailure(a.done, ModelDownloadFailureKind.cancelled);
      expect(h.store.activeDownload, isNull);
    });

    test('iOS: background begins a task, foreground ends it, expiry stops with the partial kept', () async {
      h.server.chunkSize = 4096;
      h.server.cdnScript.add(const Cdn.stallAfter(12000));
      final dl = h.store.download(h.consent(withVad: false));
      await waitFor(() => h.server.cdnRequests.isNotEmpty);

      h.platform.controller.add(const AppStateChanged(WhisperAppState.background));
      await waitFor(() => h.platform.begunTasks.length == 1, reason: 'background task');
      h.platform.controller.add(const AppStateChanged(WhisperAppState.foreground));
      await waitFor(() => h.platform.endedTasks.length == 1, reason: 'task ended on foreground');

      h.platform.controller.add(const AppStateChanged(WhisperAppState.background));
      await waitFor(() => h.platform.begunTasks.length == 2);
      await waitFor(() => h.part(h.model).existsSync() && h.part(h.model).lengthSync() >= 12000);
      h.platform.controller.add(const BackgroundTaskExpiring(2));
      await expectFailure(dl.done, ModelDownloadFailureKind.interrupted);
      expect(h.part(h.model).existsSync(), isTrue, reason: 'partial kept for the resume');
      expect(h.sidecar(h.model).existsSync(), isTrue);
      expect(h.platform.endedTasks, containsAll([1, 2]));
    });
  });

  group('consent', () {
    ConsentDisclosure tweak({String? sha, int? bytes, String? host, String? id, String? file, bool vad = true}) => ConsentDisclosure.forTesting(
          modelId: id ?? h.model.id,
          fileName: file ?? h.model.fileName,
          host: host ?? h.model.host,
          cdnHost: SpeechModelCatalog.cdnHost,
          sha256: sha ?? h.model.sha256,
          totalBytes: bytes ?? h.model.bytes + (vad ? h.vad.bytes : 0),
          includesVad: vad,
        );

    test('a disclosure that differs from the catalog is rejected before the first request', () async {
      final cases = <String, ConsentDisclosure>{
        'sha': tweak(sha: '2' * 64),
        'bytes': tweak(bytes: 1),
        'host': tweak(host: 'example.com'),
        'file': tweak(file: 'other.bin'),
        'unknown model': tweak(id: 'whisper-large'),
        'the VAD as a model': tweak(id: h.vad.id, bytes: h.vad.bytes, sha: h.vad.sha256, file: h.vad.fileName),
        'vad flag vs total': tweak(bytes: h.model.bytes),
      };
      for (final e in cases.entries) {
        final dl = h.store.download(UserConsent.accepted(e.value, acceptedAt: DateTime.utc(2026)));
        await expectFailure(dl.done, ModelDownloadFailureKind.consentMismatch);
        expect(h.store.activeDownload, isNull, reason: e.key);
      }
      expect(h.server.requests, isEmpty);
      expect(h.wakelock.acquired, 0);
      expect(Directory(h.layout.dir).existsSync(), isFalse, reason: 'nothing is created before consent is valid');
    });

    test('there is no consent memory: each download needs its own (a stale disclosure is refused)', () async {
      await h.store.download(h.consent()).done;
      await h.store.deleteAll();
      final stale = UserConsent.accepted(tweak(bytes: h.model.bytes + 7), acceptedAt: DateTime.utc(2020));
      await expectFailure(h.store.download(stale).done, ModelDownloadFailureKind.consentMismatch);
    });

    test('production catalog: a real disclosure reaches the network, a tampered one does not', () async {
      final real = FileSpeechModelStore(
        supportDirectory: h.dir.path,
        platform: h.platform,
        config: h.defaultConfig(),
      );
      // The fake server does not serve the real file names: 404 on the redirect = a request was made.
      final ok = ConsentDisclosure.of(SpeechModelCatalog.balanced, includesVad: true);
      await expectFailure(real.download(UserConsent.accepted(ok, acceptedAt: DateTime.utc(2026))).done, ModelDownloadFailureKind.server);
      expect(h.server.resolves, hasLength(1));
      expect(h.server.resolves.single.file, SpeechModelCatalog.balanced.fileName);

      h.server.requests.clear();
      final tampered = ConsentDisclosure.forTesting(
        modelId: ok.modelId,
        fileName: ok.fileName,
        host: ok.host,
        cdnHost: ok.cdnHost,
        sha256: ok.sha256,
        totalBytes: ok.totalBytes - 1,
        includesVad: true,
      );
      await expectFailure(real.download(UserConsent.accepted(tampered, acceptedAt: DateTime.utc(2026))).done, ModelDownloadFailureKind.consentMismatch);
      expect(h.server.requests, isEmpty);
    });
  });
}
