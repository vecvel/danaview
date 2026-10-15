// OWNER: QA-11
//
// Export preset matrix through the real plugin (BUILD_PLAN QA-11 part 2, ARCH §14.1 preset table,
// §14.4): every preset — YouTube 1080p, YouTube 4K where the capabilities allow it, YouTube Shorts
// 1080×1920, Instagram Reels 1080×1920, Instagram Feed 1080×1350, TikTok 1080×1920 (30 and, for a
// 60 fps project, 60 fps) and Custom 48 fps — is resolved by core's `resolveExportSettings`
// (CORE-33, the same function the export flow uses) against this device's capabilities, exported
// from a moving full-frame noise picture with a 1 kHz tone, and checked with QA-11's conformance
// rules (conformance_test.dart). Every row prints its measured values as `QA11|preset|…`.
//
// Portrait sizes: an encoder that refuses a portrait size must take the landscape-plus-rotation
// retry (display size still portrait, rotation 90/270 in the track matrix, `portraitRetried`
// warning) or fail visibly with `encoderSizeLimit` — never silently (a landscape output without
// rotation, or any other failure, fails the row).
//
//   cd packages/danaview_editor_engine/example
//   flutter test integration_test/preset_matrix_test.dart -d <iOS simulator | Android emulator | device>
//
// The API 35 emulator run is the Windows lane; the low/mid lab devices are deferred (no device).

// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart'
    show EditorCapabilities, EngineErrorCode, EncodeSettings;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'conformance_test.dart' as qa;

const int _durUs = 3000000;

/// Engine capabilities -> core export capabilities (the same mapping as UX-39's
/// `exportCapabilitiesOf`, which lives in the app package).
ExportCapabilities _exportCaps(EditorCapabilities c) {
  final size = c.maxExportSize;
  final long = size.width > size.height ? size.width : size.height;
  final short = size.width > size.height ? size.height : size.width;
  return ExportCapabilities(
    h264Encode: c.h264Encode,
    hevcEncode: c.hevcEncode,
    movContainer: c.movContainer,
    maxExportLongSide: long.round(),
    maxExportShortSide: short.round(),
    maxFpsByHeight: c.maxFpsByHeight,
    maxTextureSize: c.maxTextureSize,
    maxAudioSpeed: c.maxAudioSpeed,
    holdFrame: c.holdFrame,
  );
}

EditProject _project(AspectRatio aspect, FrameRate rate) {
  final now = DateTime.utc(2026, 10, 15);
  return EditProject(
    id: const ProjectId('pr_qa11matrix'),
    meta: ProjectMeta(name: 'QA-11 matrix', createdAt: now, updatedAt: now),
    timeline: Timeline(settings: ProjectSettings(canvas: CanvasSpec(aspect: aspect), frameRate: rate)),
  );
}

/// One matrix row: (name, project aspect, project rate, settings, expected w, h, fps).
typedef _Row = (String, AspectRatio, FrameRate, ExportSettings, int, int, int);

