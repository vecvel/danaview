// OWNER: CORE-02
//
// Writes test/fixtures/vectors/frame_grid.json: the shared frame-grid vectors of ARCH §5 (D-35),
// read by the Dart (CORE-02), Swift (IOS-08/10/11) and Kotlin (AND-08/10) tests.
//
//   dart run tool/gen_frame_vectors.dart          # rewrite the file
//   dart run tool/gen_frame_vectors.dart --check  # exit 1 if the committed file differs
//
// `androidSeekMsRounding` stays null until ENG-06 records AND-01's measurement ("floor" when
// Media3 shows the first frame with pts ≥ the seek position, "ceil" when it shows the last frame
// with pts ≤ the position). Regeneration preserves the recorded value.

import 'dart:convert';
import 'dart:io';

import 'package:danaview_editor_core/model.dart';

const String _path = 'test/fixtures/vectors/frame_grid.json';

void main(List<String> args) {
  final file = File(_path);
  Object? recordedRounding;
  if (file.existsSync()) {
    final existing = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    recordedRounding = existing['androidSeekMsRounding'];
  }
  final text = '${const JsonEncoder.withIndent('  ').convert(buildVectors(androidSeekMsRounding: recordedRounding))}\n';
  if (args.contains('--check')) {
    if (!file.existsSync() || file.readAsStringSync() != text) {
      stderr.writeln('$_path is stale: run dart run tool/gen_frame_vectors.dart');
      exitCode = 1;
    }
    return;
  }
  file
    ..createSync(recursive: true)
    ..writeAsStringSync(text);
  stdout.writeln('wrote $_path');
}

/// The vector document.
Map<String, Object?> buildVectors({Object? androidSeekMsRounding}) => {
      'schema': 1,
      'generatedBy': 'packages/danaview_editor_core/tool/gen_frame_vectors.dart',
      'rule': 'plan time of frame k = ceil(k*1e6/fps); platform time tau -> k = round(tau*fps/1e6); '
          'P(k) = round(k*1e6/fps); evaluate at timeOfFrame(k) (ARCH §5, D-35)',
      'androidSeekMsRounding': androidSeekMsRounding,
      'rates': [for (final fps in FrameRate.supportedProjectRates) _rate(fps)],
    };

Map<String, Object?> _rate(int fps) {
  final r = FrameRate(fps, 1);
  final h = floorDiv(microsPerSecond, 2 * fps) - 1; // half a frame − 1 µs (≥ 1 µs margin)
  final hour = 3600 * fps;
  final ks = <int>{0, 1, 2, 3, fps - 1, fps, fps + 1, fps + 2, 1000, hour, hour + 1, hour + 2, 24 * hour - 1}.toList()..sort();
  return {
    'fps': fps,
    'halfFrameMinus1Us': h,
    'frames': [
      for (final k in ks)
        () {
          final t = r.timeOfFrame(k);
          final floorT = floorDiv(k * microsPerSecond, fps);
          final p = r.platformTimeOfFrame(k);
          return {
            'k': k,
            'timeOfFrame': t,
            'floorTime': floorT,
            'platformTime': p,
            'rational': [k, fps],
            'frameIndexOf': {'tMinus1': r.frameIndexOf(t - 1), 't': r.frameIndexOf(t), 'tPlus1': r.frameIndexOf(t + 1)},
            'nearest': {
              'timeOfFrame': r.frameIndexNearest(t),
              'floorTime': r.frameIndexNearest(floorT),
              'platformTime': r.frameIndexNearest(p),
              'rational': r.frameIndexOfRational(k, fps),
            },
            'nearestAtPlatformPlusHalf': r.frameIndexNearest(p + h),
            'nearestAtPlatformMinusHalf': r.frameIndexNearest(p - h),
          };
        }(),
    ],
  };
}
