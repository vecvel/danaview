// OWNER: S4-Q
//
// Slice S4 E2E (BUILD_PLAN v1.2 §1A, S4-Q; the S4 share of HOM-32 and of QA-101 scenario 1) on the
// iOS Simulator (iPhone and iPad), with the real app router and the real S2 + S3 + S4 wiring
// (`filesHomeOverrides` → `documentsOverrides` → `pdfToolsOverrides`, real PDFKit through
// danaview_pdf, the real library, import queue, saved-signature store and backup flag).
//
// With DANAVIEW_FILES_HOME=true:
//
//   1. real-world PDFs (make_s4_docs.sh: a two-column report with embedded fonts and a picture, a
//      phone scan, a form with fields and annotations, a 200-page file, a password PDF, a
//      3-page partner) and two photos are imported "From Files" into Imported;
//   2. Organise pages from the viewer: select, rotate, drag to reorder, delete, Save as a new file;
//      Extract the selection; Split by ranges and every N pages; Undo all; the discard prompt;
//      Cancel during a 200-page save leaves no file;
//   3. Replace: only for a Danaview folder file (same entry, new bytes); a file from outside the
//      library is never offered Replace and its result goes to Imported;
//   4. Merge with… (viewer menu) a PDF, the partner and a photo; Cancel during a merge;
//   5. the multi-select bar's Merge into PDF (two photos, then Add files adds a PDF);
//   6. Compress… every preset on the scan (sizes and times), the report and the 200-page file;
//      "not smaller" on a tiny text PDF (no file); Cancel (no file);
//   7. Annotate: highlight, underline and strike-through of real text (line rects of real search
//      hits), ink in a colour and width, a text box, the eraser, select + Delete, Undo / Redo, the
//      discard prompt (Cancel keeps, Discard drops); Save as "(annotated)" keeps the form's fields
//      and its own annotations;
//   8. Sign: draw, type and import a signature; place on three pages, move and resize, select +
//      Delete + Undo; Save "(signed)" burns them in (no stamp annotation, text still text);
//   9. a password PDF unlocked in the viewer: organise, merge and compress outputs stay encrypted
//      with that password;
//  10. saved signatures sit in `<app support>/signatures` (app-private, `isExcludedFromBackup`),
//      survive closing and reopening the app's world, show in Settings › Privacy, and "Delete all"
//      empties them;
//  11. every original (library copies and the files on the host) is unchanged (bytes and
//      timestamps), every result keeps its text selectable (real text extraction), nothing is left
//      in the tools' staging folder, and no HttpClient is created.
//
// With DANAVIEW_FILES_HOME off (the 1.1 build): the app boots to the 1.1 Home, the app root adds no
// S4 override, no handler or tools scope exists, Settings has no saved-signature rows and no
// signatures folder is created.
//
// Native input seams (system UI and native touches an integration test can't produce): the Files
// picker stages copies as UIDocumentPicker does; the photo picker of "Import" hands over a photo's
// bytes; the PDFKit view's text selection, ink strokes, taps and stamp drags arrive through a
// wrapper of the real annotate engine (its `events` and `selectionLines`) and of the real view
// controller (its `hasSelection` state). Everything they feed goes through the real session,
// model, native preview and native save. Real finger ink, a real long-press selection and dragging
// a signature by hand are the manual checks of S4-QA.md; Apple Pencil needs a real iPad.
//
// Results are copied with a manifest into DV_S4_OUT (the host's build/e2e/s4_out/<device>), where
// tool/check_s4_outputs.py reads them with a second reader (poppler).
//
// Run: integration_test/v12/s4/tool/make_s4_docs.sh
//      DV_E2E_IPHONE="iPhone 17" DV_E2E_EXTRA_DEFINES="DANAVIEW_FILES_HOME=true DV_S4_DOCS=$PWD/build/e2e/s4_docs \
//        DV_S4_OUT=$PWD/build/e2e/s4_out/iphone" \
//        scripts/ci/editor/e2e_ios.sh --target integration_test/v12/s4/s4_pdf_tools_test.dart iphone
//      (flag off: the same without DANAVIEW_FILES_HOME=true; the iPad: DV_E2E_IPAD=… ipad)

// ignore_for_file: avoid_print, implementation_imports, depend_on_referenced_packages

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:danaview/app.dart';
import 'package:danaview/main.dart' show editorAppOverrides;
import 'package:danaview/router/app_router.dart' show appNavigatorKey;
import 'package:danaview/wiring/documents_wiring.dart';
import 'package:danaview/wiring/files_home_wiring.dart';
import 'package:danaview/wiring/pdf_tools_wiring.dart';
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
import 'package:danaview_features/src/library/selection/selection_actions.dart' show selectionActionGroupsProvider;
import 'package:danaview_features/src/library/selection/selection_bar.dart' show mediaSelectionGroup;
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_library_native/danaview_library_native.dart' show NativeBackupFlags;
import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:danaview_platform/danaview_platform.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../editor/support/e2e.dart';

const String _docsDir = String.fromEnvironment('DV_S4_DOCS');
const String _outDir = String.fromEnvironment('DV_S4_OUT');

const String _report = 's4_report.pdf';
const String _scan = 's4_scan.pdf';
const String _form = 's4_form.pdf';
const String _long = 's4_long.pdf';
const String _locked = 's4_locked.pdf';
const String _partner = 's4_partner.pdf';
const String _photo = 's4_photo.jpg';
const String _sigPhoto = 's4_signature.jpg';
const String _password = 's4qa-open';
const List<String> _imports = [_report, _scan, _form, _long, _locked, _partner, _photo, _sigPhoto];

/// The page tokens of each text fixture (make_s4_docs.sh), page by page.
final Map<String, List<String>> _tokens = {
  _report: [for (var p = 1; p <= 6; p++) 'S4QR-P${p.toString().padLeft(4, '0')}'],
  _form: ['S4QF-P0001', 'S4QF-P0002'],
  _locked: ['S4QL-P0001', 'S4QL-P0002', 'S4QL-P0003'],
  _long: [for (var p = 1; p <= 200; p++) 'HOM27T-P${p.toString().padLeft(4, '0')}'],
  _partner: ['HOM27M-P0001', 'HOM27M-P0002', 'HOM27M-P0003'],
};

void _say(String line) => print('DV_E2E_REPORT s4: $line');

// ---------------------------------------------------------------------------------------------
// Seams
// ---------------------------------------------------------------------------------------------

/// Stages picks into the app's staging directory as UIDocumentPicker does.
final class _StagingPicker implements ImportPicker {
  _StagingPicker(this.staging);

  final String staging;
  final List<String> files = [];

  @override
  bool get canPickPhotos => true;

  @override
  Future<List<ImportSource>> pickPhotos() async => const [];

  @override
  Future<List<ImportSource>> pickFiles() async {
    final out = <ImportSource>[];
    for (final p in files) {
      final name = p.split('/').last;
      final dir = Directory('$staging/s4q-${DateTime.now().microsecondsSinceEpoch}')..createSync(recursive: true);
      final copy = File(p).copySync('${dir.path}/$name');
      out.add(ImportSource.file(copy.path,
          displayName: name, sizeBytes: copy.lengthSync(), modifiedAt: File(p).lastModifiedSync(), sourceHint: SourceHint.files, stagedCopy: true));
    }
    files.clear();
    return out;
  }
}

/// The real view controller; its `hasSelection` can be forced on (a native long-press selection).
final class _SeamView implements PdfViewController {
  _SeamView(this.real) {
    _sub = real.states.listen((s) {
      _last = s;
      _out.add(_selected ? s.copyWith(hasSelection: true) : s);
    });
  }

  final PdfViewController real;
  final StreamController<PdfViewState> _out = StreamController<PdfViewState>.broadcast();
  // ignore: unused_field
  late final StreamSubscription<PdfViewState> _sub;
  PdfViewState? _last;
  bool _selected = false;

  Future<void> select(bool on) async {
    _selected = on;
    final s = _last ?? await real.state();
    _out.add(s.copyWith(hasSelection: on));
  }

  @override
  int get viewId => real.viewId;

  @override
  Stream<PdfViewState> get states => _out.stream;

  @override
  Future<PdfViewState> state() async {
    final s = await real.state();
    return _selected ? s.copyWith(hasSelection: true) : s;
  }

  @override
  Future<void> goToPage(int pageIndex) => real.goToPage(pageIndex);

  @override
  Future<void> setScale(double scale) => real.setScale(scale);

  @override
  Future<void> zoomToFit() => real.zoomToFit();

  @override
  Future<void> setDisplayMode(PdfDisplayMode mode) => real.setDisplayMode(mode);

  @override
  Future<PdfSearchResult> search(String query, {bool caseSensitive = false, int maxHits = 500}) =>
      real.search(query, caseSensitive: caseSensitive, maxHits: maxHits);

  @override
  Future<void> cancelSearch() => real.cancelSearch();

  @override
  Future<void> showSearchHit(PdfSearchHit hit) => real.showSearchHit(hit);

  @override
  Future<void> clearSearch() => real.clearSearch();

  @override
  Future<String?> selectedText() => real.selectedText();

  @override
  Future<bool> copySelection() => real.copySelection();

  @override
  Future<void> clearSelection() async {
    _selected = false;
    await real.clearSelection();
  }
}

/// The real annotate engine; native events and the text selection can be fed in.
final class _SeamAnnotate implements PdfAnnotateEngine {
  _SeamAnnotate(this.real);

  final PdfAnnotateEngine real;
  final List<StreamController<PdfAnnotateEvent>> _sinks = [];
  List<PdfPageRects>? selection;
  List<PdfAnnotateItem> shown = const [];
  final List<String> saves = [];

  void emit(PdfAnnotateEvent event) {
    for (final s in List.of(_sinks)) {
      s.add(event);
    }
  }

  @override
  Future<void> setMode(int viewId, PdfAnnotateMode? mode) => real.setMode(viewId, mode);

  @override
  Future<void> show(int viewId, List<PdfAnnotateItem> items, {String? selectedId}) {
    shown = items;
    return real.show(viewId, items, selectedId: selectedId);
  }

  @override
  Future<List<PdfPageRects>> selectionLines(int viewId) async => selection ?? await real.selectionLines(viewId);

