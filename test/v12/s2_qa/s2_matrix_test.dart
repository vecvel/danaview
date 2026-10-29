// OWNER: S2-Q
//
// Slice S2 QA (BUILD_PLAN v1.2 §1A, S2-Q; the S2 share of QA-105 and QA-103): the overflow and
// accessibility matrix of the S2 surfaces as the app composes them (DanaviewApp, the app router,
// the S2 wiring over an in-process HOM-17 library), and the network guard of the S2 flows.
//
// Matrix (ARCH v1.2 §1.4): widths 280, 375, 768, 1280 px × text scale 0.85, 1.35 with no
// exception (overflow) on every surface: Overview with Import, search, Recent photos, Favourites
// and Recents; All with a row menu; Videos; Photos and its selection bar; Folders root, a nested
// folder and Recently deleted; the import sheet and its folder chooser; a document's file menu and
// File info; the photo viewer and its info sheet. At 375 px × 1.0 and 1280 px × 1.35 every surface
// also meets the iOS 44 pt tap target, labelled tap target and text contrast guidelines.
//
// Network guard: an HttpOverrides spy fails any HttpClient the S2 flows create (QA-103 scope: S2
// adds no host).

// The root package reaches the library through danaview_features in its fixtures.
// ignore_for_file: depend_on_referenced_packages, implementation_imports

import 'dart:io';

import 'package:danaview/app.dart';
import 'package:danaview/wiring/files_home_wiring.dart';
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_features/src/flags.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart' show EventChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../library_test_utils.dart';
import '../filters/filters_support.dart';

const String _longPhoto = 'A very long holiday photo name from the summer trip to the coast in 2026.jpg';
const String _longVideo = 'Interview with the whole family recorded on a long winter evening.mp4';
const String _longDoc = 'Quarterly report with a name that is far too long for any phone.pdf';
const String _longFolder = 'A folder name that is far too long to fit on any phone screen';

/// Fails the test when anything creates an HttpClient.
final class _NoNetwork extends HttpOverrides {
  final List<String> attempts = [];

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts.add(StackTrace.current.toString().split('\n').take(6).join(' | '));
    throw StateError('S2 QA: no network expected');
  }
}

final class _Seeded {
  _Seeded(this.photo, this.video, this.doc, this.trips, this.nested);

  final FileEntry photo;
  final FileEntry video;
  final FileEntry doc;
  final FolderId trips;
  final FolderId nested;
}

final class _App {
  _App(this.tester, this.env, this.container, this.runtime, this.lib, this.seeded);

  final WidgetTester tester;
  final LibraryTestEnv env;
  final ProviderContainer container;
  final FilesHomeRuntime runtime;
  final FixtureLibrary lib;
  final _Seeded seeded;

  GoRouter get router => GoRouter.of(tester.element(find.byType(Navigator).first));

  Future<void> tab(HomeTab tab) async {
    await tester.ensureVisible(find.byKey(homeTabKey(tab)));
    await tester.pump();
    await tester.tap(find.byKey(homeTabKey(tab)));
    await pumpFrames(tester, count: 8);
  }

  Future<void> tapKey(String key) async {
    final f = find.byKey(ValueKey<String>(key)).hitTestable();
    await tester.ensureVisible(f.first);
    await tester.pump();
    await tester.tap(f.first);
    await pumpFrames(tester, count: 8);
  }

  Future<void> back() async {
    Navigator.of(tester.element(find.byType(Navigator).last)).maybePop();
    await pumpFrames(tester, count: 8);
  }

  Future<void> dispose() async {
    DanaviewToast.dismiss();
    await tester.pumpWidget(const SizedBox());
    await pumpFrames(tester, count: 6);
    container.dispose();
    await lib.close(tester);
    await env.dispose();
  }
}

Future<_App> _pumpApp(WidgetTester tester, double textScale) async {
  FeatureFlags.debugFilesHomeOverride = true;
  addTearDown(FeatureFlags.debugReset);
  final env = await LibraryTestEnv.create();
  final lib = await FixtureLibrary.open(tester);
  final trips = await lib.folder(tester, 'Trips');
  final nested = await lib.folder(tester, _longFolder, parent: trips);
  final photo = await lib.add(tester, _longPhoto, folder: nested, meta: const EntryMeta(width: 4032, height: 3024));
  lib.now = lib.now.add(const Duration(minutes: 1));
  final video = await lib.add(tester, _longVideo, folder: trips);
  lib.now = lib.now.add(const Duration(minutes: 1));
  final doc = await lib.add(tester, _longDoc, meta: const EntryMeta(pageCount: 12));
  final gone = await lib.add(tester, 'Deleted beach photo with a long name.jpg');
  await lib.run(tester, (s) => s.write((w, now) => w.trashEntries([gone.id], now: now)));
  await lib.run(tester, (s) => s.write((w, now) => w.setEntryFavourite(photo.id, true)));
  await lib.run(tester, (s) => s.write((w, now) => w.markOpened(doc.id, now: now)));
  final runtime = (await tester.runAsync(() => filesHomeOverrides(
        prefs: env.prefs,
        platform: TargetPlatform.iOS,
        directories: FilesHomeDirectories(support: Directory.systemTemp.path, cache: Directory.systemTemp.path),
        openStore: (_, __) async => lib.store,
        openThumbnails: (_) async => throw const FileSystemException('no thumbnails in tests'),
        observeLifecycle: false,
      )))!;
  final container = ProviderContainer(overrides: [...env.overrides, ...runtime.overrides]);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const DanaviewApp()));
  await pumpFrames(tester);
  return _App(tester, env, container, runtime, lib, _Seeded(photo, video, doc, trips, nested));
}

