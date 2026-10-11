// OWNER: UX-01
//
// Availability matrix (ARCH §3.3, D-17, D-31): platform × DANAVIEW_EDITOR × web; desktop is always
// hidden (no teaser state); the device gate comes from engine capabilities and never throws.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/danaview_editor.dart';
import 'package:danaview_editor_engine_api/testing.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

import '../../support/support.dart';

void main() {
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    EditorFlags.debugEditorOverride = null;
    EditorFlags.debugAutoCaptionsOverride = null;
  });

  group('EditorAvailability.resolve matrix', () {
    const mobile = {TargetPlatform.iOS, TargetPlatform.android};
    for (final platform in TargetPlatform.values) {
      for (final flag in [true, false]) {
        for (final web in [false, true]) {
          final EditorSupport expected;
          if (web || !mobile.contains(platform)) {
            expected = const EditorHidden(EditorHiddenReason.platform);
          } else if (!flag) {
            expected = const EditorHidden(EditorHiddenReason.flagOff);
          } else {
            expected = const EditorSupported();
          }
          test('${platform.name} DANAVIEW_EDITOR=$flag web=$web -> $expected', () {
            final got = EditorAvailability.resolve(platform: platform, editorFlag: flag, isWeb: web);
            expect(got, expected);
            expect(got.showsEntryPoints, expected is EditorSupported);
          });
        }
      }
    }

    test('desktop is always hidden, whatever the flag (D-17, no teaser)', () {
      for (final platform in [TargetPlatform.macOS, TargetPlatform.windows, TargetPlatform.linux, TargetPlatform.fuchsia]) {
        for (final flag in [true, false]) {
          final got = EditorAvailability.resolve(platform: platform, editorFlag: flag);
          expect(got, isA<EditorHidden>());
          expect(got.showsEntryPoints, isFalse);
        }
      }
    });

    test('EditorSupport has exactly three states (supported, hidden, unsupported)', () {
      String describe(EditorSupport s) => switch (s) {
            EditorSupported() => 'supported',
            EditorHidden() => 'hidden',
            EditorUnsupported() => 'unsupported',
          };
      expect(describe(const EditorSupported()), 'supported');
      expect(describe(const EditorHidden(EditorHiddenReason.platform)), 'hidden');
      expect(describe(const EditorUnsupported(UnsupportedReasons.gles3Missing)), 'unsupported');
    });

    test('an unsupported device still shows the entry points (explanation stays reachable)', () {
      expect(const EditorUnsupported(UnsupportedReasons.androidTooOld).showsEntryPoints, isTrue);
    });
  });

  group('EditorAvailability.platform', () {
    test('the compile-time flag defaults to false (D-31)', () {
      expect(EditorFlags.editor, isFalse);
      expect(EditorFlags.autoCaptions, isFalse);
    });

    test('follows the target platform and the flag override', () {
      final cases = <(TargetPlatform, bool), EditorSupport>{
        (TargetPlatform.iOS, true): const EditorSupported(),
        (TargetPlatform.android, true): const EditorSupported(),
        (TargetPlatform.iOS, false): const EditorHidden(EditorHiddenReason.flagOff),
        (TargetPlatform.android, false): const EditorHidden(EditorHiddenReason.flagOff),
        (TargetPlatform.macOS, true): const EditorHidden(EditorHiddenReason.platform),
        (TargetPlatform.windows, true): const EditorHidden(EditorHiddenReason.platform),
        (TargetPlatform.linux, true): const EditorHidden(EditorHiddenReason.platform),
      };
      cases.forEach((key, expected) {
        debugDefaultTargetPlatformOverride = key.$1;
        EditorFlags.debugEditorOverride = key.$2;
        expect(EditorAvailability.platform, expected, reason: '$key');
        expect(EditorAvailability.showsEntryPoints, expected is EditorSupported, reason: '$key');
      });
    });

    test('auto captions flag override', () {
      EditorFlags.debugAutoCaptionsOverride = true;
      expect(EditorFlags.autoCaptionsEnabled, isTrue);
      EditorFlags.debugAutoCaptionsOverride = null;
      expect(EditorFlags.autoCaptionsEnabled, EditorFlags.autoCaptions);
    });
  });

  group('editorDeviceSupportProvider (device gate)', () {
    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      EditorFlags.debugEditorOverride = true;
    });

    test('supported capabilities -> EditorSupported', () async {
      final h = EditorTestHarness();
      final c = h.container();
      expect(await c.read(editorDeviceSupportProvider.future), const EditorSupported());
      expect(h.engine.calls, contains('capabilities'));
    });

    for (final reason in [
      UnsupportedReasons.androidTooOld,
      UnsupportedReasons.gles3Missing,
      UnsupportedReasons.insufficientMemory,
      UnsupportedReasons.metalMissing,
    ]) {
      test('unsupported device ($reason) -> EditorUnsupported($reason)', () async {
        final h = EditorTestHarness(engine: FakeEditorEngine(caps: EditorCapabilities.unsupported(reason)));
        expect(await h.container().read(editorDeviceSupportProvider.future), EditorUnsupported(reason));
      });
    }

    test('unsupported without a reason -> engine_not_available', () async {
      final h = EditorTestHarness(engine: FakeEditorEngine(caps: const EditorCapabilities(supported: false)));
      expect(await h.container().read(editorDeviceSupportProvider.future), const EditorUnsupported(UnsupportedReasons.engineNotAvailable));
    });

    test('a failing engine reports engine_not_available instead of throwing', () async {
      final h = EditorTestHarness();
      h.engine.failNext['capabilities'] = EngineFailure.of(EngineErrorCode.internal);
      expect(await h.container().read(editorDeviceSupportProvider.future), const EditorUnsupported(UnsupportedReasons.engineNotAvailable));
    });

    test('no engine configured (desktop bootstrap without overrides) never throws', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final c = EditorTestHarness().container();
      // A container without the engine override: the root provider throws EditorNotConfiguredError.
      final bare = ProviderContainer();
      addTearDown(bare.dispose);
      expect(() => bare.read(editorEngineProvider), throwsA(isA<EditorNotConfiguredError>()));
      expect(await bare.read(editorDeviceSupportProvider.future), const EditorUnsupported(UnsupportedReasons.engineNotAvailable));
      expect(await c.read(editorDeviceSupportProvider.future), const EditorSupported());
    });

    for (final platform in [TargetPlatform.macOS, TargetPlatform.windows, TargetPlatform.linux]) {
      test('desktop (${platform.name}) is hidden and never asks the engine', () async {
        debugDefaultTargetPlatformOverride = platform;
        final h = EditorTestHarness();
        expect(await h.container().read(editorDeviceSupportProvider.future), const EditorHidden(EditorHiddenReason.platform));
        expect(h.engine.calls, isNot(contains('capabilities')));
      });
    }

    test('flag off on mobile is hidden and never asks the engine', () async {
      EditorFlags.debugEditorOverride = false;
      final h = EditorTestHarness();
      expect(await h.container().read(editorDeviceSupportProvider.future), const EditorHidden(EditorHiddenReason.flagOff));
      expect(h.engine.calls, isNot(contains('capabilities')));
    });
  });
}
