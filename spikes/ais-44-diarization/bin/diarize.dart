// AIS-44 spike host: run sherpa-onnx offline speaker diarization on WAVs.
// Not part of any product build. No network.
//
// dart run bin/diarize.dart --seg <model.onnx> --emb <embedding.onnx>
//     [--clusters N | --threshold T] [--threads 2] [--out out.json] a.wav b.wav ...
//
// Prints one JSON object per clip: segments, wall time, RTF.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

void main(List<String> argv) {
  final opts = <String, String>{};
  final wavs = <String>[];
  for (var i = 0; i < argv.length; i++) {
    if (argv[i].startsWith('--')) {
      opts[argv[i].substring(2)] = argv[++i];
    } else {
      wavs.add(argv[i]);
    }
  }
  final seg = opts['seg']!;
  final emb = opts['emb']!;
  final threads = int.parse(opts['threads'] ?? '2');
  final clusters = int.parse(opts['clusters'] ?? '-1');
  final threshold = double.parse(opts['threshold'] ?? '0.5');

  // AOT exe: pass the sherpa_onnx_macos 'macos' dir; `dart run` resolves it itself.
  so.initBindings(Platform.environment['SHERPA_LIB_DIR']);
  final t0 = DateTime.now();
  final sd = so.OfflineSpeakerDiarization(so.OfflineSpeakerDiarizationConfig(
    segmentation: so.OfflineSpeakerSegmentationModelConfig(
      pyannote: so.OfflineSpeakerSegmentationPyannoteModelConfig(model: seg),
      numThreads: threads,
      debug: false,
    ),
    embedding: so.SpeakerEmbeddingExtractorConfig(
        model: emb, numThreads: threads, debug: false),
    clustering:
        so.FastClusteringConfig(numClusters: clusters, threshold: threshold),
    minDurationOn: double.parse(opts['minOn'] ?? '0.2'),
    minDurationOff: double.parse(opts['minOff'] ?? '0.5'),
  ));
  final loadMs = DateTime.now().difference(t0).inMilliseconds;

  final results = <Map<String, Object?>>[];
  for (final path in wavs) {
    final w = so.readWave(path);
    if (w.sampleRate != sd.sampleRate) {
      throw StateError('$path: ${w.sampleRate} Hz, want ${sd.sampleRate}');
    }
    final dur = w.samples.length / w.sampleRate;
    final sw = Stopwatch()..start();
    final segs = sd.process(samples: Float32List.fromList(w.samples));
    sw.stop();
    final secs = sw.elapsedMicroseconds / 1e6;
    results.add({
      'clip': path.split('/').last.replaceAll('.wav', ''),
      'duration': dur,
      'wall': secs,
      'rtf': secs / dur,
      'segments': [
        for (final s in segs)
          {'speaker': 'S${s.speaker}', 'start': s.start, 'end': s.end}
      ],
    });
    stderr.writeln('${results.last['clip']}: ${segs.length} segs, '
        '${secs.toStringAsFixed(2)} s, RTF ${(secs / dur).toStringAsFixed(3)}');
  }
  sd.free();
  final out = jsonEncode({
    'seg': seg,
    'emb': emb,
    'threads': threads,
    'clusters': clusters,
    'threshold': threshold,
    'loadMs': loadMs,
    'results': results,
  });
  if (opts['out'] != null) {
    File(opts['out']!).writeAsStringSync(out);
  } else {
    stdout.writeln(out);
  }
}
