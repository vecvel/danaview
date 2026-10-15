// OWNER: UX-38
//
// Test rig for Regenerate captions, the interrupted-job notice and the captions settings (UX-38):
// a project with a main video clip of [minutes] minutes (with audio), a music track and a generated
// Spanish captions lane with one cue every 2.5 s; the editor harness of the Auto captions rig (UX-37)
// with a real EditorController over FakeEditorEngine and a FakeTranscriptionService (AI-08).

import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_prefs.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/editor_scope.dart';
import 'package:danaview_editor/src/editor/flows/captions/interrupted_notice.dart';
import 'package:danaview_editor/src/editor/flows/captions/regenerate_sheet.dart';
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
abstract final class Regen {
  static const TrackId main = TrackId('tr_main');
  static const TrackId music = TrackId('tr_music');
  static const TrackId lane = TrackId('tr_auto');
  static const ItemId clip = ItemId('it_main');
  static const ItemId second = ItemId('it_second');
  static const ItemId song = ItemId('it_song');

  /// The id of cue [i] of the generated lane.
  static ItemId cue(int i) => ItemId('cu_$i');
}

MediaAsset _asset(String id, {required MediaKind kind, required int duration}) => MediaAsset(
      id: MediaId(id),
      kind: kind,
      displayName: '$id.file',
      locator: AppRelativeLocator(AppRoot.support, 'danaview/editor/media/$id/file'),
      ownership: MediaOwnership.managedCopy,
      fingerprint: MediaFingerprint(sizeBytes: 1000, quickHash: id.padRight(40, '0')),
      probe: MediaProbe(
        kind: kind,
        duration: duration,
        hasVideo: kind == MediaKind.video,
        hasAudio: true,
        width: kind == MediaKind.video ? 1920 : null,
        height: kind == MediaKind.video ? 1080 : null,
      ),
      origin: MediaOrigin.files,
      addedAt: DateTime.utc(2026, 10, 1),
    );

/// Provenance of the generated lane; [clips] scopes it to clips (a "This clip" run).
CaptionProvenance regenProvenance({List<ItemId> clips = const []}) => CaptionProvenance(
      generator: 'whisper.cpp',
      engineVersion: '1.9.4',
      modelId: SpeechModelCatalog.fast.id,
      modelSha256: SpeechModelCatalog.fast.sha256,
      language: 'es',
      languageDetected: false,
      segmentation: const SegmentationSettings(),
      scope: CaptionScopeData(clips: clips),
      transcriptKeys: const ['fake-transcript-key'],
      generatedAt: DateTime.utc(2026, 10, 2),
    );

/// Cue drafts every 2.5 s over [from]..[to] (timeline µs), 2 s long.
List<SubtitleCueDraft> drafts(int from, int to, {String prefix = 'Nuevo'}) => [
      for (var t = from, i = 0; t + 2 * s <= to; t += 2500000, i++) SubtitleCueDraft(TimeRange(t, t + 2 * s), '$prefix $i'),
    ];

/// The rig's project.
///
/// [minutes] of main clip (a second clip of the same length follows when [twoClips]); a lane with
/// one generated cue every 2.5 s over the first clip (and the second when [twoClips]); [edited]
/// cue indices are marked edited after generation and [manual] ones added by hand; [scopeClips]
/// scopes the provenance.
EditProject regenProject(
  ProjectId id, {
  int minutes = 1,
  bool twoClips = false,
  Set<int> edited = const {},
  Set<int> manual = const {},
  bool locked = false,
  List<ItemId> scopeClips = const [],
  bool generatedLane = true,
}) {
  final length = minutes * 60 * s;
  final end = twoClips ? 2 * length : length;
  final cues = <SubtitleCue>[];
  for (var t = 0, i = 0; t + 2 * s <= end; t += 2500000, i++) {
    cues.add(SubtitleCue(
      id: Regen.cue(i),
      start: t,
      duration: 2 * s,
      text: 'Hola $i',
      origin: manual.contains(i) ? CueOrigin.manual : CueOrigin.generated,
      editedAfterGeneration: edited.contains(i),
    ));
  }
  return EditProject(
    id: id,
    meta: ProjectMeta(name: 'Regenerate', createdAt: DateTime.utc(2026, 10, 1), updatedAt: DateTime.utc(2026, 10, 1)),
    timeline: Timeline(
      tracks: [
        Track(id: Regen.main, kind: TrackKind.video, isMain: true, items: [
          MediaClip(id: Regen.clip, start: 0, duration: length, media: const MediaId('m_v'), visual: const VisualProps()),
          if (twoClips) MediaClip(id: Regen.second, start: length, duration: length, media: const MediaId('m_v'), visual: const VisualProps()),
        ]),
        Track(id: Regen.music, kind: TrackKind.audio, name: 'Music', audioRole: AudioRole.music, items: [
          MediaClip(id: Regen.song, start: 0, duration: 30 * s, media: const MediaId('m_a')),
        ]),
        if (generatedLane)
          Track(
            id: Regen.lane,
            kind: TrackKind.subtitle,
            name: 'Captions (Spanish) · Auto',
            locked: locked,
            subtitle: SubtitleTrackData(language: 'es', provenance: regenProvenance(clips: scopeClips)),
            items: cues,
          ),
      ],
    ),
    pool: MediaPool({
      const MediaId('m_v'): _asset('m_v', kind: MediaKind.video, duration: length + 60 * s),
      const MediaId('m_a'): _asset('m_a', kind: MediaKind.audio, duration: 600 * s),
    }),
  );
}

const int gib = 1024 * 1024 * 1024;

