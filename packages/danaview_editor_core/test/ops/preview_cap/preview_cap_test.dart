// OWNER: CORE-38
//
// Edits above the live-preview layer caps (ARCH D-14, D-45(B), §7.1, §13.5; owner decision
// 2026-10-11, D-43(e) point 7): `maxVisualSequences` and `maxConcurrentVideoLayers` limit live
// preview only. A command is never refused for either cap; `LayerLimits` reports the
// informational `PreviewCapStatus` instead. Items (5,000) and duration (24 h) stay hard limits.

import 'dart:math';

import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';

import '../../session/session_support.dart';
import '../../support/random_project.dart';
import '../framework/framework_test.dart' show randomCommand;
import '../framework/ops_support.dart';

/// Main video [0,600) and [lanes] overlay lanes, each with one short video at [100·i, 100·i+50).
EditProject sparsePip({int lanes = 6}) => project([
      lane('tr_main', TrackKind.video, [vclip('it_main', 0, 600)], main: true),
      for (var i = 0; i < lanes; i++) lane('tr_ov$i', TrackKind.overlay, [vclip('it_p$i', 100 * i, 50, media: 'md_video2')]),
    ]);

EditProject withLane(EditProject x, Track t) => x.copyWith(
      timeline: Timeline(
        settings: x.settings,
        tracks: [...x.tracks]..insert(TrackOrder.insertIndexFor(x.tracks, t.kind), t),
        markers: x.markers,
        revision: x.revision,
      ),
    );

final EditCommand seventhLane =
    RawEditCommand('Add seventh lane', (x) => withLane(x, lane('tr_ov6', TrackKind.overlay, [vclip('it_p6', 20, 50, media: 'md_video2')])));

EditProject twoVideos() => project([
      lane('tr_main', TrackKind.video, [vclip('it_main', 0, 600)], main: true),
      lane('tr_ov0', TrackKind.overlay, [vclip('it_v0', 0, 90, media: 'md_video2')]),
      lane('tr_txt', TrackKind.text, [text('it_t1', 0, 45)]),
    ]);

final EditCommand overlappingVideo = InsertMedia([const MediaId('md_short')], f(30), track: const TrackId('tr_ov0'), mode: InsertMode.newLane);

const EditPolicy seqPolicy = EditPolicy(maxVisualSequences: 2);
const EditPolicy decPolicy = EditPolicy(maxConcurrentVideoLayers: 2);

