// OWNER: CORE-29
//
// RenderPlan contract corpus (ARCH §11.9): every valid fixture validates against the JSON Schema,
// passes the validator and round-trips byte-identically; every invalid fixture fails with the
// right code and layer id; malformed documents fail to decode at the right path; decoders ignore
// unknown keys; grid_cuts_30fps matches its per-frame expectation (D-35).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:json_schema/json_schema.dart';
import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';

const _dir = 'test/fixtures/render_plans/contract';

Uint8List _bytes(String path) => Uint8List.fromList(utf8.encode(File(path).readAsStringSync().trimRight()));

List<File> _jsonFiles(String dir) => Directory(dir).listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList()
  ..sort((a, b) => a.path.compareTo(b.path));

String _name(File f) => f.uri.pathSegments.last;

/// Re-encodes [bytes] through the codec that matches the document kind.
Uint8List _reencode(Uint8List bytes) {
  final json = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
  if (json.containsKey('rev')) return PlanJson.encodePlanBytes(PlanJson.decodePlanBytes(bytes));
  if (json.containsKey('from')) return PlanJson.encodePatchBytes(PlanJson.decodePatchBytes(bytes));
  return PlanJson.encodeTransientBytes(PlanJson.decodeTransientBytes(bytes));
}

void main() {
  final schema = JsonSchema.create(
    jsonDecode(File('schema/render_plan.v1.schema.json').readAsStringSync()) as Object,
    schemaVersion: SchemaVersion.draft2020_12,
  );
  final valid = _jsonFiles(_dir).where((f) => !f.path.endsWith('.expected_active.json')).toList();

  test('the corpus has at least 25 hand-written valid fixtures covering plans, patches and transients', () {
    expect(valid.length, greaterThanOrEqualTo(25));
    final kinds = {
      for (final f in valid)
        () {
          final j = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
          return j.containsKey('rev') ? 'plan' : (j.containsKey('from') ? 'patch' : 'transient');
        }(),
    };
    expect(kinds, {'plan', 'patch', 'transient'});
  });

  group('valid fixtures', () {
    for (final f in valid) {
      final name = _name(f);
      test('$name validates against the JSON Schema', () {
        final result = schema.validate(jsonDecode(f.readAsStringSync()));
        expect(result.isValid, isTrue, reason: result.errors.join('\n'));
      });
      test('$name round-trips byte-identically and passes the validator', () {
        final bytes = _bytes(f.path);
        final json = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
        if (json.containsKey('rev')) {
          final plan = PlanJson.decodePlanBytes(bytes);
          expect(PlanValidator.validate(plan), isEmpty);
          expect(PlanJson.decodePlanBytes(PlanJson.encodePlanBytes(plan)), plan, reason: 'typed equality survives a round trip');
        }
        expect(utf8.decode(_reencode(bytes)), utf8.decode(bytes));
        expect(f.readAsStringSync().endsWith('\n'), isTrue, reason: 'one trailing newline');
        expect(f.readAsStringSync().trimRight().contains('\n'), isFalse, reason: 'canonical form is a single line');
      });
    }
  });

  group('invalid fixtures', () {
    final invalid = _jsonFiles('$_dir/invalid');
    test('there is a fixture for every violation code but the version (which cannot decode)', () {
      final codes = {
        for (final f in invalid) ((jsonDecode(f.readAsStringSync()) as Map<String, Object?>)['_expect']! as Map<String, Object?>)['code'],
      };
      expect(codes, PlanViolationCode.values.where((c) => c != PlanViolationCode.version).map((c) => c.name).toSet());
    });

    for (final f in invalid) {
      final name = _name(f);
      test('invalid/$name fails with the expected code and layer id, and nothing else', () {
        final json = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
        final expected = json['_expect']! as Map<String, Object?>;
        final violations = PlanValidator.validate(PlanJson.decodePlan(json));
        expect(
          violations.any((v) => v.code.name == expected['code'] && v.id == expected['id']),
          isTrue,
          reason: 'expected ${expected['code']} on ${expected['id']}, got:\n${violations.join('\n')}',
        );
        expect(violations.where((v) => v.code.name != expected['code']), isEmpty, reason: 'the fixture isolates one invariant:\n${violations.join('\n')}');
      });
    }
  });

  group('malformed documents (decode fails with the error path)', () {
    for (final f in _jsonFiles('$_dir/invalid_format')) {
      test('invalid_format/${_name(f)}', () {
        final json = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
        final expected = (json['_expect']! as Map<String, Object?>)['path'];
        expect(
          () => PlanJson.decodePlan(json),
          throwsA(isA<PlanFormatException>().having((e) => e.path, 'path', expected)),
        );
      });
    }

    test('invalid JSON text fails with PlanFormatException', () {
      expect(() => PlanJson.decodePlanBytes(Uint8List.fromList(utf8.encode('{"v":'))), throwsA(isA<PlanFormatException>()));
      expect(() => PlanJson.decodePlanBytes(Uint8List.fromList(utf8.encode('[]'))), throwsA(isA<PlanFormatException>()));
    });

    test('patches and transients check their version too', () {
      expect(() => PlanJson.decodePatch({'v': 2, 'from': 1, 'to': 2}), throwsA(isA<PlanFormatException>()));
      expect(() => PlanJson.decodeTransient({'v': 0, 'item': 'x', 'layers': []}), throwsA(isA<PlanFormatException>()));
    });
  });

  group('tolerant decoding: unknown keys are ignored, defaults may be explicit', () {
    test('a plan with unknown keys, explicit defaults and loose formatting equals minimal_preview', () {
      final loose = PlanJson.decodePlanBytes(_bytes('$_dir/tolerant/plan_unknown_keys.json'));
      final canonical = PlanJson.decodePlanBytes(_bytes('$_dir/minimal_preview.json'));
      expect(loose, canonical);
      expect(utf8.decode(PlanJson.encodePlanBytes(loose)), File('$_dir/minimal_preview.json').readAsStringSync().trimRight());
    });

    test('a patch with unknown keys decodes', () {
      final p = PlanJson.decodePatchBytes(_bytes('$_dir/tolerant/patch_unknown_keys.json'));
      expect(p.from, 7);
      expect(p.to, 8);
      expect(p.layers.remove, ['it_x#v']);
      expect(p.layers.upsert, isEmpty);
    });

    test('timing fields in a transient are ignored (ARCH §11.2)', () {
      final t = PlanJson.decodeTransientBytes(_bytes('$_dir/tolerant/transient_timing_fields_ignored.json'));
      expect(t, PlanJson.decodeTransientBytes(_bytes('$_dir/transient_move.json')));
    });
  });

  group('grid_cuts_30fps (D-35)', () {
    final plan = PlanJson.decodePlanBytes(_bytes('$_dir/grid_cuts_30fps.json'));
    final expected = jsonDecode(File('$_dir/grid_cuts_30fps.expected_active.json').readAsStringSync()) as Map<String, Object?>;
    final grid = plan.canvas.gridRate;

    test('has layer edges at frames k ≡ 1 and k ≡ 2 (mod 3), among them 31, 32, 61 and 62', () {
      final edgeFrames = {
        for (final l in plan.layers) ...[grid.frameIndexOf(l.t0), grid.frameIndexOf(l.t1)],
      };
      expect(edgeFrames, containsAll([31, 32, 61, 62]));
      expect({for (final k in edgeFrames) k % 3}, containsAll([1, 2]));
      for (final l in plan.layers) {
        expect(grid.isOnGrid(l.t0) && grid.isOnGrid(l.t1), isTrue);
      }
    });

    test('expected_active.json lists every frame of the plan', () {
      final frames = (expected['frames']! as List).cast<Map<String, Object?>>();
      expect(frames.map((e) => e['k']), [for (var k = 0; k < 90; k++) k]);
      for (final e in frames) {
        expect(e['timeOfFrame'], grid.timeOfFrame(e['k']! as int));
      }
    });

    test('active layers per frame, also from platform times P(k) and the rational k/fps', () {
      for (final e in (expected['frames']! as List).cast<Map<String, Object?>>()) {
        final k = e['k']! as int;
        final active = (e['active']! as List).cast<String>();
        expect(plan.activeLayerIdsAt(grid.timeOfFrame(k)), active, reason: 'k=$k');
        // A platform clock stamps frame k at P(k), up to 1 µs before the plan edge: map it first.
        final fromPlatform = grid.timeOfFrame(grid.frameIndexNearest(grid.platformTimeOfFrame(k)));
        expect(plan.activeLayerIdsAt(fromPlatform), active, reason: 'k=$k via P(k)');
        final fromRational = grid.timeOfFrame(grid.frameIndexOfRational(k, 30));
        expect(plan.activeLayerIdsAt(fromRational), active, reason: 'k=$k via k/fps');
      }
    });

    test('reading P(k) without the platform-time rule gets it wrong exactly at the k ≡ 1 (mod 3) edges', () {
      var wrong = 0;
      for (final e in (expected['frames']! as List).cast<Map<String, Object?>>()) {
        final k = e['k']! as int;
        final naive = plan.activeLayerIdsAt(grid.platformTimeOfFrame(k));
        if (naive.join() != (e['active']! as List).join()) {
          wrong++;
          expect(k % 3, 1);
        }
      }
      expect(wrong, greaterThan(0), reason: 'the fixture exists to catch floor-based mapping');
    });
  });

  group('export plans keep edit points on the project grid (D-35)', () {
    test('export_24_from_30: output rate 24, gridFps 30; every edge is a 30 fps frame start', () {
      final plan = PlanJson.decodePlanBytes(_bytes('$_dir/export_24_from_30.json'));
      expect(plan.canvas.fps, 24);
      expect(plan.canvas.gridFps, 30);
      for (final l in plan.layers) {
        expect(plan.canvas.gridRate.isOnGrid(l.t0) && plan.canvas.gridRate.isOnGrid(l.t1), isTrue, reason: l.id);
      }
    });

    test('export_48_from_24: output rate 48, gridFps 24', () {
      final plan = PlanJson.decodePlanBytes(_bytes('$_dir/export_48_from_24.json'));
      expect(plan.canvas.fps, 48);
      expect(plan.canvas.gridFps, 24);
      expect(PlanValidator.validate(plan), isEmpty);
    });

    test('an edge on the output grid but not on the project grid is rejected', () {
      final plan = PlanJson.decodePlanBytes(_bytes('$_dir/export_24_from_30.json'));
      final onOutputGrid = FrameRate.fps24.timeOfFrame(1);
      expect(plan.canvas.gridRate.isOnGrid(onOutputGrid), isFalse);
      final bad = plan.copyWith(layers: [
        for (final l in plan.layers)
          l.id == plan.layers.last.id
              ? PlanLayer(id: l.id, z: l.z, t0: onOutputGrid, t1: l.t1, kind: l.kind, asset: l.asset, base: l.base, anim: l.anim)
              : l,
      ]);
      expect(PlanValidator.validate(bad).any((v) => v.code == PlanViolationCode.offGrid), isTrue);
    });
  });
}