  @override
  Stream<PdfAnnotateEvent> events(int viewId) {
    late final StreamController<PdfAnnotateEvent> c;
    StreamSubscription<PdfAnnotateEvent>? sub;
    c = StreamController<PdfAnnotateEvent>(
      onListen: () {
        sub = real.events(viewId).listen(c.add, onError: c.addError);
        _sinks.add(c);
      },
      onCancel: () async {
        _sinks.remove(c);
        await sub?.cancel();
      },
    );
    return c.stream;
  }

  @override
  PdfToolJob save(PdfToolInput input, {required List<PdfAnnotation> annotations, List<PdfStamp> stamps = const [], bool burnIn = false, required String outPath}) {
    saves.add(burnIn ? 'burn-in ${stamps.length} stamps' : '${annotations.length} annotations');
    return real.save(input, annotations: annotations, stamps: stamps, burnIn: burnIn, outPath: outPath);
  }
}

/// Records every HttpClient the app creates (QA-103 scope: S4 adds no host).
final class _HttpSpy extends HttpOverrides {
  final List<String> created = [];

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    created.add(StackTrace.current.toString().split('\n').skip(1).take(4).join(' | '));
    return super.createHttpClient(context);
  }
}

final class _World {
  _World(this.prefs, this.player, this.editor, this.picker, this.annotate, this.signaturePhoto);

  final SharedPreferences prefs;
  final PlaybackEngine player;
  final List<Override> editor;
  final _StagingPicker picker;
  final _SeamAnnotate annotate;
  final Uint8List signaturePhoto;
  final List<_SeamView> views = [];
  FilesHomeRuntime? runtime;

  LibraryStore get store => runtime!.store!;
  _SeamView get view => views.last;

  Widget _view(BuildContext context, PdfDocumentInfo document, ValueChanged<PdfViewController> onCreated) =>
      PdfView(document: document, onCreated: (c) {
        final seam = _SeamView(c);
        views.add(seam);
        onCreated(seam);
      });

