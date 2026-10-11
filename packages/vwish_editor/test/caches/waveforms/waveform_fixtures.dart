// OWNER: UX-21
//
// Test rig for WaveformCache: scripted peaks jobs, synthetic peaks and column measuring.

import 'dart:typed_data';

import 'package:flutter/painting.dart' show Color;
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_engine_api/testing.dart';
import 'package:vwish_editor_engine_api/vwish_editor_engine_api.dart';

/// Records every peaks request; each job stays pending until the test completes it.
class ScriptedWaveformSource implements WaveformSource {
  final List<ResolvedMedia> media = [];
  final List<int> streams = [];
  final List<FakeMediaJob<WaveformPeaks>> jobs = [];

  Iterable<FakeMediaJob<WaveformPeaks>> get live => jobs.where((j) => !j.cancelled);

  @override
  MediaJob<WaveformPeaks> peaks(EngineMedia media, {int audioStream = 0}) {
    this.media.add(media);
    streams.add(audioStream);
    final job = FakeMediaJob<WaveformPeaks>('peaks-${jobs.length}');
    jobs.add(job);
    return job;
  }
}

/// Peaks of [seconds] of audio at 200 pairs/s whose amplitude at source second `t` is
/// `amp(t)` (0..127), symmetric (min = -amp).
WaveformPeaks peaksOf(double seconds, double Function(double sec) amp, {int pairsPerSecond = 200}) {
  final pairs = (seconds * pairsPerSecond).round();
  final data = Int8List(pairs * 2);
  for (var i = 0; i < pairs; i++) {
    final a = amp(i / pairsPerSecond).round().clamp(0, 127);
    data[2 * i] = -a;
    data[2 * i + 1] = a;
  }
  return WaveformPeaks(minMax: data, duration: (seconds * microsPerSecond).round(), pairsPerSecond: pairsPerSecond);
}

/// A resolver for ids: `fp-<id>`; [offline] ids resolve to null.
WaveformResolverFixture waveResolver({Set<String> offline = const {}}) => WaveformResolverFixture(offline);

class WaveformResolverFixture {
  WaveformResolverFixture(this.offline);

  final Set<String> offline;
  final List<String> calls = [];

  ResolvedMedia? call(MediaId id) {
    calls.add(id.value);
    if (offline.contains(id.value)) return null;
    return ResolvedMedia(uri: 'file:///media/${id.value}.m4a', fingerprint: 'fp-${id.value}');
  }
}

/// The vertical extent (top row, bottom row inclusive) of the non-background pixels in column [x]
/// of an RGBA image [width] px wide and [height] px tall, or null when the column is empty.
(int, int)? columnExtent(ByteData data, int width, int height, int x, {Color background = const Color(0xFF000000)}) {
  int? top, bottom;
  for (var y = 0; y < height; y++) {
    final o = (y * width + x) * 4;
    final c = Color.fromARGB(data.getUint8(o + 3), data.getUint8(o), data.getUint8(o + 1), data.getUint8(o + 2));
    if (c != background) {
      top ??= y;
      bottom = y;
    }
  }
  return top == null ? null : (top, bottom!);
}

/// The height in px of the waveform bar in column [x].
int barHeight(ByteData data, int width, int height, int x) {
  final e = columnExtent(data, width, height, x);
  return e == null ? 0 : e.$2 - e.$1 + 1;
}
