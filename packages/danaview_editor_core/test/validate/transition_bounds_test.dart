// OWNER: CORE-08
//
// TransitionBounds: the validator resolves the neighbouring transitions of a whole track in one
// pass (maxFramesBetween); that must equal maxFrames, which resolves them per call (and which
// commands and the random generator use), including when transitions overlap the same items.

import 'package:test/test.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';

import '../support/random_project.dart';

void main() {
  test('maxFramesBetween with track-resolved neighbours equals maxFrames on 300 random projects', () {
    var checked = 0;
    for (var seed = 0; seed < 300; seed++) {
      final p = randomProject(seed);
      final rate = p.settings.frameRate;
      for (final track in p.tracks) {
        if (track.transitions.isEmpty) continue;
        final byId = {for (final i in track.items) i.id: i};
        final inAtStart = <ItemId, int>{};
        final inAtEnd = <ItemId, int>{};
        for (final t in track.transitions) {
          if (t.left != t.right) {
            inAtStart[t.right] = (t.durationFrames + 1) ~/ 2;
            inAtEnd[t.left] = t.durationFrames ~/ 2;
          }
        }
        for (final tr in track.transitions) {
          final left = byId[tr.left];
          final right = byId[tr.right];
          if (left is! MediaClip || right is! MediaClip) continue;
          for (final kind in TransitionKind.values) {
            final a = TransitionBounds.maxFrames(track: track, left: left, right: right, kind: kind, rate: rate, pool: p.pool);
            final b = TransitionBounds.maxFramesBetween(
              left: left,
              right: right,
              kind: kind,
              rate: rate,
              pool: p.pool,
              framesBeforeInLeft: inAtStart[left.id] ?? 0,
              framesAfterInRight: inAtEnd[right.id] ?? 0,
            );
            expect(b, a, reason: 'seed $seed ${tr.id} ${kind.name}');
            checked++;
          }
        }
      }
    }
    expect(checked, greaterThan(1000));
  });

  test('a transition at the left clip start and one at the right clip end reduce the room', () {
    const rate = FrameRate.fps30;
    TimeUs f(int k) => rate.timeOfFrame(k);
    final when = DateTime.utc(2026, 10, 10);
    final img = MediaAsset(
      id: const MediaId('md_img'),
      kind: MediaKind.image,
      displayName: 'img',
      locator: const AppRelativeLocator(AppRoot.documents, 'img'),
      ownership: MediaOwnership.managedCopy,
      fingerprint: const MediaFingerprint(sizeBytes: 1, quickHash: 'q'),
      probe: MediaProbe(kind: MediaKind.image, width: 100, height: 100),
      origin: MediaOrigin.files,
      addedAt: when,
    );
    final pool = MediaPool({img.id: img});
    MediaClip clip(String id, int start, int frames) => MediaClip(
          id: ItemId(id),
          start: f(start),
          duration: f(start + frames) - f(start),
          media: img.id,
          visual: VisualProps.neutral,
        );
    final a = clip('it_a', 0, 20);
    final b = clip('it_b', 20, 10);
    final c = clip('it_c', 30, 10);
    final d = clip('it_d', 40, 20);
    final track = Track(id: const TrackId('tr_v'), kind: TrackKind.video, isMain: true, items: [a, b, c, d], transitions: [
      const Transition(id: TransitionId('tx_ab'), left: ItemId('it_a'), right: ItemId('it_b'), kind: TransitionKind.fade, durationFrames: 6),
      const Transition(id: TransitionId('tx_cd'), left: ItemId('it_c'), right: ItemId('it_d'), kind: TransitionKind.fade, durationFrames: 5),
    ]);
    // b has 10 frames minus ⌈6/2⌉ = 7 left; c has 10 minus ⌊5/2⌋ = 8 left; n ≤ 2·min(7, 8).
    final max = TransitionBounds.maxFrames(track: track, left: b, right: c, kind: TransitionKind.fade, rate: rate, pool: pool);
    expect(max, 14);
    expect(
      TransitionBounds.maxFramesBetween(
        left: b,
        right: c,
        kind: TransitionKind.fade,
        rate: rate,
        pool: pool,
        framesBeforeInLeft: 3,
        framesAfterInRight: 2,
      ),
      14,
    );
    expect(TransitionBounds.maxFramesBetween(left: b, right: c, kind: TransitionKind.fade, rate: rate, pool: pool), 20);
  });
}
