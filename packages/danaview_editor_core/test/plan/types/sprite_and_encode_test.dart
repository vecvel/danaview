// OWNER: CORE-29
//
// SpriteRequest/SpriteManifest (ARCH §10.3, §14.1) and EncodeSettings (ARCH §12.4) value types.

import 'package:test/test.dart';
import 'package:danaview_editor_core/plan.dart';

void main() {
  group('SpriteRequest', () {
    SpriteRequest request({String key = 'k1', double scale = 1.5, bool reveal = false, Map<String, Object?>? spec}) => SpriteRequest(
          key: key,
          itemId: 'it_title',
          source: SpriteSource.text,
          layoutSpec: spec ?? {'text': 'Hello', 'size': 48, 'nested': {'a': [1, 2]}},
          scale: scale,
          canvasWidth: 1920,
          canvasHeight: 1080,
          fontsVersion: 3,
          reveal: reveal,
        );

    test('value equality compares the layout spec deeply', () {
      expect(request(), request());
      expect(request().hashCode, request().hashCode);
      expect(request(), isNot(request(key: 'k2')));
      expect(request(), isNot(request(scale: 2)));
      expect(request(), isNot(request(reveal: true)));
      expect(request(), isNot(request(spec: {'text': 'Bye'})));
    });

    test('the layout spec is copied and unmodifiable', () {
      final spec = <String, Object?>{'text': 'x'};
      final r = request(spec: spec);
      spec['text'] = 'changed';
      expect(r.layoutSpec['text'], 'x');
      expect(() => r.layoutSpec['text'] = 'y', throwsUnsupportedError);
    });

    test('sources', () => expect(SpriteSource.values.map((e) => e.name), ['text', 'cue']));
  });

  group('SpriteManifest', () {
    const file = SpriteFile(uri: 'file:///cache/danaview/editor/sprites/k1.vsprite', sw: 900, sh: 160, sscale: 1.5, reveal: true);

    test('looks files up by request key; empty has none', () {
      final m = SpriteManifest({'k1': file});
      expect(m['k1'], file);
      expect(m['k2'], isNull);
      expect(SpriteManifest.empty.files, isEmpty);
      expect(() => m.files['x'] = file, throwsUnsupportedError);
    });

    test('SpriteFile equality', () {
      expect(file, const SpriteFile(uri: 'file:///cache/danaview/editor/sprites/k1.vsprite', sw: 900, sh: 160, sscale: 1.5, reveal: true));
      expect(file.hashCode, const SpriteFile(uri: 'file:///cache/danaview/editor/sprites/k1.vsprite', sw: 900, sh: 160, sscale: 1.5, reveal: true).hashCode);
      expect(file, isNot(const SpriteFile(uri: 'file:///x', sw: 900, sh: 160, sscale: 1.5, reveal: true)));
      expect(file, isNot(const SpriteFile(uri: 'file:///cache/danaview/editor/sprites/k1.vsprite', sw: 901, sh: 160, sscale: 1.5, reveal: true)));
    });
  });

  group('EncodeSettings', () {
    const s = EncodeSettings(width: 1920, height: 1080, fps: 30, videoBitrate: 12000000);

    test('defaults (ARCH §12.4)', () {
      expect(s.container, ExportContainer.mp4);
      expect(s.codec, VideoCodec.h264);
      expect(s.audioBitrate, 192000);
      expect(s.audioSampleRate, 48000);
      expect(s.audioChannels, 2);
      expect(s.keyframeIntervalMs, 2000);
      expect(s.stripLocation, isTrue);
    });

    test('enums cover mp4/mov and h264/hevc', () {
      expect(ExportContainer.values.map((e) => e.name), ['mp4', 'mov']);
      expect(VideoCodec.values.map((e) => e.name), ['h264', 'hevc']);
    });

    test('toJson / fromJson round-trip', () {
      final custom = s.copyWith(container: ExportContainer.mov, codec: VideoCodec.hevc, width: 3840, height: 2160, fps: 60, videoBitrate: 40000000, audioBitrate: 256000, keyframeIntervalMs: 1000);
      expect(EncodeSettings.fromJson(custom.toJson()), custom);
      expect(EncodeSettings.fromJson(s.toJson()), s);
      expect(s.toJson().keys, containsAll(['container', 'codec', 'width', 'height', 'fps', 'videoBitrate', 'audioBitrate', 'audioSampleRate', 'audioChannels', 'keyframeIntervalMs', 'stripLocation']));
    });

    test('fromJson fills the documented defaults', () {
      final j = EncodeSettings.fromJson({'container': 'mp4', 'codec': 'h264', 'width': 1280, 'height': 720, 'fps': 24, 'videoBitrate': 8000000});
      expect(j.audioBitrate, 192000);
      expect(j.audioSampleRate, 48000);
      expect(j.audioChannels, 2);
      expect(j.keyframeIntervalMs, 2000);
      expect(j.stripLocation, isTrue);
    });

    test('equality, hashCode and copyWith', () {
      expect(s, const EncodeSettings(width: 1920, height: 1080, fps: 30, videoBitrate: 12000000));
      expect(s.hashCode, const EncodeSettings(width: 1920, height: 1080, fps: 30, videoBitrate: 12000000).hashCode);
      expect(s.copyWith(), s);
      expect(s.copyWith(fps: 60), isNot(s));
      expect(s.copyWith(width: 1280).width, 1280);
      expect(s.copyWith(height: 720).height, 720);
      expect(s.copyWith(videoBitrate: 1).videoBitrate, 1);
      expect(s.copyWith(audioBitrate: 96000).audioBitrate, 96000);
      expect(s.copyWith(codec: VideoCodec.hevc).codec, VideoCodec.hevc);
      expect(s.copyWith(container: ExportContainer.mov).container, ExportContainer.mov);
      expect(s.copyWith(keyframeIntervalMs: 500).keyframeIntervalMs, 500);
      expect(s.copyWith().stripLocation, isTrue, reason: 'location is always stripped in v1');
    });
  });
}
