// OWNER: CORE-22
//
// Deterministic bytes and the body conventions of ARCH §8.2: committed golden bodies (the encoder
// must reproduce them byte for byte; regenerate with DANAVIEW_UPDATE_GOLDENS=1 after an intended
// format change, which also needs a schema bump), fixed key order, omitted defaults, numbers,
// colours, times, sorted keyframe channels and the preserved pool order.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:danaview_editor_core/codec.dart';
import 'package:danaview_editor_core/model.dart';

import 'support/codec_projects.dart';

const String fixtures = 'test/codec/fixtures';

final bool _update = Platform.environment['DANAVIEW_UPDATE_GOLDENS'] == '1';

/// Compares [actual] (one line, a trailing newline is added) with the golden file [name].
void expectGolden(String name, String actual) {
  final file = File('$fixtures/$name');
  if (_update) {
    file
      ..createSync(recursive: true)
      ..writeAsStringSync('$actual\n');
  }
  expect(file.existsSync(), isTrue, reason: '$name is missing; run with DANAVIEW_UPDATE_GOLDENS=1 once');
  expect(file.readAsStringSync(), '$actual\n', reason: '$name: the encoder must reproduce the golden bytes');
}

/// The keys of [json] in order.
List<String> keysOf(Object? json) => (json! as Map<String, Object?>).keys.toList();

