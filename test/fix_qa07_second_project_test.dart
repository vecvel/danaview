// OWNER: FIX-QA07
//
// QA-07 D3: the E2E harness builds the app wiring once per process and pumps a new DanaviewApp in
// every testWidgets. A project created through Projects › New project in the second app must open
// like the first one: the app router (a new GoRouter per DanaviewApp over the shared
// `appNavigatorKey`) and the shared editor runtime carry nothing over from the first app.
//
// The second app is pumped inside one testWidgets after unmounting the first tree (what the test
// binding does between two testWidgets). Two separate host testWidgets cannot share the wiring:
// work the first test leaves in flight (the repository's rescans, the close flush) belongs to that
// test's FakeAsync zone and never completes in the next one. On a device there is no fake clock;
// there the harness waits for the shared wiring to be idle before each launch (E2eApp.launch).

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview/app.dart';
import 'package:danaview/main.dart' show editorAppOverrides;
import 'package:danaview_editor/danaview_editor.dart';
import 'package:danaview_editor_core/store.dart' show StoreRoots;
import 'package:danaview_editor_core/testing.dart' show MemoryStoreFs;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show PickedMedia;
import 'package:danaview_editor_core/model.dart' show MediaKind, MediaOrigin, MediaProbe;
import 'package:danaview_editor_engine_api/testing.dart' show FakeEditorEngine;
import 'package:danaview_transcription/testing.dart' show FakeTranscriptionService;

import 'library_test_utils.dart';

const _roots = StoreRoots(support: '/fake/support', cache: '/fake/cache', documents: '/fake/documents');

List<Override>? _world;

const int _s = 1000000;
final _probe = MediaProbe(kind: MediaKind.video, duration: 10 * _s, hasVideo: true, hasAudio: true, width: 1920, height: 1080);
final FakeEditorEngine _engine = FakeEditorEngine(validatePlans: false, probes: {
  for (final n in ['One', 'Two']) ...{'/fake/documents/$n.mp4': _probe, 'file:///fake/documents/$n.mp4': _probe},
});

Future<List<Override>> _boot() async {
  final env = await LibraryTestEnv.create();
  final runtime = await EditorBootstrap.createRuntime(
    engine: _engine,
    roots: _roots,
    prefs: EditorPrefs.memory(),
    fs: MemoryStoreFs(),
    startGc: false,
    listenToLifecycle: false,
  );
  return [...env.overrides, ...editorAppOverrides(runtime, transcription: FakeTranscriptionService())];
}

Future<void> _frames(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  final f = find.byKey(ValueKey(key));
  expect(f, findsOneWidget, reason: key);
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
  await _frames(tester);
}

/// Pumps a new DanaviewApp over the shared wiring and creates [name] through Projects › New project.
Future<void> _createAndOpen(WidgetTester tester, String name, {bool withMedia = true}) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  EditorFlags.debugEditorOverride = true;
  useSurface(tester, const TestSurface(Size(390, 844), 1.0));
  final overrides = _world ??= await _boot();
  await tester.pumpWidget(ProviderScope(overrides: overrides, child: const DanaviewApp()));
  await _frames(tester);
  await tester.tap(find.byTooltip('Video editor'));
  await _frames(tester);
  expect(find.byType(ProjectsScreen), findsOneWidget);
  await _tapKey(tester, 'projects-new');
  await tester.enterText(find.byKey(const ValueKey('new-project-name')), name);
  await _frames(tester, 2);
  if (withMedia) {
    _engine.picker.nextPicks = [
      PickedMedia(uri: 'file:///fake/documents/$name.mp4', displayName: '$name.mp4', origin: MediaOrigin.files, isTemporaryCopy: false, sizeBytes: 1000),
    ];
    await _tapKey(tester, 'new-project-files');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await _frames(tester);
    await _tapKey(tester, 'new-project-create');
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await _frames(tester, 5);
    }
  } else {
    await _tapKey(tester, 'new-project-start-empty');
  }
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  await _frames(tester, 20);
  expect(find.byType(EditorScreen), findsOneWidget, reason: 'the editor of "$name" opens');
}

Future<void> _closeEditor(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await _frames(tester, 3);
  }
  expect(find.byType(EditorScreen), findsNothing);
  expect(find.byType(ProjectsScreen), findsOneWidget);
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(const EventChannel('danaview/device_orientation'), MockStreamHandler.inline(onListen: (_, __) {}));
  });

  testWidgets('a second DanaviewApp over the same wiring opens the project it creates', (tester) async {
    try {
      await _createAndOpen(tester, 'One');
      await _closeEditor(tester);
      // What the test binding does between two testWidgets: unmount the whole tree.
      await tester.pumpWidget(Container(key: UniqueKey()));
      await _frames(tester, 40);
      await _createAndOpen(tester, 'Two');
      expect(find.text('Two'), findsWidgets);
      await _closeEditor(tester);
      expect(find.text('2 projects'), findsOneWidget);
      await tester.pumpWidget(Container(key: UniqueKey()));
      await _frames(tester, 40);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      EditorFlags.debugEditorOverride = null;
    }
  });
}
