// OWNER: UX-23
//
// Crop mode (ux.md §7.5): the crop math (aspect presets, free and locked handle drags, moves,
// clamping), the crop panel (editing mode cropSource while open, aspect chips, rotate 90°, flips,
// reset, done) and the crop overlay's handles on the preview (one "Crop" entry per drag), plus the
// surface matrix.

import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/contracts/inspector_routes.dart';
import 'package:danaview_editor/src/editor/preview/canvas_geometry.dart';
import 'package:danaview_editor/src/editor/preview/crop_overlay.dart';
import 'package:danaview_editor_core/eval.dart' show Size2;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show CropSourceMode, NormalPreviewMode;

import '../../support/support.dart';
import 'transform_rig.dart';

const Size2 hd = Size2(1920, 1080);

Matcher closeCrop(CropRect c) => predicate<CropRect>(
      (x) => (x.left - c.left).abs() < 1e-6 && (x.top - c.top).abs() < 1e-6 && (x.right - c.right).abs() < 1e-6 && (x.bottom - c.bottom).abs() < 1e-6,
      'crop ≈ (${c.left}, ${c.top}, ${c.right}, ${c.bottom})',
    );

double pxRatio(CropRect c, Size2 src) => (src.width * (c.right - c.left)) / (src.height * (c.bottom - c.top));

Future<void> tapKey(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey<String>(key));
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await tester.pump();
  await tester.pump();
}

Future<TransformRig> pumpCrop(WidgetTester tester, {EditorSurface surface = SurfaceMatrix.phone, EditProject Function(FakeProjectRepository)? project}) async {
  final rig = await TransformRig.pump(tester, surface: surface, project: project);
  await rig.open(Ids.a, CropInspector.new);
  return rig;
}

/// Drags on the preview from the preview-area point [from] by [by] in several moves.
Future<void> dragPreview(WidgetTester tester, TransformRig rig, Offset from, Offset by) async {
  final g = await tester.startGesture(rig.global(from));
  for (var i = 0; i < 5; i++) {
    await g.moveBy(by / 5);
    await tester.pump();
  }
  await g.up();
  await tester.pump();
  await tester.pump();
}

