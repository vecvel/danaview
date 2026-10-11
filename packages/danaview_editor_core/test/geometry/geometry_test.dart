// OWNER: CORE-07
//
// Placement math (ARCH §11.6 "Place"): the matrix M with flips and 90° rotations, baseSize for
// every fit mode with crops, canvas ↔ normalized conversions, boxAt (keyframe-aware, exact at
// keys), inverse mapping and hit tests.

import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';

const FrameRate rate = FrameRate.fps30;
TimeUs f(int k) => rate.timeOfFrame(k);

Matcher near(Offset2 p, [double eps = 1e-9]) => predicate<Offset2>(
      (o) => (o.dx - p.dx).abs() <= eps && (o.dy - p.dy).abs() <= eps,
      'near $p',
    );

final DateTime when = DateTime.utc(2026, 10, 9);

MediaAsset video(String id, int w, int h) => MediaAsset(
      id: MediaId(id),
      kind: MediaKind.video,
      displayName: id,
      locator: AppRelativeLocator(AppRoot.documents, id),
      ownership: MediaOwnership.managedCopy,
      fingerprint: const MediaFingerprint(sizeBytes: 1, quickHash: 'q'),
      probe: MediaProbe(kind: MediaKind.video, duration: 60 * microsPerSecond, hasVideo: true, width: w, height: h),
      origin: MediaOrigin.files,
      addedAt: when,
    );

/// Measures text as 20 px per grapheme by one line height (deterministic stand-in for API-04).
final class FakeMetrics implements TextMetricsProvider {
  @override
  Size2 measure(TextLayoutSpec spec) => Size2(spec.graphemeCount * 20.0, spec.fontSizePx * spec.lineHeight);
}

