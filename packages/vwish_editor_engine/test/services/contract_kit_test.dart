// OWNER: ENG-03
//
// The FakeEditorEngine contract kit (API-01, `checkEngineContract`) against MobileEditorEngine
// over mocked channels, where applicable to ENG-03: capabilities caching and the job contract
// (non-empty id, setPriority, idempotent cancel → EngineCancelled) run on the real mobile
// services; the preview and export parts belong to ENG-02 / ENG-04 and are delegated to the fake
// engine here (their tickets run the kit against their own services). A second test checks that
// the mobile services and the fake agree on the ENG-03 behaviours the kit does not cover.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor_engine/src/pigeon/conversions.dart';
import 'package:vwish_editor_engine/src/pigeon/engine_api.g.dart';
import 'package:vwish_editor_engine/vwish_editor_engine.dart';
import 'package:vwish_editor_engine_api/testing.dart';
import 'package:vwish_editor_engine_api/vwish_editor_engine_api.dart';

import 'support/services_harness.dart';

/// MobileEditorEngine for everything ENG-03 owns (and the engine root), the fake for preview and
/// export.
final class _Eng03Engine implements EditorEngine {
  _Eng03Engine(this.mobile, this.fake);

  final MobileEditorEngine mobile;
  final FakeEditorEngine fake;

  @override
  Future<EditorCapabilities> capabilities() => mobile.capabilities();
  @override
  Future<EditCompatibility> compatibility(String pathOrUri) => mobile.compatibility(pathOrUri);
  @override
  Future<MediaProbe> probe(EngineMedia media) => mobile.probe(media);
  @override
  Future<PreviewSession> openPreview(PreviewConfig config) => fake.openPreview(config);
  @override
  ThumbnailSource get thumbnails => mobile.thumbnails;
  @override
  WaveformSource get waveforms => mobile.waveforms;
  @override
  MediaJobs get jobs => mobile.jobs;
  @override
  ExportService get exporter => fake.exporter;
  @override
  VoiceRecorder? get voiceRecorder => mobile.voiceRecorder;
  @override
  MediaPicker get picker => mobile.picker;
  @override
  FileHandoff get files => mobile.files;
  @override
  MediaAccess get access => mobile.access;
  @override
  BackgroundWorkGuard get background => mobile.background;
  @override
  ExternalDropTarget get drops => mobile.drops;
  @override
  Future<int> freeBytes(String path) => mobile.freeBytes(path);
  @override
  Stream<EngineSignal> get signals => mobile.signals;
  @override
  Future<void> trimCaches(CacheTrimLevel level) => mobile.trimCaches(level);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockEngineHost host;
  setUp(() {
    host = MockEngineHost()..acceptInitialize();
    host.installEvents();
    var n = 0;
    host
      ..on('EngineHostApi', 'capabilities', (_) => capabilitiesToMsg(fakeDefaultCapabilities))
      ..on('JobsHostApi', 'startJob', (_) => 'kit-${n++}')
      ..on('JobsHostApi', 'cancelJob', (_) => null)
      ..on('JobsHostApi', 'setJobPriority', (_) => null);
  });
  tearDown(() => host.dispose());

  test('checkEngineContract passes with the mobile ENG-03 services over mocked channels', () async {
    final mobile = MobileEditorEngine(config: servicesConfig, limits: noRateLimits);
    final violations = await checkEngineContract(_Eng03Engine(mobile, FakeEditorEngine()));
    expect(violations, isEmpty);
    await pumpEventQueue();
    expect(host.count('EngineHostApi', 'capabilities'), 1, reason: 'capabilities are cached');
    expect(host.count('JobsHostApi', 'startJob'), 1);
    expect(
        host.args['JobsHostApi.cancelJob'],
        [
          ['kit-0']
        ],
        reason: 'the kit cancels before the startJob reply; the cancel reaches native once the id is known');
    expect(host.count('JobsHostApi', 'setJobPriority'), 0, reason: 'interactive is already the freeze-frame priority');
  });

  test('the mobile services and the fake agree on the ENG-03 behaviours the kit does not check', () async {
    host
      ..on('PlatformHostApi', 'excludeFromBackup', (_) => null)
      ..on('PlatformHostApi', 'pick', (_) => <PickedMediaMsg>[])
      ..on('PlatformHostApi', 'acquireBackground', (_) => 'lease')
      ..on('PlatformHostApi', 'releaseBackground', (_) => null);
    final mobile = MobileEditorEngine(config: servicesConfig, limits: noRateLimits);
    final fake = FakeEditorEngine(editorRoots: const ['/s/vwish/editor', '/c/vwish/editor', '/s/vwish/speech']);

    for (final EditorEngine engine in [fake, mobile]) {
      final name = engine.runtimeType.toString();
      // D-44: backup exclusion inside the editor roots only.
      await engine.access.excludeFromBackup('/s/vwish/editor/media');
      await expectLater(
        engine.access.excludeFromBackup('/d/Documents/Exports'),
        throwsA(isA<MediaAccessFailure>().having((f) => f.kind, 'kind', MediaAccessFailureKind.outsideEditorRoots)),
        reason: name,
      );
      // A cancelled picker is an empty list.
      expect(await engine.picker.pick(const MediaPickRequest(source: MediaPickSource.photos, kinds: {MediaPickKind.video})), isEmpty,
          reason: name);
      // A thumbnail cancelled before it completes ends with EngineCancelled.
      final handle = engine.thumbnails.request(const ThumbnailRequest(media: servicesMedia, intervalMs: 1000, tileIndex: 0, heightPx: 40),
          priority: ThumbPriority.visible);
      handle.cancel();
      await expectLater(handle.result, throwsA(isA<EngineCancelled>()), reason: name);
      // Leases are acquired and released.
      final lease = await engine.background.acquire(title: 'Export', progress: const Stream<double>.empty());
      expect(lease, isNotNull, reason: name);
      await lease!.release();
    }
  });
}
