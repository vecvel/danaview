// OWNER: UX-23
//
// Masks (ux.md §10.10, §7.5): the handle math (outline, corners, move, resize, rotate with the 45°
// magnet, feather), the mask panel (shape, rows per shape, invert, aspect lock, reset and
// keyframe-all dispatching the core commands) and the mask handles on the preview (one labelled
// entry per drag, keyframe-aware), plus the surface matrix.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/contracts/inspector_routes.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_header.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_rows.dart';
import 'package:danaview_editor/src/editor/inspector/keyframe_toggle.dart';
import 'package:danaview_editor/src/editor/panels/mask_panel.dart';
import 'package:danaview_editor/src/editor/preview/canvas_geometry.dart';
import 'package:danaview_editor/src/editor/preview/crop_overlay.dart';
import 'package:danaview_editor/src/editor/preview/mask_overlay.dart';
import 'package:danaview_editor_core/eval.dart' show ItemBox, Offset2, Size2;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../support/support.dart';
import 'transform_rig.dart';

const CanvasGeometry unit = CanvasGeometry(canvasPx: Size(1000, 1000), viewRect: Rect.fromLTWH(0, 0, 1000, 1000));
const ItemBox box = ItemBox(center: Offset2(500, 500), base: Size2(400, 200));
const MaskSpec rect = MaskSpec(shape: MaskShape.rectangle, center: Vec2(0.5, 0.5), size: Vec2(0.5, 0.5));

Matcher near(Offset o, [double eps = 1e-6]) =>
    predicate<Offset>((x) => (x - o).distance < eps, 'offset ≈ $o');

Future<void> tapKey(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey<String>(key));
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await tester.pump();
  await tester.pump();
}

Future<TransformRig> pumpMask(WidgetTester tester, {EditorSurface surface = SurfaceMatrix.phone, MaskSpec? mask, Map<ItemId, KeyframeSet> keys = const {}}) async {
  final rig = await TransformRig.pump(
    tester,
    surface: surface,
    project: (repo) => transformProject(repo, visuals: mask == null ? const {} : {Ids.a: VisualProps(mask: mask)}, keys: keys),
  );
  await rig.open(Ids.a, MaskInspector.new);
  return rig;
}

MaskHandles shownHandles(WidgetTester tester) => tester.state<MaskOverlayState>(find.byType(MaskOverlay)).handles!;

Future<void> dragPreview(WidgetTester tester, TransformRig rig, Offset from, Offset to) async {
  final g = await tester.startGesture(rig.global(from));
  for (var i = 1; i <= 5; i++) {
    await g.moveTo(rig.global(Offset.lerp(from, to, i / 5)!));
    await tester.pump();
  }
  await g.up();
  await tester.pump();
  await tester.pump();
}

