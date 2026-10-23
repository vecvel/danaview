// OWNER: HOM-17
//
// The `library.db` migrations framework (ARCH v1.2 §5.3): pure, forward-only steps keyed by the
// version they lead to. A database without `meta` is created at the current version; a database
// newer than this build opens read-only (the v1.1 D-12 rule applied to the library). Each step and
// its version bump run in one transaction.

import 'package:sqlite3/sqlite3.dart';

import 'library_schema.dart';

/// One forward migration step to [toVersion].
final class LibraryMigration {
  /// A step that brings a database at `toVersion - 1` to [toVersion].
  const LibraryMigration(this.toVersion, this.statements);

  /// The schema version after this step.
  final int toVersion;

  /// The statements of the step, run in order inside one transaction.
  final List<String> statements;
}

/// Every step, in version order. Version 1 is the initial schema.
const List<LibraryMigration> libraryMigrations = [
  LibraryMigration(1, librarySchemaV1),
];

/// What opening and migrating a database found.
enum MigrationOutcome {
  /// A new database was created at [librarySchemaVersion].
  created,

  /// The database was already at [librarySchemaVersion].
  upToDate,

  /// One or more steps ran.
  migrated,

  /// The database is newer than this build: open it read-only and show the banner.
  newerReadOnly,
}

/// The `meta.schema_version` of [db], or null for an empty database (no `meta` table).
int? schemaVersionOf(Database db) {
  final hasMeta = db.select("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'meta'").isNotEmpty;
  if (!hasMeta) return null;
  final rows = db.select("SELECT value FROM meta WHERE key = 'schema_version'");
  if (rows.isEmpty) throw const FormatException('library.db has a meta table but no schema_version');
  final version = int.tryParse(rows.first['value'] as String? ?? '');
  if (version == null || version < 1) throw const FormatException('library.db has a malformed schema_version');
  return version;
}

/// Brings [db] to [librarySchemaVersion] with [migrations]. Never runs a step on a database newer
/// than this build. Throws [FormatException] for a malformed `meta` and lets SQLite errors through
/// (the store treats both as corruption).
MigrationOutcome migrateLibrary(Database db, {List<LibraryMigration> migrations = libraryMigrations}) {
  final target = migrations.isEmpty ? 0 : migrations.last.toVersion;
  final current = schemaVersionOf(db);
  if (current != null && current > target) return MigrationOutcome.newerReadOnly;
  if (current == target) return MigrationOutcome.upToDate;
  final from = current ?? 0;
  for (final step in migrations.where((m) => m.toVersion > from)) {
    db.execute('BEGIN IMMEDIATE');
    try {
      for (final statement in step.statements) {
        db.execute(statement);
      }
      db.execute("INSERT OR REPLACE INTO meta(key, value) VALUES ('schema_version', ?)", ['${step.toVersion}']);
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
  return current == null ? MigrationOutcome.created : MigrationOutcome.migrated;
}
