// OWNER: INT-02
//
// The editor's app routes and entry points (ARCH §17.1, D-17, D-31): `/projects`,
// `/editor/:projectId?t=`, `/settings/editor`, the Home edit button, the Settings "Video editor" row
// and the Settings › Storage contributors, gated by platform and the VWISH_EDITOR flag.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:vwish/app.dart';
import 'package:vwish/router/app_router.dart';
import 'package:vwish_editor/vwish_editor.dart';
import 'package:vwish_editor_core/store.dart' show EmptyProjectSpec, StoreRoots;
import 'package:vwish_editor_core/testing.dart' show MemoryStoreFs;
import 'package:vwish_editor_engine_api/testing.dart' show FakeEditorEngine;
import 'package:vwish_features/vwish_features.dart';
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import 'library_test_utils.dart';

const _roots = StoreRoots(support: '/fake/support', cache: '/fake/cache', documents: '/fake/documents');
const _editorTooltip = 'Video editor';

/// The app on [platform] with the editor flag [flag], wired like `main.dart` does.
Future<_App> _pumpApp(WidgetTester tester, {required TargetPlatform platform, required bool flag}) async {
  debugDefaultTargetPlatformOverride = platform;
  EditorFlags.debugEditorOverride = flag;
  useSurface(tester, const TestSurface(Size(390, 844), 1.0));
  final env = await LibraryTestEnv.create();
  final engine = FakeEditorEngine();
  final editor = await EditorBootstrap.create(
    engine: EditorAvailability.platform is EditorSupported ? engine : null,
    roots: _roots,
    prefs: EditorPrefs.memory(),
    fs: MemoryStoreFs(),
    startGc: false,
    listenToLifecycle: false,
    onOpenProjects: openProjects,
  );
  final container = ProviderContainer(overrides: [...env.overrides, ...editor]);
  await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const VwishApp()));
  await pumpFrames(tester);
  return _App(tester, env, container, engine);
}

class _App {
  _App(this.tester, this.env, this.container, this.engine);

  final WidgetTester tester;
  final LibraryTestEnv env;
  final ProviderContainer container;
  final FakeEditorEngine engine;

  GoRouter get router => GoRouter.of(tester.element(find.byType(Navigator).first));

  String get location => router.state.uri.toString();

  Future<void> go(String location) async {
    router.go(location);
    await pumpFrames(tester, count: 10);
  }

  Future<void> dispose() async {
    VwishToast.dismiss();
    await tester.pumpWidget(const SizedBox());
    await pumpFrames(tester, count: 40);
    await container.read(editorRuntimeProvider)?.dispose();
    container.dispose();
    await env.dispose();
    debugDefaultTargetPlatformOverride = null;
    EditorFlags.debugEditorOverride = null;
  }
}

