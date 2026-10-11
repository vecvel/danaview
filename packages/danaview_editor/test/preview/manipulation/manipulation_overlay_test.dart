// OWNER: UX-22
//
// ManipulationOverlay gestures (ux.md §7.3 rows, §7.4 snapping) on the preview region over the real
// EditorController and FakeEditorEngine: tap select and cycling, double-tap text, one-finger move,
// two-finger scale/rotate/transform, corner and rotate handles, trackpad pan-zoom, long-press menu,
// keyframe-aware writes at the playhead, captions' custom Y, transients ≤ 1 per frame, one history
// entry per gesture, cancel through the back order, semantics actions, and a golden of the handles.

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/editor_providers.dart';
import 'package:danaview_editor/src/editor/actions/editor_action_registry.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/editor_lifecycle.dart';
import 'package:danaview_editor/src/editor/preview/canvas_geometry.dart';
import 'package:danaview_editor/src/editor/preview/manipulation_overlay.dart';
import 'package:danaview_editor/src/editor/preview/manipulation_painter.dart';
import 'package:danaview_editor/src/editor/preview/snap_guides.dart';
import 'package:danaview_editor/src/editor/preview/text_overlay_layer.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';

import '../surface/preview_rig.dart';

// The region is 384×216 at the top-left (view = canvas × 0.2). The clip (scale 0.5) covers
// canvas 480–1440 × 270–810, i.e. view 96–288 × 54–162; the text sits at the centre.
const Offset _onClip = Offset(120, 70);

ManipulationOverlayState _overlay(WidgetTester tester) => tester.state<ManipulationOverlayState>(find.byType(ManipulationOverlay));

TimelineItem _item(PreviewRig rig, ItemId id) => rig.state.project!.index.locate(id)!.item;

T _value<T>(PreviewRig rig, ItemId id, PropertyKey<T> key, {TimeUs? at}) {
  final item = _item(rig, id);
  return evaluate(item, key, (at ?? rig.playhead.value) - item.start);
}

int _entries(PreviewRig rig) => rig.editor.session.historyEntries.length;

String? _undoLabel(PreviewRig rig) => rig.state.history.undoLabel;

/// Drags one finger from [from] by [by] in [steps] moves, pumping a frame after each.
Future<void> _drag(WidgetTester tester, Offset from, Offset by, {int steps = 6, bool up = true}) async {
  final g = await tester.startGesture(from);
  for (var i = 0; i < steps; i++) {
    await g.moveBy(by / steps.toDouble());
    await tester.pump(const Duration(milliseconds: 16));
  }
  if (up) {
    await g.up();
    await tester.pump();
  }
}

