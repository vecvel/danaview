// OWNER: S2-W
//
// BUILD_PLAN v1.2 §1A, S2 gate "Wiring and legal": the S2 features (Photos & Files Home) are
// reachable in the real app (DanaviewApp with the app router) behind DANAVIEW_FILES_HOME, and the
// app is the S1 app without it:
//
// * flag off: no override, no Files & Media Home, Settings shows only Settings › Privacy;
// * flag on: the library opens under the support directory, the import, organise, selection,
//   photo-viewer and thumbnail providers are installed; the Home shows Home, All, Videos, Photos,
//   Playlists and Folders (no Documents until S3) with the 1.1 sections on Home, the Import and
//   search row, the library tabs read the store, opening a document shows its file menu, See all
//   and folder requests switch tabs; Settings shows Library storage after Privacy;
// * the Home with the S2 slots and Settings with Library storage don't overflow at 280-1280 px and
//   text scale 0.85-1.35.

// The root package reaches the library through danaview_features in its fixtures.
// ignore_for_file: depend_on_referenced_packages, implementation_imports

import 'dart:io';

import 'package:danaview/app.dart';
import 'package:danaview/router/app_router.dart';
import 'package:danaview/wiring/files_home_wiring.dart';
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_features/src/flags.dart';
import 'package:danaview_features/src/library/file_actions/file_actions.dart';
import 'package:danaview_features/src/library/files/library_store_providers.dart';
import 'package:danaview_features/src/library/home/recent_photos_tray.dart' show HomeTabRequestNotification;
import 'package:danaview_features/src/library/import/import_pickers.dart';
import 'package:danaview_features/src/library/import/import_providers.dart';
import 'package:danaview_features/src/library/organise/organise_providers.dart';
import 'package:danaview_features/src/library/photo_viewer/photo_viewer_actions.dart';
import 'package:danaview_features/src/library/selection/selection_bar.dart';
import 'package:danaview_features/src/more/settings_sections/library_storage_section.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../library_test_utils.dart';
import '../filters/filters_support.dart';

final Finder _tabStrip = find.byKey(const ValueKey('home-tab-strip'));
final Finder _storageSection = find.byKey(const ValueKey('settings-section-libraryStorage'));
final Finder _privacySection = find.byKey(const ValueKey('settings-section-privacy'));

class _App {
  _App(this.tester, this.env, this.container, this.runtime, this.lib);

  final WidgetTester tester;
  final LibraryTestEnv env;
  final ProviderContainer container;
  final FilesHomeRuntime runtime;
  final FixtureLibrary? lib;

  GoRouter get router => GoRouter.of(tester.element(find.byType(Navigator).first));

  Future<void> go(String location) async {
    router.go(location);
    await pumpFrames(tester, count: 10);
  }

  Future<void> tab(HomeTab tab) async {
    await tester.ensureVisible(find.byKey(homeTabKey(tab)));
    await tester.pump();
    await tester.tap(find.byKey(homeTabKey(tab)));
    await pumpFrames(tester, count: 8);
    expect(tester.takeException(), isNull);
  }

  Future<void> dispose() async {
    DanaviewToast.dismiss();
    await tester.pumpWidget(const SizedBox());
    await pumpFrames(tester, count: 6);
    container.dispose();
    if (lib case final lib?) {
      await lib.close(tester);
    }
    await env.dispose();
  }
}

/// Boots the app. With [filesHome] the S2 runtime is built over an in-process fixture library
/// (seeded by [seed]) for [platform]; [roots] records where the wiring opened the store.
Future<_App> _pumpApp(
  WidgetTester tester, {
  bool filesHome = false,
  double textScale = 1.0,
  TargetPlatform platform = TargetPlatform.iOS,
  Future<void> Function(FixtureLibrary lib)? seed,
  List<String>? roots,
}) async {
  FeatureFlags.debugFilesHomeOverride = filesHome;
  addTearDown(FeatureFlags.debugReset);
  final env = await LibraryTestEnv.create();
  final lib = filesHome ? await FixtureLibrary.open(tester) : null;
  if (lib != null && seed != null) await seed(lib);
  final support = Directory.systemTemp.path;
  final runtime = (await tester.runAsync(() => filesHomeOverrides(
        prefs: env.prefs,
        platform: platform,
        directories: FilesHomeDirectories(support: support, cache: Directory.systemTemp.path),
        openStore: (root, _) async {
          roots?.add(root);
          return lib!.store;
        },
        openThumbnails: (_) async => throw const FileSystemException('no thumbnails in tests'),
        observeLifecycle: false,
      )))!;
  final container = ProviderContainer(overrides: [...env.overrides, ...runtime.overrides]);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const DanaviewApp()));
  await pumpFrames(tester);
  return _App(tester, env, container, runtime, lib);
}