void main() {
  final codec = ProjectJsonCodec();

  group('golden bodies', () {
    test('kitchen sink (a non-default value in every field)', () {
      expectGolden('kitchen_sink.body.json', codec.encode(kitchenSinkProject()));
    });

    test('minimal (every field at its default)', () {
      final body = codec.encode(minimalProject());
      expect(
        body,
        '{"id":"pr_minimal00000","meta":{"name":"Untitled","created":"2026-10-09T12:00:00.000Z",'
        '"updated":"2026-10-09T12:00:00.000Z"},"settings":{},"tracks":[],"markers":[],"pool":{},"view":{}}',
      );
      expectGolden('minimal.body.json', body);
    });

    test('a full document: header line + body line', () {
      final body = Uint8List.fromList(utf8.encode(codec.encode(kitchenSinkProject())));
      final header = ProjectHeader.forBody(
        body,
        app: '1.1.0+3',
        savedAt: DateTime.utc(2026, 10, 9, 18),
        docRevision: 9001,
        saveId: 'sv_kitchen00001',
      );
      expectGolden('kitchen_sink.dnproj', '${header.encodeLine()}\n${utf8.decode(body)}');
    });

    test('golden bodies decode back to the projects they were made from', () {
      for (final (name, project) in [('kitchen_sink.body.json', kitchenSinkProject()), ('minimal.body.json', minimalProject())]) {
        final decoded = codec.decode(File('$fixtures/$name').readAsStringSync().trimRight());
        expect(decoded.warnings, isEmpty);
        expect(decoded.project, project, reason: name);
      }
    });
  });

  group('fixed key order', () {
    final json = jsonDecode(codec.encode(kitchenSinkProject())) as Map<String, Object?>;
    final tracks = json['tracks']! as List<Object?>;
    final main = tracks.first! as Map<String, Object?>;
    final clip = (main['items']! as List<Object?>).first;
    final pool = (json['pool']! as Map<String, Object?>)['assets']! as List<Object?>;

    test('body root', () {
      expect(keysOf(json), ['id', 'docRev', 'rev', 'meta', 'settings', 'tracks', 'markers', 'pool', 'view']);
    });

    test('track, clip, visual', () {
      expect(keysOf(main), ['id', 'kind', 'name', 'main', 'locked', 'hidden', 'muted', 'solo', 'chg', 'items', 'tx']);
      expect(keysOf(clip), [
        't', 'id', 'start', 'dur', 'media', 'in', 'speed', 'pitch', 'reversed', 'stream', 'visual', 'audio', 'detached', 'kf',
        'link', 'label', //
      ]);
      expect(keysOf((clip! as Map<String, Object?>)['visual']), ['xf', 'fit', 'crop', 'adj', 'detail', 'look', 'chroma', 'mask']);
    });

    test('asset and probe', () {
      final asset = pool.first! as Map<String, Object?>;
      expect(keysOf(asset), ['id', 'kind', 'name', 'loc', 'own', 'fp', 'probe', 'origin', 'proxy', 'added']);
      expect(keysOf(asset['probe']), [
        'kind', 'dur', 'video', 'audio', 'w', 'h', 'rot', 'fps', 'avgFps', 'vfr', 'container', 'vcodec', 'acodec', 'streams',
        'ch', 'sr', 'bits', 'transfer', 'size', 'editable', 'issues', //
      ]);
    });

    test('keyframe channels are sorted whatever the insertion order', () {
      final kf = (clip! as Map<String, Object?>)['kf']! as Map<String, Object?>;
      expect(keysOf(kf), ['adjust.exposure', 'transform.scale']);
    });

    test('the pool keeps insertion (media-bin) order', () {
      final p = kitchenSinkProject();
      final ids = [for (final a in pool) (a! as Map<String, Object?>)['id']];
      expect(ids, [for (final id in p.pool.assets.keys) id as String]);
      final reversed = p.copyWith(pool: MediaPool({for (final a in p.pool.assets.values.toList().reversed) a.id: a}));
      final decoded = ProjectJsonCodec().decode(ProjectJsonCodec().encode(reversed)).project;
      expect(decoded.pool.assets.keys.toList(), p.pool.assets.keys.toList().reversed.toList());
    });
  });

  group('values', () {
    MediaClip clipWith({double scale = 1, double volume = 1, int chroma = 0x00B140}) => MediaClip(
          id: const ItemId('it_a'),
          start: 0,
          duration: 33334,
          media: const MediaId('md_a'),
          visual: VisualProps(transform: Transform2D(scale: scale), chroma: ChromaKey(enabled: true, color: chroma)),
          audio: AudioProps(volume: volume),
        );

    Map<String, Object?> encodeItem(TimelineItem item) {
      final p = minimalProject().copyWith(
        timeline: Timeline(tracks: [Track(id: const TrackId('tr_a'), kind: TrackKind.video, isMain: true, items: [item])]),
      );
      final json = jsonDecode(ProjectJsonCodec().encode(p)) as Map<String, Object?>;
      final track = (json['tracks']! as List<Object?>).first! as Map<String, Object?>;
      return (track['items']! as List<Object?>).first! as Map<String, Object?>;
    }

    String encodeItemText(TimelineItem item) => jsonEncode(encodeItem(item));

    test('integral doubles are written as integers, others in shortest round-trip form', () {
      expect(encodeItemText(clipWith(scale: 2)), contains('"xf":{"s":2}'));
      expect(encodeItemText(clipWith(scale: 0.1 + 0.2)), contains('"xf":{"s":0.30000000000000004}'));
      expect(encodeItemText(clipWith(volume: 1e-7)), contains('"audio":{"vol":1e-7}'));
      expect(encodeItemText(clipWith(volume: -0.0)), contains('"audio":{"vol":0}'));
    });

    test('non-finite numbers never reach the file (they read back as the default)', () {
      final text = encodeItemText(clipWith(scale: double.nan, volume: double.infinity));
      expect(text, isNot(contains('NaN')));
      expect(text, isNot(contains('Infinity')));
      expect(text, isNot(contains('"xf"')));
      expect(text, isNot(contains('"audio"')));
    });

    test('colours are "#RRGGBBAA" (the chroma key RGB "#RRGGBB")', () {
      final style = TextItem(
        id: const ItemId('it_t'),
        start: 0,
        duration: 33334,
        text: 'x',
        style: const TextStyleSpec(color: 0x80FF8800, stroke: StrokeStyle(color: 0x00000000)),
      );
      final j = encodeItem(style);
      expect((j['style']! as Map<String, Object?>)['color'], '#FF880080');
      expect(((j['style']! as Map<String, Object?>)['stroke']! as Map<String, Object?>)['color'], '#00000000');
      expect(encodeItemText(clipWith(chroma: 0x0047BB)), contains('"color":"#0047BB"'));
    });

    test('times are integer µs and dates UTC ISO-8601', () {
      final p = kitchenSinkProject();
      final json = jsonDecode(codec.encode(p)) as Map<String, Object?>;
      final meta = json['meta']! as Map<String, Object?>;
      expect(meta['created'], '2026-10-01T08:00:00.000Z');
      expect(meta['updated'], '2026-10-09T17:45:00.123456Z');
      final local = p.copyWith(meta: p.meta.copyWith(updatedAt: p.meta.updatedAt.toLocal()));
      expect(codec.encode(local), codec.encode(p), reason: 'local DateTimes are written in UTC');
    });

    test('defaults are omitted, including whole default-valued objects', () {
      final j = encodeItem(MediaClip(id: const ItemId('it_d'), start: 0, duration: 1, media: const MediaId('md_d')));
      expect(j.keys, ['t', 'id', 'start', 'dur', 'media']);
      final v = encodeItem(MediaClip(id: const ItemId('it_v'), start: 0, duration: 1, media: const MediaId('md_v'), visual: VisualProps.neutral));
      expect(v['visual'], <String, Object?>{}, reason: 'neutral visual props are {} (absent means "no visual", audio lanes)');
    });

    test('a cleared subtitle box is written as null; the default box is omitted', () {
      Map<String, Object?> sub(SubtitleStyle style) {
        final p = minimalProject().copyWith(
          timeline: Timeline(tracks: [Track(id: const TrackId('tr_s'), kind: TrackKind.subtitle, subtitle: SubtitleTrackData(style: style))]),
        );
        final json = jsonDecode(codec.encode(p)) as Map<String, Object?>;
        return ((json['tracks']! as List<Object?>).first! as Map<String, Object?>)['sub']! as Map<String, Object?>;
      }

      expect(sub(const SubtitleStyle()), <String, Object?>{});
      expect(sub(const SubtitleStyle(background: null)), {
        'style': {'box': null},
      });
      expect(sub(const SubtitleStyle(background: BoxStyle(opacity: 1))), {
        'style': {
          'box': {'op': 1},
        },
      });
    });
  });
}
