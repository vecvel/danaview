// OWNER: UX-11
//
// Test support for the track headers, the track menu and the track bindings: lane fixtures for
// every kind and state, a recording command sink, and a rig that opens a real EditorController
// (ControllerRig over FakeEditorEngine) behind the providers the headers and the sheet read.

import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/app/editor_prefs.dart';
import 'package:vwish_editor/src/app/editor_providers.dart';
import 'package:vwish_editor/src/editor/contracts/contracts.dart';
import 'package:vwish_editor/src/editor/editor_scope.dart';
import 'package:vwish_editor/src/editor/state/edit_transaction.dart';
import 'package:vwish_editor/src/editor/state/editor_state.dart';
import 'package:vwish_editor/src/editor/timeline/timeline_metrics.dart';
import 'package:vwish_editor/src/editor/timeline/timeline_snapshot.dart';
import 'package:vwish_editor/src/editor/timeline/track_headers.dart';
import 'package:vwish_editor/src/editor/wiring/action_bindings.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart' show EditCommand;

import '../../state/state_support.dart';
import '../../support/support.dart';
import '../canvas/canvas_fixtures.dart';

export '../canvas/canvas_fixtures.dart' show asset, clip, f, projectOf, s;

final CaptionProvenance _provenance = CaptionProvenance(
  generator: 'whisper.cpp',
  engineVersion: '1.9.4',
  modelId: 'whisper-base-q5_1',
  modelSha256: 'abc',
  language: 'en',
  languageDetected: true,
  segmentation: const SegmentationSettings(),
  scope: CaptionScopeData(),
  generatedAt: DateTime.utc(2026),
);

/// A project with every lane kind: main video (two clips), extra video, overlay, text, subtitles,
/// two audio lanes (music, voice). Lane ids `tr_<name>`.
EditProject allKindsProject({
  bool locked = false,
  bool generatedSubtitles = false,
  bool burnIn = true,
  List<Track>? extra,
}) {
  final main = Track(
    id: const TrackId('tr_main'),
    kind: TrackKind.video,
    isMain: true,
    items: [clip('it_v1', 'm_a', 0, 4 * s), clip('it_v2', 'm_a', 4 * s, 4 * s)],
  );
  final video2 = Track(id: const TrackId('tr_video2'), kind: TrackKind.video, locked: locked, items: [clip('it_v3', 'm_a', 1 * s, 3 * s)]);
  final overlay = Track(id: const TrackId('tr_overlay'), kind: TrackKind.overlay, items: [clip('it_o', 'm_img', 1 * s, 2 * s)]);
  final text = Track(id: const TrackId('tr_text'), kind: TrackKind.text, items: [TextItem(id: const ItemId('it_t'), start: 0, duration: 2 * s, text: 'Hi')]);
  final subs = Track(
    id: const TrackId('tr_subs'),
    kind: TrackKind.subtitle,
    subtitle: SubtitleTrackData(
      burnIn: burnIn,
      provenance: generatedSubtitles ? _provenance : null,
    ),
    items: [SubtitleCue(id: const ItemId('it_c1'), start: 0, duration: 2 * s, text: 'One')],
  );
  final music = Track(
    id: const TrackId('tr_music'),
    kind: TrackKind.audio,
    audioRole: AudioRole.music,
    items: [clip('it_a1', 'm_snd', 0, 6 * s)],
  );
  final voice = Track(id: const TrackId('tr_voice'), kind: TrackKind.audio, audioRole: AudioRole.voice, items: []);
  return projectOf(
    [main, video2, overlay, text, subs, music, voice, ...?extra],
    assets: [asset('m_a'), asset('m_img', kind: MediaKind.image, hasAudio: false), asset('m_snd', kind: MediaKind.audio)],
  );
}

/// [project] with track [id] replaced by `change(track)`.
EditProject withTrack(EditProject project, String id, Track Function(Track track) change) => EditProject(
      id: project.id,
      meta: project.meta,
      timeline: project.timeline.copyWith(tracks: [for (final t in project.tracks) t.id == TrackId(id) ? change(t) : t]),
      pool: project.pool,
      view: project.view,
    );

