// OWNER: API-03
//
// Joint test (BUILD_PLAN API-03): danaview_editor_core's FrameRate, evaluateAnimKeys, evaluate,
// baseSize/boxAt/planPlacementMatrix and evaluateTextAnimation pass the same shared vectors the
// Swift and Kotlin suites read (keyframes.json, transform.json, typewriter.json,
// text_scale_8x.json), and so does this package's render math.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

import 'support/fixtures.dart';

final DateTime _when = DateTime.utc(2026, 10, 10);

MediaAsset _video(String id, double w, double h) => MediaAsset(
      id: MediaId(id),
      kind: MediaKind.video,
      displayName: id,
      locator: AppRelativeLocator(AppRoot.documents, id),
      ownership: MediaOwnership.managedCopy,
      fingerprint: const MediaFingerprint(sizeBytes: 1, quickHash: 'q'),
      probe: MediaProbe(kind: MediaKind.video, duration: 600 * microsPerSecond, hasVideo: true, width: w.round(), height: h.round()),
      origin: MediaOrigin.files,
      addedAt: _when,
    );

EditProject _project(CanvasSpec canvas, MediaClip clip, MediaAsset asset) => EditProject(
      id: const ProjectId('pr_api03'),
      meta: ProjectMeta(name: 'api03', createdAt: _when, updatedAt: _when),
      timeline: Timeline(settings: ProjectSettings(canvas: canvas), tracks: [
        Track(id: const TrackId('tr_main'), kind: TrackKind.video, isMain: true, items: [clip]),
      ]),
      pool: MediaPool({asset.id: asset}),
    );

