// OWNER: S3-Q
//
// S3 Documents stress probe (BUILD_PLAN v1.2 §1A, S3-Q: the slice's share of HOM-14 and HOM-32 for
// the Documents surfaces; ARCH v1.2 §10.1 Home budgets). HOM-14 owns the 50,000-item and
// 10,000-document runs on the device lab and HOM-32 the device timings; this file is S3-Q's interim
// evidence for the Documents tab, its sub-filters, the name search and the bounded linked-folder
// walk, and does not replace them.
//
// With DANAVIEW_FILES_HOME=true, on the real S2 + S3 wiring (`filesHomeOverrides` with
// `documentsOverrides`: HOM-17 store on its isolate writer, HOM-04 thumbnails, PDFKit first-page
// thumbnails) on the iOS Simulator:
//
//   1. a Danaview-folder library of N files (default 10,000: 70 % documents across every sub-filter
//      kind, 30 % photos) is generated through the import path (part file + commit) from the local
//      S3 documents (make_s3_docs.sh): most in one big folder, the rest over 20 folders;
//   2. three linked roots are generated in the app's temporary directory and walked exactly as the
//      Documents tab does (`walkLinkedDocuments` in `Isolate.run`), timed with RSS:
//        * "depth": a chain of 11 folders (depths 0..10) with one document each: only depths 0..8
//          may be listed (linkedDocumentDepth 8);
//        * "wide": 2,300 empty folders at depth 1, 10 documents at depth 0 and 50 at depth 2: the
//          folder budget (2,000 per root) ends the walk before depth 2, so exactly 10 come back;
//        * "big": 2,171 folders up to depth 9, 2 documents + 1 photo + 1 hidden file in each, and
//          1,200 documents in one folder (5,540 documents): the document budget (5,000 in all)
//          ends the walk, so the three roots give exactly 5,000;
//      the walked list is handed to the Documents tab (`linkedDocumentsProvider`), so the tab holds
//      the generated Danaview documents and 5,000 linked rows;
//   3. on the Documents tab with every sub-filter (All documents, PDF, Word, Excel, PowerPoint,
//      Text/CSV, Other) a fling script (3 flings down, 2 up) runs with the binding fully live, plus
//      the drag script (8 slow drags) on All documents; every FrameTiming is recorded, plus RSS
//      and the HOM-04 cache; the first frame after each chip tap is timed;
//   4. name search over the generated library: the index load, then each query 5 times through the
//      search controller (every kind and documents only), and once typed into the Home search
//      field (keystroke to the match count on screen, 60 ms debounce included);
//   5. the generated folder is deleted, Recently deleted emptied and the linked roots removed (the
//      library is left as found; Empty also purges anything else in the simulator's Recently
//      deleted).
//
// The simulator runs a debug (JIT) build only: Flutter has no profile mode on the iOS Simulator, so
// the frame numbers are debug-mode indications, not the §10.1 verdict (HOM-14 / QA-104 on the
// device lab). The walk and search timings and the memory numbers are less mode-dependent.
//
// Run: integration_test/v12/s3/tool/make_s3_docs.sh
//      DV_E2E_EXTRA_DEFINES="DANAVIEW_FILES_HOME=true DV_S3_DOCS=$PWD/build/e2e/s3_docs [DV_S3_STRESS_N=10000]" \
//        scripts/ci/editor/e2e_ios.sh --target integration_test/v12/s3/s3_documents_stress_test.dart iphone
//
// Rule 30: nothing here prints a file name, a path or document text; the reports carry counts,
// timings and the probe's own synthetic search queries only.

// ignore_for_file: avoid_print, implementation_imports, depend_on_referenced_packages

import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:danaview/app.dart';
import 'package:danaview/wiring/documents_wiring.dart';
import 'package:danaview/wiring/files_home_wiring.dart';
import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_engine/danaview_engine.dart';
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_features/src/flags.dart';
import 'package:danaview_features/src/library/filters/filter_providers.dart' show linkedDocumentsProvider;
import 'package:danaview_features/src/library/filters/library_filters.dart' show documentSubFilters;
import 'package:danaview_features/src/library/search/name_search_controller.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_platform/danaview_platform.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../editor/support/e2e.dart';

const String _docsDir = String.fromEnvironment('DV_S3_DOCS');
const int _n = int.fromEnvironment('DV_S3_STRESS_N', defaultValue: 10000);
const String _rootName = 'S3 Stress';

