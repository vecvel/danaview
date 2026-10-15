// OWNER: QA-00
//
// Test media in the app sandbox. The ENG-05 fixtures are copied from `E2eConfig.fixturesDir` into
// `<StoreRoots.documents>/e2e_media/` (the app's own Documents, so an import is a
// `documentsReference` per ARCH §9.1 and relink scenarios can make a file go missing), plus the
// small files the suite writes itself: a `.cube` LUT and SRT/VTT subtitle files.

import 'dart:io';

import 'e2e_app.dart';
import 'e2e_config.dart';

/// ENG-05 fixture names used by the scenarios.
abstract final class Fx {
  /// H.264 1080p30, 8 s, barcodes 0..239, no audio.
  static const String frameCounter = 'frame_counter_1080p30.mp4';

  /// The frame_counter video with a 1 kHz tone (AAC).
  static const String toneUnderVideo = 'tone_under_video.mp4';

  /// 10 s synthesized English speech (AAC).
  static const String speech = 'speech_10s.m4a';

  /// 10 s 1 kHz mono tone at −12 dBFS (WAV).
  static const String tone1k = 'tone_1khz.wav';

  /// A 6 s A/V clip with flashes and clicks.
  static const String clapFlash = 'clap_flash_av.mp4';

  /// A 4K still.
  static const String still4k = 'still_4k.jpg';
}

/// The suite's media folder and generated files.
abstract final class E2eMedia {
  /// `<documents>/e2e_media`.
  static String get dir => '${E2eApp.world.runtime.roots.documents}/e2e_media';

  /// The sandbox copy of fixture [name] (copied on first use).
  static String fixture(String name, {String? as}) {
    final target = File('$dir/${as ?? name}');
    if (target.existsSync()) return target.path;
    final source = File('${E2eConfig.fixturesDir}/$name');
    if (!source.existsSync()) {
      throw StateError('Fixture $name is not staged in ${E2eConfig.fixturesDir}. Pass --dart-define=DV_E2E_FIXTURES=<abs path of '
          'packages/danaview_editor_engine/test_fixtures/media> (iOS Simulator) or run tool/e2e_host.sh stage (Android).');
    }
    target.parent.createSync(recursive: true);
    source.copySync(target.path);
    return target.path;
  }

  /// A fresh sandbox copy of fixture [name] under a unique name (for relink scenarios).
  static String uniqueCopy(String name, String tag) {
    final dot = name.lastIndexOf('.');
    final unique = '${name.substring(0, dot)}-$tag-${DateTime.now().millisecondsSinceEpoch}${name.substring(dot)}';
    return fixture(name, as: unique);
  }

  /// A 2×2×2 `.cube` that swaps red and blue (visible, valid, tiny).
  static String cubeLut() {
    final f = File('$dir/e2e_swap_rb.cube');
    if (!f.existsSync()) {
      f.parent.createSync(recursive: true);
      final b = StringBuffer()
        ..writeln('TITLE "E2E swap red and blue"')
        ..writeln('LUT_3D_SIZE 2');
      // Red varies fastest.
      for (var bl = 0; bl < 2; bl++) {
        for (var g = 0; g < 2; g++) {
          for (var r = 0; r < 2; r++) {
            b.writeln('${bl.toDouble()} ${g.toDouble()} ${r.toDouble()}');
          }
        }
      }
      f.writeAsStringSync(b.toString());
    }
    return f.path;
  }

  /// An SRT file with [cues] (start µs, end µs, text), written as `<name>.<lang>.srt`.
  static String srt(String name, List<(int, int, String)> cues, {String lang = 'en'}) {
    final f = File('$dir/$name.$lang.srt');
    f.parent.createSync(recursive: true);
    final b = StringBuffer();
    for (final (i, (s, e, text)) in cues.indexed) {
      b
        ..write('${i + 1}\r\n')
        ..write('${_stamp(s)} --> ${_stamp(e)}\r\n')
        ..write('$text\r\n\r\n');
    }
    f.writeAsStringSync(b.toString());
    return f.path;
  }

  static String _stamp(int us) {
    final ms = (us / 1000).round();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(ms ~/ 3600000)}:${two(ms ~/ 60000 % 60)}:${two(ms ~/ 1000 % 60)},${(ms % 1000).toString().padLeft(3, '0')}';
  }
}
