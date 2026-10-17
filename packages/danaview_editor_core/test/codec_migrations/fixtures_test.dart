// OWNER: CORE-23
//
// Every schema keeps `test/fixtures/projects/s<N>/` files that must migrate, validate, re-encode
// and round-trip (ARCH §8.5). This test walks every committed fixture through the whole open path:
// header classification (from the header alone) -> checksum verification -> migration chain ->
// JSON-schema validation of the migrated body -> decode -> re-encode -> decode again.
//
// Set `REGENERATE_FIXTURES=1` to rebuild the committed `.dnproj` files from the `.body.json`
// sources; otherwise a test checks they are up to date.

import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:json_schema/json_schema.dart';
import 'package:test/test.dart';
import 'package:danaview_editor_core/codec.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/store.dart';

import 'support/fixtures.dart';

void main() {
  if (Platform.environment['REGENERATE_FIXTURES'] == '1') {
    test('regenerate fixtures', regenerate);
    return;
  }

  final schema = JsonSchema.create(
    jsonDecode(File('schema/project.v1.schema.json').readAsStringSync()) as Object,
    schemaVersion: SchemaVersion.draft2020_12,
  );
  // Today's chain is the test-only s0 -> s1. When schema 2 lands, the chain becomes
  // `Migrations.standard` (+ this step for the s0 fixtures) and s2 fixtures are added to allFixtures.
  final migrations = testMigrationsS0ToS1();
  final codec = ProjectJsonCodec();

  test('every schema directory is covered by allFixtures', () {
    final onDisk = {
      for (final dir in Directory(projectFixtureRoot).listSync().whereType<Directory>())
        for (final f in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.dnproj'))) f.path.replaceAll(r'\', '/'),
    };
    expect(onDisk, allFixtures.map((f) => f.documentPath).toSet());
    for (final s in allFixtures) {
      expect(File(s.bodyPath).existsSync(), isTrue, reason: '${s.bodyPath} is the readable source of ${s.documentPath}');
    }
  });

  group('committed documents are up to date', () {
    for (final spec in allFixtures) {
      test('s${spec.schema}/${spec.name}.dnproj', () {
        expect(readDocument(spec), expectedDocument(spec), reason: 'run with REGENERATE_FIXTURES=1 after editing a .body.json');
      });
    }
  });

  group('open path', () {
    for (final spec in allFixtures) {
      test('s${spec.schema}/${spec.name} migrates, validates, re-encodes and round-trips', () {
        final bytes = readDocument(spec);

        // Header alone decides what to do with it.
        final compat = migrations.classifyDocument(bytes);
        expect(compat, spec.schema == 0 ? SchemaCompatibility.needsMigration : SchemaCompatibility.current);

        final doc = DnprojFormat.parse(bytes);
        expect(doc.header.schema, spec.schema);
        final body = jsonDecode(utf8.decode(doc.body)) as Map<String, Object?>;

        final result = migrations.migrate(body, from: doc.header.schema);
        expect(result.toSchema, currentProjectSchema);
        expect(result.migratedFrom, spec.schema == 0 ? 0 : isNull);
        expect(result.needsPreMigrationBackup, spec.schema == 0);

        final check = schema.validate(result.body);
        expect(check.isValid, isTrue, reason: check.errors.take(8).join('\n'));

        final decoded = codec.decodeJson(result.body);
        expect(decoded.warnings, isEmpty);
        final project = decoded.project;

        final reencoded = codec.encode(project);
        expect(codec.encode(codec.decode(reencoded).project), reencoded, reason: 'canonical encoding is a fixed point');
        expect(codec.decode(reencoded).project, project, reason: 'decode(encode(p)) == p');
        final reparsed = jsonDecode(reencoded);
        expect(schema.validate(reparsed).isValid, isTrue);
      });
    }
  });

  test('s0/rich migrates to exactly the CORE-22 kitchen sink body', () {
    final s0 = jsonDecode(File('$projectFixtureRoot/s0/rich.body.json').readAsStringSync()) as Map<String, Object?>;
    final s1 = jsonDecode(File('$projectFixtureRoot/s1/kitchen_sink.body.json').readAsStringSync()) as Map<String, Object?>;
    final migrated = migrations.migrate(s0, from: 0).body;
    expect(const DeepCollectionEquality().equals(migrated, s1), isTrue);
    final project = codec.decodeJson(migrated).project;
    expect(project, codec.decodeJson(s1).project);
    // The project validator sees the same project (the golden fixture is a codec fixture, not a
    // valid editing session, so compare verdicts rather than expecting none).
    expect(validate(project).map((v) => v.toString()), validate(codec.decodeJson(s1).project).map((v) => v.toString()));
  });

  test('s0/minimal migrates to the empty s1 project', () {
    final s0 = jsonDecode(File('$projectFixtureRoot/s0/minimal.body.json').readAsStringSync()) as Map<String, Object?>;
    final migrated = migrations.migrate(s0, from: 0).body;
    expect(migrated.keys, ['id', 'meta', 'settings', 'tracks', 'markers', 'pool', 'view']);
    final p1 = codec.decodeJson(migrated).project;
    expect(p1.meta.name, 'Untitled');
    expect(p1.tracks, isEmpty);
  });

  test('s0/fractional keeps sub-millisecond precision (ms doubles -> integer µs)', () {
    final s0 = jsonDecode(File('$projectFixtureRoot/s0/fractional.body.json').readAsStringSync()) as Map<String, Object?>;
    final migrated = migrations.migrate(s0, from: 0).body;
    final items = ((migrated['tracks']! as List).single as Map<String, Object?>)['items']! as List;
    final first = items.first as Map<String, Object?>;
    expect(first['dur'], 1041667);
    expect(first['in'], 41708);
    expect((items[1] as Map<String, Object?>)['start'], 1041667);
    expect((migrated['view']! as Map<String, Object?>)['playhead'], 41708);
    expect(((migrated['markers']! as List).single as Map<String, Object?>)['time'], 1041667);
  });
}