final List<_Row> _rows = [
  ('youtube_1080p', AspectRatio.landscape16x9, FrameRate.fps30, ExportSettings(preset: ExportPresetId.youtube), 1920, 1080, 30),
  ('youtube_4k', AspectRatio.landscape16x9, FrameRate.fps30, ExportSettings(preset: ExportPresetId.youtube4k), 3840, 2160, 30),
  ('youtube_shorts', AspectRatio.portrait9x16, FrameRate.fps30, ExportSettings(preset: ExportPresetId.youtubeShorts), 1080, 1920, 30),
  ('instagram_reels', AspectRatio.portrait9x16, FrameRate.fps30, ExportSettings(preset: ExportPresetId.instagramReels), 1080, 1920, 30),
  ('instagram_feed', AspectRatio.portrait4x5, FrameRate.fps30, ExportSettings(preset: ExportPresetId.instagramFeed), 1080, 1350, 30),
  ('tiktok', AspectRatio.portrait9x16, FrameRate.fps30, ExportSettings(preset: ExportPresetId.tiktok), 1080, 1920, 30),
  ('tiktok_60', AspectRatio.portrait9x16, FrameRate.fps60, ExportSettings(preset: ExportPresetId.tiktok), 1080, 1920, 60),
  ('custom_48fps', AspectRatio.landscape16x9, FrameRate.fps30, ExportSettings(preset: ExportPresetId.custom, shortSide: 1080, fps: 48), 1920, 1080, 48),
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory base;
  setUp(() => base = Directory.systemTemp.createTempSync('danaview_qa11_matrix'));
  tearDown(() {
    if (base.existsSync()) base.deleteSync(recursive: true);
  });

  test('the matrix covers every preset of the ARCH §14.1 table', () {
    expect({for (final r in _rows) r.$4.preset}, ExportPreset.all.map((p) => p.id).toSet());
    // Unclamped, the table gives the expected sizes and rates.
    for (final (name, aspect, rate, settings, w, h, fps) in _rows) {
      final e = resolveExportSettings(_project(aspect, rate), settings).encode;
      expect((e.width, e.height, e.fps), (w, h, fps), reason: name);
    }
  });

  testWidgets('every preset exports and passes conformance', (tester) async {
    final env = await qa.Qa11Env.open(base);
    if (env == null) return;
    final caps = _exportCaps(env.caps);
    final assets = {
      'md_noise000001': qa.PlanJsonKit.imageAsset(env.noise, qa.noiseSide, qa.noiseSide),
      'md_tone01000': qa.PlanJsonKit.audioAsset(env.tone(1000), 10000000),
    };
    var accounted = 0;
    for (final (name, aspect, rate, settings, w, h, fps) in _rows) {
      final resolved = resolveExportSettings(_project(aspect, rate), settings, capabilities: caps);
      final EncodeSettings encode = resolved.encode;
      final notices = resolved.notices.map((n) => n.code.name).toList();
      if (name == 'youtube_4k' && (encode.width, encode.height) != (w, h)) {
        debugPrint('QA11|preset|name=$name|skipped=capabilities (maxExport ${caps.maxExportLongSide}x${caps.maxExportShortSide})'
            '|resolved=${encode.width}x${encode.height}|notices=${notices.join(',')}');
        continue;
      }
      expect((encode.width, encode.height), (w, h), reason: '$name: size (notices $notices)');
      if (encode.fps != fps) {
        // A device clamp (maxFpsByHeight) must be announced.
        expect(notices, contains('fpsClamped'), reason: '$name: fps $fps -> ${encode.fps} silently');
      }
      final plan = qa.PlanJsonKit.plan(w: encode.width, h: encode.height, fps: encode.fps, durUs: _durUs, assets: assets, layers: [
        qa.PlanJsonKit.movingImage('it_noise000001#v', 'md_noise000001', 0, _durUs, encode.width, encode.height),
      ], audio: [
        qa.PlanJsonKit.audioSeg('it_tone0000001#a', 'md_tone01000', [
          [0, _durUs, 0, _durUs],
        ], [
          [0, 1],
        ]),
      ]);
      final run = await env.export(name, plan, encode);
      final failure = run.failure;
      if (failure != null) {
        // The only acceptable failure is a visible encoder size refusal of a portrait size.
        debugPrint('QA11|preset|name=$name|failed=${failure.code.name}|warnings=${run.warnings.join(',')}');
        expect(failure.code, EngineErrorCode.encoderSizeLimit, reason: '$name: ${failure.code} ${failure.debugDetail}');
        expect(encode.height > encode.width, isTrue, reason: '$name: only portrait sizes may be refused');
        accounted++;
        continue;
      }
      final row = qa.checkConformance(run, planDurUs: _durUs);
      row.values['preset'] = settings.preset.name;
      row.values['notices'] = notices.join(',');
      row.values['portrait'] = encode.height > encode.width
          ? (run.facts!.videoTracks.single.rotation == 0 ? 'native' : 'landscape+rotation retry')
          : 'n/a';
      debugPrint(row.line('preset'));
      accounted++;
      env.discard(run);
    }
    expect(accounted, greaterThanOrEqualTo(_rows.length - 1), reason: 'only 4K may be skipped by capabilities');
  }, timeout: const Timeout(Duration(minutes: 40)));
}
