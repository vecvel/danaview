// OWNER: CORE-33
//
// Multi-pass precompose disk estimate (FIX-PREFLIGHT, D-45(B), ARCH §14.1 step 5): one
// intermediate I = 4 · video bitrate · (dur + 1 grid frame) / 8 · 1.02, the extra work-volume
// bytes beyond the single-pass estimate are max(2·I, I + output) − output, in both regimes
// (2·I wins, which is every real export, and I + output wins), and ExportReady exposes it over
// the plan's duration and grid.
//
// FIX-PRECOMPOSE-ESTIMATE: that is AND-19's model; IOS-20 sizes an intermediate at
// min(240 Mbit/s, max(4·v, 0.2 bpp)) plus one 10 s joining segment and needs two alive, so the
// Dart estimate is the per-platform maximum, tested for both platforms and every regime.

import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';

import '../compile_lowering/lowering_support.dart';

void main() {
  test('padded duration adds one grid frame (on and off the grid)', () {
    expect(precomposePaddedDurationUs(60000000, 30), 60033334); // timeOfFrame(1801)
    expect(precomposePaddedDurationUs(10000000, 25), 10040000);
    expect(precomposePaddedDurationUs(1000000, 24), FrameRate.fps24.timeOfFrame(25));
    expect(precomposePaddedDurationUs(1010000, 24), FrameRate.fps24.timeOfFrame(25), reason: 'off-grid end: the next grid frame');
  });

  test('one intermediate is 4 × video bitrate × (dur + 1 frame) / 8 × 1.02', () {
    final i = precomposeIntermediateBytes(videoBitrate: 8000000, durationUs: 60000000, gridFps: 30);
    final formula = 4 * 8000000 * (60000000 + 1000000 / 30) / 1e6 / 8 * 1.02;
    expect((i - formula).abs() / formula, lessThan(0.001));
    expect(i, 244936002);
  });

  test('extra bytes when 2·I is the peak (every real export): 2·I − output', () {
    const encode = EncodeSettings(width: 1920, height: 1080, fps: 30, videoBitrate: 8000000, audioBitrate: 192000);
    final output = estimateEncodeBytes(encode, 60000000);
    expect(output, 62668800);
    final i = precomposeIntermediateBytes(videoBitrate: 8000000, durationUs: 60000000, gridFps: 30);
    final extra = precomposeExtraBytesFor(PrecomposeDiskModel.android, encode, 60000000, 30);
    expect(extra, 2 * i - output);
    expect(extra, 427203204);
    expect(output + extra, 2 * i, reason: 'the work volume must hold two intermediates');
  });

  test('extra bytes when I + output is the peak: exactly one intermediate', () {
    // Artificial settings with audio above 3× video so the output outweighs an intermediate.
    const encode = EncodeSettings(width: 1280, height: 720, fps: 25, videoBitrate: 1000000, audioBitrate: 5000000);
    final output = estimateEncodeBytes(encode, 10000000);
    final i = precomposeIntermediateBytes(videoBitrate: 1000000, durationUs: 10000000, gridFps: 25);
    expect((output, i), (7650000, 5120400));
    expect(precomposeExtraBytesFor(PrecomposeDiskModel.android, encode, 10000000, 25), i);
  });

  group('iOS (IOS-20) model', () {
    test('intermediate bitrate: 4× the export bitrate', () {
      const encode = EncodeSettings(width: 1920, height: 1080, fps: 30, videoBitrate: 8000000);
      expect(iosPrecomposeIntermediateBitrate(encode), 32000000);
    });

    test('intermediate bitrate: 0.2 bit per pixel and frame floor at low bitrates', () {
      const encode = EncodeSettings(width: 1920, height: 1080, fps: 30, videoBitrate: 2000000);
      expect(iosPrecomposeIntermediateBitrate(encode), 12441600); // 1920·1080·30·0.2 > 8 Mbit/s
    });

    test('intermediate bitrate: capped at 240 Mbit/s', () {
      const encode = EncodeSettings(width: 1920, height: 1080, fps: 30, videoBitrate: 100000000);
      expect(iosPrecomposeIntermediateBitrate(encode), 240000000);
    });

    test('one intermediate is b · dur / 8 · 1.02 + one 10 s segment', () {
      const encode = EncodeSettings(width: 1920, height: 1080, fps: 30, videoBitrate: 8000000);
      expect(iosPrecomposeIntermediateBytes(encode, 60000000), 244800000 + 40000000);
      expect(iosPrecomposeIntermediateBytes(encode, -5), 40000000, reason: 'negative duration counts as 0');
    });

    test('extra bytes are two intermediates alive at once', () {
      const encode = EncodeSettings(width: 1920, height: 1080, fps: 30, videoBitrate: 8000000);
      expect(precomposeExtraBytesFor(PrecomposeDiskModel.ios, encode, 60000000, 30), 569600000);
    });
  });

  group('per-platform maximum', () {
    int extra(PrecomposeDiskModel m, EncodeSettings e, int dur, int fps) => precomposeExtraBytesFor(m, e, dur, fps);

    test('a real export: iOS needs more than Android, and the estimate covers it', () {
      const encode = EncodeSettings(width: 1920, height: 1080, fps: 30, videoBitrate: 8000000, audioBitrate: 192000);
      final android = extra(PrecomposeDiskModel.android, encode, 60000000, 30);
      final ios = extra(PrecomposeDiskModel.ios, encode, 60000000, 30);
      expect((android, ios), (427203204, 569600000));
      expect(precomposeExtraBytesOf(encode, 60000000, 30), ios);
    });

    test('every auto preset row and quality: the estimate is at least each platform', () {
      for (final row in autoBitrateTableMbps.keys) {
        for (final fps in [24, 30, 60]) {
          for (final q in ExportQuality.values) {
            for (final codec in VideoCodec.values) {
              final v = autoVideoBitrate(shortSide: row, fps: fps, codec: codec, quality: q);
              final encode = EncodeSettings(width: row * 16 ~/ 9 ~/ 2 * 2, height: row, fps: fps, videoBitrate: v, codec: codec);
              final all = precomposeExtraBytesOf(encode, 30000000, fps);
              for (final m in PrecomposeDiskModel.values) {
                expect(all, greaterThanOrEqualTo(extra(m, encode, 30000000, fps)), reason: '$row p$fps $q $codec $m');
              }
              expect(PrecomposeDiskModel.values.map((m) => extra(m, encode, 30000000, fps)), contains(all));
              if (v * precomposeBitrateFactor <= iosPrecomposeMaxBitrate) {
                expect(all, extra(PrecomposeDiskModel.ios, encode, 30000000, fps),
                    reason: 'below its bitrate cap iOS needs more: $row p$fps $q $codec');
              }
            }
          }
        }
      }
    });

    test('above the iOS 240 Mbit/s cap the Android model wins', () {
      const encode = EncodeSettings(width: 1920, height: 1080, fps: 30, videoBitrate: 100000000, audioBitrate: 192000);
      final android = extra(PrecomposeDiskModel.android, encode, 60000000, 30);
      final ios = extra(PrecomposeDiskModel.ios, encode, 60000000, 30);
      expect(ios, 4272000000);
      expect(android, greaterThan(ios));
      expect(precomposeExtraBytesOf(encode, 60000000, 30), android);
    });

    test('when the output outweighs an intermediate, the maximum still holds', () {
      const encode = EncodeSettings(width: 1280, height: 720, fps: 25, videoBitrate: 1000000, audioBitrate: 5000000);
      final android = extra(PrecomposeDiskModel.android, encode, 10000000, 25);
      final ios = extra(PrecomposeDiskModel.ios, encode, 10000000, 25);
      expect(precomposeExtraBytesOf(encode, 10000000, 25), android > ios ? android : ios);
    });
  });

  test('ExportReady.precomposeExtraBytes uses the plan duration and gridFps (project rate)', () {
    final vA = asset('md_videoA00001', MediaKind.video, duration: 20000000);
    final p = project([mainLane([clip('it_main0000001', 0, 96, 'md_videoA00001', rate: FrameRate.fps48)])],
        assets: [vA], settings: ProjectSettings(frameRate: FrameRate.fps48));
    final s = ExportSettings(preset: ExportPresetId.custom, fps: 24, shortSide: 720);
    final requests = exportSpriteRequests(p, s);
    final r = compileExport(p, s, fakeManifest(requests), resolver: resolverFor(p), spriteRequests: requests) as ExportReady;
    expect(r.plan.canvas.gridFps, 48);
    expect(r.precomposeExtraBytes, precomposeExtraBytesOf(r.encode, r.plan.durUs, 48));
    expect(r.precomposeExtraBytes, greaterThan(r.resolved.estimatedBytes), reason: '2·I − output > output at 4× bitrate');
  });
}
