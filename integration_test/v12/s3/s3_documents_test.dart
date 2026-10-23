// OWNER: S3-Q
//
// Slice S3 E2E (BUILD_PLAN v1.2 §1A, S3-Q; the S3 share of HOM-32 and of QA-101 scenario 1): with
// DANAVIEW_FILES_HOME=true, on the real app router and the real S2 + S3 wiring
// (`filesHomeOverrides` with `documentsOverrides`, and `installIncomingDocumentOpen` exactly as
// lib/main.dart does) on the iOS Simulator:
//
//   1. the Home shows the Documents tab next to the S2 tabs;
//   2. a PDF (200 pages), a text file, a CSV, a Word file and a zip are imported "From Files";
//      library copies byte-equal, staged copies removed; the Documents tab lists the documents with
//      their sub-filters (the zip is an "other" file: All tab);
//   3. the PDF opens in the real PDFKit viewer (first page timed), search finds a page token,
//      "Open in another app" hands the file over;
//   4. the text file, the CSV and the Word file go to Quick Look first (ARCH §3, Apple column; the
//      real `canPreview` decides); with Quick Look failing the text and CSV fall back to the in-app
//      viewers (rows shown); the zip gets the file card, whose Share and Open in another app hand
//      the library file over; Recents record every open;
//   5. Open with Danaview: a PDF that iOS copied into Documents/Inbox arrives on the app's
//      `danaview/media_intent` channel as from the AppDelegate; it is imported into Imported
//      (sourceHint openWith), opened in the PDF viewer and the system copy removed; the same file
//      from outside the app opens the entry already there (no second copy, source unchanged);
//   6. the Share Extension inbox: a batch laid out as ios/DanaviewShare/InboxWriter.swift writes it
//      (a PDF and a JPEG, target folder picked in the extension) is placed in the real App Group
//      container next to an incomplete batch; on the next foreground the importer moves the complete
//      batch into the folder (sourceHint shareExtension), shows the toast, deletes the batch and
//      leaves the incomplete one; the folder snapshot the extension's picker reads lists the folder;
//   7. the library is closed and reopened: documents, the shared items and Recents persist; the PDF
//      opens again;
//   8. every original is unchanged (bytes and timestamps), and no HttpClient is created.
//
// Findings that are product gaps rather than scenario failures (no Share or Save to Files for a
// document) are reported as `DV_E2E_REPORT s3: FINDING` lines, not failed.
//
// Local test documents only: integration_test/v12/s3/tool/make_s3_docs.sh writes them on the host
// and the simulator reads them in place (`--dart-define=DV_S3_DOCS=<dir>`). System UI an integration
// test can't drive is replaced at the app's own seams, as in the S2 scenario: the Files picker stages
// copies into the app's staging directory, the file-out port records what the app hands to the
// share sheet and "Open in", and the Quick Look port records `present` (its `canPreview` is the real
// native probe). With `--dart-define=DV_S3_REAL_QL=true` the Word file is shown in the real
// QLPreviewController, and the scenario waits up to 3 minutes for a person (or a simulator tool) to
// tap Done. The real Share Extension UI and Files' "Open in Danaview" are the manual simulator checks
// of S3-QA.md.
//
// Run: integration_test/v12/s3/tool/make_s3_docs.sh
//      DV_E2E_EXTRA_DEFINES="DANAVIEW_FILES_HOME=true DV_S3_DOCS=$PWD/build/e2e/s3_docs" \
//        scripts/ci/editor/e2e_ios.sh --target integration_test/v12/s3/s3_documents_test.dart iphone

// ignore_for_file: avoid_print, implementation_imports, depend_on_referenced_packages

import 'dart:convert';
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
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_platform/danaview_platform.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../editor/support/e2e.dart';

const String _docsDir = String.fromEnvironment('DV_S3_DOCS');
const bool _realQuickLook = bool.fromEnvironment('DV_S3_REAL_QL');

