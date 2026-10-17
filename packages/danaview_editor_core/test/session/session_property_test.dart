// OWNER: CORE-19
//
// Property test of EditSession over random projects and random command / undo / redo / jump /
// transaction / pool-edit sequences: undo/redo identity against a model of committed snapshots,
// invariants at every history position (I4 included), strictly increasing stamps, editCount and
// history bookkeeping. (The full CORE-34 fuzzer builds on this.)

import 'dart:math';

import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';

import '../ops/framework/framework_test.dart' show randomCommand;
import '../ops/framework/ops_support.dart' show expectValid;
import '../support/random_project.dart';
import 'session_support.dart';

void main() {
  for (var seed = 0; seed < 30; seed++) {
    test('random session (seed $seed)', () {
      final r = Random(seed);
      final clock = FakeClock();
      final s = EditSession(
        randomProject(seed, const RandomProjectSpec(items: 30)),
        ids: SeededIdGenerator(900000 + seed),
        clock: clock.call,
      );
      // Model: committed snapshots; states[cursor] is the current one.
      final states = <Timeline>[s.project.timeline];
      var cursor = 0;
      var edits = 0;
      var lastRevision = s.project.revision;

      void checkRevision() {
        final rev = s.project.revision;
        expect(rev, greaterThanOrEqualTo(lastRevision));
        lastRevision = rev;
      }

      void push(Timeline t) {
        states
          ..removeRange(cursor + 1, states.length)
          ..add(t);
        cursor = states.length - 1;
        edits++;
      }

      for (var step = 0; step < 60; step++) {
        clock.advance(Duration(milliseconds: 200 + r.nextInt(2000)));
        final before = s.project;
        final roll = r.nextInt(10);
        if (roll < 4) {
          final o = s.apply(randomCommand(s.project, r));
          if (o.changed) {
            expect(s.project.revision, greaterThan(lastRevision));
            push(s.project.timeline);
          } else {
            expect(identical(s.project, before), isTrue);
          }
        } else if (roll < 6) {
          final st = s.undo();
          if (cursor == 0) {
            expect(st, isNull);
          } else {
            cursor--;
            expect(s.project.revision, greaterThan(lastRevision));
          }
        } else if (roll < 7) {
          final st = s.redo();
          if (cursor == states.length - 1) {
            expect(st, isNull);
          } else {
            cursor++;
            expect(s.project.revision, greaterThan(lastRevision));
          }
        } else if (roll < 8) {
          final n = r.nextInt(7) - 3;
          final target = (cursor + n).clamp(0, states.length - 1);
          final st = s.jump(n);
          expect(st == null, target == cursor);
          if (st != null) expect(st.steps, (target - cursor).abs());
          cursor = target;
        } else if (roll < 9) {
          final tx = s.begin('Gesture');
          final updates = 1 + r.nextInt(3);
          for (var i = 0; i < updates; i++) {
            tx.update(randomCommand(before, r));
            expectValid(s.project, 'transaction working copy');
          }
          final cancel = r.nextInt(4) == 0;
          if (cancel) {
            tx.cancel();
            expect(identical(s.project.timeline, before.timeline), isTrue);
          } else {
            final o = tx.commit();
            if (o.changed) push(s.project.timeline);
          }
        } else {
          final ids = s.project.pool.assets.keys.toList();
          if (ids.isNotEmpty) {
            final o = s.applyPoolEdit(RemoveAssets({ids[r.nextInt(ids.length)]}));
            if (o.changed) push(s.project.timeline);
          }
        }
        checkRevision();
        expect(sameSnapshot(s.project.timeline, states[cursor]), isTrue, reason: 'step $step');
        expect(s.history.position, cursor);
        expect(s.history.length, states.length - 1);
        expect(s.project.meta.editCount, edits);
        expectValid(s.project, 'step $step');
        expect(s.retainedMedia(), containsAll(s.project.pool.assets.keys));
      }

      expect(edits, greaterThan(5), reason: 'the sequence must exercise history');

      // Walk the whole history back and forth: identity and invariants at every position.
      while (s.undo() != null) {
        cursor--;
        expect(sameSnapshot(s.project.timeline, states[cursor]), isTrue);
        expectValid(s.project, 'undo walk');
      }
      expect(cursor, 0);
      while (s.redo() != null) {
        cursor++;
        expect(sameSnapshot(s.project.timeline, states[cursor]), isTrue);
        expectValid(s.project, 'redo walk');
      }
      expect(cursor, states.length - 1);
    });
  }
}
