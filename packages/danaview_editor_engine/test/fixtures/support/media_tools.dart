// OWNER: ENG-05
//
// Test-side access to the dev-only ffmpeg/ffprobe tools (never shipped, never downloaded) and to
// the committed fixtures. Tests that need them skip with a message when the tools are missing.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Absolute path of `test_fixtures/media` (tests run with the package root as cwd).
Directory get fixtureMediaDir => Directory('test_fixtures/media');

/// A fixture file by name.
File fixtureFile(String name) => File('${fixtureMediaDir.path}/$name');

/// Parsed `manifest.json` entries by file name.
Map<String, Map<String, dynamic>> loadManifest() {
  final raw = jsonDecode(File('${fixtureMediaDir.path}/manifest.json').readAsStringSync())
      as Map<String, dynamic>;
  return (raw['files'] as Map<String, dynamic>)
      .map((k, v) => MapEntry(k, v as Map<String, dynamic>));
}

String? _find(String name) {
  const dirs = <String>['/opt/homebrew/bin', '/usr/local/bin', '/usr/bin'];
  final env = Platform.environment[name == 'ffmpeg' ? 'FFMPEG' : 'FFPROBE'];
  if (env != null && File(env).existsSync()) return env;
  for (final d in dirs) {
    if (File('$d/$name').existsSync()) return '$d/$name';
  }
  final path = Platform.environment['PATH'] ?? '';
  for (final d in path.split(':')) {
    if (d.isNotEmpty && File('$d/$name').existsSync()) return '$d/$name';
  }
  return null;
}

/// Path of ffmpeg or null.
final String? ffmpegPath = _find('ffmpeg');

/// Path of ffprobe or null.
final String? ffprobePath = _find('ffprobe');

/// Skip reason for tests that need ffmpeg and ffprobe, or null when available.
String? get skipWithoutFfmpeg => (ffmpegPath == null || ffprobePath == null)
    ? 'ffmpeg/ffprobe (dev-only tools) not found; install them or set FFMPEG/FFPROBE'
    : null;

/// `ffprobe -show_streams -show_format` as JSON.
Future<Map<String, dynamic>> probe(String path) async {
  final r = await Process.run(ffprobePath!, <String>[
    '-v', 'error', '-show_streams', '-show_format', '-of', 'json', path, //
  ]);
  if (r.exitCode != 0) throw StateError('ffprobe failed for $path: ${r.stderr}');
  return jsonDecode(r.stdout as String) as Map<String, dynamic>;
}

/// Decoded video frame, tightly packed RGBA.
class RawFrame {
  /// Creates a frame.
  const RawFrame(this.index, this.pixels);

  /// Zero-based decode order.
  final int index;

  /// RGBA bytes.
  final Uint8List pixels;
}

/// Streams every frame of [path] as RGBA of `width` x `height` through ffmpeg (autorotate on,
/// all frames kept, no dropping or duplication) and calls [onFrame] for each, without ever
/// holding more than one frame in memory.
Future<int> forEachRgbaFrame(
  String path, {
  required int width,
  required int height,
  required void Function(int index, Uint8List rgba) onFrame,
  double? startSeconds,
  double? seconds,
}) async {
  final args = <String>[
    '-v', 'error', //
    if (startSeconds != null) ...<String>['-ss', '$startSeconds'],
    '-i', path,
    if (seconds != null) ...<String>['-t', '$seconds'],
    '-fps_mode', 'passthrough',
    '-an',
    '-f', 'rawvideo',
    '-pix_fmt', 'rgba',
    '-',
  ];
  final proc = await Process.start(ffmpegPath!, args);
  final frameBytes = width * height * 4;
  final buf = Uint8List(frameBytes);
  var filled = 0;
  var count = 0;
  final err = proc.stderr.drain<void>();
  await for (final chunk in proc.stdout) {
    var off = 0;
    while (off < chunk.length) {
      final n =
          (frameBytes - filled) < (chunk.length - off) ? frameBytes - filled : chunk.length - off;
      buf.setRange(filled, filled + n, chunk, off);
      filled += n;
      off += n;
      if (filled == frameBytes) {
        onFrame(count++, buf);
        filled = 0;
      }
    }
  }
  await err;
  final code = await proc.exitCode;
  if (code != 0) throw StateError('ffmpeg exited with $code for $path');
  if (filled != 0) throw StateError('ffmpeg produced a partial frame for $path');
  return count;
}

