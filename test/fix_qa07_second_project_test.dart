// OWNER: FIX-QA07
//
// QA-07 D3 repro: one wiring per process (like the E2E harness), a new DanaviewApp per testWidgets,
// a project created through Projects > New project in each test must open.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:danaview/app.dart';
import 'package:danaview/main.dart' show editorAppOverrides;
import 'package:danaview/router/app_router.dart';
import 'package:danaview_editor/danaview_editor.dart';
import 'package:danaview_editor_core/store.dart' show StoreRoots;
import 'package:danaview_editor_core/testing.dart' show MemoryStoreFs;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show PickedMedia, MediaOrigin;
import 'package:danaview_editor_engine_api/testing.dart' show FakeEditorEngine;
import 'package:danaview_transcription/testing.dart' show FakeTranscriptionService;

import 'library_test_utils.dart';

const _roots = StoreRoots(support: '/fake/support', cache: '/fake/cache', documents: '/fake/documents');

List<Override>? _world;

final FakeEditorEngine _engine = FakeEditorEngine(validatePlans: false);

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

Future<void> _createEmpty(WidgetTester tester, String name, {bool withMedia = false}) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  EditorFlags.debugEditorOverride = true;
  useSurface(tester, const TestSurface(Size(390, 844), 1.0));
  final overrides = _world ??= await _boot();
  await tester.pumpWidget(ProviderScope(overrides: overrides, child: const DanaviewApp()));
  await _frames(tester);
  await tester.tap(find.byTooltip('Video editor'));
  await _frames(tester);
  expect(find.byType(ProjectsScreen), findsOneWidget);
  debugPrint('texts: ${find.byType(Text).evaluate().map((e) => (e.widget as Text).data).toList()}');
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
    debugPrint('after create: ${find.byType(Text).evaluate().map((e) => (e.widget as Text).data).toList()}');
  } else {
    await _tapKey(tester, 'new-project-start-empty');
  }
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  await _frames(tester, 20);
  expect(find.byType(EditorScreen), findsOneWidget, reason: 'the editor of "$name" opens');
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(const EventChannel('danaview/device_orientation'), MockStreamHandler.inline(onListen: (_, __) {}));
  });

  testWidgets('a second DanaviewApp over the same wiring opens its new project', (tester) async {
    try {
      await _createEmpty(tester, 'One', withMedia: true);
      // What the test binding does between two testWidgets: unmount the whole tree.
      await tester.pumpWidget(Container(key: UniqueKey()));
      await _frames(tester, 40);
      await _createEmpty(tester, 'Two', withMedia: true);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      EditorFlags.debugEditorOverride = null;
    }
  });
}
