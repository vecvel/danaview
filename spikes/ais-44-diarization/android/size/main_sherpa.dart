// AIS-44 Android half: size + FFI smoke app (throwaway). The "sherpa" variant of
// build/size_app runs one diarization through the stock sherpa_onnx Dart package
// (DynamicLibrary.open of the plugin's jniLibs) and logs the result to logcat.
// Inputs are pushed by android/size/smoke.sh to the app's external files dir.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

const dir = '/sdcard/Android/data/com.vecvel.ais44size/files';

void main() {
  runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('AIS-44')))));
  Future<void>(() {
    try {
      for (final f in ['seg.int8.onnx', 'nemo_en_titanet_small.onnx', 'c2_2spk_overlap.wav']) {
        final file = File('$dir/$f');
        // ignore: avoid_print
        print('AIS44FILE $f exists=${file.existsSync()} '
            'readable=${() { try { return file.openSync().lengthSync(); } catch (e) { return e; } }()}');
      }
      so.initBindings();
      final sd = so.OfflineSpeakerDiarization(so.OfflineSpeakerDiarizationConfig(
        segmentation: so.OfflineSpeakerSegmentationModelConfig(
          pyannote: so.OfflineSpeakerSegmentationPyannoteModelConfig(model: '$dir/seg.int8.onnx'),
          numThreads: 2,
        ),
        embedding: so.SpeakerEmbeddingExtractorConfig(
            model: '$dir/nemo_en_titanet_small.onnx', numThreads: 2),
        clustering: so.FastClusteringConfig(numClusters: -1, threshold: 0.7),
        minDurationOn: 0.2,
        minDurationOff: 0.5,
      ));
      final w = so.readWave('$dir/c2_2spk_overlap.wav');
      final sw = Stopwatch()..start();
      final segs = sd.process(samples: Float32List.fromList(w.samples));
      final secs = sw.elapsedMicroseconds / 1e6;
      final dur = w.samples.length / w.sampleRate;
      final hwm = File('/proc/self/status')
          .readAsLinesSync()
          .firstWhere((l) => l.startsWith('VmHWM'));
      // ignore: avoid_print
      print('AIS44SMOKE ok segs=${segs.length} speakers=${segs.map((s) => s.speaker).toSet().length} '
          'rtf=${(secs / dur).toStringAsFixed(3)} $hwm '
          '${segs.map((s) => 'S${s.speaker}:${s.start.toStringAsFixed(2)}-${s.end.toStringAsFixed(2)}').join(' ')}');
      sd.free();
    } catch (e, st) {
      // ignore: avoid_print
      print('AIS44SMOKE fail $e $st');
    }
  });
}
