// OWNER: CORE-23
//
// The test-only `s0 → s1` migration (ARCH §8.5: "v1 ships the framework plus a test-only
// `s0 → s1` migration"). Schema 0 never shipped: it is a fictional pre-release shape that differs
// from schema 1 in the ways real migrations do, so every part of the framework is exercised:
//
// | s0 | s1 |
// |---|---|
// | flat `name`, `created`, `updated`, `edits`, `origin` | `meta{name, created, updated, edits, origin}` |
// | flat `fps`, `sampleRate` | `settings{fps, sampleRate}` |
// | items: `type`, `startMs`, `durMs`, `inMs` | `t`, `start`, `dur`, `in` (integer µs = ms × 1000) |
// | markers: `timeMs` | `time` (µs) |
// | view: `playheadMs`, `scrollMs` | `playhead`, `scrollT` (µs) |
// | optional `settings`, `markers`, `pool`, `view` | always present (`{}` / `[]`) |
//
// Everything else (pool, per-item properties, unknown keys) is carried over untouched. The step is
// idempotent: an s1 body, or an s0 body it already converted, comes back equal.
//
// It is exported by the codec barrel so the repository tests (CORE-25) and the QA fixtures can
// register it with `Migrations([testMigrationS0ToS1], ...)`; it is **not** part of
// [Migrations.standard].

part of 'migrations.dart';

/// The test-only migration from the fictional schema 0 to schema 1 (see the file header).
const MigrationStep testMigrationS0ToS1 = MigrationStep(from: 0, name: 's0-to-s1', apply: _s0ToS1);

/// A [Migrations] whose chain is only [testMigrationS0ToS1] (target schema 1).
Migrations testMigrationsS0ToS1() => Migrations(const [testMigrationS0ToS1]);

Map<String, Object?> _s0ToS1(Map<String, Object?> body) {
  const metaKeys = ['name', 'created', 'updated', 'edits', 'origin'];
  const settingsKeys = ['fps', 'sampleRate'];

  final meta = _mapOrNew(body, 'meta');
  for (final k in metaKeys) {
    if (body.containsKey(k) && !meta.containsKey(k)) meta[k] = body[k];
    body.remove(k);
  }
  final settings = _mapOrNew(body, 'settings');
  for (final k in settingsKeys) {
    if (body.containsKey(k) && !settings.containsKey(k)) settings[k] = body[k];
    body.remove(k);
  }

  final tracks = body['tracks'];
  if (tracks is List) {
    for (final track in tracks) {
      if (track is! Map) continue;
      final items = track['items'];
      if (items is! List) continue;
      for (final item in items) {
        if (item is Map<String, Object?>) {
          _rename(item, 'type', 't');
          _msToUs(item, 'startMs', 'start');
          _msToUs(item, 'durMs', 'dur');
          _msToUs(item, 'inMs', 'in');
        }
      }
    }
  }
  final markers = body['markers'];
  if (markers is List) {
    for (final m in markers) {
      if (m is Map<String, Object?>) _msToUs(m, 'timeMs', 'time');
    }
  }
  final view = _mapOrNew(body, 'view');
  _msToUs(view, 'playheadMs', 'playhead');
  _msToUs(view, 'scrollMs', 'scrollT');

  // Fixed s1 key order; keys this step does not know follow (decoders ignore them).
  const order = ['id', 'docRev', 'rev', 'meta', 'settings', 'tracks', 'markers', 'pool', 'view'];
  final out = <String, Object?>{
    for (final k in order)
      if (k == 'settings' || k == 'view' || k == 'pool' || k == 'meta') k: body[k] ?? <String, Object?>{}
      else if (k == 'tracks' || k == 'markers') k: body[k] ?? <Object?>[]
      else if (body.containsKey(k)) k: body[k],
  };
  for (final e in body.entries) {
    out.putIfAbsent(e.key, () => e.value);
  }
  return out;
}

Map<String, Object?> _mapOrNew(Map<String, Object?> parent, String key) {
  final v = parent[key];
  if (v is Map<String, Object?>) return v;
  final fresh = <String, Object?>{};
  parent[key] = fresh;
  return fresh;
}

void _rename(Map<String, Object?> m, String from, String to) {
  if (!m.containsKey(from)) return;
  final v = m.remove(from);
  m.putIfAbsent(to, () => v);
}

void _msToUs(Map<String, Object?> m, String from, String to) {
  if (!m.containsKey(from)) return;
  final v = m.remove(from);
  if (m.containsKey(to)) return;
  if (v is int) {
    m[to] = v * 1000;
  } else if (v is double && v.isFinite) {
    m[to] = (v * 1000).round();
  } else {
    throw ProjectFormatException('expected a number of milliseconds', from);
  }
}
