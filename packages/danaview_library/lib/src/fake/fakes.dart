// OWNER: HOM-17
//
// Test doubles of the library store (ARCH v1.2 §12.1), exported only by lib/testing.dart: a fake
// clock for the 30-day expiry, a recording backup-flag port, and fault injectors that count the
// steps of a write or crash at one of them.

/// Fakes of the library store and database (ARCH v1.2 §12.1).
library;

import '../store/backup_flags.dart';
import '../store/library_faults.dart';

/// A clock tests move by hand (also backwards). Pass [call] as `LibraryStore.open(clock: …)`.
final class FakeLibraryClock {
  /// A clock at [start] (UTC).
  FakeLibraryClock(DateTime start) : _now = start.toUtc();

  DateTime _now;

  /// The current time.
  DateTime call() => _now;

  /// Moves the clock by [delta] (negative moves it back).
  void advance(Duration delta) => _now = _now.add(delta);

  /// Sets the clock to [time].
  void set(DateTime time) => _now = time.toUtc();
}

/// A backup-flag port that records every call.
final class RecordingBackupFlagPort implements BackupFlagPort {
  /// The calls, as `(path, excluded)`.
  final List<(String, bool)> calls = [];

  @override
  Future<void> setExcludedFromBackup(String path, {required bool excluded}) async => calls.add((path, excluded));
}

/// Records every step a write reaches.
final class RecordingFaults implements LibraryFaults {
  /// The steps, in order.
  final List<String> steps = [];

  @override
  void hit(String step) => steps.add(step);
}

/// Throws [LibraryCrash] at the [index]th step reached (0-based), once.
final class CrashAtStep implements LibraryFaults {
  /// Crashes at step [index] once armed.
  CrashAtStep(this.index);

  /// The step to crash at.
  final int index;

  /// Steps are counted only while armed (so setup writes don't count).
  bool armed = false;

  int _seen = 0;

  /// True once the crash happened.
  bool crashed = false;

  @override
  void hit(String step) {
    if (!armed || crashed) return;
    if (_seen++ == index) {
      crashed = true;
      throw LibraryCrash(step);
    }
  }
}
