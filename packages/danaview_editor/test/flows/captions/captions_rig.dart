// OWNER: UX-37
//
// Test rig for the Auto captions flow: a project with a 60 s main video clip (with audio), a music
// track and, optionally, an earlier generated captions lane; the editor harness with a real
// EditorController over FakeEditorEngine and a FakeTranscriptionService (AI-08); a host that records
// the wakelock and the privacy link and reports `en-US` as the device locale.

import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_prefs.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/editor_scope.dart';
import 'package:danaview_editor/src/editor/flows/captions/auto_captions_controller.dart';
import 'package:danaview_editor/src/editor/flows/captions/auto_captions_sheet.dart';
import 'package:danaview_editor/src/editor/flows/captions/model_consent_view.dart';
import 'package:danaview_editor/src/editor/state/editor_controller.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:danaview_transcription/danaview_transcription.dart';
import 'package:danaview_transcription/testing.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../support/support.dart';

export 'package:danaview_transcription/testing.dart';

const int s = microsPerSecond;

/// Ids of the rig's project.
abstract final class Cap {
  static const TrackId main = TrackId('tr_main');
  static const TrackId music = TrackId('tr_music');
  static const TrackId generated = TrackId('tr_auto');
  static const ItemId clip = ItemId('it_main');
  static const ItemId song = ItemId('it_song');
  static const ItemId oldCue = ItemId('cu_old');
}

const int gib = 1024 * 1024 * 1024;

MediaAsset _asset(String id, {required MediaKind kind}) => MediaAsset(
      id: MediaId(id),
      kind: kind,
      displayName: '$id.file',
      locator: AppRelativeLocator(AppRoot.support, 'danaview/editor/media/$id/file'),
      ownership: MediaOwnership.managedCopy,
      fingerprint: MediaFingerprint(sizeBytes: 1000, quickHash: id.padRight(40, '0')),
      probe: MediaProbe(
        kind: kind,
        duration: 600 * s,
        hasVideo: kind == MediaKind.video,
        hasAudio: true,
        width: kind == MediaKind.video ? 1920 : null,
        height: kind == MediaKind.video ? 1080 : null,
      ),
      origin: MediaOrigin.files,
      addedAt: DateTime.utc(2026, 10, 1),
    );

/// Provenance of the earlier generated lane.
CaptionProvenance oldProvenance() => CaptionProvenance(
      generator: 'whisper.cpp',
      engineVersion: '1.9.4',
      modelId: SpeechModelCatalog.fast.id,
      modelSha256: SpeechModelCatalog.fast.sha256,
      language: 'es',
      languageDetected: false,
      segmentation: const SegmentationSettings(preset: SegmentationPreset.shortPhrases),
      scope: CaptionScopeData(),
      generatedAt: DateTime.utc(2026, 10, 2),
    );

/// The rig's project; [generated] adds an earlier "Captions (Spanish) · Auto" lane with one cue.
EditProject captionsProject(ProjectId id, {bool generated = false, bool locked = false}) => EditProject(
      id: id,
      meta: ProjectMeta(name: 'Captions', createdAt: DateTime.utc(2026, 10, 1), updatedAt: DateTime.utc(2026, 10, 1)),
      timeline: Timeline(
        tracks: [
          Track(id: Cap.main, kind: TrackKind.video, isMain: true, items: [
            MediaClip(id: Cap.clip, start: 0, duration: 60 * s, media: const MediaId('m_v'), visual: const VisualProps()),
          ]),
          Track(id: Cap.music, kind: TrackKind.audio, name: 'Music', audioRole: AudioRole.music, items: [
            MediaClip(id: Cap.song, start: 0, duration: 30 * s, media: const MediaId('m_a')),
          ]),
          if (generated)
            Track(
              id: Cap.generated,
              kind: TrackKind.subtitle,
              name: 'Captions (Spanish) · Auto',
              locked: locked,
              subtitle: SubtitleTrackData(language: 'es', provenance: oldProvenance()),
              items: [SubtitleCue(id: Cap.oldCue, start: 0, duration: 2 * s, text: 'Hola', origin: CueOrigin.generated)],
            ),
        ],
      ),
      pool: MediaPool({
        const MediaId('m_v'): _asset('m_v', kind: MediaKind.video),
        const MediaId('m_a'): _asset('m_a', kind: MediaKind.audio),
      }),
    );

/// Wakelock calls and privacy-link taps.
class HostLog {
  /// Wakelock calls in order.
  final List<bool> wakelock = [];

  /// Privacy-link taps.
  int privacy = 0;
}

/// The rig.
class CaptionsRig {
  /// Creates the rig. [ramBytes] drives tier gating; [locale] is the device locale.
  CaptionsRig({
    bool generated = false,
    bool locked = false,
    int ramBytes = 8 * gib,
    Locale locale = const Locale('en', 'US'),
    Map<String, Object> prefs = const {},
    bool privacyLink = true,
  })  : repo = FakeProjectRepository(),
        transcription = FakeTranscriptionService(physicalRamBytes: ramBytes, clock: () => DateTime.utc(2026, 10, 15, 12)) {
    final empty = repo.seedEmpty('Captions');
    id = empty.id;
    repo.seed(captionsProject(id, generated: generated, locked: locked));
    harness = EditorTestHarness(
      engine: FakeEditorEngine(validatePlans: false),
      repository: repo,
      transcription: transcription,
      prefs: EditorPrefs.memory(prefs),
      overrides: [
        autoCaptionsHostProvider.overrideWithValue(AutoCaptionsHost(
          wakelock: host.wakelock.add,
          deviceLocale: () => locale,
          onOpenPrivacyPolicy: privacyLink ? () => host.privacy++ : null,
        )),
      ],
    );
  }

