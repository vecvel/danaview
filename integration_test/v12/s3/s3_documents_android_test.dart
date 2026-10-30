// OWNER: S3-Q (Android half)
//
// Slice S3 E2E, Android variant (BUILD_PLAN v1.2 §1A, S3-Q; the S3 share of HOM-32 and of QA-101
// scenario 1), the counterpart of s3_documents_test.dart (iOS). With DANAVIEW_FILES_HOME=true, on
// the real app router and the real S2 + S3 wiring (`filesHomeOverrides` with `documentsOverrides`:
// the PdfRenderer viewer of HOM-25 and the NativeIncoming port of HOM-21A; and
// `installIncomingDocumentOpen` exactly as lib/main.dart does) on the Android Emulator:
//
//   1. the Home shows the Documents tab next to the S2 tabs;
//   2. a PDF (200 pages), a text file, a CSV, a Word file and a zip are imported "From Files";
//      library copies byte-equal, staged copies removed; the Documents tab lists the documents with
//      their sub-filters; the row menu reaches HOM-22's file menu and File info (FIX-S3Q-1);
//   3. the PDF opens in the real PdfRenderer viewer (first page timed), search finds a page token,
//      page thumbnails, "Open in another app" and the top bar's Share hand the file over;
//   4. Android has no Quick Look (ARCH §3, Android column): the text file opens in the in-app text
//      viewer, the CSV in the grid, the Word file and the zip on the file card (V2-121), whose Share
//      and Open in another app hand the library file over; Recents record every open;
//   5. Open with Danaview: a real ACTION_VIEW of a PDF (content:// URI) sent by the host with
//      `am start` to the flag-gated `.IncomingDocumentsAlias` (HOM-21A) is imported into Imported
//      (sourceHint openWith) and opened in the PDF viewer; the same file again opens the entry
//      already there (no second copy);
//   6. Share to Danaview (no App Group inbox on Android: ACTION_SEND instead): a real ACTION_SEND
//      of a PDF and one of a JPEG land in Imported (sourceHint shareExtension) with the "1 shared
//      item saved" toast; an ACTION_SEND of plain text becomes a .txt entry named from the subject.
//      `am` has no Uri-list extra, so ACTION_SEND_MULTIPLE is HOM-21A's instrumented
//      IncomingAppE2eTest and S3-R's DocumentsUI smoke;
//   7. the library is closed and reopened: documents, the shared items and Recents persist; the PDF
//      opens again;
//   8. every original is unchanged (bytes and timestamps), and no HttpClient is created.
//
// The intents are real: the host driver (integration_test/editor/tool/e2e_host.sh, `sendIntent`)
// runs `am start` as another app would; the content URIs are the app's own FileProvider
// (`<cacheDir>/danaview-out/`), which the app reads without a grant, so no third-party sender is
// needed. The Files picker and the system share sheet are replaced at the app's own seams, as in the
// iOS variant. The real DocumentsUI "Share" / "Open with" and the share chooser are S3-R's release
// smoke.
//
// Run: integration_test/v12/s3/tool/make_s3_docs.sh
//      DV_E2E_EXTRA_DEFINES="DANAVIEW_FILES_HOME=true" \
//      DANAVIEW_E2E_FRESH=1 \
//        scripts/ci/editor/e2e_android.sh --target integration_test/v12/s3/s3_documents_android_test.dart emulator-5554
//      (the script pushes build/e2e/s3_docs to Android/data/<app>/files/s3_docs and passes DV_S3_DOCS)

// ignore_for_file: avoid_print, implementation_imports, depend_on_referenced_packages

import 'dart:io';

import 'package:danaview/app.dart';
import 'package:danaview/main.dart' show editorAppOverrides;
import 'package:danaview/router/app_router.dart' show appNavigatorKey;
import 'package:danaview/wiring/documents_wiring.dart';
import 'package:danaview/wiring/files_home_wiring.dart';
import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_documents/danaview_documents.dart';
import 'package:danaview_editor/danaview_editor.dart';
import 'package:danaview_editor_engine/danaview_editor_engine.dart';
import 'package:danaview_engine/danaview_engine.dart';
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_features/src/flags.dart';
import 'package:danaview_features/src/library/file_actions/file_actions.dart';
import 'package:danaview_features/src/library/import/import_pickers.dart';
import 'package:danaview_features/src/library/import/import_providers.dart';
import 'package:danaview_features/src/library/import/incoming_intents.dart' show incomingIntentImportProvider;
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_platform/danaview_platform.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../editor/support/e2e.dart';

const String _docsDir = String.fromEnvironment('DV_S3_DOCS');

const String _pdf = 's3_report.pdf';
const String _txt = 's3_notes.txt';
const String _csv = 's3_table.csv';
const String _docx = 's3_brief.docx';
const String _zip = 's3_bundle.zip';
const String _openWith = 's3_openwith.pdf';
const String _sharedPdf = 's3_shared.pdf';
const String _sharedJpg = 's3_shared.jpg';
const List<String> _originals = [_pdf, _txt, _csv, _docx, _zip, _openWith, _sharedPdf, _sharedJpg];

