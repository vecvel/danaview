// OWNER: CORE-19
//
// EditSession (ARCH §7.3, BUILD_PLAN CORE-19): undo/redo/jump identity, coalescing, transaction
// semantics, sticky pool changes vs undoable pool edits, session-monotonic stamps, eviction by
// count and bytes, retainedMedia, exceptions as InternalInconsistency.

import 'package:test/test.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart';

import '../ops/framework/ops_support.dart';
import 'session_support.dart';

const ItemId a = ItemId('it_a');
const ItemId b = ItemId('it_b');
const ItemId c = ItemId('it_c');
const ItemId p1 = ItemId('it_p1');
const ItemId t1 = ItemId('it_t1');

/// Every revision a test observed, to check strict growth.
void expectStrictlyIncreasing(List<int> stamps) {
  for (var i = 1; i < stamps.length; i++) {
    expect(stamps[i], greaterThan(stamps[i - 1]), reason: 'stamps $stamps');
  }
}

void main() {
  group('apply / undo / redo / jump', () {
    test('undo restores the identical snapshot; redo restores the identical result', () {
      final s = sessionOn(null);
      final t0 = s.project.timeline;
      final o1 = s.apply(SplitItems({b}, f(90)));
      expect(o1.changed, isTrue);
      final t1Line = s.project.timeline;
      final o2 = s.apply(MoveItems({p1}, f(10)));
      expect(o2.changed, isTrue);
      final t2 = s.project.timeline;
      expect(s.history, const HistoryStatus(position: 2, length: 2, undoLabel: 'Move clip'));

      final u1 = s.undo()!;
      expect(u1.direction, HistoryDirection.undo);
      expect(u1.labels, ['Move clip']);
      expect(sameSnapshot(s.project.timeline, t1Line), isTrue);
      expect(u1.changedTracks, {const TrackId('tr_ov1')});
      expect(u1.selection!.items, {p1});
      expect(s.history.redoLabel, 'Move clip');

      s.undo();
      expect(sameSnapshot(s.project.timeline, t0), isTrue);
      expect(s.undo(), isNull);
      expect(s.history.canUndo, isFalse);

      final r = s.redo()!;
      expect(r.direction, HistoryDirection.redo);
      expect(r.label, 'Split');
      expect(sameSnapshot(s.project.timeline, t1Line), isTrue);
      s.redo();
      expect(sameSnapshot(s.project.timeline, t2), isTrue);
      expect(s.redo(), isNull);
      expectValid(s.project);
    });

    test('jump is one combined step with one stamp; it clamps; 0 is a no-op', () {
      final s = sessionOn(null);
      final snaps = [s.project.timeline];
      s.apply(SplitItems({b}, f(90)));
      snaps.add(s.project.timeline);
      s.apply(MoveItems({p1}, f(10)));
      snaps.add(s.project.timeline);
      s.apply(const AddMarker(0, name: 'm'));
      snaps.add(s.project.timeline);
      final rev = s.project.revision;

      expect(s.jump(0), isNull);
      final back = s.jump(-2)!;
      expect(back.steps, 2);
      expect(back.labels, ['Add marker', 'Move clip']);
      expect(s.project.revision, rev + 1);
      expect(sameSnapshot(s.project.timeline, snaps[1]), isTrue);
      expect(s.history.position, 1);

      final fwd = s.jump(99)!;
      expect(fwd.steps, 2);
      expect(fwd.labels, ['Move clip', 'Add marker']);
      expect(s.project.revision, rev + 2);
      expect(sameSnapshot(s.project.timeline, snaps[3]), isTrue);

      s.jump(-99);
      expect(sameSnapshot(s.project.timeline, snaps[0]), isTrue);
      expect(s.history.position, 0);
      expect(s.jump(-1), isNull);
    });

    test('a new apply after undo drops the redo entries', () {
      final s = sessionOn(null);
      s.apply(SplitItems({b}, f(90)));
      s.apply(MoveItems({p1}, f(10)));
      s.undo();
      s.apply(const AddMarker(0));
      expect(s.history, const HistoryStatus(position: 2, length: 2, undoLabel: 'Add marker'));
      expect(s.recentLabels(10), ['Add marker', 'Split']);
      expect(s.recentLabels(1), ['Add marker']);
    });

    test('rejected and no-op commands record nothing', () {
      final s = sessionOn(standard(lockMain: true));
      final before = s.project;
      final r = s.apply(SplitItems({b}, f(90)));
      expect(r.rejection, isA<TrackLocked>());
      expect(identical(s.project, before), isTrue);
      final n = s.apply(MoveItems({p1}, 0));
      expect(n.changed, isFalse);
      expect(identical(s.project, before), isTrue);
      expect(s.history, HistoryStatus.empty);
      expect(s.project.meta.editCount, 0);
      expect(s.project.docRevision, before.docRevision);
    });

    test('dryRun previews without recording or stamping', () {
      final s = sessionOn(null);
      final stamp = s.nextStamp;
      final pv = s.dryRun(MoveItems({p1}, f(10)));
      expect(pv.placements[p1]!.range.start, f(40));
      expect(s.history.length, 0);
      expect(s.nextStamp, stamp);
    });

    test('exceptions inside a command become InternalInconsistency and change nothing', () {
      final s = sessionOn(null);
      final before = s.project;
      final o = s.apply(RawEditCommand('Boom', (_) => throw StateError('boom')));
      expect(o.rejection, isA<InternalInconsistency>());
      expect(identical(s.project, before), isTrue);
      expect(s.history.length, 0);
      final tx = s.begin('Gesture');
      final u = tx.update(RawEditCommand('Boom', (_) => throw StateError('boom')));
      expect(u.rejection, isA<InternalInconsistency>());
      expect(identical(s.project, before), isTrue);
      expect(tx.commit().noop, isTrue);
      expect(s.history.length, 0);
      expect(s.dryRun(RawEditCommand('Boom', (_) => throw StateError('boom'))).rejection, isA<InternalInconsistency>());
    });
  });

  group('editCount and stamps', () {
    test('editCount counts committed entries and never decrements', () {
      final s = sessionOn(null);
      s.apply(SplitItems({b}, f(90)));
      s.apply(MoveItems({p1}, f(10)));
      expect(s.project.meta.editCount, 2);
      s.undo();
      s.undo();
      expect(s.project.meta.editCount, 2);
      s.redo();
      expect(s.project.meta.editCount, 2);
      s.apply(const AddMarker(0));
      expect(s.project.meta.editCount, 3);
    });

    test('the first stamp follows the persisted revision and lane stamps', () {
      final p0 = standard();
      final tl = p0.timeline;
      final p = p0.copyWith(
        timeline: tl.copyWith(
          revision: 10,
          tracks: [for (final t in tl.tracks) t.id.value == 'tr_txt' ? t.copyWith(changedAt: 15) : t],
        ),
      );
      final s = sessionOn(p);
      expect(s.nextStamp, 16);
      s.apply(MoveItems({p1}, f(10)));
      expect(s.project.revision, 16);
      expect(s.project.tracks.firstWhere((t) => t.id.value == 'tr_ov1').changedAt, 16);
    });

    test('stamps strictly increase across undo + new edit and are never reused', () {
      final s = sessionOn(null);
      final revisions = [s.project.revision];
      final laneStamps = <int>{};
      int overlayStamp() => s.project.tracks.firstWhere((t) => t.id.value == 'tr_ov1').changedAt;

      s.apply(MoveItems({p1}, f(10)));
      revisions.add(s.project.revision);
      final first = overlayStamp();
      laneStamps.add(first);

      s.undo();
      revisions.add(s.project.revision);
      expect(overlayStamp(), 0, reason: 'the restored lane keeps its old stamp');

      s.apply(MoveItems({p1}, f(20)));
      revisions.add(s.project.revision);
      final second = overlayStamp();
      expect(second, isNot(first), reason: 'a different lane state never reuses a stamp');
      expect(second, greaterThan(first));

      s.undo();
      revisions.add(s.project.revision);
      s.redo();
      revisions.add(s.project.revision);
      expect(overlayStamp(), second, reason: 'redo restores the identical lane');

      final tx = s.begin('Drag');
      tx.update(MoveItems({p1}, f(5)));
      revisions.add(s.project.revision);
      tx.update(MoveItems({p1}, f(6)));
      revisions.add(s.project.revision);
      tx.commit();
      revisions.add(s.project.revision);
      s.applyPoolChange(AddAssets([asset('md_new', MediaKind.image)]));
      s.updateView((v) => v.copyWith(playhead: f(3)));
      s.apply(const AddMarker(0));
      revisions.add(s.project.revision);

      expectStrictlyIncreasing([
        for (var i = 0; i < revisions.length; i++)
          if (i == 0 || revisions[i] != revisions[i - 1]) revisions[i],
      ]);
      expect(revisions.toSet().length, revisions.length - 1, reason: 'only commit keeps the last update stamp');
    });

    test('pool and view changes bump only docRevision', () {
      final s = sessionOn(null);
      final rev = s.project.revision;
      final doc = s.project.docRevision;
      s.applyPoolChange(AddAssets([asset('md_new', MediaKind.image)]));
      expect(s.project.docRevision, doc + 1);
      s.updateView((v) => v.copyWith(playhead: f(12)));
      expect(s.project.docRevision, doc + 2);
      s.updateView((v) => v.copyWith(playhead: f(12)));
      expect(s.project.docRevision, doc + 2, reason: 'an unchanged view is not a change');
      expect(s.project.revision, rev);
      expect(s.history.length, 0);
      expect(s.project.meta.editCount, 0);
    });

    test('the view is never in history', () {
      final s = sessionOn(null);
      s.apply(MoveItems({p1}, f(10)));
      s.updateView((v) => v.copyWith(playhead: f(42), rippleEnabled: false));
      s.undo();
      expect(s.project.view.playhead, f(42));
      expect(s.project.view.rippleEnabled, isFalse);
    });
  });

  group('coalescing', () {
    test('same key within the window joins one entry; the window counts from the last edit', () {
      final clock = FakeClock();
      final s = sessionOn(null, clock: clock);
      final t0 = s.project.timeline;
      const cmd1 = SetText(t1, 'H');
      s.apply(cmd1, coalesceKey: cmd1.coalesceKey);
      for (final v in ['He', 'Hel', 'Hell', 'Hello']) {
        clock.advance(const Duration(milliseconds: 900));
        final cmd = SetText(t1, v);
        s.apply(cmd, coalesceKey: cmd.coalesceKey);
      }
      expect(s.history.length, 1);
      expect(s.project.meta.editCount, 1);
      expect((s.project.index.item(t1)! as TextItem).text, 'Hello');

      clock.advance(const Duration(milliseconds: 1001));
      s.apply(const SetText(t1, 'Hello!'), coalesceKey: 'text:$t1');
      expect(s.history.length, 2, reason: 'outside the window');
      expect(s.project.meta.editCount, 2);

      s.undo();
      expect((s.project.index.item(t1)! as TextItem).text, 'Hello');
      s.undo();
      expect(sameSnapshot(s.project.timeline, t0), isTrue);
    });

    test('a different key, another command or an undo breaks the run', () {
      final clock = FakeClock();
      final s = sessionOn(null, clock: clock);
      s.apply(const SetText(t1, 'A'), coalesceKey: 'text:$t1');
      clock.advance(const Duration(milliseconds: 100));
      s.apply(const SetCueText(ItemId('it_s1'), 'B'), coalesceKey: SetCueText.coalesceKey(const ItemId('it_s1')));
      expect(s.history.length, 2);
      clock.advance(const Duration(milliseconds: 100));
      s.apply(const SetText(t1, 'AA'), coalesceKey: 'text:$t1');
      expect(s.history.length, 3, reason: 'the newest entry has another key');
      clock.advance(const Duration(milliseconds: 100));
      s.apply(const AddMarker(0));
      clock.advance(const Duration(milliseconds: 100));
      s.apply(const SetText(t1, 'AAA'), coalesceKey: 'text:$t1');
      expect(s.history.length, 5, reason: 'an unkeyed command in between');
      clock.advance(const Duration(milliseconds: 100));
      s.undo();
      s.redo();
      clock.advance(const Duration(milliseconds: 100));
      s.apply(const SetText(t1, 'AAAA'), coalesceKey: 'text:$t1');
      expect(s.history.length, 6, reason: 'undo/redo in between');
      clock.advance(const Duration(milliseconds: 100));
      s.apply(const SetText(t1, 'AAAAB'));
      expect(s.history.length, 7, reason: 'no key: never coalesces');
    });

    test('a coalesced entry keeps its original before and its byte estimate tracks the result', () {
      final clock = FakeClock();
      final s = sessionOn(null, clock: clock);
      final t0 = s.project.timeline;
      s.apply(const SetText(t1, 'x'), coalesceKey: 'k');
      clock.advance(const Duration(milliseconds: 10));
      s.apply(const SetText(t1, 'xy'), coalesceKey: 'k');
      final e = s.entries.single;
      expect(identical(e.before, t0), isTrue);
      expect(identical(e.after, s.project.timeline), isTrue);
      expect(s.historyBytes, e.approxBytes);
      expect(e.affected, {t1});
    });
  });

  group('transactions', () {
    test('update applies to the base, never cumulatively; commit records one entry', () {
      final s = sessionOn(null);
      final base = s.project;
      final tx = s.begin('Move clip');
      expect(tx.isOpen, isTrue);
      expect(tx.preview, isNull);
      tx.update(MoveItems({p1}, f(10)));
      expect(s.project.index.item(p1)!.start, f(40));
      tx.update(MoveItems({p1}, f(20)));
      expect(s.project.index.item(p1)!.start, f(50), reason: 'from the base, not 40 + 20');
      expect(tx.preview!.placements[p1]!.range.start, f(50));
      expect(s.history.length, 0, reason: 'nothing recorded before commit');
      expect(identical(s.committedProject, base), isTrue);

      final o = tx.commit();
      expect(o.changed, isTrue);
      expect(tx.isOpen, isFalse);
      expect(s.transaction, isNull);
      expect(s.history, const HistoryStatus(position: 1, length: 1, undoLabel: 'Move clip'));
      expect(s.project.index.item(p1)!.start, f(50));
      expect(s.project.meta.editCount, 1);
      s.undo();
      expect(sameSnapshot(s.project.timeline, base.timeline), isTrue);
    });

    test('dragging back to the start yields the base; commit is then a no-op', () {
      final s = sessionOn(null);
      final base = s.project;
      final tx = s.begin('Move clip');
      tx.update(MoveItems({p1}, f(10)));
      tx.update(MoveItems({p1}, 0));
      expect(identical(s.project, base), isTrue);
      expect(tx.commit().noop, isTrue);
      expect(s.history.length, 0);
      expect(s.project.meta.editCount, 0);
    });

    test('a refused update shows the base', () {
      final s = sessionOn(null);
      final base = s.project;
      final tx = s.begin('Trim');
      tx.update(MoveItems({p1}, f(10)));
      final r = tx.update(const TrimItem(ItemId('it_unknown'), TrimEdge.end, 0));
      expect(r.rejection, isA<ItemNotFound>());
      expect(identical(s.project, base), isTrue);
      expect(tx.preview!.rejection, isA<ItemNotFound>());
      expect(tx.commit().noop, isTrue);
      expect(s.history.length, 0);
    });

    test('cancel restores the base; a second begin cancels the first; apply/undo cancel too', () {
      final s = sessionOn(null);
      final base = s.project;
      final tx1 = s.begin('Drag 1');
      tx1.update(MoveItems({p1}, f(10)));
      tx1.cancel();
      expect(identical(s.project, base), isTrue);
      tx1.cancel();
      expect(tx1.commit().noop, isTrue, reason: 'commit after cancel does nothing');
      expect(tx1.update(MoveItems({p1}, f(5))).noop, isTrue);
      expect(identical(s.project, base), isTrue);

      final tx2 = s.begin('Drag 2');
      tx2.update(MoveItems({p1}, f(10)));
      final tx3 = s.begin('Drag 3');
      expect(tx2.isOpen, isFalse);
      expect(identical(s.project, base), isTrue);
      expect(identical(s.transaction, tx3), isTrue);

      tx3.update(MoveItems({p1}, f(10)));
      s.apply(const AddMarker(0));
      expect(tx3.isOpen, isFalse);
      expect(s.project.index.item(p1)!.start, f(30), reason: 'the gesture was cancelled');
      expect(s.history.length, 1);

      final tx4 = s.begin('Drag 4');
      tx4.update(MoveItems({p1}, f(10)));
      s.undo();
      expect(tx4.isOpen, isFalse);
      expect(sameSnapshot(s.project.timeline, base.timeline), isTrue);
    });

    test('pool changes and view updates keep the transaction open and are visible in it', () {
      final s = sessionOn(null);
      final tx = s.begin('Drag');
      tx.update(MoveItems({p1}, f(10)));
      s.applyPoolChange(AddAssets([asset('md_new', MediaKind.image)]));
      s.updateView((v) => v.copyWith(playhead: f(7)));
      expect(tx.isOpen, isTrue);
      expect(s.project.pool.contains(const MediaId('md_new')), isTrue);
      expect(s.project.view.playhead, f(7));
      expect(s.project.index.item(p1)!.start, f(40));
      tx.commit();
      expect(s.project.pool.contains(const MediaId('md_new')), isTrue);
      expect(s.project.view.playhead, f(7));
      s.undo();
      expect(s.project.pool.contains(const MediaId('md_new')), isTrue, reason: 'imports are sticky');
    });

    test('a transaction commit never coalesces with a typing run', () {
      final s = sessionOn(null);
      s.apply(const SetText(t1, 'x'), coalesceKey: 'text:$t1');
      final tx = s.begin('Move clip');
      tx.update(MoveItems({p1}, f(10)));
      tx.commit();
      s.apply(const SetText(t1, 'xy'), coalesceKey: 'text:$t1');
      expect(s.history.length, 3);
    });
  });

  group('pool changes and pool edits', () {
    final newVideo = asset('md_new', MediaKind.video, duration: sec(30), hasAudio: true);

    test('imports are sticky: undo never removes them', () {
      final s = sessionOn(null);
      s.applyPoolChange(AddAssets([newVideo]));
      final o = s.apply(InsertMedia([newVideo.id], f(300)));
      expect(o.changed, isTrue, reason: '$o');
      s.undo();
      expect(s.project.pool.contains(newVideo.id), isTrue);
      expectValid(s.project);
    });

    test('UpdateAsset replaces an existing asset and ignores unknown ones', () {
      final s = sessionOn(null);
      final doc = s.project.docRevision;
      final updated = basePool[const MediaId('md_video')]!.copyWith(status: const FailedStatus('x'));
      s.applyPoolChange(UpdateAsset(updated));
      expect(s.project.pool[updated.id], updated);
      s.applyPoolChange(UpdateAsset(newVideo));
      expect(s.project.pool.contains(newVideo.id), isFalse);
      expect(s.project.docRevision, doc + 1);
      expect(s.history.length, 0);
    });

    test('relink is undoable while later imports stay', () {
      final s = sessionOn(null);
      final old = s.project.pool[const MediaId('md_video')]!;
      final relinked = asset('md_video', MediaKind.video, duration: sec(60), hasAudio: true, hash: 'q-other', size: 2000);
      final o = s.applyPoolEdit(RelinkAssets({old.id: relinked}));
      expect(o.changed, isTrue);
      expect(o.affected, containsAll([a, b, const ItemId('it_a_au')]));
      expect(s.history.undoLabel, 'Relink media');
      expect(s.project.meta.editCount, 1);
      expect(s.project.pool[old.id], relinked);
      expect(s.entries.single.poolDelta, PoolDelta(before: {old.id: old}, after: {old.id: relinked}));

      s.applyPoolChange(AddAssets([newVideo]));
      s.undo();
      expect(s.project.pool[old.id], old);
      expect(s.project.pool.contains(newVideo.id), isTrue);
      s.redo();
      expect(s.project.pool[old.id], relinked);
      expect(s.project.pool.contains(newVideo.id), isTrue);
      expectValid(s.project);
    });

    test('relink refusals: unknown id, changed id, broken invariants; adjust fixes them in one entry', () {
      final s = sessionOn(null);
      final before = s.project;
      expect(s.applyPoolEdit(RelinkAssets({newVideo.id: newVideo})).rejection, MediaUnavailable(newVideo.id));
      expect(s.applyPoolEdit(RelinkAssets({const MediaId('md_video'): newVideo})).rejection, const InvalidValue('replacements'));
      final asAudio = asset('md_video', MediaKind.audio, duration: sec(60), hasAudio: true);
      expect(s.applyPoolEdit(RelinkAssets({asAudio.id: asAudio})).rejection, isA<InternalInconsistency>());
      // md_video2 (it_c uses 2 s of it) relinked to a 1 s file.
      final short = asset('md_video2', MediaKind.video, duration: sec(1), hasAudio: true, hash: 'q-short');
      expect(s.applyPoolEdit(RelinkAssets({short.id: short})).rejection, isA<InternalInconsistency>());
      expect(identical(s.project, before), isTrue);
      expect(s.history.length, 0);
      expect(s.applyPoolEdit(RelinkAssets({})).noop, isTrue);
      final same = before.pool[const MediaId('md_video')]!;
      expect(s.applyPoolEdit(RelinkAssets({same.id: same})).noop, isTrue);

      final o = s.applyPoolEdit(RelinkAssets({short.id: short}), adjust: TrimItem(c, TrimEdge.end, f(180)));
      expect(o.changed, isTrue, reason: '$o');
      expect(s.history.length, 1);
      expect(s.project.index.item(c)!.end, f(180));
      expect(s.project.pool[short.id], short);
      expectValid(s.project);
      s.undo();
      expect(s.project.index.item(c)!.end, f(210));
      expect(s.project.pool[short.id], before.pool[short.id]);
      expectValid(s.project);
    });

    test('remove only unused media; undo brings it back; retained while in history', () {
      final s = sessionOn(null, policy: const HistoryPolicy(maxEntries: 3));
      final rec = const MediaId('md_rec');
      final used = const MediaId('md_video');
      expect(s.applyPoolEdit(RemoveAssets({used})).rejection, const InvalidValue('mediaInUse'));
      expect(s.applyPoolEdit(RemoveAssets({const MediaId('md_nope')})).rejection, const MediaUnavailable(MediaId('md_nope')));
      expect(s.applyPoolEdit(RemoveAssets({})).noop, isTrue);

      final o = s.applyPoolEdit(RemoveAssets({rec}));
      expect(o.changed, isTrue);
      expect(s.history.undoLabel, 'Remove from project');
      expect(s.project.pool.contains(rec), isFalse);
      expect(s.retainedMedia(), contains(rec), reason: 'undo can bring it back');

      s.undo();
      expect(s.project.pool[rec], basePool[rec]);
      s.redo();
      expect(s.project.pool.contains(rec), isFalse);

      // Evict the remove entry: the asset is no longer retained.
      for (var i = 0; i < 3; i++) {
        s.apply(AddMarker(f(i)));
      }
      expect(s.entries.map((e) => e.label), everyElement('Add marker'));
      expect(s.retainedMedia(), isNot(contains(rec)));
    });

    test('a source of a derived asset that stays cannot be removed', () {
      final reversed = asset(
        'md_rev',
        MediaKind.video,
        duration: sec(5),
        derived: ReversedSpec(const MediaId('md_noaudio'), TimeRange(0, sec(5)), sourceQuickHash: 'q-md_noaudio'),
      );
      final s = sessionOn(null);
      s.applyPoolChange(AddAssets([reversed]));
      expect(s.applyPoolEdit(RemoveAssets({const MediaId('md_noaudio')})).rejection, const InvalidValue('mediaInUse'));
      expect(s.applyPoolEdit(RemoveAssets({const MediaId('md_noaudio'), reversed.id})).changed, isTrue);
    });

    test('a pool edit cancels an open transaction', () {
      final s = sessionOn(null);
      final tx = s.begin('Drag');
      tx.update(MoveItems({p1}, f(10)));
      s.applyPoolEdit(RemoveAssets({const MediaId('md_rec')}));
      expect(tx.isOpen, isFalse);
      expect(s.project.index.item(p1)!.start, f(30));
    });
  });

  group('retainedMedia', () {
    test('covers the current timeline, every snapshot, pool deltas, the pool and derived sources', () {
      final still = asset(
        'md_still',
        MediaKind.still,
        derived: StillSpec(const MediaId('md_video2'), sec(1), sourceQuickHash: 'q-md_video2'),
      );
      final s = sessionOn(null);
      s.applyPoolChange(AddAssets([still]));
      expect(s.retainedMedia(), containsAll(s.project.pool.assets.keys));

      // Remove md_video2 from the timeline, then the pool: it stays retained (history + derived).
      s.apply(DeleteItems({c}));
      s.applyPoolEdit(RemoveAssets({const MediaId('md_video2')}));
      // ...a derived still that stays blocks it.
      expect(s.history.length, 1);
      s.applyPoolEdit(RemoveAssets({still.id, const MediaId('md_video2')}));
      expect(s.project.pool.contains(const MediaId('md_video2')), isFalse);
      final r = s.retainedMedia();
      expect(r, containsAll([const MediaId('md_video2'), still.id]));
      expect(() => r.add(const MediaId('x')), throwsUnsupportedError);
    });

    test('mediaReferencedBy finds clips and imported LUT looks', () {
      final p = standard();
      expect(mediaReferencedBy(p.timeline),
          {const MediaId('md_video'), const MediaId('md_video2'), const MediaId('md_image'), const MediaId('md_music')});
      final s = sessionOn(p);
      final o = s.apply(SetLook({a}, const ImportedLut(MediaId('md_lut'))));
      expect(o.changed, isTrue, reason: '$o');
      expect(mediaReferencedBy(s.project.timeline), contains(const MediaId('md_lut')));
      expect(s.applyPoolEdit(RemoveAssets({const MediaId('md_lut')})).rejection, const InvalidValue('mediaInUse'));
      s.undo();
      expect(s.applyPoolEdit(RemoveAssets({const MediaId('md_lut')})).changed, isTrue);
      expect(s.retainedMedia(), contains(const MediaId('md_lut')), reason: 'redo of SetLook needs it');
    });
  });

  group('limits', () {
    test('eviction by count (200 by default), oldest first', () {
      final s = sessionOn(project([lane('tr_main', TrackKind.video, [], main: true)]));
      for (var i = 0; i < 205; i++) {
        s.apply(AddMarker(f(i), name: 'm$i'));
      }
      expect(s.history.length, 200);
      expect(s.history.position, 200);
      expect(s.project.meta.editCount, 205);
      var undos = 0;
      while (s.undo() != null) {
        undos++;
      }
      expect(undos, 200);
      expect(s.project.markers.length, 5, reason: 'the 5 oldest entries were evicted');
    });

    test('eviction by approximate bytes; the newest entry is always kept', () {
      final empty = project([lane('tr_main', TrackKind.video, [], main: true)]);
      final probe = sessionOn(empty)..apply(AddMarker(f(0)));
      final one = probe.historyBytes;
      expect(one, greaterThan(0));

      final s = sessionOn(empty, policy: HistoryPolicy(maxApproxBytes: one * 3 + one ~/ 2));
      for (var i = 0; i < 10; i++) {
        s.apply(AddMarker(f(i)));
        expect(s.historyBytes, lessThanOrEqualTo(s.historyPolicy.maxApproxBytes));
      }
      expect(s.history.length, lessThan(10));
      expect(s.historyBytes, s.entries.fold<int>(0, (sum, e) => sum + e.approxBytes));

      final tiny = sessionOn(empty, policy: const HistoryPolicy(maxApproxBytes: 1));
      tiny.apply(AddMarker(f(0)));
      tiny.apply(AddMarker(f(1)));
      expect(tiny.history.length, 1);
      expect(tiny.undo(), isNotNull);
    });

    test('approxEntryBytes counts changed lanes and new items only', () {
      final p = standard();
      final s = sessionOn(p);
      s.apply(MoveItems({p1}, f(10)));
      final move = s.entries.last.approxBytes;
      // entry + one lane + one slot + one new item.
      expect(move, 64 + 64 + 8 + 300);
      expect(approxEntryBytes(p.timeline, p.timeline), 64);
      expect(approxEntryBytes(p.timeline, p.timeline.copyWith(revision: 99)), 64);
      s.apply(const SetText(t1, 'changed'));
      expect(s.entries.last.approxBytes, 64 + 64 + 8 + 300);
      expect(s.historyBytes, 2 * (64 + 64 + 8 + 300));
    });

    test('the session keeps one LayerLimits and its edit policy', () {
      final s = sessionOn(null, editPolicy: const EditPolicy(maxItems: 8));
      expect(s.editPolicy.maxItems, 8);
      final o = s.apply(const AddMarker(0));
      expect(o.changed, isTrue);
      final r = s.apply(AddText(f(300)));
      expect(r.rejection, isA<LimitExceeded>());
      s.editPolicy = const EditPolicy();
      expect(s.apply(AddText(f(300))).changed, isTrue);
      expect(identical(s.limits, s.limits), isTrue);
      expect(s.limits.countsOf(s.project).exceeded(s.editPolicy), isEmpty);
    });
  });
}
