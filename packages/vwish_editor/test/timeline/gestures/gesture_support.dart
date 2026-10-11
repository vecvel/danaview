// OWNER: UX-12
//
// Test rig for the timeline view and its gesture arbiter: a real EditorController (ControllerRig,
// FakeEditorEngine) opened on a small project, a TimelineView filling the screen, and helpers that
// turn (time, lane) into global positions through the canvas geometry.

import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/app/editor_prefs.dart';
import 'package:vwish_editor/src/app/editor_providers.dart';
import 'package:vwish_editor/src/editor/editor_scope.dart';
import 'package:vwish_editor/src/editor/state/editor_state.dart';
import 'package:vwish_editor/src/editor/timeline/render_timeline_canvas.dart';
import 'package:vwish_editor/src/editor/timeline/timeline_gestures.dart';
import 'package:vwish_editor/src/editor/timeline/timeline_hit.dart';
import 'package:vwish_editor/src/editor/timeline/timeline_semantics.dart';
import 'package:vwish_editor/src/editor/timeline/timeline_view.dart';
import 'package:vwish_editor/src/editor/timeline/timeline_viewport.dart';
import 'package:vwish_editor_core/model.dart';

import '../../state/state_support.dart';
import '../../support/support.dart';
import '../canvas/canvas_fixtures.dart';

export '../canvas/canvas_fixtures.dart' show f, s;

/// The test project:
///
/// * overlay `tr_ov`: `it_o` (image, 1–3 s) with opacity keys at frames 0 and 30;
/// * main `tr_main`: `it_a` 0–4 s, `it_b` 4–8 s (cross dissolve at 4 s), gap 8–10 s, `it_c` 10–14 s;
/// * video `tr_lock` (locked): `it_l` 2–6 s;
/// * audio `tr_music`: `it_m` 0–10 s;
/// * marker `mk_beat` at 6 s.
EditProject gestureProject() {
  final overlay = Track(
    id: const TrackId('tr_ov'),
    kind: TrackKind.overlay,
    items: [clip('it_o', 'm_logo', 1 * s, 2 * s, label: 'Logo', visual: const VisualProps(), keyframes: keys({'transform.opacity': [0, 30]}))],
  );
  final main = Track(
    id: const TrackId('tr_main'),
    kind: TrackKind.video,
    isMain: true,
    items: [
      clip('it_a', 'm_beach', 0, 4 * s, label: 'Beach', visual: const VisualProps()),
      clip('it_b', 'm_city', 4 * s, 4 * s, label: 'City', visual: const VisualProps()),
      clip('it_c', 'm_beach', 10 * s, 4 * s, label: 'Beach 2', visual: const VisualProps()),
    ],
    transitions: const [
      Transition(id: TransitionId('tx_ab'), left: ItemId('it_a'), right: ItemId('it_b'), kind: TransitionKind.crossDissolve, durationFrames: 10),
    ],
  );
  final locked = Track(
    id: const TrackId('tr_lock'),
    kind: TrackKind.video,
    locked: true,
    items: [clip('it_l', 'm_city', 2 * s, 4 * s, label: 'Locked', visual: const VisualProps())],
  );
  final music = Track(
    id: const TrackId('tr_music'),
    kind: TrackKind.audio,
    audioRole: AudioRole.music,
    items: [clip('it_m', 'm_song', 0, 10 * s, label: 'Song')],
  );
  return projectOf(
    [main, locked, overlay, music],
    assets: [
      asset('m_beach', name: 'beach.mp4'),
      asset('m_city', name: 'city.mov'),
      asset('m_logo', kind: MediaKind.image, name: 'logo.png', hasAudio: false),
      asset('m_song', kind: MediaKind.audio, name: 'song.m4a'),
    ],
    markers: const [Marker(id: MarkerId('mk_beat'), time: 6 * s, name: 'Beat')],
  );
}

/// A timeline under test.
class TimelineRig {
  TimelineRig._(this.rig, this.container);

  /// The controller rig.
  final ControllerRig rig;

  /// The provider container of the pumped app.
  final ProviderContainer container;

  /// The project id.
  ProjectId get id => rig.id;

