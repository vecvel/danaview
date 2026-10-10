// OWNER: CORE-12
//
// Seeded fuzz of SetSpeed, SetReversed and FreezeFrame on random valid projects (CORE-08
// generator): no command throws or becomes InternalInconsistency, every applied result validates
// fully, dry run and apply agree, the input is never modified. The project-wide fuzzer (CORE-34)
// mixes these with every other command.

import 'dart:math';

import 'package:test/test.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart';

import '../../support/random_project.dart';
import '../framework/ops_support.dart';

/// [p] with a pending still of every video asset of its pool (what the session makes before a freeze).
EditProject withStills(EditProject p) {
  var pool = p.pool;
  final stills = <MediaId, MediaId>{};
  for (final a in p.pool.assets.values) {
    if (a.kind != MediaKind.video) continue;
    final id = MediaId('md_still_${a.id.value.substring(3)}');
    stills[a.id] = id;
    pool = pool.upsert(asset(id.value, MediaKind.still,
        derived: StillSpec(a.id, 0, sourceQuickHash: a.fingerprint.quickHash), status: const PendingStatus('job')));
  }
  return p.copyWith(pool: pool);
}

EditCommand randomSpeedCommand(EditProject p, Random r) {
  final items = [for (final t in p.tracks) ...t.items];
  ItemId pick() =>
      r.nextInt(15) == 0 || items.isEmpty ? const ItemId('it_unknown__1') : items[r.nextInt(items.length)].id;
  final end = p.duration <= 0 ? microsPerSecond : p.duration;
  switch (r.nextInt(3)) {
    case 0:
      final SpeedSpec spec = switch (r.nextInt(4)) {
        0 => ConstantSpeed(speedPresets[r.nextInt(speedPresets.length)]),
        1 => ConstantSpeed(0.05 + r.nextDouble() * 11),
        2 => SpeedRampPresets.byId(SpeedRampPresets.ids[r.nextInt(SpeedRampPresets.ids.length)])!,
        _ => SpeedRamp([
            const SpeedPoint(0, 1),
            for (var i = 1; i < 1 + r.nextInt(5); i++) SpeedPoint(i / 6, 0.1 + r.nextDouble() * 9.9),
            const SpeedPoint(1, 1),
          ]),
      };
      return SetSpeed(pick(), spec,
          maintainPitch: r.nextBool() ? null : r.nextBool(), ripple: r.nextBool() ? null : r.nextBool());
    case 1:
      return SetReversed(pick(), r.nextBool());
    default:
      final id = pick();
      final at = r.nextInt(end);
      final loc = p.index.locate(id);
      final media = loc?.item is MediaClip ? (loc!.item as MediaClip).media : const MediaId('md_x');
      return FreezeFrame(
          id,
          r.nextBool() ? at : (loc?.item.start ?? at) + r.nextInt(microsPerSecond),
          r.nextInt(3 * microsPerSecond) - 100,
          MediaId('md_still_${media.value.length > 3 ? media.value.substring(3) : 'x'}'));
  }
}

final Map<String, int> appliedBy = {};

void main() {
  for (var seed = 0; seed < 60; seed++) {
    test('random speed, reverse and freeze commands keep every invariant (seed $seed)', () {
      var p = withStills(randomProject(seed, const RandomProjectSpec(items: 40)));
      final r = Random(seed * 31 + 5);
      for (var i = 0; i < 25; i++) {
        final c = randomSpeedCommand(p, r);
        final seedIds = 900000 + seed * 100 + i;
        final before = p;
        late EditOutcome out;
        late EditPreview pre;
        expect(() => out = applyCommand(p, c, ctx(seed: seedIds)), returnsNormally, reason: '$c');
        expect(() => pre = dryRun(p, c, ctx(seed: seedIds)), returnsNormally, reason: '$c');
        expect(identical(before, p), isTrue);
        expect(pre.rejection.runtimeType, out.rejection.runtimeType, reason: 'dry run and apply disagree on $c');
        expect(out.rejection, isNot(isA<InternalInconsistency>()), reason: '$c -> ${out.rejection}');
        if (out.isRejected || out.noop) {
          expect(identical(out.project, p), isTrue, reason: '$c');
          continue;
        }
        expectValid(out.project, '$c');
        appliedBy.update(c.runtimeType.toString(), (n) => n + 1, ifAbsent: () => 1);
        p = out.project;
      }
    });
  }

  test('the fuzz exercised every command (tearDown of the seeds above)', () {
    expect(appliedBy['SetSpeed'], greaterThan(100));
    expect(appliedBy['SetReversed'], greaterThan(50));
    expect(appliedBy['FreezeFrame'], greaterThan(20), reason: '$appliedBy');
  });
}