  /// The project store.
  final FakeProjectRepository repo;

  /// The fake service.
  final FakeTranscriptionService transcription;

  /// Host calls.
  final HostLog host = HostLog();

  /// The harness.
  late final EditorTestHarness harness;

  /// The project.
  late final ProjectId id;

  /// The last started fake job.
  FakeTranscriptionJob get job => transcription.jobs.last;

  /// Marks [spec] (default Balanced) installed.
  void install([SpeechModelSpec? spec]) {
    final m = spec ?? SpeechModelCatalog.balanced;
    transcription.statuses[m.id] = SpeechModelReady(InstalledSpeechModel(spec: m, installedAt: DateTime.utc(2026, 10, 1)));
  }

  // ---- Unit tests (no widget tree) -------------------------------------------------------------

  ProviderContainer? _container;

  /// A container with the editor opened and, unless [keepController] is false, the flow's
  /// controller kept alive by a listener.
  Future<ProviderContainer> open({bool keepController = true}) async {
    final c = _container = ProviderContainer(overrides: harness.overrides);
    addTearDown(c.dispose);
    c.listen(editorControllerProvider(id), (_, __) {});
    if (keepController) c.listen(autoCaptionsControllerProvider(id), (_, __) {});
    await c.read(editorControllerProvider(id).notifier).open();
    await settle();
    return c;
  }

  /// The user's consent to [disclosure], obtained the only way there is: pumping the consent view
  /// and tapping its Download button (ARCH §4.2 rule 8).
  static Future<UserConsent> consentFromView(WidgetTester tester, ConsentDisclosure disclosure) async {
    UserConsent? consent;
    applySurface(tester, SurfaceMatrix.phone);
    await tester.pumpWidget(surfaceApp(
      SurfaceMatrix.phone,
      Scaffold(
        body: SingleChildScrollView(
          child: ModelConsentView(disclosure: disclosure, onAccept: (c) => consent = c, onDecline: () {}),
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('captions-consent-accept')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    return consent!;
  }

  /// The controller.
  AutoCaptionsController get controller => _container!.read(autoCaptionsControllerProvider(id).notifier);

  /// The flow state.
  AutoCaptionsState get state => _container!.read(autoCaptionsControllerProvider(id));

  /// The editor controller.
  EditorController get editor => _container!.read(editorControllerProvider(id).notifier);

  /// The editor state.
  EditorState get editorState => _container!.read(editorControllerProvider(id));

  /// The committed project.
  EditProject get project => editorState.project!;

  /// Subtitle lanes of the project.
  List<Track> get subtitleTracks => [for (final t in project.tracks) if (t.kind == TrackKind.subtitle) t];

  /// Lets the fakes' microtasks and zero timers run.
  Future<void> settle([int turns = 12]) async {
    for (var i = 0; i < turns; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Opens the flow and settles.
  Future<void> openFlow({TranscriptionScope? scope}) async {
    await controller.open(scope: scope);
    await settle();
  }

  // ---- Widget tests ----------------------------------------------------------------------------

  /// Pumps a host page with an "Open captions" button inside the editor scope and opens the editor.
  Future<void> pump(WidgetTester tester, {EditorSurface surface = SurfaceMatrix.phone}) async {
    await harness.pumpApp(
      tester,
      EditorScope(
        projectId: id,
        child: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: DanaviewButton.primary(
                key: const ValueKey('rig-open'),
                label: 'Open captions',
                onPressed: () => AutoCaptionsSheet.show(context, projectId: id),
              ),
            ),
          ),
        ),
      ),
      surface: surface,
    );
    final c = harness.containerOf(tester);
    _container = c;
    c.listen(editorControllerProvider(id), (_, __) {});
    await tester.runAsync(() async {
      await c.read(editorControllerProvider(id).notifier).open();
      await settle();
    });
    await tester.pump();
  }

  /// Opens the sheet and lets the checks finish.
  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('rig-open')));
    await pumpSome(tester);
  }

  /// Pumps a few frames (sheet animation, fakes' microtasks).
  Future<void> pumpSome(WidgetTester tester, [int frames = 8]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// Taps the widget with [key] (scrolled into view) and pumps.
  Future<void> tapKey(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
    await pumpSome(tester);
  }

  /// A progress sample.
  static TranscriptionProgress sample(TranscriptionPhase phase, double fraction,
          {Duration? eta, PauseReason? paused, String? partial, int unit = 0, int units = 1, List<LanguageProbability>? candidates}) =>
      TranscriptionProgress(
        phase: phase,
        fraction: fraction,
        eta: eta,
        paused: paused,
        partialText: partial,
        unitIndex: unit,
        unitCount: units,
        languageCandidates: candidates,
      );
}
