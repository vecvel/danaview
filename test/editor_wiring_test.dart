// OWNER: INT-04
//
// App wiring v2 (ARCH §4.1, §16, §17.1, §17.10; D-17, D-28): the D-28 engine adapters
// (EngineSpeechAudioExtractor, EngineBackgroundLeaseProvider), the governor's export port and the
// engine-signal merge; the app booted with fakes the way main.dart wires it (EditorBootstrap +
// editorAppOverrides) reaching the player's Edit action (EditorLauncher.openFromPlayer -> the
// editor at the player's position -> back to the player), Auto captions in the editor and the
// "Speech model" storage row; and the macOS build (D-17): no Edit in the player top bar or the
// Playback sheet, no "E – Edit video" shortcut line, no speech storage contributor, no editor
// providers. Settings › About › Open-source licences (`/settings/licenses`, restored by the owner
// 2026-10-16, FIX-LICENSES) opens the licences page from About on iOS and on macOS.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:danaview/app.dart';
import 'package:danaview/main.dart';
import 'package:danaview/router/app_router.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_editor/danaview_editor.dart';
// The launcher override below reuses the wired free-space check, which the barrel does not export.
// ignore: implementation_imports
import 'package:danaview_editor/src/editor/flows/import_media_sheet.dart' show importSpaceCheckProvider;
import 'package:danaview_editor_core/model.dart' show FromPlayerOrigin, MediaKind, MediaProbe, TimeRange;
import 'package:danaview_editor_core/model.dart' as core show ResolvedMedia;
import 'package:danaview_editor_core/store.dart' show StoreRoots;
import 'package:danaview_editor_core/testing.dart' show MemoryStoreFs;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' hide ThermalLevel;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' as api show ThermalLevel;
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_features/licenses.dart' show DanaviewLicensesScreen;
import 'package:danaview_transcription/danaview_transcription.dart';
import 'package:danaview_transcription/testing.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:danaview_whisper/danaview_whisper.dart';

import 'library_test_utils.dart';

const _roots = StoreRoots(support: '/fake/support', cache: '/fake/cache', documents: '/fake/documents');
const _videoPath = '/fake/documents/holiday.mp4';
const _video = MediaRef(id: _videoPath, title: 'Holiday', pathOrUri: _videoPath);
const _editKey = ValueKey('player-edit-video');
const _sheetRowKey = ValueKey('player-sheet-edit-video');
const int _s = 1000000;

final _probe = MediaProbe(kind: MediaKind.video, duration: 60 * _s, hasVideo: true, hasAudio: true, width: 1920, height: 1080);

// -------------------------------------------------------------------------------------------------
// The app, wired like main.dart
// -------------------------------------------------------------------------------------------------

/// The app on [platform] with DANAVIEW_EDITOR [flag] and DANAVIEW_AUTO_CAPTIONS [captions], wired
/// like `main.dart`: `EditorBootstrap.createRuntime` + [editorAppOverrides] with [transcription].
Future<WiredApp> pumpWiredApp(
  WidgetTester tester, {
  required TargetPlatform platform,
  bool flag = true,
  bool captions = true,
  TranscriptionService? transcription,
  FakeEditorEngine? engine,
  Size size = const Size(390, 844),
}) async {
  debugDefaultTargetPlatformOverride = platform;
  EditorFlags.debugEditorOverride = flag;
  EditorFlags.debugAutoCaptionsOverride = captions;
  useSurface(tester, TestSurface(size, 1.0));
  final env = await LibraryTestEnv.create();
  final fake = engine ?? FakeEditorEngine(validatePlans: false);
  final fs = MemoryStoreFs();
  final service = transcription ?? FakeTranscriptionService();
  EditorRuntime? runtime;
  final List<Override> editor;
  if (EditorAvailability.platform is EditorSupported) {
    runtime = await EditorBootstrap.createRuntime(
      engine: fake,
      roots: _roots,
      prefs: EditorPrefs.memory(),
      fs: fs,
      startGc: false,
      listenToLifecycle: false,
    );
    editor = editorAppOverrides(runtime, transcription: captions ? service : null);
  } else {
    editor = EditorBootstrap.unavailable();
  }
  final container = ProviderContainer(overrides: [
    ...env.overrides,
    ...editor,
    if (runtime != null)
      // The played file lives on the real disk in production; here the launcher's file checks are
      // answered by the test (the import itself runs through the wired pool and store).
      editorLauncherProvider.overrideWith((ref) => EditorLauncher(
            engine: fake,
            repository: runtime!.repository,
            capabilities: fake.capabilities,
            spaceCheck: () => ref.read(importSpaceCheckProvider),
            access: runtime.pool.access,
            fileExists: (_) async => true,
            fileSize: (_) async => 1000,
            playerOrigin: (path, name) async => FromPlayerOrigin(quickHash: 'q' * 40, sizeBytes: 1000, displayName: name),
          )),
  ]);
  await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const DanaviewApp()));
  await pumpFrames(tester);
  return WiredApp(tester, env, container, fake, fs, runtime);
}

