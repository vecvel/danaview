// OWNER: CORE-29
//
// The JSON Schema rejects what ARCH §11.2 forbids and accepts what it allows (so the corpus test
// above is not vacuous), and the fixture corpus covers every key and every animatable channel.

import 'dart:convert';
import 'dart:io';

import 'package:json_schema/json_schema.dart';
import 'package:test/test.dart';
import 'package:danaview_editor_core/plan.dart';

const _dir = 'test/fixtures/render_plans/contract';

Map<String, Object?> _load(String name) => jsonDecode(File('$_dir/$name').readAsStringSync()) as Map<String, Object?>;

/// A deep copy that tests mutate.
Map<String, Object?> _copy(Map<String, Object?> m) => jsonDecode(jsonEncode(m)) as Map<String, Object?>;

void main() {
  final schema = JsonSchema.create(
    jsonDecode(File('schema/render_plan.v1.schema.json').readAsStringSync()) as Object,
    schemaVersion: SchemaVersion.draft2020_12,
  );

  bool accepts(Object? doc) => schema.validate(doc).isValid;

  Map<String, Object?> plan() => _copy(_load('effects_every_static_key.json'));
  Map<String, Object?> layer(Map<String, Object?> p, int i) => ((p['layers']! as List)[i]) as Map<String, Object?>;
  Map<String, Object?> asset(Map<String, Object?> p, String id) => (p['assets']! as Map<String, Object?>)[id]! as Map<String, Object?>;

  group('schema accepts', () {
    test('the base plan used by the negative tests', () => expect(accepts(plan()), isTrue));

    test('unknown keys everywhere (decoders must ignore them)', () {
      final p = plan()
        ..['future'] = 1
        ..['canvas'] = {...(plan()['canvas']! as Map<String, Object?>), 'hdr': true};
      layer(p, 0)['extra'] = {'x': 1};
      expect(accepts(p), isTrue);
    });

    test('a bare patch and a bare transient', () {
      expect(accepts({'v': 1, 'from': 0, 'to': 1}), isTrue);
      expect(accepts({'v': 1, 'item': 'it_a', 'layers': <Object?>[]}), isTrue);
    });

    test('both targets and every v1 rate', () {
      for (final rate in [24, 25, 30, 48, 50, 60]) {
        final p = plan();
        (p['canvas']! as Map<String, Object?>)['fps'] = rate;
        (p['canvas']! as Map<String, Object?>)['gridFps'] = rate;
        expect(accepts(p), isTrue, reason: '$rate');
      }
      expect(accepts(plan()..['target'] = 'export'), isTrue);
    });
  });

  group('schema rejects', () {
    void rejects(String why, void Function(Map<String, Object?> p) mutate) {
      test(why, () {
        final p = plan();
        mutate(p);
        expect(accepts(p), isFalse);
      });
    }

    rejects('version 2', (p) => p['v'] = 2);
    rejects('a missing required top-level key', (p) => p.remove('audio'));
    rejects('an unknown target', (p) => p['target'] = 'thumbnail');
    rejects('a negative revision', (p) => p['rev'] = -1);
    rejects('an odd canvas width', (p) => (p['canvas']! as Map<String, Object?>)['w'] = 1921);
    rejects('a canvas smaller than 16 px', (p) => (p['canvas']! as Map<String, Object?>)['h'] = 8);
    rejects('fps 29', (p) => (p['canvas']! as Map<String, Object?>)['fps'] = 29);
    rejects('gridFps 120', (p) => (p['canvas']! as Map<String, Object?>)['gridFps'] = 120);
    rejects('a colour without alpha', (p) => (p['canvas']! as Map<String, Object?>)['bg'] = '#123456');
    rejects('an http asset uri', (p) => asset(p, 'md_clipA0000001')['uri'] = 'https://example.com/a.mp4');
    rejects('a bare path as an asset uri', (p) => asset(p, 'md_clipA0000001')['uri'] = '/var/mobile/a.mp4');
    rejects('an asset without a uri', (p) => asset(p, 'md_clipA0000001').remove('uri'));
    rejects('an unknown asset kind', (p) => asset(p, 'md_clipA0000001')['kind'] = 'movie');
    rejects('rotation 45', (p) => asset(p, 'md_clipA0000001')['rot'] = 45);
    rejects('a lut without n', (p) => asset(p, 'lt_teal0000001').remove('n'));
    rejects('a lut with n = 66', (p) => asset(p, 'lt_teal0000001')['n'] = 66);
    rejects('a layer without a kind', (p) => layer(p, 0).remove('kind'));
    rejects('a media layer without seq', (p) => layer(p, 0).remove('seq'));
    rejects('a media layer without a map', (p) => layer(p, 0).remove('map'));
    rejects('a media layer with an empty map', (p) => layer(p, 0)['map'] = []);
    rejects('a map segment with three numbers', (p) => layer(p, 0)['map'] = [[0, 1, 2]]);
    rejects('a map segment with fractional times', (p) => layer(p, 0)['map'] = [[0, 1.5, 0, 1]]);
    rejects('z beyond the four bands', (p) => layer(p, 0)['z'] = 40000);
    rejects('a non-integer layer time', (p) => layer(p, 0)['t'] = [0, 100.5]);
    rejects('opacity above 1', (p) => (layer(p, 0)['xf']! as Map<String, Object?>)['op'] = 1.5);
    rejects('a three-number crop', (p) => layer(p, 0)['crop'] = [0, 0, 1]);
    rejects('a crop value above 1', (p) => layer(p, 0)['crop'] = [0, 0, 1.2, 1]);
    rejects('a non-positive base', (p) => layer(p, 0)['base'] = [0, 100]);
    rejects('an adjustment above 1', (p) => ((layer(p, 0)['fx']! as Map<String, Object?>)['adj']! as Map<String, Object?>)['tint'] = 1.5);
    rejects('a blur above 1', (p) => ((layer(p, 0)['fx']! as Map<String, Object?>)['detail']! as Map<String, Object?>)['blur'] = 2);
    rejects('a chroma key with alpha', (p) => ((layer(p, 0)['fx']! as Map<String, Object?>)['chroma']! as Map<String, Object?>)['key'] = '#00B140FF');
    rejects('an unknown mask shape', (p) => ((layer(p, 0)['fx']! as Map<String, Object?>)['mask']! as Map<String, Object?>)['shape'] = 'star');
    rejects('a mask corner above 0.5', (p) => ((layer(p, 0)['fx']! as Map<String, Object?>)['mask']! as Map<String, Object?>)['corner'] = 0.6);
    rejects('an unknown anim channel', (p) => layer(p, 0)['anim'] = {'xf.skew': [[0, 1]]});
    rejects('an anim channel without keys', (p) => layer(p, 0)['anim'] = {'xf.s': <Object?>[]});
    rejects('an anim key with three numbers', (p) => layer(p, 0)['anim'] = {'xf.s': [[0, 1, 2]]});
    rejects('a canvas mask without size', (p) => layer(p, 0)['cmasks'] = [{'cx': 0, 'cy': 0}]);
    rejects('a canvas mask anim on feather', (p) => layer(p, 0)['cmasks'] = [{'cx': 0, 'cy': 0, 'w': 1, 'h': 1, 'anim': {'feather': [[0, 1]]}}]);
    rejects('a solid without a colour', (p) => (p['layers']! as List).add({'id': 'x#v', 'z': 1, 't': [0, 1], 'kind': 'solid'}));
    rejects('seq on an image layer', (p) => (p['layers']! as List).add({'id': 'x#v', 'z': 1, 't': [0, 1], 'kind': 'image', 'asset': 'a', 'seq': 0}));
    rejects('a sprite layer without an asset', (p) => (p['layers']! as List).add({'id': 'x#v', 'z': 20010, 't': [0, 1], 'kind': 'sprite'}));
    rejects('an audio segment without gain', (p) => ((p['audio']! as List)[0] as Map<String, Object?>).remove('gain'));
    rejects('a gain above 2', (p) => ((p['audio']! as List)[0] as Map<String, Object?>)['gain'] = [[0, 2.5]]);
    rejects('a negative gain', (p) => ((p['audio']! as List)[0] as Map<String, Object?>)['gain'] = [[0, -1]]);
    rejects('an empty gain envelope', (p) => ((p['audio']! as List)[0] as Map<String, Object?>)['gain'] = []);
    rejects('a negative audio stream', (p) => ((p['audio']! as List)[0] as Map<String, Object?>)['stream'] = -1);

    test('a sprite asset without sscale', () {
      final p = _copy(_load('sprites_export_reveal.json'));
      expect(accepts(p), isTrue);
      asset(p, 'sp_sub000000001').remove('sscale');
      expect(accepts(p), isFalse);
    });

    test('a patch with a non-integer revision', () => expect(accepts({'v': 1, 'from': 1.5, 'to': 2}), isFalse));
    test('a patch that carries rev (it is a plan, not a patch)', () => expect(accepts({'v': 1, 'from': 1, 'to': 2, 'rev': 3}), isFalse));
    test('a transient without layers', () => expect(accepts({'v': 1, 'item': 'x'}), isFalse));
    test('a transient layer without an id', () => expect(accepts({'v': 1, 'item': 'x', 'layers': [<String, Object?>{}]}), isFalse));
  });

  group('corpus coverage', () {
    final files = Directory(_dir).listSync().whereType<File>().where((f) => f.path.endsWith('.json') && !f.path.endsWith('.expected_active.json')).toList();
    final docs = [for (final f in files) jsonDecode(f.readAsStringSync()) as Map<String, Object?>];

    /// Every key name used by a fixture, except dynamic keys (asset ids, anim channel names).
    final used = <String>{};
    final channels = <String>{};
    final cmaskChannels = <String>{};
    void walk(Object? node, {String? parent}) {
      if (node is Map<String, Object?>) {
        for (final e in node.entries) {
          final dynamicKeys = parent == 'assets' || (parent == 'upsert' && e.value is Map<String, Object?> && (e.value! as Map<String, Object?>).containsKey('uri'));
          if (parent == 'anim') {
            channels.add(e.key);
            walk(e.value, parent: 'animKeys');
            continue;
          }
          if (dynamicKeys) {
            walk(e.value, parent: 'asset');
            continue;
          }
          used.add(e.key);
          if (e.key == 'cmasks') {
            for (final m in (e.value! as List).cast<Map<String, Object?>>()) {
              final a = m['anim'];
              if (a is Map<String, Object?>) cmaskChannels.addAll(a.keys);
            }
          }
          walk(e.value, parent: e.key);
        }
      } else if (node is List) {
        for (final x in node) {
          walk(x, parent: parent);
        }
      }
    }

    for (final d in docs) {
      walk(d);
    }

    /// Property names the schema declares.
    final declared = <String>{};
    void collect(Object? node) {
      if (node is Map<String, Object?>) {
        final props = node['properties'];
        if (props is Map<String, Object?>) {
          declared.addAll(props.keys);
          props.values.forEach(collect);
        }
        for (final k in ['\$defs', 'items', 'additionalProperties', 'oneOf', 'allOf', 'then', 'else', 'if']) {
          final v = node[k];
          if (v is Map<String, Object?>) {
            if (k == '\$defs') {
              v.values.forEach(collect);
            } else {
              collect(v);
            }
          } else if (v is List) {
            v.forEach(collect);
          }
        }
      }
    }

    collect(jsonDecode(File('schema/render_plan.v1.schema.json').readAsStringSync()));

    test('every key the schema declares is used by at least one fixture', () {
      // `req` children, the patch collections and every effect parameter are in the list.
      final missing = declared.difference(used);
      expect(missing, isEmpty, reason: 'declared but never used: $missing');
    });

    test('every animatable channel appears in a fixture', () {
      expect(PlanChannels.all.difference(channels), isEmpty, reason: 'channels without a fixture: ${PlanChannels.all.difference(channels)}');
      expect(channels.difference({...PlanChannels.all, ...PlanChannels.canvasMask}), isEmpty, reason: 'only known channels in the corpus');
    });

    test('canvas masks animate cx, cy, w and h', () {
      expect(cmaskChannels, PlanChannels.canvasMask);
    });

    test('the lowered features of ARCH §11.7 are all represented', () {
      final plans = [for (final d in docs) if (d.containsKey('rev')) d];
      bool any(bool Function(Map<String, Object?> plan) f) => plans.any(f);
      Iterable<Map<String, Object?>> layers(Map<String, Object?> p) => (p['layers']! as List).cast<Map<String, Object?>>();
      Iterable<Map<String, Object?>> audio(Map<String, Object?> p) => (p['audio']! as List).cast<Map<String, Object?>>();
      Iterable<Map<String, Object?>> assets(Map<String, Object?> p) => (p['assets']! as Map<String, Object?>).values.cast<Map<String, Object?>>();

      expect(any((p) => p['target'] == 'preview'), isTrue);
      expect(any((p) => p['target'] == 'export'), isTrue);
      expect(any((p) => layers(p).any((l) => l['hold'] == true)), isTrue, reason: 'hold');
      expect(any((p) => layers(p).any((l) => ((l['map'] as List?) ?? const []).length > 3)), isTrue, reason: 'speed ramp map');
      expect(any((p) => layers(p).any((l) => l['kind'] == 'solid' && (l['id']! as String).contains('#tx'))), isTrue, reason: 'transition helper');
      expect(any((p) => layers(p).any((l) => l['kind'] == 'media' && (l['id']! as String).endsWith('#bd'))), isTrue, reason: 'backdrop');
      expect(any((p) => layers(p).any((l) => l['kind'] == 'sprite' && (l['id']! as String).endsWith('#c'))), isTrue, reason: 'burned cue');
      expect(any((p) => layers(p).any((l) => ((l['seq'] as int?) ?? 0) >= 1)), isTrue, reason: 'seq ≥ 1');
      expect(any((p) => audio(p).any((a) => ((a['gain']! as List).any((k) => ((k as List)[1] as num) >= 2)))), isTrue, reason: 'gain up to 2.0');
      expect(any((p) => audio(p).any((a) => ((a['gain']! as List).any((k) => ((k as List)[1] as num) == 0)))), isTrue, reason: 'gain 0');
      expect(any((p) => audio(p).any((a) => a['pitch'] == false)), isTrue, reason: 'varispeed');
      expect(any((p) => audio(p).any((a) => ((a['stream'] as int?) ?? 0) > 0)), isTrue, reason: 'second audio stream');
      expect(any((p) => (p['audio']! as List).isEmpty && p['target'] == 'export'), isTrue, reason: 'no-audio export');
      expect(any((p) => p['canvas'] is Map<String, Object?> && (p['canvas']! as Map<String, Object?>).containsKey('gridFps')), isTrue, reason: 'gridFps != fps');
      expect(any((p) => assets(p).any((a) => a['kind'] == 'lut')), isTrue);
      expect(any((p) => assets(p).any((a) => a['kind'] == 'sprite' && a['reveal'] == true)), isTrue);
      expect(any((p) => assets(p).any((a) => a['transfer'] == 'hlg')), isTrue);
      expect(any((p) => assets(p).any((a) => a['transfer'] == 'pq')), isTrue);
      expect(any((p) => assets(p).any((a) => a.containsKey('bookmark'))), isTrue);
      expect(any((p) => assets(p).any((a) => a.containsKey('proxyUri'))), isTrue);
      expect(any((p) => assets(p).any((a) => a['kind'] == 'image')), isTrue);
      expect(any((p) => assets(p).any((a) => a['kind'] == 'audio')), isTrue);
      final req = [for (final p in plans) if (p['req'] != null) p['req']! as Map<String, Object?>];
      expect(req.expand((r) => r.keys).toSet(), {'offline', 'pendingReverse', 'pendingStill'});
    });

    test('every transition kind is lowered in a fixture (two layers share a z inside the window)', () {
      for (final name in ['transition_cross_dissolve', 'transition_slide', 'transition_wipe', 'transition_zoom', 'transition_fade', 'transition_dip_to_white']) {
        expect(File('$_dir/$name.json').existsSync(), isTrue, reason: name);
      }
      for (final name in ['transition_cross_dissolve', 'transition_slide', 'transition_wipe', 'transition_zoom']) {
        final p = PlanJson.decodePlanBytes(File('$_dir/$name.json').readAsBytesSync());
        final overlap = p.layers.where((l) => l.z == 10).toList();
        expect(overlap.length, 2, reason: name);
        expect(overlap[0].t1, greaterThan(overlap[1].t0), reason: '$name overlaps inside the window');
        expect(overlap[0].seq, isNot(overlap[1].seq), reason: '$name uses two sequence slots');
      }
    });

    test('patches cover structural, gain-only, header-only and removal-only forms; transients cover all fields', () {
      final patches = [for (final d in docs) if (d.containsKey('from')) d];
      expect(patches.length, greaterThanOrEqualTo(5));
      expect(patches.any((p) => p.containsKey('canvas') && p.containsKey('durUs') && p.containsKey('assets') && p.containsKey('layers') && p.containsKey('audio')), isTrue);
      expect(patches.any((p) => p.length == 3), isTrue, reason: 'header only');
      final transients = [for (final d in docs) if (d.containsKey('item')) d];
      expect(transients.length, greaterThanOrEqualTo(4));
      final fields = {for (final t in transients) for (final l in (t['layers']! as List).cast<Map<String, Object?>>()) ...l.keys};
      expect(fields, {'id', 'xf', 'crop', 'base', 'fx', 'anim', 'cmasks'});
    });
  });
}
