// OWNER: HOM-21
//
// D-S3W-2: the player offers HOM-21's "Save to Danaview folder" in its actions menu (the Playback
// sheet behind "More options") while a local file plays and the library is open
// (DANAVIEW_FILES_HOME); the sheet is reachable at every width then. Tapping the row closes the
// sheet, imports the playing file once with sourceHint player and shows the toast; the row is at
// least a 44 pt target. Without a library (flag off) there is no row and the wide control bar keeps
// its 1.1 layout (no More button); a stream offers nothing.
//
// The root package reaches danaview_library through danaview_features.
// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_engine/danaview_engine.dart';
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_features/src/library/files/library_store_providers.dart';
import 'package:danaview_features/src/library/import/import_providers.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _saveRow = ValueKey('player-sheet-save-to-danaview');
const _phone = Size(402, 874);
const _wide = Size(1280, 800);

final class _Lib {
  _Lib(this.root, this.src, this.store, this.service);

  final Directory root;
  final Directory src;
  final LibraryStore store;
  final ImportService service;

  static Future<_Lib> open() async {
    final root = Directory.systemTemp.createTempSync('d_s3w_2_lib_');
    final src = Directory.systemTemp.createTempSync('d_s3w_2_src_');
    final store = await LibraryStore.open(root: root.path, background: false);
    return _Lib(root, src, store, ImportService(store: store));
  }

  Future<void> close() async {
    await service.dispose();
    await store.close();
    root.deleteSync(recursive: true);
    src.deleteSync(recursive: true);
  }
}

/// Pumps the player screen playing [media], with the library of [lib] when set (flag on).
Future<FakePlaybackEngine> _pump(WidgetTester tester, {required Size size, required MediaRef media, _Lib? lib}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final engine = FakePlaybackEngine();
  await engine.initialize();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  const padding = EdgeInsets.only(top: 20);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      playbackEngineProvider.overrideWithValue(engine),
      sessionRepositoryProvider.overrideWithValue(SessionRepository(prefs)),
      libraryRepositoryProvider.overrideWithValue(LibraryRepository(prefs)),
      if (lib != null) ...[
        libraryStoreProvider.overrideWithValue(lib.store),
        importServiceProvider.overrideWithValue(lib.service),
      ],
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: DanaviewTheme.darkTheme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(padding: padding, viewPadding: padding),
        child: child!,
      ),
      home: DanaviewPlayerScreen(onBack: () {}),
    ),
  ));
  final container = ProviderScope.containerOf(tester.element(find.byType(DanaviewPlayerScreen)));
  // No desktop title bar on the macOS test host.
  container.read(playerControllerProvider.notifier).toggleFullscreen().ignore();
  await tester.runAsync(() => container.read(queueControllerProvider.notifier).playFrom([media]));
  await _settle(tester);
  return engine;
}

Future<void> _settle(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(tester.takeException(), isNull);
}

Future<void> _openMore(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.more_horiz_rounded));
  await _settle(tester);
}

Future<void> _finish(WidgetTester tester, FakePlaybackEngine engine, [_Lib? lib]) async {
  DanaviewToast.dismiss();
  await tester.pumpWidget(const SizedBox());
  await engine.dispose();
  if (lib != null) await tester.runAsync(lib.close);
}

void main() {
  group('flag on: Save to Danaview folder in the player menu', () {
    for (final (name, size) in [('phone', _phone), ('wide window', _wide)]) {
      testWidgets('$name: the Playback sheet offers it; a tap closes the sheet and saves the playing file once', (tester) async {
        final lib = (await tester.runAsync(_Lib.open))!;
        final video = File('${lib.src.path}/Holiday.mov')..writeAsBytesSync(List<int>.generate(6000, (i) => (i * 7 + 3) % 251));
        final engine = await _pump(tester, size: size, media: LibraryRepository.mediaRefForFile(video.path), lib: lib);

        expect(find.byIcon(Icons.more_horiz_rounded), findsOneWidget, reason: 'the menu is reachable at every width');
        await _openMore(tester);
        final row = find.byKey(_saveRow);
        await tester.ensureVisible(row);
        await _settle(tester, frames: 2);
        expect(find.descendant(of: row, matching: find.text('Save to Danaview folder')), findsOneWidget);
        expect(tester.getSize(row).height, greaterThanOrEqualTo(DanaviewSpacing.minTapTarget));

        await tester.tap(row);
        // The copy runs on a worker isolate: let real time and frames pass in turn.
        for (var i = 0; i < 200 && lib.store.reader.allEntries().isEmpty; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump(const Duration(milliseconds: 10));
        }
        await _settle(tester);
        expect(find.byKey(_saveRow), findsNothing, reason: 'the sheet closed');
        final entry = lib.store.reader.allEntries().single;
        expect(entry.sourceHint, SourceHint.player);
        expect(entry.displayName, 'Holiday.mov');
        expect(find.text('Saved to Danaview folders'), findsOneWidget);
        expect(video.existsSync(), isTrue, reason: "the user's file is only read");

        await _finish(tester, engine, lib);
      });
    }

    testWidgets('a stream offers nothing', (tester) async {
      final lib = (await tester.runAsync(_Lib.open))!;
      final engine = await _pump(tester, size: _phone, media: MediaUrl.tryParse('https://example.com/live.m3u8')!, lib: lib);
      await _openMore(tester);
      expect(find.byKey(_saveRow), findsNothing);
      await _finish(tester, engine, lib);
    });
  });

  group('flag off', () {
    testWidgets('no row in the Playback sheet, and the wide bar keeps its 1.1 layout', (tester) async {
      final dir = Directory.systemTemp.createTempSync('d_s3w_2_off_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final video = File('${dir.path}/Trip.mov')..writeAsBytesSync(List<int>.filled(4000, 5));
      final media = LibraryRepository.mediaRefForFile(video.path);

      var engine = await _pump(tester, size: _phone, media: media);
      await _openMore(tester);
      expect(find.text('Queue'), findsOneWidget, reason: 'the sheet is open');
      expect(find.byKey(_saveRow), findsNothing);
      await _finish(tester, engine);

      engine = await _pump(tester, size: _wide, media: media);
      expect(find.byIcon(Icons.more_horiz_rounded), findsNothing);
      await _finish(tester, engine);
    });
  });
}
