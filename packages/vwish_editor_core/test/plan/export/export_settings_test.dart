// OWNER: CORE-33
//
// Export settings → encode settings (ARCH §14.1): the preset table exactly, Custom (sizes, Match
// project and fixed rates incl. 48, bitrates, container, codec), the auto bitrate table × HEVC ×
// quality, a clamp test per capability flag, the size estimate formula and aspect-mismatch
// detection.

import 'package:test/test.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/plan.dart';

import '../compile_visual/support.dart';

final MediaAsset vA = asset('md_videoA00001', MediaKind.video, duration: 60000000);

EditProject proj({AspectRatio aspect = AspectRatio.landscape16x9, FrameRate rate = FrameRate.fps30, int frames = 60}) => project(
      [mainLane([clip('it_main0000001', 0, frames, 'md_videoA00001', rate: rate)])],
      assets: [vA],
      settings: ProjectSettings(canvas: CanvasSpec(aspect: aspect), frameRate: rate),
    );

ResolvedExport resolve(EditProject p, ExportPresetId preset, {ExportCapabilities caps = const ExportCapabilities(), ExportSettings? s}) =>
    resolveExportSettings(p, (s ?? ExportSettings()).copyWith(preset: preset), capabilities: caps);

/// (w, h, fps, codec, video Mbps, audio kbps, container).
(int, int, int, VideoCodec, double, int, ExportContainer) row(ResolvedExport r) => (
      r.encode.width,
      r.encode.height,
      r.encode.fps,
      r.encode.codec,
      r.encode.videoBitrate / 1e6,
      r.encode.audioBitrate ~/ 1000,
      r.encode.container,
    );