void main() {
  group('keyframes.json', () {
    final doc = vectorFile('keyframes.json');
    for (final raw in list(doc['cases'])) {
      final c = obj(raw);
      test('${c['name']}', () {
        final fps = c['fps']! as int;
        final rate = FrameRate.project(fps);
        final start = c['itemStartUs']! as int;
        final duration = c['itemDurationUs']! as int;
        final keys = [
          for (final k in list(c['keys'])) AnimKey((list(k)[0]! as num).toInt(), asDouble(list(k)[1])),
        ];
        final property = PropertyKeys.lookup(c['property']! as String)!;
        final clip = MediaClip(
          id: const ItemId('it_kf'),
          start: start,
          duration: duration,
          media: const MediaId('md_v'),
          visual: VisualProps.neutral,
          keyframes: KeyframeSet({
            property.id: KeyframeTrack([for (final k in keys) Keyframe(k.tUs - start, k.v)]),
          }),
        );
        expect(PlanChannels.all, contains(c['channel']));
        for (final raw in list(c['samples'])) {
          final s = obj(raw);
          final k = s['k']! as int;
          final tau = s['tau']! as int;
          final t = s['t']! as int;
          final v = asDouble(s['v']);
          // D-35: the platform time maps to its frame; evaluation uses the plan time of that frame.
          expect(rate.frameIndexNearest(tau), k, reason: 'tau $tau');
          expect(rate.timeOfFrame(k), t);
          expect(LayerParamSnapshot.frameTime(PlanCanvas(w: 16, h: 16, fps: fps), tau), t);
          // Plan channel (absolute µs).
          expect(evaluateAnimKeys(keys, t), closeTo(v, 1e-9), reason: 'plan channel at k $k');
          // Domain keyframes (item-local µs), core evaluate.
          expect(evaluate(clip, property, t - start)! as double, closeTo(v, 1e-9), reason: 'domain evaluate at k $k');
        }
      });
    }
  });

  group('transform.json', () {
    final doc = vectorFile('transform.json');
    for (final raw in list(doc['cases'])) {
      final c = obj(raw);
      test('${c['name']}', () {
        final d = obj(c['domain']);
        final aspect = list(d['aspect']);
        final spec = CanvasSpec(aspect: AspectRatio(aspect[0]! as int, aspect[1]! as int), baseShortSide: d['baseShortSide']! as int);
        expect([spec.widthPx, spec.heightPx], c['canvas']);
        final source = doubles(d['source']);
        final crop = doubles(d['crop']);
        final position = doubles(d['position']);
        final asset = _video('md_v', source[0], source[1]);
        final clip = MediaClip(
          id: const ItemId('it_x'),
          start: 0,
          duration: microsPerSecond,
          media: asset.id,
          visual: VisualProps(
            fit: FitMode.values.byName(d['fit']! as String),
            crop: CropRect(left: crop[0], top: crop[1], right: crop[2], bottom: crop[3]),
            transform: Transform2D(
              position: Vec2(position[0], position[1]),
              scale: asDouble(d['scale']),
              rotationDeg: asDouble(d['rotation']),
              flipH: d['flipH']! as bool,
              flipV: d['flipV']! as bool,
            ),
          ),
        );
        final m = doubles(c['M']);
        final expected = Affine2(m[0], m[1], m[2], m[3], m[4], m[5]);
        final base = doubles(c['base']);

        // Core boxAt (CORE-07) derives base and M from the domain.
        final box = boxAt(_project(spec, clip, asset), clip.id, 0)!;
        expect(box.base.width, closeTo(base[0], 1e-6));
        expect(box.base.height, closeTo(base[1], 1e-6));
        expect(box.matrix.closeTo(expected, 1e-6), isTrue, reason: '${box.matrix} vs $expected');

        // The plan form: core planPlacementMatrix and RenderMath.placement.
        final xf = obj(c['xf']);
        final planXf = PlanTransform(
          cx: asDouble(xf['cx']),
          cy: asDouble(xf['cy']),
          s: asDouble(xf['s']),
          r: asDouble(xf['r']),
          fx: xf['fx']! as bool,
          fy: xf['fy']! as bool,
        );
        final canvas = PlanCanvas(w: spec.widthPx, h: spec.heightPx, fps: 30);
        final pm = RenderMath.placement(planXf, PlanSize(base[0], base[1]), canvas);
        expect(pm.closeTo(expected, 1e-6), isTrue);
        expect(planPlacementMatrix(planXf, PlanSize(base[0], base[1]), spec.sizePx).closeTo(expected, 1e-6), isTrue);
        for (final rawP in list(c['points'])) {
          final p = obj(rawP);
          final local = doubles(p['local']);
          final canvasPt = doubles(p['canvas']);
          final q = pm.apply(Offset2(local[0], local[1]));
          expect(q.dx, closeTo(canvasPt[0], 1e-6));
          expect(q.dy, closeTo(canvasPt[1], 1e-6));
        }
      });
    }
  });

  group('typewriter.json', () {
    final doc = vectorFile('typewriter.json');
    for (final raw in list(doc['cases'])) {
      final c = obj(raw);
      test('${c['name']}', () {
        final text = c['text']! as String;
        expect(textGraphemeCount(text), c['graphemes']);
        final start = c['itemStartUs']! as int;
        final item = TextItem(
          id: const ItemId('it_tw'),
          start: start,
          duration: c['itemDurationUs']! as int,
          text: text,
          animation: TextAnimation(inKind: TextAnimKind.typewriter, inDuration: c['inDurationUs']! as int),
        );
        final channel = [
          for (final k in list(c['channel'])) AnimKey((list(k)[0]! as num).toInt(), asDouble(list(k)[1])),
        ];
        // The compiler's reveal channel spans the in-phase exactly.
        expect(textAnimationBreakpoints(item).take(2), [channel.first.tUs, channel.last.tUs]);
        final rate = FrameRate.project(c['fps']! as int);
        for (final rawF in list(c['frames'])) {
          final f = obj(rawF);
          final t = rate.timeOfFrame(f['k']! as int);
          expect(t, f['t']);
          final reveal = evaluateAnimKeys(channel, t);
          expect(reveal, closeTo(asDouble(f['reveal']), 1e-9));
          expect(RenderMath.revealCount(reveal), f['shown']);
          final state = evaluateTextAnimation(item, t, const CanvasSpec());
          expect(state.revealCount, f['shown'], reason: 'core evaluateTextAnimation at k ${f['k']}');
          expect(state.reveal, closeTo(reveal, 1e-9));
        }
      });
    }
  });

  test('text_scale_8x.json matches its golden plan', () {
    final doc = vectorFile('text_scale_8x.json');
    final planPath = '${packageRoot().path}/test_fixtures/vectors/${doc['plan']}';
    final plan = PlanJson.decodePlanBytes(Uint8List.fromList(utf8.encode(File(planPath).readAsStringSync().trimRight())));
    final layer = plan.layers.firstWhere((l) => l.id == doc['layer']);
    final sprite = obj(doc['sprite']);
    final asset = plan.assets[layer.asset]!;
    expect([asset.sw, asset.sh, asset.sscale], [sprite['sw'], sprite['sh'], sprite['sscale']]);
    expect(asset.sscale, 8);
    var reachedEight = false;
    for (final raw in list(doc['frames'])) {
      final f = obj(raw);
      final t = plan.canvas.frameRate.timeOfFrame(f['k']! as int);
      expect(t, f['t']);
      final p = LayerParamSnapshot.at(layer, plan.canvas, t);
      expect(p.xf.s, closeTo(asDouble(f['xf.s']), 1e-9));
      reachedEight |= p.xf.s == 8;
      final m = doubles(f['M']);
      expect(RenderMath.placement(p.xf, layer.base!, plan.canvas).closeTo(Affine2(m[0], m[1], m[2], m[3], m[4], m[5]), 1e-6), isTrue);
      expect(File('${packageRoot().path}/test_fixtures/vectors/${f['png']}').existsSync(), isTrue);
    }
    expect(reachedEight, isTrue, reason: 'the case must include the 8× key');
  });
}
