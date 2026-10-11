// OWNER: ENG-09
//
// Engine smoke test through the example host on a simulator, emulator or device:
//
//   cd packages/danaview_editor_engine/example
//   flutter test integration_test/engine_smoke_test.dart -d <device>
//
// It proves the plugin registers, the Pigeon channels answer (or answer channel-error while the
// native plugin classes are ENG-01's placeholders) and every engine root call maps to the API
// contract instead of crashing. It holds for every stage of the native side: placeholder plugin
// (`engine_not_available`), ENG-07/ENG-08 glue (native placeholder capabilities, supported false)
// and the real engines (supported true on capable devices).

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_editor_engine_example/engine_host.dart';
import 'package:danaview_editor_engine_example/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory base;

  setUp(() {
    base = Directory.systemTemp.createTempSync('danaview_engine_smoke');
  });

  tearDown(() {
    if (base.existsSync()) base.deleteSync(recursive: true);
  });

  testWidgets('capabilities() answers with a supported flag or an unsupported reason', (tester) async {
    final engine = createExampleEngine(base: base);
    final caps = await engine.capabilities().timeout(const Duration(seconds: 20));
    if (caps.supported) {
      expect(caps.planVersions, contains(1));
      expect(caps.unsupportedReason, isNull);
    } else {
      expect(caps.unsupportedReason, isNotNull);
      expect(caps.unsupportedReason, isNotEmpty);
    }
    // Cached after the first load (ARCH §12.1).
    expect(identical(await engine.capabilities(), caps), isTrue);
    // ARCH §12.1: the recorder is exposed only when the capabilities report it.
    expect(engine.voiceRecorder == null, !caps.voiceRecording);
  });

  testWidgets('compatibility() never throws for a missing file', (tester) async {
    final engine = createExampleEngine(base: base);
    final caps = await engine.capabilities();
    final missing = '${base.path}/missing.mp4';
    try {
      final result = await engine.compatibility(missing).timeout(const Duration(seconds: 20));
      if (!caps.supported) {
        expect(result, isA<NotEditable>());
      }
    } on EngineFailure catch (f) {
      // A real engine may refuse a missing file with a typed failure; never a raw PlatformException.
      expect(f.code, isNot(EngineErrorCode.notSupportedOnDevice));
    }
  });

  testWidgets('trimCaches() completes', (tester) async {
    final engine = createExampleEngine(base: base);
    await engine.trimCaches(CacheTrimLevel.memoryPressure).timeout(const Duration(seconds: 20));
  });

  testWidgets('the example screen shows the engine summary', (tester) async {
    await tester.pumpWidget(EngineExampleApp(report: probeEngine(createExampleEngine(base: base))));
    final summary = find.byKey(const ValueKey('engine-summary'));
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      final text = tester.widget<Text>(summary).data ?? '';
      if (!text.startsWith('loading')) break;
    }
    final text = tester.widget<Text>(summary).data ?? '';
    expect(text, startsWith('engine '));
    expect(text, isNot(contains(base.path)));
    expect(tester.takeException(), isNull);
  });
}
