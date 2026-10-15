// OWNER: QA-00
//
// Boots the real app for the E2E suite: the same wiring as `lib/main.dart` (mpv player engine,
// session and library repositories, `EditorBootstrap.createRuntime`, `editorAppOverrides` with Auto
// captions), with the production `MobileEditorEngine` wrapped by `E2eEditorEngine` (picker and
// handoff seams only). The wiring is built once per test process; every `testWidgets` pumps a new
// `ProviderScope` + `DanaviewApp` over it.
//
// Waiting rules (QA-00 acceptance): every wait polls a condition (an engine ack, a state change, a
// handshake file) with a deadline; no step relies on a fixed sleep. Taps go through [E2eApp.tap]:
// pointer down, 100 ms, pointer up (the simulator ignores instant taps, see the iOS testing notes),
// and nothing ever takes a screenshot while a tap is in flight.

// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:io';

import 'package:danaview/app.dart';
import 'package:danaview/main.dart' show createAutoCaptions, editorAppOverrides;
import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_editor/danaview_editor.dart';
import 'package:danaview_editor_engine/danaview_editor_engine.dart';
import 'package:danaview_engine/danaview_engine.dart';
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_platform/danaview_platform.dart';
import 'package:danaview_transcription/danaview_transcription.dart' show SpeechModelCatalog;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'e2e_config.dart';
import 'e2e_engine.dart';
import 'e2e_handshake.dart';

/// The wired app of this test process.
final class E2eWorld {
  E2eWorld._({required this.engine, required this.runtime, required this.captions, required this.overrides});

  /// The editor engine with the test seams.
  final E2eEditorEngine engine;

  /// The editor runtime (store, pool, compiler, GC).
  final EditorRuntime runtime;

  /// Auto captions, when the build has them.
  final AutoCaptionsRuntime? captions;

  /// The app's provider overrides.
  final List<Override> overrides;
}

/// App-level driver of the suite.
abstract final class E2eApp {
  static E2eWorld? _world;

  /// The wiring (built by the first [launch]).
  static E2eWorld get world => _world ?? (throw StateError('E2eApp.launch first'));

  static Future<E2eWorld> _boot() async {
    if (!E2eConfig.editorFlag) {
      throw StateError('Build with --dart-define=DANAVIEW_EDITOR=true (and DANAVIEW_AUTO_CAPTIONS=true for scenario 8)');
    }
    if (EditorAvailability.platform is! EditorSupported) {
      throw StateError('The editor is not supported on this device: ${EditorAvailability.platform}');
    }
    // lib/main.dart, step by step.
    IncomingMediaBridge.setLaunchArgs(const []);
    await PlatformBridge.initializeWindow();
    if (PlatformBridge.isMobile) await PlayerOrientation.applyAppDefault();
    final prefs = await SharedPreferences.getInstance();
    final sessionRepo = SessionRepository(prefs);
    final libraryRepo = LibraryRepository(prefs);
    await sessionRepo.migrateMediaIds(libraryRepo.resolveStoredPath);
    final player = MpvPlaybackEngine(subtitleFontAssets: DanaviewFonts.files);
    await player.initialize();

    final roots = await EditorBootstrap.defaultRoots();
    final engine = E2eEditorEngine(MobileEditorEngine(config: EditorBootstrap.engineConfigOf(roots)));
    final runtime = await EditorBootstrap.createRuntime(engine: engine, roots: roots, prefs: await EditorPrefs.load());
    final captions = EditorAppWiring.autoCaptionsEnabled ? createAutoCaptions(engine: engine, supportDirectory: roots.support) : null;
    if (captions != null) await captions.service.initialize();
    final overrides = <Override>[
      playbackEngineProvider.overrideWithValue(player),
      sessionRepositoryProvider.overrideWithValue(sessionRepo),
      libraryRepositoryProvider.overrideWithValue(libraryRepo),
      ...editorAppOverrides(runtime, transcription: captions?.service),
    ];
    return E2eWorld._(engine: engine, runtime: runtime, captions: captions, overrides: overrides);
  }

  /// Boots the wiring (once per process) and pumps the app at Home.
  static Future<E2eWorld> launch(WidgetTester tester) async {
    final world = _world ??= await _boot();
    await tester.pumpWidget(ProviderScope(overrides: world.overrides, child: const DanaviewApp()));
    await pumpUntil(tester, () => find.byType(DanaviewHomeScreen).evaluate().isNotEmpty, what: 'Home');
    return world;
  }

