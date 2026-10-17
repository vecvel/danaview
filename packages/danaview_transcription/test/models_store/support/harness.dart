// OWNER: AI-09
//
// Shared fixtures of the model store tests: fake device services and a harness that wires a store
// to a temp folder and a loopback FakeModelServer.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_transcription/danaview_transcription.dart';
import 'package:danaview_whisper/danaview_whisper.dart' show WhisperDeviceEvent;

import 'fake_model_server.dart';

final class FakePlatform implements ModelStorePlatform {
  int? freeBytes;
  final List<String> excluded = [];
  final List<int> endedTasks = [];
  final List<String> begunTasks = [];
  final StreamController<WhisperDeviceEvent> controller = StreamController<WhisperDeviceEvent>.broadcast();

  @override
  Future<int?> freeDiskBytes(String path) async => freeBytes;

  @override
  Future<bool> excludeFromBackup(String path) async {
    excluded.add(path);
    return true;
  }

  @override
  Future<int?> beginBackgroundTask(String name) async {
    begunTasks.add(name);
    return begunTasks.length;
  }

  @override
  Future<void> endBackgroundTask(int id) async => endedTasks.add(id);

  @override
  Stream<WhisperDeviceEvent> get events => controller.stream;
}

final class CountingWakelock implements DownloadWakelock {
  int acquired = 0;
  int released = 0;

  @override
  Future<void> acquire() async => acquired++;

  @override
  Future<void> release() async => released++;
}

/// Polls [condition] until it holds (the tests wait on real IO, never on fixed sleeps).
Future<void> waitFor(FutureOr<bool> Function() condition, {Duration timeout = const Duration(seconds: 10), String? reason}) async {
  final end = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(end)) fail('Timed out waiting for ${reason ?? 'condition'}');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Expects [future] to fail with a [ModelDownloadFailure] of [kind].
Future<void> expectFailure(Future<Object?> future, ModelDownloadFailureKind kind) async {
  try {
    await future;
  } on ModelDownloadFailure catch (e) {
    expect(e.kind, kind);
    return;
  }
  fail('Expected ModelDownloadFailure($kind), but it completed');
}

final class Harness {
  Harness._(this.dir, this.server);

  final Directory dir;
  final FakeModelServer server;
  final FakePlatform platform = FakePlatform();
  final CountingWakelock wakelock = CountingWakelock();
  final List<Duration> delays = [];
  bool jobRunning = false;

  late Uint8List modelData;
  late Uint8List vadData;
  late SpeechModelSpec model;
  late SpeechModelSpec model2;
  late SpeechModelSpec vad;
  late Uint8List model2Data;
  late FileSpeechModelStore store;

  static Future<Harness> create({int modelSize = 100 * 1024, int vadSize = 4096, ModelDownloaderConfig Function(Harness h)? config}) async {
    final dir = await Directory.systemTemp.createTemp('danaview_models_');
    final h = Harness._(dir, await FakeModelServer.start());
    h.modelData = modelBytes(modelSize, seed: 1);
    h.model2Data = modelBytes(modelSize ~/ 2, seed: 3);
    h.vadData = modelBytes(vadSize, seed: 2);
    h.model = specFor('test-model', h.modelData);
    h.model2 = specFor('test-model-2', h.model2Data, tier: SpeechModelTier.balanced);
    h.vad = specFor('test-vad', h.vadData);
    h.server
      ..serve(h.model, h.modelData)
      ..serve(h.model2, h.model2Data)
      ..serve(h.vad, h.vadData);
    h.store = h.newStore(config: config?.call(h));
    return h;
  }

  ModelDownloaderConfig defaultConfig({int? sidecarEvery, Duration? idle, List<Duration>? backoff}) => ModelDownloaderConfig(
        appVersion: '9.9.9',
        urlFor: (spec) => server.resolveUrl(spec.fileName),
        isAllowedRedirect: (_) => true,
        delay: (d) async => delays.add(d),
        progressInterval: Duration.zero,
        sidecarEveryBytes: sidecarEvery ?? 4 * 1024 * 1024,
        idleTimeout: idle ?? const Duration(seconds: 30),
        retryBackoff: backoff ?? const [Duration(seconds: 2), Duration(seconds: 4), Duration(seconds: 8)],
      );

  /// A store over the same folder (a "restart" of the app).
  FileSpeechModelStore newStore({ModelDownloaderConfig? config, Set<String> legacy = const {}}) => FileSpeechModelStore(
        supportDirectory: dir.path,
        platform: platform,
        wakelock: wakelock,
        isModelInUse: () => jobRunning,
        config: config ?? defaultConfig(),
        models: [model, model2],
        vadSpec: vad,
        legacySha256: legacy,
      );

  ModelStoreLayout get layout => store.layout;

  UserConsent consent({SpeechModelSpec? spec, bool withVad = true}) => consentFor(spec ?? model, vad: withVad ? vad : null);

  File file(SpeechModelSpec s) => File(layout.fileOf(s));
  File part(SpeechModelSpec s) => File(layout.partOf(s));
  File sidecar(SpeechModelSpec s) => File(layout.sidecarOf(s));

  Future<void> dispose() async {
    await server.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
