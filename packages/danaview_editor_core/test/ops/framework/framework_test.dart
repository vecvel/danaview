// OWNER: CORE-09
//
// The command framework (ARCH §7.1, BUILD_PLAN CORE-09): purity, rejections as data, the shared
// apply / dry-run path, no-op detection, post-step validation, exception handling, atomic
// composites, stamping, the live pool and the generic limits (D-14).

import 'dart:math';

import 'package:test/test.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';

import '../../support/random_project.dart';
import 'ops_support.dart';

/// A random command for [p] (valid targets most of the time, unknown ids and odd times sometimes).
EditCommand randomCommand(EditProject p, Random r) {
  final items = [for (final t in p.tracks) ...t.items];
  final lanes = p.tracks;
  final media = p.pool.assets.keys.toList();
  final rate = p.settings.frameRate;
  final end = p.duration;
  ItemId pick() => r.nextInt(12) == 0 || items.isEmpty ? const ItemId('it_unknown__1') : items[r.nextInt(items.length)].id;
  Set<ItemId> picks() => {for (var i = 0; i < 1 + r.nextInt(3); i++) pick()};
  TimeUs time() {
    final span = end <= 0 ? microsPerSecond : end + microsPerSecond;
    final t = r.nextInt(span);
    return r.nextBool() ? rate.timeOfFrame(rate.frameIndexOf(t)) : t;
  }

  TimeUs delta() => (r.nextBool() ? 1 : -1) * r.nextInt(3 * microsPerSecond);
  TrackId? lane() => r.nextInt(3) == 0 || lanes.isEmpty ? null : lanes[r.nextInt(lanes.length)].id;
  MediaId m() => r.nextInt(10) == 0 || media.isEmpty ? const MediaId('md_unknown') : media[r.nextInt(media.length)];

  switch (r.nextInt(12)) {
    case 0:
      return InsertMedia([m()], time(), track: lane(), mode: InsertMode.values[r.nextInt(InsertMode.values.length)]);
    case 1:
      return MoveItems(picks(), delta(), toTrack: lane(), ripple: r.nextBool(), clamp: r.nextBool());
    case 2:
      return TrimItem(pick(), TrimEdge.values[r.nextInt(2)], time(), ripple: r.nextBool(), clamp: r.nextBool());
    case 3:
      return SplitItems(r.nextBool() ? const {} : picks(), time());
    case 4:
      return DeleteItems(picks(), ripple: r.nextBool());
    case 5:
      final l = lane();
      final t0 = time();
      return DeleteGap(GapRef(l ?? const TrackId('tr_unknown__1'), TimeRange(t0, t0 + r.nextInt(2 * microsPerSecond))));
    case 6:
      return DuplicateItems(picks(), ripple: r.nextBool());
    case 7:
      return ReplaceMedia(pick(), m());
    case 8:
      return ExtractAudio(pick());
    case 9:
      return r.nextBool() ? LinkItems(picks()) : UnlinkItems(picks());
    case 10:
      final c = cutItems(p, picks(), ripple: r.nextBool());
      return c.command;
    default:
      return CompositeCommand('Random pair', [randomCommand(p, r), randomCommand(p, r)]);
  }
}