/// The snapshot of [project].
TimelineSnapshot snapshotOfProject(EditProject project) => TimelineSnapshotBuilder().build(project);

/// A command sink that records every command and returns [result].
class RecordingSink {
  /// The commands, in order.
  final List<EditCommand> commands = [];

  /// What `apply` returns.
  EditResult result = EditApplied(label: 'test');

  /// The sink function.
  EditResult call(EditCommand command) {
    commands.add(command);
    return result;
  }

  /// Actions over this sink, recording the non-history operations too.
  TrackActions actions() => TrackActions(
        apply: call,
        focusLane: focused.add,
        selectAllOn: selectedAll.add,
        setLaneHeight: heights.add,
      );

  /// Lanes passed to `focusLane`.
  final List<TrackId> focused = [];

  /// Lanes passed to `selectAllOn`.
  final List<TrackId> selectedAll = [];

  /// Heights passed to `setLaneHeight`.
  final List<LaneHeightPreset> heights = [];
}

/// An editor opened on [project] behind the providers the headers and the sheet read.
class TrackRig {
  TrackRig._(this.rig, this.container, this.tester);

  /// The controller rig.
  final ControllerRig rig;

  /// The provider container of the pumped app.
  final ProviderContainer container;

  /// The tester.
  final WidgetTester tester;

  /// Project id.
  ProjectId get id => rig.id;

  /// The editor state.
  EditorState get state => container.read(editorControllerProvider(id));

  /// The project.
  EditProject get project => state.project!;

  /// The track [id] of the current project.
  Track track(String id) => project.tracks.firstWhere((t) => t.id == TrackId(id));

  /// Track ids in `Timeline.tracks` order.
  List<String> get order => [for (final t in project.tracks) t.id.value];

  /// Lets the controller and the widgets settle after a command.
  Future<void> settle() async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }
}

/// Pumps [builder]'s widget (inside the project's `EditorScope`) on [surface] over a controller
/// opened on [project]. [bindings] replace the action bindings (default: the real ones).
Future<TrackRig> pumpTrackRig(
  WidgetTester tester,
  Widget Function(ProjectId id) builder, {
  EditProject? project,
  EditorSurface surface = SurfaceMatrix.phone,
  Map<EditorActionId, EditorActionBinding>? bindings,
}) async {
  final repo = FakeProjectRepository();
  final id = repo.seed(project ?? allKindsProject());
  final rig = ControllerRig(repository: repo, id: id);
  await tester.runAsync(rig.open);
  applySurface(tester, surface);
  final scope = ProviderScope(
    overrides: [
      editorPrefsProvider.overrideWithValue(EditorPrefs.memory()),
      editorEngineProvider.overrideWithValue(rig.engine),
      editorSessionProvider.overrideWith((ref, id) => rig.session),
      editorControllerProvider.overrideWith((ref, id) => rig.controller),
      if (bindings != null) editorActionBindingsProvider.overrideWithValue(bindings),
    ],
    child: surfaceApp(surface, EditorScope(projectId: id, child: builder(id))),
  );
  await tester.pumpWidget(scope);
  await tester.pump();
  await tester.pump();
  final container = ProviderScope.containerOf(tester.element(find.byType(MaterialApp).first), listen: false);
  // The real controller factory keeps itself alive until close(); the test override does not, so
  // hold the providers while sheets (which watch them) come and go.
  final keep = [
    container.listen(editorControllerProvider(id), (_, __) {}),
    container.listen(timelineSnapshotProvider(id), (_, __) {}),
  ];
  addTearDown(() async {
    for (final k in keep) {
      k.close();
    }
    // The controller owns timers and streams; closing it lets the test end cleanly.
    await tester.runAsync(() => rig.controller.close());
  });
  return TrackRig._(rig, container, tester);
}