/// Visits every S2 surface; [check] runs on each.
Future<void> _visit(_App app, Future<void> Function(String where) check) async {
  final tester = app.tester;
  final s = app.seeded;
  await check('Overview (Import, search, Recent photos, Favourites, Recents)');

  await app.tapKey('home-import');
  await check('Import menu');
  await tester.tap(find.text(HomeChromeLabels.importToLibrary));
  await pumpFrames(tester, count: 8);
  await check('import sheet');
  await app.tapKey('import-target');
  await check('import folder chooser');
  await app.back();
  await app.back();

  await app.tab(HomeTab.all);
  await check('All');
  final row = find.byKey(ValueKey('library-entry-${s.doc.id.value}'));
  await tester.ensureVisible(row);
  await tester.pump();
  await tester.tap(find.descendant(of: row, matching: find.byTooltip('More')));
  await pumpFrames(tester);
  await check('All row menu');
  // Since S3 a document row's tap opens its viewer; the file menu is the row menu's
  // "More actions…" (FIX-S3Q-1), so the matrix reaches File info through it (FIX-S3Q-3).
  await tester.tap(find.text('More actions…').hitTestable().first);
  await pumpFrames(tester, count: 8);
  await check('document file menu');
  await app.tapKey('file-info');
  await check('File info');
  await app.back();

  await app.tab(HomeTab.videos);
  await check('Videos');

  await app.tab(HomeTab.photos);
  await check('Photos');
  final cell = find.byKey(ValueKey<String>(s.photo.id.value)).hitTestable();
  await tester.longPress(cell.first);
  await pumpFrames(tester, count: 8);
  expect(find.byKey(const ValueKey('home-selection-bar')), findsOneWidget);
  await check('Photos selection bar');
  await app.tapKey('selection-clear');
  await tester.tap(cell.first);
  await pumpFrames(tester, count: 10);
  expect(find.byKey(const ValueKey('photo-viewer-pages')), findsOneWidget);
  await check('photo viewer');
  await app.tapKey('photo-viewer-info');
  await pumpFrames(tester, count: 10);
  await check('photo info sheet');
  await app.back();
  await app.tapKey('photo-viewer-close');

  await app.tab(HomeTab.folders);
  await check('Folders root');
  await app.tapKey('danaview-folder-${s.trips.value}');
  await app.tapKey('danaview-folder-${s.nested.value}');
  await check('nested folder with breadcrumbs');
  await app.tapKey('folders-up');
  await app.tapKey('folders-up');
  await app.tapKey('recently-deleted-row');
  await check('Recently deleted');
}

void main() {
  // HOM-21A starts listening to the native library events at boot (Android incoming intents);
  // a widget test has no native side, so give the channel a silent stream instead of a
  // MissingPluginException.
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('dev.flutter.pigeon.danaview_library_native.LibraryEventsApi.libraryEvents'),
      MockStreamHandler.inline(onListen: (arguments, events) {}),
    );
  });
  tearDown(FeatureFlags.debugReset);

  group('S2 surfaces: no overflow', () {
    for (final width in [280.0, 375.0, 768.0, 1280.0]) {
      for (final scale in [0.85, 1.35]) {
        testWidgets('${width.toInt()} px @${scale}x', (tester) async {
          useSurface(tester, TestSurface(Size(width, width > 1000 ? 800 : (width > 700 ? 1024 : 640)), scale));
          final spy = _NoNetwork();
          await HttpOverrides.runWithHttpOverrides(() async {
            final app = await _pumpApp(tester, scale);
            await _visit(app, (where) async => expect(tester.takeException(), isNull, reason: where));
            await app.dispose();
          }, spy);
          expect(spy.attempts, isEmpty, reason: 'no HttpClient in the S2 flows');
        });
      }
    }
  });

  group('S2 surfaces: targets, labels and contrast', () {
    for (final (width, scale) in [(375.0, 1.0), (1280.0, 1.35)]) {
      testWidgets('${width.toInt()} px @${scale}x', (tester) async {
        useSurface(tester, TestSurface(Size(width, width > 1000 ? 800 : 812), scale));
        final app = await _pumpApp(tester, scale);
        await _visit(app, (where) async {
          expect(tester.takeException(), isNull, reason: where);
          await expectLater(tester, meetsGuideline(iOSTapTargetGuideline), reason: where);
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline), reason: where);
          await expectLater(tester, meetsGuideline(textContrastGuideline), reason: where);
        });
        await app.dispose();
      });
    }
  });
}