void main() {
  group('Affine2', () {
    test('rotation is clockwise on a y-down canvas and exact at multiples of 90°', () {
      expect(Affine2.rotationDeg(90).apply(const Offset2(1, 0)), const Offset2(0, 1));
      expect(Affine2.rotationDeg(180).apply(const Offset2(1, 0)), const Offset2(-1, 0));
      expect(Affine2.rotationDeg(270).apply(const Offset2(1, 0)), const Offset2(0, -1));
      expect(Affine2.rotationDeg(-90).apply(const Offset2(1, 0)), const Offset2(0, -1));
      expect(Affine2.rotationDeg(360), Affine2.identity);
      expect(Affine2.rotationDeg(-360), Affine2.identity);
      expect(Affine2.rotationDeg(45).apply(const Offset2(1, 0)), near(Offset2(math.sqrt1_2, math.sqrt1_2)));
    });

    test('composition applies the right operand first and inverse undoes it', () {
      final m = const Affine2.translation(10, 20) * Affine2.rotationDeg(30) * const Affine2.scaling(2, -3);
      final p = const Offset2(4, -7);
      final expected = const Affine2.translation(10, 20).apply(Affine2.rotationDeg(30).apply(const Affine2.scaling(2, -3).apply(p)));
      expect(m.apply(p), near(expected));
      expect(m.inverse()!.apply(m.apply(p)), near(p));
      expect((m * m.inverse()!).closeTo(Affine2.identity), isTrue);
      expect(const Affine2.scaling(0, 1).inverse(), isNull);
    });
  });

  group('placementMatrix equals T(c)·R(r)·S(s·fx, s·fy)·T(−base/2)', () {
    const base = Size2(400, 300);
    const center = Offset2(960, 540);
    for (final rot in [0.0, 90.0, 180.0, 270.0, -90.0, 33.0]) {
      for (final fx in [false, true]) {
        for (final fy in [false, true]) {
          test('r = $rot fx = $fx fy = $fy', () {
            const s = 1.5;
            final m = placementMatrix(center: center, base: base, scale: s, rotationDeg: rot, flipH: fx, flipV: fy);
            final reference = Affine2.translation(center.dx, center.dy) *
                Affine2.rotationDeg(rot) *
                Affine2.scaling(s * (fx ? -1 : 1), s * (fy ? -1 : 1)) *
                Affine2.translation(-base.width / 2, -base.height / 2);
            expect(m.closeTo(reference, 1e-9), isTrue, reason: '$m vs $reference');
            // The base centre always lands on the centre.
            expect(m.apply(const Offset2(200, 150)), near(center));
          });
        }
      }
    }

    test('flips mirror the corners about the centre', () {
      final plain = placementMatrix(center: const Offset2(100, 100), base: const Size2(40, 20));
      final h = placementMatrix(center: const Offset2(100, 100), base: const Size2(40, 20), flipH: true);
      final v = placementMatrix(center: const Offset2(100, 100), base: const Size2(40, 20), flipV: true);
      expect(plain.apply(Offset2.zero), const Offset2(80, 90));
      expect(h.apply(Offset2.zero), const Offset2(120, 90));
      expect(v.apply(Offset2.zero), const Offset2(80, 110));
    });

    test('90° rotation maps the base top-left to the top-right of the rotated box', () {
      final m = placementMatrix(center: const Offset2(100, 100), base: const Size2(40, 20), rotationDeg: 90);
      // Top-left (−20, −10) from the centre rotates clockwise to (10, −20).
      expect(m.apply(Offset2.zero), const Offset2(110, 80));
      expect(m.apply(const Offset2(40, 20)), const Offset2(90, 120));
    });

    test('plan transform defaults put the layer at the canvas centre', () {
      const canvas = Size2(1920, 1080);
      final m = planPlacementMatrix(PlanTransform.identity, const PlanSize(1920, 1080), canvas);
      expect(m, Affine2.identity);
      final moved = planPlacementMatrix(const PlanTransform(cx: 100, cy: 50, s: 2, r: 90, fx: true), const PlanSize(10, 10), canvas);
      expect(moved, placementMatrix(center: const Offset2(100, 50), base: const Size2(10, 10), scale: 2, rotationDeg: 90, flipH: true));
    });
  });

  group('baseSize', () {
    const canvas = Size2(1920, 1080);

    test('fit letterboxes, fill covers, stretch takes the canvas', () {
      const portrait = Size2(1080, 1920);
      expect(baseSize(fit: FitMode.fit, source: portrait, canvas: canvas), const Size2(607.5, 1080));
      final fill = baseSize(fit: FitMode.fill, source: portrait, canvas: canvas);
      expect(fill.width, 1920);
      expect(fill.height, closeTo(1920 * 1920 / 1080, 1e-9));
      expect(baseSize(fit: FitMode.stretch, source: portrait, canvas: canvas), canvas);
      expect(baseSize(fit: FitMode.fit, source: const Size2(3840, 2160), canvas: canvas), canvas);
      expect(baseSize(fit: FitMode.fill, source: const Size2(1280, 720), canvas: canvas), canvas);
    });

    test('crop is applied before the fit', () {
      // Left half of a 16:9 source is 8:9: fit → full height.
      const half = CropRect(right: 0.5);
      expect(baseSize(fit: FitMode.fit, crop: half, source: const Size2(1920, 1080), canvas: canvas), const Size2(960, 1080));
      expect(baseSize(fit: FitMode.fill, crop: half, source: const Size2(1920, 1080), canvas: canvas), const Size2(1920, 2160));
      expect(baseSize(fit: FitMode.stretch, crop: half, source: const Size2(1920, 1080), canvas: canvas), canvas);
      // A centred square crop of a portrait source on a portrait canvas.
      const sq = CropRect(top: 0.25, bottom: 0.25 + 1080 / 1920);
      final b = baseSize(fit: FitMode.fit, crop: sq, source: const Size2(1080, 1920), canvas: const Size2(1080, 1920));
      expect(b.width, 1080);
      expect(b.height, closeTo(1080, 1e-9));
    });

    test('the fitted side equals the canvas side exactly', () {
      for (final (w, h) in [(1920, 1080), (1080, 1920), (1000, 999), (3, 7)]) {
        for (final fit in [FitMode.fit, FitMode.fill]) {
          final b = baseSize(fit: fit, source: Size2(w.toDouble(), h.toDouble()), canvas: const Size2(1080, 1350));
          expect(b.width == 1080 || b.height == 1350, isTrue);
        }
      }
    });

    test('rejects empty sources, crops and canvases', () {
      expect(() => baseSize(fit: FitMode.fit, source: Size2.zero, canvas: canvas), throwsArgumentError);
      expect(() => baseSize(fit: FitMode.fit, crop: const CropRect(left: 0.5, right: 0.5), source: canvas, canvas: canvas),
          throwsArgumentError);
      expect(() => baseSize(fit: FitMode.fit, source: canvas, canvas: Size2.zero), throwsArgumentError);
    });
  });

  group('canvas conversions', () {
    const canvas = Size2(1080, 1920);

    test('positions are canvas fractions with 0 at the centre', () {
      expect(positionToCanvas(Vec2.zero, canvas), const Offset2(540, 960));
      expect(positionToCanvas(const Vec2(-0.5, 0.5), canvas), const Offset2(0, 1920));
      expect(canvasToPosition(const Offset2(810, 480), canvas), const Vec2(0.25, -0.25));
      for (final v in [const Vec2(0.1, -0.7), const Vec2(-2, 2), const Vec2(1.3, 0.01)]) {
        final back = canvasToPosition(positionToCanvas(v, canvas), canvas);
        expect(back.x, closeTo(v.x, 1e-12));
        expect(back.y, closeTo(v.y, 1e-12));
      }
    });

    test('text points are px at a 1,080 px short side', () {
      expect(pointsToPx(48, canvas), 48);
      expect(pointsToPx(48, const Size2(3840, 2160)), 96);
      expect(pointsToPx(48, const Size2(1280, 720)), closeTo(32, 1e-12));
      expect(pxToPoints(32, const Size2(1280, 720)), closeTo(48, 1e-12));
      expect(const CanvasSpec(aspect: AspectRatio.portrait9x16, baseShortSide: 720).sizePx, const Size2(720, 1280));
      expect(const CanvasSpec(baseShortSide: 2160).pxPerPoint, 2);
    });
  });

  group('boxAt', () {
    const canvasSpec = CanvasSpec(); // 1920×1080
    final pool = MediaPool({const MediaId('md_v'): video('md_v', 1080, 1920)});

    MediaClip clip({VisualProps visual = VisualProps.neutral, KeyframeSet keyframes = KeyframeSet.empty}) => MediaClip(
          id: const ItemId('it_c'),
          start: f(30),
          duration: f(120) - f(30),
          media: const MediaId('md_v'),
          visual: visual,
          keyframes: keyframes,
        );

    EditProject project(List<TimelineItem> overlay, {List<TimelineItem> text = const [], List<TimelineItem> cues = const []}) =>
        EditProject(
          id: const ProjectId('pr_geo'),
          meta: ProjectMeta(name: 'g', createdAt: when, updatedAt: when),
          timeline: Timeline(settings: const ProjectSettings(canvas: canvasSpec), tracks: [
            Track(id: const TrackId('tr_main'), kind: TrackKind.video, isMain: true, items: [
              MediaClip(id: const ItemId('it_bg'), start: 0, duration: f(300), media: const MediaId('md_v'), visual: const VisualProps(fit: FitMode.fill)),
            ]),
            Track(id: const TrackId('tr_ov'), kind: TrackKind.overlay, items: overlay),
            Track(id: const TrackId('tr_tx'), kind: TrackKind.text, items: text),
            Track(id: const TrackId('tr_sub'), kind: TrackKind.subtitle, subtitle: const SubtitleTrackData(), items: cues),
          ]),
          pool: pool,
        );

    test('a static clip: base from fit + crop, placed by the transform', () {
      final c = clip(
        visual: const VisualProps(
          crop: CropRect(bottom: 0.5),
          transform: Transform2D(position: Vec2(0.25, -0.25), scale: 0.5, rotationDeg: 90, flipH: true, opacity: 0.8),
        ),
      );
      final box = boxAt(project([c]), c.id, f(40))!;
      // Crop keeps the top half of 1080×1920 → 1080×960 → fit into 1920×1080 → 1215×1080.
      expect(box.base, const Size2(1215, 1080));
      expect(box.center, const Offset2(1440, 270));
      expect(box.scale, 0.5);
      expect(box.rotationDeg, 90);
      expect(box.flipH, isTrue);
      expect(box.opacity, 0.8);
      expect(box.size, const Size2(607.5, 540));
      // Rotated 90°: the bounds swap width and height.
      final b = box.bounds;
      expect(b.width, closeTo(540, 1e-9));
      expect(b.height, closeTo(607.5, 1e-9));
    });

    test('keyframed transforms are exact at keys and linear between them', () {
      final keys = KeyframeSet({
        'transform.position.x': KeyframeTrack([Keyframe(f(30) - f(30), -0.5), Keyframe(f(60) - f(30), 0.5)]),
        'transform.position.y': KeyframeTrack([Keyframe(0, 0), Keyframe(f(60) - f(30), 0.25)]),
        'transform.scale': KeyframeTrack([Keyframe(0, 1), Keyframe(f(90) - f(30), 2)]),
        'transform.rotation': KeyframeTrack([Keyframe(0, 0), Keyframe(f(60) - f(30), 360)]),
        'transform.opacity': KeyframeTrack([Keyframe(f(45) - f(30), 0.25)]),
      });
      final c = clip(keyframes: keys);
      final p = project([c]);
      final atStart = boxAt(p, c.id, f(30))!;
      expect(atStart.center, const Offset2(0, 540));
      expect(atStart.scale, 1);
      expect(atStart.rotationDeg, 0);
      expect(atStart.opacity, 0.25);
      final atKey = boxAt(p, c.id, f(60))!;
      expect(atKey.center, const Offset2(1920, 810));
      expect(atKey.rotationDeg, 360);
      expect(boxAt(p, c.id, f(90))!.scale, 2);
      // Held after the last key, interpolated between.
      expect(boxAt(p, c.id, f(100))!.scale, 2);
      expect(boxAt(p, c.id, f(45))!.center.dx, closeTo(960, 1e-6));
      expect(boxAt(p, c.id, f(45))!.center.dy, closeTo(540 + 0.125 * 1080, 1e-6));
    });

    test('inverse mapping and hit tests follow the oriented box', () {
      final c = clip(visual: const VisualProps(transform: Transform2D(scale: 0.25, rotationDeg: 45)));
      final p = project([c]);
      final box = boxAt(p, c.id, f(40))!;
      expect(box.toLocal(box.center), near(Offset2(box.base.width / 2, box.base.height / 2), 1e-6));
      expect(box.toLocalNormalized(box.corners[2]), near(const Offset2(1, 1), 1e-9));
      expect(box.fromLocalNormalized(const Offset2(0.5, 0.5)), near(box.center, 1e-9));
      for (final corner in box.corners) {
        expect(box.contains(corner), isTrue);
      }
      // Just outside the rotated edge midpoint, inside with slop.
      final mid = (box.corners[0] + box.corners[1]) * 0.5;
      final outward = (mid - box.center) * (1 / (mid - box.center).distance);
      final outside = mid + outward * 3;
      expect(box.contains(outside), isFalse);
      expect(box.contains(outside, slop: 4), isTrue);
      // The overlay is on top of the main lane; outside it the main lane is hit.
      expect(hitTest(p, box.center, f(40)), c.id);
      expect(hitTestAll(p, box.center, f(40)), [c.id, const ItemId('it_bg')]);
      expect(hitTest(p, const Offset2(5, 5), f(40)), const ItemId('it_bg'));
      // Not active before its start.
      expect(hitTest(p, box.center, f(10)), const ItemId('it_bg'));
    });

    test('a pending freeze still without its own size uses its source picture size', () {
      final still = MediaAsset(
        id: const MediaId('md_still'),
        kind: MediaKind.still,
        displayName: 'still',
        locator: const AppRelativeLocator(AppRoot.documents, 'still'),
        ownership: MediaOwnership.projectOwned,
        fingerprint: const MediaFingerprint(sizeBytes: 0, quickHash: ''),
        probe: MediaProbe(kind: MediaKind.still),
        origin: MediaOrigin.derived,
        derived: const StillSpec(MediaId('md_v'), 0, sourceQuickHash: 'q'),
        status: const PendingStatus('job'),
        addedAt: when,
      );
      final c = clip().copyWith(media: const MediaId('md_still'));
      final box = itemBoxAt(c, f(40), settings: const ProjectSettings(), pool: pool.upsert(still))!;
      expect(box.base, const Size2(607.5, 1080));
    });

    test('audio clips, missing media and unknown ids have no box', () {
      final audio = MediaClip(id: const ItemId('it_a'), start: 0, duration: f(10), media: const MediaId('md_v'));
      expect(itemBoxAt(audio, 0, settings: const ProjectSettings(), pool: pool), isNull);
      final missing = clip().copyWith(media: const MediaId('md_none'));
      expect(itemBoxAt(missing, f(40), settings: const ProjectSettings(), pool: pool), isNull);
      expect(boxAt(project([]), const ItemId('it_nope'), 0), isNull);
    });

    test('text boxes use the metrics provider, the transform and the text animation', () {
      final t = TextItem(
        id: const ItemId('it_t'),
        start: f(30),
        duration: f(90) - f(30),
        text: 'Hello',
        transform: const Transform2D(position: Vec2(0, 0.25), scale: 2, rotationDeg: 10, flipH: true),
        animation: TextAnimation(inKind: TextAnimKind.scale, inDuration: f(36) - f(30)),
      );
      final p = project([], text: [t]);
      expect(boxAt(p, t.id, f(40)), isNull, reason: 'needs metrics');
      final metrics = FakeMetrics();
      final settled = boxAt(p, t.id, f(50), text: metrics)!;
      expect(settled.base, const Size2(100, 48 * 1.2));
      expect(settled.center, const Offset2(960, 810));
      expect(settled.scale, 2);
      expect(settled.rotationDeg, 10);
      expect(settled.flipH, isFalse, reason: 'text ignores flips');
      final first = boxAt(p, t.id, f(30), text: metrics)!;
      expect(first.scale, closeTo(2 * 0.6, 1e-12));
      expect(first.opacity, 0);
    });

    test('cue boxes sit inside the safe margin', () {
      final cue = SubtitleCue(id: const ItemId('it_cue'), start: 0, duration: f(30), text: '<i>Hi</i> there');
      final p = project([], cues: [cue]);
      final box = boxAt(p, cue.id, 0, text: FakeMetrics())!;
      expect(box.base.width, 8 * 20.0);
      final bottom = box.center.dy + box.base.height / 2;
      expect(bottom, closeTo(1080 * (1 - subtitleSafeMargin), 1e-9));
      expect(cueCenter(const Size2(10, 100), SubtitlePosition.top, const Size2(1920, 1080)).dy, closeTo(1080 * 0.06 + 50, 1e-9));
      expect(cueCenter(const Size2(10, 100), const CustomSubtitlePosition(0.5), const Size2(1920, 1080)), const Offset2(960, 540));
      expect(hitTest(p, box.center, 0, text: FakeMetrics()), cue.id);
    });

    test('hidden lanes are not hit', () {
      final c = clip();
      final p = project([c]);
      final hidden = p.copyWith(
        timeline: p.timeline.copyWith(tracks: [for (final t in p.tracks) t.id == const TrackId('tr_ov') ? t.copyWith(hidden: true) : t]),
      );
      final center = boxAt(p, c.id, f(40))!.center;
      expect(hitTest(hidden, center, f(40)), const ItemId('it_bg'));
    });
  });
}
