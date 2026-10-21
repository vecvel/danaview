// AIS-44 spike host: speaker-embedding check, independent of segmentation.
// For each ground-truth segment (overlap-free part only) of the given clips,
// computes an embedding and prints a JSON list {clip, speaker, start, end, emb}.
// tool/verify.py turns that into same/different-speaker cosine statistics.
//
// dart run bin/embed.dart --emb <embedding.onnx> --out out.json data/c1.wav ...
//
// With --regions <diarize.json> [--win 1.5 --hop 0.75] it instead embeds
// fixed-length chunks over the speech that diarize.dart found (speaker null),
// for tool/chunks.py (chunk-level clustering experiment).
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
  final regions = opts['regions'] == null
      ? null
      : {
          for (final r in (jsonDecode(File(opts['regions']!).readAsStringSync())
                  as Map<String, dynamic>)['results'] as List)
            (r as Map<String, dynamic>)['clip'] as String:
                (r['segments'] as List).cast<Map<String, dynamic>>()
        };
  final win = double.parse(opts['win'] ?? '1.5');
  final hop = double.parse(opts['hop'] ?? '0.75');
  List<double> embed(so.WaveData w, double a, double b) {
    final st = ex.createStream();
    st.acceptWaveform(
        samples: Float32List.fromList(w.samples
            .sublist((a * w.sampleRate).round(), (b * w.sampleRate).round())),
        sampleRate: w.sampleRate);
    st.inputFinished();
    final e = ex.compute(st);
    st.free();
    audioSecs += b - a;
    return e.toList();
  }

  for (final path in wavs) {
    final w = so.readWave(path);
    final clip = path.split('/').last.replaceAll('.wav', '');
    if (regions != null) {
      // Union of detected speech, then fixed windows inside each region.
      final iv = [
        for (final s in regions[clip]!)
          [(s['start'] as num).toDouble(), (s['end'] as num).toDouble()]
      ]..sort((x, y) => x[0].compareTo(y[0]));
      final merged = <List<double>>[];
      for (final v in iv) {
        if (merged.isNotEmpty && v[0] <= merged.last[1]) {
          if (v[1] > merged.last[1]) merged.last[1] = v[1];
        } else {
          merged.add([v[0], v[1]]);
        }
      }
      for (final m in merged) {
        for (var a = m[0]; a < m[1] - 0.3; a += hop) {
          final b = (a + win) < m[1] ? a + win : m[1];
          if (b - a < 0.5) break;
          out.add({'clip': clip, 'speaker': null, 'start': a, 'end': b, 'emb': embed(w, a, b)});
        }
      }
      continue;
    }
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