const String _pdf = 's3_report.pdf';
const String _txt = 's3_notes.txt';
const String _csv = 's3_table.csv';
const String _docx = 's3_brief.docx';
const String _zip = 's3_bundle.zip';
const String _openWith = 's3_openwith.pdf';
const String _sharedPdf = 's3_shared.pdf';
const String _sharedJpg = 's3_shared.jpg';
const List<String> _originals = [_pdf, _txt, _csv, _docx, _zip, _openWith, _sharedPdf, _sharedJpg];

void _report(String line) => print('DV_E2E_REPORT s3: $line');

/// Stages picks into the app's staging directory as UIDocumentPicker does.
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

/// Records what the app hands to the share sheet, Save to Files and "Open in" (system UI).
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

/// Quick Look with the real native probe; `present` is recorded (system UI), or real for
/// [realFor] when DV_S3_REAL_QL is on. [failNext] makes the next present fail (the host then falls
/// back to the next viewer).
final class _QuickLook implements QuickLookPort {
  _QuickLook(this.real);

  final QuickLookPort real;
  final List<String> presented = [];
  final Map<String, bool> probed = {};
  bool failNext = false;
  String? realFor;

  @override
  Future<bool> canPreview(ViewerFile file) async {
    final ok = await real.canPreview(file);
    probed[file.displayName] = ok;
    return ok;
  }