/// The app's own FileProvider (danaview_library_native, HOM-22A): `<cacheDir>/danaview-out/`.
const String _providerBase = 'content://com.vecvel.danaview.danaview.library.files/danaview_out';
const String _alias = '.IncomingDocumentsAlias';

void _report(String line) => print('DV_E2E_REPORT s3a: $line');

/// Stages picks into the app's staging directory as the SAF picker's copy does.
final class _StagingPicker implements ImportPicker {
  _StagingPicker(this.staging);

  final String staging;
  final List<String> files = [];
  final List<String> staged = [];

  @override
  bool get canPickPhotos => true;

  @override
  Future<List<ImportSource>> pickPhotos() async => const [];

  @override
  Future<List<ImportSource>> pickFiles() async {
    final out = <ImportSource>[];
    for (final p in files) {
      final name = p.split('/').last;
      final dir = Directory('$staging/s3q-${DateTime.now().microsecondsSinceEpoch}')..createSync(recursive: true);
      final copy = File(p).copySync('${dir.path}/$name');
      staged.add(copy.path);
      out.add(ImportSource.file(copy.path,
          displayName: name, sizeBytes: copy.lengthSync(), modifiedAt: File(p).lastModifiedSync(), sourceHint: SourceHint.files, stagedCopy: true));
    }
    files.clear();
    return out;
  }
}

/// Records what the app hands to the share sheet, Save out and "Open in" (system UI).
final class _RecordingFileOut implements FileOutPort {
  _RecordingFileOut(this.real);

  final FileOutPort real;
  final List<OutFile> shared = [];
  final List<OutFile> openedIn = [];
  final List<(OutFile, SaveOutTarget)> saved = [];

  @override
  FileOutCapabilities get capabilities => real.capabilities;

  @override
  Future<SaveOutOutcome> saveOut(List<OutFile> files, SaveOutTarget target, {OutAnchor? anchor}) async {
    for (final f in files) {
      saved.add((f, target));
    }
    return SaveOutOutcome(cancelled: false, saved: files.length, failed: 0);
  }

  @override
  Future<ShareOutcome> share(List<OutFile> files, {String? subject, OutAnchor? anchor}) async {
    shared.addAll(files);
    return const ShareOutcome(completed: true);
  }

  @override
  Future<bool> openIn(OutFile file, {OutAnchor? anchor}) async {
    openedIn.add(file);
    return true;
  }
}

/// Records every HttpClient the app creates during the scenario (QA-103 scope: S3 adds no host).
final class _HttpSpy extends HttpOverrides {
  final List<String> created = [];

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    created.add(StackTrace.current.toString().split('\n').skip(1).take(4).join(' | '));
    return super.createHttpClient(context);
  }
}

final class _World {
  _World(this.prefs, this.player, this.editor, this.picker, this.out);

  final SharedPreferences prefs;
  final PlaybackEngine player;
  final List<Override> editor;
  final _StagingPicker picker;
  final _RecordingFileOut out;
  FilesHomeRuntime? runtime;

  LibraryStore get store => runtime!.store!;

  /// Opens the S2 + S3 wiring (as `lib/main.dart` does) and pumps the app at Home.
  Future<void> launch(WidgetTester tester) async {
    final r = runtime = await filesHomeOverrides(prefs: prefs);
    expect(r.store, isNotNull, reason: 'the library opened under filesDir');
    final dirs = await FilesHomeDirectories.resolve();
    installIncomingDocumentOpen(
      appNavigatorKey,
      openEntry: (context, read, entry) => openLibraryEntryWith(context, read, entry, onOpenPlayer: () {}),
    );
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: [
        playbackEngineProvider.overrideWithValue(player),
        sessionRepositoryProvider.overrideWithValue(SessionRepository(prefs)),
        libraryRepositoryProvider.overrideWithValue(LibraryRepository(prefs)),
        ...editor,
        ...r.overrides,
        // The app's seams for system UI (see the file header); everything else is the real wiring,
        // including PdfRenderer (PlatformPdfDocuments) and the NativeIncoming port.
        importPickerProvider.overrideWithValue(picker),
        importStagingDirectoryProvider.overrideWithValue(dirs.importStaging),
        fileOutPortProvider.overrideWithValue(out),
      ],
      child: const DanaviewApp(),
    ));
    await E2eApp.pumpUntil(tester, () => find.byType(DanaviewHomeScreen).evaluate().isNotEmpty, what: 'Home');
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    IncomingMediaBridge.interceptor = null;
    await runtime?.dispose();
    runtime = null;
  }
}

