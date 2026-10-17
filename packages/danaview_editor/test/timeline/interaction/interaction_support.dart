// OWNER: UX-13
//
// Test rig of the interaction slot: UX-12's `pumpTimeline` (real EditorController over
// FakeEditorEngine, the gesture project) with `interactionProvider`'s slot taking the drags, plus
// a mouse helper, a haptic recorder and a registry action context.

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/actions/editor_action_registry.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_hit.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_interaction.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_view.dart';
import 'package:danaview_editor/src/editor/wiring/action_bindings.dart';
import 'package:danaview_editor_core/model.dart';

import '../gestures/gesture_support.dart';

export '../gestures/gesture_support.dart';

/// The interaction slot of the pumped timeline.
TimelineInteractionController interactionOf(TimelineRig t) => t.container.read(interactionProvider(t.id));

/// One mouse for a whole test (the mouse tracker wants one add per device).
Future<TestGesture> mouseAt(WidgetTester tester, Offset at) async {
  final g = await tester.createGesture(kind: PointerDeviceKind.mouse, pointer: 7);
  await g.addPointer(location: at);
  return g;
}

/// Clicks with [g] at [at].
Future<void> click(WidgetTester tester, TestGesture g, Offset at) async {
  await g.moveTo(at);
  await g.down(at);
  await g.up();
  await tester.pump();
}

/// Records `HapticFeedback` calls on the platform channel.
class HapticRecorder {
  HapticRecorder._();

  /// Starts recording for this test.
  static HapticRecorder install(WidgetTester tester) {
    final r = HapticRecorder._();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') r.calls.add(call.arguments as String?);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    return r;
  }

  /// The feedback types played, in order (`HapticFeedbackType.selectionClick`, …).
  final List<String?> calls = [];

  /// Number of selection clicks.
  int get selectionClicks => calls.where((c) => c == 'HapticFeedbackType.selectionClick').length;

  /// Number of light impacts.
  int get lightImpacts => calls.where((c) => c == 'HapticFeedbackType.lightImpact').length;
}

/// The registry with every binding merged, and a context for the pumped timeline.
({EditorActionRegistry registry, WidgetActionContext ctx}) actionsOf(WidgetTester tester, TimelineRig t) {
  final registry = EditorActionRegistry(bindings: mergeEditorActionBindings());
  final context = tester.element(find.byType(TimelineView));
  final ctx = WidgetActionContext.container(projectId: t.id, context: context, container: t.container, source: EditorActionSource.keyboard);
  return (registry: registry, ctx: ctx);
}

/// [gestureProject] plus a subtitle lane `tr_subs` (cues `cue_1` 1–2 s "Hello" and `cue_2` 3–4 s
/// "World") and 1 s fades on the music clip `it_m`.
EditProject interactionProject() {
  final p = gestureProject();
  final tracks = [...p.timeline.tracks];
  final musicIndex = tracks.indexWhere((t) => t.id == const TrackId('tr_music'));
  final music = tracks[musicIndex];
  final song = music.items.single as MediaClip;
  tracks[musicIndex] = music.copyWith(items: [song.copyWith(audio: const AudioProps(fadeIn: 1 * s, fadeOut: 1 * s))]);
  tracks.insert(
    musicIndex,
    Track(
      id: const TrackId('tr_subs'),
      kind: TrackKind.subtitle,
      items: const [
        SubtitleCue(id: ItemId('cue_1'), start: 1 * s, duration: 1 * s, text: 'Hello'),
        SubtitleCue(id: ItemId('cue_2'), start: 3 * s, duration: 1 * s, text: 'World'),
      ],
    ),
  );
  return p.copyWith(timeline: p.timeline.copyWith(tracks: tracks));
}

/// Global position of the [edge] fade handle of the selected item [id].
Offset fadeHandleAt(WidgetTester tester, TimelineRig t, String id, FadeEdge edge) {
  final c = t.canvas(tester);
  final g = c.geometry;
  final model = g.snapshot.item(ItemId(id))!;
  final li = g.snapshot.laneIndexOf(g.snapshot.laneOf(ItemId(id))!.id)!;
  return c.localToGlobal(g.fadeHandleCentre(g.itemRect(li, model), model, edge));
}

/// Global position of the [edge] trim handle of the selected item [id] (inside the clip edge).
Offset trimHandleAt(WidgetTester tester, TimelineRig t, String id, TrimEdge edge) {
  final c = t.canvas(tester);
  final g = c.geometry;
  final model = g.snapshot.item(ItemId(id))!;
  final li = g.snapshot.laneIndexOf(g.snapshot.laneOf(ItemId(id))!.id)!;
  final r = TimelineCanvasGeometry.trimHandleRect(g.itemRect(li, model), edge);
  return c.localToGlobal(Offset(r.center.dx, r.top + r.height * 0.8));
}
