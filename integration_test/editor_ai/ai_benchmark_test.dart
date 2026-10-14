// OWNER: QA-06
//
// Auto captions device benchmark (ai.md §14, §16.4 device matrix; BUILD_PLAN QA-06). For every tier
// whose model is staged on the device it measures, through the real danaview_whisper runtime and
// the SpeechTuning constants the app ships:
//   * cold model load with the GPU requested (on a fresh install this includes the first Metal
//     kernel-library compile, V-A4), then a warm reload, and a CPU-only load;
//   * a transcription of the staged 60 s English clip: wall time, whisper compute time, real-time
//     factor, chunks, GPU used or not, and the lowest available memory seen while it ran (footprint
//     proxy next to `phys_footprint` / `dumpsys meminfo` from the device lab).
// Results are printed as `DV_AI_BENCH {json}` lines and reported through the integration binding
// (`flutter drive` writes them to build/integration_response_data.json); docs/v1.1/editor/ai-eval.md
// §5 collects them per device.
//
// Staging (nothing is downloaded by the test):
//   <dir>/ggml-tiny-q5_1.bin, ggml-base-q5_1.bin, ggml-small-q5_1.bin, ggml-silero-v6.2.0.bin
//   <dir>/bench-60s-en.wav (16 kHz mono s16; any licensed 60 s English talk clip)
// where <dir> is --dart-define=DV_BENCH_DIR=..., or by default the app's speech model directory
// (<Application Support>/danaview/speech/models on iOS, <files>/danaview/speech/models on Android).
//   iOS:     xcrun devicectl device copy to --device <id> --domain-type appDataContainer
//            --domain-identifier com.vecvel.danaview --source <file>
//            --destination "Library/Application Support/danaview/speech/models/<file>"
//   Android: adb push <file> /data/local/tmp/ && adb shell run-as com.vecvel.danaview cp ...
// Run:  flutter test integration_test/editor_ai/ai_benchmark_test.dart -d <device> [--dart-define=DV_BENCH_TIERS=balanced]
// On a simulator or emulator the test runs the CPU path (useful for plumbing only; not a device figure).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:danaview_transcription/danaview_transcription.dart';
import 'package:danaview_whisper/danaview_whisper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const String _dirDefine = String.fromEnvironment('DV_BENCH_DIR');
const String _tiersDefine = String.fromEnvironment('DV_BENCH_TIERS', defaultValue: 'fast,balanced,accurate');
const String _clipName = 'bench-60s-en.wav';

String _benchDir() {
  if (_dirDefine.isNotEmpty) return _dirDefine;
  final container = Directory.systemTemp.parent.path;
  final support = Platform.isIOS ? '$container/Library/Application Support' : '$container/files';
  return '$support/danaview/speech/models';
}

