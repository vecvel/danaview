// OWNER: ENG-02
//
// The API-01 engine contract kit against MobileEditorEngine's preview over mocked Pigeon channels
// (ARCH §12.2 normative semantics, §21.1): plans and patches cross as PlanJson bytes, failures as
// native FlutterErrors, clock samples through the real EngineEventsApi event channel. Jobs and
// export come from the fake engine here (ENG-03 / ENG-04 run the kit for theirs).

import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor_engine/src/mobile_preview_session.dart';
import 'package:vwish_editor_engine/vwish_editor_engine.dart';
import 'package:vwish_editor_engine_api/testing.dart';
import 'package:vwish_editor_engine_api/vwish_editor_engine_api.dart';

import '../glue/support/mock_engine_host.dart';
import 'support/native_preview_double.dart';

const _config = EditorEngineConfig(cacheRoot: '/c/vwish/editor', supportRoot: '/s/vwish/editor');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('MobilePreviewSession passes the engine contract kit over mocked channels', () async {
    final host = MockEngineHost();
    final native = NativePreviewDouble(host, host.installEvents());
    final mobile = MobileEditorEngine(config: _config);
    final engine = PreviewOverMobileEngine(mobile, FakeEditorEngine());
    try {
      final violations = await checkEngineContract(engine, settle: const Duration(milliseconds: 20));
      expect(violations, isEmpty);
      expect(native.disposed, ['ps1']);
      for (final call in ['setPlan', 'applyPatch', 'setTransient', 'clearTransient', 'play', 'pause', 'seek', 'dispose']) {
        expect(host.count('PreviewHostApi', call), greaterThan(0), reason: call);
      }
    } finally {
      await native.dispose();
      await mobile.channels.dispose();
      host.dispose();
    }
  });

  test('the kit catches a session that drops the seq rules (sensitivity)', () async {
    final host = MockEngineHost();
    final native = NativePreviewDouble(host, host.installEvents());
    // A broken native: play and pause report a stale seq and emit no clock.
    host
      ..on('PreviewHostApi', 'play', (_) => 0)
      ..on('PreviewHostApi', 'pause', (_) => 0);
    final mobile = MobileEditorEngine(config: _config);
    final engine = PreviewOverMobileEngine(mobile, FakeEditorEngine());
    try {
      final violations = await checkEngineContract(engine, settle: const Duration(milliseconds: 20));
      expect(violations, isNotEmpty);
    } finally {
      await native.dispose();
      await mobile.channels.dispose();
      host.dispose();
    }
  });

  test('openPreview returns a MobilePreviewSession bound to the native texture', () async {
    final host = MockEngineHost();
    final native = NativePreviewDouble(host, host.installEvents());
    final mobile = MobileEditorEngine(config: _config);
    try {
      final session = await mobile.openPreview(const PreviewConfig(canvasWidth: 64, canvasHeight: 36, fps: 30));
      expect(session, isA<MobilePreviewSession>());
      expect(session.textureId, native.sessions['ps1']!.textureId);
      expect((session as MobilePreviewSession).sessionId, 'ps1');
      await session.dispose();
    } finally {
      await native.dispose();
      await mobile.channels.dispose();
      host.dispose();
    }
  });
}