  /// Opens the wiring as `lib/main.dart` does and pumps the app at Home.
  Future<void> launch(WidgetTester tester) async {
    final r = runtime = await filesHomeOverrides(prefs: prefs);
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
        if (FeatureFlags.filesHomeEnabled) ...[
          // System UI and native touches (see the file header); everything else is the app's.
          importPickerProvider.overrideWithValue(picker),
          importStagingDirectoryProvider.overrideWithValue(dirs.importStaging),
          pdfToolsEngineProvider.overrideWithValue(PdfToolsEngine(documents: PlatformPdfDocuments(), tools: PlatformPdfPageTools(), annotate: annotate)),
          signaturePhotoPickerProvider.overrideWithValue((_) async => signaturePhoto),
          documentViewerSetupProvider.overrideWith((ref) => documentViewerSetupFor(TargetPlatform.iOS, compress: pdfCompressLauncher(ref.read), pdfView: _view)),
        ],
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
  final sig = _docsDir.isEmpty ? Uint8List(0) : File('$_docsDir/$_sigPhoto').readAsBytesSync();
  return _World(prefs, player, editor, _StagingPicker(dirs.importStaging), _SeamAnnotate(PlatformPdfAnnotateEngine()), sig);
}

// ---------------------------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------------------------

Finder _key(String k) => find.byKey(ValueKey<String>(k));

Finder _entryRow(EntryId id) => _key('library-entry-${id.value}');

Future<void> _tab(WidgetTester tester, HomeTab tab) async {
  await E2eApp.tap(tester, find.byKey(homeTabKey(tab)), what: '${tab.name} tab');
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _tapKey(WidgetTester tester, String key, {String? what}) async {
  await E2eApp.pumpUntil(tester, () => _key(key).evaluate().isNotEmpty, what: what ?? key);
  if (_key(key).hitTestable().evaluate().isEmpty) {
    await tester.ensureVisible(_key(key).first);
    await tester.pump(const Duration(milliseconds: 200));
  }
  await E2eApp.pumpUntil(tester, () => _key(key).hitTestable().evaluate().isNotEmpty, what: what ?? key);
  await E2eApp.tap(tester, _key(key).hitTestable().first, what: what ?? key);
}

/// Taps [f] at once if it is on screen (a progress Cancel that may close any moment); no waiting.
Future<void> _tapNow(WidgetTester tester, Finder f) async {
  if (f.hitTestable().evaluate().isEmpty) return;
  final g = await tester.startGesture(tester.getCenter(f.hitTestable().first));
  await Future<void>.delayed(const Duration(milliseconds: 60));
  await g.up();
  await tester.pump();
}

Future<void> _tapText(WidgetTester tester, String text) async {
  await E2eApp.pumpUntil(tester, () => find.text(text).hitTestable().evaluate().isNotEmpty, what: '"$text"');
  await E2eApp.tap(tester, find.text(text).hitTestable().last, what: text);
}

Future<void> _tapTooltip(WidgetTester tester, String tooltip) async {
  await E2eApp.pumpUntil(tester, () => find.byTooltip(tooltip).hitTestable().evaluate().isNotEmpty, what: tooltip);
  await E2eApp.tap(tester, find.byTooltip(tooltip).hitTestable().last, what: tooltip);
}

Future<void> _settle(WidgetTester tester, [int ms = 400]) async {
  for (var i = 0; i < ms ~/ 100; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<void> _enter(WidgetTester tester, String text) async {
  await E2eApp.pumpUntil(tester, () => find.byType(EditableText).hitTestable().evaluate().isNotEmpty, what: 'a text field');
  await tester.enterText(find.byType(EditableText).hitTestable().last, text);
  await tester.pump();
  await E2eApp.hideKeyboard(tester);
}

Future<void> _longPress(WidgetTester tester, Finder finder, {required String what}) async {
  final target = finder.first;
  await E2eApp.pumpUntil(tester, () => target.hitTestable().evaluate().isNotEmpty, what: what);
  final gesture = await tester.startGesture(tester.getCenter(target));
  await Future<void>.delayed(const Duration(milliseconds: 800));
  await tester.pump(const Duration(milliseconds: 800));
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _reveal(WidgetTester tester, Finder target, {required String what}) async {
  if (target.hitTestable().evaluate().isNotEmpty) return;
  final lists = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down);
  await E2eApp.pumpUntil(tester, () => lists.evaluate().isNotEmpty, what: 'the list for $what');
  await tester.pump(const Duration(milliseconds: 300));
  await tester.scrollUntilVisible(target, 160, scrollable: lists.last, maxScrolls: 300);
  await tester.pump(const Duration(milliseconds: 200));
}

Set<EntryId> _ids(LibraryStore store) => {for (final e in store.reader.allEntries(includeTrashed: true)) e.id};

List<FileEntry> _newEntries(LibraryStore store, Set<EntryId> before) =>
    store.reader.allEntries(includeTrashed: true).where((e) => !before.contains(e.id)).toList();

bool _isNameOf(String display, String name) {
  if (display == name) return true;
  final dot = name.lastIndexOf('.');
  final stem = dot < 0 ? name : name.substring(0, dot);
  final ext = dot < 0 ? '' : name.substring(dot);
  return RegExp('^${RegExp.escape(stem)} \\(\\d+\\)${RegExp.escape(ext)}\$').hasMatch(display);
}

final Finder _keepBoth = find.byWidgetPredicate(
    (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('import-keep-both-'));

String _sha(List<int> bytes) {
  // FNV-1a 64 (no crypto package in the app's test deps); the bytes are compared too.
  var h = 0xcbf29ce484222325;
  for (final b in bytes) {
    h ^= b;
    h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return h.toRadixString(16);
}

/// What a second look at a written PDF shows.
final class _Inspect {
  _Inspect(this.pages, this.encrypted, this.rotations, this.text, this.subtypes, this.images);

  final int pages;
  final bool encrypted;
  final List<int> rotations;
  final List<String> text;
  final Map<String, int> subtypes;
  final int images;

  bool hasTokens(Iterable<String> tokens) => tokens.every((t) => text.any((p) => p.contains(t)));
}

/// Annotation and image subtypes in [bytes], including Flate-compressed object streams.
(Map<String, int>, int) _scanObjects(Uint8List bytes) {
  final subtypes = <String, int>{};
  var images = 0;
  void scan(String s) {
    for (final m in RegExp(r'/Subtype\s*/([A-Za-z]+)').allMatches(s)) {
      final k = m.group(1)!;
      if (k == 'Image') {
        images++;
      } else {
        subtypes[k] = (subtypes[k] ?? 0) + 1;
      }
    }
    for (final _ in RegExp(r'/FT\s*/(Tx|Btn|Ch|Sig)').allMatches(s)) {
      subtypes['Field'] = (subtypes['Field'] ?? 0) + 1;
    }
  }

  final text = latin1.decode(bytes, allowInvalid: true);
  scan(text);
  final streams = RegExp(r'stream\r?\n').allMatches(text);
  for (final m in streams) {
    final end = text.indexOf('endstream', m.end);
    if (end < 0 || end - m.end > 4 * 1024 * 1024) continue;
    final head = text.substring((m.start - 300).clamp(0, m.start), m.start);
    if (!head.contains('/ObjStm')) continue;
    try {
      scan(latin1.decode(zlib.decode(bytes.sublist(m.end, end)), allowInvalid: true));
    } on Object {
      // Not Flate or truncated: ignore.
    }
  }
  return (subtypes, images);
}

Future<_Inspect> _inspect(String path, {String? password}) async {
  final docs = PlatformPdfDocuments();
  final probe = await docs.probe(path);
  final info = await docs.open(path, password: password);
  final rotations = [for (final s in info.pageSizes) s.rotation];
  await docs.close(info.handle);
  final text = await PlatformPdfTextExtractor().extractText(path, password: password);
  final (subtypes, images) = probe.encrypted ? (<String, int>{}, -1) : _scanObjects(File(path).readAsBytesSync());
  return _Inspect(info.pageCount, probe.encrypted, rotations, [for (final p in text.pages) p.text], subtypes, images);
}

/// Copies [path] into DV_S4_OUT with a manifest line, for the host's second reader.
final List<Map<String, Object?>> _manifest = [];
void _keep(String tag, String path, Map<String, Object?> expect) {
  if (_outDir.isEmpty) return;
  try {
    Directory(_outDir).createSync(recursive: true);
    final name = '$tag.pdf';
    File(path).copySync('$_outDir/$name');
    _manifest.add({'tag': tag, 'file': name, ...expect});
    File('$_outDir/manifest.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(_manifest));
  } on FileSystemException catch (e) {
    _say('NOTE could not copy $tag to DV_S4_OUT (${e.osError?.message})');
  }
}

/// Files left in the tools' staging folder (must be none after a tool ends).
List<String> _stagingLeft(String importStaging) {
  final dir = Directory(pdfToolsStagingIn(importStaging));
  if (!dir.existsSync()) return const [];
  return [for (final f in dir.listSync(recursive: true).whereType<File>()) f.path.split('/').last];
}

/// Waits for [count] new entries after [before] (a tool's result being imported).
Future<List<FileEntry>> _awaitNew(WidgetTester tester, LibraryStore store, Set<EntryId> before, {int count = 1, String what = 'the result', int seconds = 90}) async {
  await E2eApp.pumpUntil(tester, () => _newEntries(store, before).length >= count, what: what, timeout: Duration(seconds: seconds));
  return _newEntries(store, before);
}

String _pathOf(LibraryStore store, FileEntry e) => store.paths.entryFile(e.id, e.displayName);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  if (!FeatureFlags.filesHomeEnabled) {
    testWidgets('S4 flag off: the 1.1 Home, no PDF tools anywhere', (tester) async {
      final spy = _HttpSpy();
      HttpOverrides.global = spy;
      addTearDown(() => HttpOverrides.global = null);
      final world = await _boot();
      final runtime = world.runtime = await filesHomeOverrides(prefs: world.prefs);
      expect(runtime.overrides, isEmpty, reason: 'the app root adds nothing with the flag off');
      expect(pdfToolsOverrides(platform: TargetPlatform.iOS, support: '/x'), isEmpty);
      expect(documentsOverrides(platform: TargetPlatform.iOS, support: '/x', excludeStagingFromBackup: false), isEmpty);
      await world.launch(tester);
      final c = ProviderScope.containerOf(tester.element(find.byType(DanaviewApp)), listen: false);
      expect(c.read(pdfToolsEngineProvider), isNull);
      expect(c.read(pdfToolsEnvironmentProvider), isNull);
      expect(c.read(signatureStoreProvider), isNull);
      expect(c.read(pdfCompressEngineProvider), isNull);
      expect(c.read(pdfPageToolsHandlerProvider), isNull);
      expect(c.read(compressPdfHandlerProvider), isNull);
      expect(c.read(signPdfHandlerProvider), isNull);
      expect(c.read(mergeIntoPdfHandlerProvider), isNull);
      expect(c.read(selectionActionGroupsProvider), [mediaSelectionGroup]);
      for (final tab in HomeTab.values) {
        expect(find.byKey(homeTabKey(tab)), findsNothing, reason: 'the 1.1 Home has no Files & Media tabs');
      }
      await E2eApp.screenshot(tester, 's4-off-01-home');
      unawaited(GoRouter.of(appNavigatorKey.currentContext!).push('/settings'));
      await E2eApp.pumpUntil(tester, () => _key('settings-section-privacy').evaluate().isNotEmpty || find.text('Privacy').evaluate().isNotEmpty,
          what: 'Settings');
      await _settle(tester, 800);
      expect(_key('settings-saved-signatures'), findsNothing, reason: 'no saved-signature rows');
      expect(_key('privacy-saved-signatures'), findsNothing);
      await E2eApp.screenshot(tester, 's4-off-02-settings');
      final dirs = await FilesHomeDirectories.resolve();
      expect(Directory(SignatureStore.signaturesPathIn(dirs.support)).existsSync(), isFalse, reason: 'no signatures folder in a flag-off build');
      _say('flag off: 1.1 Home, no S4 override/handler/engine/store, Settings without saved signatures, no signatures folder');
      expect(spy.created, isEmpty);
      await world.close(tester);
    });
    return;
  }

  testWidgets('S4: organise, replace, merge, multi-select merge, compress, annotate, sign, passwords, signatures, originals', (tester) async {
    if (_docsDir.isEmpty) throw StateError('Pass --dart-define=DV_S4_DOCS=<dir> (integration_test/v12/s4/tool/make_s4_docs.sh)');
    final blocking = <String>[];
    final findings = <String>[];
    void finding(String s, {bool block = true}) {
      (block ? blocking : findings).add(s);
      _say('FINDING ${block ? '(blocking) ' : ''}$s');
    }

    final spy = _HttpSpy();
    HttpOverrides.global = spy;
    addTearDown(() => HttpOverrides.global = null);
    addTearDown(() => IncomingMediaBridge.interceptor = null);
    final world = await _boot();
    final hostFiles = {for (final n in _imports) n: File('$_docsDir/$n')};
    for (final e in hostFiles.entries) {
      expect(e.value.existsSync(), isTrue, reason: 'make_s4_docs.sh output ${e.key}');
    }
    final hostBytes = {for (final e in hostFiles.entries) e.key: e.value.readAsBytesSync()};
    final hostTimes = {for (final e in hostFiles.entries) e.key: e.value.lastModifiedSync()};
    final dirs = await FilesHomeDirectories.resolve();
    final timings = <String, int>{};
    Future<T> timed<T>(String what, Future<T> Function() body) async {
      final sw = Stopwatch()..start();
      final r = await body();
      timings[what] = sw.elapsedMilliseconds;
      _say('time $what: ${sw.elapsedMilliseconds} ms');
      return r;
    }

    await world.launch(tester);
    var store = world.store;
    var c = ProviderScope.containerOf(tester.element(find.byType(DanaviewApp)), listen: false);
    final sigStore = c.read(signatureStoreProvider)!;
    await sigStore.deleteAll(); // a used simulator may hold signatures of an earlier run
    await c.read(pdfToolsSupportedProvider.future);
    _say('tools reported: ${(await c.read(pdfToolsSupportedProvider.future)).map((t) => t.name).toList()..sort()}');
    await E2eApp.screenshot(tester, 's4-01-home');

    // ---- 1. Import ----
    // The Home's (+) menu › Import to library (the S2 E2Es still look for the old 's2-import' key).
    await E2eApp.tapKey(tester, 'home-import');
    await _tapText(tester, HomeChromeLabels.importToLibrary);
    await E2eApp.waitKey(tester, 'import-sheet');
    await E2eApp.tapKey(tester, 'import-target');
    await E2eApp.tapKey(tester, 'import-folder-imported');
    final beforeImport = _ids(store);
    world.picker.files.addAll([for (final n in _imports) hostFiles[n]!.path]);
    await E2eApp.tapKey(tester, 'import-from-files');
    final lib = <String, FileEntry>{};
    for (final n in _imports) {
      for (var answered = 0;; answered++) {
        await E2eApp.pumpUntil(
            tester,
            () =>
                _newEntries(store, beforeImport).any((e) => _isNameOf(e.displayName, n)) ||
                _keepBoth.hitTestable().evaluate().isNotEmpty,
            what: 'the import of $n',
            timeout: const Duration(seconds: 90));
        final hit = _newEntries(store, beforeImport).where((e) => _isNameOf(e.displayName, n)).firstOrNull;
        if (hit != null) {
          lib[n] = hit;
          break;
        }
        if (answered > 8) fail('Keep both kept coming back');
        await E2eApp.tap(tester, _keepBoth.hitTestable().first, what: 'Keep both');
      }
    }
    await E2eApp.pumpUntil(tester, () => c.read(importServiceProvider)!.items.every((i) => i.state.isFinal), what: 'imports to finish');
    tester.state<NavigatorState>(find.byType(Navigator).last).maybePop();
    await _settle(tester, 600);
    final libBytes = {for (final e in lib.entries) e.key: File(_pathOf(store, e.value)).readAsBytesSync()};
    final libTimes = {for (final e in lib.entries) e.key: File(_pathOf(store, e.value)).lastModifiedSync()};
    for (final n in _imports) {
      expect(libBytes[n], hostBytes[n], reason: '$n library copy byte-equal');
    }
    _say('imported ${lib.length} files into Imported (PDFs: report 6 p two-column embedded fonts + picture, scan 4 p, '
        'form 2 p fields + annotations, 200 p, password 3 p, partner 3 p; photos 2)');
    for (final n in [_report, _form, _long, _partner]) {
      final i = await _inspect(_pathOf(store, lib[n]!));
      expect(i.hasTokens(_tokens[n]!), isTrue, reason: '$n text extractable before the tools');
    }
    final formBefore = await _inspect(_pathOf(store, lib[_form]!));
    _say('form fixture objects: ${formBefore.subtypes}');

    Future<void> openPdf(FileEntry e, {String? password}) async {
      await _tab(tester, HomeTab.documents);
      try {
        await _reveal(tester, _entryRow(e.id), what: 'row ${e.displayName}');
        await E2eApp.tap(tester, _entryRow(e.id).hitTestable(), what: 'row ${e.displayName}');
      } on Object catch (err) {
        // A long Documents list (every result of this run) that the scroll helper can't reach:
        // open the row's file the way its tap does (files_home_wiring `_openEntry`).
        _say('NOTE opened ${e.displayName} directly (${err.runtimeType})');
        final path = _pathOf(store, e);
        unawaited(openDocumentViewer(appNavigatorKey.currentContext!, c.read, viewerFileOfEntry(e, path), fileMenuItem: mediaItemOfEntry(e, path)));
      }
      await E2eApp.pumpUntil(tester, () => find.byType(PdfViewer).evaluate().isNotEmpty, what: 'the PDF viewer', timeout: const Duration(seconds: 20));
      if (password != null) {
        await E2eApp.pumpUntil(tester, () => find.text('Unlock').hitTestable().evaluate().isNotEmpty, what: 'the password sheet');
        await _enter(tester, password);
        await _tapText(tester, 'Unlock');
      }
      await E2eApp.pumpUntil(tester, () => find.textContaining('Page 1 of').evaluate().isNotEmpty, what: 'the first page',
          timeout: const Duration(seconds: 30));
      await _settle(tester, 600);
    }

    Future<void> viewerBack() async {
      await _tapTooltip(tester, 'Back');
      await E2eApp.pumpUntil(tester, () => find.byType(DocumentViewer).evaluate().isEmpty, what: 'the viewer to close');
      await _settle(tester);
    }

    Future<void> viewerMenu(String label) async {
      await _tapTooltip(tester, 'View options');
      await _tapText(tester, label);
    }

    Future<void> chooseSave(String key) async {
      await E2eApp.pumpUntil(tester, () => _key('pdf-save-new').evaluate().isNotEmpty, what: 'the save choice');
      await E2eApp.screenshot(tester, 's4-save-choice');
      await _tapKey(tester, key);
    }

    final staging = c.read(importStagingDirectoryProvider)!;

    // ---- 2. Organise pages ----
    await openPdf(lib[_report]!);
    expect(_key('pdf-viewer-organise'), findsOneWidget);
    expect(_key('pdf-viewer-annotate'), findsOneWidget);
    expect(_key('pdf-viewer-sign'), findsOneWidget);
    await E2eApp.screenshot(tester, 's4-02-viewer');
    await _tapKey(tester, 'pdf-viewer-organise');
    await E2eApp.pumpUntil(tester, () => _key('pdf-organiser-page-5').evaluate().isNotEmpty, what: 'the organiser grid');
    await _settle(tester, 1000);
    await E2eApp.screenshot(tester, 's4-03-organiser');
    // Select page 2 and rotate it.
    await _tapKey(tester, 'pdf-organiser-page-1');
    await _tapKey(tester, 'pdf-organiser-rotate');
    await _tapKey(tester, 'pdf-organiser-page-1'); // deselect
    // Drag page 4 to the front (long-press drag on touch).
    final from = tester.getCenter(_key('pdf-organiser-page-3'));
    final to = tester.getCenter(_key('pdf-organiser-page-0'));
    final drag = await tester.startGesture(from);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 700));
    for (var i = 1; i <= 10; i++) {
      await drag.moveTo(Offset.lerp(from, to, i / 10)!);
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 300));
    await drag.up();
    await _settle(tester, 600);
    final firstCell = tester.getTopLeft(_key('pdf-organiser-page-3'));
    final dragWorked = firstCell.dy <= tester.getTopLeft(_key('pdf-organiser-page-0')).dy &&
        firstCell.dx <= tester.getTopLeft(_key('pdf-organiser-page-0')).dx;
    _say('organiser drag: page 4 to the front ${dragWorked ? 'worked' : 'did NOT move the page'}');
    if (!dragWorked) finding('Organise pages: a long-press drag of a page thumbnail did not reorder it');
    // Delete page 6.
    await _tapKey(tester, 'pdf-organiser-page-5');
    await _tapKey(tester, 'pdf-organiser-delete');
    await E2eApp.screenshot(tester, 's4-04-organiser-edited');
    // Undo all, then redo the same edits through the semantics-free path: the toolbar again.
    await _tapTooltip(tester, 'View options');
    await _tapText(tester, 'Undo all changes');
    await _settle(tester);
    expect(tester.widget<DanaviewButton>(_key('pdf-organiser-save')).onPressed, isNull, reason: 'Undo all: nothing to save');
    // The discard prompt: change, Back, Cancel keeps the organiser.
    await _tapKey(tester, 'pdf-organiser-page-0');
    await _tapKey(tester, 'pdf-organiser-rotate');
    await _tapTooltip(tester, 'Back');
    await E2eApp.pumpUntil(tester, () => find.text('Discard changes?').evaluate().isNotEmpty, what: 'the discard prompt');
    await E2eApp.screenshot(tester, 's4-05-organiser-discard');
    await _tapText(tester, 'Cancel');
    await _settle(tester);
    expect(_key('pdf-organiser-grid'), findsOneWidget, reason: 'Cancel keeps the organiser');
    // Final edits: page 1 already rotated; rotate page 2, drag page 4 first, delete page 6.
    await _tapKey(tester, 'pdf-organiser-page-0'); // deselect
    await _tapKey(tester, 'pdf-organiser-page-1');
    await _tapKey(tester, 'pdf-organiser-rotate');
    await _tapKey(tester, 'pdf-organiser-page-1');
    await _tapKey(tester, 'pdf-organiser-page-5');
    await _tapKey(tester, 'pdf-organiser-delete');
    var before = _ids(store);
    final organised = await timed('organise 6-page report (save new)', () async {
      await _tapKey(tester, 'pdf-organiser-save');
      await chooseSave('pdf-save-new');
      return (await _awaitNew(tester, store, before, what: 'the organised copy')).single;
    });
    await E2eApp.pumpUntil(tester, () => find.textContaining('Saved as').evaluate().isNotEmpty, what: 'the saved toast');
    expect(organised.displayName, contains('(edited)'));
    expect(organised.folderId, lib[_report]!.folderId, reason: 'next to the original');
    final orgOut = await _inspect(_pathOf(store, organised));
    expect(orgOut.pages, 5);
    expect(orgOut.rotations.take(2).toList(), [90, 90], reason: 'pages 1 and 2 turned');
    expect(orgOut.hasTokens(_tokens[_report]!.take(5)), isTrue, reason: 'text stays selectable after organise');
    expect(orgOut.text.any((t) => t.contains('S4QR-P0006')), isFalse, reason: 'page 6 deleted');
    _say('organise: ${organised.displayName}, 5 pages, rotations ${orgOut.rotations}, tokens extractable, picture kept (${orgOut.images} images)');
    _keep('organise', _pathOf(store, organised), {'pages': 5, 'tokens': _tokens[_report]!.take(5).toList(), 'rot': [90, 90, 0, 0, 0]});
    await _settle(tester, 800);

    // Extract and split from the organiser again (on the viewer of the original).
    await _tapKey(tester, 'pdf-viewer-organise');
    await E2eApp.pumpUntil(tester, () => _key('pdf-organiser-page-5').evaluate().isNotEmpty, what: 'the organiser grid');
    await _tapKey(tester, 'pdf-organiser-page-1');
    await _tapKey(tester, 'pdf-organiser-page-2');
    before = _ids(store);
    final extracted = await timed('extract 2 pages', () async {
      await _tapKey(tester, 'pdf-organiser-extract');
      return (await _awaitNew(tester, store, before, what: 'the extract')).single;
    });
    final extOut = await _inspect(_pathOf(store, extracted));
    expect(extOut.pages, 2);
    expect(extOut.hasTokens(['S4QR-P0002', 'S4QR-P0003']), isTrue);
    _say('extract: ${extracted.displayName}, 2 pages, text kept');
    _keep('extract', _pathOf(store, extracted), {'pages': 2, 'tokens': ['S4QR-P0002', 'S4QR-P0003']});
    await _tapKey(tester, 'pdf-organiser-page-1');
    await _tapKey(tester, 'pdf-organiser-page-2');
    // Split by ranges.
    await _tapKey(tester, 'pdf-organiser-split');
    await _tapKey(tester, 'pdf-split-ranges');
    await tester.enterText(_key('pdf-split-field').hitTestable(), '1-2, 3-6');
    await tester.pump();
    await E2eApp.hideKeyboard(tester);
    await E2eApp.screenshot(tester, 's4-06-split');
    before = _ids(store);
    final parts = await timed('split into 2 ranges', () async {
      await _tapKey(tester, 'pdf-split-go');
      return _awaitNew(tester, store, before, count: 2, what: 'the split parts');
    });
    parts.sort((a, b) => a.displayName.compareTo(b.displayName));
    final partPages = [for (final p in parts) (await _inspect(_pathOf(store, p))).pages];
    expect(partPages..sort(), [2, 4]);
    _say('split ranges 1-2, 3-6: ${parts.map((p) => p.displayName).toList()} pages $partPages');
    // Split every 4 pages.
    await _tapKey(tester, 'pdf-organiser-split');
    await _tapKey(tester, 'pdf-split-every');
    await tester.enterText(_key('pdf-split-every-field').hitTestable(), '4');
    await tester.pump();
    await E2eApp.hideKeyboard(tester);
    before = _ids(store);
    final every = await _awaitNewAfterTap(tester, store, before, 'pdf-split-go', count: 2);
    _say('split every 4 pages: ${every.map((p) => p.displayName).toList()}');
    for (final p in every) {
      expect((await _inspect(_pathOf(store, p))).text.join().contains('S4QR'), isTrue, reason: 'split text kept');
    }
    await _tapTooltip(tester, 'Back');
    await _settle(tester, 600);
    await viewerBack();

    // Cancel during a 200-page organise leaves no file.
    await openPdf(lib[_long]!);
    await _tapKey(tester, 'pdf-viewer-organise');
    await E2eApp.pumpUntil(tester, () => _key('pdf-organiser-page-0').evaluate().isNotEmpty, what: 'the 200-page organiser');
    await _tapKey(tester, 'pdf-organiser-select-all');
    await _tapKey(tester, 'pdf-organiser-rotate');
    await _tapKey(tester, 'pdf-organiser-select-all'); // select none
    await _tapKey(tester, 'pdf-organiser-page-0');
    await _tapKey(tester, 'pdf-organiser-delete');
    before = _ids(store);
    final longSw = Stopwatch()..start();
    await _tapKey(tester, 'pdf-organiser-save');
    await chooseSave('pdf-save-new');
    var cancelled = false;
    await E2eApp.pumpUntil(tester, () => _key('pdf-tool-cancel').hitTestable().evaluate().isNotEmpty || _newEntries(store, before).isNotEmpty,
        what: 'the progress sheet', timeout: const Duration(seconds: 60));
    if (_key('pdf-tool-cancel').hitTestable().evaluate().isNotEmpty) {
      await _tapNow(tester, _key('pdf-tool-cancel'));
    }
    await _settle(tester, 2500);
    FileEntry long;
    if (_newEntries(store, before).isEmpty) {
      cancelled = true;
      expect(_stagingLeft(staging), isEmpty, reason: 'no partial file in staging');
      expect(_key('pdf-organiser-grid'), findsOneWidget, reason: 'Cancel keeps the organiser and its edits');
      _say('cancel: 200-page organise cancelled from the progress sheet; no entry, staging empty');
      before = _ids(store);
      long = await timed('organise 200 pages (rotate all, delete 1)', () async {
        await _tapKey(tester, 'pdf-organiser-save');
        await chooseSave('pdf-save-new');
        return (await _awaitNew(tester, store, before, what: 'the 200-page organise', seconds: 180)).single;
      });
    } else {
      long = (await _awaitNew(tester, store, before, what: 'the 200-page organise')).single;
      timings['organise 200 pages (rotate all, delete 1), incl. the save choice'] = longSw.elapsedMilliseconds;
      _say('NOTE organise cancel: the 200-page save finished (${longSw.elapsedMilliseconds} ms incl. the save choice) before Cancel landed');
      findings.add('200-page organise finished before Cancel landed (cancel evidence from merge and compress)');
    }
    expect(cancelled || long.displayName.contains('(edited)'), isTrue);
    final longOut = await _inspect(_pathOf(store, long));
    expect(longOut.pages, 199);
    expect(longOut.hasTokens(_tokens[_long]!.skip(1)), isTrue, reason: '199 page tokens extractable');
    _say('200-page organise: 199 pages, all tokens extractable');
    await _settle(tester, 800);
    await viewerBack();

    // ---- 3. Replace: Danaview folder file only ----
    final partner = lib[_partner]!;
    final partnerPath = _pathOf(store, partner);
    final partnerBefore = File(partnerPath).readAsBytesSync();
    await openPdf(partner);
    await _tapKey(tester, 'pdf-viewer-organise');
    await E2eApp.pumpUntil(tester, () => _key('pdf-organiser-page-2').evaluate().isNotEmpty, what: 'the organiser');
    await _tapKey(tester, 'pdf-organiser-page-0');
    await _tapKey(tester, 'pdf-organiser-rotate');
    before = _ids(store);
    await _tapKey(tester, 'pdf-organiser-save');
    await chooseSave('pdf-save-replace');
    await E2eApp.pumpUntil(tester, () => find.textContaining('Replaced').evaluate().isNotEmpty, what: 'the Replaced toast', timeout: const Duration(seconds: 60));
    await _settle(tester, 1500);
    final replaced = store.reader.entry(partner.id)!;
    expect(_newEntries(store, before), isEmpty, reason: 'Replace adds no entry');
    expect(replaced.folderId, partner.folderId);
    expect(replaced.displayName, partner.displayName);
    final replacedBytes = File(_pathOf(store, replaced)).readAsBytesSync();
    expect(replacedBytes, isNot(partnerBefore), reason: 'the Danaview folder file was rewritten');
    final repOut = await _inspect(_pathOf(store, replaced));
    expect(repOut.pages, 3);
    final partnerRot = (await _inspect(hostFiles[_partner]!.path)).rotations.first;
    expect(repOut.rotations.first, (partnerRot + 90) % 360, reason: 'page 1 turned in the replaced file');
    expect(repOut.hasTokens(_tokens[_partner]!), isTrue);
    expect(hostFiles[_partner]!.readAsBytesSync(), hostBytes[_partner], reason: 'the host original is untouched');
    _say('Replace (Danaview folder): same entry, name and folder; file rewritten (rotation ${repOut.rotations}); no new entry');
    await E2eApp.screenshot(tester, 's4-08-replaced');
    await viewerBack();
    // A file from outside the library (as a linked-folder PDF): Replace is never offered.
    final outside = ViewerFile(path: hostFiles[_partner]!.path, displayName: _partner, kind: FileKind.document, docKind: DocumentKind.pdf);
    unawaited(openDocumentViewer(appNavigatorKey.currentContext!, c.read, outside));
    await E2eApp.pumpUntil(tester, () => find.textContaining('Page 1 of').evaluate().isNotEmpty, what: 'the outside PDF', timeout: const Duration(seconds: 30));
    await _tapKey(tester, 'pdf-viewer-organise');
    await E2eApp.pumpUntil(tester, () => _key('pdf-organiser-page-2').evaluate().isNotEmpty, what: 'the organiser');
    await _tapKey(tester, 'pdf-organiser-page-2');
    await _tapKey(tester, 'pdf-organiser-delete');
    before = _ids(store);
    await _tapKey(tester, 'pdf-organiser-save');
    final outsideResult = (await _awaitNew(tester, store, before, what: 'the outside result')).single;
    expect(_key('pdf-save-replace'), findsNothing, reason: 'no Replace for a file outside the Danaview folders');
    expect(outsideResult.folderId, store.reader.systemFolder(FolderSystemRole.imported)!.id, reason: 'results of outside files go to Imported');
    expect(hostFiles[_partner]!.readAsBytesSync(), hostBytes[_partner]);
    _say('outside file: no save choice (no Replace), result in Imported, source untouched');
    await _settle(tester, 800);
    await viewerBack();

    // ---- 4. Merge with… ----
    await openPdf(lib[_report]!);
    await viewerMenu('Merge with…');
    await E2eApp.pumpUntil(tester, () => _key('pdf-merge-picker-list').evaluate().isNotEmpty, what: 'the merge picker');
    await E2eApp.screenshot(tester, 's4-09-merge-picker');
    // Scrolls the picker's list to [name] and checks it (the list holds every PDF and photo).
    Future<void> pick(String name) async {
      await E2eApp.pumpUntil(tester, () => _key('pdf-merge-picker-list').evaluate().isNotEmpty, what: 'the picker');
      await _settle(tester, 400);
      final row = find.descendant(of: _key('pdf-merge-picker-list'), matching: find.text(name));
      final list = find.descendant(of: _key('pdf-merge-picker-list'), matching: find.byType(Scrollable)).first;
      await tester.scrollUntilVisible(row, 120, scrollable: list, maxScrolls: 200);
      await _settle(tester, 200);
      await E2eApp.tap(tester, row.first, what: name);
      await _settle(tester, 300);
    }

    await pick(lib[_partner]!.displayName);
    await pick(lib[_photo]!.displayName);
    await E2eApp.hideKeyboard(tester);
    await _tapKey(tester, 'pdf-merge-picker-add');
    await E2eApp.pumpUntil(tester, () => _key('pdf-merge-go').hitTestable().evaluate().isNotEmpty, what: 'the merge screen');
    await E2eApp.screenshot(tester, 's4-10-merge-screen');
    before = _ids(store);
    final merged = await timed('merge report + partner + photo', () async {
      await _tapKey(tester, 'pdf-merge-go');
      return (await _awaitNew(tester, store, before, what: 'the merged file')).single;
    });
    final mergedOut = await _inspect(_pathOf(store, merged));
    expect(merged.displayName, contains('(merged)'));
    expect(mergedOut.pages, 6 + 3 + 1);
    expect(mergedOut.hasTokens([..._tokens[_report]!, ..._tokens[_partner]!]), isTrue, reason: 'merge keeps text');
    _say('merge with…: ${merged.displayName}, ${mergedOut.pages} pages (6 + 3 + photo), text kept');
    _keep('merge', _pathOf(store, merged), {'pages': 10, 'tokens': [..._tokens[_report]!, ..._tokens[_partner]!]});
    await _settle(tester, 800);
    // Cancel a long merge: 200 + 200 + the scan.
    await viewerMenu('Merge with…');
    await E2eApp.pumpUntil(tester, () => _key('pdf-merge-picker-list').evaluate().isNotEmpty, what: 'the merge picker');
    await pick(lib[_long]!.displayName);
    await pick(lib[_scan]!.displayName);
    await E2eApp.hideKeyboard(tester);
    await _tapKey(tester, 'pdf-merge-picker-add');
    await E2eApp.pumpUntil(tester, () => _key('pdf-merge-add').hitTestable().evaluate().isNotEmpty, what: 'the merge screen');
    await _tapKey(tester, 'pdf-merge-add');
    await E2eApp.pumpUntil(tester, () => _key('pdf-merge-picker-list').evaluate().isNotEmpty, what: 'the picker again');
    await pick(lib[_long]!.displayName);
    await E2eApp.hideKeyboard(tester);
    await _tapKey(tester, 'pdf-merge-picker-add');
    before = _ids(store);
    await _tapKey(tester, 'pdf-merge-go');
    cancelled = false;
    await E2eApp.pumpUntil(tester, () => _key('pdf-tool-cancel').hitTestable().evaluate().isNotEmpty || _newEntries(store, before).isNotEmpty,
        what: 'the merge progress', timeout: const Duration(seconds: 30));
    if (_key('pdf-tool-cancel').hitTestable().evaluate().isNotEmpty) {
      await E2eApp.screenshot(tester, 's4-11-merge-progress');
      await _tapNow(tester, _key('pdf-tool-cancel'));
    }
    await _settle(tester, 2500);
    cancelled = _newEntries(store, before).isEmpty;
    if (cancelled) {
      expect(_newEntries(store, before), isEmpty, reason: 'a cancelled merge leaves no file');
      expect(_stagingLeft(staging), isEmpty);
      _say('cancel: 406-page merge cancelled; no entry, staging empty');
    } else {
      findings.add('406-page merge finished before Cancel');
      _say('NOTE merge cancel: finished before Cancel');
    }
    if (_key('pdf-merge-go').hitTestable().evaluate().isNotEmpty) {
      await _tapTooltip(tester, 'Back');
      await _settle(tester, 600);
    }
    await viewerBack();

    // File menu of a PDF: the S4 entries.
    await _tab(tester, HomeTab.documents);
    await _reveal(tester, _entryRow(lib[_form]!.id), what: 'the form row');
    await E2eApp.tap(tester, find.descendant(of: _entryRow(lib[_form]!.id), matching: find.byTooltip('More')).hitTestable(), what: 'More');
    await _tapText(tester, 'More actions…');
    await E2eApp.pumpUntil(tester, () => _key('file-share').evaluate().isNotEmpty, what: 'the file menu');
    final s4Menu = [
      for (final a in [FileAction.organisePages, FileAction.mergeWith, FileAction.compressPdf, FileAction.signPdf])
        if (_key(fileActionId(a)).evaluate().isNotEmpty) fileActionId(a),
    ];
    _say('PDF file menu S4 entries: $s4Menu');
    expect(s4Menu.length, 4, reason: 'Organise pages, Merge with…, Compress…, Sign…');
    await E2eApp.screenshot(tester, 's4-12-file-menu');
    await tester.ensureVisible(_key(fileActionId(FileAction.organisePages)));
    await _tapKey(tester, fileActionId(FileAction.organisePages));
    await E2eApp.pumpUntil(tester, () => _key('pdf-organiser-grid').evaluate().isNotEmpty, what: 'the organiser from the file menu');
    await _tapTooltip(tester, 'Back');
    await _settle(tester, 600);

    // ---- 5. Multi-select Merge into PDF ----
    // Documents rows have no selection; try it and report.
    await _tab(tester, HomeTab.documents);
    await _reveal(tester, _entryRow(lib[_form]!.id), what: 'the form row');
    await _longPress(tester, _entryRow(lib[_form]!.id), what: 'long-press a PDF row');
    await _settle(tester, 600);
    final pdfSelectable = _key('home-selection-bar').evaluate().isNotEmpty;
    if (!pdfSelectable) {
      if (find.byType(DocumentViewer).evaluate().isNotEmpty) await viewerBack();
      finding('Multi-select Merge into PDF: no list lets a PDF be selected (a long-press on a Documents / All row does not start a '
          'selection; only Photos cells do), so the selection bar can only merge photos');
    } else {
      tester.state<NavigatorState>(find.byType(Navigator).last).maybePop();
    }
    await _tab(tester, HomeTab.photos);
    await _longPress(tester, find.byKey(ValueKey<String>(lib[_photo]!.id.value)), what: 'photo cell');
    await E2eApp.waitKey(tester, 'home-selection-bar');
    await E2eApp.tap(tester, find.byKey(ValueKey<String>(lib[_sigPhoto]!.id.value)).hitTestable().first, what: 'second photo');
    await _settle(tester);
    await E2eApp.screenshot(tester, 's4-13-selection-merge');
    expect(_key('selection-action-file-merge-pdf'), findsOneWidget, reason: 'Merge into PDF in the selection bar (S4-W fix)');
    await _tapKey(tester, 'selection-action-file-merge-pdf');
    await E2eApp.pumpUntil(tester, () => _key('pdf-merge-go').hitTestable().evaluate().isNotEmpty, what: 'the merge screen');
    await _tapKey(tester, 'pdf-merge-add');
    await E2eApp.pumpUntil(tester, () => _key('pdf-merge-picker-list').evaluate().isNotEmpty, what: 'the picker');
    await pick(lib[_form]!.displayName);
    await E2eApp.hideKeyboard(tester);
    await _tapKey(tester, 'pdf-merge-picker-add');
    before = _ids(store);
    final multi = await timed('merge 2 photos + a PDF (selection bar)', () async {
      await _tapKey(tester, 'pdf-merge-go');
      return (await _awaitNew(tester, store, before, what: 'the merged photos')).single;
    });
    final multiOut = await _inspect(_pathOf(store, multi));
    expect(multiOut.pages, 2 + 2);
    expect(multiOut.hasTokens(_tokens[_form]!), isTrue);
    _say('selection bar Merge into PDF: ${multi.displayName}, ${multiOut.pages} pages (2 photos + the form), text kept');
    _keep('merge_photos', _pathOf(store, multi), {'pages': 4, 'tokens': _tokens[_form]});
    await _settle(tester, 800);

    // ---- 6. Compress… ----
    await openPdf(lib[_scan]!);
    final compressSizes = <String, String>{};
    for (final preset in PdfCompressPreset.values) {
      await viewerMenu('Compress…');
      await E2eApp.pumpUntil(tester, () => _key('compress-run').hitTestable().evaluate().isNotEmpty, what: 'the compress sheet');
      await _tapKey(tester, 'compress-preset-${preset.name}');
      await _settle(tester, 1500);
      if (preset == PdfCompressPreset.high) await E2eApp.screenshot(tester, 's4-14-compress-sheet');
      before = _ids(store);
      final sw = Stopwatch()..start();
      await _tapKey(tester, 'compress-run');
      await E2eApp.pumpUntil(tester, () => _key('compress-done').evaluate().isNotEmpty || _key('compress-not-smaller').evaluate().isNotEmpty || _key('compress-error').evaluate().isNotEmpty,
          what: 'compress ${preset.name}', timeout: const Duration(seconds: 120));
      sw.stop();
      if (_key('compress-done').evaluate().isNotEmpty) {
        final out = (await _awaitNew(tester, store, before, what: 'the compressed file')).single;
        final size = File(_pathOf(store, out)).lengthSync();
        compressSizes['scan ${preset.name}'] = '${hostBytes[_scan]!.length} → $size B, ${sw.elapsedMilliseconds} ms';
        expect(size, lessThan(hostBytes[_scan]!.length));
        expect((await _inspect(_pathOf(store, out))).pages, 4);
        if (preset == PdfCompressPreset.small) await E2eApp.screenshot(tester, 's4-15-compress-done');
        _keep('compress_scan_${preset.name}', _pathOf(store, out), {'pages': 4, 'maxBytes': hostBytes[_scan]!.length});
      } else {
        compressSizes['scan ${preset.name}'] = _key('compress-not-smaller').evaluate().isNotEmpty ? 'not smaller' : 'error';
        finding('Compress ${preset.name} on the phone scan did not produce a smaller file (${compressSizes['scan ${preset.name}']})',
            block: preset != PdfCompressPreset.high);
      }
      await _tapKey(tester, _key('compress-close').evaluate().isNotEmpty ? 'compress-close' : 'compress-again');
      await _settle(tester, 600);
      if (find.text('Compress PDF').evaluate().isNotEmpty) {
        tester.state<NavigatorState>(find.byType(Navigator).last).maybePop();
        await _settle(tester, 600);
      }
    }
    // Cancel.
    await viewerMenu('Compress…');
    await E2eApp.pumpUntil(tester, () => _key('compress-run').hitTestable().evaluate().isNotEmpty, what: 'the compress sheet');
    await _tapKey(tester, 'compress-preset-small');
    before = _ids(store);
    await _tapKey(tester, 'compress-run');
    await E2eApp.pumpUntil(tester, () => _key('compress-cancel').hitTestable().evaluate().isNotEmpty || _key('compress-done').evaluate().isNotEmpty,
        what: 'compress progress');
    if (_key('compress-cancel').hitTestable().evaluate().isNotEmpty) {
      await E2eApp.screenshot(tester, 's4-16-compress-progress');
      await _tapNow(tester, _key('compress-cancel'));
      await _settle(tester, 2500);
      if (_newEntries(store, before).isEmpty) {
        expect(_stagingLeft(staging), isEmpty);
        _say('cancel: compress (small, phone scan) cancelled; no entry');
      } else {
        findings.add('compress finished before Cancel landed');
        _say('NOTE compress cancel: finished before Cancel landed');
      }
    } else {
      findings.add('compress finished before Cancel');
    }
    if (_key('compress-close').hitTestable().evaluate().isNotEmpty) {
      await _tapKey(tester, 'compress-close');
      await _settle(tester, 600);
    }
    if (find.text('Compress PDF').evaluate().isNotEmpty) {
      tester.state<NavigatorState>(find.byType(Navigator).last).maybePop();
      await _settle(tester, 600);
    }
    await viewerBack();
    // The report (picture + text), the 200-page file and the tiny partner ("not smaller").
    for (final n in [_report, _long, _partner]) {
      await openPdf(n == _partner ? store.reader.entry(lib[_partner]!.id)! : lib[n]!);
      await viewerMenu('Compress…');
      await E2eApp.pumpUntil(tester, () => _key('compress-run').hitTestable().evaluate().isNotEmpty, what: 'the compress sheet');
      await _tapKey(tester, 'compress-preset-medium');
      await _settle(tester, 1000);
      before = _ids(store);
      final sw = Stopwatch()..start();
      await _tapKey(tester, 'compress-run');
      await E2eApp.pumpUntil(tester, () => _key('compress-done').evaluate().isNotEmpty || _key('compress-not-smaller').evaluate().isNotEmpty || _key('compress-error').evaluate().isNotEmpty,
          what: 'compress $n', timeout: const Duration(seconds: 180));
      sw.stop();
      final inSize = File(_pathOf(store, store.reader.entry(lib[n]!.id)!)).lengthSync();
      if (_key('compress-done').evaluate().isNotEmpty) {
        final out = (await _awaitNew(tester, store, before, what: 'the compressed $n')).single;
        final size = File(_pathOf(store, out)).lengthSync();
        final o = await _inspect(_pathOf(store, out));
        compressSizes['$n medium'] = '$inSize → $size B, ${sw.elapsedMilliseconds} ms';
        expect(o.hasTokens(n == _partner ? _tokens[_partner]! : _tokens[n]!), isTrue, reason: 'compress keeps text ($n)');
        _keep('compress_${n.split('.').first}', _pathOf(store, out), {'tokens': _tokens[n], 'maxBytes': inSize});
      } else if (_key('compress-not-smaller').evaluate().isNotEmpty) {
        await _settle(tester, 800);
        expect(_newEntries(store, before), isEmpty, reason: 'not smaller: nothing saved');
        compressSizes['$n medium'] = 'not smaller (no file), ${sw.elapsedMilliseconds} ms';
        if (n == _partner) await E2eApp.screenshot(tester, 's4-17-compress-not-smaller');
      } else {
        compressSizes['$n medium'] = 'error';
        finding('Compress medium failed on $n');
      }
      await _tapKey(tester, _key('compress-close').evaluate().isNotEmpty ? 'compress-close' : 'compress-again');
      await _settle(tester, 600);
      if (find.text('Compress PDF').evaluate().isNotEmpty) {
        tester.state<NavigatorState>(find.byType(Navigator).last).maybePop();
        await _settle(tester, 600);
      }
      await viewerBack();
    }
    for (final e in compressSizes.entries) {
      _say('compress ${e.key}: ${e.value}');
    }
    // The 11 KB (replaced) partner: "not smaller", or a copy saved for a few bytes (reported).
    _say('compress of a small text PDF: ${compressSizes['s4_partner.pdf medium']}');

    // ---- 7. Annotate ----
    await openPdf(lib[_form]!);
    final view = world.view;
    final hits = <PdfSearchHit>[];
    for (final q in ['S4QF-P0001', 'S4QF-P0002']) {
      final r = await view.search(q);
      hits.add(r.hits.first);
    }
    final body = await view.search('application');
    _say('annotate: real search hits for line rects: ${[for (final h in hits) 'p${h.pageIndex} ${h.bounds.width.toStringAsFixed(0)}x${h.bounds.height.toStringAsFixed(0)}']}');
    await view.clearSearch();
    await _tapKey(tester, 'pdf-viewer-annotate');
    await E2eApp.pumpUntil(tester, () => _key('pdf-annotate-toolbar').evaluate().isNotEmpty, what: 'the annotate toolbar');
    await E2eApp.screenshot(tester, 's4-18-annotate');
    final vid = view.viewId;
    Future<void> mark(String key, PdfSearchHit hit) async {
      world.annotate.selection = [PdfPageRects(hit.pageIndex, [hit.bounds])];
      await view.select(true);
      await _settle(tester, 300);
      await _tapKey(tester, key);
      await _settle(tester, 300);
      world.annotate.selection = null;
      await view.select(false);
    }

    await mark('pdf-annotate-highlight', hits[0]);
    await _tapKey(tester, 'pdf-annotate-markup-color-${0xFF34C759.toRadixString(16)}');
    await mark('pdf-annotate-underline', hits[1]);
    await mark('pdf-annotate-strike', body.hits.isNotEmpty ? body.hits.first : hits[0]);
    // Ink, in red and bold.
    await _tapKey(tester, 'pdf-annotate-tool-pen');
    await _tapKey(tester, 'pdf-annotate-pen-color-${0xFFE53935.toRadixString(16)}');
    await _tapKey(tester, 'pdf-annotate-width-2');
    world.annotate.emit(PdfInkStrokeEvent(vid, 0, [for (var i = 0; i <= 20; i++) Offset(80 + i * 12.0, 300 + (i.isEven ? 0 : 18))]));
    await _settle(tester, 400);
    world.annotate.emit(PdfInkStrokeEvent(vid, 1, [for (var i = 0; i <= 10; i++) Offset(100 + i * 20.0, 500 - i * 6.0)]));
    await _settle(tester, 400);
    // A text box.
    await _tapKey(tester, 'pdf-annotate-tool-text');
    world.annotate.emit(PdfAnnotateTapEvent(vid, 0, const Offset(320, 420), null));
    await E2eApp.pumpUntil(tester, () => find.text('Add text').evaluate().isNotEmpty, what: 'the text prompt');
    await _enter(tester, 'S4QA note text');
    await _tapText(tester, 'Add');
    await _settle(tester, 400);
    var items = world.annotate.shown;
    final kinds = [for (final i in items) i.annotation?.kind.name];
    _say('annotate items after highlight/underline/strike/ink×2/text: $kinds');
    expect(items.length, 6);
    // Eraser removes the second ink stroke; Undo brings it back; Redo removes it again; Undo.
    final ink2 = items.lastWhere((i) => i.annotation?.kind == PdfAnnotationKind.ink);
    await _tapKey(tester, 'pdf-annotate-tool-eraser');
    world.annotate.emit(PdfAnnotateTapEvent(vid, 1, const Offset(150, 490), ink2.id));
    await _settle(tester, 400);
    expect(world.annotate.shown.length, 5, reason: 'the eraser removed a stroke');
    await _tapKey(tester, 'pdf-annotate-undo');
    await _settle(tester, 300);
    expect(world.annotate.shown.length, 6, reason: 'Undo');
    await _tapKey(tester, 'pdf-annotate-redo');
    await _settle(tester, 300);
    expect(world.annotate.shown.length, 5, reason: 'Redo');
    await _tapKey(tester, 'pdf-annotate-undo');
    await _settle(tester, 300);
    // Select the text box and delete it, then Undo.
    await _tapKey(tester, 'pdf-annotate-tool-select');
    final textBox = world.annotate.shown.firstWhere((i) => i.annotation?.kind == PdfAnnotationKind.freeText);
    world.annotate.emit(PdfAnnotateTapEvent(vid, 0, const Offset(330, 430), textBox.id));
    await E2eApp.pumpUntil(tester, () => _key('pdf-annotate-delete').evaluate().isNotEmpty, what: 'Delete for the selected mark');
    await E2eApp.screenshot(tester, 's4-19-annotate-selected');
    await _tapKey(tester, 'pdf-annotate-delete');
    await _settle(tester, 300);
    expect(world.annotate.shown.length, 5);
    await _tapKey(tester, 'pdf-annotate-undo');
    await _settle(tester, 300);
    expect(world.annotate.shown.length, 6);
    // The discard prompt: Cancel keeps the marks.
    await _tapTooltip(tester, 'Back');
    await E2eApp.pumpUntil(tester, () => find.text('Discard annotations?').evaluate().isNotEmpty, what: 'the discard prompt');
    await E2eApp.screenshot(tester, 's4-20-annotate-discard');
    await _tapText(tester, 'Cancel');
    await _settle(tester);
    expect(_key('pdf-annotate-toolbar'), findsOneWidget, reason: 'Cancel keeps annotating');
    before = _ids(store);
    final annotated = await timed('annotate save (6 marks)', () async {
      await _tapKey(tester, 'pdf-annotate-save');
      await chooseSave('pdf-save-new');
      return (await _awaitNew(tester, store, before, what: 'the annotated copy')).single;
    });
    final annOut = await _inspect(_pathOf(store, annotated));
    _say('annotate: ${annotated.displayName}; objects ${annOut.subtypes}');
    for (final k in ['Highlight', 'Underline', 'StrikeOut', 'Ink', 'FreeText']) {
      expect(annOut.subtypes[k] ?? 0, greaterThanOrEqualTo(1), reason: '$k annotation written');
    }
    expect(annOut.subtypes['Ink'] ?? 0, greaterThanOrEqualTo(2), reason: 'two ink strokes');
    expect(annOut.subtypes['Field'] ?? 0, formBefore.subtypes['Field'] ?? 0, reason: 'the form fields survive');
    expect(annOut.subtypes['Highlight']!, greaterThan(formBefore.subtypes['Highlight'] ?? 0), reason: 'existing + new highlights');
    expect(annOut.hasTokens(_tokens[_form]!), isTrue, reason: 'text stays selectable after annotate');
    _keep('annotate', _pathOf(store, annotated), {'pages': 2, 'tokens': _tokens[_form], 'annots': ['Highlight', 'Underline', 'StrikeOut', 'Ink', 'FreeText', 'Widget']});
    await _settle(tester, 800);
    // Discard: a mark, Back, Discard, no file.
    await _tapKey(tester, 'pdf-viewer-annotate');
    await _tapKey(tester, 'pdf-annotate-tool-pen');
    world.annotate.emit(PdfInkStrokeEvent(vid, 0, const [Offset(50, 50), Offset(150, 80), Offset(250, 60)]));
    await _settle(tester, 400);
    before = _ids(store);
    await _tapTooltip(tester, 'Back');
    await _tapText(tester, 'Discard');
    await _settle(tester, 800);
    expect(_key('pdf-annotate-toolbar'), findsNothing);
    expect(_newEntries(store, before), isEmpty, reason: 'Discard saves nothing');
    _say('annotate: discard prompt (Cancel keeps, Discard leaves without a file)');
    await viewerBack();

    // ---- 8. Sign ----
    await openPdf(lib[_report]!);
    final sview = world.view;
    await _tapKey(tester, 'pdf-viewer-sign');
    await E2eApp.pumpUntil(tester, () => _key('signature-pad').evaluate().isNotEmpty, what: 'New signature (none saved yet)');
    await E2eApp.screenshot(tester, 's4-21-new-signature');
    // Draw.
    final pad = tester.getRect(_key('signature-pad'));
    final g = await tester.startGesture(pad.centerLeft + const Offset(30, 0));
    for (var i = 1; i <= 24; i++) {
      await g.moveTo(pad.centerLeft + Offset(30 + i * (pad.width - 60) / 24, (i.isEven ? -1 : 1) * pad.height * 0.25));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await _settle(tester, 300);
    await _tapKey(tester, 'signature-create-save');
    await E2eApp.pumpUntil(tester, () => _key('signature-pad').evaluate().isEmpty, what: 'the sheet to close');
    await _settle(tester, 600);
    final sid = sview.viewId;
    Future<String> place(int page, Offset at) async {
      final n = world.annotate.shown.length;
      world.annotate.emit(PdfAnnotateTapEvent(sid, page, at, null));
      await E2eApp.pumpUntil(tester, () => world.annotate.shown.length > n, what: 'the stamp on page ${page + 1}');
      await _settle(tester, 300);
      return world.annotate.shown.last.id;
    }

    final s1 = await place(0, const Offset(360, 700));
    // Move and resize it (what dragging the stamp or its corner sends).
    world.annotate.emit(PdfStampMovedEvent(sid, 0, s1, const PdfRect(330, 690, 220, 80)));
    await _settle(tester, 400);
    final moved = world.annotate.shown.firstWhere((i) => i.id == s1).stamp!.rect;
    expect([moved.x, moved.y, moved.width, moved.height], [330, 690, 220, 80], reason: 'move + resize applied');
    // Type.
    await _tapKey(tester, 'sign-new-signature');
    await _tapText(tester, 'Type');
    await tester.enterText(_key('signature-type-name').hitTestable(), 'Masud Q');
    await tester.pump();
    await E2eApp.hideKeyboard(tester);
    await _tapKey(tester, 'signature-type-font-1');
    await E2eApp.screenshot(tester, 's4-22-type-signature');
    await _tapKey(tester, 'signature-create-save');
    await E2eApp.pumpUntil(tester, () => _key('signature-type-name').evaluate().isEmpty, what: 'the sheet to close');
    await _settle(tester, 600);
    await sview.goToPage(1);
    final s2 = await place(1, const Offset(80, 720));
    // Import.
    await _tapKey(tester, 'sign-new-signature');
    await _tapText(tester, 'Import');
    await _tapKey(tester, 'signature-import-pick');
    await E2eApp.pumpUntil(tester, () => _key('signature-import-preview').evaluate().isNotEmpty, what: 'the imported preview', timeout: const Duration(seconds: 30));
    await E2eApp.screenshot(tester, 's4-23-import-signature');
    await _tapKey(tester, 'signature-create-save');
    await E2eApp.pumpUntil(tester, () => _key('signature-import-preview').evaluate().isEmpty, what: 'the sheet to close');
    await _settle(tester, 600);
    await sview.goToPage(4);
    final s3 = await place(4, const Offset(300, 150));
    _say('sign: placed drawn (p1, moved/resized), typed (p2), imported (p5): ${[s1, s2, s3].length} stamps');
    // Select the typed one, delete it, Undo.
    world.annotate.emit(PdfAnnotateTapEvent(sid, 1, const Offset(90, 730), s2));
    await E2eApp.pumpUntil(tester, () => _key('pdf-sign-delete').evaluate().isNotEmpty, what: 'Delete for the selected signature');
    await E2eApp.screenshot(tester, 's4-24-sign-selected');
    await _tapKey(tester, 'pdf-sign-delete');
    await _settle(tester, 300);
    expect(world.annotate.shown.length, 2);
    await _tapKey(tester, 'pdf-sign-undo');
    await _settle(tester, 300);
    expect(world.annotate.shown.length, 3);
    final stamps = [for (final i in world.annotate.shown) i.stamp!];
    final saved = await sigStore.list();
    expect(saved.length, 3, reason: 'drawn, typed and imported signatures saved');
    expect(saved.map((s) => s.kind).toSet(), {SignatureKind.drawn, SignatureKind.typed, SignatureKind.imported});
    before = _ids(store);
    final signed = await timed('sign save (3 stamps, burn-in)', () async {
      await _tapKey(tester, 'pdf-sign-save');
      await chooseSave('pdf-save-new');
      return (await _awaitNew(tester, store, before, what: 'the signed copy')).single;
    });
    expect(world.annotate.saves.last, 'burn-in 3 stamps');
    final signOut = await _inspect(_pathOf(store, signed));
    final reportIn = await _inspect(_pathOf(store, lib[_report]!));
    _say('sign: ${signed.displayName}; objects ${signOut.subtypes}; images ${reportIn.images} → ${signOut.images}');
    expect(signOut.pages, 6);
    expect(signOut.subtypes['Stamp'] ?? 0, 0, reason: 'burned in, not a stamp annotation');
    expect(signOut.images, greaterThan(reportIn.images), reason: 'the signatures are page content');
    expect(signOut.hasTokens(_tokens[_report]!), isTrue, reason: 'text stays selectable after sign');
    _keep('sign', _pathOf(store, signed), {
      'pages': 6,
      'tokens': _tokens[_report],
      'noAnnots': ['Stamp'],
      'stamps': [for (final s in stamps) {'page': s.pageIndex, 'x': s.rect.x, 'y': s.rect.y, 'w': s.rect.width, 'h': s.rect.height}],
    });
    await _settle(tester, 800);
    await viewerBack();

    // ---- 9. Password PDF: encrypted in, encrypted out ----
    await openPdf(lib[_locked]!, password: _password);
    await E2eApp.screenshot(tester, 's4-25-locked-unlocked');
    await _tapKey(tester, 'pdf-viewer-organise');
    await E2eApp.pumpUntil(tester, () => _key('pdf-organiser-page-2').evaluate().isNotEmpty, what: 'the organiser (unlocked)');
    await _tapKey(tester, 'pdf-organiser-page-2');
    await _tapKey(tester, 'pdf-organiser-delete');
    before = _ids(store);
    await _tapKey(tester, 'pdf-organiser-save');
    await chooseSave('pdf-save-new');
    final lockedOrg = (await _awaitNew(tester, store, before, what: 'the organised locked copy')).single;
    final lockedProbe = await PlatformPdfDocuments().probe(_pathOf(store, lockedOrg));
    final lockedNoPw = await PlatformPdfDocuments().open(_pathOf(store, lockedOrg));
    await PlatformPdfDocuments().close(lockedNoPw.handle);
    final lockedOut = await _inspect(_pathOf(store, lockedOrg), password: _password);
    expect(lockedProbe.encrypted, isTrue, reason: 'organise of an encrypted PDF is encrypted');
    expect(lockedNoPw.locked, isTrue, reason: 'it needs the password');
    expect(lockedOut.pages, 2);
    expect(lockedOut.hasTokens(['S4QL-P0001', 'S4QL-P0002']), isTrue);
    _keep('locked_organise', _pathOf(store, lockedOrg), {'pages': 2, 'password': _password, 'encrypted': true, 'tokens': ['S4QL-P0001', 'S4QL-P0002']});
    _say('password PDF: organise output encrypted (locked without the password, opens with it, text kept)');
    await _settle(tester, 800);
    // Compress the unlocked PDF.
    await viewerMenu('Compress…');
    await E2eApp.pumpUntil(tester, () => _key('compress-run').hitTestable().evaluate().isNotEmpty, what: 'the compress sheet');
    await _tapKey(tester, 'compress-preset-small');
    before = _ids(store);
    await _tapKey(tester, 'compress-run');
    await E2eApp.pumpUntil(tester, () => _key('compress-done').evaluate().isNotEmpty || _key('compress-not-smaller').evaluate().isNotEmpty || _key('compress-error').evaluate().isNotEmpty,
        what: 'compress (locked)', timeout: const Duration(seconds: 90));
    if (_key('compress-done').evaluate().isNotEmpty) {
      final out = (await _awaitNew(tester, store, before, what: 'the compressed locked copy')).single;
      final p = await PlatformPdfDocuments().probe(_pathOf(store, out));
      expect(p.encrypted, isTrue, reason: 'compress of an encrypted PDF is encrypted');
      _say('password PDF: compress output encrypted');
    } else {
      _say('password PDF: compress said ${_key('compress-not-smaller').evaluate().isNotEmpty ? 'not smaller (no file)' : 'error'}');
      if (_key('compress-error').evaluate().isNotEmpty) finding('Compress failed on the unlocked password PDF');
    }
    await _tapKey(tester, _key('compress-close').evaluate().isNotEmpty ? 'compress-close' : 'compress-again');
    await _settle(tester, 600);
    if (find.text('Compress PDF').evaluate().isNotEmpty) {
      tester.state<NavigatorState>(find.byType(Navigator).last).maybePop();
      await _settle(tester, 600);
    }
    // Merge the unlocked PDF with the partner: the first encrypted input's password.
    await viewerMenu('Merge with…');
    await E2eApp.pumpUntil(tester, () => _key('pdf-merge-picker-list').evaluate().isNotEmpty, what: 'the merge picker');
    await pick(store.reader.entry(lib[_partner]!.id)!.displayName);
    await E2eApp.hideKeyboard(tester);
    await _tapKey(tester, 'pdf-merge-picker-add');
    before = _ids(store);
    await _tapKey(tester, 'pdf-merge-go');
    final lockedMerge = (await _awaitNew(tester, store, before, what: 'the merged locked copy')).single;
    final lmProbe = await PlatformPdfDocuments().probe(_pathOf(store, lockedMerge));
    expect(lmProbe.encrypted, isTrue, reason: 'merge with an encrypted input is encrypted');
    final lmOut = await _inspect(_pathOf(store, lockedMerge), password: _password);
    expect(lmOut.pages, 6);
    _keep('locked_merge', _pathOf(store, lockedMerge), {'pages': 6, 'password': _password, 'encrypted': true});
    _say('password PDF: merge output encrypted with the first encrypted input\'s password, 6 pages');
    await _settle(tester, 800);
    await viewerBack();

    // ---- 10. Saved signatures: app-private, backup-excluded, persistent, Settings › Privacy ----
    final sigDir = Directory(SignatureStore.signaturesPathIn(dirs.support));
    expect(sigDir.existsSync(), isTrue);
    expect(sigDir.path.contains('/Library/Application Support/'), isTrue, reason: 'app-private (not Documents)');
    final libRoot = store.paths.root;
    expect(sigDir.path.startsWith(libRoot), isFalse, reason: 'not in the Danaview folders');
    final flags = NativeBackupFlags();
    final dirExcluded = await flags.isExcludedFromBackup(sigDir.path);
    final fileFlags = [for (final s in await sigStore.list()) await flags.isExcludedFromBackup(s.path)];
    _say('signatures: ${sigDir.listSync().length} files in <app support>/signatures; isExcludedFromBackup dir $dirExcluded, files $fileFlags');
    expect(dirExcluded, isTrue, reason: 'the signatures folder is excluded from backups');
    // Reopen the app's world (library, providers, store) from disk.
    await world.close(tester);
    await world.launch(tester);
    store = world.store;
    c = ProviderScope.containerOf(tester.element(find.byType(DanaviewApp)), listen: false);
    final again = await c.read(signatureStoreProvider)!.list();
    expect(again.length, 3, reason: 'saved signatures survive a restart');
    expect(await flags.isExcludedFromBackup(sigDir.path), isTrue);
    _say('signatures persist across the app restart (3), still backup-excluded');
    unawaited(GoRouter.of(appNavigatorKey.currentContext!).push('/settings'));
    await E2eApp.pumpUntil(tester, () => find.byType(DanaviewSettingsScreen).evaluate().isNotEmpty, what: 'Settings');
    await _settle(tester, 800);
    await _reveal(tester, _key('privacy-saved-signatures'), what: 'the saved signatures row');
    await E2eApp.pumpUntil(tester, () => find.textContaining('3 saved on this device').evaluate().isNotEmpty, what: 'the count');
    await E2eApp.screenshot(tester, 's4-26-settings-signatures');
    await _reveal(tester, _key('privacy-saved-signatures-delete-all'), what: 'Delete all');
    await _tapKey(tester, 'privacy-saved-signatures-delete-all');
    await E2eApp.pumpUntil(tester, () => find.text('Delete all saved signatures?').evaluate().isNotEmpty, what: 'the confirm');
    await E2eApp.tap(tester, find.text('Delete all').hitTestable().last, what: 'Delete all');
    await E2eApp.pumpUntil(tester, () => find.textContaining('None saved').evaluate().isNotEmpty, what: 'None saved');
    await E2eApp.screenshot(tester, 's4-27-settings-deleted');
    expect(await c.read(signatureStoreProvider)!.list(), isEmpty);
    expect(sigDir.existsSync() ? sigDir.listSync().whereType<File>().where((f) => f.path.endsWith('.png')).length : 0, 0, reason: 'files deleted');
    _say('Settings › Privacy: "3 saved on this device" → Delete all → "None saved", PNGs deleted');
    appNavigatorKey.currentState!.maybePop();
    await _settle(tester, 600);

    // ---- 11. Originals, staging, network ----
    for (final n in _imports) {
      expect(hostFiles[n]!.readAsBytesSync(), hostBytes[n], reason: 'host $n bytes unchanged');
      expect(hostFiles[n]!.lastModifiedSync(), hostTimes[n], reason: 'host $n timestamp unchanged');
      if (n == _partner) continue; // replaced on purpose (§3)
      final e = store.reader.entry(lib[n]!.id)!;
      final f = File(_pathOf(store, e));
      expect(_sha(f.readAsBytesSync()), _sha(libBytes[n]!), reason: 'library $n bytes unchanged by every tool');
      expect(f.lastModifiedSync(), libTimes[n], reason: 'library $n timestamp unchanged');
    }
    _say('originals: ${_imports.length} host files and ${_imports.length - 1} library files unchanged (bytes and timestamps); the partner was replaced on purpose');
    expect(_stagingLeft(staging), isEmpty, reason: 'nothing left in the tools staging folder');
    _say('staging: nothing left in ${pdfToolsStagingIn('<import staging>')}');
    for (final e in timings.entries) {
      _say('timing ${e.key}: ${e.value} ms');
    }
    expect(spy.created, isEmpty, reason: 'S4 adds no host: ${spy.created}');
    _say('network: no HttpClient created');
    _say('findings (non-blocking): $findings');
    await world.close(tester);
    expect(blocking, isEmpty, reason: blocking.join('\n'));
  });
}

Future<List<FileEntry>> _awaitNewAfterTap(WidgetTester tester, LibraryStore store, Set<EntryId> before, String key, {int count = 1}) async {
  await _tapKey(tester, key);
  return _awaitNew(tester, store, before, count: count, what: 'the results of $key');
}
