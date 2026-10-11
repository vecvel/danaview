// OWNER: UX-19
//
// TextOverlayLayer / TextOverlayPainter (D-05, ARCH §13.1, BUILD_PLAN UX-19):
// * parity: text styles and animations at key times match the API-04 sprite rasterization (the
//   export path) within 1 px, plus goldens of the overlay;
// * scene: active items only, bottom → top, burn-in-off subtitle tracks previewed, hidden lanes
//   skipped, cues at their track position;
// * per-frame cost ≤ 1 ms for 10 visible items (profile-style timing of the paint);
// * playback repaints the overlay once per frame and never rebuilds the editor scaffold.

import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/debug/rebuild_counters.dart';
import 'package:vwish_editor/src/editor/layout/editor_scaffold.dart';
import 'package:vwish_editor/src/editor/preview/canvas_geometry.dart';
import 'package:vwish_editor/src/editor/preview/fullscreen_preview.dart';
import 'package:vwish_editor/src/editor/preview/text_overlay_layer.dart';
import 'package:vwish_editor_core/eval.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart';
import 'package:vwish_editor_engine_api/vwish_editor_engine_api.dart';

import '../surface/preview_rig.dart' show PreviewIds, PreviewRig;
import 'text_overlay_support.dart';

/// A parity case: an item and the times to compare.
class _Case {
  const _Case(this.name, this.text, {this.style = const TextStyleSpec(), this.animation = const TextAnimation(), this.extra, required this.times});

  final String name;
  final String text;
  final TextStyleSpec style;
  final TextAnimation animation;
  final List<EditCommand> Function(ItemId id)? extra;
  final List<TimeUs> times;
}

final List<_Case> _cases = [
  const _Case('plain', 'Hello world', times: [1 * us]),
  const _Case(
    'styled',
    'Bold italic\nsecond line',
    style: TextStyleSpec(
      fontSizePt: 64,
      bold: true,
      italic: true,
      align: TextAlignH.left,
      color: 0xFFFFD54F,
      letterSpacing: 2,
      lineHeight: 1.4,
      background: BoxStyle(color: 0xFF1E3A8A, opacity: 0.8, paddingPt: 16, cornerRadiusPt: 10),
      stroke: StrokeStyle(color: 0xFF000000, widthPt: 3),
      shadow: ShadowStyle(color: 0xFF000000, opacity: 0.6, blurPt: 4, distancePt: 4, angleDeg: 90),
    ),
    times: [1 * us],
  ),
  const _Case('fade', 'Fading in', animation: TextAnimation(inKind: TextAnimKind.fade, inDuration: 1 * us), times: [500000, 2 * us]),
  const _Case(
    'slide',
    'Sliding',
    animation: TextAnimation(inKind: TextAnimKind.slide, inDirection: TextSlideDirection.left, inDuration: 1 * us, outKind: TextAnimKind.slide, outDuration: 1 * us),
    times: [400000, 3500000],
  ),
  const _Case('scale', 'Scaling', animation: TextAnimation(inKind: TextAnimKind.scale, inDuration: 1 * us), times: [500000]),
  const _Case(
    'typewriter',
    'Typing it out',
    style: TextStyleSpec(background: BoxStyle(color: 0xFF000000, opacity: 0.7, paddingPt: 12, cornerRadiusPt: 6)),
    animation: TextAnimation(inKind: TextAnimKind.typewriter, inDuration: 2 * us),
    times: [700000, 2500000],
  ),
  _Case(
    'transformed',
    'Rotated and moved',
    extra: (id) => [
      SetProperty<double>([id], PropertyKeys.rotation, 30),
      SetProperty<double>([id], PropertyKeys.scale, 1.5),
      SetProperty<Vec2>([id], PropertyKeys.position, const Vec2(0.1, -0.2)),
      SetProperty<double>([id], PropertyKeys.opacity, 0.7),
    ],
    times: const [1 * us],
  ),
];

