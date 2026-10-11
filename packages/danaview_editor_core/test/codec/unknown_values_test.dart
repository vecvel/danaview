// OWNER: CORE-22
//
// Forward compatibility and malformed input (ARCH §8.2, BUILD_PLAN CORE-22 "unknown enum →
// warning not failure"): unknown keys are ignored; unknown enum values decode to the field default
// with an `unknownEnum` warning; unknown variants, item tags, track kinds and asset kinds produce
// warnings and defaults or drop the node; nothing of that kind throws, and `repair()` then opens
// the result. A body that is structurally broken throws `ProjectFormatException` with a path.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:json_schema/json_schema.dart';
import 'package:test/test.dart';
import 'package:danaview_editor_core/codec.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';

import 'support/codec_projects.dart';

void main() {
  final codec = ProjectJsonCodec();

  group('future_values.body.json (values written by a newer app)', () {
    final text = File('test/codec/fixtures/forward/future_values.body.json').readAsStringSync();
    final result = codec.decode(text);
    final p = result.project;
    final warnings = {for (final w in result.warnings) '${w.code} ${w.message}'};

    test('decodes without throwing and reports every unknown value', () {
      expect(warnings, {
        'unknownVariant meta.origin',
        'unknownVariant settings.bg',
        'unknownVariant clip.speed',
        'unknownEnum clip.visual.fit: "zoomFill"',
        'unknownVariant clip.visual.look',
        'unknownEnum clip.visual.mask.shape: "star"',
        'unknownItemDropped item tag "sticker"',
        'unknownEnum transition.kind: "spin"',
        'unknownEnum transition.dir: "clockwise"',
        'unknownTrackDropped kind "effects"',
        'unknownEnum text.style.align: "justify"',
        'unknownEnum text.anim.in: "bounce"',
        'unknownEnum text.anim.inDir: "diagonal"',
        'unknownEnum subtitle.pos: "middle"',
        'unknownEnum subtitle.style.align: "start"',
        'unknownEnum provenance.segmentation.preset: "karaoke"',
        'unknownEnum cue.origin: "translated"',
        'unknownEnum track.role: "ambience"',
        'unknownEnum asset.loc.app: "shared"',
        'unknownEnum asset.own: "cloud"',
        'unknownEnum asset.probe.transfer: "dolbyVision"',
        'unknownEnum asset.origin: "camera"',
        'unknownVariant asset.status',
        'unknownEnum asset.proxy: "streaming"',
        'unknownVariant asset.loc',
        'unknownVariant asset.derived',
        'unknownAssetDropped kind "model3d"',
        'unknownEnum view.follow: "smart"',
      });
    });

    test('unknown values fall back to the field defaults', () {
      expect(p.meta.origin, ProjectOrigin.projects);
      expect(p.settings.background, BackgroundSpec.black);
      expect(p.settings.frameRate, FrameRate.fps60);
      final main = p.tracks.first;
      final a = main.items.first as MediaClip;
      expect(a.speed, SpeedSpec.normal);
      expect(a.visual!.fit, FitMode.fit);
      expect(a.visual!.look, isNull);
      expect(a.visual!.mask.shape, MaskShape.none);
      expect(a.visual!.mask.opacity, 0.5, reason: 'known fields of the same object are kept');
      expect(a.audio.volume, 0.5);
      expect(main.transitions.single.kind, TransitionKind.fade);
      expect(main.transitions.single.direction, isNull);
      final text = p.tracks[1].items.single as TextItem;
      expect(text.style.align, TextAlignH.center);
      expect(text.animation.inKind, TextAnimKind.none);
      expect(text.animation.inDirection, TextSlideDirection.up);
      expect(text.animation.outKind, TextAnimKind.typewriter);
      final sub = p.tracks[2].subtitle!;
      expect(sub.position, SubtitlePosition.bottom);
      expect(sub.style.align, TextAlignH.center);
      expect(sub.provenance!.segmentation.preset, SegmentationPreset.standard);
      expect(sub.provenance!.schema, 2);
      expect((p.tracks[2].items.single as SubtitleCue).origin, CueOrigin.manual);
      expect(p.tracks[3].audioRole, isNull);
      final v = p.pool[const MediaId('md_v')]!;
      expect(v.locator, const AppRelativeLocator(AppRoot.support, 'x.mov'));
      expect(v.ownership, MediaOwnership.external, reason: 'unknown ownership never makes a file deletable');
      expect(v.probe.transfer, ColorTransfer.sdr);
      expect(v.origin, MediaOrigin.files);
      expect(v.status, AssetStatus.ready);
      expect(v.proxy, ProxyState.none);
      final audio = p.pool[const MediaId('md_a')]!;
      expect(audio.locator, const FileLocator(''), reason: 'an unknown locator reads as missing media (relink)');
      expect(audio.derived, isNull);
      expect(p.view.followMode, isNull);
    });

    test('unknown items, tracks and assets are left out', () {
      expect([for (final t in p.tracks) t.kind], [TrackKind.video, TrackKind.text, TrackKind.subtitle, TrackKind.audio]);
      expect([for (final i in p.tracks.first.items) i.id], ['it_a', 'it_b']);
      expect(p.pool.assets.keys, [const MediaId('md_v'), const MediaId('md_a')]);
    });

    test('unknown keys are ignored and the project still opens through repair()', () {
      final (repaired, _) = repair(p, ids: SeededIdGenerator(1));
      expect(validate(repaired), isEmpty);
    });

    test('re-encoding drops what this build does not know (why D-12 opens newer schemas read-only) and is schema-valid', () {
      final schema = JsonSchema.create(
        jsonDecode(File('schema/project.v1.schema.json').readAsStringSync()) as Object,
        schemaVersion: SchemaVersion.draft2020_12,
      );
      final body = codec.encode(p);
      expect(body, isNot(contains('sticker')));
      expect(body, isNot(contains('zoomFill')));
      expect(schema.validate(jsonDecode(body)).isValid, isTrue);
      expect(codec.decode(body).warnings, isEmpty);
    });
  });

  test('repeated unknown values are tallied into one warning', () {
    final body = jsonDecode(codec.encode(kitchenSinkProject())) as Map<String, Object?>;
    final cues = (((body['tracks']! as List<Object?>)[3]! as Map<String, Object?>)['items']! as List<Object?>);
    for (final c in cues) {
      (c! as Map<String, Object?>)['origin'] = 'dubbed';
    }
    final warnings = codec.decodeJson(body).warnings;
    expect(warnings, [const ProjectOpenWarning('unknownEnum', 'cue.origin: "dubbed" (3×)')]);
  });

  test('warning messages never echo long values', () {
    final body = jsonDecode(codec.encode(kitchenSinkProject())) as Map<String, Object?>;
    (body['view']! as Map<String, Object?>)['follow'] = 'x' * 500;
    final w = codec.decodeJson(body).warnings.single;
    expect(w.message.length, lessThan(80));
  });

  group('malformed bodies throw ProjectFormatException with a path', () {
    Map<String, Object?> body() => jsonDecode(codec.encode(kitchenSinkProject())) as Map<String, Object?>;
    Map<String, Object?> clip(Map<String, Object?> b) =>
        ((((b['tracks']! as List<Object?>).first! as Map<String, Object?>)['items']! as List<Object?>).first!) as Map<String, Object?>;

    void expectFormatError(Object? Function() decode, String path) {
      expect(decode, throwsA(isA<ProjectFormatException>().having((e) => e.path, 'path', path)));
    }

    test('not JSON, not an object, not UTF-8', () {
      expect(() => codec.decode('{"id":'), throwsA(isA<ProjectFormatException>()));
      expect(() => codec.decode('[1,2]'), throwsA(isA<ProjectFormatException>()));
      expect(() => codec.decodeBytes(Uint8List.fromList([0x7B, 0xFF, 0xFE, 0x7D])), throwsA(isA<ProjectFormatException>()));
    });

    test('wrong field types', () {
      expectFormatError(() => codec.decodeJson(body()..['id'] = 7), 'id');
      expectFormatError(() => codec.decodeJson(body()..['tracks'] = {}), 'tracks');
      final b = body();
      clip(b)['dur'] = '1s';
      expectFormatError(() => codec.decodeJson(b), 'tracks[0].items[0].dur');
      final c = body();
      clip(c)['start'] = 0.5;
      expectFormatError(() => codec.decodeJson(c), 'tracks[0].items[0].start');
      final d = body();
      (clip(d)['visual']! as Map<String, Object?>)['fit'] = 3;
      expectFormatError(() => codec.decodeJson(d), 'tracks[0].items[0].visual.fit');
      final e = body();
      (clip(e)['kf']! as Map<String, Object?>)['transform.scale'] = [
        [0],
      ];
      expectFormatError(() => codec.decodeJson(e), 'tracks[0].items[0].kf.transform.scale[0]');
    });

    test('missing required fields', () {
      expectFormatError(() => codec.decodeJson(body()..remove('meta')), 'meta');
      final b = body();
      clip(b).remove('media');
      expectFormatError(() => codec.decodeJson(b), 'tracks[0].items[0].media');
      final c = body();
      final assets = (c['pool']! as Map<String, Object?>)['assets']! as List<Object?>;
      (assets.first! as Map<String, Object?>).remove('fp');
      expectFormatError(() => codec.decodeJson(c), 'pool.assets[0].fp');
    });

    test('values the model cannot hold', () {
      final b = body();
      ((b['settings']! as Map<String, Object?>)['canvas']! as Map<String, Object?>)['aspect'] = [0, 9];
      expectFormatError(() => codec.decodeJson(b), 'settings.canvas.aspect');
      expectFormatError(() => codec.decodeJson(body()..['settings'] = {'fps': 0}), 'settings.fps');
      final c = body();
      ((c['meta']! as Map<String, Object?>))['created'] = 'yesterday';
      expectFormatError(() => codec.decodeJson(c), 'meta.created');
      final d = body();
      final asset = ((d['pool']! as Map<String, Object?>)['assets']! as List<Object?>)[4]! as Map<String, Object?>;
      (asset['derived']! as Map<String, Object?>)['range'] = [5, 1];
      expectFormatError(() => codec.decodeJson(d), 'pool.assets[4].derived.range');
      final e = body();
      (e['settings']! as Map<String, Object?>)['bg'] = {'solid': 'red'};
      expectFormatError(() => codec.decodeJson(e), 'settings.bg.solid');
    });
  });
}
