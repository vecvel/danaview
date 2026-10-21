// OWNER: HOM-17
//
// Settings › Library storage (BUILD_PLAN HOM-17; ARCH v1.2 §5.2, V2-V1): library size and Recently
// deleted size from the store, updated after every write; the Apple backup note and the plain
// Android 25 MB Auto Backup note; no store (DANAVIEW_FILES_HOME off) shows zeros without errors; the
// layout matrix 280–1280 px × text scale 0.85–1.35 with 44 px rows and semantics labels.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_features/src/library/files/library_store_providers.dart';
import 'package:danaview_features/src/more/settings_sections/library_storage_section.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../library_test_utils.dart';

const _big = LibraryStorageUsage(liveBytes: 987654321098, liveCount: 123456, trashedBytes: 45678901234, trashedCount: 9876);

Widget _app(LibraryTestEnv env, {double textScale = 1.0, TargetPlatform platform = TargetPlatform.iOS, LibraryStorageUsage? usage, LibraryStore? store}) =>
    libraryTestApp(
      env,
      Scaffold(
        backgroundColor: DanaviewColors.background,
        body: ListView(padding: const EdgeInsets.all(16), children: const [LibraryStorageSettingsSection()]),
      ),
      textScale: textScale,
      platform: platform,
      overrides: [
        if (store != null) libraryStoreProvider.overrideWithValue(store),
        if (usage != null) libraryStorageUsageProvider.overrideWithValue(usage),
      ],
    );

void main() {
  testWidgets('without a store (flag off) it shows zeros and the Apple note', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    final env = await LibraryTestEnv.create();
    await tester.pumpWidget(_app(env));
    await pumpFrames(tester);
    expect(tester.takeException(), isNull);
    expect(find.text(LibraryStorageSettingsSection.header), findsOneWidget);
    expect(find.text('0 files'), findsOneWidget);
    expect(find.text(LibraryStorageSettingsSection.appleNote), findsOneWidget);
    expect(find.text(LibraryStorageSettingsSection.androidNote), findsNothing);
    await env.dispose();
  });

  testWidgets('on Android it says plainly that cloud Auto Backup stops at 25 MB', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    final env = await LibraryTestEnv.create();
    await tester.pumpWidget(_app(env, platform: TargetPlatform.android, usage: _big));
    await pumpFrames(tester);
    expect(find.text(LibraryStorageSettingsSection.androidNote), findsOneWidget);
    expect(LibraryStorageSettingsSection.androidNote, contains('25 MB'));
    expect(find.text(LibraryStorageSettingsSection.appleNote), findsNothing);
    await env.dispose();
  });

  testWidgets('sizes come from the store and update after a delete', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    final env = await LibraryTestEnv.create();
    final root = Directory.systemTemp.createTempSync('hom17_settings_');
    final store = (await tester.runAsync(() => LibraryStore.open(root: root.path, background: false)))!;
    Future<String> add(String name, int bytes) async => (await tester.runAsync(() => store.write((w, now) {
          final job = w.beginImport(now: now);
          (w.fs.openPart(job.id)..writeFromSync(List.filled(bytes, 7))).closeSync();
          return w.commitImport(job.id, ImportedFileInfo(displayName: name, kind: FileKind.photo), now: now).id.value;
        })))!;
    final first = await add('a.jpg', 2048);
    await add('b.jpg', 1024);
    await tester.pumpWidget(_app(env, store: store));
    await pumpFrames(tester);
    expect(find.text('2 files'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('^Danaview folders, ')), findsOneWidget);

    await tester.runAsync(() => store.write((w, now) => w.trashEntries([w.reader.allEntries().firstWhere((e) => e.id.value == first).id], now: now)));
    await pumpFrames(tester);
    expect(find.text('1 file'), findsOneWidget);
    expect(find.textContaining('1 file · Kept for 30 days'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await store.close();
      root.deleteSync(recursive: true);
    });
    await env.dispose();
  });

  group('layout matrix', () {
    for (final scale in [0.85, 1.0, 1.35]) {
      for (final size in const [Size(280, 653), Size(320, 568), Size(375, 667), Size(768, 1024), Size(874, 402), Size(1280, 800)]) {
        final surface = TestSurface(size, scale);
        testWidgets('fits at $surface', (tester) async {
          useSurface(tester, surface);
          final env = await LibraryTestEnv.create();
          for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
            await tester.pumpWidget(_app(env, textScale: scale, platform: platform, usage: _big));
            await pumpFrames(tester, count: 2);
            expect(tester.takeException(), isNull, reason: '$platform');
            for (final key in ['library-storage-folders', 'library-storage-trash']) {
              expect(tester.getSize(find.byKey(ValueKey(key))).height, greaterThanOrEqualTo(44), reason: key);
            }
            expect(find.bySemanticsLabel(RegExp('^Recently deleted, ')), findsOneWidget);
          }
          await env.dispose();
        });
      }
    }
  });
}
