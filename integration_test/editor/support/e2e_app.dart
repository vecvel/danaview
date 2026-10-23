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
import 'package:danaview_editor_engine/src/mobile_media_access.dart' show MobileMediaAccess;
import 'package:danaview_engine/danaview_engine.dart';
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_platform/danaview_platform.dart';
import 'package:danaview_transcription/danaview_transcription.dart' show SpeechModelCatalog;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'e2e_config.dart';
import 'e2e_engine.dart';
import 'e2e_handshake.dart';
import 'e2e_wait.dart';

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

  /// Whether [_boot] fills in the Documents root the app forgets (FIX-INT-02-1). Set
  /// `--dart-define=DV_E2E_NO_WORKAROUNDS=true` to run against the app's wiring as it is.
  static const bool _workaroundDocumentsRoot = !bool.fromEnvironment('DV_E2E_NO_WORKAROUNDS');

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
    final mobile = MobileEditorEngine(config: EditorBootstrap.engineConfigOf(roots));
    // Workaround for FIX-INT-02-1 (blocker): nothing in the app sets
    // `MobileMediaAccess.documentsRoot`, so every media under Documents (all Files imports,
    // ARCH §9.1 `documentsReference`) resolves as "accessLost: documents root not available" and
    // the preview, export and relink see it offline. The suite sets it here so the other scenarios
    // can run; remove this block when FIX-INT-02-1 lands (run with DV_E2E_NO_WORKAROUNDS=true to confirm the fix).
    final access = mobile.access;
    if (_workaroundDocumentsRoot && access is MobileMediaAccess && access.documentsRoot == null) {
      access.documentsRoot = roots.documents;
    }
    final engine = E2eEditorEngine(mobile);
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
  ///
  /// A later `testWidgets` of the same process reuses the wiring, so the launch first waits until
  /// the previous test's work on it is done (FIX-QA07, QA-07 D3): projects it left open are closed,
  /// a captions job it left running ends, and the project list answers. A wiring still busy fails
  /// here with the reason instead of as a New project that never opens two minutes later.
  static Future<E2eWorld> launch(WidgetTester tester) async {
    final reused = _world != null;
    final world = _world ??= await _boot();
    if (reused) await _settleWorld(world);
    await tester.pumpWidget(ProviderScope(overrides: world.overrides, child: const DanaviewApp()));
    await pumpUntil(tester, () => find.byType(DanaviewHomeScreen).evaluate().isNotEmpty, what: 'Home');
    return world;
  }

  /// Waits (bounded) until the shared wiring holds nothing of the previous test (see [launch]).
  static Future<void> _settleWorld(E2eWorld world) async {
    final repository = world.runtime.repository;
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    final job = world.captions?.service.activeJob;
    if (job != null) {
      job.cancel();
      while (world.captions?.service.activeJob != null && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    for (final id in repository.openIds) {
      // The previous app was unmounted without the editor's close flow.
      debugPrint('[E2E] closing project $id left open by the previous test');
      try {
        await repository.close(id).timeout(const Duration(seconds: 10));
      } on Object catch (e) {
        debugPrint('[E2E] could not close $id: ${e.runtimeType}');
      }
    }
    try {
      await repository.watchSummaries().first.timeout(deadline.difference(DateTime.now()));
    } on TimeoutException {
      throw TestFailure('The shared editor wiring is still busy with the previous test (the project list does not answer); '
          'run this test in its own process');
    }
  }

  /// The app's provider container.
  static ProviderContainer container(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(DanaviewApp)), listen: false);

  /// Pumps frames until [ready] holds, or fails after [timeout] naming [what]. An exception from
  /// [ready] fails the wait at once, except a lookup that has nothing to find yet (see [E2eWait];
  /// [retryOn] adds exceptions that mean "not ready yet").
  static Future<void> pumpUntil(
    WidgetTester tester,
    bool Function() ready, {
    required String what,
    Duration timeout = const Duration(seconds: 30),
    Duration step = const Duration(milliseconds: 50),
    bool Function(Object error)? retryOn,
  }) =>
      E2eWait.until(
        () => tester.pump(),
        ready,
        what: what,
        timeout: timeout,
        step: step,
        retryOn: retryOn,
        describe: describeScreen,
      );

  /// What is on screen, for a timeout message: the routes' texts (first 40) and the hit-testable
  /// keyed widgets, so a failed wait shows the dialog or sheet that was in the way.
  static String describeScreen() {
    final texts = <String>[
      for (final e in find.byType(Text).hitTestable().evaluate().take(40))
        if ((e.widget as Text).data case final d? when d.trim().isNotEmpty) d.replaceAll('\n', ' '),
    ];
    final keys = <String>{
      for (final e in find.byWidgetPredicate((w) => w.key is ValueKey<String>).hitTestable().evaluate().take(60))
        (e.widget.key! as ValueKey<String>).value,
    };
    return 'screen texts: $texts\nscreen keys: $keys';
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

  /// A 0.1 s tap on [finder] (scrolled into view first, once it receives hits). With
  /// [ifStillThere], a target that went away meanwhile is not tapped; otherwise that fails.
  static Future<void> tap(WidgetTester tester, Finder finder, {String? what, bool ifStillThere = false}) async {
    final target = finder.first;
    await pumpUntil(tester, () => target.evaluate().isNotEmpty, what: what ?? '$finder');
    await tester.ensureVisible(target);
    await tester.pump();
    // A route still animating in ignores pointers (the Navigator's IgnorePointer), so a tap right
    // after a push is lost: wait until the target receives hits at its centre (bounded; a target
    // under a deliberate overlay is still tapped after the wait).
    try {
      await pumpUntil(tester, () => target.hitTestable().evaluate().isNotEmpty, what: 'hit-testable ${what ?? finder}', timeout: const Duration(seconds: 5));
    } on TestFailure {
      // Tap anyway; the caller's next wait reports what was in the way.
    }
    if (finder.evaluate().isEmpty || (ifStillThere && finder.hitTestable().evaluate().isEmpty)) {
      // It went away (or is leaving with its route) while the route settled, for example a
      // summary that closed itself. Tapping its old position would hit the next screen.
      if (ifStillThere) return;
      throw TestFailure('${what ?? finder} disappeared before the tap\n${describeScreen()}');
    }
    await _waitStill(tester, target);
    if (finder.evaluate().isEmpty || (ifStillThere && finder.hitTestable().evaluate().isEmpty)) {
      if (ifStillThere) return;
      throw TestFailure('${what ?? finder} disappeared before the tap\n${describeScreen()}');
    }
    final gesture = await tester.startGesture(tester.getCenter(target));
    // No pump while the pointer is down: on a device a pump waits for a real frame, and a slow one
    // (GC, a loaded emulator) held the press past the 500 ms long-press timeout, so a tooltip's long
    // press took the tap (FIX M-24, s18 on the 2 GB AVD).
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// [tap] on the widget keyed [key].
  static Future<void> tapKey(WidgetTester tester, String key, {bool ifStillThere = false}) =>
      tap(tester, find.byKey(ValueKey<String>(key)), what: 'key $key', ifStillThere: ifStillThere);

  /// Whether a widget keyed [key] is in the tree.
  static bool hasKey(String key) => find.byKey(ValueKey<String>(key)).evaluate().isNotEmpty;

  /// Waits for the widget keyed [key].
  static Future<void> waitKey(WidgetTester tester, String key, {Duration timeout = const Duration(seconds: 30)}) =>
      pumpUntil(tester, () => hasKey(key), what: 'key $key', timeout: timeout);

  /// Types [text] into the text field keyed [key], then closes the keyboard and waits until the
  /// layout is back (FIX-QA07, QA-07 D3): a keyboard still sliding away moves a sheet's buttons
  /// between the hit test and the tap, which then lands on the barrier and dismisses the sheet.
  static Future<void> enterText(WidgetTester tester, String key, String text) async {
    await waitKey(tester, key);
    final field = find.descendant(of: find.byKey(ValueKey<String>(key)), matching: find.byType(EditableText));
    await tester.enterText(field.evaluate().isEmpty ? find.byKey(ValueKey<String>(key)) : field.first, text);
    await tester.pump();
    await hideKeyboard(tester);
  }

  /// Unfocuses the text field and waits (bounded) until no keyboard inset is left.
  static Future<void> hideKeyboard(WidgetTester tester) async {
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    } on Object {
      // No text input channel (host runs); nothing to hide.
    }
    final view = tester.view;
    try {
      await pumpUntil(tester, () => view.viewInsets.bottom == 0, what: 'the keyboard to close', timeout: const Duration(seconds: 5));
    } on TestFailure {
      // A hardware keyboard or a docked iPad keyboard keeps an inset; the tap waits for a still target.
    }
  }

  /// Waits (bounded) until [target]'s centre stops moving (a sheet or keyboard still animating).
  static Future<void> _waitStill(WidgetTester tester, Finder target) async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    Offset? last;
    while (DateTime.now().isBefore(deadline)) {
      if (target.evaluate().isEmpty) return;
      final now = tester.getCenter(target);
      if (last != null && (now - last).distance < 0.5) return;
      last = now;
      await tester.pump(const Duration(milliseconds: 100));
    }
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