Future<T> _timed<T>(Future<T> Function() f, void Function(int ms) record) async {
  final sw = Stopwatch()..start();
  final v = await f();
  record(sw.elapsedMilliseconds);
  return v;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final dir = _benchDir();
  final clip = File('$dir/$_clipName');
  final tiers = [
    for (final name in _tiersDefine.split(','))
      ...SpeechModelCatalog.models.where((m) => m.tier.name == name.trim()),
  ];
  final results = <Map<String, Object?>>[];

  tearDownAll(() {
    binding.reportData = {'ai_benchmark': results};
  });

  testWidgets('device profile and runtime support', (tester) async {
    final runtime = await WhisperRuntime.open();
    final profile = await runtime.device.deviceProfile();
    final row = <String, Object?>{
      'kind': 'device',
      'os': profile.os,
      'osVersion': profile.osVersion,
      'model': profile.model,
      'ramBytes': profile.physicalRamBytes,
      'perfCores': profile.perfCores,
      'efficiencyCores': profile.efficiencyCores,
      'gpuFamily': profile.gpuFamily,
      'simulator': profile.isSimulator,
      'support': runtime.support.toString(),
      'engine': runtime.engineVersion,
      'tiersOffered': [
        for (final t in SpeechModelCatalog.availableTiers(
            physicalRamBytes: profile.physicalRamBytes, is64Bit: profile.is64Bit, isLowRamDevice: profile.isLowRam))
          t.name,
      ],
      'metalExpected': profile.os == 'ios' &&
          !profile.isSimulator &&
          profile.gpuFamily >= SpeechTuning.metalMinAppleGpuFamily,
    };
    results.add(row);
    // ignore: avoid_print
    print('DV_AI_BENCH ${jsonEncode(row)}');
    expect(row['os'], anyOf('ios', 'android'));
  });

  for (final spec in tiers) {
    final model = File('$dir/${spec.fileName}');
    final staged = model.existsSync() && clip.existsSync();
    testWidgets(
      '${spec.tier.name}: load (cold GPU, warm, CPU) and 60 s English transcription',
      (tester) async {
        await tester.runAsync(() async {
          final runtime = await WhisperRuntime.open();
          expect(runtime.support, isA<WhisperSupported>(), reason: 'runtime unsupported: ${runtime.support}');
          final vad = File('$dir/${SpeechModelCatalog.vad.fileName}');
          final row = <String, Object?>{'kind': 'tier', 'tier': spec.tier.name, 'model': spec.fileName};

          // Cold load with the GPU requested (first Metal init on a fresh install), then warm.
          var m = await _timed(() => runtime.loadModel(model.path), (ms) => row['coldLoadMs'] = ms);
          row['gpu'] = m.info.usesGpu;
          row['gpuFallback'] = m.info.gpuFallback;
          await m.release();
          await runtime.releaseIdleModels();
          m = await _timed(() => runtime.loadModel(model.path), (ms) => row['warmLoadMs'] = ms);
          await m.release();
          await runtime.releaseIdleModels();
          final cpu = await _timed(
              () => runtime.loadModel(model.path, options: const WhisperModelOptions(preferGpu: false)),
              (ms) => row['cpuLoadMs'] = ms);
          await cpu.release();
          await runtime.releaseIdleModels();

          // Transcription with the shipped constants.
          final loaded = await runtime.loadModel(model.path);
          final profile = await runtime.device.deviceProfile();
          final threads = profile.perfCores.clamp(2, 4);
          int? minAvailable = await runtime.device.availableMemory();
          final sampler = Timer.periodic(const Duration(milliseconds: 500), (_) async {
            final a = await runtime.device.availableMemory();
            if (a != null && (minAvailable == null || a < minAvailable!)) minAvailable = a;
          });
          final startAvailable = minAvailable;
          final sw = Stopwatch()..start();
          final job = loaded.transcribe(WhisperTranscribeRequest(
            wavPath: clip.path,
            language: 'en',
            threads: threads,
            vad: vad.existsSync() ? WhisperVadOptions(modelPath: vad.path) : null,
            decode: const WhisperDecodeOptions(
              noSpeechThreshold: SpeechTuning.noSpeechThreshold,
              entropyThreshold: SpeechTuning.entropyThreshold,
              logprobThreshold: SpeechTuning.logprobThreshold,
            ),
            chunkTarget: const Duration(milliseconds: SpeechTuning.chunkTargetMs),
            chunkSearch: const Duration(milliseconds: SpeechTuning.chunkSearchMs),
            carryPromptWords: SpeechTuning.carryPromptWords,
          ));
          final result = await job.result;
          sw.stop();
          sampler.cancel();
          await loaded.release();
          await runtime.releaseIdleModels();

          final audioMs = result.processed.inMilliseconds;
          row
            ..['threads'] = threads
            ..['vad'] = vad.existsSync()
            ..['audioMs'] = audioMs
            ..['wallMs'] = sw.elapsedMilliseconds
            ..['computeMs'] = result.computeTime.inMilliseconds
            ..['realTimeFactor'] = audioMs == 0 ? null : result.computeTime.inMilliseconds / audioMs
            ..['segments'] = result.segments.length
            ..['words'] = result.segments.fold<int>(0, (a, s) => a + s.words.length)
            ..['availableMemoryDropBytes'] =
                startAvailable == null || minAvailable == null ? null : startAvailable - minAvailable!
            ..['peakBudgetBytes'] = spec.peakMemoryBudgetBytes;
          results.add(row);
          // ignore: avoid_print
          print('DV_AI_BENCH ${jsonEncode(row)}');
          expect(result.segments, isNotEmpty, reason: 'no speech recognised in $_clipName');
        });
      },
      skip: !staged,
      timeout: const Timeout(Duration(minutes: 20)),
    );
  }
}