/// Decodes the first audio stream to mono float32 PCM. With [channelName] (an ffmpeg channel
/// name such as `FC`, `FL`, `FR`) only that channel is decoded; with [channelIndex] the channel
/// at that position of the decoded layout.
Future<Float32List> decodeAudioMono(String path,
    {int sampleRate = 48000, String? channelName, int? channelIndex}) async {
  final String filter;
  if (channelName != null) {
    filter = 'pan=mono|c0=$channelName';
  } else if (channelIndex != null) {
    filter = 'pan=mono|c0=c$channelIndex';
  } else {
    filter = 'aformat=channel_layouts=mono';
  }
  final r = await Process.run(
    ffmpegPath!,
    <String>[
      '-v',
      'error',
      '-i',
      path,
      '-vn',
      '-af',
      filter,
      '-ar',
      '$sampleRate',
      '-f',
      'f32le',
      '-'
    ],
    stdoutEncoding: null,
  );
  if (r.exitCode != 0) throw StateError('ffmpeg audio decode failed for $path: ${r.stderr}');
  final u8 = Uint8List.fromList(r.stdout as List<int>);
  return u8.buffer.asFloat32List(0, u8.length ~/ 4);
}

/// Video packet presentation times (seconds), sorted.
Future<List<double>> videoPts(String path) async {
  final r = await Process.run(ffprobePath!, <String>[
    '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'packet=pts_time', '-of', 'csv=p=0',
    path, //
  ]);
  if (r.exitCode != 0) throw StateError('ffprobe failed: ${r.stderr}');
  final out = (r.stdout as String)
      .split('\n')
      .where((l) => l.trim().isNotEmpty)
      .map((l) => double.parse(l.trim().split(',').first))
      .toList()
    ..sort();
  return out;
}

/// Frequency estimate (Hz) of a pure tone from positive-going zero crossings with linear
/// interpolation, ignoring [trimSeconds] at both ends (codec priming and tail).
double estimateToneHz(Float32List pcm, int sampleRate, {double trimSeconds = 0.25}) {
  final trim = (trimSeconds * sampleRate).round();
  final start = trim;
  final end = pcm.length - trim;
  double? first;
  double? last;
  var crossings = 0;
  for (var i = start + 1; i < end; i++) {
    final a = pcm[i - 1];
    final b = pcm[i];
    if (a < 0 && b >= 0) {
      final t = (i - 1) + (-a) / (b - a);
      first ??= t;
      last = t;
      crossings++;
    }
  }
  if (crossings < 2 || first == null || last == null) return 0;
  return (crossings - 1) * sampleRate / (last - first);
}

/// RMS of [pcm] in dBFS.
double rmsDbfs(Float32List pcm, {int from = 0, int? to}) {
  final end = to ?? pcm.length;
  var sum = 0.0;
  for (var i = from; i < end; i++) {
    sum += pcm[i] * pcm[i];
  }
  final meanSquare = sum / (end - from);
  return meanSquare <= 0 ? -200 : 10 * _log10(meanSquare);
}

/// Peak absolute sample of [pcm] in dBFS.
double peakDbfs(Float32List pcm, {int from = 0, int? to}) {
  final end = to ?? pcm.length;
  var peak = 0.0;
  for (var i = from; i < end; i++) {
    final v = pcm[i].abs();
    if (v > peak) peak = v.toDouble();
  }
  return peak <= 0 ? -200 : 20 * _log10(peak);
}

double _log10(double v) => math.log(v) / math.ln10;