/// A booted app.
class WiredApp {
  WiredApp(this.tester, this.env, this.container, this.engine, this.fs, this.runtime);

  final WidgetTester tester;
  final LibraryTestEnv env;
  final ProviderContainer container;
  final FakeEditorEngine engine;
  final MemoryStoreFs fs;
  final EditorRuntime? runtime;

  GoRouter get router => GoRouter.of(tester.element(find.byType(Navigator).first));

  String get location => router.state.uri.toString();

  Future<void> go(String location) async {
    router.go(location);
    await pumpFrames(tester, count: 10);
  }

  /// Plays the local video in the player screen.
  Future<void> playVideo() async {
    await container.read(queueControllerProvider.notifier).playFrom(const [_video]);
    router.push('/player');
    await pumpFrames(tester, count: 10);
  }

  Future<void> dispose() async {
    DanaviewToast.dismiss();
    await tester.pumpWidget(const SizedBox());
    await pumpFrames(tester, count: 40);
    await runtime?.dispose();
    container.dispose();
    await env.dispose();
    debugDefaultTargetPlatformOverride = null;
    EditorFlags.debugEditorOverride = null;
    EditorFlags.debugAutoCaptionsOverride = null;
  }
}

/// The FakeEditorEngine the app tests use: the played video probes as 60 s with audio.
FakeEditorEngine wiredEngine() => FakeEditorEngine(validatePlans: false, probes: {
      _videoPath: _probe,
      'file://$_videoPath': _probe,
    });

// -------------------------------------------------------------------------------------------------
// Adapter fakes
// -------------------------------------------------------------------------------------------------

final class _ThrowingJobs implements MediaJobs {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw const EngineError(EngineErrorCode.busy);
}

final class _EngineWithJobs implements EditorEngine {
  _EngineWithJobs(this.jobs);

  @override
  final MediaJobs jobs;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(invocation.memberName.toString());
}

final class _ThrowingGuard implements BackgroundWorkGuard {
  @override
  Future<BackgroundLease?> acquire({required String title, required Stream<double> progress}) async => throw StateError('no service');

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(invocation.memberName.toString());
}

final class _EngineWithGuard implements EditorEngine {
  _EngineWithGuard(this.background);

  @override
  final BackgroundWorkGuard background;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(invocation.memberName.toString());
}

final class _ScriptedExporter implements ExportService {
  List<ExportJobState> jobs = const [];
  int calls = 0;

  @override
  Future<List<ExportJobState>> activeJobs() async {
    calls++;
    return jobs;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(invocation.memberName.toString());
}

final class _Device implements DeviceResources {
  final StreamController<WhisperDeviceEvent> controller = StreamController<WhisperDeviceEvent>.broadcast();

  @override
  Future<WhisperDeviceProfile> profile() async => const WhisperDeviceProfile(os: 'ios', physicalRamBytes: 6 << 30);

  @override
  Future<int?> availableMemory() async => 1 << 30;