void main() {
  group('purity', () {
    for (var seed = 0; seed < 40; seed++) {
      test('same input + seeded ids -> equal output (seed $seed)', () {
        final p = randomProject(seed);
        final r = Random(seed);
        for (var i = 0; i < 12; i++) {
          final c = randomCommand(p, r);
          // Seeds far from the project's own generator seed, so minted ids never collide with it.
          final a = applyCommand(p, c, ctx(seed: 500000 + seed * 100 + i));
          final b = applyCommand(p, c, ctx(seed: 500000 + seed * 100 + i));
          expect(b.project, a.project, reason: '$c');
          expect(b.rejection, a.rejection, reason: '$c');
          expect(b.noop, a.noop);
          expect(b.affected, a.affected);
          expect(b.changedTracks, a.changedTracks);
          expect(b.createdTracks, a.createdTracks);
          expect(b.notices, a.notices);
          expect(b.selection, a.selection);
        }
        // The input is never modified.
        expect(p, randomProject(seed));
      });
    }
  });

  group('rejections are data', () {
    for (var seed = 100; seed < 160; seed++) {
      test('random commands never throw, never break invariants (seed $seed)', () {
        var p = randomProject(seed, const RandomProjectSpec(items: 40));
        final r = Random(seed);
        for (var i = 0; i < 25; i++) {
          final c = randomCommand(p, r);
          late EditOutcome out;
          late EditPreview pre;
          expect(() => out = applyCommand(p, c, ctx(seed: 700000 + seed * 100 + i)), returnsNormally, reason: '$c');
          expect(() => pre = dryRun(p, c, ctx(seed: 700000 + seed * 100 + i)), returnsNormally, reason: '$c');
          expect(pre.rejection.runtimeType, out.rejection.runtimeType, reason: 'dry run and apply disagree on $c');
          expect(out.rejection, isNot(isA<InternalInconsistency>()), reason: '$c -> ${out.rejection}');
          if (out.isRejected || out.noop) {
            expect(identical(out.project, p), isTrue, reason: 'refused or no-op must return the input ($c)');
            continue;
          }
          expectValid(out.project, '$c');
          p = out.project;
        }
      });
    }
  });

  group('framework', () {
    test('no-op returns the identical project without changes', () {
      final p = standard();
      final out = applyCommand(p, MoveItems({const ItemId('it_c')}, 0), ctx());
      expect(out.noop, isTrue);
      expect(out.changed, isFalse);
      expect(identical(out.project, p), isTrue);
      expect(out.changedTracks, isEmpty);
      final raw = applyCommand(p, RawEditCommand('Nothing', (x) => x), ctx());
      expect(raw.noop, isTrue);
      final equalCopy = applyCommand(p, RawEditCommand('Equal copy', (x) => x.copyWith(timeline: Timeline(settings: x.settings, tracks: [...x.tracks], markers: x.markers, revision: x.revision))), ctx());
      expect(equalCopy.noop, isTrue);
    });

    test('a command that breaks an invariant becomes InternalInconsistency; project unchanged', () {
      final p = standard();
      final out = applyCommand(
        p,
        RawEditCommand('Overlap', (x) {
          final t = x.tracks.firstWhere((t) => t.id == const TrackId('tr_ov1'));
          final next = t.copyWith(items: [...t.items, vclip('it_p2', 40, 30, media: 'md_image')]);
          return x.copyWith(timeline: Timeline(settings: x.settings, tracks: [for (final l in x.tracks) l.id == t.id ? next : l], markers: x.markers));
        }),
        ctx(),
      );
      final r = out.rejection;
      expect(r, isA<InternalInconsistency>());
      expect((r! as InternalInconsistency).violations, isNotEmpty);
      expect(identical(out.project, p), isTrue);
      final pre = dryRun(p, RawEditCommand('Overlap', (x) => out.project), ctx());
      expect(pre.isRejected, isFalse, reason: 'unchanged project is a no-op');
    });

    test('violations that existed before the command do not block edits', () {
      final broken = project([
        lane('tr_main', TrackKind.video, [vclip('it_a', 0, 60)], main: true),
        lane('tr_ov1', TrackKind.overlay, [vclip('it_p1', 0, 30, media: 'md_image'), vclip('it_p2', 10, 30, media: 'md_image')]),
        lane('tr_txt', TrackKind.text, [text('it_t1', 0, 45)]),
      ]);
      expect(validate(broken), isNotEmpty);
      final out = applyCommand(broken, MoveItems({const ItemId('it_t1')}, f(10)), ctx());
      expect(out.changed, isTrue, reason: '${out.rejection}');
    });

    test('exceptions inside a command become InternalInconsistency (apply and dry run)', () {
      final p = standard();
      final c = RawEditCommand('Throws', (x) => throw StateError('boom'));
      final out = applyCommand(p, c, ctx());
      expect(out.rejection, isA<InternalInconsistency>());
      expect((out.rejection! as InternalInconsistency).detail, 'StateError');
      expect(identical(out.project, p), isTrue);
      expect(dryRun(p, c, ctx()).rejection, isA<InternalInconsistency>());
    });

    test('every rejection is a value with a stable code', () {
      const all = <EditRejection>[
        TrackLocked(TrackId('tr_a')),
        ItemNotFound(ItemId('it_a')),
        NoRoom(),
        LimitExceeded(LimitExceeded.items, 5000),
        CannotDeleteMainTrack(),
      ];
      for (final r in all) {
        expect(r.code, isNotEmpty);
        expect(r, r);
      }
      expect(const LimitExceeded(LimitExceeded.items, 1), const LimitExceeded(LimitExceeded.items, 1));
      expect(const LimitExceeded(LimitExceeded.items, 1), isNot(const LimitExceeded(LimitExceeded.duration, 1)));
    });

    test('stamp writes the revision and changedAt of changed lanes only', () {
      final p = standard();
      final out = applyCommand(p, DeleteItems({const ItemId('it_c')}), ctx(stamp: 42));
      expect(out.project.revision, 42);
      for (final t in out.project.tracks) {
        expect(t.changedAt, out.changedTracks.contains(t.id) ? 42 : 0, reason: '${t.id}');
      }
      final unstamped = applyCommand(p, DeleteItems({const ItemId('it_c')}), ctx());
      expect(unstamped.project.revision, p.revision);
    });

    test('the live pool of the context replaces the snapshot pool', () {
      final p = standard();
      final live = p.pool.upsert(asset('md_new', MediaKind.image));
      final without = applyCommand(p, InsertMedia([const MediaId('md_new')], f(400), mode: InsertMode.newLane), ctx());
      expect(without.rejection, isA<MediaUnavailable>());
      final withLive = applyCommand(p, InsertMedia([const MediaId('md_new')], f(400), mode: InsertMode.newLane), ctx(pool: live));
      expect(withLive.changed, isTrue, reason: '${withLive.rejection}');
      expect(withLive.project.pool.contains(const MediaId('md_new')), isTrue);
    });

    test('dry run reports placements, created lanes and rejections of the apply path', () {
      final p = standard(rippleEnabled: false);
      final c = InsertMedia([const MediaId('md_short')], f(10), track: const TrackId('tr_main'), mode: InsertMode.newLane);
      final out = applyCommand(p, c, ctx());
      final pre = dryRun(p, c, ctx());
      expect(pre.rejection, isNull);
      expect(pre.createsTracks, hasLength(out.createdTracks.length));
      expect(pre.createsTracks.single.kind, TrackKind.video);
      for (final id in out.affected) {
        final loc = out.project.index.locate(id)!;
        expect(pre.placements[id]!.range, loc.item.range);
        expect(pre.placements[id]!.track, loc.track.id);
      }
      final locked = dryRun(standard(lockMain: true), DeleteItems({const ItemId('it_b')}), ctx());
      expect(locked.rejection, const TrackLocked(TrackId('tr_main')));
    });
  });

  group('CompositeCommand', () {
    test('applies children in sequence as one command', () {
      final p = standard();
      final c = CompositeCommand('Split and delete', [
        SplitItems({const ItemId('it_b')}, f(90)),
        DeleteItems({const ItemId('it_c')}),
      ]);
      final out = applyCommand(p, c, ctx());
      expect(out.changed, isTrue, reason: '${out.rejection}');
      expectValid(out.project);
      final main = out.project.tracks.firstWhere((t) => t.isMain);
      expect(main.items.map((i) => rate.frameIndexOf(i.start)), [0, 60, 90]);
      expect(out.project.index.locate(const ItemId('it_c')), isNull);
      expect(out.affected, containsAll(const [ItemId('it_b'), ItemId('it_c')]));
    });

    test('is all-or-nothing: a refused child refuses the whole command', () {
      final p = standard();
      for (final c in [
        CompositeCommand('Late failure', [SplitItems({const ItemId('it_b')}, f(90)), DeleteItems({const ItemId('it_missing__1')})]),
        CompositeCommand('Early failure', [DeleteItems({const ItemId('it_missing__1')}), DeleteItems({const ItemId('it_c')})]),
        CompositeCommand('Nested', [
          DeleteItems({const ItemId('it_c')}),
          CompositeCommand('Inner', [SplitItems({const ItemId('it_m')}, f(100)), RawEditCommand('Throws', (x) => throw ArgumentError())]),
        ]),
      ]) {
        final out = applyCommand(p, c, ctx());
        expect(out.isRejected, isTrue, reason: c.label);
        expect(identical(out.project, p), isTrue, reason: c.label);
        expect(out.affected, isEmpty);
        expect(dryRun(p, c, ctx()).rejection.runtimeType, out.rejection.runtimeType);
      }
      final locked = applyCommand(
        standard(lockMain: true),
        CompositeCommand('Locked', [DeleteItems({const ItemId('it_m')}), DeleteItems({const ItemId('it_b')})]),
        ctx(),
      );
      expect(locked.rejection, const TrackLocked(TrackId('tr_main')));
    });

    test('limits run once, on the final result', () {
      final p = standard();
      final n = LayerLimits.itemCount(p);
      final policy = EditPolicy(maxItems: n);
      final grow = applyCommand(p, DuplicateItems({const ItemId('it_t1')}), ctx(policy: policy));
      expect(grow.rejection, LimitExceeded(LimitExceeded.items, n));
      final net = applyCommand(
        p,
        CompositeCommand('Duplicate then delete', [DuplicateItems({const ItemId('it_t1')}), DeleteItems({const ItemId('it_s1')})]),
        ctx(policy: policy),
      );
      expect(net.changed, isTrue, reason: '${net.rejection}');
      expect(LayerLimits.itemCount(net.project), n);
    });

    test('an all-no-op composite is a no-op', () {
      final p = standard();
      final out = applyCommand(p, CompositeCommand('Nothing', [MoveItems({const ItemId('it_c')}, 0)]), ctx());
      expect(out.noop, isTrue);
      expect(identical(out.project, p), isTrue);
    });
  });

  group('limits (D-14)', () {
    // Main video [0,600) and six overlay lanes, each with one short video at [100·i, 100·i + 50):
    // none of the PiPs overlap each other, so they pack into one sequence above the main lane.
    EditProject sparsePip({int lanes = 6}) => project([
          lane('tr_main', TrackKind.video, [vclip('it_main', 0, 600)], main: true),
          for (var i = 0; i < lanes; i++)
            lane('tr_ov$i', TrackKind.overlay, [vclip('it_p$i', 100 * i, 50, media: 'md_video2')]),
        ]);

    EditProject withLane(EditProject x, Track t) => x.copyWith(
          timeline: Timeline(settings: x.settings, tracks: [...x.tracks]..insert(TrackOrder.insertIndexFor(x.tracks, t.kind), t), markers: x.markers, revision: x.revision),
        );

    const seqPolicy = EditPolicy(maxVisualSequences: 2);

    test('six sparse PiP lanes pass the sequence cap after packing', () {
      final five = sparsePip(lanes: 5);
      final limits = LayerLimits();
      final counts = limits.countsOf(sparsePip());
      expect(counts.visualSequences, 2);
      expect(counts.exceeded(seqPolicy), isEmpty);
      // Adding the sixth sparse lane through a command passes.
      final out = applyCommand(
        five,
        RawEditCommand('Add sixth lane', (x) => withLane(x, lane('tr_ov5', TrackKind.overlay, [vclip('it_p5', 500, 50, media: 'md_video2')]))),
        ctx(policy: seqPolicy),
      );
      expect(out.changed, isTrue, reason: '${out.rejection}');
      // Ordinary edits on the six lanes pass too.
      final move = applyCommand(sparsePip(), MoveItems({const ItemId('it_p5')}, f(20)), ctx(policy: seqPolicy));
      expect(move.changed, isTrue, reason: '${move.rejection}');
    });

    test('a seventh lane overlapping a PiP fails the sequence cap', () {
      final p = sparsePip();
      final c = RawEditCommand('Add seventh lane', (x) => withLane(x, lane('tr_ov6', TrackKind.overlay, [vclip('it_p6', 20, 50, media: 'md_video2')])));
      const expected = LimitExceeded(LimitExceeded.visualSequences, 2);
      final out = applyCommand(p, c, ctx(policy: seqPolicy));
      expect(out.rejection, expected);
      expect(identical(out.project, p), isTrue);
      expect(dryRun(p, c, ctx(policy: seqPolicy)).rejection, expected);
      // The same through a real command: an overlapping insert lands on another lane and stacks.
      final insert = InsertMedia([const MediaId('md_short')], f(10), track: const TrackId('tr_ov0'), mode: InsertMode.newLane);
      expect(applyCommand(p, insert, ctx(policy: seqPolicy)).rejection, expected);
      // With room for a third sequence it is accepted.
      expect(applyCommand(p, c, ctx(policy: const EditPolicy(maxVisualSequences: 3))).changed, isTrue);
    });

    EditProject twoVideos() => project([
          lane('tr_main', TrackKind.video, [vclip('it_main', 0, 600)], main: true),
          lane('tr_ov0', TrackKind.overlay, [vclip('it_v0', 0, 90, media: 'md_video2')]),
          lane('tr_txt', TrackKind.text, [text('it_t1', 0, 45)]),
        ]);

    const decPolicy = EditPolicy(maxConcurrentVideoLayers: 2);

    test('peak concurrent decoder-backed layers are capped', () {
      final p = twoVideos();
      expect(LayerLimits().countsOf(p).peakConcurrentVideoLayers, 2);
      final overlapping = InsertMedia([const MediaId('md_short')], f(30), track: const TrackId('tr_ov0'), mode: InsertMode.newLane);
      const expected = LimitExceeded(LimitExceeded.concurrentVideoLayers, 2);
      expect(applyCommand(p, overlapping, ctx(policy: decPolicy)).rejection, expected);
      expect(dryRun(p, overlapping, ctx(policy: decPolicy)).rejection, expected);
      // Images are not decoder-backed: the same overlap with an image passes.
      final image = InsertMedia([const MediaId('md_image')], f(30), track: const TrackId('tr_ov0'), mode: InsertMode.newLane);
      expect(applyCommand(p, image, ctx(policy: decPolicy)).changed, isTrue);
      // A video where only one other decoder is active passes.
      final later = InsertMedia([const MediaId('md_short')], f(200), track: const TrackId('tr_ov0'), mode: InsertMode.newLane);
      expect(applyCommand(p, later, ctx(policy: decPolicy)).changed, isTrue);
    });

    test('a project already over a cap stays editable; only growth is refused', () {
      final over = applyCommand(
        twoVideos(),
        InsertMedia([const MediaId('md_short')], f(30), track: const TrackId('tr_ov0'), mode: InsertMode.newLane),
        ctx(),
      ).project;
      expect(LayerLimits().countsOf(over).peakConcurrentVideoLayers, 3);
      expect(LayerLimits().countsOf(over).exceeded(decPolicy), [const LimitExceeded(LimitExceeded.concurrentVideoLayers, 2)]);
      expect(applyCommand(over, DeleteItems({const ItemId('it_v0')}), ctx(seed: 8, policy: decPolicy)).changed, isTrue);
      expect(applyCommand(over, MoveItems({const ItemId('it_t1')}, f(5)), ctx(policy: decPolicy)).changed, isTrue);
      expect(applyCommand(over, MoveItems({const ItemId('it_v0')}, f(5)), ctx(policy: decPolicy)).changed, isTrue);
      final more = InsertMedia([const MediaId('md_short')], f(40), track: const TrackId('tr_ov0'), mode: InsertMode.newLane);
      expect(applyCommand(over, more, ctx(seed: 8, policy: decPolicy)).rejection, const LimitExceeded(LimitExceeded.concurrentVideoLayers, 2));
    });

    test('maxItems: growth past the cap is refused, reductions pass', () {
      final p = standard();
      final n = LayerLimits.itemCount(p);
      final policy = EditPolicy(maxItems: n);
      expect(applyCommand(p, SplitItems({const ItemId('it_m')}, f(100)), ctx(policy: policy)).rejection, LimitExceeded(LimitExceeded.items, n));
      expect(applyCommand(p, DeleteItems({const ItemId('it_m')}), ctx(policy: policy)).changed, isTrue);
      expect(applyCommand(p, MoveItems({const ItemId('it_m')}, f(3)), ctx(policy: policy)).changed, isTrue);
      expect(const EditPolicy().maxItems, 5000);
    });

    test('the project may not grow past 24 h', () {
      final p = standard();
      final far = MoveItems({const ItemId('it_t1')}, maxProjectDurationUs - f(10));
      expect(applyCommand(p, far, ctx()).rejection, const LimitExceeded(LimitExceeded.duration, maxProjectDurationUs));
      final near = MoveItems({const ItemId('it_t1')}, maxProjectDurationUs - f(60));
      expect(applyCommand(p, near, ctx()).changed, isTrue);
    });

    test('commands that leave the visual lanes alone skip packing; packing is incremental', () {
      final context = ctx();
      final limits = context.limits;
      var p = standard();
      p = applyCommand(p, MoveItems({const ItemId('it_b')}, f(5)), context).project;
      final packs = limits.packCount;
      final textOnly = applyCommand(p, MoveItems({const ItemId('it_t1')}, f(5)), context);
      expect(textOnly.changed, isTrue);
      expect(limits.packCount, packs, reason: 'a text-only edit must not pack');
      expect(LayerLimits.visualLayersUnchanged(p, textOnly.project), isTrue);
      final visual = applyCommand(textOnly.project, MoveItems({const ItemId('it_p1')}, f(5)), context);
      expect(visual.changed, isTrue);
      expect(LayerLimits.visualLayersUnchanged(textOnly.project, visual.project), isFalse);
      // A cached checker and a fresh one agree.
      expect(limits.countsOf(visual.project), LayerLimits().countsOf(visual.project));
    });
  });
}
