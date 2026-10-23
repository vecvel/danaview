// OWNER: HOM-23
//
// BUILD_PLAN HOM-23 viewer host: the router's choice per platform is what the host shows (in-app
// text, CSV grid, file card, registered native viewers), probes and a viewer that fails after
// opening fall back down the chain to the file card, and "Recents updated on open" is checked on
// a real library store: opening a Danaview folder entry records it once in `recents()`; a linked
// file records nothing; a failing Recents write never blocks viewing.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:danaview_documents/danaview_documents.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../card/doc_harness.dart';

ViewerFile _file(String name, {ItemId? id, String? path}) {
  final c = classify(fileName: name);
  return ViewerFile(path: path ?? '/x/$name', displayName: name, kind: c.kind, docKind: c.docKind, id: id, sizeBytes: 3);
}

Future<TextDocument> _loader(String path) async => TextDocument.fromBytes(Uint8List.fromList(utf8.encode('alpha,beta\n1,2\n')));

Widget _native(String label) => Center(child: Text(label));

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump();
  }
}

void main() {
  final natives = <ViewerKind, ViewerBuilder>{
    ViewerKind.pdf: (_, v) => _native('PDF viewer'),
    ViewerKind.quickLook: (_, v) => _native('Quick Look'),
    ViewerKind.photo: (_, v) => _native('Photo viewer'),
    ViewerKind.player: (_, v) => _native('Player'),
  };

  for (final (platform, name, expected, finder) in [
    (ViewerPlatform.android, 'notes.txt', ViewerKind.text, 'alpha,beta'),
    (ViewerPlatform.windows, 'table.csv', ViewerKind.csv, 'alpha'),
    (ViewerPlatform.android, 'letter.docx', ViewerKind.fileCard, 'Open in another app'),
    (ViewerPlatform.linux, 'report.pdf', ViewerKind.fileCard, 'Open in another app'),
    (ViewerPlatform.iOS, 'report.pdf', ViewerKind.pdf, 'PDF viewer'),
    (ViewerPlatform.macOS, 'letter.docx', ViewerKind.quickLook, 'Quick Look'),
    (ViewerPlatform.android, 'report.pdf', ViewerKind.pdf, 'PDF viewer'),
    (ViewerPlatform.iOS, 'photo.heic', ViewerKind.photo, 'Photo viewer'),
    (ViewerPlatform.linux, 'clip.mkv', ViewerKind.player, 'Player'),
  ]) {
    testWidgets('${platform.name}: $name shows ${expected.name}', (tester) async {
      final shown = <ViewerKind>[];
      await tester.pumpWidget(docApp(DocumentViewer(
        file: _file(name),
        platform: platform,
        viewers: natives,
        fileOut: RecordingPort(platform == ViewerPlatform.linux ? FileOutPlatform.linux : FileOutPlatform.android),
        textLoader: _loader,
        onResolved: shown.add,
      )));
      await _settle(tester);
      expect(shown, [expected]);
      expect(find.text(finder), findsWidgets);
    });
  }

  testWidgets('a probe that refuses goes down the chain (password PDF on older Android → file card)', (tester) async {
    final shown = <ViewerKind>[];
    await tester.pumpWidget(docApp(DocumentViewer(
      file: _file('locked.pdf'),
      platform: ViewerPlatform.android,
      viewers: natives,
      probes: FunctionProbes({ViewerKind.pdf: (_) async => false}),
      onResolved: shown.add,
    )));
    await _settle(tester);
    expect(shown, [ViewerKind.fileCard]);
  });

  testWidgets('a native viewer that fails after opening falls back (Quick Look → text → card)', (tester) async {
    final shown = <ViewerKind>[];
    late ViewerContext ql;
    await tester.pumpWidget(docApp(DocumentViewer(
      file: _file('notes.txt'),
      platform: ViewerPlatform.iOS,
      viewers: {
        ViewerKind.quickLook: (_, v) {
          ql = v;
          return _native('Quick Look');
        },
      },
      textLoader: (_) => Future<TextDocument>.error(const TextLoadException()),
      onResolved: shown.add,
    )));
    await _settle(tester);
    expect(find.text('Quick Look'), findsOneWidget);
    ql.unavailable();
    await _settle(tester);
    // The in-app viewer can't read it either: the file card, with the reason.
    expect(shown, [ViewerKind.quickLook, ViewerKind.text, ViewerKind.fileCard]);
    expect(find.text('This file can\'t be shown here.'), findsOneWidget);
  });

  testWidgets('Recents: opening a Danaview folder entry records it once in the library', (tester) async {
    final dir = docTempDir();
    final store = (await tester.runAsync(() => LibraryStore.open(root: dir.path, background: false)))!;
    addTearDown(() async => tester.runAsync(store.close));
    final organiser = LibraryOrganiser(store);
    final entry = (await tester.runAsync(() => store.write((w, now) {
          final job = w.beginImport(now: now);
          (w.fs.openPart(job.id)..writeFromSync(utf8.encode('hello\nworld'))).closeSync();
          return w.commitImport(job.id, const ImportedFileInfo(displayName: 'notes.txt', kind: FileKind.document, subKind: 'text'),
              now: now);
        })))!;
    expect(organiser.recents(), isEmpty);

    final path = store.paths.entryFile(entry.id, entry.displayName);
    final before = File(path).readAsBytesSync();
    var marks = 0;
    await tester.pumpWidget(docApp(DocumentViewer(
      file: ViewerFile.fromEntry(entry, path),
      platform: ViewerPlatform.android,
      onOpened: (id) {
        marks++;
        return organiser.markOpened(id);
      },
    )));
    await _settle(tester); // resolve → the text viewer starts loading on a background isolate
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    await _settle(tester);
    expect(find.text('hello'), findsOneWidget);
    // A rebuild with the same file doesn't record again.
    await tester.pumpWidget(docApp(DocumentViewer(
        file: ViewerFile.fromEntry(entry, path),
        platform: ViewerPlatform.android,
        onOpened: (id) {
          marks++;
          return organiser.markOpened(id);
        })));
    await _settle(tester);
    expect(marks, 1);
    expect(organiser.recents().map((e) => e.id), [entry.id]);
    expect(organiser.recents().single.lastOpenedAt, isNotNull);
    // Viewing never changes the library file (read-only, rule 27).
    expect(File(path).readAsBytesSync(), before);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Recents: linked files are not recorded; a failing write never blocks viewing', (tester) async {
    final calls = <EntryId>[];
    await tester.pumpWidget(docApp(DocumentViewer(
      file: _file('report.docx', id: ItemId.parse('lk:root/report.docx')),
      platform: ViewerPlatform.android,
      onOpened: (id) async => calls.add(id),
    )));
    await _settle(tester);
    expect(calls, isEmpty);

    await tester.pumpWidget(docApp(DocumentViewer(
      key: const ValueKey('b'),
      file: _file('report.docx', id: EntryId.parse('fe_${'c' * 22}')),
      platform: ViewerPlatform.android,
      onOpened: (id) => Future<void>.error(StateError('trashed')),
    )));
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Open in another app'), findsNothing); // no port given
    expect(find.text('report.docx'), findsWidgets);
  });

  testWidgets('a new file re-routes and records again', (tester) async {
    final shown = <ViewerKind>[];
    final calls = <EntryId>[];
    Widget host(String name, String token) => docApp(DocumentViewer(
          file: _file(name, id: EntryId.parse('fe_${token * 22}')),
          platform: ViewerPlatform.android,
          textLoader: _loader,
          onOpened: (id) async => calls.add(id),
          onResolved: shown.add,
        ));
    await tester.pumpWidget(host('a.txt', 'd'));
    await _settle(tester);
    await tester.pumpWidget(host('b.docx', 'e'));
    await _settle(tester);
    expect(shown, [ViewerKind.text, ViewerKind.fileCard]);
    expect(calls.length, 2);
  });
}
