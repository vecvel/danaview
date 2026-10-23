// OWNER: HOM-17
//
// The `library.db` schema v1 and migrations framework (ARCH v1.2 §5.3): created at the current
// version, idempotent, forward-only steps in one transaction each, a failing step rolls back, a
// newer database is left alone (read-only), the recents trigger caps at 50, and row mapping keeps
// unknown kind strings (1.3.0 `savedCode`).

import 'package:danaview_library/danaview_library.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../support/sqlite_open.dart';

void main() {
  setUpAll(useHostSqlite);
  late Database db;
  setUp(() => db = sqlite3.openInMemory());
  tearDown(() => db.dispose());

  test('an empty database is created at schema v1 with every table and index of §5.3', () {
    expect(migrateLibrary(db), MigrationOutcome.created);
    expect(schemaVersionOf(db), librarySchemaVersion);
    final names = {for (final r in db.select('SELECT name FROM sqlite_master')) r['name'] as String};
    expect(names, containsAll(['meta', 'folders', 'entries', 'entry_meta', 'recents', 'import_jobs', 'refs', 'recents_cap']));
    expect(names, containsAll(['entries_folder', 'entries_kind', 'entries_added', 'entries_name', 'folders_parent']));
    expect(migrateLibrary(db), MigrationOutcome.upToDate);
  });

  test('steps run forward only, each in one transaction', () {
    const steps = [
      LibraryMigration(1, librarySchemaV1),
      LibraryMigration(2, ['ALTER TABLE entries ADD COLUMN extra TEXT']),
    ];
    expect(migrateLibrary(db), MigrationOutcome.created);
    expect(migrateLibrary(db, migrations: steps), MigrationOutcome.migrated);
    expect(schemaVersionOf(db), 2);
    expect(migrateLibrary(db, migrations: steps), MigrationOutcome.upToDate);

    const failing = [...steps, LibraryMigration(3, ['CREATE TABLE t3(x)', 'THIS IS NOT SQL'])];
    expect(() => migrateLibrary(db, migrations: failing), throwsA(isA<SqliteException>()));
    expect(schemaVersionOf(db), 2);
    expect(db.select("SELECT 1 FROM sqlite_master WHERE name = 't3'"), isEmpty, reason: 'rolled back');
  });

  test('a newer database is never migrated', () {
    migrateLibrary(db);
    db.execute("UPDATE meta SET value = '7' WHERE key = 'schema_version'");
    expect(migrateLibrary(db), MigrationOutcome.newerReadOnly);
    expect(schemaVersionOf(db), 7);
  });

  test('a malformed meta is a FormatException (the store treats it as corruption)', () {
    db.execute('CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT)');
    expect(() => migrateLibrary(db), throwsFormatException);
    db.execute("INSERT INTO meta VALUES ('schema_version', 'x')");
    expect(() => migrateLibrary(db), throwsFormatException);
  });

  test('the recents trigger keeps the 50 newest', () {
    migrateLibrary(db);
    for (var i = 0; i < 60; i++) {
      db.execute('INSERT OR REPLACE INTO recents VALUES (?, ?)', ['fe_$i', i]);
    }
    final rows = db.select('SELECT opened_at FROM recents ORDER BY opened_at');
    expect(rows.length, recentsCap);
    expect(rows.first['opened_at'], 10);
  });

  test('rows map losslessly, unknown kinds included', () {
    migrateLibrary(db);
    final folder = FolderId.random();
    db.execute("INSERT INTO folders(id, name, created_at, modified_at, system_role) VALUES (?, 'Imported', 1, 2, 'imported')", [folder.value]);
    final entry = EntryId.random();
    db.execute(
      'INSERT INTO entries(id, folder_id, display_name, kind, size_bytes, added_at, modified_at, source_hint, is_favourite) '
      "VALUES (?, ?, 'code.png', 'savedCode', 5, 10, 20, 'futureSource', 1)",
      [entry.value, folder.value],
    );
    db.execute('INSERT INTO entry_meta(entry_id, width, height, duration_us, flags) VALUES (?, 4000, 3000, 1500000, 5)', [entry.value]);
    final reader = LibraryReader(db);
    final e = reader.entry(entry)!;
    expect((e.kind, e.kindCode, e.sourceHint, e.isFavourite), (FileKind.other, 'savedCode', SourceHint.unknown, true));
    expect(reader.entriesPage(const EntryQuery(kinds: {FileKind.other})).single.id, entry);
    expect(reader.entriesPage(const EntryQuery(kinds: {FileKind.photo})), isEmpty);
    final meta = reader.meta(entry)!;
    expect((meta.width, meta.duration, meta.flags & EntryMeta.flagLive), (4000, const Duration(milliseconds: 1500), EntryMeta.flagLive));
    final f = reader.folder(folder)!;
    expect((f.systemRole, f.isSystem, f.createdAt.millisecondsSinceEpoch), (FolderSystemRole.imported, true, 1));
  });

  test('days left rounds up and never goes negative', () {
    final expires = DateTime.utc(2026, 1, 31);
    expect(daysLeftUntil(expires, DateTime.utc(2026, 1, 1)), 30);
    expect(daysLeftUntil(expires, DateTime.utc(2026, 1, 30, 23)), 1);
    expect(daysLeftUntil(expires, DateTime.utc(2026, 2, 5)), 0);
  });
}