void main() {
  const hevc = ExportCapabilities(hevcEncode: true, movContainer: true);
  const h264 = VideoCodec.h264;
  const mp4 = ExportContainer.mp4;

  group('preset table (ARCH §14.1)', () {
    test('16:9 project at 30 fps', () {
      final p = proj();
      expect(row(resolve(p, ExportPresetId.youtube)), (1920, 1080, 30, h264, 8.0, 192, mp4));
      expect(row(resolve(p, ExportPresetId.youtube4k, caps: hevc)), (3840, 2160, 30, VideoCodec.hevc, 24.0, 256, mp4));
      expect(row(resolve(p, ExportPresetId.youtube4k)), (3840, 2160, 30, h264, 40.0, 256, mp4));
      expect(row(resolve(p, ExportPresetId.youtubeShorts)), (1080, 1920, 30, h264, 8.0, 192, mp4));
      expect(row(resolve(p, ExportPresetId.instagramReels)), (1080, 1920, 30, h264, 8.0, 128, mp4));
      expect(row(resolve(p, ExportPresetId.instagramFeed)), (1080, 1350, 30, h264, 6.0, 128, mp4));
      expect(row(resolve(p, ExportPresetId.tiktok)), (1080, 1920, 30, h264, 8.0, 128, mp4));
      expect(row(resolve(p, ExportPresetId.custom)), (1920, 1080, 30, h264, 8.0, 192, mp4));
    });

    test('9:16 project at 60 fps', () {
      final p = proj(aspect: AspectRatio.portrait9x16, rate: FrameRate.fps60, frames: 120);
      expect(row(resolve(p, ExportPresetId.youtube)), (1080, 1920, 60, h264, 12.0, 192, mp4));
      expect(row(resolve(p, ExportPresetId.youtube4k, caps: hevc)), (2160, 3840, 60, VideoCodec.hevc, 36.0, 256, mp4));
      expect(row(resolve(p, ExportPresetId.youtube4k)), (2160, 3840, 60, h264, 60.0, 256, mp4));
      expect(row(resolve(p, ExportPresetId.youtubeShorts)), (1080, 1920, 60, h264, 12.0, 192, mp4));
      expect(row(resolve(p, ExportPresetId.instagramReels)), (1080, 1920, 30, h264, 8.0, 128, mp4));
      expect(row(resolve(p, ExportPresetId.instagramFeed)), (1080, 1350, 30, h264, 6.0, 128, mp4));
      expect(row(resolve(p, ExportPresetId.tiktok)), (1080, 1920, 60, h264, 8.0, 128, mp4), reason: '60 if the project is 60');
    });

    test('TikTok stays at 30 for a 50 fps project; YouTube follows the project', () {
      final p = proj(rate: FrameRate.fps50, frames: 100);
      expect(resolve(p, ExportPresetId.tiktok).encode.fps, 30);
      expect(resolve(p, ExportPresetId.youtube).encode.fps, 50);
      expect(resolve(p, ExportPresetId.youtube).encode.videoBitrate, 12000000);
    });

    test('every preset is listed once, in UI order', () {
      expect(ExportPreset.all.map((p) => p.id), ExportPresetId.values);
      expect(ExportPreset.all.map((p) => p.label),
          ['YouTube', 'YouTube 4K', 'YouTube Shorts', 'Instagram Reels', 'Instagram Feed', 'TikTok', 'Custom']);
    });
  });

  group('auto bitrate table × HEVC × quality', () {
    test('table rows', () {
      for (final (side, lo, hi) in const [(720, 5.0, 7.5), (1080, 8.0, 12.0), (1440, 16.0, 24.0), (2160, 40.0, 60.0)]) {
        expect(autoVideoBitrate(shortSide: side, fps: 30), lo * 1e6);
        expect(autoVideoBitrate(shortSide: side, fps: 48), hi * 1e6);
        expect(autoVideoBitrate(shortSide: side, fps: 25, codec: VideoCodec.hevc), lo * 0.6 * 1e6);
      }
      expect(bitrateRowFor(540), 720);
      expect(bitrateRowFor(1350), 1440);
      expect(bitrateRowFor(4320), 2160);
    });

    test('quality multiplies every preset', () {
      final p = proj();
      for (final (q, f) in const [
        (ExportQuality.smaller, 0.6),
        (ExportQuality.balanced, 1.0),
        (ExportQuality.high, 1.5),
        (ExportQuality.maximum, 2.0),
      ]) {
        expect(resolve(p, ExportPresetId.youtube, s: ExportSettings(quality: q)).encode.videoBitrate, (8e6 * f).round());
        expect(resolve(p, ExportPresetId.instagramFeed, s: ExportSettings(quality: q)).encode.videoBitrate, (6e6 * f).round());
      }
    });
  });

  group('Custom', () {
    test('short sides 720/1080/1440/2160 at the project aspect', () {
      final p = proj(aspect: AspectRatio.portrait4x5);
      final sizes = [
        for (final side in customShortSides)
          (resolve(p, ExportPresetId.custom, s: ExportSettings(shortSide: side)).encode.width,
              resolve(p, ExportPresetId.custom, s: ExportSettings(shortSide: side)).encode.height),
      ];
      expect(sizes, [(720, 900), (1080, 1350), (1440, 1800), (2160, 2700)]);
      expect(() => ExportSettings(shortSide: 1000), throwsArgumentError);
    });

    test('fps: Match project by default (a 48 fps project exports at 48), or 24/25/30/48/50/60', () {
      final p48 = proj(rate: FrameRate.fps48, frames: 96);
      expect(resolve(p48, ExportPresetId.custom).encode.fps, 48);
      expect(resolve(p48, ExportPresetId.custom).encode.videoBitrate, 12000000);
      for (final f in customFrameRates) {
        expect(resolve(p48, ExportPresetId.custom, s: ExportSettings(fps: f)).encode.fps, f);
      }
      expect(() => ExportSettings(fps: 29), throwsArgumentError);
    });

    test('fps clamped where maxFpsByHeight forbids', () {
      final p48 = proj(rate: FrameRate.fps48, frames: 96);
      const caps = ExportCapabilities(maxFpsByHeight: {720: 60, 1080: 30, 2160: 24});
      final r = resolve(p48, ExportPresetId.custom, caps: caps);
      expect(r.encode.fps, 24, reason: '48 halves to 24 within 30');
      expect(r.notices.map((n) => n.code), contains(ExportNoticeCode.fpsClamped));
      expect(resolve(p48, ExportPresetId.custom, caps: caps, s: ExportSettings(shortSide: 720)).encode.fps, 48);
      expect(resolve(p48, ExportPresetId.custom, caps: caps, s: ExportSettings(fps: 60)).encode.fps, 30);
      expect(resolve(p48, ExportPresetId.custom, caps: caps, s: ExportSettings(fps: 50)).encode.fps, 25);
      expect(resolve(p48, ExportPresetId.custom, caps: caps, s: ExportSettings(shortSide: 2160, fps: 60)).encode.fps, 24);
      expect(resolve(p48, ExportPresetId.custom, caps: caps, s: ExportSettings(shortSide: 1440, fps: 25)).encode.fps, 24,
          reason: '1440 uses the 2160 limit');
      expect(caps.maxFpsFor(4320), 24);
      expect(const ExportCapabilities().maxFpsFor(2160), 60);
      expect(clampExportFps(30, 25), 25);
    });

    test('explicit bitrates are clamped to 2–100 Mbps and 96–320 kbps', () {
      final p = proj();
      ResolvedExport r(double v, int a) =>
          resolve(p, ExportPresetId.custom, s: ExportSettings(videoBitrateMbps: v, audioBitrateKbps: a));
      expect((r(1, 64).encode.videoBitrate, r(1, 64).encode.audioBitrate), (2000000, 96000));
      expect((r(150, 400).encode.videoBitrate, r(150, 400).encode.audioBitrate), (100000000, 320000));
      expect((r(25, 256).encode.videoBitrate, r(25, 256).encode.audioBitrate), (25000000, 256000));
      expect(r(1, 64).notices.map((n) => n.code), contains(ExportNoticeCode.bitrateClamped));
      expect(r(25, 256).notices, isEmpty);
      // Presets ignore Custom-only fields.
      expect(resolve(p, ExportPresetId.youtube, s: ExportSettings(videoBitrateMbps: 50, audioBitrateKbps: 320)).encode.videoBitrate, 8000000);
    });
  });

  group('capability clamps (one per flag)', () {
    final p = proj();

    test('hevcEncode', () {
      final s = ExportSettings(codec: VideoCodec.hevc);
      expect(resolve(p, ExportPresetId.custom, s: s, caps: hevc).encode.codec, VideoCodec.hevc);
      final r = resolve(p, ExportPresetId.custom, s: s);
      expect(r.encode.codec, VideoCodec.h264);
      expect(r.notices.single.code, ExportNoticeCode.hevcUnavailable);
      expect(resolve(p, ExportPresetId.youtube, caps: hevc).encode.codec, VideoCodec.h264, reason: 'YouTube is H.264');
    });

    test('h264Encode', () {
      const hevcOnly = ExportCapabilities(h264Encode: false, hevcEncode: true);
      expect(resolve(p, ExportPresetId.youtube, caps: hevcOnly).encode.codec, VideoCodec.hevc);
    });

    test('movContainer', () {
      final s = ExportSettings(container: ExportContainer.mov);
      expect(resolve(p, ExportPresetId.custom, s: s, caps: hevc).encode.container, ExportContainer.mov);
      final r = resolve(p, ExportPresetId.custom, s: s);
      expect(r.encode.container, ExportContainer.mp4);
      expect(r.notices.single.code, ExportNoticeCode.movUnavailable);
      expect(resolve(p, ExportPresetId.youtube, s: s, caps: hevc).encode.container, ExportContainer.mp4, reason: 'presets write MP4');
    });

    test('maxExportSize', () {
      const hd = ExportCapabilities(maxExportLongSide: 1920, maxExportShortSide: 1080);
      final r = resolve(p, ExportPresetId.youtube4k, caps: hd);
      expect((r.encode.width, r.encode.height), (1920, 1080));
      expect(r.encode.videoBitrate, 8000000, reason: 'bitrate follows the clamped size');
      expect(r.notices.map((n) => n.code), contains(ExportNoticeCode.resolutionClamped));
      const small = ExportCapabilities(maxExportLongSide: 1280, maxExportShortSide: 720);
      final shorts = resolve(p, ExportPresetId.youtubeShorts, caps: small);
      expect((shorts.encode.width, shorts.encode.height), (720, 1280));
      const tiny = ExportCapabilities(maxExportLongSide: 300, maxExportShortSide: 200);
      final t = resolve(p, ExportPresetId.youtube, caps: tiny);
      expect(t.encode.width <= 300 && t.encode.height <= 200 && t.encode.width.isEven && t.encode.height.isEven, isTrue);
      expect(resolve(p, ExportPresetId.youtube, caps: hd).notices, isEmpty);
    });

    test('maxFpsByHeight', () {
      final p60 = proj(rate: FrameRate.fps60, frames: 120);
      final r = resolve(p60, ExportPresetId.youtube, caps: const ExportCapabilities(maxFpsByHeight: {1080: 30}));
      expect(r.encode.fps, 30);
      expect(r.encode.videoBitrate, 8000000, reason: '≤ 30 fps row');
    });

    test('maxTextureSize (sprite raster clamp)', () {
      final titled = project([
        mainLane([clip('it_main0000001', 0, 60, 'md_videoA00001')]),
        Track(id: const TrackId('tr_text'), kind: TrackKind.text, items: [
          TextItem(
            id: const ItemId('it_title000001'),
            start: 0,
            duration: fr(60),
            text: 'Title',
            transform: const Transform2D(scale: 8),
            style: const TextStyleSpec(fontSizePt: 200),
          ),
        ]),
      ], assets: [vA]);
      final big = exportSpriteRequests(titled, ExportSettings(preset: ExportPresetId.youtube4k), capabilities: const ExportCapabilities(maxTextureSize: 16384)).single;
      final small = exportSpriteRequests(titled, ExportSettings(preset: ExportPresetId.youtube4k), capabilities: const ExportCapabilities(maxTextureSize: 2048)).single;
      expect(big.scale, greaterThan(small.scale));
      expect(small.scale, lessThan(16), reason: 'exportScale 2 × 8 clamped');
    });

    test('maxAudioSpeed', () {
      final fast = project([mainLane([clip('it_fast00000001', 0, 30, 'md_videoA00001', speed: const ConstantSpeed(3))])], assets: [vA]);
      ExportReady ready(double max) => compileExport(fast, ExportSettings(), SpriteManifest.empty,
          resolver: resolverFor(fast), capabilities: ExportCapabilities(maxAudioSpeed: max)) as ExportReady;
      expect(ready(4).plan.audio.single.gain, [const AnimKey(0, 1)]);
      expect(ready(2).plan.audio.single.gain, [const AnimKey(0, 0)]);
    });

    test('holdFrame (a pending still blocks the export either way)', () {
      final still = asset('md_still000001', MediaKind.still,
          w: null, h: null, status: const PendingStatus('job'), derived: const StillSpec(MediaId('md_videoA00001'), 1000000, sourceQuickHash: 'qh_md_videoA00001'));
      final p = project([mainLane([clip('it_still000001', 0, 30, 'md_still000001')])], assets: [vA, still]);
      for (final hold in [true, false]) {
        final r = compileExport(p, ExportSettings(), SpriteManifest.empty, resolver: resolverFor(p), capabilities: ExportCapabilities(holdFrame: hold));
        expect((r as ExportBlocked).requirements.pendingStill, ['md_still000001']);
      }
    });
  });

  test('size estimate is (video + audio bps)·sec/8·1.02 (within 1%)', () {
    final p = proj(frames: 1800); // 60 s
    final r = resolve(p, ExportPresetId.youtube);
    final formula = (8000000 + 192000) * 60 / 8 * 1.02;
    expect((r.estimatedBytes - formula).abs() / formula, lessThan(0.01));
    expect(r.estimatedBytes, 62668800);
    expect(estimateExportBytes(videoBitrate: 40000000, audioBitrate: 256000, durationUs: 10000000), 51326400);
  });

  test('aspect mismatch: notice with "Change project to 9:16", never for the project aspect', () {
    final landscape = proj();
    final r = resolve(landscape, ExportPresetId.instagramReels);
    final n = r.notices.single;
    expect(n.code, ExportNoticeCode.aspectMismatch);
    expect(n.message, 'Change project to 9:16');
    expect(n.suggestedAspect, AspectRatio.portrait9x16);
    expect(r.aspectMismatch, isTrue);
    expect(resolve(landscape, ExportPresetId.instagramFeed).notices.single.message, 'Change project to 4:5');
    expect(resolve(landscape, ExportPresetId.youtube).aspectMismatch, isFalse);
    final portrait = proj(aspect: AspectRatio.portrait9x16);
    expect(resolve(portrait, ExportPresetId.tiktok).aspectMismatch, isFalse);
    expect(resolve(portrait, ExportPresetId.instagramFeed).aspectMismatch, isTrue);
    expect(aspectsDiffer(1080, 1920, 1080, 1920), isFalse);
  });

  test('settings value semantics', () {
    final a = ExportSettings(burnInSubtitles: {const TrackId('tr_s'): false}, sideFiles: {SideFileFormat.srt});
    expect(a, ExportSettings(burnInSubtitles: {const TrackId('tr_s'): false}, sideFiles: {SideFileFormat.srt}));
    expect(a.copyWith(fps: 48).fps, 48);
    expect(a.copyWith(fps: 48).copyWith(fps: null).fps, isNull);
    expect(a.hashCode, ExportSettings(burnInSubtitles: {const TrackId('tr_s'): false}, sideFiles: {SideFileFormat.srt}).hashCode);
  });
}