/// ARCH §10.1: ≤ 8 ms build+raster per frame at 60 Hz; "jank" is a frame over 2 × the 16.7 ms
/// frame interval.
const int _budgetUs = 8000;
const int _jankUs = 33400;

void _report(String line) => print('DV_E2E_REPORT s3-stress: $line');

/// The sample bytes of one kind of generated file (sendable to the writer isolate).
final class _Samples {
  const _Samples({required this.pdf, required this.office, required this.photo, required this.zip});

  final Uint8List pdf;
  final Uint8List office;
  final Uint8List photo;
  final Uint8List zip;
}

/// The seed of one write chunk (sendable to the writer isolate).
final class _Chunk {
  const _Chunk(this.start, this.count, this.bulk, this.small, this.samples);

  final int start;
  final int count;
  final FolderId bulk;
  final List<FolderId> small;
  final _Samples samples;
}

/// The generated name and bytes of file [i]: 30 % photos, 70 % documents over every sub-filter.
(String, List<int>, EntryMeta) _file(int i, _Samples s, DateTime when) {
  final n = i.toString().padLeft(5, '0');
  switch (i % 10) {
    case < 3:
      return ('IMG_$n.jpg', s.photo, EntryMeta(width: 1200, height: 800, takenAt: when));
    case 3:
      return ('Quarterly report $n.pdf', s.pdf, const EntryMeta(pageCount: 2));
    case 4:
      return ('Brief $n.docx', s.office, const EntryMeta());
    case 5:
      return ('Budget $n.xlsx', s.office, const EntryMeta());
    case 6:
      return ('Slides $n.pptx', s.office, const EntryMeta());
    case 7:
      return ('Notes $n.txt', 'Danaview S3 stress note $i\n'.codeUnits, const EntryMeta());
    case 8:
      return ('Table $n.csv', 'id,value\n$i,${i * 3}\n'.codeUnits, const EntryMeta());
    default:
      return ('Archive $n.zip', s.zip, const EntryMeta());
  }
}

int _seedChunk(LibraryWriter w, DateTime now, _Chunk c) {
  final base = DateTime.utc(2024, 1, 1);
  for (var i = c.start; i < c.start + c.count; i++) {
    final folder = i % 5 == 0 ? c.small[(i ~/ 5) % c.small.length] : c.bulk;
    final when = base.add(Duration(minutes: i * 97));
    final (name, bytes, meta) = _file(i, c.samples, when);
    final job = w.beginImport(target: folder, bytesTotal: bytes.length, now: now);
    final part = w.fs.openPart(job.id);
    part.writeFromSync(bytes);
    part.closeSync();
    final cls = classify(fileName: name);
    w.commitImport(job.id, ImportedFileInfo(displayName: name, kind: cls.kind, subKind: cls.subKind, modifiedAt: when, meta: meta), now: now);
  }
  return c.count;
}

// The writer runs on its own isolate: every op is built at top level, so its closure captures only
// sendable values (FIX-S2Q-2).
LibraryWrite<int> _seedOp(_Chunk c) => (w, now) => _seedChunk(w, now, c);
LibraryWrite<FolderId> _folderOp(String name, FolderId? parent) => (w, now) => w.createFolder(name, parent: parent, now: now);
LibraryWrite<void> _trashOp(FolderId id) => (w, now) => w.trashFolder(id, now: now);
LibraryWrite<PurgeResult> _emptyOp() => (w, now) => w.emptyTrash();

const List<String> _docExts = ['pdf', 'docx', 'xlsx', 'pptx', 'txt', 'csv', 'md', 'epub'];

/// Counts of a generated linked tree.
typedef _Tree = ({int folders, int documents});

void _docs(String dir, int count, String stem) {
  for (var k = 0; k < count; k++) {
    File('$dir/$stem-$k.${_docExts[(stem.length + k) % _docExts.length]}').writeAsStringSync('S3 linked $k\n');
  }
}

/// "depth": folders d0/d1/…/d10, one document `deep_d<depth>.pdf` in each.
_Tree _makeDepthRoot(String root) {
  var dir = root;
  for (var d = 0; d <= 10; d++) {
    if (d > 0) dir = '$dir/d$d';
    Directory(dir).createSync(recursive: true);
    File('$dir/deep_d$d.pdf').writeAsStringSync('%PDF-1.4\n');
  }
  return (folders: 11, documents: 11);
}