  /// The editor state.
  EditorState get state => container.read(editorControllerProvider(id));

  /// The project.
  EditProject get project => state.project!;

  /// The view state.
  TimelineViewState viewState(WidgetTester tester) => tester.state<TimelineViewState>(find.byType(TimelineView));

  /// The viewport.
  TimelineViewportController get viewport => container.read(viewportProvider(id));

  /// The canvas.
  RenderTimelineCanvas canvas(WidgetTester tester) => tester.renderObject<RenderTimelineCanvas>(find.byType(TimelineCanvas));

  /// The basic interaction (UX-13 has not replaced it in these tests).
  TimelineBasicInteraction basic(WidgetTester tester) => viewState(tester).basicInteraction;

  /// Global position of time [t] in the middle of lane [lane] (vertical [fraction] of the lane).
  Offset at(WidgetTester tester, TimeUs t, String lane, {double fraction = 0.5}) {
    final c = canvas(tester);
    final g = c.geometry;
    final li = g.snapshot.laneIndexOf(TrackId(lane))!;
    final top = g.laneTop(li);
    return c.localToGlobal(Offset(viewport.xOf(t), top + g.stack.heights[li] * fraction));
  }

  /// Global position of time [t] in the ruler.
  Offset ruler(WidgetTester tester, TimeUs t) {
    final c = canvas(tester);
    return c.localToGlobal(Offset(viewport.xOf(t), -c.geometry.metrics.rulerHeight / 2));
  }

  /// The hit at [global].
  TimelineHit? hit(WidgetTester tester, Offset global) => viewState(tester).hitAt(global);

  /// Item [id] in the current project.
  TimelineItem item(String id) => project.index.locate(ItemId(id))!.item;

  /// Number of undo entries.
  int get historyDepth => state.history.position;

  /// Label of the newest undo entry.
  String? get undoLabel => state.history.undoLabel;
}

/// Pumps a [TimelineView] over [project] (default [gestureProject]) on a [size] screen for
/// [platform] (touch on Android/iOS, mouse on macOS). Free mode with 60 px/s and time 0 at the
/// left edge unless [centreLocked]; ripple mode off unless [ripple].
Future<TimelineRig> pumpTimeline(
  WidgetTester tester, {
  EditProject? project,
  Size size = const Size(1000, 420),
  TargetPlatform platform = TargetPlatform.android,
  double textScale = 1.0,
  bool centreLocked = false,
  bool ripple = false,
  double pxPerSecond = 60,
  TimelineInteractionSlot? interaction,
  Widget Function(Widget timeline)? wrap,
}) async {
  final repo = FakeProjectRepository();
  final id = repo.seed(project ?? gestureProject());
  final rig = ControllerRig(repository: repo, id: id);
  await tester.runAsync(rig.open);
  final prefs = EditorPrefs.memory();
  final surface = EditorSurface(size, textScale: textScale, platform: platform);
  applySurface(tester, surface);
  EditorAnnouncer.instance.reset();
  final scope = ProviderScope(
    overrides: [
      editorPrefsProvider.overrideWithValue(prefs),
      editorEngineProvider.overrideWithValue(rig.engine),
      editorSessionProvider.overrideWith((ref, id) => rig.session),
      editorControllerProvider.overrideWith((ref, id) => rig.controller),
    ],
    child: surfaceApp(surface, EditorScope(projectId: id, child: (wrap ?? (w) => w)(TimelineView(interaction: interaction)))),
  );
  await tester.pumpWidget(scope);
  await tester.pump();
  await tester.pump();
  final container = ProviderScope.containerOf(tester.element(find.byType(MaterialApp).first), listen: false);
  final t = TimelineRig._(rig, container);
  rig.controller.setModes((m) => m.copyWith(ripple: ripple));
  final viewport = t.viewport;
  viewport.setMode(centreLocked ? PlayheadFollowMode.centreLocked : PlayheadFollowMode.free);
  viewport.setPxPerSecond(pxPerSecond, anchorX: 0);
  if (!centreLocked) viewport.jumpTo(scrollTimeSec: 0, scrollY: 0);
  await tester.pump();
  addTearDown(EditorAnnouncer.instance.reset);
  return t;
}