  @override
  Future<int?> freeDiskBytes(String path) async => 1 << 34;

  @override
  Stream<WhisperDeviceEvent> get events => controller.stream;
}

const _media = core.ResolvedMedia(uri: 'file:///fake/documents/holiday.mp4', fingerprint: 'qh');

void main() {
  // ---------------------------------------------------------------------------------------------
  group('EngineSpeechAudioExtractor (D-28)', () {
    test('maps the request to engine.jobs.extractSpeechAudio and the result back', () async {
      final engine = FakeEditorEngine();
      final extraction = EngineSpeechAudioExtractor(engine).extract(const SpeechAudioRequest(
        media: _media,
        range: TimeRange(2 * _s, 5 * _s),
        outputPath: '/fake/support/danaview/speech/work/job/u0.wav',
        audioStream: 1,
      ));
      final job = engine.jobs.created.single;
      expect(engine.log.calls, contains('jobs.extractSpeechAudio'));
      final progress = <double>[];
      final sub = extraction.progress.listen(progress.add);
      job.report(0.5);
      await Future<void>.delayed(Duration.zero);
      expect(progress, [0.5]);
      job.complete(const ExtractedSpeechAudio(
        path: '/fake/support/danaview/speech/work/job/u0.wav',
        frames: 48000,
        duration: 3 * _s,
        sourceChannels: 2,
        sourceSampleRate: 48000,
        codec: 'aac',
      ));
      final r = await extraction.result;
      expect((r.path, r.frames, r.duration, r.sourceChannels, r.sourceSampleRate, r.codec),
          ('/fake/support/danaview/speech/work/job/u0.wav', 48000, 3 * _s, 2, 48000, 'aac'));
      await sub.cancel();
    });

    test('cancel cancels the engine job; the result is a typed cancellation', () async {
      final engine = FakeEditorEngine();
      final extraction = EngineSpeechAudioExtractor(engine)
          .extract(const SpeechAudioRequest(media: _media, range: TimeRange(0, _s), outputPath: '/o.wav'));
      final job = engine.jobs.created.single;
      extraction.cancel();
      expect(job.cancelled, isTrue);
      await expectLater(
        extraction.result,
        throwsA(isA<SpeechAudioFailure>().having((f) => f.kind, 'kind', SpeechAudioFailureKind.cancelled)),
      );
    });

    test('every engine failure becomes a typed SpeechAudioFailure', () async {
      const cases = <EngineFailure, SpeechAudioFailureKind>{
        EngineError(EngineErrorCode.mediaOffline): SpeechAudioFailureKind.mediaOffline,
        EngineError(EngineErrorCode.permissionDenied): SpeechAudioFailureKind.permissionDenied,
        EngineError(EngineErrorCode.unsupportedMedia, debugDetail: 'no audio track'): SpeechAudioFailureKind.noAudioTrack,
        EngineError(EngineErrorCode.unsupportedMedia, debugDetail: 'codec opus'): SpeechAudioFailureKind.unsupportedCodec,
        EngineError(EngineErrorCode.decoderInitFailed): SpeechAudioFailureKind.unsupportedCodec,
        EngineError(EngineErrorCode.notSupportedOnDevice): SpeechAudioFailureKind.unsupportedCodec,
        EngineError(EngineErrorCode.decodeFailed): SpeechAudioFailureKind.decodeFailed,
        EngineError(EngineErrorCode.diskFull): SpeechAudioFailureKind.diskFull,
        EngineError(EngineErrorCode.io): SpeechAudioFailureKind.decodeFailed,
        EngineError(EngineErrorCode.internal): SpeechAudioFailureKind.decodeFailed,
        EngineCancelled(): SpeechAudioFailureKind.cancelled,
      };
      for (final entry in cases.entries) {
        final engine = FakeEditorEngine();
        final extraction = EngineSpeechAudioExtractor(engine)
            .extract(const SpeechAudioRequest(media: _media, range: TimeRange(0, _s), outputPath: '/o.wav'));
        engine.jobs.created.single.fail(entry.key);
        await expectLater(
          extraction.result,
          throwsA(isA<SpeechAudioFailure>().having((f) => f.kind, 'kind', entry.value)),
          reason: '${entry.key.code} ${entry.key.debugDetail}',
        );
      }
      expect(EngineSpeechAudioExtractor.failureOf(StateError('x')).kind, SpeechAudioFailureKind.decodeFailed);
    });

    test('a job the engine refuses synchronously fails typed, without throwing from extract', () async {
      final extraction = EngineSpeechAudioExtractor(_EngineWithJobs(_ThrowingJobs()))
          .extract(const SpeechAudioRequest(media: _media, range: TimeRange(0, _s), outputPath: '/o.wav'));
      await expectLater(extraction.result, throwsA(isA<SpeechAudioFailure>()));
      extraction.cancel();
    });
  });

  // ---------------------------------------------------------------------------------------------
  group('EngineBackgroundLeaseProvider (D-28)', () {
    test('acquires an engine lease and releases it once', () async {
      final engine = FakeEditorEngine();
      final guard = engine.background;
      final lease = await EngineBackgroundLeaseProvider(engine).acquire(title: 'Creating captions', progress: const Stream.empty());
      expect(lease, isNotNull);
      expect(guard.held, hasLength(1));
      await lease!.release();
      await lease.release();
      expect(guard.held, isEmpty);
    });

    test('a guard that throws yields no lease', () async {
      final lease = await EngineBackgroundLeaseProvider(_EngineWithGuard(_ThrowingGuard()))
          .acquire(title: 'Creating captions', progress: const Stream.empty());
      expect(lease, isNull);
    });
  });

  // ---------------------------------------------------------------------------------------------
  group('governor signals', () {
    test('EngineExportActivity reports running and resumable exports while listened to', () async {
      final exporter = _ScriptedExporter();
      final activity = EngineExportActivity(exporter, interval: const Duration(milliseconds: 5));
      final seen = <bool>[];
      final sub = activity.changes.listen(seen.add);
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(activity.isActive, isFalse);
      exporter.jobs = const [ExportResumable('j', doneFraction: 0.5)];
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(activity.isActive, isTrue);
      exporter.jobs = const [];
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(activity.isActive, isFalse);
      expect(seen, [true, false]);
      await sub.cancel();
      final calls = exporter.calls;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(exporter.calls, calls, reason: 'no polling without a listener');
      await activity.dispose();
    });

    test('EngineSignalDeviceResources merges engine memory and thermal signals into the device events', () async {
      final device = _Device();
      final engine = FakeEditorEngine();
      final merged = EngineSignalDeviceResources(device, engine.signals);
      final events = <WhisperDeviceEvent>[];
      final sub = merged.events.listen(events.add);
      await Future<void>.delayed(Duration.zero);
      engine.emitSignal(const MemoryWarningSignal());
      engine.emitSignal(const ThermalSignal(api.ThermalLevel.serious));
      device.controller.add(const LowPowerChanged(true));
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(3));
      expect(events.whereType<MemoryWarning>(), hasLength(1));
      expect(events.whereType<ThermalChanged>().single.level, ThermalLevel.serious);
      expect(events.whereType<LowPowerChanged>().single.enabled, isTrue);
      expect((await merged.profile()).os, 'ios');
      await sub.cancel();
    });

    test('the real service built by createAutoCaptions offers tiers from the device profile', () async {
      final engine = FakeEditorEngine();
      final device = _Device();
      final captions = createAutoCaptions(
        engine: engine,
        supportDirectory: '/nonexistent/support',
        channel: WhisperDeviceChannel(enabled: false),
      );
      expect(captions.service, isA<TranscriptionServiceImpl>());
      expect(captions.service.paths.root, '/nonexistent/support/danaview/speech');
      expect(captions.store.layout.dir, '/nonexistent/support/danaview/speech/models');
      await captions.dispose();
      device.controller.close().ignore();
    });
  });

