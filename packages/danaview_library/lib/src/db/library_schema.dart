// OWNER: HOM-17
//
// `library.db` schema v1 (ARCH v1.2 §5.3). Times are INT milliseconds since the epoch (UTC); bools
// are 0/1. The recents cap of 50 is a trigger. Two extra indexes beyond §5.3's list back the paged
// Home queries (`entries(trashed_at, added_at)`) and the Recently deleted view
// (`folders(trashed_at)`); they change no column.

/// The `library.db` schema version this build writes (`meta.schema_version`).
const int librarySchemaVersion = 1;

/// The number of files Recents keeps (HOM plan §8.1, D-98f).
const int recentsCap = 50;

/// The schema v1 statements, in order (ARCH v1.2 §5.3).
const List<String> librarySchemaV1 = [
  'CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT)',
  'CREATE TABLE folders(id TEXT PRIMARY KEY, parent_id TEXT NULL REFERENCES folders, name TEXT NOT NULL, '
      'created_at INT NOT NULL, modified_at INT NOT NULL, is_favourite INT NOT NULL DEFAULT 0, sort_mode TEXT, '
      'sort_desc INT NOT NULL DEFAULT 0, system_role TEXT NULL, trashed_at INT NULL, expires_at INT NULL)',
  'CREATE TABLE entries(id TEXT PRIMARY KEY, folder_id TEXT NOT NULL REFERENCES folders, display_name TEXT NOT NULL, '
      'kind TEXT NOT NULL, sub_kind TEXT, mime TEXT, uti TEXT, ext TEXT, size_bytes INT NOT NULL, quick_hash TEXT, '
      'content_sha256 TEXT NULL, added_at INT NOT NULL, modified_at INT NOT NULL, last_opened_at INT NULL, '
      'is_favourite INT NOT NULL DEFAULT 0, source_hint TEXT NOT NULL, trashed_at INT NULL, expires_at INT NULL, '
      'trashed_from_folder TEXT NULL)',
  'CREATE TABLE entry_meta(entry_id TEXT PRIMARY KEY, width INT, height INT, duration_us INT, fps REAL, codec TEXT, '
      'page_count INT, taken_at INT, camera TEXT, flags INT)',
  'CREATE TABLE recents(entry_id TEXT PRIMARY KEY, opened_at INT NOT NULL)',
  'CREATE TABLE import_jobs(id TEXT PRIMARY KEY, source_desc TEXT, target_folder TEXT, bytes_total INT, '
      'bytes_done INT, state TEXT, part_path TEXT, created_at INT)',
  'CREATE TABLE refs(entry_id TEXT NOT NULL, holder TEXT NOT NULL, PRIMARY KEY(entry_id, holder))',
  'CREATE INDEX entries_folder ON entries(folder_id, trashed_at)',
  'CREATE INDEX entries_kind ON entries(kind, sub_kind)',
  'CREATE INDEX entries_added ON entries(added_at)',
  'CREATE INDEX entries_name ON entries(display_name COLLATE NOCASE)',
  'CREATE INDEX entries_live_added ON entries(trashed_at, added_at)',
  'CREATE INDEX folders_parent ON folders(parent_id)',
  'CREATE INDEX folders_trashed ON folders(trashed_at)',
  'CREATE INDEX recents_opened ON recents(opened_at)',
  'CREATE TRIGGER recents_cap AFTER INSERT ON recents BEGIN '
      'DELETE FROM recents WHERE entry_id NOT IN (SELECT entry_id FROM recents ORDER BY opened_at DESC, entry_id LIMIT $recentsCap); '
      'END',
];
