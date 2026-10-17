// OWNER: UX-01
//
// Root providers of ARCH §17.3: unconfigured roots fail with EditorNotConfiguredError naming the
// provider; overrides (EditorBootstrap in the app, EditorTestHarness in tests) supply them; the
// capabilities provider reads the engine; the per-project families are keyed by ProjectId.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/danaview_editor.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

import '../support/support.dart';

void main() {
  test('unconfigured root providers name themselves', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final roots = <String, ProviderListenable<Object?>>{
      'editorEngineProvider': editorEngineProvider,
      'projectRepositoryProvider': projectRepositoryProvider,
      'mediaPoolServiceProvider': mediaPoolServiceProvider,
      'transcriptionServiceProvider': transcriptionServiceProvider,
      'editorPrefsProvider': editorPrefsProvider,
    };
    roots.forEach((name, provider) {
      expect(() => c.read(provider), throwsA(isA<EditorNotConfiguredError>().having((e) => e.provider, 'provider', name)), reason: name);
    });
  });

  test('harness overrides supply every root; capabilities come from the engine', () async {
    final h = EditorTestHarness();
    final c = h.container();
    expect(c.read(editorEngineProvider), same(h.engine));
    expect(c.read(projectRepositoryProvider), same(h.repository));
    expect(c.read(mediaPoolServiceProvider), same(h.mediaPool));
    expect(c.read(transcriptionServiceProvider), same(h.transcription));
    expect(c.read(editorPrefsProvider), same(h.prefs));
    final caps = await c.read(editorCapabilitiesProvider.future);
    expect(caps, same(h.engine.caps));
    expect(h.engine.calls.where((c) => c == 'capabilities'), hasLength(1));
    await c.read(editorCapabilitiesProvider.future);
    expect(h.engine.calls.where((c) => c == 'capabilities'), hasLength(1), reason: 'cached by the provider');
  });

  test('capabilities failures surface as AsyncError', () async {
    final h = EditorTestHarness();
    h.engine.failNext['capabilities'] = EngineFailure.of(EngineErrorCode.internal);
    final c = h.container();
    await expectLater(c.read(editorCapabilitiesProvider.future), throwsA(isA<EngineFailure>()));
  });

  test('per-project families are keyed by ProjectId', () {
    const a = ProjectId('pr_aaaaaaaaaaaa'), b = ProjectId('pr_bbbbbbbbbbbb');
    expect(editorControllerProvider(a), editorControllerProvider(a));
    expect(editorControllerProvider(a), isNot(editorControllerProvider(b)));
    for (final family in <Object>[
      editorSessionProvider(a),
      editorControllerProvider(a),
      playheadProvider(a),
      transportProvider(a),
      viewportProvider(a),
      interactionProvider(a),
      timelineSnapshotProvider(a),
      exportControllerProvider(a),
      autoCaptionsControllerProvider(a),
      relinkControllerProvider(a),
    ]) {
      expect((family as ProviderBase<Object?>).argument, a);
    }
  });
}
