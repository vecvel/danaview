// OWNER: CORE-33
//
// Multi-pass precompose disk estimate (FIX-PREFLIGHT, D-45(B), ARCH §14.1 step 5): one
// intermediate I = 4 · video bitrate · (dur + 1 grid frame) / 8 · 1.02, the extra work-volume
// bytes beyond the single-pass estimate are max(2·I, I + output) − output, in both regimes
// (2·I wins, which is every real export, and I + output wins), and ExportReady exposes it over
// the plan's duration and grid.

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
    final extra = precomposeExtraBytesOf(encode, 60000000, 30);
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
    expect(precomposeExtraBytesOf(encode, 10000000, 25), i);
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
