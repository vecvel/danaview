// OWNER: CORE-22
//
// `schema/project.v1.schema.json` is the normative body schema (BUILD_PLAN CORE-22): the committed
// fixtures and the encodings of random projects validate against it, and it rejects malformed
// bodies (misspelled keys, wrong enum values, bad colours, missing required fields).

import 'dart:convert';
import 'dart:io';

import 'package:json_schema/json_schema.dart';
import 'package:test/test.dart';
import 'package:danaview_editor_core/codec.dart';

import '../support/random_project.dart';
import 'support/codec_projects.dart';

const String _fixtures = 'test/codec/fixtures';

void main() {
  final schema = JsonSchema.create(
    jsonDecode(File('schema/project.v1.schema.json').readAsStringSync()) as Object,
    schemaVersion: SchemaVersion.draft2020_12,
  );
  final codec = ProjectJsonCodec();

  void expectValid(Object? json, String label) {
    final result = schema.validate(json);
    expect(result.isValid, isTrue, reason: '$label:\n${result.errors.take(10).join('\n')}');
  }

  void expectInvalid(Object? json, String label) {
    expect(schema.validate(json).isValid, isFalse, reason: '$label should be rejected');
  }

  test('the schema is draft 2020-12 and describes a closed body object', () {
    final raw = jsonDecode(File('schema/project.v1.schema.json').readAsStringSync()) as Map<String, Object?>;
    expect(raw[r'$schema'], 'https://json-schema.org/draft/2020-12/schema');
    expect(raw['required'], ['id', 'meta', 'settings', 'tracks', 'markers', 'pool', 'view']);
    expect(raw['additionalProperties'], isFalse);
  });

  group('committed fixtures validate', () {
    for (final name in ['kitchen_sink.body.json', 'minimal.body.json']) {
      test(name, () => expectValid(jsonDecode(File('$_fixtures/$name').readAsStringSync()), name));
    }
    test('kitchen_sink.dnproj body line', () {
      final lines = File('$_fixtures/kitchen_sink.dnproj').readAsStringSync().split('\n');
      expect(lines, hasLength(3), reason: 'header, body, trailing newline');
      expectValid(jsonDecode(lines[1]), 'dnproj body');
    });
  });

  test('encodings of 200 random projects validate (plain and decorated)', () {
    for (var seed = 0; seed < 100; seed++) {
      final plain = randomProject(seed, RandomProjectSpec(items: 20 + seed % 60));
      expectValid(jsonDecode(codec.encode(plain)), 'seed $seed');
      expectValid(jsonDecode(codec.encode(decorate(plain, seed))), 'seed $seed (decorated)');
    }
  });

  group('the schema rejects malformed bodies', () {
    Map<String, Object?> body() => jsonDecode(File('$_fixtures/kitchen_sink.body.json').readAsStringSync()) as Map<String, Object?>;
    Map<String, Object?> firstClip(Map<String, Object?> b) =>
        ((((b['tracks']! as List<Object?>).first! as Map<String, Object?>)['items']! as List<Object?>).first!) as Map<String, Object?>;

    test('a missing required root field', () => expectInvalid(body()..remove('meta'), 'no meta'));
    test('an unknown root key', () => expectInvalid(body()..['extra'] = 1, 'unknown key'));
    test('a misspelled item key', () {
      final b = body();
      firstClip(b)['duration'] = firstClip(b).remove('dur');
      expectInvalid(b, 'dur misspelled');
    });
    test('an unknown item tag', () {
      final b = body();
      firstClip(b)['t'] = 'sticker';
      expectInvalid(b, 'item tag');
    });
    test('an unknown enum value', () {
      final b = body();
      (firstClip(b)['visual']! as Map<String, Object?>)['fit'] = 'zoom';
      expectInvalid(b, 'fit');
    });
    test('a default value that should have been omitted', () {
      final b = body();
      (firstClip(b)['visual']! as Map<String, Object?>)['fit'] = 'fit';
      expectInvalid(b, 'fit default written');
    });
    test('a lower-case or short colour', () {
      final b = body();
      final meta = b['settings']! as Map<String, Object?>;
      meta['bg'] = {'solid': '#ff0000ff'};
      expectInvalid(b, 'lower-case colour');
      meta['bg'] = {'solid': '#FF0000'};
      expectInvalid(b, 'six-digit ARGB colour');
    });
    test('a fractional time', () {
      final b = body();
      firstClip(b)['start'] = 0.5;
      expectInvalid(b, 'fractional µs');
    });
    test('a locator with two variants', () {
      final b = body();
      final asset = ((b['pool']! as Map<String, Object?>)['assets']! as List<Object?>).first! as Map<String, Object?>;
      asset['loc'] = {'app': 'support', 'rel': 'x', 'file': '/x'};
      expectInvalid(b, 'ambiguous locator');
    });
    test('a non-UTC time', () {
      final b = body();
      (b['meta']! as Map<String, Object?>)['created'] = '2026-10-01T08:00:00.000+02:00';
      expectInvalid(b, 'offset time');
    });
  });
}