  // ---------------------------------------------------------------------------------------------
  group('iOS/Android with the editor and Auto captions (wired like main.dart)', () {
    for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
      testWidgets('$platform: Settings › Storage lists projects, cache and the speech model', (tester) async {
        final service = FakeTranscriptionService();
        final app = await pumpWiredApp(tester, platform: platform, transcription: service);
        try {
          final contributors = app.container.read(storageContributorsProvider);
          expect(contributors.map((c) => c.id), ['editor.projects', 'editor.cache', 'editor.speech']);
          expect(app.container.read(transcriptionServiceProvider), same(service));
          expect(app.container.read(autoCaptionsHostProvider).onOpenPrivacyPolicy, isNotNull);
          expect(app.container.read(exportHostProvider).onPlay, isNotNull);
          expect(app.container.read(exportHostProvider).onFreeUpSpace, isNotNull);

          await app.go('/settings/storage');
          expect(find.byType(DanaviewStorageScreen), findsOneWidget);
          expect(find.text(SpeechStorageStrings.title, skipOffstage: false), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          await app.dispose();
        }
      });
    }

    testWidgets('Auto captions off: no service override and no speech row', (tester) async {
      final app = await pumpWiredApp(tester, platform: TargetPlatform.iOS, captions: false);
      try {
        expect(app.container.read(storageContributorsProvider).map((c) => c.id), ['editor.projects', 'editor.cache']);
        expect(() => app.container.read(transcriptionServiceProvider), throwsA(anything));
      } finally {
        await app.dispose();
      }
    });

    testWidgets('the consent view\'s privacy link and the export host navigate', (tester) async {
      final app = await pumpWiredApp(tester, platform: TargetPlatform.iOS);
      try {
        app.container.read(autoCaptionsHostProvider).onOpenPrivacyPolicy!();
        await pumpFrames(tester, count: 10);
        expect(app.location, settingsLocation(SettingsDestination.privacy));
        expect(find.byType(DanaviewLegalScreen), findsOneWidget);

        await app.go('/');
        await app.container.read(exportHostProvider).onFreeUpSpace!();
        await pumpFrames(tester, count: 10);
        expect(app.location, settingsLocation(SettingsDestination.storage));

        await app.go('/');
        await app.container.read(exportHostProvider).onPlay!(_videoPath);
        await pumpFrames(tester, count: 10);
        expect(app.location, '/player');
        expect(app.container.read(playerControllerProvider).currentMediaRef?.pathOrUri, _videoPath);
      } finally {
        await app.dispose();
      }
    });

    testWidgets('player Edit opens the editor at the player position, Auto captions opens, and Back restores the player',
        (tester) async {
      final app = await pumpWiredApp(tester, platform: TargetPlatform.iOS, engine: wiredEngine());
      try {
        await app.playVideo();
        expect(find.byType(DanaviewPlayerScreen), findsOneWidget);
        final edit = find.byKey(_editKey);
        expect(edit, findsOneWidget);
        await app.container.read(playerControllerProvider.notifier).seek(const Duration(seconds: 12));
        await pumpFrames(tester);
        await tester.tap(edit);
        await pumpFrames(tester, count: 20);

        expect(find.byType(EditorScreen), findsOneWidget, reason: 'location ${app.location}');
        final screen = tester.widget<EditorScreen>(find.byType(EditorScreen));
        expect(app.location, editorLocation(screen.projectId, initialPlayhead: screen.initialPlayhead));
        expect(screen.initialPlayhead, 12 * _s);

        // Auto captions: the Captions tool, then "Auto captions" in the empty Captions panel.
        final captionsTool = find.byKey(const ValueKey('tile.tool.captions'), skipOffstage: false);
        await tester.ensureVisible(captionsTool);
        await tester.tap(captionsTool);
        await pumpFrames(tester, count: 10);
        final autoCaptions = find.text('Auto captions').last;
        await tester.ensureVisible(autoCaptions);
        await tester.tap(autoCaptions);
        await pumpFrames(tester, count: 10);
        expect(find.byKey(const ValueKey('captions-configure')), findsOneWidget);

        // Back closes the sheet, the editor, and returns to the paused player at the position.
        // (each Back closes one layer: the sheet, the Captions panel, then the editor).
        for (var i = 0; i < 5 && find.byType(EditorScreen).evaluate().isNotEmpty; i++) {
          await tester.binding.handlePopRoute();
          await pumpFrames(tester, count: 20);
        }
        expect(find.byType(EditorScreen), findsNothing);
        expect(app.location, '/player');
        final player = app.container.read(playerControllerProvider);
        expect(player.isPlaying, isFalse);
        expect(player.position, const Duration(seconds: 12));
        expect(tester.takeException(), isNull);
      } finally {
        await app.dispose();
      }
    });

    testWidgets('Settings › About › Open-source licences opens the licences page at /settings/licenses', (tester) async {
      final app = await pumpWiredApp(tester, platform: TargetPlatform.iOS);
      try {
        await app.go(settingsLocation(SettingsDestination.about));
        final row = find.text('Open-source licences');
        await tester.scrollUntilVisible(row, 200, scrollable: find.byType(Scrollable).last);
        await tester.tap(row);
        await pumpFrames(tester, count: 10);
        expect(app.location, licensesLocation);
        expect(find.byType(DanaviewLicensesScreen), findsOneWidget);
        expect(find.text('FFmpeg'), findsOneWidget);
        expect(find.text('mpv'), findsOneWidget);

        // A deep link opens it too, and Back returns to Settings.
        await app.go(licensesLocation);
        expect(app.location, '/settings/licenses');
        expect(find.byType(DanaviewLicensesScreen), findsOneWidget);
        expect(find.byType(DanaviewHomeScreen), findsNothing);
        await tester.tap(find.byTooltip('Back'));
        await pumpFrames(tester, count: 10);
        expect(find.byType(DanaviewLicensesScreen), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await app.dispose();
      }
    });
  });

  // ---------------------------------------------------------------------------------------------
  group('macOS (D-17)', () {
    testWidgets('no Edit in the player top bar or the Playback sheet, no E shortcut line, no speech contributor', (tester) async {
      final app = await pumpWiredApp(tester, platform: TargetPlatform.macOS, engine: wiredEngine(), size: const Size(1280, 800));
      try {
        expect(app.runtime, isNull);
        expect(app.container.read(storageContributorsProvider), isEmpty);
        expect(app.container.read(editorRuntimeProvider), isNull);
        expect(() => app.container.read(transcriptionServiceProvider), throwsA(anything));

        await app.playVideo();
        expect(find.byType(DanaviewPlayerScreen), findsOneWidget);
        final screen = tester.widget<DanaviewPlayerScreen>(find.byType(DanaviewPlayerScreen));
        expect(screen.onEditVideo, isNull);
        expect(find.byKey(_editKey), findsNothing);
        expect(find.byTooltip('Edit video (E)'), findsNothing);

        // E does nothing.
        await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
        await pumpFrames(tester);
        expect(app.location, '/player');
        expect(find.byType(EditorScreen), findsNothing);

        // The Playback sheet has no Edit row.
        final more = find.byTooltip('Playback');
        if (more.evaluate().isNotEmpty) {
          await tester.tap(more.first);
          await pumpFrames(tester);
        }
        expect(find.byKey(_sheetRowKey), findsNothing);

        // The keyboard cheat sheet has no "E – Edit video" line.
        await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '?');
        await pumpFrames(tester);
        expect(find.textContaining('Edit video'), findsNothing);
        expect(app.engine.log.calls, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await app.dispose();
      }
    });

    testWidgets('the licences page is reachable without the editor (its gate is "always")', (tester) async {
      final app = await pumpWiredApp(tester, platform: TargetPlatform.macOS, engine: wiredEngine(), size: const Size(1280, 800));
      try {
        await app.go(licensesLocation);
        expect(app.location, licensesLocation);
        expect(find.byType(DanaviewLicensesScreen), findsOneWidget);
        expect(find.text('FFmpeg'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await app.dispose();
      }
    });
  });
}