void main() {
  group('platform gate', () {
    test('supported only on iOS/Android with VWISH_EDITOR; hidden on desktop and web', () {
      for (final platform in TargetPlatform.values) {
        for (final flag in [true, false]) {
          final support = EditorAvailability.resolve(platform: platform, editorFlag: flag);
          final mobile = platform == TargetPlatform.iOS || platform == TargetPlatform.android;
          expect(support.showsEntryPoints, mobile && flag, reason: '$platform flag=$flag');
          if (!mobile) expect(support, const EditorHidden(EditorHiddenReason.platform));
          if (mobile && !flag) expect(support, const EditorHidden(EditorHiddenReason.flagOff));
        }
      }
      expect(EditorAvailability.resolve(platform: TargetPlatform.iOS, editorFlag: true, isWeb: true).showsEntryPoints, isFalse);
    });

    test('editor locations encode the id and the playhead', () {
      expect(editorLocation(const ProjectId('pr_abc')), '/editor/pr_abc');
      expect(editorLocation(const ProjectId('pr_abc'), initialPlayhead: 1500000), '/editor/pr_abc?t=1500000');
      expect(editorLocation(const ProjectId('a/b')), '/editor/a%2Fb');
    });
  });

  group('macOS (D-17)', () {
    testWidgets('no edit button, no Video editor row, no storage contributor; editor routes redirect to /', (tester) async {
      final app = await _pumpApp(tester, platform: TargetPlatform.macOS, flag: true);
      try {
        expect(find.byType(VwishHomeScreen), findsOneWidget);
        expect(find.byTooltip(_editorTooltip), findsNothing);
        expect(app.container.read(storageContributorsProvider), isEmpty);
        expect(app.container.read(editorRuntimeProvider), isNull);
        expect(app.engine.log.calls, isEmpty);

        await app.go('/settings');
        expect(find.byType(VwishSettingsScreen), findsOneWidget);
        expect(find.byKey(const ValueKey('settings-video-editor')), findsNothing);
        expect(find.text('Video editor'), findsNothing);

        for (final location in ['/projects', '/editor/x', '/editor/x?t=1000', '/settings/editor']) {
          await app.go(location);
          expect(app.location, '/', reason: location);
          expect(find.byType(ProjectsScreen), findsNothing);
          expect(find.byType(EditorScreen), findsNothing);
          expect(find.byType(EditorSettingsScreen), findsNothing);
        }
        expect(tester.takeException(), isNull);
      } finally {
        await app.dispose();
      }
    });
  });

  group('iOS/Android with VWISH_EDITOR off', () {
    for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
      testWidgets('$platform: hidden entry points and redirects', (tester) async {
        final app = await _pumpApp(tester, platform: platform, flag: false);
        try {
          expect(find.byTooltip(_editorTooltip), findsNothing);
          expect(app.container.read(storageContributorsProvider), isEmpty);
          await app.go('/projects');
          expect(app.location, '/');
          await app.go('/editor/pr_x');
          expect(app.location, '/');
        } finally {
          await app.dispose();
        }
      });
    }
  });

  group('iOS/Android with VWISH_EDITOR on', () {
    for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
      testWidgets('$platform: Home edit button opens Projects; storage lists the editor contributors', (tester) async {
        final app = await _pumpApp(tester, platform: platform, flag: true);
        try {
          expect(app.container.read(storageContributorsProvider).map((c) => c.id), ['editor.projects', 'editor.cache']);

          final button = find.byTooltip(_editorTooltip);
          expect(button, findsOneWidget);
          await tester.tap(button);
          await pumpFrames(tester, count: 10);
          expect(app.location, '/projects');
          expect(find.byType(ProjectsScreen), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          await app.dispose();
        }
      });
    }

    testWidgets('deep link /editor/<unknown> shows the unavailable empty state', (tester) async {
      final app = await _pumpApp(tester, platform: TargetPlatform.iOS, flag: true);
      try {
        await app.go('/editor/pr_missing0001?t=2000000');
        expect(app.location, '/editor/pr_missing0001?t=2000000');
        final screen = tester.widget<EditorScreen>(find.byType(EditorScreen));
        expect(screen.projectId, const ProjectId('pr_missing0001'));
        expect(screen.initialPlayhead, 2000000);
        expect(find.text("This project isn't available"), findsOneWidget);
        expect(find.text('Go to Projects'), findsOneWidget);

        await tester.tap(find.text('Go to Projects'));
        await pumpFrames(tester, count: 10);
        expect(app.location, '/projects');
        expect(find.byType(ProjectsScreen), findsOneWidget);
      } finally {
        await app.dispose();
      }
    });

    testWidgets('a malformed t is ignored', (tester) async {
      final app = await _pumpApp(tester, platform: TargetPlatform.android, flag: true);
      try {
        await app.go('/editor/pr_missing0002?t=abc');
        expect(tester.widget<EditorScreen>(find.byType(EditorScreen)).initialPlayhead, isNull);
        await app.go('/editor/pr_missing0002?t=-5');
        expect(tester.widget<EditorScreen>(find.byType(EditorScreen)).initialPlayhead, isNull);
      } finally {
        await app.dispose();
      }
    });

    testWidgets('Settings shows the Video editor row, which opens /settings/editor', (tester) async {
      final app = await _pumpApp(tester, platform: TargetPlatform.iOS, flag: true);
      try {
        await app.go('/settings');
        final row = find.byKey(const ValueKey('settings-video-editor'));
        expect(row, findsOneWidget);
        await tester.ensureVisible(row);
        await tester.tap(row);
        await pumpFrames(tester, count: 10);
        expect(app.location, editorSettingsLocation);
        expect(find.byType(EditorSettingsScreen), findsOneWidget);
      } finally {
        await app.dispose();
      }
    });

    testWidgets('Projects opens a project in the editor and its storage link opens Settings › Storage', (tester) async {
      final app = await _pumpApp(tester, platform: TargetPlatform.iOS, flag: true);
      try {
        final repo = app.container.read(projectRepositoryProvider);
        final id = await repo.create(const EmptyProjectSpec(name: 'Trip'));
        await app.go('/projects');
        final card = find.byKey(ValueKey('project-card-$id'));
        expect(card, findsOneWidget);
        await tester.tap(card);
        await pumpFrames(tester, count: 10);
        expect(app.location, editorLocation(id));
        expect(find.byType(EditorScreen), findsOneWidget);

        // System back runs the editor's close flow (flush, close), then the router pops to Projects.
        await tester.binding.handlePopRoute();
        await pumpFrames(tester, count: 20);
        expect(find.byType(EditorScreen), findsNothing);
        expect(app.location, projectsLocation);
        expect(app.container.read(editorRuntimeProvider)!.repository.openIds, isEmpty);

        final manage = find.byKey(const ValueKey('projects-manage-storage'));
        await tester.ensureVisible(manage);
        await tester.tap(manage);
        await pumpFrames(tester, count: 10);
        expect(app.location, settingsLocation(SettingsDestination.storage));
        expect(find.byType(VwishStorageScreen), findsOneWidget);
      } finally {
        await app.dispose();
      }
    });
  });
}