/// "wide": 2,300 empty folders at depth 1, 10 documents at depth 0, 50 at depth 2.
_Tree _makeWideRoot(String root) {
  Directory(root).createSync(recursive: true);
  _docs(root, 10, 'wide_top');
  for (var k = 0; k < 2300; k++) {
    Directory('$root/w${k.toString().padLeft(4, '0')}').createSync();
  }
  final deep = Directory('$root/w2299/inner')..createSync();
  _docs(deep.path, 50, 'wide_deep');
  return (folders: 2302, documents: 60);
}

/// "big": 20 × 5 × 5 × 3 folders (depths 1..4), a chain of 5 more (depths 5..9) under 10 of the
/// depth-4 folders, a 1,200-document folder at depth 1; 2 documents, a photo and a hidden file in
/// every other folder.
_Tree _makeBigRoot(String root) {
  Directory(root).createSync(recursive: true);
  var folders = 1;
  var documents = 0;
  void fill(String dir, String stem) {
    _docs(dir, 2, stem);
    File('$dir/photo.jpg').writeAsBytesSync(const [0xFF, 0xD8, 0xFF, 0xD9]);
    File('$dir/.DS_Store').writeAsStringSync('x');
    folders++;
    documents += 2;
  }

  final bulk = Directory('$root/Bulk')..createSync();
  _docs(bulk.path, 1200, 'bulk');
  folders++;
  documents += 1200;
  var chains = 0;
  for (var a = 0; a < 20; a++) {
    final da = '$root/a$a';
    Directory(da).createSync();
    fill(da, 'a$a');
    for (var b = 0; b < 5; b++) {
      final db = '$da/b$b';
      Directory(db).createSync();
      fill(db, 'a${a}b$b');
      for (var c = 0; c < 5; c++) {
        final dc = '$db/c$c';
        Directory(dc).createSync();
        fill(dc, 'a${a}b${b}c$c');
        for (var e = 0; e < 3; e++) {
          var dd = '$dc/e$e';
          Directory(dd).createSync();
          fill(dd, 'a${a}b${b}c${c}e$e');
          if (chains < 10) {
            chains++;
            for (var depth = 5; depth <= 9; depth++) {
              dd = '$dd/z$depth';
              Directory(dd).createSync();
              fill(dd, 'chain${chains}z$depth');
            }
          }
        }
      }
    }
  }
  return (folders: folders, documents: documents);
}

/// The vertical scrollable with the largest area on screen (the tab's list).
Finder _mainScrollable() {
  Element? best;
  var area = 0.0;
  for (final e in find.byType(Scrollable).hitTestable().evaluate()) {
    final s = e.widget as Scrollable;
    if (axisDirectionToAxis(s.axisDirection) != Axis.vertical) continue;
    final box = e.renderObject as RenderBox?;
    if (box == null || !box.hasSize) continue;
    final a = box.size.width * box.size.height;
    if (a > area) {
      area = a;
      best = e;
    }
  }
  if (best == null) throw StateError('no vertical scrollable on screen');
  final target = best;
  return find.byElementPredicate((e) => e == target);
}