  @override
  Future<void> present(List<ViewerFile> files, {int initialIndex = 0}) async {
    final name = files[initialIndex].displayName;
    if (failNext) {
      failNext = false;
      throw StateError('S3-Q: Quick Look unavailable for this step');
    }
    presented.add(name);
    if (_realQuickLook && realFor == name) {
      _report('Quick Look: real QLPreviewController shown; waiting for Done');
      await real.present(files, initialIndex: initialIndex);
      _report('Quick Look: dismissed');
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
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
  _World(this.prefs, this.player, this.editor, this.picker, this.out, this.quickLook);

  final SharedPreferences prefs;
  final PlaybackEngine player;
  final List<Override> editor;
  final _StagingPicker picker;
  final _RecordingFileOut out;
  final _QuickLook quickLook;
  FilesHomeRuntime? runtime;

  LibraryStore get store => runtime!.store!;

  /// Opens the S2 + S3 wiring (as `lib/main.dart` does) and pumps the app at Home.
  Future<void> launch(WidgetTester tester) async {
    final r = runtime = await filesHomeOverrides(prefs: prefs);
    expect(r.store, isNotNull, reason: 'the library opened under Application Support');
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
        // including PDFKit (PlatformPdfDocuments) and the Quick Look probe.
        importPickerProvider.overrideWithValue(picker),
        importStagingDirectoryProvider.overrideWithValue(dirs.importStaging),
        fileOutPortProvider.overrideWithValue(out),
        documentViewerSetupProvider.overrideWithValue(documentViewerSetupFor(TargetPlatform.iOS, quickLook: quickLook)),
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
  return _World(prefs, player, editor, _StagingPicker(dirs.importStaging), _RecordingFileOut(NativeFileOut(FileOutPlatform.iOS)),
      _QuickLook(NativeQuickLookPort()));
}

Finder _key(String k) => find.byKey(ValueKey<String>(k));

Finder _entryRow(EntryId id) => _key('library-entry-${id.value}');

Future<void> _tab(WidgetTester tester, HomeTab tab) async {
  await E2eApp.tap(tester, find.byKey(homeTabKey(tab)), what: '${tab.name} tab');
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _prompt(WidgetTester tester, String text, String confirm) async {
  await E2eApp.pumpUntil(tester, () => find.byType(EditableText).hitTestable().evaluate().isNotEmpty, what: 'the name prompt');
  await tester.enterText(find.byType(EditableText).hitTestable().last, text);
  await tester.pump();
  await E2eApp.hideKeyboard(tester);
  await E2eApp.tap(tester, find.text(confirm).hitTestable().last, what: confirm);
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

/// Scrolls the visible tab's list until [target] is built and hit-testable (rows build lazily;
/// a used install has rows of earlier runs).
Future<void> _reveal(WidgetTester tester, Finder target, {required String what}) async {
  if (target.hitTestable().evaluate().isNotEmpty) return;
  final lists = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down);
  await E2eApp.pumpUntil(tester, () => lists.evaluate().isNotEmpty, what: 'the list for $what');
  await tester.scrollUntilVisible(target, 160, scrollable: lists.last, maxScrolls: 200);
  await tester.pump(const Duration(milliseconds: 200));
}

/// Opens [entry] from the Documents tab (or All for other files) and waits for the viewer host.
Future<void> _openRow(WidgetTester tester, FileEntry entry, {HomeTab tab = HomeTab.documents}) async {
  await _tab(tester, tab);
  final row = _entryRow(entry.id);
  await _reveal(tester, row, what: 'the row of ${entry.displayName}');
  await E2eApp.tap(tester, row, what: 'row ${entry.displayName}');
  await E2eApp.pumpUntil(tester, () => find.byType(DocumentViewer).evaluate().isNotEmpty, what: 'the viewer host');
}

/// The App Group container of `group.com.vecvel.danaview` on the simulator: a sibling of the app's
/// data container (`…/data/Containers/{Data/Application,Shared/AppGroup}/<uuid>`), found by its
/// container metadata. Null when there is none (no entitlement).
Directory? _appGroupContainer(String support) {
  const marker = '/data/Containers/';
  final i = support.indexOf(marker);
  if (i < 0) return null;
  final groups = Directory('${support.substring(0, i + marker.length)}Shared/AppGroup');
  if (!groups.existsSync()) return null;
  for (final d in groups.listSync().whereType<Directory>()) {
    final meta = File('${d.path}/.com.apple.mobile_container_manager.metadata.plist');
    if (!meta.existsSync()) continue;
    if (latin1.decode(meta.readAsBytesSync(), allowInvalid: true).contains('group.com.vecvel.danaview')) return d;
  }
  return null;
}

/// Writes a batch as ios/DanaviewShare/InboxWriter.swift does: streamed copies under
/// `items/<n>/<name>`, `manifest.json` last (or not at all for an interrupted share).
Directory _writeBatch(Directory group, String batchId, List<File> files, {String? targetFolderId, bool complete = true}) {
  final batch = Directory('${group.path}/Inbox/$batchId')..createSync(recursive: true);
  final items = <Map<String, Object>>[];
  for (var n = 0; n < files.length; n++) {
    final name = files[n].uri.pathSegments.last;
    final dir = Directory('${batch.path}/items/$n')..createSync(recursive: true);
    files[n].copySync('${dir.path}/$name');
    items.add({
      'file': 'items/$n/$name',
      'name': name,
      'size': files[n].lengthSync(),
      'uti': name.endsWith('.pdf') ? 'com.adobe.pdf' : 'public.jpeg',
      if (targetFolderId != null) 'targetFolderId': targetFolderId,
    });
  }
  if (complete) {
    final manifest = jsonEncode({
      'format': 'danaview.inbox',
      'schema': 1,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'items': items,
    });
    final tmp = File('${batch.path}/manifest.json.tmp')..writeAsStringSync(manifest);
    tmp.renameSync('${batch.path}/manifest.json');
  }
  return batch;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('S3: import documents, view each in its viewer, Quick Look, Open with, Share Extension inbox, share out, reopen',
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
    for (final tab in [HomeTab.home, HomeTab.all, HomeTab.videos, HomeTab.photos, HomeTab.documents, HomeTab.folders]) {
      expect(find.byKey(homeTabKey(tab)), findsOneWidget, reason: '${tab.name} tab');
    }
    expect(IncomingMediaBridge.interceptor, isNotNull, reason: 'Open with Danaview is installed');
    _report('tabs ok, Documents shown; Open with interceptor installed');
    await E2eApp.screenshot(tester, 's3-01-home');

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
    await E2eApp.screenshot(tester, 's3-02-import-sheet');
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

    // The Documents tab lists the documents and filters by type.
    await _tab(tester, HomeTab.documents);
    for (final n in [_pdf, _txt, _csv, _docx]) {
      await _reveal(tester, _entryRow(imported[n]!.id), what: 'Documents row $n');
    }
    await E2eApp.screenshot(tester, 's3-03-documents-tab');
    await E2eApp.tapKey(tester, 'documents-sub-pdf');
    await tester.pump(const Duration(milliseconds: 300));
    await _reveal(tester, _entryRow(imported[_pdf]!.id), what: 'the PDF under the PDF sub-filter');
    expect(_entryRow(imported[_txt]!.id), findsNothing, reason: 'PDF sub-filter');
    await E2eApp.tapKey(tester, 'documents-sub-all');
    await tester.pump(const Duration(milliseconds: 300));
    await _reveal(tester, _entryRow(imported[_pdf]!.id), what: 'the PDF row');
    // Product gap check: Share / Save to Files for a document (HOM-22's file menu in S2).
    await E2eApp.tap(tester, find.descendant(of: _entryRow(imported[_pdf]!.id), matching: find.byTooltip('More')).hitTestable(),
        what: 'More of the PDF row');
    final rowMenu = ['Open', 'Rename…', 'Move to…', 'Delete', 'Share', 'Save to Files', 'File info', 'Favourite', 'Copy to…', 'Open in another app']
        .where((t) => find.text(t).hitTestable().evaluate().isNotEmpty)
        .toList();
    _report('Documents row menu: $rowMenu');
    if (!rowMenu.contains('Share')) _report('FINDING no Share / Save to Files / File info / Favourite for a document (row menu $rowMenu)');
    await E2eApp.screenshot(tester, 's3-04-document-row-menu');
    await tester.tapAt(const Offset(4, 300));
    await tester.pump(const Duration(milliseconds: 400));

    // ---- 3. The PDF in PDFKit ----
    final sw = Stopwatch()..start();
    await _openRow(tester, imported[_pdf]!);
    await E2eApp.pumpUntil(tester, () => find.byType(PdfViewer).evaluate().isNotEmpty, what: 'the PDF viewer', timeout: const Duration(seconds: 20));
    await E2eApp.pumpUntil(tester, () => find.textContaining('of 200').evaluate().isNotEmpty || find.text('PDF · 200 pages').evaluate().isNotEmpty,
        what: 'the 200 pages', timeout: const Duration(seconds: 20));
    final firstPageMs = sw.elapsedMilliseconds;
    await E2eApp.pumpUntil(tester, () => find.textContaining('Page 1 of 200').evaluate().isNotEmpty, what: 'the first page shown',
        timeout: const Duration(seconds: 20));
    _report('PDFKit: 200 pages, "Page 1 of 200" ${sw.elapsedMilliseconds} ms after the tap (document info at $firstPageMs ms; '
        'simulator debug build, budget 500 ms is for the mid tier)');
    await tester.pump(const Duration(seconds: 1));
    await E2eApp.screenshot(tester, 's3-05-pdf-viewer');
    await _tapTooltip(tester, 'Search in PDF');
    await E2eApp.pumpUntil(tester, () => find.byType(EditableText).hitTestable().evaluate().isNotEmpty, what: 'the search field');
    await tester.enterText(find.byType(EditableText).hitTestable().last, 'HOM27T-P0150');
    await E2eApp.pumpUntil(tester, () => find.textContaining('match').evaluate().isNotEmpty, what: 'search results',
        timeout: const Duration(seconds: 30));
    final summary = (tester.widget<Text>(find.textContaining('match').first)).data;
    expect(summary, isNot('No matches'), reason: 'the page token is found');
    _report('PDF search for a page token: "$summary"');
    await E2eApp.hideKeyboard(tester);
    await E2eApp.screenshot(tester, 's3-06-pdf-search');
    await _tapTooltip(tester, 'Search in PDF');
    await _tapTooltip(tester, 'Pages');
    await E2eApp.pumpUntil(tester, () => _key('pdf-pages-grid').evaluate().isNotEmpty, what: 'page thumbnails');
    await tester.pump(const Duration(seconds: 1));
    await E2eApp.screenshot(tester, 's3-07-pdf-pages');
    await _tapTooltip(tester, 'Pages');
    await _tapTooltip(tester, 'View options');
    await E2eApp.tap(tester, find.text('Open in another app').hitTestable().last, what: 'Open in another app');
    await E2eApp.pumpUntil(tester, () => world.out.openedIn.isNotEmpty, what: 'the Open in hand-off');
    expect(world.out.openedIn.last.displayName, imported[_pdf]!.displayName);
    expect(File(world.out.openedIn.last.path).readAsBytesSync(), bytes[_pdf], reason: 'the other app gets the library file');
    _report('PDF: Open in another app handed over ${world.out.openedIn.last.mime}');
    await tester.pump(const Duration(milliseconds: 500));
    await _viewerBack(tester);

    // ---- 4. Text, CSV and Word through Quick Look; in-app fallbacks; the file card ----
    for (final n in [_txt, _csv, _docx]) {
      final count = world.quickLook.presented.length;
      world.quickLook.realFor = n == _docx ? imported[_docx]!.displayName : null;
      await _openRow(tester, imported[n]!);
      await E2eApp.pumpUntil(tester, () => world.quickLook.probed.containsKey(imported[n]!.displayName), what: 'the Quick Look probe of $n');
      final previewable = world.quickLook.probed[imported[n]!.displayName]!;
      if (previewable) {
        await E2eApp.pumpUntil(tester, () => world.quickLook.presented.length > count, what: 'Quick Look for $n');
        await E2eApp.screenshot(tester, 's3-08-quicklook-${n.split('.').last}');
        await E2eApp.pumpUntil(tester, () => find.byType(DocumentViewer).evaluate().isEmpty, what: 'Quick Look to close the viewer',
            timeout: Duration(seconds: _realQuickLook && n == _docx ? 180 : 20));
      } else {
        await E2eApp.pumpUntil(tester, () => find.byType(TextViewer).evaluate().isNotEmpty || find.byType(CsvViewer).evaluate().isNotEmpty,
            what: 'the in-app viewer of $n');
        await _viewerBack(tester);
      }
      _report('$n: Quick Look canPreview=$previewable → ${previewable ? 'Quick Look (editing disabled natively)' : 'in-app viewer'}');
    }
    expect(world.quickLook.probed[imported[_docx]!.displayName], isTrue, reason: 'Quick Look previews a Word file');

    // Quick Look failing: the text and the CSV fall back to the in-app viewers.
    world.quickLook.failNext = true;
    await _openRow(tester, imported[_txt]!);
    await E2eApp.pumpUntil(tester, () => _key('text-viewer-rows').evaluate().isNotEmpty, what: 'the in-app text viewer');
    expect(find.textContaining('S3Q-T0001'), findsWidgets, reason: 'UTF-8 lines shown');
    expect(find.textContaining('日本語'), findsWidgets, reason: 'non-Latin text decoded');
    await E2eApp.screenshot(tester, 's3-09-text-viewer');
    await _viewerBack(tester);
    world.quickLook.failNext = true;
    await _openRow(tester, imported[_csv]!);
    await E2eApp.pumpUntil(tester, () => _key('csv-viewer-rows').evaluate().isNotEmpty, what: 'the in-app CSV grid');
    expect(find.text('Person 001'), findsWidgets, reason: 'CSV cells shown');
    expect(find.text('Zürich'), findsWidgets);
    await E2eApp.screenshot(tester, 's3-10-csv-viewer');
    await _viewerBack(tester);
    _report('Quick Look unavailable → text viewer and CSV grid shown (fallback)');

    // The zip: file card with Share and Open in another app.
    await _openRow(tester, imported[_zip]!, tab: HomeTab.all);
    await E2eApp.pumpUntil(tester, () => find.byType(FileCard).evaluate().isNotEmpty, what: 'the file card');
    await E2eApp.screenshot(tester, 's3-11-file-card');
    await E2eApp.tap(tester, find.text('Share').hitTestable().last, what: 'Share');
    await E2eApp.pumpUntil(tester, () => world.out.shared.isNotEmpty, what: 'the share hand-off');
    expect(File(world.out.shared.last.path).readAsBytesSync(), bytes[_zip]);
    await E2eApp.tap(tester, find.text('Open in another app').hitTestable().last, what: 'Open in another app');
    await E2eApp.pumpUntil(tester, () => world.out.openedIn.length >= 2, what: 'the Open in hand-off');
    _report('file card: Share and Open in another app handed over the library file');
    await _viewerBack(tester);

    final recents = store.reader.recents().map((e) => e.id).toSet();
    expect(recents, containsAll([for (final n in [_pdf, _txt, _csv, _docx, _zip]) imported[n]!.id]), reason: 'Recents record every open');
    _report('Recents: ${recents.length} entries, every opened document recorded');

    // ---- 5. Open with Danaview ----
    // The app container's Documents folder (iOS puts an "Open in" copy into Documents/Inbox).
    final root = store.paths.root;
    final docs = Directory('${root.substring(0, root.indexOf('/Library/'))}/Documents');
    final inboxCopy = File('${docs.path}/Inbox/$_openWith');
    inboxCopy.parent.createSync(recursive: true);
    originals[_openWith]!.copySync(inboxCopy.path);
    final beforeOpen = _entryIds(store);
    ServicesBinding.instance.channelBuffers.push(
        'danaview/media_intent', const StandardMethodCodec().encodeMethodCall(MethodCall('onOpenMedia', inboxCopy.path)), (_) {});
    await E2eApp.pumpUntil(tester, () => _newEntryNamed(store, _openWith, beforeOpen) != null, what: 'the Open with import');
    final opened = _newEntryNamed(store, _openWith, beforeOpen)!;
    await E2eApp.pumpUntil(tester, () => find.byType(PdfViewer).evaluate().isNotEmpty, what: 'the PDF viewer after Open with');
    expect(opened.folderId, importedFolder);
    expect(opened.sourceHint, SourceHint.openWith);
    expect(File(store.paths.entryFile(opened.id, opened.displayName)).readAsBytesSync(), bytes[_openWith]);
    await E2eApp.pumpUntil(tester, () => !inboxCopy.existsSync(), what: "iOS's Documents/Inbox copy removed");
    await tester.pump(const Duration(seconds: 1));
    await E2eApp.screenshot(tester, 's3-12-open-with');
    _report('Open with: imported into Imported (sourceHint openWith), opened in the PDF viewer, Documents/Inbox copy removed');
    await _viewerBack(tester);
    // The same file again, from outside the app: the entry already there opens; no copy is added.
    final countBefore = store.reader.allEntries(includeTrashed: true).length;
    ServicesBinding.instance.channelBuffers.push('danaview/media_intent',
        const StandardMethodCodec().encodeMethodCall(MethodCall('onOpenMedia', Uri.file(originals[_openWith]!.path).toString())), (_) {});
    await E2eApp.pumpUntil(tester, () => find.byType(PdfViewer).evaluate().isNotEmpty, what: 'the viewer for the same file');
    expect(store.reader.allEntries(includeTrashed: true).length, countBefore, reason: 'the same content opens the existing entry');
    expect(originals[_openWith]!.readAsBytesSync(), bytes[_openWith], reason: 'the source is only read');
    _report('Open with the same file (file:// URI from outside): the existing entry opened, no second copy');
    await _viewerBack(tester);

    // ---- 6. The Share Extension inbox ----
    final dirs = await FilesHomeDirectories.resolve();
    final group = _appGroupContainer(dirs.support);
    if (group == null) {
      fail('no App Group container for group.com.vecvel.danaview next to the app container (entitlement missing?)');
    }
    _report('App Group container found (Inbox ${Directory('${group.path}/Inbox').existsSync() ? 'present' : 'not created yet'})');
    await _tab(tester, HomeTab.folders);
    final rootsBefore = {for (final f in store.reader.childFolders(null)) f.id};
    await E2eApp.tapKey(tester, 'folders-new-root');
    await _prompt(tester, 'Shared in', 'Create');
    await E2eApp.pumpUntil(tester, () => store.reader.childFolders(null).any((f) => !rootsBefore.contains(f.id)), what: 'the Shared in folder');
    final target = store.reader.childFolders(null).firstWhere((f) => !rootsBefore.contains(f.id));
    final snapshot = File('${group.path}/folder-snapshot.json');
    await E2eApp.pumpUntil(tester, () => snapshot.existsSync() && snapshot.readAsStringSync().contains(target.id.value),
        what: 'the folder snapshot for the extension picker', timeout: const Duration(seconds: 20));
    expect(snapshot.readAsStringSync(), contains(target.name));
    _report('folder snapshot in the App Group lists the new folder (${snapshot.lengthSync()} B)');

    final stamp = DateTime.now().millisecondsSinceEpoch;
    final batch = _writeBatch(group, '$stamp-s3q', [originals[_sharedPdf]!, originals[_sharedJpg]!], targetFolderId: target.id.value);
    final interrupted = _writeBatch(group, '${stamp + 1}-s3q-interrupted', [originals[_sharedPdf]!], complete: false);
    final beforeInbox = _entryIds(store);
    // The extension posts a Darwin notification the app sees while it runs; a background → foreground
    // cycle is the path a share from another app always takes, so the scenario uses it.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(milliseconds: 300));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await E2eApp.pumpUntil(tester,
        () => _newEntryNamed(store, _sharedPdf, beforeInbox) != null && _newEntryNamed(store, _sharedJpg, beforeInbox) != null,
        what: 'the inbox import', timeout: const Duration(seconds: 45));
    final sharedPdf = _newEntryNamed(store, _sharedPdf, beforeInbox)!;
    final sharedJpg = _newEntryNamed(store, _sharedJpg, beforeInbox)!;
    await E2eApp.pumpUntil(tester, () => find.textContaining('shared items saved').evaluate().isNotEmpty, what: 'the inbox toast');
    await E2eApp.screenshot(tester, 's3-13-inbox-toast');
    for (final e in [sharedPdf, sharedJpg]) {
      expect(e.folderId, target.id, reason: 'the folder picked in the extension');
      expect(e.sourceHint, SourceHint.shareExtension);
    }
    expect(File(store.paths.entryFile(sharedPdf.id, sharedPdf.displayName)).readAsBytesSync(), bytes[_sharedPdf]);
    expect(File(store.paths.entryFile(sharedJpg.id, sharedJpg.displayName)).readAsBytesSync(), bytes[_sharedJpg]);
    expect(sharedJpg.kind, FileKind.photo);
    await E2eApp.pumpUntil(tester, () => !batch.existsSync(), what: 'the imported batch deleted');
    expect(interrupted.existsSync(), isTrue, reason: 'an incomplete batch is never imported (deleted after 24 h)');
    expect(store.reader.allEntries(includeTrashed: true).where((e) => !beforeInbox.contains(e.id)).length, 2,
        reason: 'the interrupted share left no entry');
    _report('Share Extension inbox: 2 items into "${target.name}" (sourceHint shareExtension), toast shown, batch deleted, '
        'interrupted batch left alone and not imported');
    interrupted.deleteSync(recursive: true);

    // ---- 7. Reopen ----
    await world.close(tester);
    await world.launch(tester);
    final reopened = world.store;
    for (final e in [...imported.values, opened, sharedPdf, sharedJpg]) {
      final again = reopened.reader.entry(e.id);
      expect(again, isNotNull, reason: '${e.displayName} persists');
      expect(File(reopened.paths.entryFile(e.id, again!.displayName)).existsSync(), isTrue);
    }
    expect(reopened.reader.recents().map((e) => e.id), containsAll([imported[_pdf]!.id, opened.id]), reason: 'Recents persist');
    await _openRow(tester, imported[_pdf]!);
    await E2eApp.pumpUntil(tester, () => find.textContaining('Page 1 of 200').evaluate().isNotEmpty, what: 'the PDF after reopening',
        timeout: const Duration(seconds: 20));
    await E2eApp.screenshot(tester, 's3-14-after-reopen');
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
