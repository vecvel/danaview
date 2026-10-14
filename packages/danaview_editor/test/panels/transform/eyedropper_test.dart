// OWNER: UX-23
//
// The eyedropper (ux.md §7.5): source-point mapping through the clip box and crop, the 15 Hz
// throttle of `EyedropperSampler`, and the overlay driven by `PreviewToolController.pickColor` with
// the fake engine (sampleColor calls throttled while dragging, the release colour returned to the
// caller, cancel returns null, the previous tool comes back), plus the matrix.

import 'dart:async';

import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/contracts/inspector_routes.dart';
import 'package:danaview_editor/src/editor/preview/crop_overlay.dart';
import 'package:danaview_editor/src/editor/preview/eyedropper_overlay.dart';
import 'package:danaview_editor_core/model.dart';

import '../../support/support.dart';
import 'transform_rig.dart';

/// The view centre of the clip A's box (it is centred on the canvas).
Offset clipCentre(TransformRig rig) => rig.geometry.viewRect.center;

void main() {
  group('EyedropperSampler', () {
    testWidgets('samples at most 15 times a second while dragging and once more on release', (tester) async {
      var asked = 0;
      final colors = <Color>[];
      final sampler = EyedropperSampler(
        sample: (p) async {
          asked++;
          return Color(0xFF000000 | (asked & 0xFF));
        },
        onColor: colors.add,
      );
      // 60 moves, one every 16 ms (about 1 s of dragging).
      for (var i = 0; i < 60; i++) {
        sampler.move(Offset(i / 60, 0.5));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(asked, inInclusiveRange(14, 16));
      expect(sampler.requests, asked);
      Color? result;
      unawaited(sampler.release(const Offset(0.9, 0.5)).then((c) => result = c));
      await tester.pump(const Duration(milliseconds: 200));
      expect(asked, inInclusiveRange(15, 17), reason: 'release samples once and drops pending samples');
      expect(result, colors.last);
      sampler.dispose();
    });

    testWidgets('the latest point wins inside a window; points outside the clip are skipped', (tester) async {
      final points = <Offset>[];
      final sampler = EyedropperSampler(sample: (p) async {
        points.add(p);
        return const Color(0xFF112233);
      }, onColor: (_) {});
      sampler.move(const Offset(0.1, 0.1));
      sampler.move(const Offset(0.2, 0.2));
      sampler.move(null);
      sampler.move(const Offset(0.3, 0.3));
      await tester.pump(const Duration(milliseconds: 70));
      expect(points, [const Offset(0.1, 0.1), const Offset(0.3, 0.3)]);
      sampler.dispose();
      await tester.pump(const Duration(milliseconds: 200));
    });
  });

  group('source mapping', () {
    testWidgets('the view point maps through the clip box and its crop', (tester) async {
      final rig = await TransformRig.pump(tester, project: (repo) => transformProject(repo, visuals: {Ids.a: const VisualProps(crop: CropRect(left: 0.2, top: 0.1, right: 0.6, bottom: 0.9))}));
      final p = eyedropperSourcePoint(rig.project, Ids.a, 0, rig.geometry, clipCentre(rig))!;
      expect(p.dx, closeTo(0.4, 1e-6));
      expect(p.dy, closeTo(0.5, 1e-6));
      expect(eyedropperSourcePoint(rig.project, Ids.a, 0, rig.geometry, const Offset(-50, -50)), isNull);
      expect(eyedropperSourcePoint(rig.project, Ids.text, 0, rig.geometry, clipCentre(rig)), isNull);
    });
  });

  group('overlay with the fake engine', () {
    testWidgets('a drag samples the pre-key source at ≤ 15 Hz and the release colour returns to the caller', (tester) async {
      final rig = await TransformRig.pump(tester);
      rig.preview.sampledColor = const Color(0xFF00B140);
      final live = <Color>[];
      Color? picked;
      var done = false;
      unawaited(rig.tools.pickColor(Ids.a, onSample: live.add).then((c) {
        picked = c;
        done = true;
      }));
      await tester.pump();
      await tester.pump();
      expect(find.byType(EyedropperOverlay), findsOneWidget);
      expect(find.text('Drag over the picture to pick a colour'), findsOneWidget);
      final centre = clipCentre(rig);
      final g = await tester.startGesture(rig.global(centre));
      for (var i = 0; i < 60; i++) {
        await g.moveBy(const Offset(0.5, 0.2));
        await tester.pump(const Duration(milliseconds: 16));
      }
      final during = rig.calls('preview.sampleColor');
      expect(during, inInclusiveRange(14, 17));
      expect(live, isNotEmpty);
      final state = tester.state<EyedropperOverlayState>(find.byType(EyedropperOverlay));
      expect(state.color, const Color(0xFF00B140));
      await g.up();
      await tester.pump();
      await tester.pump();
      expect(done, isTrue);
      expect(picked, const Color(0xFF00B140));
      expect(rig.calls('preview.sampleColor'), during + 1);
      expect(rig.tools.value, isNull);
      expect(find.byType(EyedropperOverlay), findsNothing);
    });

    testWidgets('Cancel returns null; the mask handles come back after a pick', (tester) async {
      final rig = await TransformRig.pump(tester, project: (repo) => transformProject(repo, visuals: {Ids.a: const VisualProps(mask: MaskSpec(shape: MaskShape.rectangle))}));
      await rig.open(Ids.a, MaskInspector.new);
      await tester.pump();
      expect(rig.tools.value, isA<MaskPreviewTool>());
      Color? picked = const Color(0xFFFFFFFF);
      var done = false;
      unawaited(rig.tools.pickColor(Ids.a).then((c) {
        picked = c;
        done = true;
      }));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('eyedropper.cancel')));
      await tester.pump();
      expect(done, isTrue);
      expect(picked, isNull);
      expect(rig.calls('preview.sampleColor'), 0);
      expect(rig.tools.value, isA<MaskPreviewTool>());
    });

    testWidgets('assistive technology samples the clip centre', (tester) async {
      final rig = await TransformRig.pump(tester);
      Color? picked;
      unawaited(rig.tools.pickColor(Ids.a).then((c) => picked = c));
      await tester.pump();
      await tester.pump();
      final node = tester.getSemantics(find.byType(EyedropperOverlay));
      expect(node.label, 'Colour picker on the preview');
      tester.binding.pipelineOwner.semanticsOwner!.performAction(node.id, SemanticsAction.tap);
      await tester.pump();
      await tester.pump();
      expect(picked, rig.preview.sampledColor);
    });

    test('pickColor on a disposed controller completes with null', () async {
      final c = PreviewToolController(() => null);
      c.dispose();
      expect(await c.pickColor(Ids.a), isNull);
    });
  });

  group('matrix (ARCH §17.9)', () {
    testSurfaces('the eyedropper banner fits', (tester, surface) async {
      final rig = await TransformRig.pump(tester, surface: surface);
      unawaited(rig.tools.pickColor(Ids.a));
      await tester.pump();
      await tester.pump();
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      rig.tools.cancelPick();
      await tester.pump();
    });
  });
}
