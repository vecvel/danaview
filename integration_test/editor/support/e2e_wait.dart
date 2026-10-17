// OWNER: FIX-JOB-RESUME
//
// The bounded wait under `E2eApp.pumpUntil` (QA-00 waiting rules), kept free of app imports so the
// host test (`test/e2e_support/e2e_wait_test.dart`) can run it without a device.
//
// A predicate that throws used to count as "not ready yet" for any exception, so a real failure
// inside a wait (a failed job, an unexpected state, a disposed controller) surfaced only as a
// timeout minutes later (QA-05 §2.3). Now:
//
// * `TestFailure` is rethrown as is;
// * a lookup that has nothing to find yet counts as "not ready": an iterable lookup with no (or
//   more than one) match (`StateError` "No element" / "Too many elements", from `single`, `first`,
//   `firstWhere`, ...) and a null check on a value that is not there yet (`x!`); a caller can widen
//   this with `retryOn`;
// * anything else fails the wait at once with a `TestFailure` naming the wait and the error.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart' show TestFailure;

/// Polls a condition with a deadline (see the file header for how exceptions are treated).
abstract final class E2eWait {
  /// Whether [error], thrown by a wait's predicate, only means "not there yet".
  static bool isNotReadyYet(Object error) {
    if (error is StateError) {
      final m = error.message;
      return m == 'No element' || m == 'Too many elements';
    }
    if (error is TypeError) return '$error'.contains('Null check operator used on a null value');
    return false;
  }

  /// Calls [pump], then [ready], until [ready] holds; fails after [timeout] naming [what] (with
  /// [describe]'s text when given). [retryOn] marks further exceptions as "not ready yet".
  static Future<void> until(
    Future<void> Function() pump,
    bool Function() ready, {
    required String what,
    Duration timeout = const Duration(seconds: 30),
    Duration step = const Duration(milliseconds: 50),
    bool Function(Object error)? retryOn,
    String Function()? describe,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      await pump();
      bool ok;
      try {
        ok = ready();
      } on TestFailure {
        rethrow;
      } on Object catch (e, s) {
        if (!isNotReadyYet(e) && !(retryOn?.call(e) ?? false)) {
          Error.throwWithStackTrace(TestFailure('Waiting for $what failed: ${e.runtimeType}: $e'), s);
        }
        ok = false;
      }
      if (ok) return;
      if (DateTime.now().isAfter(deadline)) {
        final screen = describe?.call();
        throw TestFailure('Timed out after ${timeout.inSeconds} s waiting for $what${screen == null ? '' : '\n$screen'}');
      }
      await Future<void>.delayed(step);
    }
  }
}
