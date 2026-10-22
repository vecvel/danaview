// OWNER: HOM-18
//
// Shared fixtures of the HOM-18 tests (test/v12/filters/, test/v12/folders_tab/): an in-process
// HOM-17 library store in a temp dir with a settable fake clock, files added through the real
// import commit path and classified by the real HOM-16 classifier, and the app harness.

// The root package reaches danaview_library through danaview_features.
// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:danaview_features/src/library/files/library_store_providers.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../library_test_utils.dart';

/// The fixture library's file names: every kind and every Documents sub-filter.
const List<String> fixtureFileNames = [
  'Holiday.mp4',
  'Interview.mov',
  'Beach.jpg',
  'Portrait.heic',
  'Report.pdf',
  'Letter.docx',
  'Budget.xlsx',
  'Pitch.pptx',
  'Notes.txt',
  'Data.csv',
  'Archive.zip',
  'Song.mp3',
];

/// A library store in a temp dir whose clock the test sets.
class FixtureLibrary {
  FixtureLibrary._(this.root, this.store, this._clock);

  /// The temp dir.
  final Directory root;

  /// The store.
  final LibraryStore store;

  final _Clock _clock;

  /// The store clock's time.
  DateTime get now => _clock.now;
  set now(DateTime value) => _clock.now = value;

  /// Opens an empty library at [start].
  static Future<FixtureLibrary> open(WidgetTester tester, {DateTime? start}) async {
    final root = Directory.systemTemp.createTempSync('hom18_');
    final clock = _Clock(start ?? DateTime.utc(2026, 10, 1, 12));
    final store = (await tester.runAsync(() => LibraryStore.open(root: root.path, background: false, clock: () => clock.now)))!;
    return FixtureLibrary._(root, store, clock);
  }

  /// Runs [op] on the store outside the fake zone.
  Future<T> run<T>(WidgetTester tester, Future<T> Function(LibraryStore s) op) async => (await tester.runAsync(() => op(store))) as T;

  /// Creates a folder.
  Future<FolderId> folder(WidgetTester tester, String name, {FolderId? parent}) =>
      run(tester, (s) => s.write((w, now) => w.createFolder(name, parent: parent, now: now)));

  /// Adds [name] (classified by HOM-16) to [folder] (default `Imported`), [minutesAgo] before now.
  Future<FileEntry> add(WidgetTester tester, String name, {FolderId? folder, EntryMeta? meta, int bytes = 3}) {
    final cls = classify(fileName: name);
    return run(tester, (s) => s.write((w, now) {
          final job = w.beginImport(target: folder, now: now);
          (w.fs.openPart(job.id)..writeFromSync(List.filled(bytes, 7))).closeSync();
          return w.commitImport(
            job.id,
            ImportedFileInfo(displayName: name, kind: cls.kind, subKind: cls.subKind, meta: meta),
            now: now,
          );
        }));
  }

  /// Adds every [fixtureFileNames] file a minute apart, plus one entry whose stored kind is a
  /// later version's (`savedCode`), and returns them by name.
  Future<Map<String, FileEntry>> seedFixture(WidgetTester tester, {FolderId? folder}) async {
    final out = <String, FileEntry>{};
    for (final name in fixtureFileNames) {
      out[name] = await add(tester, name, folder: folder, meta: name.endsWith('.pdf') ? const EntryMeta(pageCount: 12) : null);
      now = now.add(const Duration(minutes: 1));
    }
    final code = await add(tester, 'Wifi code.dvcode', folder: folder);
    await run(tester, (s) => s.write((w, _) => w.db.execute("UPDATE entries SET kind = 'savedCode' WHERE id = ?", [code.id.value])));
    out['Wifi code.dvcode'] = store.reader.entry(code.id)!;
    return out;
  }

  /// Unmounts and deletes the library.
  Future<void> close(WidgetTester tester) async {
    DanaviewToast.dismiss();
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await store.close();
      root.deleteSync(recursive: true);
    });
  }
}

class _Clock {
  _Clock(this.now);
  DateTime now;
}

/// The app around [body] with [lib]'s store (none when null).
Widget filtersApp(LibraryTestEnv env, Widget body, {FixtureLibrary? lib, double textScale = 1.0, List<Override> overrides = const []}) =>
    libraryTestApp(
      env,
      ColoredBox(color: DanaviewColors.background, child: SafeArea(child: body)),
      textScale: textScale,
      overrides: [
        if (lib != null) libraryStoreProvider.overrideWithValue(lib.store),
        ...overrides,
      ],
    );

/// Widths × text scales of ARCH §1.4.
final List<(double, double)> filtersMatrix = [
  for (final w in [280.0, 375.0, 768.0, 1280.0])
    for (final s in [0.85, 1.0, 1.35]) (w, s),
];