void main() {
  setUpAll(loadFigtree);

  group('parity with the API-04 sprites (within 1 px)', () {
    for (final c in _cases) {
      for (final t in c.times) {
        test('${c.name} at ${t / us}s', () async {
          final (project, id) = textProject(c.text, style: c.style, animation: c.animation, extra: c.extra ?? (_) => const []);
          final rasterizer = TextSpriteRasterizer();
          final scene = TextOverlayScene(rasterizer.engine);
          final overlay = await overlayImage(scene, project, t);
          final a = await rgbaOf(overlay);
          final b = await exportLikeRgba(rasterizer, project, id, t);
          final w = overlay.width, h = overlay.height;
          overlay.dispose();
          final ia = inkBounds(a, w, h);
          final ib = inkBounds(b, w, h);
          expect(ia, isNotNull, reason: 'the overlay paints the item');
          expect(ib, isNotNull);
          expect((ia!.left - ib!.left).abs(), lessThanOrEqualTo(1), reason: '$ia vs $ib');
          expect((ia.top - ib.top).abs(), lessThanOrEqualTo(1), reason: '$ia vs $ib');
          expect((ia.right - ib.right).abs(), lessThanOrEqualTo(1), reason: '$ia vs $ib');
          expect((ia.bottom - ib.bottom).abs(), lessThanOrEqualTo(1), reason: '$ia vs $ib');
          expect(mismatchesBeyond1px(a, b, w, h), 0);
        });
      }
    }

    test('negative control: a 2 px misplacement is detected', () async {
      final (project, id) = textProject('Hello world');
      final (moved, _) = textProject('Hello world', extra: (id) => [SetProperty<Vec2>([id], PropertyKeys.position, const Vec2(2 / 1920, 0))]);
      final rasterizer = TextSpriteRasterizer();
      final overlay = await overlayImage(TextOverlayScene(rasterizer.engine), moved, 1 * us);
      final a = await rgbaOf(overlay);
      final b = await exportLikeRgba(rasterizer, project, id, 1 * us);
      expect(mismatchesBeyond1px(a, b, overlay.width, overlay.height), greaterThan(0));
      overlay.dispose();
    });

    test('typewriter reveals clusters with time (box grows with the text)', () async {
      final (project, _) = textProject(
        'Typing it out',
        style: const TextStyleSpec(background: BoxStyle(color: 0xFF000000, opacity: 0.7)),
        animation: const TextAnimation(inKind: TextAnimKind.typewriter, inDuration: 2 * us),
      );
      final scene = TextOverlayScene(TextLayoutEngine());
      double widthAt(TimeUs t) {
        final e = scene.entriesAt(project, t).single;
        return e.revealCount?.toDouble() ?? -1;
      }

      expect(widthAt(0), 0);
      expect(widthAt(1 * us), 6);
      expect(widthAt(3 * us), 13);
      final early = inkBounds(await rgbaOf(await overlayImage(scene, project, 500000)), 1920, 1080)!;
      final later = inkBounds(await rgbaOf(await overlayImage(scene, project, 1500000)), 1920, 1080)!;
      expect(later.width, greaterThan(early.width));
    });
  });

  group('goldens', () {
    for (final c in _cases) {
      test('overlay ${c.name}', () async {
        final (project, _) = textProject(c.text, style: c.style, animation: c.animation, extra: c.extra ?? (_) => const []);
        final scene = TextOverlayScene(TextLayoutEngine());
        final image = await overlayImage(scene, project, c.times.first, scale: 0.25);
        await expectLater(image, matchesGoldenFile('goldens/text_overlay_${c.name}.png'));
        image.dispose();
      });
    }
  });

  group('scene', () {
    test('only items active at t, bottom → top, cues at their track position', () {
      final (project, id) = textProject('Top', duration: 2 * us, extra: (id) => [
            const AddText(1 * us, text: 'Second lane', duration: 2 * us),
            const AddCue(0, 'A caption', duration: 3 * us),
          ]);
      final scene = TextOverlayScene(TextLayoutEngine());
      final at0 = scene.entriesAt(project, 0);
      expect(at0.map((e) => e.cue), [false, true], reason: 'text below subtitles');
      expect(at0.first.item, id);
      final at15 = scene.entriesAt(project, 1500000);
      expect(at15.where((e) => !e.cue), hasLength(2));
      expect(scene.entriesAt(project, 3500000), isEmpty);
      // The cue sits at the bottom safe margin.
      final cue = at0.last;
      final b = cue.layout.blockSize;
      expect(cue.center.dy + b.height / 2, moreOrLessEquals(1080 - subtitleSafeMargin * 1080, epsilon: 0.01));
      // Layouts are memoized per item instance.
      expect(identical(scene.entriesAt(project, 0).first.layout, at0.first.layout), isTrue);
    });

    test('burn-in-off subtitle tracks still preview; hidden lanes are skipped', () {
      final (project, _) = textProject('Text', extra: (id) => [const AddCue(0, 'Caption', duration: 3 * us)]);
      final track = project.tracks.firstWhere((t) => t.kind == TrackKind.subtitle).id;
      final edit = EditSession(project);
      expect(edit.apply(SetBurnIn(track, false)).changed, isTrue);
      final scene = TextOverlayScene(TextLayoutEngine());
      expect(edit.project.tracks.firstWhere((t) => t.id == track).subtitle!.burnIn, isFalse);
      expect(scene.entriesAt(edit.project, 1 * us).where((e) => e.cue), hasLength(1));
      expect(edit.apply(SetTrackFlags(track, hidden: true)).changed, isTrue);
      expect(scene.entriesAt(edit.project, 1 * us).where((e) => e.cue), isEmpty);
      final textTrack = edit.project.tracks.firstWhere((t) => t.kind == TrackKind.text).id;
      expect(edit.apply(SetTrackFlags(textTrack, hidden: true)).changed, isTrue);
      expect(scene.entriesAt(edit.project, 1 * us), isEmpty);
    });

    test('custom caption Y places the block centre at y·H', () {
      final (project, _) = textProject('Text', extra: (id) => [const AddCue(0, 'Caption', duration: 3 * us)]);
      final track = project.tracks.firstWhere((t) => t.kind == TrackKind.subtitle).id;
      final edit = EditSession(project);
      expect(edit.apply(SetSubtitlePosition(track, const CustomSubtitlePosition(0.25))).changed, isTrue);
      final cue = TextOverlayScene(TextLayoutEngine()).entriesAt(edit.project, 0).last;
      expect(cue.center.dy, moreOrLessEquals(270));
    });

    test('the painter maps canvas px through the letterbox geometry', () async {
      final (project, _) = textProject('Hello');
      final scene = TextOverlayScene(TextLayoutEngine());
      final full = inkBounds(await rgbaOf(await overlayImage(scene, project, 0)), 1920, 1080)!;
      final quarter = inkBounds(await rgbaOf(await overlayImage(scene, project, 0, scale: 0.25)), 480, 270)!;
      expect(quarter.center.dx, moreOrLessEquals(full.center.dx / 4, epsilon: 1));
      expect(quarter.center.dy, moreOrLessEquals(full.center.dy / 4, epsilon: 1));
    });
  });

  group('performance', () {
    test('per-frame cost ≤ 1 ms for 10 visible items', () {
      final (project, _) = textProject('Item 0', extra: (id) => [
            for (var i = 1; i < 10; i++) AddText(0, text: 'Item $i with a longer line', duration: 4 * us),
          ]);
      expect(project.tracks.where((t) => t.kind == TrackKind.text).length, 10);
      final scene = TextOverlayScene(TextLayoutEngine());
      final playhead = ValueNotifier<TimeUs>(0);
      final geometry = CanvasGeometry.letterbox(const Size(1920, 1080), const Size(390, 219.375));
      final painter = TextOverlayPainter(scene: scene, project: project, playhead: playhead, geometry: geometry);
      void frame(int k) {
        playhead.value = k * 33333;
        final rec = ui.PictureRecorder();
        painter.paint(ui.Canvas(rec), const Size(390, 219.375));
        rec.endRecording().dispose();
      }

      for (var k = 0; k < 30; k++) {
        frame(k); // warm-up: layouts are built once per item, then memoized
      }
      const frames = 300;
      final sw = Stopwatch()..start();
      for (var k = 0; k < frames; k++) {
        frame(k % 100);
      }
      sw.stop();
      final perFrameMs = sw.elapsedMicroseconds / frames / 1000;
      expect(scene.entriesAt(project, 0), hasLength(10));
      expect(perFrameMs, lessThanOrEqualTo(1.0), reason: 'per frame: ${perFrameMs.toStringAsFixed(3)} ms');
      debugPrint('text overlay: ${perFrameMs.toStringAsFixed(3)} ms per frame for 10 items');
    });
  });

  group('in the editor', () {
    setUp(() => EditorRebuildCounters.reset());

    testWidgets('playback repaints the overlay per frame and never rebuilds the scaffold', (tester) async {
      final rig = await PreviewRig.pump(
        tester,
        home: (id) => EditorScaffold(inspectorOpen: false, topBar: (context, transport) => const SizedBox.expand()),
      );
      expect(find.byType(TextOverlayLayer), findsOneWidget);
      await rig.real(() => rig.transport.play());
      final counts = await EditorRebuildCounters.record(() => rig.playFrames(30));
      expect(counts['EditorScaffold'], isNull, reason: '$counts');
      expect(counts['PreviewRegion'], isNull, reason: '$counts');
      expect(counts[TextOverlayPainter.paintCounter], inInclusiveRange(25, 31), reason: '$counts');
    });

    testWidgets('edits repaint the overlay from the working project', (tester) async {
      final rig = await PreviewRig.pump(tester);
      final counts = await EditorRebuildCounters.record(() async {
        rig.editor.apply(SetText(PreviewIds.text, 'Changed'));
        await tester.pump();
      });
      expect(counts[TextOverlayPainter.paintCounter], 1, reason: '$counts');
    });

    testWidgets('the fullscreen preview hosts the same overlay', (tester) async {
      final rig = await PreviewRig.pump(tester);
      rig.transport.setFullscreen(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.descendant(of: find.byType(FullscreenPreview), matching: find.byType(TextOverlayLayer)), findsOneWidget);
    });
  });
}