Future<_World> _boot() async {
  if (!FeatureFlags.filesHomeEnabled) throw StateError('Build with --dart-define=DANAVIEW_FILES_HOME=true');
  if (_docsDir.isEmpty) throw StateError('Pass --dart-define=DV_S3_DOCS=<dir> (integration_test/v12/s3/tool/make_s3_docs.sh)');
  if (!Platform.isAndroid) throw StateError('The Android variant; iOS runs s3_documents_test.dart');
  if (!E2eHandshake.available) throw StateError('Run through e2e_android.sh / e2e_host.sh (the host sends the intents)');
  IncomingMediaBridge.setLaunchArgs(const []);
  await PlatformBridge.initializeWindow();
  if (PlatformBridge.isMobile) await PlayerOrientation.applyAppDefault();
  final prefs = await SharedPreferences.getInstance();
  final player = MpvPlaybackEngine(subtitleFontAssets: DanaviewFonts.files);
  await player.initialize();
  var editor = EditorBootstrap.unavailable();
  if (EditorAvailability.platform is EditorSupported) {
    final roots = await EditorBootstrap.defaultRoots();
    final engine = MobileEditorEngine(config: EditorBootstrap.engineConfigOf(roots));
    final runtime = await EditorBootstrap.createRuntime(engine: engine, roots: roots, prefs: await EditorPrefs.load());
    editor = editorAppOverrides(runtime);
  }
  final dirs = await FilesHomeDirectories.resolve();
  return _World(prefs, player, editor, _StagingPicker(dirs.importStaging), _RecordingFileOut(NativeFileOut(FileOutPlatform.android)));
}

Finder _key(String k) => find.byKey(ValueKey<String>(k));

Finder _entryRow(EntryId id) => _key('library-entry-${id.value}');

Future<void> _tab(WidgetTester tester, HomeTab tab) async {
  await _closeHomeScreen(tester);
  await E2eApp.tap(tester, find.byKey(homeTabKey(tab)), what: '${tab.name} tab');
  await tester.pump(const Duration(milliseconds: 300));
}

/// Pops a Home screen (Folders, Playlists, Projects; DESIGN_SYSTEM §10.4) if one is on top.
Future<void> _closeHomeScreen(WidgetTester tester) async {
  final screen = find.byType(HomeDestinationScreen);
  if (screen.evaluate().isEmpty) return;
  await E2eApp.tap(tester, find.descendant(of: screen, matching: find.byTooltip('Back')).first, what: 'Back');
  await tester.pump(const Duration(milliseconds: 500));
}

/// The filter's "Show: All": every file in the All grid (the earlier All tab).
Future<void> _showAll(WidgetTester tester) async {
  await _closeHomeScreen(tester);
  await E2eApp.tap(tester, find.byKey(const ValueKey<String>('home-filter')), what: 'filter');
  await tester.pump(const Duration(milliseconds: 300));
  await E2eApp.tap(tester, find.text('All').hitTestable().last, what: 'Show: All');
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _dismissSheet(WidgetTester tester) async {
  tester.state<NavigatorState>(find.byType(Navigator).last).maybePop();
  await tester.pump(const Duration(milliseconds: 500));
}

bool _isNameOf(String display, String name) {
  if (display == name) return true;
  final dot = name.lastIndexOf('.');
  final stem = dot < 0 ? name : name.substring(0, dot);
  final ext = dot < 0 ? '' : name.substring(dot);
  return RegExp('^${RegExp.escape(stem)} \\(\\d+\\)${RegExp.escape(ext)}\$').hasMatch(display);
}

FileEntry? _newEntryNamed(LibraryStore store, String name, Set<EntryId> before) => store.reader
    .allEntries(includeTrashed: true)
    .where((e) => !before.contains(e.id) && _isNameOf(e.displayName, name))
    .firstOrNull;

Set<EntryId> _entryIds(LibraryStore store) => {for (final e in store.reader.allEntries(includeTrashed: true)) e.id};

final Finder _keepBoth = find.byWidgetPredicate(
    (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('import-keep-both-'));

/// Waits for the import of [name] to land as a new entry; answers "Keep both" on a used install.
Future<FileEntry> _awaitImport(WidgetTester tester, LibraryStore store, String name, Set<EntryId> before) async {
  for (var answered = 0;; answered++) {
    await E2eApp.pumpUntil(tester, () => _newEntryNamed(store, name, before) != null || _keepBoth.hitTestable().evaluate().isNotEmpty,
        what: 'the import of $name', timeout: const Duration(seconds: 60));
    final entry = _newEntryNamed(store, name, before);
    if (entry != null) return entry;
    if (answered >= 6) fail('the duplicate question came back after Keep both');
    await E2eApp.tap(tester, _keepBoth.hitTestable().first, what: 'Keep both');
    await tester.pump(const Duration(milliseconds: 300));
  }
}

/// Taps the round button with [tooltip] (kit icon buttons carry their label as tooltip).
Future<void> _tapTooltip(WidgetTester tester, String tooltip) =>
    E2eApp.tap(tester, find.byTooltip(tooltip).hitTestable().first, what: tooltip);

Future<void> _viewerBack(WidgetTester tester) async {
  await _tapTooltip(tester, 'Back');
  await E2eApp.pumpUntil(tester, () => find.byType(DocumentViewer).evaluate().isEmpty, what: 'the viewer to close');
}

/// Scrolls the visible tab's list until [target] is built and hit-testable. The list is looked up
/// again before every drag: the tab's list rebuilds while it scrolls on a used install (thumbnails
/// and counts arrive), and `scrollUntilVisible` then fails on the Scrollable it held ("No element",
/// the Mac's flaky `_reveal` step).
Future<void> _reveal(WidgetTester tester, Finder target, {required String what}) async {
  final lists = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).hitTestable();
  for (var i = 0; i < 160; i++) {
    if (target.hitTestable().evaluate().isNotEmpty) {
      await tester.pump(const Duration(milliseconds: 200));
      return;
    }
    if (lists.evaluate().isEmpty) {
      await tester.pump(const Duration(milliseconds: 200));
      continue;
    }
    // Down first; after 80 drags back up (the list may have been left scrolled).
    await tester.drag(lists.last, Offset(0, i < 80 ? -240 : 240), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 250));
  }
  fail('$what: not found in the list');
}

