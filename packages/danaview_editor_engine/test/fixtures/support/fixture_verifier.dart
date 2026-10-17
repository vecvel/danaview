// OWNER: ENG-05
//
// Semantic verification of the ENG-05 fixtures against manifest.json (V-U6): barcodes per frame,
// durations within one frame, stream layout, tone frequency within 1 Hz, levels and channel
// content. Used for the committed files and for a fresh regeneration; byte equality is NOT
// checked because hardware encoders and the speech synthesizer change across OS updates.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor_engine/testing.dart';

import 'media_tools.dart';

/// Names of every fixture in the manifest, in manifest order.
List<String> fixtureNames(Map<String, Map<String, dynamic>> manifest) =>
    manifest.keys.toList()..sort();

Map<String, dynamic>? _stream(Map<String, dynamic> probed, String type) {
  for (final s in (probed['streams'] as List<dynamic>).cast<Map<String, dynamic>>()) {
    if (s['codec_type'] == type) return s;
  }
  return null;
}

double _fps(String rate) {
  final p = rate.split('/');
  return double.parse(p[0]) / double.parse(p[1]);
}

/// Verifies [name] inside [dir] against [expected] (one manifest entry).
Future<void> verifyFixture(Directory dir, String name, Map<String, dynamic> expected) async {
  final path = '${dir.path}/$name';
  expect(File(path).existsSync(), isTrue, reason: '$name missing in ${dir.path}');
  final probed = await probe(path);
  final video = expected['video'] as Map<String, dynamic>?;
  final audio = expected['audio'] as Map<String, dynamic>?;
  final image = expected['image'] as Map<String, dynamic>?;
  final vStream = _stream(probed, 'video');
  final aStream = _stream(probed, 'audio');
  final duration = double.tryParse('${(probed['format'] as Map<String, dynamic>)['duration']}');

  // Stream layout.
  if (video == null && image == null) {
    expect(vStream, isNull, reason: '$name must have no video stream');
  }
  if (audio == null) {
    expect(aStream, isNull, reason: '$name must have no audio stream');
  }
  final expectedDuration = (expected['durationSeconds'] as num?)?.toDouble();
  if (expectedDuration != null) {
    final frame = video != null && video['fps'] != null ? 1 / (video['fps'] as num) : 1 / 30;
    // Audio-only AAC keeps the encoder delay in the container: allow 0.1 s there.
    final tol = video == null ? 0.1 : (aStream != null ? 0.1 : frame + 1e-3);
    expect(duration, isNotNull);
    expect(duration!, closeTo(expectedDuration, tol), reason: '$name duration');
    if (video != null && aStream == null && video['fps'] != null) {
      expect(duration, closeTo(expectedDuration, frame + 1e-3),
          reason: '$name duration within 1 frame');
    }
  }

  if (video != null) {
    expect(vStream, isNotNull, reason: '$name video stream');
    expect(vStream!['codec_name'], video['codec'], reason: '$name codec');
    expect(vStream['width'], video['width'], reason: '$name width');
    expect(vStream['height'], video['height'], reason: '$name height');
    final rotation = (video['rotationDegrees'] as num?)?.toInt() ?? 0;
    final side =
        (vStream['side_data_list'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? const [];
    final rot = side.map((e) => e['rotation']).whereType<num>().toList();
    expect(rot.isEmpty ? 0 : rot.first.toInt(), rotation == 0 ? 0 : -rotation,
        reason: '$name rotation');
    if (video['fps'] != null) {
      expect(
          _fps(vStream['r_frame_rate'] as String), closeTo((video['fps'] as num).toDouble(), 0.01));
    }
    if (video['bitDepth'] == 10) {
      expect(vStream['pix_fmt'], contains('10'));
      expect(vStream['profile'], 'Main 10');
      expect(vStream['color_transfer'], 'arib-std-b67');
      expect(vStream['color_primaries'], 'bt2020');
    }
    if (video['variableFrameRate'] == true) {
      final pts = await videoPts(path);
      final ticks = (video['ptsTicks'] as List<dynamic>).cast<int>();
      expect(pts.length, ticks.length, reason: '$name frame count');
      for (var i = 0; i < ticks.length; i++) {
        expect(pts[i], closeTo(ticks[i] / (video['ptsTimescale'] as num), 0.001),
            reason: '$name pts[$i]');
      }
    }

    // Barcode of every frame.
    final bc = expected['barcode'] as Map<String, dynamic>;
    final dw = (video['displayWidth'] ?? video['width']) as int;
    final dh = (video['displayHeight'] ?? video['height']) as int;
    final got = <int?>[];
    await forEachRgbaFrame(path, width: dw, height: dh, onFrame: (i, rgba) {
      got.add(FrameBarcode.decode(rgba, width: dw, height: dh));
    });
    final first = bc['firstIndex'] as int, last = bc['lastIndex'] as int;
    expect(got.length, video['frameCount'], reason: '$name decoded frame count');
    expect(got, List<int>.generate(last - first + 1, (i) => first + i),
        reason: '$name barcode per frame');
  }

  if (image != null) {
    expect(vStream, isNotNull);
    expect(vStream!['width'], image['width']);
    expect(vStream['height'], image['height']);
    final alpha = (vStream['pix_fmt'] as String).contains('a');
    expect(alpha, image['alpha'], reason: '$name alpha');
    if (expected.containsKey('barcode')) {
      final w = image['width'] as int, h = image['height'] as int;
      int? idx;
      await forEachRgbaFrame(path, width: w, height: h, onFrame: (i, rgba) {
        idx = FrameBarcode.decode(rgba, width: w, height: h);
      });
      expect(idx, (expected['barcode'] as Map<String, dynamic>)['firstIndex']);
    }
  }

  if (audio != null) {
    expect(aStream, isNotNull, reason: '$name audio stream');
    expect(aStream!['codec_name'], audio['codec'], reason: '$name audio codec');
    expect(int.parse('${aStream['sample_rate']}'), audio['sampleRate']);
    expect(aStream['channels'], audio['channels']);
    final layout = audio['channelLayout'] as String?;
    if (layout != null && (name.endsWith('.mp4') || name.endsWith('.m4a'))) {
      expect(aStream['channel_layout'], layout, reason: '$name channel layout');
    }
    await _verifyAudio(path, name, expected, audio);
  }
}

Future<void> _verifyAudio(
    String path, String name, Map<String, dynamic> expected, Map<String, dynamic> audio) async {
  final lossy = audio['codec'] != 'pcm_s16le';
  final levelTol = lossy ? 1.5 : 0.3;
  const sr = 48000;

  if (audio['toneHz'] != null && audio['channels'] == 6) {
    // Centre-only tone: FC carries it, every other channel is silent (AAC leakage < -60 dBFS).
    final fc = await decodeAudioMono(path, channelName: 'FC');
    expect(estimateToneHz(fc, sr), closeTo((audio['toneHz'] as num).toDouble(), 1.0),
        reason: '$name FC tone');
    expect(peakDbfs(fc, from: sr ~/ 4, to: fc.length - sr ~/ 4),
        closeTo((audio['peakDbfs'] as num).toDouble(), levelTol));
    for (final ch in <String>['FL', 'FR', 'LFE', 'BL', 'BR']) {
      final pcm = await decodeAudioMono(path, channelName: ch);
      expect(peakDbfs(pcm, from: sr ~/ 4, to: pcm.length - sr ~/ 4), lessThan(-60),
          reason: '$name $ch must be silent');
    }
  } else if (audio['toneHzLeft'] != null) {
    final l = await decodeAudioMono(path, channelName: 'FL');
    final r = await decodeAudioMono(path, channelName: 'FR');
    expect(estimateToneHz(l, sr), closeTo((audio['toneHzLeft'] as num).toDouble(), 1.0));
    expect(estimateToneHz(r, sr), closeTo((audio['toneHzRight'] as num).toDouble(), 1.0));
    expect(peakDbfs(l), closeTo((audio['peakDbfs'] as num).toDouble(), levelTol));
    expect(peakDbfs(r), closeTo((audio['peakDbfs'] as num).toDouble(), levelTol));
  } else if (audio['toneHz'] != null) {
    final pcm = await decodeAudioMono(path);
    expect(estimateToneHz(pcm, sr), closeTo((audio['toneHz'] as num).toDouble(), 1.0),
        reason: '$name tone');
    if (audio['peakDbfs'] != null) {
      expect(peakDbfs(pcm, from: sr ~/ 4, to: pcm.length - sr ~/ 4),
          closeTo((audio['peakDbfs'] as num).toDouble(), levelTol));
    }
  } else if (audio['clickHz'] != null) {
    final pcm = await decodeAudioMono(path);
    final times = (expected['clickTimesSeconds'] as List<dynamic>).cast<num>();
    for (final t in times) {
      // First sample above 0.02 in [t - 50 ms, t + 100 ms].
      final from = ((t - 0.05) * sr).round(), to = ((t + 0.1) * sr).round();
      var onset = -1;
      for (var i = from; i < to && i < pcm.length; i++) {
        if (pcm[i].abs() > 0.02) {
          onset = i;
          break;
        }
      }
      expect(onset, isNonNegative, reason: '$name click near $t s');
      expect((onset / sr - t).abs(), lessThan(0.025), reason: '$name click onset vs flash time $t');
    }
    // Quiet between clicks.
    final quiet = <int>[
      (0.3 * sr).round(),
      (1.8 * sr).round(),
      (3.2 * sr).round(),
      (5.0 * sr).round()
    ];
    for (final q in quiet) {
      expect(peakDbfs(pcm, from: q, to: q + sr ~/ 4), lessThan(-60),
          reason: '$name silence at ${q / sr}s');
    }
  } else if (audio['speech'] == true) {
    final pcm = await decodeAudioMono(path, sampleRate: 16000);
    expect(pcm.length / 16000, closeTo(10.0, 0.12), reason: 'speech duration');
    var active = 0;
    for (var w = 0; w + 1600 <= pcm.length; w += 1600) {
      if (rmsDbfs(pcm, from: w, to: w + 1600) > -45) active++;
    }
    expect(active, greaterThan(40),
        reason: 'speech must be audible in more than 4 s of 100 ms windows');
    expect(peakDbfs(pcm), greaterThan(-20));
  }
}

/// The total committed size budget (BUILD_PLAN ENG-05: <= 30 MB).
int totalBytes(Directory dir) {
  var sum = 0;
  for (final e in dir.listSync()) {
    if (e is File) sum += e.lengthSync();
  }
  return sum;
}

/// Convenience for tests that only need the bytes of a file.
Uint8List readBytes(String name) => fixtureFile(name).readAsBytesSync();
