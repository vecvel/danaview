// OWNER: CORE-23
//
// The migration framework (ARCH §8.5, D-12): header-only classification, the chain runner,
// idempotence, input immutability and "opening never writes".

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:test/test.dart';
import 'package:danaview_editor_core/codec.dart';
import 'package:danaview_editor_core/store.dart';

import '../codec/support/codec_projects.dart';
import 'support/fixtures.dart';
import 'support/s0_writer.dart';

const _eq = DeepCollectionEquality();

/// Header bytes with [schema]/[minReader] followed by [tail] (arbitrary bytes, never parsed).
Uint8List _document({required int schema, required int minReader, List<int> tail = const [], Map<String, Object?> extra = const {}}) {
  final header = <String, Object?>{'format': projectFormatName, 'schema': schema, 'minReader': minReader, ...extra};
  return Uint8List.fromList([...utf8.encode(jsonEncode(header)), 0x0A, ...tail]);
}

Map<String, Object?> _snapshot(Map<String, Object?> m) => jsonDecode(jsonEncode(m)) as Map<String, Object?>;

void main() {
  group('classification (D-12), from the header alone', () {
    final standard = Migrations.standard;
    final withS0 = testMigrationsS0ToS1();

    test('schema equals the build: current', () {
      expect(standard.classify(schema: 1, minReader: 1), SchemaCompatibility.current);
    });

    test('newer schema, minReader readable: read-only', () {
      expect(standard.classify(schema: 2, minReader: 1), SchemaCompatibility.readOnlyNewer);
      expect(standard.classify(schema: 9, minReader: 1), SchemaCompatibility.readOnlyNewer);
      expect(standard.classify(schema: 3, minReader: 0), SchemaCompatibility.readOnlyNewer);
    });

    test('minReader above the build: needs a newer app, even when schema equals', () {
      expect(standard.classify(schema: 2, minReader: 2), SchemaCompatibility.needsNewerApp);
      expect(standard.classify(schema: 7, minReader: 5), SchemaCompatibility.needsNewerApp);
      expect(standard.classify(schema: 1, minReader: 2), SchemaCompatibility.needsNewerApp);
    });

    test('older schema: migratable only when the chain reaches it', () {
      expect(withS0.classify(schema: 0, minReader: 0), SchemaCompatibility.needsMigration);
      expect(standard.classify(schema: 0, minReader: 0), SchemaCompatibility.unsupportedOld);
    });

    test('classifyHeader uses schema and minReader of a ProjectHeader', () {
      final body = Uint8List.fromList(utf8.encode('{}'));
      ProjectHeader header(int schema, int minReader) => ProjectHeader.forBody(body,
          app: '9.0.0+1', savedAt: DateTime.utc(2027), docRevision: 1, saveId: 'sv_x', schema: schema, minReader: minReader);
      expect(standard.classifyHeader(header(1, 1)), SchemaCompatibility.current);
      expect(standard.classifyHeader(header(4, 1)), SchemaCompatibility.readOnlyNewer);
      expect(standard.classifyHeader(header(4, 3)), SchemaCompatibility.needsNewerApp);
    });

    test('a newer document is classified without parsing its body (garbage, invalid UTF-8, huge)', () {
      final garbage = [0xFF, 0xFE, 0x00, ...utf8.encode('{"not json'), ...List.filled(1 << 20, 0xC3)];
      expect(standard.classifyDocument(_document(schema: 5, minReader: 1, tail: garbage)), SchemaCompatibility.readOnlyNewer);
      expect(standard.classifyDocument(_document(schema: 5, minReader: 4, tail: garbage)), SchemaCompatibility.needsNewerApp);
      // A prefix that ends right after the header's newline is enough.
      expect(standard.classifyDocument(_document(schema: 2, minReader: 1)), SchemaCompatibility.readOnlyNewer);
    });

    test('a newer app may have changed everything in the header except format, schema, minReader', () {
      final doc = _document(schema: 6, minReader: 1, extra: {'app': 99, 'bodySha256': 'sha3:xyz', 'compression': 'zstd', 'savedAt': null});
      expect(() => ProjectHeader.readFrom(doc), throwsA(isA<ProjectFormatException>()), reason: 'the strict header parser rejects it');
      expect(standard.classifyDocument(doc), SchemaCompatibility.readOnlyNewer);
    });

    test('malformed headers throw ProjectFormatException', () {
      expect(() => standard.classifyDocument(Uint8List.fromList(utf8.encode('{"format":"danaview.editor.project"}'))), throwsA(isA<ProjectFormatException>()), reason: 'no newline');
      expect(() => standard.classifyDocument(Uint8List.fromList(utf8.encode('not json\n'))), throwsA(isA<ProjectFormatException>()));
      expect(() => standard.classifyDocument(Uint8List.fromList([0xFF, 0xFF, 0x0A])), throwsA(isA<ProjectFormatException>()));
      expect(() => standard.classifyDocument(Uint8List.fromList(utf8.encode('{"format":"other","schema":1,"minReader":1}\n'))), throwsA(isA<ProjectFormatException>()));
      expect(() => standard.classifyDocument(Uint8List.fromList(utf8.encode('{"format":"danaview.editor.project","schema":-1,"minReader":1}\n'))), throwsA(isA<ProjectFormatException>()));
      expect(() => standard.classifyDocument(Uint8List.fromList(utf8.encode('{"format":"danaview.editor.project","schema":"1","minReader":1}\n'))), throwsA(isA<ProjectFormatException>()));
      expect(() => standard.classifyDocument(Uint8List.fromList(utf8.encode('[1,2]\n'))), throwsA(isA<ProjectFormatException>()));
    });

    test('a real committed document classifies as current', () {
      expect(standard.classifyDocument(File('test/codec/fixtures/kitchen_sink.dnproj').readAsBytesSync()), SchemaCompatibility.current);
    });
  });

  group('the chain runner', () {
    // A synthetic three-step chain: s0 -> s1 (the real test step), s1 -> s2 (rename), s2 -> s3 (add).
    final s1ToS2 = MigrationStep(
      from: 1,
      name: 's1-to-s2',
      apply: (b) {
        final meta = b['meta']! as Map<String, Object?>;
        if (meta.containsKey('name')) meta['title'] = meta.remove('name');
        return b;
      },
    );
    final s2ToS3 = MigrationStep(
      from: 2,
      name: 's2-to-s3',
      apply: (b) {
        b.putIfAbsent('extra', () => 3);
        return b;
      },
    );
    final chain3 = Migrations([s2ToS3, testMigrationS0ToS1, s1ToS2], target: 3); // unordered on purpose

    test('steps are ordered by from and applied in sequence from the document schema', () {
      expect(chain3.chain.map((s) => s.name), ['s0-to-s1', 's1-to-s2', 's2-to-s3']);
      final s0 = jsonDecode(File('$projectFixtureRoot/s0/minimal.body.json').readAsStringSync()) as Map<String, Object?>;
      final r0 = chain3.migrate(s0, from: 0);
      expect(r0.applied, ['s0-to-s1', 's1-to-s2', 's2-to-s3']);
      expect(r0.fromSchema, 0);
      expect(r0.toSchema, 3);
      expect((r0.body['meta']! as Map)['title'], 'Untitled');
      expect(r0.body['extra'], 3);

      final s1 = jsonDecode(File('$projectFixtureRoot/s1/minimal.body.json').readAsStringSync()) as Map<String, Object?>;
      final r1 = chain3.migrate(s1, from: 1);
      expect(r1.applied, ['s1-to-s2', 's2-to-s3']);

      final r3 = chain3.migrate(s1, from: 3);
      expect(r3.applied, isEmpty);
      expect(r3.migrated, isFalse);
      expect(r3.migratedFrom, isNull);
      expect(identical(r3.body, s1), isTrue, reason: 'nothing to do: the same map comes back');
    });

    test('classification follows the target of the chain', () {
      expect(chain3.classify(schema: 0, minReader: 0), SchemaCompatibility.needsMigration);
      expect(chain3.classify(schema: 2, minReader: 1), SchemaCompatibility.needsMigration);
      expect(chain3.classify(schema: 3, minReader: 3), SchemaCompatibility.current);
      expect(chain3.classify(schema: 4, minReader: 3), SchemaCompatibility.readOnlyNewer);
      expect(chain3.classify(schema: 4, minReader: 4), SchemaCompatibility.needsNewerApp);
      expect(chain3.oldestMigratable, 0);
      expect(Migrations.standard.oldestMigratable, currentProjectSchema);
    });

    test('the caller\'s body is never modified and the result shares nothing with it', () {
      final s0 = jsonDecode(File('$projectFixtureRoot/s0/rich.body.json').readAsStringSync()) as Map<String, Object?>;
      final before = _snapshot(s0);
      final result = chain3.migrate(s0, from: 0);
      expect(_eq.equals(s0, before), isTrue, reason: 'input unchanged');
      // Mutating the result must not leak into the input (deep copy).
      final tracks = result.body['tracks']! as List;
      ((tracks.first as Map<String, Object?>)['items']! as List).clear();
      expect(_eq.equals(s0, before), isTrue);
    });

    test('result metadata: migratedFrom, needsPreMigrationBackup and the backup file name', () {
      final s0 = jsonDecode(File('$projectFixtureRoot/s0/minimal.body.json').readAsStringSync()) as Map<String, Object?>;
      final result = testMigrationsS0ToS1().migrate(s0, from: 0);
      expect(result.migrated, isTrue);
      expect(result.migratedFrom, 0);
      expect(result.needsPreMigrationBackup, isTrue);
      expect(result.preMigrationBackupName, 'pre-migration-s0.dnproj');
      expect(Migrations.preMigrationBackupName(7), 'pre-migration-s7.dnproj');
      final m = testMigrationsS0ToS1();
      expect(m.needsPreMigrationBackup(0), isTrue);
      expect(m.needsPreMigrationBackup(1), isFalse);
      expect(m.needsPreMigrationBackup(2), isFalse);
      final none = m.migrate(jsonDecode(File('$projectFixtureRoot/s1/minimal.body.json').readAsStringSync()) as Map<String, Object?>, from: 1);
      expect(none.needsPreMigrationBackup, isFalse);
      expect(none.preMigrationBackupName, isNull);
    });

    test('documents the chain cannot reach are refused with ProjectFormatException', () {
      expect(() => Migrations.standard.migrate({}, from: 0), throwsA(isA<ProjectFormatException>()));
      expect(() => testMigrationsS0ToS1().migrate({}, from: 2), throwsA(isA<ProjectFormatException>()), reason: 'newer than the build');
      final s2only = Migrations([s2ToS3], target: 3);
      expect(() => s2only.migrate({}, from: 1), throwsA(isA<ProjectFormatException>()), reason: 'below the oldest step');
      expect(s2only.migrate({'meta': {}}, from: 2).applied, ['s2-to-s3']);
      expect(s2only.classify(schema: 1, minReader: 1), SchemaCompatibility.unsupportedOld);
    });

    test('a step that fails on a malformed body surfaces as ProjectFormatException naming the step', () {
      final bad = <String, Object?>{
        'id': 'pr_x',
        'tracks': [
          {'id': 'tr_1', 'kind': 'video', 'items': [{'type': 'clip', 'startMs': 'soon'}]},
        ],
      };
      final before = _snapshot(bad);
      Object? error;
      try {
        testMigrationsS0ToS1().migrate(bad, from: 0);
      } on ProjectFormatException catch (e) {
        error = e;
      }
      expect(error, isA<ProjectFormatException>());
      expect((error! as ProjectFormatException).path, 'startMs');
      expect(_eq.equals(bad, before), isTrue);

      final crash = Migrations([MigrationStep(from: 0, name: 'boom', apply: (b) => throw StateError('x'))]);
      expect(
        () => crash.migrate({}, from: 0),
        throwsA(isA<ProjectFormatException>().having((e) => e.message, 'message', contains('boom'))),
      );
    });

    test('invalid chains are rejected at construction', () {
      MigrationStep step(int from) => MigrationStep(from: from, name: 'x$from', apply: (b) => b);
      expect(() => Migrations([step(0), step(2)], target: 3), throwsArgumentError, reason: 'gap');
      expect(() => Migrations([step(0), step(0)], target: 2), throwsArgumentError, reason: 'duplicate');
      expect(() => Migrations([step(0), step(1)], target: 3), throwsArgumentError, reason: 'ends below the target');
      expect(() => Migrations([step(1)], target: 1), throwsArgumentError, reason: 'starts at the target');
      expect(() => Migrations([step(0)], target: 1), returnsNormally);
      expect(() => Migrations(const []), returnsNormally);
      expect(Migrations.standard.chain, isEmpty);
      expect(() => Migrations.standard.chain.add(step(0)), throwsUnsupportedError, reason: 'the chain is unmodifiable');
    });
  });

  group('test-only s0 -> s1 step', () {
    final step = testMigrationS0ToS1;

    test('is idempotent on every fixture (step(step(x)) == step(x), step(s1) == s1)', () {
      for (final spec in allFixtures) {
        final body = jsonDecode(File(spec.bodyPath).readAsStringSync()) as Map<String, Object?>;
        final once = step.apply(deepCopyJson(body));
        final twice = step.apply(deepCopyJson(once));
        expect(_eq.equals(once, twice), isTrue, reason: '${spec.name} s${spec.schema}');
        expect(jsonEncode(once), jsonEncode(twice), reason: 'key order is stable too');
      }
    });

    test('chain runner re-run: migrating an already migrated body again changes nothing', () {
      final m = testMigrationsS0ToS1();
      final s0 = jsonDecode(File('$projectFixtureRoot/s0/rich.body.json').readAsStringSync()) as Map<String, Object?>;
      final first = m.migrate(s0, from: 0).body;
      final again = m.migrate(first, from: 0).body;
      expect(jsonEncode(again), jsonEncode(first));
    });

    test('inverse property: migrate(toS0(json)) == json for 100 random projects', () {
      final codec = ProjectJsonCodec();
      final m = testMigrationsS0ToS1();
      for (var seed = 0; seed < 100; seed++) {
        final project = decoratedRandomProject(seed);
        final s1 = jsonDecode(codec.encode(project)) as Map<String, Object?>;
        final s0 = toS0(s1);
        expect(s0.containsKey('meta'), isFalse);
        final migrated = m.migrate(s0, from: 0).body;
        expect(_eq.equals(migrated, s1), isTrue, reason: 'seed $seed');
        expect(codec.decodeJson(migrated).project, project, reason: 'seed $seed decodes to the same project');
        // Idempotent on the random s1 body as well.
        expect(_eq.equals(step.apply(deepCopyJson(s1)), s1), isTrue);
      }
    });

    test('keys the step does not know are carried over, after the s1 keys', () {
      final out = step.apply({'id': 'pr_x', 'name': 'A', 'futureKey': 7, 'tracks': <Object?>[]});
      expect(out.keys.toList(), ['id', 'meta', 'settings', 'tracks', 'markers', 'pool', 'view', 'futureKey']);
    });
  });

  group('opening never writes', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('danaview_mig_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    String tree(Directory d) => (d.listSync(recursive: true)..sort((a, b) => a.path.compareTo(b.path)))
        .map((e) => '${e.path}|${e is File ? e.lengthSync() : -1}|${e.statSync().modified.microsecondsSinceEpoch}')
        .join('\n');

    test('read, classify and migrate of an s0 document perform no mutating filesystem step and leave the files untouched', () async {
      final spec = allFixtures.firstWhere((f) => f.schema == 0 && f.name == 'rich');
      final path = '${tmp.path}/project.dnproj';
      File(path).writeAsBytesSync(readDocument(spec));
      final before = tree(tmp);

      final fs = FaultInjectingFs(const LocalStoreFs());
      final files = DnprojFiles(fs: fs);
      final migrations = testMigrationsS0ToS1();

      final header = await files.readHeader(path);
      expect(migrations.classifyHeader(header), SchemaCompatibility.needsMigration);
      final read = await files.read(path);
      expect(migrations.classifyDocument(File(path).readAsBytesSync()), SchemaCompatibility.needsMigration);
      final result = migrations.migrate(jsonDecode(utf8.decode(read.document.body)) as Map<String, Object?>, from: read.document.header.schema);
      expect(result.migratedFrom, 0);

      expect(fs.log, isEmpty, reason: 'only reads went through the filesystem');
      expect(tree(tmp), before);
      expect(Directory('${tmp.path}/backups').existsSync(), isFalse, reason: 'the pre-migration backup is the repository\'s first save');
    });
  });
}
