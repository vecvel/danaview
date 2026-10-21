// OWNER: HOM-17
//
// Opening `library.db` connections (ARCH v1.2 §5.3): the writer's read-write connection in WAL
// mode and the UI isolate's read-only one. sqlite3 2.x opens the platform SQLite (V-S21: iOS and
// macOS ship it; Android needs the app root to bundle one, see the HOM-17 report).

import 'package:sqlite3/sqlite3.dart';

/// Opens the read-write connection at [path] (created when missing), in WAL mode with a busy
/// timeout. Throws [SqliteException] for a file that isn't a database.
Database openLibraryWriteConnection(String path) {
  final db = sqlite3.open(path);
  try {
    db.execute('PRAGMA busy_timeout = 5000');
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA synchronous = NORMAL');
    return db;
  } catch (_) {
    db.dispose();
    rethrow;
  }
}

/// Opens a read-only connection at [path] for paged queries on the UI isolate.
Database openLibraryReadConnection(String path) {
  final db = sqlite3.open(path, mode: OpenMode.readOnly);
  try {
    db.execute('PRAGMA busy_timeout = 5000');
    db.execute('PRAGMA query_only = 1');
    return db;
  } catch (_) {
    db.dispose();
    rethrow;
  }
}

/// True when SQLite's quick check finds [db] intact.
bool libraryQuickCheck(Database db) {
  final rows = db.select('PRAGMA quick_check');
  return rows.length == 1 && rows.first.values.first == 'ok';
}
