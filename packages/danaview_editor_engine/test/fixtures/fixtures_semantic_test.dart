// OWNER: ENG-05
//
// V-U6: the committed fixtures match manifest.json semantically, and (opt-in, macOS) a fresh
// regeneration with tool/make_fixtures.swift is semantically equivalent to the committed set.
//
//   flutter test test/fixtures/fixtures_semantic_test.dart
//   DANAVIEW_FIXTURE_REGEN=1 flutter test test/fixtures/fixtures_semantic_test.dart   # also regenerates

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/fixture_verifier.dart';
import 'support/media_tools.dart';

void main() {
  final skip = skipWithoutFfmpeg;
  final manifest = loadManifest();

  group('committed fixtures', () {
    test('manifest lists every committed media file and nothing else', () {
      final files = fixtureMediaDir
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .where((n) => n != 'manifest.json' && n != 'README.md')
          .toSet();
      expect(manifest.keys.toSet(), files);
      expect(
          manifest.keys,
          containsAll(<String>[
            'frame_counter_1080p30.mp4', 'frame_counter_720p25.mp4', 'frame_counter_720p24.mp4',
            'frame_counter_720p48.mp4', 'frame_counter_720p60.mp4', 'clap_flash_av.mp4',
            'vfr_720p.mp4',
            'hlg_10bit_720p.mov', 'rotated_90.mov', 'speech_10s.m4a', 'surround_5_1.m4a',
            'tone_440hz.wav', 'tone_1khz.wav', 'tone_under_video.mp4', 'still_4k.jpg', 'alpha.png',
            'stereo_440l_880r.wav', 'sample_h264_aac.mkv', 'sample_vp9_opus.webm', //
          ]));
    });

    test('total size stays within the 30 MB budget', () {
      expect(totalBytes(fixtureMediaDir), lessThanOrEqualTo(30 * 1024 * 1024));
    });

    for (final name in fixtureNames(manifest)) {
      test('$name matches its manifest entry', () async {
        await verifyFixture(fixtureMediaDir, name, manifest[name]!);
      }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));
    }
  });

  group('regeneration', () {
    final enabled = Platform.environment['DANAVIEW_FIXTURE_REGEN'] == '1';
    final why = !enabled
        ? 'opt-in: set DANAVIEW_FIXTURE_REGEN=1 (macOS, swiftc and ffmpeg required)'
        : (!Platform.isMacOS ? 'macOS only' : skip);

    test('a fresh run of tool/make_fixtures.swift is semantically equivalent', () async {
      final tmp = Directory.systemTemp.createTempSync('danaview_fixture_regen_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final bin = '${tmp.path}/make_fixtures';
      final compile = await Process.run('swiftc', <String>[
        '-O', '-swift-version', '5', 'tool/make_fixtures.swift', '-o', bin, //
      ]);
      expect(compile.exitCode, 0, reason: '${compile.stderr}');
      final out = Directory('${tmp.path}/media')..createSync();
      final run = await Process.run(bin, <String>['--out', out.path]);
      expect(run.exitCode, 0, reason: '${run.stderr}');
      final fresh = <String, Map<String, dynamic>>{};
      final regenManifest = (await File('${out.path}/manifest.json').readAsString());
      expect(regenManifest, isNotEmpty);
      for (final name in fixtureNames(manifest)) {
        // The regenerated files must satisfy the COMMITTED manifest (semantic equivalence).
        await verifyFixture(out, name, manifest[name]!);
        fresh[name] = manifest[name]!;
      }
      expect(fresh.length, manifest.length);
      expect(totalBytes(out), lessThanOrEqualTo(30 * 1024 * 1024));
    }, skip: why, timeout: const Timeout(Duration(minutes: 10)));
  });
}