Future<void> _seedMixed(FixtureLibrary lib, WidgetTester tester) async {
  for (final name in ['Beach.jpg', 'Holiday.mp4', 'Report.pdf']) {
    await lib.add(tester, name);
    lib.now = lib.now.add(const Duration(minutes: 1));
  }
}

void main() {
  tearDown(FeatureFlags.debugReset);

  group('flag off: the S1 app', () {
    test('DANAVIEW_FILES_HOME defaults to false and the wiring adds nothing', () async {
      expect(FeatureFlags.filesHome, isFalse);
      expect(filesHomeWired, isFalse);
      final runtime = await filesHomeOverrides(
        prefs: (await LibraryTestEnv.create()).prefs,
        openStore: (_, __) => fail('the library must not open with the flag off'),
      );
      expect(runtime.overrides, isEmpty);
      expect(runtime.store, isNull);
      expect(appSettingsSections.ordered.map((e) => e.$1), [SettingsSectionSlot.privacy]);
    });

    testWidgets('Home is the 1.1 Home and Settings has no Library storage', (tester) async {
      useSurface(tester, const TestSurface(Size(390, 844), 1.0));
      final app = await _pumpApp(tester);
      expect(find.byType(DanaviewHomeScreen), findsOneWidget);
      expect(find.byType(FilesHome), findsNothing);
      expect(_tabStrip, findsNothing);
      expect(find.text('Open file'), findsOneWidget);
      await app.go('/settings');
      expect(_privacySection, findsOneWidget);
      expect(_storageSection, findsNothing);
      await app.dispose();
    });
  });

  group('flag on: the runtime', () {
    testWidgets('opens the library under the support directory and installs the S2 providers', (tester) async {
      useSurface(tester, const TestSurface(Size(390, 844), 1.0));
      final roots = <String>[];
      final app = await _pumpApp(tester, filesHome: true, roots: roots);
      expect(roots, [libraryRootIn(Directory.systemTemp.path, LibraryRootStyle.appSupport)]);
      final c = app.container;
      expect(c.read(libraryStoreProvider), same(app.lib!.store));
      expect(c.read(importServiceProvider), isNotNull);
      expect(c.read(importPickerProvider), isA<NativeImportPicker>());
      expect(c.read(importStagingDirectoryProvider), endsWith('import_staging'));
      expect(c.read(importExtraCopiersProvider).single, isA<NativeImportCopier>());
      expect(c.read(sortPreferenceStoreProvider), isA<PrefsSortPreferenceStore>());
      expect(c.read(selectionActionGroupsProvider), [mediaSelectionGroup, fileSelectionGroup]);
      expect(c.read(photoViewerHooksProvider).share, isNotNull, reason: 'iOS has a share sheet');
      expect(c.read(fileOutPortProvider), isA<NativeFileOut>());
      expect(app.runtime.thumbnails, isNull, reason: 'a failed thumbnail cache leaves the Home usable');
      await app.dispose();
    });

    testWidgets('Android keeps the library under filesDir/library', (tester) async {
      useSurface(tester, const TestSurface(Size(390, 844), 1.0));
      final roots = <String>[];
      final app = await _pumpApp(tester, filesHome: true, roots: roots, platform: TargetPlatform.android);
      expect(roots.single, endsWith('${Platform.pathSeparator}library'));
      await app.dispose();
    });

    testWidgets('Windows and Linux get the file_selector picker and the save-dialog port, no share', (tester) async {
      useSurface(tester, const TestSurface(Size(1280, 800), 1.0));
      final app = await _pumpApp(tester, filesHome: true, platform: TargetPlatform.linux);
      final c = app.container;
      expect(c.read(importPickerProvider), isA<CallbackImportPicker>());
      expect(c.read(importExtraCopiersProvider), isEmpty);
      expect(c.read(fileOutPortProvider), isA<DesktopFileOut>());
      await app.dispose();
    });

    test('a library that fails to open leaves the store out', () async {
      FeatureFlags.debugFilesHomeOverride = true;
      final runtime = await filesHomeOverrides(
        prefs: (await LibraryTestEnv.create()).prefs,
        platform: TargetPlatform.iOS,
        directories: FilesHomeDirectories(support: Directory.systemTemp.path, cache: Directory.systemTemp.path),
        openStore: (_, __) async => throw const FileSystemException('locked'),
        openThumbnails: (_) async => throw const FileSystemException('none'),
        observeLifecycle: false,
      );
      expect(runtime.store, isNull);
      expect(runtime.overrides, isNotEmpty);
    });

    test('library entries become the media items the selection and file menu take', () {
      FileEntry entry(String name, FileKind kind, {String? sub}) => FileEntry(
            id: EntryId.parse('fe_0123456789abcdef'),
            folderId: FolderId.parse('fd_0123456789abcdef'),
            displayName: name,
            kind: kind,
            subKind: sub,
            sizeBytes: 3,
            addedAt: DateTime.utc(2026),
            modifiedAt: DateTime.utc(2026),
            sourceHint: SourceHint.files,
          );
      expect(mediaItemOfEntry(entry('a.jpg', FileKind.photo), '/l/a.jpg'), isA<PhotoMediaItem>().having((p) => p.mimeType, 'mime', 'image/jpeg'));
      expect(mediaItemOfEntry(entry('a.mp4', FileKind.video), '/l/a.mp4'), isA<VideoMediaItem>().having((v) => v.uri, 'uri', '/l/a.mp4'));
      expect(mediaItemOfEntry(entry('a.pdf', FileKind.document, sub: 'pdf'), '/l/a.pdf'),
          isA<DocumentItem>().having((d) => d.docKind, 'kind', DocumentKind.pdf));
      expect(mediaItemOfEntry(entry('a.zip', FileKind.other), '/l/a.zip'), isA<DocumentItem>());
    });
  });

  group('flag on: the Home in the app', () {
    testWidgets('tabs are Home, All, Videos, Photos, Playlists, Folders; Documents waits for S3', (tester) async {
      useSurface(tester, const TestSurface(Size(390, 844), 1.0, padding: EdgeInsets.only(top: 47, bottom: 34)));
      final app = await _pumpApp(tester, filesHome: true);
      expect(find.byType(FilesHome), findsOneWidget);
      expect(_tabStrip, findsOneWidget);
      for (final tab in [HomeTab.home, HomeTab.all, HomeTab.videos, HomeTab.photos, HomeTab.playlists, HomeTab.folders]) {
        expect(find.byKey(homeTabKey(tab)), findsOneWidget, reason: tab.name);
      }
      expect(find.byKey(homeTabKey(HomeTab.documents)), findsNothing);
      expect(find.byKey(homeTabKey(HomeTab.projects)), findsNothing, reason: 'the editor is not wired in tests');
      expect(s2DocumentsShown, isFalse);
      // The 1.1 sections stay on Home, with the Import and search row added.
      expect(find.text('Open file'), findsOneWidget);
      expect(find.byKey(const ValueKey('s2-import')), findsOneWidget);
      expect(find.byKey(const ValueKey('s2-search')), findsOneWidget);
      await app.dispose();
    });

    testWidgets('the library tabs read the store; a document opens its file menu', (tester) async {
      useSurface(tester, const TestSurface(Size(390, 1400), 1.0));
      final app = await _pumpApp(tester, filesHome: true, seed: (lib) => _seedMixed(lib, tester));
      await app.tab(HomeTab.all);
      expect(find.text('Beach.jpg'), findsOneWidget);
      expect(find.text('Holiday.mp4'), findsOneWidget);
      expect(find.text('Report.pdf'), findsOneWidget);
      await tester.tap(find.text('Report.pdf'));
      await pumpFrames(tester, count: 8);
      expect(find.byKey(const ValueKey('file-info')), findsOneWidget, reason: 'S2 has no document viewer: the file menu');
      await tester.tap(find.byKey(const ValueKey('file-info')));
      await pumpFrames(tester, count: 8);
      expect(tester.takeException(), isNull);
      await app.dispose();
    });

    testWidgets('the Folders tab shows the Danaview folders next to the linked ones', (tester) async {
      useSurface(tester, const TestSurface(Size(390, 1400), 1.0));
      final app = await _pumpApp(tester, filesHome: true, seed: (lib) => _seedMixed(lib, tester));
      await app.tab(HomeTab.folders);
      expect(find.text('Danaview folders'), findsWidgets);
      expect(find.textContaining('Recently deleted'), findsWidgets);
      await app.dispose();
    });

    testWidgets('a tab request (See all, a folder hit) re-opens the shell on that tab', (tester) async {
      useSurface(tester, const TestSurface(Size(390, 844), 1.0));
      final app = await _pumpApp(tester, filesHome: true, seed: (lib) => _seedMixed(lib, tester));
      const HomeTabRequestNotification(HomeTab.photos).dispatch(tester.element(find.text('Open file')));
      await pumpFrames(tester, count: 8);
      expect(tester.state<FilesHomeState>(find.byType(FilesHome)).initialTab, HomeTab.photos);
      expect(find.text('Open file').hitTestable(), findsNothing, reason: 'the Photos tab is showing');
      await app.dispose();
    });

    testWidgets('the import sheet opens from Home', (tester) async {
      useSurface(tester, const TestSurface(Size(390, 844), 1.0));
      final app = await _pumpApp(tester, filesHome: true);
      await tester.tap(find.byKey(const ValueKey('s2-import')));
      await pumpFrames(tester, count: 8);
      expect(find.byKey(const ValueKey('import-sheet')), findsOneWidget);
      await app.dispose();
    });

    testWidgets('Settings shows Library storage after Privacy', (tester) async {
      useSurface(tester, const TestSurface(Size(390, 2400), 1.0));
      final app = await _pumpApp(tester, filesHome: true, seed: (lib) => _seedMixed(lib, tester));
      expect(appSettingsSections.ordered.map((e) => e.$1), [SettingsSectionSlot.privacy, SettingsSectionSlot.libraryStorage]);
      await app.go('/settings');
      expect(_privacySection, findsOneWidget);
      expect(_storageSection, findsOneWidget);
      expect(tester.getTopLeft(_storageSection).dy, greaterThan(tester.getTopLeft(_privacySection).dy));
      expect(find.text(LibraryStorageSettingsSection.header), findsOneWidget);
      // flutter test runs as Android: the plain Auto Backup note (V2-V1).
      expect(find.text(LibraryStorageSettingsSection.androidNote), findsOneWidget);
      await app.dispose();
    });
  });

  group('flag on: no overflow', () {
    for (final width in [280.0, 375.0, 1280.0]) {
      for (final scale in [0.85, 1.35]) {
        testWidgets('Home, All, Folders and Settings at ${width.toInt()} px @${scale}x', (tester) async {
          useSurface(tester, TestSurface(Size(width, width > 1000 ? 800 : 640), scale));
          final app = await _pumpApp(tester, filesHome: true, textScale: scale, seed: (lib) => _seedMixed(lib, tester));
          expect(tester.takeException(), isNull);
          final import = find.byKey(const ValueKey('s2-import'));
          await tester.ensureVisible(import);
          await pumpFrames(tester);
          expect(tester.getSize(import).height, greaterThanOrEqualTo(44));
          expect(tester.takeException(), isNull);
          for (final tab in [HomeTab.all, HomeTab.folders, HomeTab.photos]) {
            await app.tab(tab);
          }
          await app.go('/settings');
          await tester.scrollUntilVisible(_storageSection, 200, scrollable: find.byType(Scrollable).first);
          await pumpFrames(tester);
          expect(tester.takeException(), isNull);
          await app.dispose();
        });
      }
    }
  });
}