void main() {
  group('PreviewCapStatus', () {
    test('aboveLivePreviewCap is true when either count is over its cap', () {
      const within = PreviewCapStatus(visualSequences: 2, maxVisualSequences: 2, peakConcurrentVideoLayers: 2, maxConcurrentVideoLayers: 2);
      expect(within.aboveLivePreviewCap, isFalse);
      const seq = PreviewCapStatus(visualSequences: 3, maxVisualSequences: 2, peakConcurrentVideoLayers: 1, maxConcurrentVideoLayers: 2);
      expect((seq.aboveLivePreviewCap, seq.aboveSequenceCap, seq.aboveConcurrentLayerCap), (true, true, false));
      const dec = PreviewCapStatus(visualSequences: 1, maxVisualSequences: 2, peakConcurrentVideoLayers: 3, maxConcurrentVideoLayers: 2);
      expect((dec.aboveLivePreviewCap, dec.aboveSequenceCap, dec.aboveConcurrentLayerCap), (true, false, true));
      expect(seq, const PreviewCapStatus(visualSequences: 3, maxVisualSequences: 2, peakConcurrentVideoLayers: 1, maxConcurrentVideoLayers: 2));
      expect(seq.hashCode, const PreviewCapStatus(visualSequences: 3, maxVisualSequences: 2, peakConcurrentVideoLayers: 1, maxConcurrentVideoLayers: 2).hashCode);
      expect(seq, isNot(dec));
    });

    test('LimitCounts.previewCap carries the counts and the caps; exceeded lists only hard limits', () {
      const counts = LimitCounts(items: 10, duration: 1000, peakConcurrentVideoLayers: 9, visualSequences: 9);
      const policy = EditPolicy(maxConcurrentVideoLayers: 2, maxVisualSequences: 3);
      expect(
        counts.previewCap(policy),
        const PreviewCapStatus(visualSequences: 9, maxVisualSequences: 3, peakConcurrentVideoLayers: 9, maxConcurrentVideoLayers: 2),
      );
      expect(counts.exceeded(policy), isEmpty);
      const hard = LimitCounts(items: 11, duration: maxProjectDurationUs + 1, peakConcurrentVideoLayers: 9, visualSequences: 9);
      expect(hard.exceeded(const EditPolicy(maxItems: 10, maxConcurrentVideoLayers: 2, maxVisualSequences: 3)), [
        const LimitExceeded(LimitExceeded.items, 10),
        const LimitExceeded(LimitExceeded.duration, maxProjectDurationUs),
      ]);
    });

    test('core no longer produces the layer-cap rejections, but the constants stay declared', () {
      expect(LimitExceeded.visualSequences, isA<String>());
      expect(LimitExceeded.concurrentVideoLayers, isA<String>());
      final before = sparsePip();
      final after = applyCommand(before, seventhLane, ctx()).project;
      const tight = EditPolicy(maxVisualSequences: 1, maxConcurrentVideoLayers: 1);
      expect(LayerLimits().check(before, after, tight), isNull);
      expect(LayerLimits().check(after, before, tight), isNull);
    });
  });

  group('sequence cap (maxVisualSequences)', () {
    test('a seventh overlapping PiP lane succeeds and reports the counts', () {
      final p = sparsePip();
      final context = ctx(policy: seqPolicy);
      final out = applyCommand(p, seventhLane, context);
      expect(out.changed, isTrue, reason: '${out.rejection}');
      expect(out.rejection, isNull);
      expect(
        context.limits.lastPreviewCap,
        const PreviewCapStatus(visualSequences: 3, maxVisualSequences: 2, peakConcurrentVideoLayers: 3, maxConcurrentVideoLayers: 4),
      );
      expect(context.limits.lastPreviewCap!.aboveLivePreviewCap, isTrue);
    });

    test('a reducing edit clears the flag', () {
      final context = ctx(policy: seqPolicy);
      final over = applyCommand(sparsePip(), seventhLane, context).project;
      expect(context.limits.lastPreviewCap!.aboveLivePreviewCap, isTrue);
      final reduced = applyCommand(over, DeleteItems({const ItemId('it_p6')}), context);
      expect(reduced.changed, isTrue, reason: '${reduced.rejection}');
      expect(context.limits.lastPreviewCap!.aboveLivePreviewCap, isFalse);
      expect(context.limits.lastPreviewCap!.visualSequences, 2);
    });
  });

  group('concurrent decoder cap (maxConcurrentVideoLayers)', () {
    test('a peak-concurrent-decoder overflow succeeds and reports the counts', () {
      final context = ctx(policy: decPolicy);
      final out = applyCommand(twoVideos(), overlappingVideo, context);
      expect(out.changed, isTrue, reason: '${out.rejection}');
      final status = context.limits.lastPreviewCap!;
      expect(status.aboveLivePreviewCap, isTrue);
      expect(status.aboveConcurrentLayerCap, isTrue);
      expect((status.peakConcurrentVideoLayers, status.maxConcurrentVideoLayers), (3, 2));
    });

    test('a reducing edit clears the flag', () {
      final context = ctx(policy: decPolicy);
      final over = applyCommand(twoVideos(), overlappingVideo, context).project;
      expect(context.limits.lastPreviewCap!.aboveLivePreviewCap, isTrue);
      final reduced = applyCommand(over, DeleteItems({const ItemId('it_v0')}), ctx(seed: 8, policy: decPolicy));
      expect(reduced.changed, isTrue, reason: '${reduced.rejection}');
      expect(LayerLimits().previewCapOf(reduced.project, decPolicy).aboveLivePreviewCap, isFalse);
    });

    test('a text-only edit keeps the flag without re-packing', () {
      final context = ctx(policy: decPolicy);
      final over = applyCommand(twoVideos(), overlappingVideo, context).project;
      final packs = context.limits.packCount;
      final moved = applyCommand(over, MoveItems({const ItemId('it_t1')}, f(5)), context);
      expect(moved.changed, isTrue);
      expect(context.limits.lastPreviewCap!.aboveLivePreviewCap, isTrue);
      expect(context.limits.packCount, packs, reason: 'a text-only edit must not pack');
    });
  });

  group('dryRun and applyCommand agree', () {
    test('on the fixtures', () {
      for (final (base, command, policy) in [
        (sparsePip(), seventhLane, seqPolicy),
        (twoVideos(), overlappingVideo, decPolicy),
        (sparsePip(), MoveItems({const ItemId('it_p5')}, f(20)), seqPolicy),
      ]) {
        final a = ctx(policy: policy);
        final d = ctx(policy: policy);
        final applied = applyCommand(base, command, a);
        final probe = dryRun(base, command, d);
        expect(probe.rejection, applied.rejection);
        expect(d.limits.lastPreviewCap, a.limits.lastPreviewCap);
        expect(a.limits.lastPreviewCap, LayerLimits().previewCapOf(applied.project, policy));
      }
    });

    test('on random commands with a cap-tight policy', () {
      const tight = EditPolicy(maxConcurrentVideoLayers: 2, maxVisualSequences: 2);
      var above = 0;
      for (var seed = 0; seed < 12; seed++) {
        final r = Random(seed);
        var p = randomProject(seed, const RandomProjectSpec(items: 40));
        for (var step = 0; step < 25; step++) {
          final c = randomCommand(p, r);
          final a = EditContext(ids: SeededIdGenerator(seed * 1000 + step), now: when, policy: tight);
          final d = EditContext(ids: SeededIdGenerator(seed * 1000 + step), now: when, policy: tight);
          final applied = applyCommand(p, c, a);
          final probe = dryRun(p, c, d);
          expect(probe.rejection, applied.rejection, reason: 'seed $seed step $step $c');
          expect(applied.rejection, isNot(isA<LimitExceeded>()), reason: 'no layer-cap or hard-limit rejection expected');
          expect(d.limits.lastPreviewCap, a.limits.lastPreviewCap, reason: 'seed $seed step $step $c');
          if (applied.changed) {
            expect(a.limits.lastPreviewCap, LayerLimits().previewCapOf(applied.project, tight), reason: 'seed $seed step $step');
            if (a.limits.lastPreviewCap!.aboveLivePreviewCap) above++;
            p = applied.project;
          }
        }
      }
      expect(above, greaterThan(0), reason: 'the tight policy must put some projects above the cap');
    });
  });

  group('hard limits reject exactly as before', () {
    test('maxItems: growth past the cap is refused, reductions and moves pass', () {
      final p = standard();
      final n = LayerLimits.itemCount(p);
      final policy = EditPolicy(maxItems: n);
      final split = SplitItems({const ItemId('it_m')}, f(100));
      expect(applyCommand(p, split, ctx(policy: policy)).rejection, LimitExceeded(LimitExceeded.items, n));
      expect(dryRun(p, split, ctx(policy: policy)).rejection, LimitExceeded(LimitExceeded.items, n));
      expect(applyCommand(p, DeleteItems({const ItemId('it_m')}), ctx(policy: policy)).changed, isTrue);
      expect(applyCommand(p, MoveItems({const ItemId('it_m')}, f(3)), ctx(policy: policy)).changed, isTrue);
      // A project already over the item limit stays editable; only growth is refused.
      final tighter = EditPolicy(maxItems: n - 2);
      expect(applyCommand(p, MoveItems({const ItemId('it_m')}, f(3)), ctx(policy: tighter)).changed, isTrue);
      expect(applyCommand(p, split, ctx(policy: tighter)).rejection, LimitExceeded(LimitExceeded.items, n - 2));
    });

    test('the project may not grow past 24 h', () {
      final p = standard();
      final far = MoveItems({const ItemId('it_t1')}, maxProjectDurationUs - f(10));
      expect(applyCommand(p, far, ctx()).rejection, const LimitExceeded(LimitExceeded.duration, maxProjectDurationUs));
      expect(dryRun(p, far, ctx()).rejection, const LimitExceeded(LimitExceeded.duration, maxProjectDurationUs));
      expect(applyCommand(p, MoveItems({const ItemId('it_t1')}, maxProjectDurationUs - f(60)), ctx()).changed, isTrue);
    });

    test('a hard-limit refusal reports the state of the unchanged base', () {
      final over = applyCommand(twoVideos(), overlappingVideo, ctx()).project;
      final n = LayerLimits.itemCount(over);
      final policy = EditPolicy(maxItems: n, maxConcurrentVideoLayers: 2);
      final context = ctx(policy: policy);
      final out = applyCommand(over, SplitItems({const ItemId('it_main')}, f(300)), context);
      expect(out.rejection, LimitExceeded(LimitExceeded.items, n));
      expect(context.limits.lastPreviewCap, LayerLimits().previewCapOf(over, policy));
    });
  });

  test('the session exposes the state through its LayerLimits', () {
    final s = sessionOn(twoVideos(), editPolicy: decPolicy);
    expect(s.limits.lastPreviewCap, isNull);
    expect(s.limits.previewCapOf(s.project, s.editPolicy).aboveLivePreviewCap, isFalse);
    expect(s.apply(overlappingVideo).changed, isTrue);
    expect(s.limits.lastPreviewCap!.aboveLivePreviewCap, isTrue);
    expect(s.limits.previewCapOf(s.project, s.editPolicy), s.limits.lastPreviewCap);
    expect(s.limits.countsOf(s.project).exceeded(s.editPolicy), isEmpty);
  });
}
