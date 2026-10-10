// OWNER: CORE-26
//
// AutosaveScheduler on a fake clock: 2 s debounce, forced at 10 s, skipped while a transaction is
// open, one save at a time, failure then retry on the next trigger.

import 'dart:async';

import 'package:test/test.dart';
import 'package:vwish_editor_core/store.dart';

import '../repository/support/repo_support.dart';

void main() {
  late FakeTimers timers;
  late List<DateTime> saves;
  late bool paused;
  late AutosaveScheduler s;
  Object? failNext;
  Completer<void>? gate;

  setUp(() {
    timers = FakeTimers();
    saves = [];
    paused = false;
    failNext = null;
    gate = null;
    s = AutosaveScheduler(
      save: () async {
        saves.add(timers.now);
        final g = gate;
        if (g != null) await g.future;
        final f = failNext;
        failNext = null;
        if (f != null) throw f;
      },
      isPaused: () => paused,
      timer: timers.call,
      now: timers.clock,
    );
  });
  tearDown(() => s.dispose());

  DateTime at(int seconds) => DateTime.utc(2026, 10, 10, 9).add(Duration(seconds: seconds));

  test('debounced: saves 2 s after the last request', () async {
    s.request();
    await timers.elapse(const Duration(seconds: 1));
    s.request();
    await timers.elapse(const Duration(milliseconds: 1999));
    expect(saves, isEmpty);
    await timers.elapse(const Duration(milliseconds: 1));
    expect(saves, [at(3)]);
    expect(s.status.phase, AutosavePhase.saved);
    await timers.elapse(const Duration(seconds: 30));
    expect(saves, hasLength(1), reason: 'nothing new to save');
  });

  test('forced at 10 s while requests keep coming', () async {
    for (var i = 0; i < 25; i++) {
      s.request();
      await timers.elapse(const Duration(seconds: 1));
    }
    expect(saves.first, at(10));
    expect(saves[1], at(20));
    expect(saves, hasLength(2));
  });

  test('skipped while a transaction is open, retried an idle period later', () async {
    paused = true;
    s.request();
    await timers.elapse(const Duration(seconds: 2));
    expect(saves, isEmpty);
    await timers.elapse(const Duration(seconds: 6));
    expect(saves, isEmpty);
    paused = false;
    await timers.elapse(const Duration(seconds: 2));
    expect(saves, [at(10)]);
  });

  test('one save at a time; requests during a save schedule the next one', () async {
    gate = Completer<void>();
    s.request();
    await timers.elapse(const Duration(seconds: 2));
    expect(saves, hasLength(1));
    expect(s.status.phase, AutosavePhase.saving);
    s.request();
    await timers.elapse(const Duration(seconds: 5));
    expect(saves, hasLength(1), reason: 'the running save is not doubled');
    gate!.complete();
    gate = null;
    await settle();
    await timers.elapse(const Duration(seconds: 2));
    expect(saves, hasLength(2));
  });

  test('a failed save reports failed(StoreFailure); the next trigger retries', () async {
    final statuses = <AutosaveStatus>[];
    s.statuses.listen(statuses.add);
    failNext = const StoreFailure(StoreFailureKind.diskFull, 'test');
    s.request();
    await timers.elapse(const Duration(seconds: 2));
    expect(s.status.phase, AutosavePhase.failed);
    expect(s.status.failure!.kind, StoreFailureKind.diskFull);
    await timers.elapse(const Duration(seconds: 60));
    expect(saves, hasLength(1), reason: 'no retry loop without a trigger');
    s.request();
    await timers.elapse(const Duration(seconds: 2));
    expect(saves, hasLength(2));
    expect(s.status.phase, AutosavePhase.saved);
    expect(statuses.map((x) => x.phase), containsAllInOrder([AutosavePhase.pending, AutosavePhase.saving, AutosavePhase.failed, AutosavePhase.saving, AutosavePhase.saved]));
  });

  test('non-store errors are reported as io failures', () async {
    failNext = StateError('boom');
    s.request();
    await timers.elapse(const Duration(seconds: 2));
    expect(s.status.failure!.kind, StoreFailureKind.io);
  });

  test('flush saves a pending autosave at once (even paused); cancel drops it', () async {
    s.request();
    paused = true;
    await s.flush();
    expect(saves, hasLength(1));
    s.request();
    s.cancel();
    expect(s.hasPendingWork, isFalse);
    await timers.elapse(const Duration(seconds: 20));
    expect(saves, hasLength(1));
  });

  test('dispose stops future saves', () async {
    s.request();
    await s.dispose();
    s.request();
    await timers.elapse(const Duration(seconds: 20));
    expect(saves, isEmpty);
  });
}