void main() {
  group('MaskHandles', () {
    test('corners, centre and handles follow the clip box', () {
      final h = MaskHandles.layout(geometry: unit, box: box, mask: rect);
      expect(h.center, near(const Offset(500, 500)));
      expect(h.corners[0], near(const Offset(400, 450)));
      expect(h.corners[2], near(const Offset(600, 550)));
      expect(h.rotate, near(const Offset(500, 450 - MaskHandles.rotateOffset)));
      expect(h.feather, near(const Offset(600 + MaskHandles.featherOffset, 500)));
      expect(h.hit(const Offset(500, 500), slop: 22), MaskHandle.move);
      expect(h.hit(const Offset(401, 451), slop: 22), MaskHandle.topLeft);
      expect(h.hit(h.rotate, slop: 22), MaskHandle.rotate);
      expect(h.hit(h.feather, slop: 22), MaskHandle.feather);
      expect(h.hit(const Offset(50, 50), slop: 22), isNull);
    });

    test('a rotated, flipped clip box carries the mask', () {
      const turned = ItemBox(center: Offset2(500, 500), base: Size2(400, 200), rotationDeg: 90, flipH: true);
      final h = MaskHandles.layout(geometry: unit, box: turned, mask: rect);
      expect(h.center, near(const Offset(500, 500)));
      // Base-local top-left (400, 450 before placement) goes through flip then 90° clockwise.
      final expected = turned.fromLocalNormalized(const Offset2(0.25, 0.25));
      expect(h.corners[0], near(Offset(expected.dx, expected.dy)));
    });

    test('move, resize (free and locked), rotate (with the magnet) and feather', () {
      final h = MaskHandles.layout(geometry: unit, box: box, mask: rect);
      final moved = h.moved(const Offset(500, 500), const Offset(540, 520));
      expect(moved.x, closeTo(0.6, 1e-9));
      expect(moved.y, closeTo(0.6, 1e-9));
      final size = h.resized(const Offset(640, 560));
      expect(size.x, closeTo(0.7, 1e-9));
      expect(size.y, closeTo(0.6, 1e-9));
      final locked = h.resized(const Offset(640, 560), lockAspect: true);
      expect(locked.x, closeTo(locked.y, 1e-9));
      expect(h.rotated(const Offset(700, 500)), closeTo(90, 1e-9));
      expect(h.rotated(const Offset(700, 489), snap: false), isNot(90));
      expect(h.rotated(const Offset(700, 495)), 90, reason: 'within 3° of 90');
      expect(h.feathered(h.feather), closeTo(0, 1e-9));
      // feather f = 0.25·min(w, h)·feather; one normalized x unit is 400 view px here.
      final f = h.feathered(h.feather + const Offset(25, 0));
      expect(f, closeTo(25 / 400 / (0.25 * 0.5), 1e-9));
      expect(h.feathered(h.feather + const Offset(1000, 0)), 1);
    });

    test('an ellipse outline lies on the ellipse; uniform size keeps the proportions in range', () {
      final h = MaskHandles.layout(geometry: unit, box: box, mask: rect.copyWith(shape: MaskShape.ellipse));
      expect(h.outline.first, near(const Offset(600, 500)));
      final u = MaskCommands.uniformSize(const Vec2(0.4, 0.2), 0.8);
      expect(u.x, closeTo(0.8, 1e-9));
      expect(u.y, closeTo(0.4, 1e-9));
      final capped = MaskCommands.uniformSize(const Vec2(0.4, 0.2), 1.9);
      expect(capped.x, closeTo(1.9, 1e-9));
      final small = MaskCommands.uniformSize(const Vec2(1, 0.1), 0.01);
      expect(small.y, greaterThanOrEqualTo(0.01));
    });
  });

  group('mask panel', () {
    testWidgets('None shows only the shape; picking Rectangle dispatches SetMask, one labelled entry', (tester) async {
      final rig = await pumpMask(tester);
      expect(find.byType(InspectorSliderRow), findsNothing);
      expect(find.text('Pick a shape to show only part of the picture.'), findsOneWidget);
      expect(find.descendant(of: find.byType(InspectorHeader), matching: find.text('Mask')), findsOneWidget);
      final before = rig.entries;
      await tester.tap(find.descendant(of: find.byKey(const ValueKey<String>('mask.shape')), matching: find.text('Rectangle')));
      await tester.pump();
      await tester.pump();
      expect(rig.visual(Ids.a).mask.shape, MaskShape.rectangle);
      expect(rig.visual(Ids.a).mask.size, const Vec2(0.6, 0.6));
      expect(rig.undoLabel, 'Rectangle mask');
      expect(rig.entries, before + 1);
      final labels = tester.widgetList<InspectorSliderRow>(find.byType(InspectorSliderRow)).map((r) => r.label).toList();
      expect(labels, ['Position X', 'Position Y', 'Width', 'Height', 'Rotation', 'Corner radius', 'Feather', 'Opacity']);
      expect(find.byKey(const ValueKey<String>('mask.invert')), findsOneWidget);
      expect(rig.tools.value, const MaskPreviewTool(Ids.a));
    });

    testWidgets('Circle shows a locked Size row, unlocking shows Width and Height; no corner radius', (tester) async {
      final rig = await pumpMask(tester, mask: rect.copyWith(shape: MaskShape.ellipse, size: const Vec2(0.4, 0.2)));
      List<String> labels() => tester.widgetList<InspectorSliderRow>(find.byType(InspectorSliderRow)).map((r) => r.label).toList();
      expect(labels(), ['Position X', 'Position Y', 'Size', 'Rotation', 'Feather', 'Opacity']);
      expect(rig.tools.value, const MaskPreviewTool(Ids.a, lockAspect: true));
      // The Size slider keeps the proportions.
      final size = find.byKey(const ValueKey<String>('mask.size'));
      await tester.ensureVisible(size);
      await tester.pump();
      final g = await tester.startGesture(tester.getCenter(find.descendant(of: size, matching: find.byType(DanaviewSlider))));
      for (var i = 0; i < 4; i++) {
        await g.moveBy(const Offset(15, 0));
        await tester.pump();
      }
      await g.up();
      await tester.pump();
      final s = rig.visual(Ids.a).mask.size;
      expect(s.x, isNot(0.4));
      expect(s.y / s.x, closeTo(0.5, 1e-6));
      expect(rig.undoLabel, 'Change mask size');
      await tapKey(tester, 'mask.lock');
      expect(labels(), ['Position X', 'Position Y', 'Width', 'Height', 'Rotation', 'Feather', 'Opacity']);
      expect(rig.tools.value, const MaskPreviewTool(Ids.a));
    });

    testWidgets('rows dispatch SetProperty: width, feather, invert', (tester) async {
      final rig = await pumpMask(tester, mask: rect);
      Future<void> drag(String label, double dx) async {
        final slider = find.descendant(of: find.widgetWithText(InspectorSliderRow, label), matching: find.byType(DanaviewSlider));
        await tester.ensureVisible(slider);
        await tester.pump();
        final g = await tester.startGesture(tester.getCenter(slider));
        for (var i = 0; i < 4; i++) {
          await g.moveBy(Offset(dx / 4, 0));
          await tester.pump();
        }
        await g.up();
        await tester.pump();
      }

      await drag('Width', 40);
      expect(rig.visual(Ids.a).mask.size.x, isNot(0.5));
      expect(rig.visual(Ids.a).mask.size.y, 0.5);
      await drag('Feather', 60);
      expect(rig.visual(Ids.a).mask.feather, greaterThan(0));
      expect(rig.undoLabel, 'Change feather');
      final invert = find.descendant(of: find.byKey(const ValueKey<String>('mask.invert')), matching: find.byType(DanaviewSwitch));
      await tester.ensureVisible(invert);
      await tester.pump();
      await tester.tap(invert);
      await tester.pump();
      expect(rig.visual(Ids.a).mask.invert, isTrue);
      expect(find.descendant(of: find.widgetWithText(InspectorSliderRow, 'Feather'), matching: find.byType(PropertyKeyframeToggle)), findsOneWidget);
      expect(find.descendant(of: find.widgetWithText(InspectorSliderRow, 'Corner radius'), matching: find.byType(PropertyKeyframeToggle)), findsNothing);
    });

    testWidgets('None removes the mask and its keyframes; header keyframe-all keys the mask rows', (tester) async {
      final rig = await pumpMask(tester, mask: rect);
      await rig.seek(f(10));
      final toggle = find.descendant(of: find.byType(InspectorHeader), matching: find.byType(KeyframeToggle));
      await tester.tap(toggle);
      await tester.pump();
      for (final k in MaskRows.keyframable) {
        expect(KeyframeOps.hasKeyAt(keyframesOf(rig.item(Ids.a)), k, f(10)), isTrue, reason: k.id);
      }
      await tester.tap(find.descendant(of: find.byKey(const ValueKey<String>('mask.shape')), matching: find.text('None')));
      await tester.pump();
      expect(rig.visual(Ids.a).mask, MaskSpec.none);
      expect(TransformCommandsAnyKeys.any(rig.item(Ids.a)), isFalse);
      expect(rig.undoLabel, 'Remove mask');
    });
  });

  group('mask overlay', () {
    testWidgets('handles show over the clip at the playhead and drags write labelled entries', (tester) async {
      final rig = await pumpMask(tester, mask: rect);
      expect(find.byType(MaskOverlay), findsOneWidget);
      var h = shownHandles(tester);
      final before = rig.entries;
      await dragPreview(tester, rig, h.center, h.center + const Offset(10, 6));
      expect(rig.visual(Ids.a).mask.center, isNot(rect.center));
      expect(rig.undoLabel, 'Move mask');
      expect(rig.entries, before + 1);
      h = shownHandles(tester);
      await dragPreview(tester, rig, h.corners[2], h.corners[2] + const Offset(12, 12));
      expect(rig.undoLabel, 'Resize mask');
      expect(rig.visual(Ids.a).mask.size.x, greaterThan(0.5));
      h = shownHandles(tester);
      final right = h.center + const Offset(1, 0) * (h.rotate - h.center).distance;
      await dragPreview(tester, rig, h.rotate, right);
      expect(rig.undoLabel, 'Rotate mask');
      expect(rig.visual(Ids.a).mask.rotationDeg, closeTo(90, 3.01));
      h = shownHandles(tester);
      final out = (h.feather - h.featherAnchor) / (h.feather - h.featherAnchor).distance;
      await dragPreview(tester, rig, h.feather, h.feather + out * 20);
      expect(rig.undoLabel, 'Feather mask');
      expect(rig.visual(Ids.a).mask.feather, greaterThan(0));
    });

    testWidgets('a keyed mask property gets a key at the playhead', (tester) async {
      final rig = await pumpMask(tester, mask: rect, keys: {
        Ids.a: KeyframeSet({
          'mask.center.x': KeyframeTrack([Keyframe(f(0), 0.5), Keyframe(f(60), 0.5)]),
          'mask.center.y': KeyframeTrack([Keyframe(f(0), 0.5), Keyframe(f(60), 0.5)]),
        }),
      });
      await rig.seek(f(20));
      final h = shownHandles(tester);
      await dragPreview(tester, rig, h.center, h.center + const Offset(8, 0));
      expect(KeyframeOps.hasKeyAt(keyframesOf(rig.item(Ids.a)), PropertyKeys.maskCenter, f(20)), isTrue);
      expect(rig.visual(Ids.a).mask.center, rect.center, reason: 'static value kept');
    });

    testWidgets('no handles off the clip or without a shape; taps elsewhere pass through', (tester) async {
      final rig = await pumpMask(tester, mask: rect);
      await rig.seek(f(150));
      expect(find.byType(CustomPaint).evaluate().where((e) => (e.widget as CustomPaint).painter is MaskPainter), isEmpty);
      final p = MaskPainter(handles: MaskHandles.layout(geometry: unit, box: box, mask: rect));
      expect(p.hitTest(const Offset(10, 10)), isFalse);
      expect(p.hitTest(const Offset(500, 500)), isTrue);
    });
  });

  group('matrix (ARCH §17.9)', () {
    testSurfaces('the mask panel fits with each shape', (tester, surface) async {
      final rig = await pumpMask(tester, surface: surface, mask: rect);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      rig.editor.closeInspector();
      await tester.pump();
      await rig.open(Ids.b, MaskInspector.new);
      expectNoOverflow(tester);
      await tester.tap(find.descendant(of: find.byKey(const ValueKey<String>('mask.shape')), matching: find.text('Circle')));
      await tester.pump();
      await tester.pump();
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
    });
  });
}

/// Whether an item has any mask keyframes.
abstract final class TransformCommandsAnyKeys {
  static bool any(TimelineItem item) => MaskRows.keyframable.any((k) => KeyframeOps.isAnimated(keyframesOf(item), k));
}
