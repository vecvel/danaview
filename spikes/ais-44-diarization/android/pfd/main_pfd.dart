// AIS-44 Play Feature Delivery probe (throwaway): the base APK carries no sherpa-onnx
// or ONNX Runtime .so; the on-demand "diarization" module does. Logs AIS44PFD lines.
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

const dir = '/sdcard/Android/data/com.vecvel.ais44size/files';
const ch = MethodChannel('ais44/split');

// ignore: avoid_print
void log(Object o) => print('AIS44PFD $o');

bool canOpen() {
  try {
    DynamicLibrary.open('libsherpa-onnx-c-api.so');
    return true;
  } catch (e) {
    return false;
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('AIS-44 PFD')))));
  Future<void>(() async {
    try {
      log('before installed=${await ch.invokeMethod('installed')} dlopen=${canOpen()}');
      final sw = Stopwatch()..start();
      log('install ${await ch.invokeMethod('install')} in ${sw.elapsedMilliseconds} ms');
      log('dlopen-before-load=${canOpen()}');
      log('load ${await ch.invokeMethod('load')}');
      log('dlopen-after-load=${canOpen()}');
      so.initBindings();
      final sd = so.OfflineSpeakerDiarization(so.OfflineSpeakerDiarizationConfig(
        segmentation: so.OfflineSpeakerSegmentationModelConfig(
          pyannote: so.OfflineSpeakerSegmentationPyannoteModelConfig(
              model: '$dir/seg.int8.onnx'),
          numThreads: 2,
        ),
        embedding: so.SpeakerEmbeddingExtractorConfig(
            model: '$dir/nemo_en_titanet_small.onnx', numThreads: 2),
        clustering: so.FastClusteringConfig(numClusters: -1, threshold: 0.7),
      ));
      final w = so.readWave('$dir/c2_2spk_overlap.wav');
      final segs = sd.process(samples: Float32List.fromList(w.samples));
      log('done segs=${segs.length} '
          'speakers=${segs.map((s) => s.speaker).toSet().length} '
          '${segs.map((s) => 'S${s.speaker}:${s.start.toStringAsFixed(2)}-${s.end.toStringAsFixed(2)}').join(' ')}');
      sd.free();
    } catch (e) {
      log('fail $e');
    }
    exit(0);
  });
}
