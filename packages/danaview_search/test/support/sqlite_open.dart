// OWNER: D-7 (S2, ARCH v1.2 V-S21)
//
// Host SQLite for the pure-Dart tests. `sqlite3` 2.x loads a native library from the host: macOS
// and Linux have one, a Windows host has only the OS copy `winsqlite3.dll`. Tests call
// [useHostSqlite] in `setUpAll` before they open a database; on Windows it points `sqlite3` at
// `winsqlite3.dll`, everywhere else it does nothing. Isolates the store spawns keep the package
// default, which on a Windows host without `sqlite3.dll` also opens `winsqlite3.dll`. Product code
// never uses winsqlite3: the app bundles SQLite through sqlite3_flutter_libs (D-7).

import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart';

/// Makes the test isolate open the host's SQLite (`winsqlite3.dll` on Windows; no-op elsewhere).
void useHostSqlite() {
  if (!Platform.isWindows) return;
  open.overrideFor(OperatingSystem.windows, _openWinSqlite3);
}

// Top-level, as `open.overrideFor` requires for openers used across isolates.
DynamicLibrary _openWinSqlite3() => DynamicLibrary.open('winsqlite3.dll');