/// Two fingers from [a0]/[b0] to [a1]/[b1] in [steps].
Future<void> _twoFingers(WidgetTester tester, Offset a0, Offset b0, Offset a1, Offset b1, {int steps = 8}) async {
  final a = await tester.startGesture(a0, pointer: 1);
  final b = await tester.startGesture(b0, pointer: 2);
  await tester.pump();
  for (var i = 1; i <= steps; i++) {
    final f = i / steps;
    await a.moveTo(Offset.lerp(a0, a1, f)!);
    await b.moveTo(Offset.lerp(b0, b1, f)!);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await a.up();
  await tester.pump();
  await b.up();
  await tester.pump();
}

void main() {
  group('taps', () {
    testWidgets('tap selects the top-most item; repeated taps at the same point cycle', (tester) async {
      final rig = await PreviewRig.pump(tester);
      final center = rig.canvas(960, 540);
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 400));
      expect(rig.state.selection.primary, PreviewIds.text, reason: 'text composites above the clip');
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 400));
      expect(rig.state.selection.primary, PreviewIds.clip);
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 400));
      expect(rig.state.selection.primary, PreviewIds.text);
      expect(_entries(rig), 0, reason: 'selection is not history');
    });

    testWidgets('double tap on a text item opens the text panel', (tester) async {
      final rig = await PreviewRig.pump(tester);
      final center = rig.canvas(960, 540);
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 400));
      expect(rig.state.inspector, TextInspector(PreviewIds.text));
    });

    testWidgets('long press selects the item and opens its context menu', (tester) async {
      final rig = await PreviewRig.pump(tester);
      final g = await tester.startGesture(_onClip);
      await tester.pump(const Duration(milliseconds: 700));
      await g.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(rig.state.selection.primary, PreviewIds.clip);
      final registry = rig.container.read(editorActionRegistryProvider);
      for (final id in ManipulationOverlayState.menuActions) {
        // "Delete" also shows as the Delete key's shortcut label.
        expect(find.text(registry.spec(id).label), findsWidgets, reason: id.name);
      }
    });
  });

  group('one-finger move', () {
    testWidgets('drag on an unselected item selects it and moves it: one "Move" entry', (tester) async {
      final rig = await PreviewRig.pump(tester);
      await _drag(tester, _onClip, const Offset(30, 20), steps: 10);
      await rig.settle();
      expect(rig.state.selection.primary, PreviewIds.clip);
      final p = _value(rig, PreviewIds.clip, PropertyKeys.position);
      expect(p.x, moreOrLessEquals(150 / 1920));
      expect(p.y, moreOrLessEquals(100 / 1080));
      expect(_entries(rig), 1, reason: 'one entry per gesture');
      expect(_undoLabel(rig), ManipulationStrings.move);
      expect(rig.editor.undo(), isTrue);
      expect(_value(rig, PreviewIds.clip, PropertyKeys.position), Vec2.zero);
    });

    testWidgets('snaps to the canvas centre and edges, with guides and one haptic per engagement', (tester) async {
      final rig = await PreviewRig.pump(tester);
      final g = await tester.startGesture(_onClip);
      for (var i = 0; i < 6; i++) {
        await g.moveBy(const Offset(4 / 6, 60 / 6));
        await tester.pump(const Duration(milliseconds: 16));
      }
      final overlay = _overlay(tester);
      expect(overlay.shownGuides.map((g) => g.kind), containsAll([SnapTargetKind.center, SnapTargetKind.edge]));
      expect(overlay.snapEngagements, greaterThanOrEqualTo(1));
      final engaged = overlay.snapEngagements;
      await g.moveBy(const Offset(0.5, 0));
      await tester.pump(const Duration(milliseconds: 16));
      expect(overlay.snapEngagements, engaged, reason: 'no haptic while the snap holds');
      await g.up();
      await tester.pump();
      final p = _value(rig, PreviewIds.clip, PropertyKeys.position);
      expect(p.x, moreOrLessEquals(0, epsilon: 1e-9), reason: 'centre x snapped');
      expect(p.y, moreOrLessEquals(0.25), reason: 'bottom edge snapped to the canvas bottom');
      expect(overlay.shownGuides, isEmpty);
    });

    testWidgets('snapping off (global mode) moves freely', (tester) async {
      final rig = await PreviewRig.pump(tester);
      rig.editor.setModes((m) => m.copyWith(snapping: false));
      await _drag(tester, _onClip, const Offset(4, 60));
      expect(_value(rig, PreviewIds.clip, PropertyKeys.position).x, moreOrLessEquals(20 / 1920));
    });

    testWidgets('holding Alt/Option suspends snapping for the drag', (tester) async {
      final rig = await PreviewRig.pump(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      expect(SnapGuides.altHeld, isTrue);
      await _drag(tester, _onClip, const Offset(4, 60));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      expect(_value(rig, PreviewIds.clip, PropertyKeys.position).x, moreOrLessEquals(20 / 1920));
      expect(SnapGuides.altHeld, isFalse);
    });

    testWidgets('transients reach the preview at most once per frame', (tester) async {
      final rig = await PreviewRig.pump(tester);
      final before = rig.engine.log.calls.where((c) => c == 'preview.setTransient').length;
      final g = await tester.startGesture(_onClip);
      const frames = 12;
      for (var f = 0; f < frames; f++) {
        for (var i = 0; i < 4; i++) {
          await g.moveBy(const Offset(1, 0.5)); // 4 pointer events per frame
        }
        await tester.pump(const Duration(milliseconds: 17));
      }
      final sent = rig.engine.log.calls.where((c) => c == 'preview.setTransient').length - before;
      expect(sent, greaterThan(0), reason: 'the move is previewed natively');
      expect(sent, lessThanOrEqualTo(frames));
      await g.up();
      await tester.pump();
      expect(_entries(rig), 1);
    });

    testWidgets('keyframed position: the move writes a key at the playhead ("Move (keyframe)")', (tester) async {
      final rig = await PreviewRig.pump(tester);
      final clip = PreviewIds.clip;
      expect(rig.editor.apply(AddKeyframe(KeyframeRef(clip, PropertyKeys.position.id, 0), value: Vec2.zero)).applied, isTrue);
      expect(rig.editor.apply(AddKeyframe(KeyframeRef(clip, PropertyKeys.position.id, 2 * s), value: const Vec2(0.2, 0))).applied, isTrue);
      await rig.real(() => rig.transport.seekTo(1 * s));
      expect(_value(rig, clip, PropertyKeys.position).x, moreOrLessEquals(0.1));
      final before = _entries(rig);
      // The clip moved right by 0.1 × 1920 = 192 canvas px (38.4 view px) at 1 s.
      await _drag(tester, _onClip + const Offset(38.4, 0), const Offset(0, 40), steps: 8);
      expect(_entries(rig), before + 1);
      expect(_undoLabel(rig), '${ManipulationStrings.move}${ManipulationStrings.keyframeSuffix}');
      expect(_value(rig, clip, PropertyKeys.position, at: 1 * s).y, moreOrLessEquals(200 / 1080));
      expect(_value(rig, clip, PropertyKeys.position, at: 0), Vec2.zero, reason: 'other keys untouched');
      expect(_value(rig, clip, PropertyKeys.position, at: 2 * s), const Vec2(0.2, 0));
    });
  });

  group('pinch, rotate, handles', () {
    testWidgets('two-finger pinch scales the selected item around its centre ("Scale")', (tester) async {
      final rig = await PreviewRig.pump(tester);
      rig.editor.select(PreviewIds.clip);
      await tester.pump();
      await _twoFingers(tester, const Offset(150, 140), const Offset(230, 140), const Offset(110, 140), const Offset(270, 140));
      expect(_value(rig, PreviewIds.clip, PropertyKeys.scale), moreOrLessEquals(1.0, epsilon: 1e-6));
      final p = _value(rig, PreviewIds.clip, PropertyKeys.position);
      expect(p.x.abs() < 1e-9 && p.y.abs() < 1e-9, isTrue, reason: 'focal point did not move: $p');
      expect(_entries(rig), 1);
      expect(_undoLabel(rig), ManipulationStrings.scale);
    });

    testWidgets('two-finger rotation rotates with the 45° magnet ("Rotate")', (tester) async {
      final rig = await PreviewRig.pump(tester);
      rig.editor.select(PreviewIds.clip);
      await tester.pump();
      // 88° clockwise around the focal point (190, 140): snaps to 90°.
      const c = Offset(190, 140);
      Offset at(double deg, double r) => c + Offset.fromDirection(deg * 3.141592653589793 / 180, r);
      await _twoFingers(tester, at(180, 40), at(0, 40), at(180 + 88, 40), at(88, 40));
      expect(_value(rig, PreviewIds.clip, PropertyKeys.rotation), 90);
      expect(_value(rig, PreviewIds.clip, PropertyKeys.scale), moreOrLessEquals(0.5, epsilon: 1e-6));
      expect(_undoLabel(rig), ManipulationStrings.rotate);
    });

    testWidgets('pinch with rotation and a moving focal point is one "Transform" entry', (tester) async {
      final rig = await PreviewRig.pump(tester);
      rig.editor.select(PreviewIds.clip);
      await tester.pump();
      await _twoFingers(tester, const Offset(150, 140), const Offset(230, 140), const Offset(140, 120), const Offset(260, 160));
      expect(_value(rig, PreviewIds.clip, PropertyKeys.scale), isNot(0.5));
      expect(_value(rig, PreviewIds.clip, PropertyKeys.rotation), isNot(0));
      expect(_entries(rig), 1);
      expect(_undoLabel(rig), ManipulationStrings.transform);
    });

    testWidgets('corner handle: uniform scale from the centre ("Scale")', (tester) async {
      final rig = await PreviewRig.pump(tester);
      rig.editor.select(PreviewIds.clip);
      await tester.pump();
      // Bottom-right corner (288, 162) out to (336, 189): 1.5× the distance from the centre (192, 108).
      await _drag(tester, const Offset(288, 162), const Offset(48, 27), steps: 8);
      expect(_value(rig, PreviewIds.clip, PropertyKeys.scale), moreOrLessEquals(0.75, epsilon: 1e-6));
      expect(_value(rig, PreviewIds.clip, PropertyKeys.position), Vec2.zero);
      expect(_undoLabel(rig), ManipulationStrings.scale);
    });

    testWidgets('rotate handle: rotates about the centre, snapping near 45° steps ("Rotate")', (tester) async {
      final rig = await PreviewRig.pump(tester);
      rig.editor.select(PreviewIds.clip);
      await tester.pump();
      // The handle sits 28 px above the top edge's midpoint: (192, 26). Drag it round to the right.
      final g = await tester.startGesture(const Offset(192, 26));
      for (final p in const [Offset(210, 30), Offset(240, 50), Offset(262, 80), Offset(272, 104)]) {
        await g.moveTo(p);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pump();
      // atan2 of (80, −4) from the centre ≈ −2.9° → 87.1° clockwise from the start → magnet 90°.
      expect(_value(rig, PreviewIds.clip, PropertyKeys.rotation), 90);
      expect(_undoLabel(rig), ManipulationStrings.rotate);
    });

    testWidgets('trackpad pinch (pan-zoom) scales the selected item', (tester) async {
      final rig = await PreviewRig.pump(tester);
      rig.editor.select(PreviewIds.clip);
      await tester.pump();
      final g = await tester.createGesture(kind: PointerDeviceKind.trackpad);
      await g.panZoomStart(const Offset(190, 140));
      await tester.pump();
      for (var i = 1; i <= 5; i++) {
        await g.panZoomUpdate(const Offset(190, 140), scale: 1 + i * 0.2);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.panZoomEnd();
      await tester.pump();
      expect(_value(rig, PreviewIds.clip, PropertyKeys.scale), moreOrLessEquals(1.0, epsilon: 1e-6));
      expect(_entries(rig), 1);
    });
  });

  group('captions, cancel, semantics', () {
    testWidgets('dragging a caption moves its track to a custom Y ("Move captions")', (tester) async {
      final rig = await PreviewRig.pump(
        tester,
        project: (repo) => previewProject(repo, withText: false, extra: const [AddCue(0, 'A caption', duration: 3 * s)]),
      );
      final track = rig.state.project!.tracks.firstWhere((t) => t.kind == TrackKind.subtitle);
      final cue = track.items.single.id;
      final engine = rig.container.read(previewTextEngineProvider);
      final box = boxAt(rig.state.project!, cue, 0, text: engine)!;
      final from = rig.canvas(box.center.dx, box.center.dy);
      await _drag(tester, from, const Offset(10, -60), steps: 8);
      expect(rig.state.selection.primary, cue);
      final data = rig.state.project!.tracks.firstWhere((t) => t.id == track.id).subtitle!;
      expect(data.position, isA<CustomSubtitlePosition>());
      expect((data.position as CustomSubtitlePosition).yFraction, moreOrLessEquals((box.center.dy - 300) / 1080, epsilon: 1e-6));
      expect(_undoLabel(rig), ManipulationStrings.moveCaptions);
      expect(_entries(rig), 1);
    });

    testWidgets('the back order cancels a gesture in progress and restores the base', (tester) async {
      final rig = await PreviewRig.pump(
        tester,
        open: false,
        home: (id) => Consumer(
          builder: (context, ref, _) => EditorLifecycle(
            delegate: ref.read(editorControllerProvider(id).notifier),
            onExit: () {},
            child: regionHome(id),
          ),
        ),
      );
      await rig.openEditor();
      final g = await tester.startGesture(_onClip);
      for (var i = 0; i < 6; i++) {
        await g.moveBy(const Offset(5, 3));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(_overlay(tester).isManipulating, isTrue);
      expect(_value(rig, PreviewIds.clip, PropertyKeys.position), isNot(Vec2.zero));
      final dispatcher = EditorBackDispatcher.of(tester.element(find.byType(ManipulationOverlay)));
      expect(await dispatcher.handleBack(), EditorBackStep.cancelGesture);
      await tester.pump();
      expect(_overlay(tester).isManipulating, isFalse);
      expect(_value(rig, PreviewIds.clip, PropertyKeys.position), Vec2.zero);
      await g.moveBy(const Offset(10, 0));
      await g.up();
      await tester.pump();
      expect(_entries(rig), 0);
      expect(_value(rig, PreviewIds.clip, PropertyKeys.position), Vec2.zero);
    });

    testWidgets('semantics actions move, scale and rotate the selected item', (tester) async {
      final handle = tester.ensureSemantics();
      final rig = await PreviewRig.pump(tester);
      rig.editor.select(PreviewIds.clip);
      await tester.pump();
      expect(find.bySemanticsLabel(RegExp(r'^Selected clip, scale 50 percent, rotation 0 degrees')), findsOneWidget);
      final finder = find.bySemanticsLabel(RegExp(r'^Selected clip'));
      void perform(String label) {
        final node = tester.getSemantics(finder);
        final owner = node.owner!;
        final action = node.getSemanticsData().customSemanticsActionIds!
            .map(CustomSemanticsAction.getAction)
            .firstWhere((a) => a!.label == label)!;
        owner.performAction(node.id, SemanticsAction.customAction, CustomSemanticsAction.getIdentifier(action));
      }

      perform(ManipulationStrings.moveRight);
      await tester.pump();
      expect(_value(rig, PreviewIds.clip, PropertyKeys.position).x, moreOrLessEquals(ManipulationSteps.move));
      perform(ManipulationStrings.scaleUp);
      await tester.pump();
      expect(_value(rig, PreviewIds.clip, PropertyKeys.scale), moreOrLessEquals(0.55));
      perform(ManipulationStrings.rotateClockwise);
      await tester.pump();
      expect(_value(rig, PreviewIds.clip, PropertyKeys.rotation), ManipulationSteps.rotate);
      expect(_entries(rig), 3);
      handle.dispose();
    });
  });

  group('golden', () {
    testWidgets('handles, guides and readout', (tester) async {
      final g = CanvasGeometry.letterbox(const Size(1920, 1080), const Size(384, 216));
      const box = ItemBox(center: Offset2(1500, 300), base: Size2(800, 450), scale: 0.6, rotationDeg: 20);
      final handles = ManipulationHandles.layout(geometry: g, box: box, view: const Size(384, 216), touch: true);
      final guides = ManipulationPainter.viewGuides(
        g,
        const SnapGuides(canvas: Size2(1920, 1080)).segmentsOf({const SnapGuide(SnapAxis.horizontal, 540, SnapTargetKind.center)}),
      );
      await tester.pumpWidget(Center(
        child: RepaintBoundary(
          child: SizedBox(
            width: 384,
            height: 216,
            child: ColoredBox(
              color: const Color(0xFF222222),
              child: CustomPaint(painter: ManipulationPainter(handles: handles, guides: guides, readout: manipulationReadout(scale: 0.6, rotationDeg: 20))),
            ),
          ),
        ),
      ));
      await expectLater(find.byType(RepaintBoundary).first, matchesGoldenFile('goldens/manipulation_handles.png'));
    });
  });
}