/// Pumps real-time frames for [d] (the binding is fully live).
Future<void> _run(WidgetTester tester, Duration d) async {
  final end = DateTime.now().add(d);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

String _pct(List<int> sorted, double p) => sorted.isEmpty ? '-' : (sorted[math.min(sorted.length - 1, (sorted.length * p).floor())] / 1000).toStringAsFixed(1);

String _summary(List<FrameTiming> t) {
  final build = t.map((f) => f.buildDuration.inMicroseconds).toList()..sort();
  final raster = t.map((f) => f.rasterDuration.inMicroseconds).toList()..sort();
  final total = t.map((f) => f.buildDuration.inMicroseconds + f.rasterDuration.inMicroseconds).toList()..sort();
  final overBudget = total.where((us) => us > _budgetUs).length;
  final jank = t.where((f) => f.totalSpan.inMicroseconds > _jankUs).length;
  return 'frames ${t.length}; build p50/p90/p99/max ${_pct(build, .5)}/${_pct(build, .9)}/${_pct(build, .99)}/${_pct(build, 1)} ms; '
      'raster p50/p90/p99/max ${_pct(raster, .5)}/${_pct(raster, .9)}/${_pct(raster, .99)}/${_pct(raster, 1)} ms; '
      'build+raster > 8 ms: $overBudget; span > 2 frames: $jank';
}

String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

String _ms(List<int> us) {
  final s = List<int>.of(us)..sort();
  return 'median ${(s[s.length ~/ 2] / 1000).toStringAsFixed(1)} / max ${(s.last / 1000).toStringAsFixed(1)} ms';
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('S3 stress: Documents tab, sub-filters, search and the linked walk over a generated library', (tester) async {
    if (!FeatureFlags.filesHomeEnabled) throw StateError('Build with --dart-define=DANAVIEW_FILES_HOME=true');
    if (_docsDir.isEmpty) throw StateError('Pass --dart-define=DV_S3_DOCS=<dir> (integration_test/v12/s3/tool/make_s3_docs.sh)');
    final samples = _Samples(
      pdf: File('$_docsDir/s3_shared.pdf').readAsBytesSync(),
      office: File('$_docsDir/s3_brief.docx').readAsBytesSync(),
      photo: File('$_docsDir/s3_shared.jpg').readAsBytesSync(),
      zip: File('$_docsDir/s3_bundle.zip').readAsBytesSync(),
    );

    IncomingMediaBridge.setLaunchArgs(const []);
    await PlatformBridge.initializeWindow();
    final prefs = await SharedPreferences.getInstance();
    final player = MpvPlaybackEngine(subtitleFontAssets: DanaviewFonts.files);
    await player.initialize();
    final runtime = await filesHomeOverrides(prefs: prefs);
    final store = runtime.store!;
    final thumbs = runtime.thumbnails!;

    // ---- 1. The generated library ----
    for (final f in store.reader.childFolders(null).where((f) => f.name == _rootName)) {
      await store.write(_trashOp(f.id));
    }
    await store.write(_emptyOp());
    final before = store.reader.allEntries().length;
    final seedWatch = Stopwatch()..start();
    final root = await store.write(_folderOp(_rootName, null));
    final bulk = await store.write(_folderOp('Bulk', root));
    final small = <FolderId>[];
    for (var i = 0; i < 20; i++) {
      small.add(await store.write(_folderOp('Set ${i + 1}', root)));
    }
    const chunk = 250;
    for (var s = 0; s < _n; s += chunk) {
      await store.write(_seedOp(_Chunk(s, math.min(chunk, _n - s), bulk, small, samples)));
    }
    seedWatch.stop();
    final all = store.reader.allEntries();
    expect(all.length - before, _n, reason: 'generated entries');
    final docCount = all.where((e) => e.kind == FileKind.document).length;
    _report('library: $_n generated, ${all.length} live entries ($docCount documents); seeded in ${seedWatch.elapsedMilliseconds} ms');

    // ---- 2. The linked roots and the bounded walk ----
    final linkedBase = Directory('${Directory.systemTemp.path}/s3q-linked-stress');
    if (linkedBase.existsSync()) linkedBase.deleteSync(recursive: true);
    final genWatch = Stopwatch()..start();
    final depthTree = _makeDepthRoot('${linkedBase.path}/depth');
    final wideTree = _makeWideRoot('${linkedBase.path}/wide');
    final bigTree = _makeBigRoot('${linkedBase.path}/big');
    genWatch.stop();
    _report('linked roots generated in ${genWatch.elapsedMilliseconds} ms: depth ${depthTree.folders} folders / ${depthTree.documents} docs, '
        'wide ${wideTree.folders} / ${wideTree.documents}, big ${bigTree.folders} / ${bigTree.documents} '
        '(budgets: $linkedDocumentFolderBudget folders per root, $linkedDocumentBudget documents, depth $linkedDocumentDepth)');
    final rootPaths = ['${linkedBase.path}/depth', '${linkedBase.path}/wide', '${linkedBase.path}/big'];
    final walkUs = <int>[];
    var linked = const <DocumentItem>[];
    final rssWalk0 = ProcessInfo.currentRss;
    for (var k = 0; k < 3; k++) {
      final w = Stopwatch()..start();
      // As linkedDocumentWalkerProvider does: on a background isolate.
      linked = await Isolate.run(() => walkLinkedDocuments(rootPaths));
      w.stop();
      walkUs.add(w.elapsedMicroseconds);
    }
    final perRoot = {for (final p in rootPaths) p: linked.where((d) => d.uri.startsWith('$p/')).length};
    final depthNames = {for (final d in linked) if (d.uri.startsWith('${rootPaths[0]}/')) d.name};
    _report('linked walk (3 runs, Isolate.run): ${_ms(walkUs)}; ${linked.length} documents '
        '(depth ${perRoot[rootPaths[0]]}, wide ${perRoot[rootPaths[1]]}, big ${perRoot[rootPaths[2]]}); '
        'RSS ${_mb(rssWalk0)} → ${_mb(ProcessInfo.currentRss)} MB (max ${_mb(ProcessInfo.maxRss)} MB)');
    expect(linked.length, linkedDocumentBudget, reason: 'the document budget ends the walk');
    expect(depthNames, {for (var d = 0; d <= linkedDocumentDepth; d++) 'deep_d$d.pdf'}, reason: 'depth ≤ $linkedDocumentDepth');
    expect(perRoot[rootPaths[1]], 10, reason: 'the folder budget ends the wide root before depth 2');
    expect(linked.where((d) => d.name.startsWith('.') || d.name == 'photo.jpg'), isEmpty, reason: 'hidden and non-document files skipped');

    // ---- 3. The app at Home, then the Documents tab ----
    final openWatch = Stopwatch()..start();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        playbackEngineProvider.overrideWithValue(player),
        sessionRepositoryProvider.overrideWithValue(SessionRepository(prefs)),
        libraryRepositoryProvider.overrideWithValue(LibraryRepository(prefs)),
        ...runtime.overrides,
        // The walked roots stand in for linked folders (the walk itself is timed above).
        linkedDocumentsProvider.overrideWithValue(linked),
      ],
      child: const DanaviewApp(),
    ));
    await E2eApp.pumpUntil(tester, () => find.byKey(homeTabKey(HomeTab.documents)).evaluate().isNotEmpty, what: 'Home tabs');
    openWatch.stop();
    _report('Home with tabs after ${openWatch.elapsedMilliseconds} ms (debug build, store already open); RSS ${_mb(ProcessInfo.currentRss)} MB');

    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    final failures = <String>[];
    final tabWatch = Stopwatch()..start();
    await E2eApp.tap(tester, find.byKey(homeTabKey(HomeTab.documents)), what: 'Documents tab');
    await tester.pump();
    tabWatch.stop();
    _report('Documents: first frame after tap ${tabWatch.elapsedMilliseconds} ms');
    await _run(tester, const Duration(milliseconds: 800));

    for (final sub in documentSubFilters) {
      final code = sub?.code ?? 'all';
      final scroll = _mainScrollable();
      tester.state<ScrollableState>(scroll).position.jumpTo(0);
      await _run(tester, const Duration(milliseconds: 200));
      final chipWatch = Stopwatch()..start();
      await E2eApp.tapKey(tester, 'documents-sub-$code');
      await tester.pump();
      chipWatch.stop();
      await _run(tester, const Duration(milliseconds: 600));
      final s0 = (thumbs.stats.generated, thumbs.stats.diskHits, thumbs.stats.memoryHits, thumbs.stats.failures);
      final evict0 = thumbs.memory.evictions;
      final rss0 = ProcessInfo.currentRss;
      final timings = <FrameTiming>[];
      void collect(List<FrameTiming> t) => timings.addAll(t);
      SchedulerBinding.instance.addTimingsCallback(collect);
      final list = _mainScrollable();
      // Fling script: 3 down, 2 up, each followed by its ballistic run.
      for (final dy in [-2400.0, -2400.0, -2400.0, 2400.0, 2400.0]) {
        await tester.fling(list, Offset(0, dy), 6000);
        await _run(tester, const Duration(milliseconds: 1600));
      }
      final flingFrames = List<FrameTiming>.of(timings);
      timings.clear();
      if (sub == null) {
        // Drag script on All documents: 8 slow drags, alternating 5 down / 3 up.
        for (var i = 0; i < 8; i++) {
          await tester.timedDrag(list, Offset(0, i < 5 ? -600.0 : 600.0), const Duration(milliseconds: 800));
          await _run(tester, const Duration(milliseconds: 300));
        }
        await _run(tester, const Duration(milliseconds: 500));
      }
      SchedulerBinding.instance.removeTimingsCallback(collect);
      final dragFrames = List<FrameTiming>.of(timings);
      final exception = tester.takeException();
      if (exception != null) failures.add('$code: $exception');
      final st = thumbs.stats;
      _report('documents/$code: first frame after chip tap ${chipWatch.elapsedMilliseconds} ms');
      _report('documents/$code fling: ${_summary(flingFrames)}');
      if (sub == null) _report('documents/$code drag: ${_summary(dragFrames)}');
      _report('documents/$code memory: RSS ${_mb(rss0)} → ${_mb(ProcessInfo.currentRss)} MB (max ${_mb(ProcessInfo.maxRss)} MB); '
          'thumb LRU ${_mb(thumbs.memory.bytes)} MB (peak ${_mb(thumbs.memory.peakBytes)} MB, cap ${_mb(thumbs.memory.maxBytes)} MB), '
          'evictions +${thumbs.memory.evictions - evict0}; generated +${st.generated - s0.$1}, disk hits +${st.diskHits - s0.$2}, '
          'memory hits +${st.memoryHits - s0.$3}, failures +${st.failures - s0.$4}');
      if (sub == null) await E2eApp.screenshot(tester, 's3-stress-documents');
      expect(thumbs.memory.peakBytes, lessThanOrEqualTo(64 * 1024 * 1024), reason: 'HOM-04 LRU ≤ 64 MB (§10.1)');
    }

    // ---- 4. Name search over the generated library ----
    await E2eApp.tap(tester, find.byKey(homeTabKey(HomeTab.home)), what: 'Home tab');
    await _run(tester, const Duration(milliseconds: 600));
    final container = ProviderScope.containerOf(tester.element(find.byType(DanaviewHomeScreen)), listen: false);
    final keep = container.listen(nameSearchControllerProvider, (_, __) {});
    final controller = container.read(nameSearchControllerProvider.notifier);
    final loadWatch = Stopwatch()..start();
    await controller.danaviewSettled;
    loadWatch.stop();
    _report('search: Danaview index settled ${loadWatch.elapsedMilliseconds} ms after the Home tab (load started at launch)');
    for (final kinds in [null, {FileKind.document}]) {
      await controller.setKinds(kinds);
      for (final q in ['report', 'budget 012', 'slides 0999', 'notes', 'zzqx']) {
        final us = <int>[];
        var total = 0;
        for (var k = 0; k < 5; k++) {
          final w = Stopwatch()..start();
          await controller.setQuery(q);
          w.stop();
          us.add(w.elapsedMicroseconds);
          total = container.read(nameSearchControllerProvider).results?.total ?? -1;
        }
        _report('search "$q" kinds ${kinds == null ? 'all' : 'documents'}: ${_ms(us)}, $total matches');
      }
    }
    controller.clear();
    await controller.setKinds(null);
    await _run(tester, const Duration(milliseconds: 300));
    final field = find.descendant(of: find.byKey(const ValueKey('s2-search')), matching: find.byType(EditableText));
    await E2eApp.pumpUntil(tester, () => field.hitTestable().evaluate().isNotEmpty, what: 'the Home search field');
    final typeWatch = Stopwatch()..start();
    await tester.enterText(field.hitTestable().first, 'report');
    await E2eApp.pumpUntil(tester, () => find.byKey(const ValueKey('library-search-count')).evaluate().isNotEmpty, what: 'search matches');
    typeWatch.stop();
    final countText = (tester.widget<Text>(find.byKey(const ValueKey('library-search-count'))).data ?? '');
    _report('search typed into the Home field: keystroke to "$countText" on screen ${typeWatch.elapsedMilliseconds} ms (60 ms debounce included)');
    await E2eApp.screenshot(tester, 's3-stress-search');
    await E2eApp.hideKeyboard(tester);
    controller.clear();
    keep.close();
    final exception = tester.takeException();
    if (exception != null) failures.add('search: $exception');
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fadePointers;

    // ---- 5. Leave the library and the disk as found ----
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await store.write(_trashOp(root));
    await store.write(_emptyOp());
    expect(store.reader.allEntries().length, before, reason: 'generated entries purged');
    if (linkedBase.existsSync()) linkedBase.deleteSync(recursive: true);
    await runtime.dispose();
    expect(failures, isEmpty);
  });
}
