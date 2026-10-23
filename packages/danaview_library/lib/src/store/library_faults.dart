// OWNER: HOM-17
//
// Crash-injection points of the writer and LibraryFs (BUILD_PLAN HOM-17: "a crash injected at every
// step of move, delete and import leaves the database and files consistent"). Production code uses
// [LibraryFaults.none]; tests pass an injector that throws [LibraryCrash] at a chosen step and then
// reopen the store as a fresh launch would.

/// Thrown by a test injector to simulate the process dying at a step. The writer doesn't roll back
/// on it; the connection is dropped as a crash would drop it.
final class LibraryCrash implements Exception {
  /// A crash at [step].
  const LibraryCrash(this.step);

  /// The step name.
  final String step;

  @override
  String toString() => 'LibraryCrash($step)';
}

/// Receives every named step of a multi-step write.
abstract interface class LibraryFaults {
  /// No injection.
  static const LibraryFaults none = _NoFaults();

  /// Called when [step] is reached; may throw [LibraryCrash].
  void hit(String step);
}

final class _NoFaults implements LibraryFaults {
  const _NoFaults();

  @override
  void hit(String step) {}
}
