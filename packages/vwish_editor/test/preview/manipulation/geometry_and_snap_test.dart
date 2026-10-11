// OWNER: UX-22
//
// CanvasGeometry (letterbox mapping, boxes in the view), SnapGuides (centre/edges/safe margins,
// thresholds, rotation magnet, haptic on engagement) and ManipulationHandles (placement, hit
// radius, handles kept inside the view with leaders) — ux.md §7.2–7.4.

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/editor/preview/canvas_geometry.dart';
import 'package:vwish_editor/src/editor/preview/manipulation_painter.dart';
import 'package:vwish_editor/src/editor/preview/snap_guides.dart';
import 'package:vwish_editor_core/eval.dart';

void main() {
  group('CanvasGeometry', () {
    test('letterbox: fitted and centred, uniform scale', () {
      final g = CanvasGeometry.letterbox(const Size(1920, 1080), const Size(300, 300));
      expect(g.viewRect, const Rect.fromLTWH(0, 65.625, 300, 168.75));
      expect(g.scale, 300 / 1920);
      final p = CanvasGeometry.letterbox(const Size(1080, 1920), const Size(400, 300));
      expect(p.viewRect.height, 300);
      expect(p.viewRect.left, moreOrLessEquals((400 - 300 * 1080 / 1920) / 2));
    });

    test('view ↔ canvas round trip', () {
      final g = CanvasGeometry.letterbox(const Size(1920, 1080), const Size(300, 300));
      for (final c in const [Offset(0, 0), Offset(1920, 1080), Offset(960, 540), Offset(123.5, 987.25)]) {
        final v = g.toView(c);
        expect(g.toCanvas(v).dx, moreOrLessEquals(c.dx));
        expect(g.toCanvas(v).dy, moreOrLessEquals(c.dy));
      }
      expect(g.toView(Offset.zero), const Offset(0, 65.625));
      expect(g.toCanvas2(const Offset(150, 150)), const Offset2(960, 540));
    });

    test('boxes: oriented corners, path and hit test with view-px slop', () {
      final g = CanvasGeometry.letterbox(const Size(1920, 1080), const Size(384, 216));
      const box = ItemBox(center: Offset2(960, 540), base: Size2(400, 200), rotationDeg: 90);
      final cs = g.cornersOf(box);
      // Rotated 90° clockwise: the top-left corner (−200, −100) goes to (100, −200) around the centre.
      expect(cs[0].dx, moreOrLessEquals((960 + 100) * 0.2));
      expect(cs[0].dy, moreOrLessEquals((540 - 200) * 0.2));
      expect(g.hits(box, g.toView(const Offset(960, 540))), isTrue);
      expect(g.hits(box, g.toView(const Offset(960 + 150, 540))), isFalse, reason: 'outside the rotated width (200)');
      expect(g.hits(box, g.toView(const Offset(960 + 105, 540)), slop: 2), isTrue, reason: '2 view px = 10 canvas px of slop');
      expect(g.boxPath(box).contains(g.toView(const Offset(960, 540 + 190))), isTrue);
      expect(g.isEmpty, isFalse);
      expect(CanvasGeometry.letterbox(const Size(1920, 1080), Size.zero).isEmpty, isTrue);
    });
  });

  group('SnapGuides', () {
    const guides = SnapGuides(canvas: Size2(1920, 1080));
    ItemBox boxAt(double cx, double cy) => ItemBox(center: Offset2(cx, cy), base: const Size2(400, 200));

    test('centre lines snap the box centre within the threshold', () {
      final r = guides.snapMove(boxAt(965, 300), 10);
      expect(r.delta, const Offset2(-5, 0));
      expect(r.guides, {const SnapGuide(SnapAxis.vertical, 960, SnapTargetKind.center)});
      expect(guides.snapMove(boxAt(975, 300), 10).snapped, isFalse, reason: 'beyond the threshold');
    });

    test('edges snap the box bounds; both axes at once', () {
      final r = guides.snapMove(boxAt(206, 1080 - 104), 10);
      expect(r.delta, const Offset2(-6, 4));
      expect(r.guides.map((g) => g.kind).toSet(), {SnapTargetKind.edge});
      expect(r.guides, hasLength(2));
    });

    test('title-safe margins only while the guides are on', () {
      final box = boxAt(96 + 200 + 3, 300);
      expect(guides.snapMove(box, 10).snapped, isFalse);
      const safe = SnapGuides(canvas: Size2(1920, 1080), safeMargins: true);
      final r = safe.snapMove(box, 10);
      expect(r.delta.dx, moreOrLessEquals(-3));
      expect(r.guides.single.kind, SnapTargetKind.safeMargin);
    });

    test('rotated boxes snap by their bounds', () {
      const rotated = ItemBox(center: Offset2(500, 540), base: Size2(400, 200), rotationDeg: 90);
      // Bounds 400..600 wide 200: its right edge 600 is not a target; the centre y is.
      final r = guides.snapMove(rotated, 10);
      expect(r.guides, {const SnapGuide(SnapAxis.horizontal, 540, SnapTargetKind.center)});
    });

    test('rotation magnet: ±3° around multiples of 45°', () {
      expect(SnapGuides.snapRotation(43).degrees, 45);
      expect(SnapGuides.snapRotation(43).snapped, isTrue);
      expect(SnapGuides.snapRotation(-2.5).degrees, 0);
      expect(SnapGuides.snapRotation(91.5).degrees, 90);
      expect(SnapGuides.snapRotation(40).degrees, 40);
      expect(SnapGuides.snapRotation(40).snapped, isFalse);
    });

    test('thresholds: 6 view px with a pointer, 10 on touch', () {
      expect(SnapGuides.thresholdFor(touch: false), 6);
      expect(SnapGuides.thresholdFor(touch: true), 10);
    });

    test('haptic fires when a snap engages, not continuously', () {
      var clicks = 0;
      final e = SnapEngagement(haptic: () => clicks++);
      const g = SnapGuide(SnapAxis.vertical, 960, SnapTargetKind.center);
      e.guides({g});
      e.guides({g});
      e.guides({g});
      expect(clicks, 1);
      e.guides({});
      e.guides({g});
      expect(clicks, 2);
      e.rotation(true);
      e.rotation(true);
      expect(clicks, 3);
    });
  });

  group('ManipulationHandles', () {
    final g = CanvasGeometry.letterbox(const Size(1920, 1080), const Size(384, 216));

    test('corners, rotate handle 28 px above the top edge, hit radius by input', () {
      const box = ItemBox(center: Offset2(960, 540), base: Size2(800, 400));
      final touch = ManipulationHandles.layout(geometry: g, box: box, view: const Size(384, 216), touch: true);
      expect(touch.corners, hasLength(4));
      expect(touch.corners.first.position, const Offset(112, 68));
      expect(touch.rotate!.position, const Offset(192, 68 - 28));
      expect(touch.hitTest(const Offset(112 + 15, 68 + 15)), const HandleHit(ManipulationHandleKind.corner, 0));
      expect(touch.hitTest(const Offset(192, 40)), const HandleHit(ManipulationHandleKind.rotate));
      final pointer = ManipulationHandles.layout(geometry: g, box: box, view: const Size(384, 216), touch: false);
      expect(pointer.hitTest(const Offset(112 + 15, 68 + 15)), isNull, reason: 'pointer hit radius is 10');
      expect(pointer.hitTest(const Offset(112 + 5, 68 + 5)), const HandleHit(ManipulationHandleKind.corner, 0));
    });

    test('the rotate handle flips below near the top of the view', () {
      const box = ItemBox(center: Offset2(960, 300), base: Size2(800, 400));
      final h = ManipulationHandles.layout(geometry: g, box: box, view: const Size(384, 216), touch: true);
      // Top edge at y = 100 canvas = 20 view: 28 px above would leave the view.
      expect(h.rotate!.position.dy, moreOrLessEquals(100 + 28));
      expect(h.rotate!.anchor.dy, moreOrLessEquals(100));
    });

    test('handles outside the view are clamped inside with a leader', () {
      const box = ItemBox(center: Offset2(100, 540), base: Size2(800, 400));
      final h = ManipulationHandles.layout(geometry: g, box: box, view: const Size(384, 216), touch: true);
      final c = h.corners.first;
      expect(c.anchor.dx, lessThan(0));
      expect(c.position.dx, ManipulationHandles.cornerDiameter / 2);
      expect(c.clamped, isTrue);
      for (final spot in [...h.corners, h.rotate!]) {
        expect(spot.position.dx, inInclusiveRange(0, 384));
        expect(spot.position.dy, inInclusiveRange(0, 216));
      }
    });

    test('captions have no corner or rotate handles', () {
      const box = ItemBox(center: Offset2(960, 900), base: Size2(600, 80));
      final h = ManipulationHandles.layout(geometry: g, box: box, view: const Size(384, 216), touch: true, scalable: false, rotatable: false);
      expect(h.corners, isEmpty);
      expect(h.rotate, isNull);
      expect(h.hitTest(h.center), isNull);
    });

    test('readout text', () {
      expect(manipulationReadout(scale: 0.64, rotationDeg: 31.6), 'W 64% · 32°');
    });
  });
}