/// The rig.
class RegenRig {
  /// Creates the rig over [project] (built for the rig's id), with [transcription] (default fake)
  /// and extra provider [overrides].
  RegenRig({
    EditProject Function(ProjectId id)? project,
    FakeTranscriptionService? transcription,
    Map<String, Object> prefs = const {},
    List<Override> overrides = const [],
  })  : repo = FakeProjectRepository(),
        transcription = transcription ?? FakeTranscriptionService(physicalRamBytes: 8 * gib, clock: () => DateTime.utc(2026, 10, 15, 12)) {
    final empty = repo.seedEmpty('Regenerate');
    id = empty.id;
    repo.seed((project ?? regenProject)(id));
    harness = EditorTestHarness(
      engine: FakeEditorEngine(validatePlans: false),
      repository: repo,
      transcription: this.transcription,
      prefs: EditorPrefs.memory(prefs),
      overrides: overrides,
    );
  }

  /// The project store.
  final FakeProjectRepository repo;

  /// The fake service.
  final FakeTranscriptionService transcription;

  /// The harness.
  late final EditorTestHarness harness;

  /// The project.
  late final ProjectId id;

  ProviderContainer? _container;

  /// The container.
  ProviderContainer get container => _container!;

  /// Marks [spec] (default Fast) installed.
  void install([SpeechModelSpec? spec]) {
    final m = spec ?? SpeechModelCatalog.fast;
    transcription.statuses[m.id] = SpeechModelReady(InstalledSpeechModel(spec: m, installedAt: DateTime.utc(2026, 10, 1)));
  }

  /// A container with the editor opened (unit tests).
  Future<ProviderContainer> open() async {
    final c = _container = ProviderContainer(overrides: harness.overrides);
    addTearDown(c.dispose);
    c.listen(editorControllerProvider(id), (_, __) {});
    await c.read(editorControllerProvider(id).notifier).open();
    await settle();
    return c;
  }

  /// The regenerator over the opened editor.
  CaptionRegenerator regenerator() {
    final c = container;
    final session = c.read(editorSessionProvider(id));
    final engine = c.read(editorEngineProvider);
    return CaptionRegenerator(
      service: c.read(transcriptionServiceProvider),
      editor: c.read(editorControllerProvider(id).notifier),
      state: () => c.read(editorControllerProvider(id)),
      timeline: () => DomainTimelineView(session.committedProject!, access: engine.access),
      clock: () => DateTime.utc(2026, 10, 15, 12),
    );
  }

  /// The editor controller.
  EditorController get editor => container.read(editorControllerProvider(id).notifier);

  /// The editor state.
  EditorState get editorState => container.read(editorControllerProvider(id));

  /// The committed project.
  EditProject get project => editorState.project!;

  /// Subtitle lanes.
  List<Track> get subtitleTracks => [for (final t in project.tracks) if (t.kind == TrackKind.subtitle) t];

  /// The generated lane.
  Track get lane => project.tracks.firstWhere((t) => t.id == Regen.lane);

  /// Lets the fakes' microtasks run.
  Future<void> settle([int turns = 12]) async {
    for (var i = 0; i < turns; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Pumps a host page inside the editor scope with a "Regenerate" button (opens the sheet for the
  /// generated lane) above [body] (default: the interrupted notice), and opens the editor.
  Future<void> pump(WidgetTester tester, {EditorSurface surface = SurfaceMatrix.phone, Widget? body}) async {
    await harness.pumpApp(
      tester,
      EditorScope(
        projectId: id,
        child: Scaffold(
          body: Builder(
            builder: (context) => SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DanaviewButton.primary(
                      key: const ValueKey('rig-regenerate'),
                      label: 'Regenerate',
                      onPressed: () => RegenerateSheet.show(context, projectId: id, track: Regen.lane),
                    ),
                    const SizedBox(height: 16),
                    body ?? InterruptedNotice(projectId: id),
                  ],
                ),
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
    await pumpSome(tester);
  }

  /// Opens the Regenerate sheet.
  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('rig-regenerate')));
    await pumpSome(tester);
  }

  /// Pumps a few frames.
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
}

/// A request for the rig's project (the fake never reads the timeline).
TranscriptionRequest rigRequest(ProjectId id, {TranscriptionScope scope = const TimelineScope(), SpokenLanguage language = const FixedLanguage('es')}) =>
    TranscriptionRequest(
      project: id,
      scope: scope,
      language: language,
      modelId: SpeechModelCatalog.fast.id,
      segmentation: const SegmentationSettings(preset: SegmentationPreset.singleLine),
      target: const ReplaceTrackTarget(Regen.lane),
      timeline: () => throw UnimplementedError('not read by the fake'),
    );

/// A store over the fake that also returns the stored request (as the real service does).
final class RecordingInterruptedStore implements InterruptedCaptionsStore {
  /// Creates the store.
  RecordingInterruptedStore(this.service, {this.requests = const {}});

  /// The fake.
  final FakeTranscriptionService service;

  /// Stored requests by job id.
  final Map<String, Map<String, Object?>> requests;

  /// Discarded job ids.
  final List<String> discarded = [];

  @override
  Future<ResumableTranscription?> pending(ProjectId project) async {
    if (service.activeJob != null) return null;
    return service.resumableForSync(project);
  }

  @override
  Future<Map<String, Object?>?> requestOf(ResumableTranscription job) async => requests[job.jobId];

  @override
  Future<void> discard(ResumableTranscription job) async {
    discarded.add(job.jobId);
    service.resumable.remove(job.project);
  }
}