/// Opens [entry] from the Documents tab (or All for other files) and waits for the viewer host.
Future<void> _openRow(WidgetTester tester, FileEntry entry, {bool all = false}) async {
  if (all) {
    await _showAll(tester);
  } else {
    await _tab(tester, HomeTab.documents);
  }
  final row = _entryRow(entry.id);
  await _reveal(tester, row, what: 'the row of ${entry.displayName}');
  await E2eApp.tap(tester, row, what: 'row ${entry.displayName}');
  await E2eApp.pumpUntil(tester, () => find.byType(DocumentViewer).evaluate().isNotEmpty, what: 'the viewer host');
}

/// Copies [files] into a fresh `<cacheDir>/danaview-out/s3q-…/` batch and returns their content
/// URIs on the app's FileProvider (what another app's share would carry).
List<String> _provide(String cache, List<File> files) {
  final batch = 's3q-${DateTime.now().microsecondsSinceEpoch}';
  final dir = Directory('$cache/danaview-out/$batch')..createSync(recursive: true);
  final uris = <String>[];
  for (final f in files) {
    final name = f.uri.pathSegments.last;
    f.copySync('${dir.path}/$name');
    uris.add('$_providerBase/$batch/$name');
  }
  return uris;
}

/// Asks the host to send [intent] with `am start` (see the file header).
Future<void> _sendIntent(WidgetTester tester, String intent,
    {required String type, List<String> uris = const [], String? subject, String? text}) async {
  final ack = await E2eHandshake.request(tester, 'sendIntent', args: {
    'intent': intent,
    'type': type,
    'uris': uris.join('|'),
    if (subject != null) 'subject': subject,
    if (text != null) 'text': text,
    'component': _alias,
  });
  expect(ack.ok, isTrue, reason: 'the host sent $intent: ${ack.detail}');
  _report('host: ${ack.detail}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('S3 Android: import documents, view each in its viewer, Open with (VIEW), Share to (SEND), share out, reopen',
      (tester) async {
    final spy = _HttpSpy();
    HttpOverrides.global = spy;
    addTearDown(() => HttpOverrides.global = null);
    addTearDown(() => IncomingMediaBridge.interceptor = null);
    final world = await _boot();
    final originals = {for (final n in _originals) n: File('$_docsDir/$n')};
    for (final e in originals.entries) {
      expect(e.value.existsSync(), isTrue, reason: 'make_s3_docs.sh output ${e.key} in $_docsDir');
    }
    final bytes = {for (final e in originals.entries) e.key: e.value.readAsBytesSync()};
    final mtimes = {for (final e in originals.entries) e.key: e.value.lastModifiedSync()};

    // ---- 1. Home with the Documents tab ----
    await world.launch(tester);
    final store = world.store;
    for (final tab in HomeTab.values) {
      expect(find.byKey(homeTabKey(tab)), findsOneWidget, reason: '${tab.name} tab');
    }
    expect(IncomingMediaBridge.interceptor, isNotNull, reason: 'Open with Danaview is installed');
    final c0 = ProviderScope.containerOf(tester.element(find.byType(DanaviewApp)), listen: false);
    expect(c0.read(incomingIntentImportProvider), isNotNull, reason: 'HOM-21A: the incoming-intent importer runs on Android');
    _report('tabs ok, Documents shown; Open with interceptor and incoming-intent importer installed');
    await E2eApp.screenshot(tester, 's3a-01-home');

    // ---- 2. Import the documents From Files ----
    await E2eApp.tapKey(tester, 's2-import');
    await E2eApp.waitKey(tester, 'import-sheet');
    await E2eApp.tapKey(tester, 'import-target');
    await E2eApp.tapKey(tester, 'import-folder-imported');
    final before = _entryIds(store);
    world.picker.files.addAll([for (final n in [_pdf, _txt, _csv, _docx, _zip]) originals[n]!.path]);
    await E2eApp.tapKey(tester, 'import-from-files');
    final imported = <String, FileEntry>{};
    for (final n in [_pdf, _txt, _csv, _docx, _zip]) {
      imported[n] = await _awaitImport(tester, store, n, before);
    }
    final c = ProviderScope.containerOf(tester.element(find.byType(DanaviewApp)), listen: false);
    await E2eApp.pumpUntil(tester, () => c.read(importServiceProvider)!.items.every((i) => i.state.isFinal), what: 'imports to finish');
    await E2eApp.screenshot(tester, 's3a-02-import-sheet');
    await _dismissSheet(tester);
    final importedFolder = store.reader.systemFolder(FolderSystemRole.imported)!.id;
    for (final e in imported.entries) {
      final entry = e.value;
      expect(entry.folderId, importedFolder);
      expect(File(store.paths.entryFile(entry.id, entry.displayName)).readAsBytesSync(), bytes[e.key], reason: '${e.key} copy byte-equal');
    }
    for (final s in world.picker.staged) {
      expect(File(s).existsSync(), isFalse, reason: 'staged copy removed after import');
    }
    expect(imported[_pdf]!.kind, FileKind.document);
    _report('kinds: ${[for (final n in [_pdf, _txt, _csv, _docx, _zip]) imported[n]!.kind.name].join(', ')}');
    _report('imported ${imported.length} files into Imported; copies byte-equal; staged copies removed');

    await _tab(tester, HomeTab.documents);
    for (final n in [_pdf, _txt, _csv, _docx]) {
      await _reveal(tester, _entryRow(imported[n]!.id), what: 'Documents row $n');
    }
    await E2eApp.screenshot(tester, 's3a-03-documents-tab');
    await E2eApp.tapKey(tester, 'documents-sub-pdf');
    await tester.pump(const Duration(milliseconds: 300));
    await _reveal(tester, _entryRow(imported[_pdf]!.id), what: 'the PDF under the PDF sub-filter');
    expect(_entryRow(imported[_txt]!.id), findsNothing, reason: 'PDF sub-filter');
    await E2eApp.tapKey(tester, 'documents-sub-all');
    await tester.pump(const Duration(milliseconds: 300));
    await _reveal(tester, _entryRow(imported[_pdf]!.id), what: 'the PDF row');
    await E2eApp.tap(tester, find.descendant(of: _entryRow(imported[_pdf]!.id), matching: find.byTooltip('More')).hitTestable(),
        what: 'More of the PDF row');
    final rowMenu = ['Open', 'Rename…', 'Move to…', 'More actions…', 'Delete']
        .where((t) => find.text(t).hitTestable().evaluate().isNotEmpty)
        .toList();
    _report('Documents row menu: $rowMenu');
    expect(rowMenu, contains('More actions…'), reason: 'FIX-S3Q-1: the row menu reaches the file menu');
    await E2eApp.screenshot(tester, 's3a-04-document-row-menu');
    await E2eApp.tap(tester, find.text('More actions…').hitTestable().last, what: 'More actions…');
    await E2eApp.pumpUntil(tester, () => _key('file-share').evaluate().isNotEmpty, what: 'the file menu');
    final fileMenu = [
      for (final id in ['file-share', 'file-open-in', 'file-save-out', 'file-copy-to', 'file-move-to', 'file-rename', 'file-favourite', 'file-info', 'file-delete'])
        if (_key(id).evaluate().isNotEmpty) id,
    ];
    _report('Documents file menu: $fileMenu');
    for (final id in ['file-share', 'file-save-out', 'file-info']) {
      expect(fileMenu, contains(id), reason: 'FIX-S3Q-1: $id for a Danaview-folder document');
    }
    await E2eApp.screenshot(tester, 's3a-04b-document-file-menu');
    await tester.ensureVisible(_key('file-info'));
    await tester.pump(const Duration(milliseconds: 200));
    await E2eApp.tap(tester, _key('file-info').hitTestable(), what: 'File info');
    await E2eApp.pumpUntil(tester, () => _key('file-info-sheet').evaluate().isNotEmpty, what: 'the File info sheet');
    await E2eApp.screenshot(tester, 's3a-04c-document-file-info');
    await tester.tapAt(const Offset(4, 60));
    await tester.pump(const Duration(milliseconds: 600));
    await E2eApp.pumpUntil(tester, () => _key('file-info-sheet').evaluate().isEmpty, what: 'File info to close');

    // ---- 3. The PDF in PdfRenderer ----
    final sw = Stopwatch()..start();
    await _openRow(tester, imported[_pdf]!);
    await E2eApp.pumpUntil(tester, () => find.byType(PdfViewer).evaluate().isNotEmpty, what: 'the PDF viewer', timeout: const Duration(seconds: 20));
    await E2eApp.pumpUntil(tester, () => find.textContaining('of 200').evaluate().isNotEmpty || find.text('PDF · 200 pages').evaluate().isNotEmpty,
        what: 'the 200 pages', timeout: const Duration(seconds: 20));
    final infoMs = sw.elapsedMilliseconds;
    await E2eApp.pumpUntil(tester, () => find.textContaining('Page 1 of 200').evaluate().isNotEmpty, what: 'the first page shown',
        timeout: const Duration(seconds: 20));
    _report('PdfRenderer: 200 pages, "Page 1 of 200" ${sw.elapsedMilliseconds} ms after the tap (document info at $infoMs ms; '
        'emulator debug build, budget 500 ms is for the mid tier)');
    await tester.pump(const Duration(seconds: 1));
    await E2eApp.screenshot(tester, 's3a-05-pdf-viewer');
    await _tapTooltip(tester, 'Search in PDF');
    await E2eApp.pumpUntil(tester, () => find.byType(EditableText).hitTestable().evaluate().isNotEmpty, what: 'the search field');
    final searchSw = Stopwatch()..start();
    await tester.enterText(find.byType(EditableText).hitTestable().last, 'HOM27T-P0150');
    await E2eApp.pumpUntil(tester, () => find.textContaining('match').evaluate().isNotEmpty, what: 'search results',
        timeout: const Duration(seconds: 60));
    final summary = (tester.widget<Text>(find.textContaining('match').first)).data;
    expect(summary, isNot('No matches'), reason: 'the page token is found');
    _report('PDF search for a page token: "$summary" in ${searchSw.elapsedMilliseconds} ms');
    await E2eApp.hideKeyboard(tester);
    await E2eApp.screenshot(tester, 's3a-06-pdf-search');
    await _tapTooltip(tester, 'Search in PDF');
    await _tapTooltip(tester, 'Pages');
    await E2eApp.pumpUntil(tester, () => _key('pdf-pages-grid').evaluate().isNotEmpty, what: 'page thumbnails');
    await tester.pump(const Duration(seconds: 1));
    await E2eApp.screenshot(tester, 's3a-07-pdf-pages');
    await _tapTooltip(tester, 'Pages');
    await _tapTooltip(tester, 'View options');
    await E2eApp.tap(tester, find.text('Open in another app').hitTestable().last, what: 'Open in another app');
    await E2eApp.pumpUntil(tester, () => world.out.openedIn.isNotEmpty, what: 'the Open in hand-off');
    expect(world.out.openedIn.last.displayName, imported[_pdf]!.displayName);
    expect(File(world.out.openedIn.last.path).readAsBytesSync(), bytes[_pdf], reason: 'the other app gets the library file');
    _report('PDF: Open in another app handed over ${world.out.openedIn.last.mime}');
    await tester.pump(const Duration(milliseconds: 500));
    await E2eApp.tap(tester, _key('viewer-file-menu').hitTestable(), what: 'File actions of the viewer');
    await E2eApp.pumpUntil(tester, () => _key('file-share').evaluate().isNotEmpty, what: "the viewer's file menu");
    for (final id in ['file-share', 'file-save-out', 'file-info']) {
      expect(_key(id), findsOneWidget, reason: "FIX-S3Q-1: $id in the viewer's file menu");
    }
    await E2eApp.screenshot(tester, 's3a-07b-pdf-viewer-file-menu');
    final sharedBefore = world.out.shared.length;
    await E2eApp.tap(tester, _key('file-share').hitTestable(), what: 'Share from the viewer');
    await E2eApp.pumpUntil(tester, () => world.out.shared.length > sharedBefore, what: 'the share hand-off from the viewer');
    expect(File(world.out.shared.last.path).readAsBytesSync(), bytes[_pdf], reason: 'Share from the viewer hands over the library file');
    _report('PDF viewer: File actions → Share handed over the library file');
    await tester.pump(const Duration(milliseconds: 500));
    await _viewerBack(tester);

    // ---- 4. Text, CSV in the in-app viewers; Word and zip on the file card ----
    await _openRow(tester, imported[_txt]!);
    await E2eApp.pumpUntil(tester, () => _key('text-viewer-rows').evaluate().isNotEmpty, what: 'the in-app text viewer');
    expect(find.textContaining('S3Q-T0001'), findsWidgets, reason: 'UTF-8 lines shown');
    expect(find.textContaining('日本語'), findsWidgets, reason: 'non-Latin text decoded');
    await E2eApp.screenshot(tester, 's3a-08-text-viewer');
    await _viewerBack(tester);
    await _openRow(tester, imported[_csv]!);
    await E2eApp.pumpUntil(tester, () => _key('csv-viewer-rows').evaluate().isNotEmpty, what: 'the in-app CSV grid');
    expect(find.text('Person 001'), findsWidgets, reason: 'CSV cells shown');
    expect(find.text('Zürich'), findsWidgets);
    await E2eApp.screenshot(tester, 's3a-09-csv-viewer');
    await _viewerBack(tester);
    _report('text viewer (UTF-8, CJK) and CSV grid shown');

    await _openRow(tester, imported[_docx]!);
    await E2eApp.pumpUntil(tester, () => find.byType(FileCard).evaluate().isNotEmpty, what: 'the file card of the Word file');
    await E2eApp.screenshot(tester, 's3a-10-docx-file-card');
    await E2eApp.tap(tester, find.text('Open in another app').hitTestable().last, what: 'Open in another app (Word)');
    await E2eApp.pumpUntil(tester, () => world.out.openedIn.length >= 2, what: 'the Open in hand-off of the Word file');
    expect(File(world.out.openedIn.last.path).readAsBytesSync(), bytes[_docx]);
    _report('Word: file card (Android Office, V2-121); Open in another app handed over ${world.out.openedIn.last.mime}');
    await _viewerBack(tester);

    await _openRow(tester, imported[_zip]!, all: true);
    await E2eApp.pumpUntil(tester, () => find.byType(FileCard).evaluate().isNotEmpty, what: 'the file card');
    await E2eApp.screenshot(tester, 's3a-11-file-card');
    final sharedBeforeZip = world.out.shared.length;
    await E2eApp.tap(tester, find.text('Share').hitTestable().last, what: 'Share');
    await E2eApp.pumpUntil(tester, () => world.out.shared.length > sharedBeforeZip, what: 'the share hand-off');
    expect(File(world.out.shared.last.path).readAsBytesSync(), bytes[_zip]);
    await E2eApp.tap(tester, find.text('Open in another app').hitTestable().last, what: 'Open in another app');
    await E2eApp.pumpUntil(tester, () => world.out.openedIn.length >= 3, what: 'the Open in hand-off');
    _report('file card: Share and Open in another app handed over the library file');
    await _viewerBack(tester);

    final recents = store.reader.recents().map((e) => e.id).toSet();
    expect(recents, containsAll([for (final n in [_pdf, _txt, _csv, _docx, _zip]) imported[n]!.id]), reason: 'Recents record every open');
    _report('Recents: ${recents.length} entries, every opened document recorded');

    // ---- 5. Open with Danaview: a real ACTION_VIEW ----
    final dirs = await FilesHomeDirectories.resolve();
    // VIEW dedupes by content (an entry already there opens), so a used install that kept an
    // earlier run's copy can't show the import: run on a fresh install.
    expect(
        store.reader.allEntries(includeTrashed: true).where((e) => _isNameOf(e.displayName, _openWith)),
        isEmpty,
        reason: 'an earlier run left $_openWith in the library: run with DANAVIEW_E2E_FRESH=1');
    final beforeOpen = _entryIds(store);
    final viewUri = _provide(dirs.cache, [originals[_openWith]!]);
    await _sendIntent(tester, 'VIEW', type: 'application/pdf', uris: viewUri);
    await E2eApp.pumpUntil(tester, () => _newEntryNamed(store, _openWith, beforeOpen) != null, what: 'the Open with import',
        timeout: const Duration(seconds: 45));
    final opened = _newEntryNamed(store, _openWith, beforeOpen)!;
    await E2eApp.pumpUntil(tester, () => find.byType(PdfViewer).evaluate().isNotEmpty, what: 'the PDF viewer after Open with',
        timeout: const Duration(seconds: 30));
    expect(opened.folderId, importedFolder);
    expect(opened.sourceHint, SourceHint.openWith);
    expect(File(store.paths.entryFile(opened.id, opened.displayName)).readAsBytesSync(), bytes[_openWith]);
    await tester.pump(const Duration(seconds: 1));
    await E2eApp.screenshot(tester, 's3a-12-open-with');
    _report('Open with (ACTION_VIEW application/pdf → $_alias): imported into Imported (sourceHint openWith), opened in the PDF viewer');
    await _viewerBack(tester);
    final countBefore = store.reader.allEntries(includeTrashed: true).length;
    await _sendIntent(tester, 'VIEW', type: 'application/pdf', uris: _provide(dirs.cache, [originals[_openWith]!]));
    await E2eApp.pumpUntil(tester, () => find.byType(PdfViewer).evaluate().isNotEmpty, what: 'the viewer for the same file',
        timeout: const Duration(seconds: 30));
    await tester.pump(const Duration(seconds: 1));
    expect(store.reader.allEntries(includeTrashed: true).length, countBefore, reason: 'the same content opens the existing entry');
    _report('Open with the same file again: the existing entry opened, no second copy');
    await _viewerBack(tester);

    // ---- 6. Share to Danaview: real ACTION_SEND of a PDF, a JPEG and plain text ----
    final beforeShare = _entryIds(store);
    await _sendIntent(tester, 'SEND', type: 'application/pdf', uris: _provide(dirs.cache, [originals[_sharedPdf]!]));
    await E2eApp.pumpUntil(tester, () => _newEntryNamed(store, _sharedPdf, beforeShare) != null, what: 'the PDF share import',
        timeout: const Duration(seconds: 45));
    await E2eApp.pumpUntil(tester, () => find.textContaining('1 shared item saved').evaluate().isNotEmpty, what: 'the share toast');
    await E2eApp.screenshot(tester, 's3a-13-share-toast');
    await tester.pump(const Duration(seconds: 4));
    await _sendIntent(tester, 'SEND', type: 'image/jpeg', uris: _provide(dirs.cache, [originals[_sharedJpg]!]));
    await E2eApp.pumpUntil(tester, () => _newEntryNamed(store, _sharedJpg, beforeShare) != null, what: 'the JPEG share import',
        timeout: const Duration(seconds: 45));
    final sharedPdf = _newEntryNamed(store, _sharedPdf, beforeShare)!;
    final sharedJpg = _newEntryNamed(store, _sharedJpg, beforeShare)!;
    for (final e in [sharedPdf, sharedJpg]) {
      expect(e.folderId, importedFolder, reason: 'Android shares land in Imported (no folder picker)');
      expect(e.sourceHint, SourceHint.shareExtension);
    }
    expect(File(store.paths.entryFile(sharedPdf.id, sharedPdf.displayName)).readAsBytesSync(), bytes[_sharedPdf]);
    expect(File(store.paths.entryFile(sharedJpg.id, sharedJpg.displayName)).readAsBytesSync(), bytes[_sharedJpg]);
    expect(sharedJpg.kind, FileKind.photo);
    expect(_entryIds(store).difference(beforeShare).length, 2, reason: 'one entry per shared item');
    _report('Share (ACTION_SEND application/pdf, then image/jpeg): each into Imported (sourceHint shareExtension), toast shown');
    await tester.pump(const Duration(seconds: 4));

    const subject = 's3q_shared_note';
    const sharedText = 'S3Q-shared-text-from-another-app';
    final beforeText = _entryIds(store);
    await _sendIntent(tester, 'SEND', type: 'text/plain', subject: subject, text: sharedText);
    await E2eApp.pumpUntil(tester, () => _newEntryNamed(store, '$subject.txt', beforeText) != null, what: 'the text share import',
        timeout: const Duration(seconds: 45));
    final textEntry = _newEntryNamed(store, '$subject.txt', beforeText)!;
    expect(File(store.paths.entryFile(textEntry.id, textEntry.displayName)).readAsStringSync().trim(), sharedText);
    expect(textEntry.sourceHint, SourceHint.shareExtension);
    await E2eApp.pumpUntil(tester, () => find.textContaining('1 shared item saved').evaluate().isNotEmpty, what: 'the text share toast');
    _report('Share (ACTION_SEND text/plain): "${textEntry.displayName}" (${textEntry.kind.name}) with the shared text');

    // ---- 7. Reopen ----
    await world.close(tester);
    await world.launch(tester);
    final reopened = world.store;
    for (final e in [...imported.values, opened, sharedPdf, sharedJpg, textEntry]) {
      final again = reopened.reader.entry(e.id);
      expect(again, isNotNull, reason: '${e.displayName} persists');
      expect(File(reopened.paths.entryFile(e.id, again!.displayName)).existsSync(), isTrue);
    }
    expect(reopened.reader.recents().map((e) => e.id), containsAll([imported[_pdf]!.id, opened.id]), reason: 'Recents persist');
    await _openRow(tester, imported[_pdf]!);
    await E2eApp.pumpUntil(tester, () => find.textContaining('Page 1 of 200').evaluate().isNotEmpty, what: 'the PDF after reopening',
        timeout: const Duration(seconds: 20));
    await E2eApp.screenshot(tester, 's3a-14-after-reopen');
    await _viewerBack(tester);
    _report('reopen: every entry, the shared items and Recents persist; the PDF opens again');

    // ---- 8. Originals and network ----
    for (final n in _originals) {
      expect(originals[n]!.readAsBytesSync(), bytes[n], reason: '$n bytes unchanged');
      expect(originals[n]!.lastModifiedSync(), mtimes[n], reason: '$n timestamp unchanged');
    }
    _report('originals: bytes and timestamps unchanged (${_originals.length} files)');
    expect(spy.created, isEmpty, reason: 'S3 adds no host: ${spy.created}');
    _report('network: no HttpClient created');
    await world.close(tester);
  });
}