void main() {
  group('CropMath', () {
    test('aspect presets give the largest crop of that pixel aspect around the current centre', () {
      for (final a in [CropAspect.r16x9, CropAspect.r9x16, CropAspect.r1x1, CropAspect.r4x5, CropAspect.r4x3]) {
        final c = CropMath.forAspect(CropRect.full, a, hd);
        expect(pxRatio(c, hd), closeTo(a.w! / a.h!, 1e-6), reason: a.label);
        expect(c.left >= 0 && c.top >= 0 && c.right <= 1 && c.bottom <= 1, isTrue, reason: a.label);
        expect((c.right - c.left == 1) || (c.bottom - c.top == 1), isTrue, reason: '${a.label} touches two edges');
        expect(CropMath.matching(c, hd), a == CropAspect.r16x9 ? CropAspect.original : a, reason: a.label);
      }
      expect(CropMath.forAspect(const CropRect(left: 0.1, top: 0.1, right: 0.5, bottom: 0.6), CropAspect.original, hd), CropRect.full);
      const some = CropRect(left: 0.1, top: 0.1, right: 0.5, bottom: 0.6);
      expect(CropMath.forAspect(some, CropAspect.free, hd), some);
      // Centred near the left edge: shifted to stay inside.
      final shifted = CropMath.forAspect(const CropRect(left: 0, top: 0.4, right: 0.1, bottom: 0.6), CropAspect.r1x1, hd);
      expect(shifted.left, 0);
      expect(pxRatio(shifted, hd), closeTo(1, 1e-6));
    });

    test('free handle drags move their edges and clamp to the source and the minimum size', () {
      expect(CropMath.drag(CropRect.full, CropHandle.bottomRight, const Offset(-0.2, -0.3)),
          closeCrop(const CropRect(left: 0, top: 0, right: 0.8, bottom: 0.7)));
      expect(CropMath.drag(CropRect.full, CropHandle.left, const Offset(0.25, 0.4)), closeCrop(const CropRect(left: 0.25, top: 0, right: 1, bottom: 1)));
      expect(CropMath.drag(CropRect.full, CropHandle.top, const Offset(0, -0.5)), closeCrop(CropRect.full));
      final tiny = CropMath.drag(CropRect.full, CropHandle.topLeft, const Offset(2, 2));
      expect(tiny.right - tiny.left, closeTo(CropMath.minSize, 1e-9));
      expect(tiny.bottom - tiny.top, closeTo(CropMath.minSize, 1e-9));
    });

    test('moves keep the size and stay inside', () {
      const c = CropRect(left: 0.2, top: 0.2, right: 0.6, bottom: 0.5);
      expect(CropMath.drag(c, CropHandle.move, const Offset(0.1, 0.1)), closeCrop(const CropRect(left: 0.3, top: 0.3, right: 0.7, bottom: 0.6)));
      expect(CropMath.drag(c, CropHandle.move, const Offset(5, -5)), closeCrop(const CropRect(left: 0.6, top: 0, right: 1, bottom: 0.3)));
    });

    test('locked drags keep the aspect on corners and edges', () {
      final start = CropMath.forAspect(CropRect.full, CropAspect.r1x1, hd);
      final r = CropMath.normalizedRatio(1, hd);
      for (final h in CropHandle.values.where((h) => h != CropHandle.move)) {
        final c = CropMath.drag(start, h, Offset(-0.1 * (h.sx == 0 ? 1 : h.sx), -0.1 * (h.sy == 0 ? 1 : h.sy)), ratio: r);
        expect(pxRatio(c, hd), closeTo(1, 1e-6), reason: h.name);
        expect(c.left >= 0 && c.top >= 0 && c.right <= 1 && c.bottom <= 1, isTrue, reason: h.name);
        expect(c.right - c.left, lessThan(start.right - start.left), reason: '${h.name} shrinks');
      }
      // The opposite corner stays.
      final br = CropMath.drag(start, CropHandle.bottomRight, const Offset(-0.1, -0.1), ratio: r);
      expect((br.left, br.top), (start.left, start.top));
      // Growing past the source is clamped.
      final big = CropMath.drag(start, CropHandle.bottomRight, const Offset(1, 1), ratio: r);
      expect(big.bottom, lessThanOrEqualTo(1));
      expect(pxRatio(big, hd), closeTo(1, 1e-6));
    });

    test('scale grows and shrinks around the centre; hit finds handles, edges and the inside', () {
      const c = CropRect(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75);
      final g = CropMath.scale(c, 0.1);
      expect(g.right - g.left, closeTo(0.55, 1e-9));
      expect((g.left + g.right) / 2, closeTo(0.5, 1e-9));
      const rect = Rect.fromLTRB(100, 100, 300, 200);
      expect(CropMath.hit(rect, const Offset(101, 99), slop: 22), CropHandle.topLeft);
      expect(CropMath.hit(rect, const Offset(200, 201), slop: 22), CropHandle.bottom);
      expect(CropMath.hit(rect, const Offset(299, 160), slop: 22), CropHandle.right);
      expect(CropMath.hit(rect, const Offset(150, 150), slop: 22), CropHandle.move);
      expect(CropMath.hit(rect, const Offset(10, 10), slop: 22), isNull);
    });

    test('the source rect is the source fitted into the letterboxed canvas', () {
      final g = CanvasGeometry.letterbox(const Size(1080, 1920), const Size(400, 400));
      final r = CropMath.sourceRect(g, hd);
      expect(r.width, closeTo(g.viewRect.width, 1e-9));
      expect(r.width / r.height, closeTo(16 / 9, 1e-9));
      expect(r.center.dy, closeTo(g.viewRect.center.dy, 1e-9));
    });
  });

  group('crop panel', () {
    testWidgets('opening puts the preview in cropSource mode; Done leaves it', (tester) async {
      final rig = await pumpCrop(tester);
      expect(rig.preview.mode, isA<CropSourceMode>().having((m) => m.item, 'item', Ids.a));
      expect(rig.tools.value, const CropPreviewTool(Ids.a));
      expect(find.byType(CropOverlay), findsOneWidget);
      expect(find.text('1920 × 1080 px'), findsOneWidget);
      await tapKey(tester, 'crop.done');
      await tester.pump();
      expect(rig.state.inspector, isNull);
      expect(rig.preview.mode, isA<NormalPreviewMode>());
      expect(rig.tools.value, isNull);
      expect(find.byType(CropOverlay), findsNothing);
    });

    testWidgets('aspect chips dispatch SetCrop with the preset, one labelled entry, and lock the frame', (tester) async {
      final rig = await pumpCrop(tester);
      final before = rig.entries;
      await tapKey(tester, 'crop.aspect.r1x1');
      expect(pxRatio(rig.visual(Ids.a).crop, hd), closeTo(1, 1e-6));
      expect(rig.undoLabel, 'Crop to 1:1');
      expect(rig.entries, before + 1);
      expect(rig.tools.value, const CropPreviewTool(Ids.a, aspect: CropAspect.r1x1));
      expect(find.text('1080 × 1080 px'), findsOneWidget);
      await tapKey(tester, 'crop.aspect.r9x16');
      expect(pxRatio(rig.visual(Ids.a).crop, hd), closeTo(9 / 16, 1e-6));
      await tapKey(tester, 'crop.aspect.original');
      expect(rig.visual(Ids.a).crop, CropRect.full);
      await tapKey(tester, 'crop.aspect.free');
      expect(rig.visual(Ids.a).crop, CropRect.full, reason: 'Free changes nothing');
      expect(rig.tools.value, const CropPreviewTool(Ids.a));
    });

    testWidgets('rotate 90° and the flips write the transform; reset restores the full source', (tester) async {
      final rig = await pumpCrop(tester, project: (repo) => transformProject(repo, visuals: {Ids.a: const VisualProps(crop: CropRect(left: 0.1, top: 0.1, right: 0.9, bottom: 0.8))}));
      await tapKey(tester, 'crop.rotate');
      expect(rig.visual(Ids.a).transform.rotationDeg, 90);
      expect(rig.undoLabel, 'Rotate 90°');
      await tapKey(tester, 'transform.flipH');
      expect(rig.visual(Ids.a).transform.flipH, isTrue);
      await tapKey(tester, 'crop.reset');
      expect(rig.visual(Ids.a).crop, CropRect.full);
      expect(rig.undoLabel, 'Reset crop');
    });

    testWidgets('rotate 90° wraps past 360°', (tester) async {
      final rig = await pumpCrop(tester, project: (repo) => transformProject(repo, visuals: {Ids.a: const VisualProps(transform: Transform2D(rotationDeg: 300))}));
      await tapKey(tester, 'crop.rotate');
      expect(rig.visual(Ids.a).transform.rotationDeg, 30);
    });

    testWidgets('an unknown picture size explains why and disables the chips', (tester) async {
      await pumpCrop(tester, project: (repo) => transformProject(repo, unknownSize: true));
      expect(find.textContaining('cannot be cropped'), findsOneWidget);
      expect(find.byType(CropOverlay), findsOneWidget);
    });
  });

  group('crop overlay', () {
    testWidgets('dragging the bottom-right handle is one "Crop" entry with SetCrop', (tester) async {
      final rig = await pumpCrop(tester);
      final src = CropMath.sourceRect(rig.geometry, hd);
      final before = rig.entries;
      await dragPreview(tester, rig, src.bottomRight - const Offset(1, 1), Offset(-src.width * 0.25, -src.height * 0.5));
      final c = rig.visual(Ids.a).crop;
      expect(c.right, closeTo(0.75, 0.02));
      expect(c.bottom, closeTo(0.5, 0.02));
      expect((c.left, c.top), (0.0, 0.0));
      expect(rig.entries, before + 1);
      expect(rig.undoLabel, 'Crop');
    });

    testWidgets('dragging inside moves the frame; with 1:1 a corner keeps the aspect', (tester) async {
      final rig = await pumpCrop(tester);
      await tapKey(tester, 'crop.aspect.r1x1');
      final src = CropMath.sourceRect(rig.geometry, hd);
      var view = CropMath.toView(rig.visual(Ids.a).crop, src);
      await dragPreview(tester, rig, view.topLeft + const Offset(1, 1), Offset(view.width * 0.2, view.height * 0.2));
      expect(pxRatio(rig.visual(Ids.a).crop, hd), closeTo(1, 1e-6));
      expect(rig.visual(Ids.a).crop.right - rig.visual(Ids.a).crop.left, lessThan(1080 / 1920 - 0.01));
      view = CropMath.toView(rig.visual(Ids.a).crop, src);
      final before = rig.visual(Ids.a).crop;
      await dragPreview(tester, rig, view.center, Offset(-view.width * 0.1, 0));
      final after = rig.visual(Ids.a).crop;
      expect(after.right - after.left, closeTo(before.right - before.left, 1e-6));
      expect(after.left, lessThan(before.left));
    });

    testWidgets('semantics increase grows the crop', (tester) async {
      final rig = await pumpCrop(tester, project: (repo) => transformProject(repo, visuals: {Ids.a: const VisualProps(crop: CropRect(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75))}));
      final node = tester.getSemantics(find.byType(CropOverlay));
      expect(node.label, 'Crop frame');
      tester.binding.pipelineOwner.semanticsOwner!.performAction(node.id, SemanticsAction.increase);
      await tester.pump();
      expect(rig.visual(Ids.a).crop.right - rig.visual(Ids.a).crop.left, greaterThan(0.5));
    });
  });

  group('matrix (ARCH §17.9)', () {
    testSurfaces('the crop panel fits on every surface', (tester, surface) async {
      await pumpCrop(tester, surface: surface);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      final done = find.byKey(const ValueKey<String>('crop.done'));
      await tester.ensureVisible(done);
      await tester.pump();
      expectNoOverflow(tester);
      expectInside(tester, done);
    });
  });
}
