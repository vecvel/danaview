// AIS-44 spike host: speaker-embedding check, independent of segmentation.
// For each ground-truth segment (overlap-free part only) of the given clips,
// computes an embedding and prints a JSON list {clip, speaker, start, end, emb}.
// tool/verify.py turns that into same/different-speaker cosine statistics.
//
// dart run bin/embed.dart --emb <embedding.onnx> --out out.json data/c1.wav ...
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
  so.initBindings(Platform.environment['SHERPA_LIB_DIR']);
  final ex = so.SpeakerEmbeddingExtractor(
      config: so.SpeakerEmbeddingExtractorConfig(
          model: opts['emb']!, numThreads: 2, debug: false));
  final out = <Map<String, Object?>>[];
  final sw = Stopwatch()..start();
  var audioSecs = 0.0;
  for (final path in wavs) {
    final w = so.readWave(path);
    final gt = jsonDecode(File(path.replaceAll('.wav', '.json')).readAsStringSync())
        as Map<String, dynamic>;
    final segs = (gt['segments'] as List).cast<Map<String, dynamic>>();
    for (final s in segs) {
      // Clip the segment to the part no other segment covers.
      var a = (s['start'] as num).toDouble();
      var b = (s['end'] as num).toDouble();
      for (final o in segs) {
        if (identical(o, s)) continue;
        final oa = (o['start'] as num).toDouble(), ob = (o['end'] as num).toDouble();
        if (oa <= a && ob > a) a = ob;
        if (oa < b && ob >= b) b = oa;
      }
      if (b - a < 1.0) continue;
      final samples = Float32List.fromList(
          w.samples.sublist((a * w.sampleRate).round(), (b * w.sampleRate).round()));
      final st = ex.createStream();
      st.acceptWaveform(samples: samples, sampleRate: w.sampleRate);
      st.inputFinished();
      final e = ex.compute(st);
      st.free();
      audioSecs += b - a;
      out.add({
        'clip': path.split('/').last.replaceAll('.wav', ''),
        'speaker': s['speaker'],
        'start': a,
        'end': b,
        'emb': e.toList(),
      });
    }
  }
  stderr.writeln('${out.length} embeddings, dim ${ex.dim}, '
      '${(sw.elapsedMilliseconds / 1000 / audioSecs).toStringAsFixed(4)} s per audio s');
  ex.free();
  File(opts['out']!).writeAsStringSync(jsonEncode(out));
}