  /// The app's provider container.
  static ProviderContainer container(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(DanaviewApp)), listen: false);

  /// Pumps frames until [ready] holds, or fails after [timeout] naming [what].
  static Future<void> pumpUntil(
    WidgetTester tester,
    bool Function() ready, {
    required String what,
    Duration timeout = const Duration(seconds: 30),
    Duration step = const Duration(milliseconds: 50),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      await tester.pump();
      bool ok;
      try {
        ok = ready();
      } on TestFailure {
        rethrow;
      } on Object {
        // Not there yet (a finder or a provider not built yet).
        ok = false;
      }
      if (ok) return;
      if (DateTime.now().isAfter(deadline)) throw TestFailure('Timed out after ${timeout.inSeconds} s waiting for $what');
      await Future<void>.delayed(step);
    }
  }

  /// Awaits [future] while pumping frames (an engine call that needs the UI to keep running).
  static Future<T> pumpWhile<T>(WidgetTester tester, Future<T> future, {required String what, Duration timeout = const Duration(seconds: 60)}) async {
    var done = false;
    T? value;
    Object? error;
    StackTrace? stack;
    unawaited(future.then((v) {
      value = v;
      done = true;
    }, onError: (Object e, StackTrace s) {
      error = e;
      stack = s;
      done = true;
    }));
    await pumpUntil(tester, () => done, what: what, timeout: timeout);
    if (error != null) Error.throwWithStackTrace(error!, stack!);
    return value as T;
  }

  /// A 0.1 s tap on [finder] (scrolled into view first).
  static Future<void> tap(WidgetTester tester, Finder finder, {String? what}) async {
    final target = finder.first;
    await pumpUntil(tester, () => target.evaluate().isNotEmpty, what: what ?? '$finder');
    await tester.ensureVisible(target);
    await tester.pump();
    final gesture = await tester.startGesture(tester.getCenter(target));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// [tap] on the widget keyed [key].
  static Future<void> tapKey(WidgetTester tester, String key) => tap(tester, find.byKey(ValueKey<String>(key)), what: 'key $key');

  /// Whether a widget keyed [key] is in the tree.
  static bool hasKey(String key) => find.byKey(ValueKey<String>(key)).evaluate().isNotEmpty;

  /// Waits for the widget keyed [key].
  static Future<void> waitKey(WidgetTester tester, String key, {Duration timeout = const Duration(seconds: 30)}) =>
      pumpUntil(tester, () => hasKey(key), what: 'key $key', timeout: timeout);

  /// Types [text] into the text field keyed [key].
  static Future<void> enterText(WidgetTester tester, String key, String text) async {
    await waitKey(tester, key);
    final field = find.descendant(of: find.byKey(ValueKey<String>(key)), matching: find.byType(EditableText));
    await tester.enterText(field.evaluate().isEmpty ? find.byKey(ValueKey<String>(key)) : field.first, text);
    await tester.pump();
  }

  /// Opens Projects from Home through the edit button left of the gear (scenario 1).
  static Future<void> openProjectsFromHome(WidgetTester tester) async {
    await tap(tester, find.bySemanticsLabel('Open video editor'), what: 'Home edit button');
    await pumpUntil(tester, () => find.byType(ProjectsScreen).evaluate().isNotEmpty, what: 'Projects screen');
  }

  /// Evidence screenshot taken by the host (`xcrun simctl io screenshot` / `adb exec-out screencap`)
  /// after the UI settled; skipped without a host driver. Never runs in parallel with a tap.
  static Future<void> screenshot(WidgetTester tester, String name) async {
    await tester.pump(const Duration(milliseconds: 300));
    if (!E2eHandshake.available) return;
    await E2eHandshake.request(tester, 'screenshot', args: {'name': name}, timeout: const Duration(seconds: 30));
  }

  /// Installs the tiny model and the VAD from [E2eConfig.modelsDir] through the store's
  /// `installFromFile` seam (no network). Returns false when the files are not staged.
  static Future<bool> stageSpeechModel() async {
    final captions = world.captions;
    if (captions == null) return false;
    final model = File('${E2eConfig.modelsDir}/${SpeechModelCatalog.fast.fileName}');
    final vad = File('${E2eConfig.modelsDir}/${SpeechModelCatalog.vad.fileName}');
    if (!model.existsSync() || !vad.existsSync()) return false;
    if (await captions.store.installed(SpeechModelCatalog.fast.id) != null) return true;
    await captions.store.installFromFile(SpeechModelCatalog.vad, vad.path);
    await captions.store.installFromFile(SpeechModelCatalog.fast, model.path);
    return true;
  }
}
