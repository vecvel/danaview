// OWNER: CORE-23
//
// Test helper: renders a schema-1 body as the fictional schema 0 (the inverse of
// `testMigrationS0ToS1`, see lib/src/codec/migrations/s0_to_s1.dart), so the s0 -> s1 migration can
// be property-tested against random projects: `migrate(toS0(json)) == json`.

/// The schema-0 form of the schema-1 body [s1].
Map<String, Object?> toS0(Map<String, Object?> s1) {
  Object ms(int us) => us % 1000 == 0 ? us ~/ 1000 : us / 1000;
  final meta = (s1['meta'] as Map).cast<String, Object?>();
  final settings = Map<String, Object?>.of((s1['settings'] as Map).cast<String, Object?>());
  final out = <String, Object?>{
    for (final k in ['id', 'docRev', 'rev'])
      if (s1.containsKey(k)) k: s1[k],
    for (final k in ['name', 'created', 'updated', 'edits', 'origin'])
      if (meta.containsKey(k)) k: meta[k],
  };
  for (final k in ['fps', 'sampleRate']) {
    if (settings.containsKey(k)) out[k] = settings.remove(k);
  }
  out['settings'] = settings;
  out['tracks'] = [
    for (final t in (s1['tracks'] as List).cast<Map<String, Object?>>())
      {
        for (final e in t.entries)
          e.key: e.key == 'items'
              ? [
                  for (final i in (e.value! as List).cast<Map<String, Object?>>())
                    {
                      for (final f in i.entries)
                        if (f.key == 't')
                          'type': f.value
                        else if (f.key == 'start')
                          'startMs': ms(f.value! as int)
                        else if (f.key == 'dur')
                          'durMs': ms(f.value! as int)
                        else if (f.key == 'in')
                          'inMs': ms(f.value! as int)
                        else
                          f.key: f.value,
                    },
                ]
              : e.value,
      },
  ];
  out['markers'] = [
    for (final m in (s1['markers'] as List).cast<Map<String, Object?>>())
      {for (final e in m.entries) e.key == 'time' ? 'timeMs' : e.key: e.key == 'time' ? ms(e.value! as int) : e.value},
  ];
  out['pool'] = s1['pool'];
  out['view'] = {
    for (final e in (s1['view'] as Map).cast<String, Object?>().entries)
      if (e.key == 'playhead')
        'playheadMs': ms(e.value! as int)
      else if (e.key == 'scrollT')
        'scrollMs': ms(e.value! as int)
      else
        e.key: e.value,
  };
  return out;
}
