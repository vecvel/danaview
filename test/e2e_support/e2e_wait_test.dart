// OWNER: FIX-JOB-RESUME
//
// Host test of the E2E suite's bounded wait (integration_test/editor/support/e2e_wait.dart, used by
// `E2eApp.pumpUntil`): exceptions other than TestFailure inside a predicate fail the wait at once
// instead of turning into a timeout (QA-05 §2.3); lookups with nothing to find yet keep polling.

import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/editor/support/e2e_wait.dart';

void main() {
  var pumps = 0;
  Future<void> pump() async => pumps++;

  setUp(() => pumps = 0);

  Future<Object?> failureOf(Future<void> wait) async {
    try {
      await wait;
      return null;
    } on Object catch (e) {
      return e;
    }
  }

  test('returns once the predicate holds', () async {
    var n = 0;
    await E2eWait.until(pump, () => ++n >= 3, what: 'three polls', step: Duration.zero);
    expect(n, 3);
    expect(pumps, 3);
  });

  test('a StateError inside the predicate fails fast, not after the timeout', () async {
    final watch = Stopwatch()..start();
    final e = await failureOf(E2eWait.until(
      pump,
      () => throw StateError('the proxy failed after the relaunch'),
      what: 'the proxy',
      timeout: const Duration(seconds: 20),
    ));
    expect(e, isA<TestFailure>());
    expect((e! as TestFailure).message, allOf(startsWith('Waiting for the proxy failed'), contains('the proxy failed after the relaunch')));
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    expect(pumps, 1);
  });

  test('other exceptions (ArgumentError, custom, a failed cast) fail fast too', () async {
    for (final thrower in <bool Function()>[
      () => throw ArgumentError('bad'),
      () => throw const FormatException('nope'),
      () => throw _EngineBroke(),
      () => (Object() as String).isEmpty,
    ]) {
      pumps = 0;
      final e = await failureOf(E2eWait.until(pump, thrower, what: 'x', timeout: const Duration(seconds: 20)));
      expect(e, isA<TestFailure>());
      expect(pumps, 1);
    }
  });

  test('a TestFailure thrown by the predicate is rethrown unchanged', () async {
    final failure = TestFailure('the reverse asset failed: decodeFailed');
    final e = await failureOf(E2eWait.until(pump, () => throw failure, what: 'reverse'));
    expect(identical(e, failure), isTrue);
  });

  test('a lookup with nothing to find yet keeps polling until it resolves', () async {
    var items = <int>[];
    int? value;
    var n = 0;
    await E2eWait.until(pump, () {
      if (++n == 4) {
        items = [7];
        value = 7;
      }
      return items.firstWhere((i) => i == 7) == value! && items.single == 7;
    }, what: 'the row', step: Duration.zero);
    expect(n, 4);
  });

  test('retryOn widens what counts as not ready', () async {
    var n = 0;
    await E2eWait.until(
      pump,
      () => ++n < 3 ? throw _EngineBroke() : true,
      what: 'retry',
      step: Duration.zero,
      retryOn: (e) => e is _EngineBroke,
    );
    expect(n, 3);
  });

  test('a predicate that never holds times out with the description', () async {
    final e = await failureOf(E2eWait.until(
      pump,
      () => false,
      what: 'never',
      timeout: const Duration(milliseconds: 120),
      step: const Duration(milliseconds: 20),
      describe: () => 'screen texts: []',
    ));
    expect(e, isA<TestFailure>());
    expect((e! as TestFailure).message, allOf(startsWith('Timed out after 0 s waiting for never'), contains('screen texts: []')));
  });

  test('isNotReadyYet classifies lookups only', () {
    expect(E2eWait.isNotReadyYet(StateError('No element')), isTrue);
    expect(E2eWait.isNotReadyYet(StateError('Too many elements')), isTrue);
    expect(E2eWait.isNotReadyYet(StateError('Tried to use ExportController after dispose')), isFalse);
    int? missing;
    Object? nullCheck;
    try {
      missing!.isEven;
    } on Object catch (e) {
      nullCheck = e;
    }
    expect(E2eWait.isNotReadyYet(nullCheck!), isTrue);
    expect(E2eWait.isNotReadyYet(Exception('x')), isFalse);
  });
}

class _EngineBroke implements Exception {}
