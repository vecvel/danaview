// OWNER: S2-Q
//
// S2 Home stress probe (BUILD_PLAN v1.2 §1A, S2-Q: the slice's share of HOM-14; ARCH v1.2 §10.1
// Home budgets). HOM-14 itself (N5) owns the 50,000-item run, `tool/v12/make_library_fixture.dart`
// and `integration_test/v12/home_stress/`; this file is S2-Q's interim evidence for the S2 tabs and
// does not replace it.
//
// With DANAVIEW_FILES_HOME=true, on the real S2 wiring (`filesHomeOverrides`: HOM-17 store on its
// isolate writer, HOM-04 thumbnails) on the iOS Simulator:
//
//   1. a Danaview-folder library of N mixed items (default 5,000: 60 % photos, 25 % videos, 15 %
//      text) is generated in the app's own library through the import path (part file + commit,
//      with photo/video facts), from local media (make_s2_media.sh `stress/`): most in one big
//      folder, the rest spread over 20 folders;
//   2. on All, Videos, Photos and Folders (the big folder opened) a fling script (3 flings down, 2
//      up) and a drag script (8 slow drags) run with the binding fully live; every FrameTiming is
//      recorded, plus RSS and the HOM-04 cache (memory LRU bytes / peak / evictions, generated,
//      disk and memory hits, coalesced, cancels);
//   3. the generated folder is deleted and Recently deleted emptied (the library is left as found;
//      note that Empty now also purges anything else in Recently deleted of the simulator's library).
//
// The simulator runs a debug (JIT) build only: Flutter has no profile mode on the iOS Simulator, so
// the frame numbers are recorded as debug-mode indications, not as the §10.1 verdict (that is
// HOM-14 / QA-104 on the device lab). Memory and cache behaviour are mode-independent enough to
// check the 64 MB LRU cap.
//
// Run: integration_test/v12/s2/tool/make_s2_media.sh
//      DV_E2E_EXTRA_DEFINES="DANAVIEW_FILES_HOME=true DV_S2_MEDIA=$PWD/build/e2e/s2_media [DV_S2_STRESS_N=5000]" \
//        scripts/ci/editor/e2e_ios.sh --target integration_test/v12/s2/s2_home_stress_test.dart iphone

// ignore_for_file: avoid_print, implementation_imports, depend_on_referenced_packages

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:danaview/app.dart';
import 'package:danaview/wiring/files_home_wiring.dart';
import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_engine/danaview_engine.dart';
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_features/src/flags.dart';
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

const String _mediaDir = String.fromEnvironment('DV_S2_MEDIA');
const int _n = int.fromEnvironment('DV_S2_STRESS_N', defaultValue: 5000);
const String _rootName = 'S2 Stress';

/// ARCH §10.1: ≤ 8 ms build+raster per frame at 60 Hz; "jank" is a frame over 2 × the 16.7 ms
/// frame interval.
const int _budgetUs = 8000;
const int _jankUs = 33400;

void _report(String line) => print('DV_E2E_REPORT s2-stress: $line');

/// The seed of one write chunk (sendable to the writer isolate).
final class _Chunk {
  const _Chunk(this.start, this.count, this.bulk, this.small, this.photos, this.videos);

  final int start;
  final int count;
  final FolderId bulk;
  final List<FolderId> small;
  final List<Uint8List> photos;
  final List<Uint8List> videos;
}

int _seedChunk(LibraryWriter w, DateTime now, _Chunk c) {
  final base = DateTime.utc(2024, 1, 1);
  for (var i = c.start; i < c.start + c.count; i++) {
    final folder = i % 5 == 0 ? c.small[(i ~/ 5) % c.small.length] : c.bulk;
    final when = base.add(Duration(minutes: i * 211));
    final String name;
    final List<int> bytes;
    final EntryMeta meta;
    switch (i % 20) {
      case < 12:
        final v = i % c.photos.length;
        name = 'IMG_${i.toString().padLeft(5, '0')}.jpg';
        bytes = c.photos[v];
        meta = EntryMeta(width: v % 3 == 0 ? 1200 : 1600, height: v % 3 == 0 ? 1600 : 1200, takenAt: when);
      case < 17:
        final v = i % c.videos.length;
        name = 'MOV_${i.toString().padLeft(5, '0')}.mp4';
        bytes = c.videos[v];
        meta = EntryMeta(width: 480, height: 270, duration: Duration(seconds: v + 1), takenAt: when);
      default:
        name = 'note_${i.toString().padLeft(5, '0')}.txt';
        bytes = 'Danaview S2 stress note $i\n'.codeUnits;
        meta = const EntryMeta();
    }
    final job = w.beginImport(target: folder, bytesTotal: bytes.length, now: now);
    final part = w.fs.openPart(job.id);
    part.writeFromSync(bytes);
    part.closeSync();
    final cls = classify(fileName: name);
    w.commitImport(job.id, ImportedFileInfo(displayName: name, kind: cls.kind, subKind: cls.subKind, modifiedAt: when, meta: meta), now: now);
  }
  return c.count;
}

// The writer runs on its own isolate: every op is built here, at top level, so its closure captures
// only sendable values (a closure inside the test body would capture the test's context, FIX-S2Q-2).
LibraryWrite<int> _seedOp(_Chunk c) => (w, now) => _seedChunk(w, now, c);
LibraryWrite<FolderId> _folderOp(String name, FolderId? parent) => (w, now) => w.createFolder(name, parent: parent, now: now);
LibraryWrite<void> _trashOp(FolderId id) => (w, now) => w.trashFolder(id, now: now);
LibraryWrite<PurgeResult> _emptyOp() => (w, now) => w.emptyTrash();

/// The vertical scrollable with the largest area on screen (the tab's grid or list).
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

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('S2 stress: fling and drag every library tab over a generated library', (tester) async {
    if (!FeatureFlags.filesHomeEnabled) throw StateError('Build with --dart-define=DANAVIEW_FILES_HOME=true');
    if (_mediaDir.isEmpty) throw StateError('Pass --dart-define=DV_S2_MEDIA=<dir> (make_s2_media.sh)');
    final stressDir = Directory('$_mediaDir/stress');
    final photos = [for (var i = 0; i < 24; i++) File('${stressDir.path}/p${i.toString().padLeft(2, '0')}.jpg').readAsBytesSync()];
    final videos = [for (var i = 0; i < 4; i++) File('${stressDir.path}/v$i.mp4').readAsBytesSync()];

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
      final c = _Chunk(s, math.min(chunk, _n - s), bulk, small, photos, videos);
      await store.write(_seedOp(c));
    }
    seedWatch.stop();
    final all = store.reader.allEntries().length;
    expect(all - before, _n, reason: 'generated entries');
    _report('library: $_n generated (${store.reader.allEntries().where((e) => e.kind == FileKind.photo).length} photos, '
        '${store.reader.allEntries().where((e) => e.kind == FileKind.video).length} videos in the library), '
        '$all live entries in total; seeded in ${seedWatch.elapsedMilliseconds} ms');

    // ---- 2. The app at Home ----
    final openWatch = Stopwatch()..start();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        playbackEngineProvider.overrideWithValue(player),
        sessionRepositoryProvider.overrideWithValue(SessionRepository(prefs)),
        libraryRepositoryProvider.overrideWithValue(LibraryRepository(prefs)),
        ...runtime.overrides,
      ],
      child: const DanaviewApp(),
    ));
    await E2eApp.pumpUntil(tester, () => find.byKey(homeTabKey(HomeTab.videos)).evaluate().isNotEmpty, what: 'Home tabs');
    openWatch.stop();
    _report('Home with tabs after ${openWatch.elapsedMilliseconds} ms (debug build, store already open); '
        'RSS ${_mb(ProcessInfo.currentRss)} MB');

    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    final failures = <String>[];
    // The views of the four-tab Home (DESIGN_SYSTEM §10.2–10.4): the filter's Show: All (every
    // file), the Videos and Photos tabs, and the Folders screen (the Home tab's Folders See all).
    for (final view in ['all', 'videos', 'photos', 'folders']) {
      final switchWatch = Stopwatch()..start();
      switch (view) {
        case 'all':
          await E2eApp.tap(tester, find.byKey(const ValueKey<String>('home-filter')), what: 'filter');
          await tester.pump(const Duration(milliseconds: 300));
          await E2eApp.tap(tester, find.text('All').hitTestable().last, what: 'Show: All');
        case 'folders':
          await E2eApp.tap(tester, find.byKey(homeTabKey(HomeTab.home)), what: 'home tab');
          await tester.pump(const Duration(milliseconds: 300));
          const HomeDestinationRequestNotification(HomeDestination.folders)
              .dispatch(tester.element(find.byKey(const ValueKey<String>('home-tab-strip'))));
        default:
          await E2eApp.tap(tester, find.byKey(homeTabKey(view == 'videos' ? HomeTab.videos : HomeTab.photos)), what: '$view tab');
      }
      await tester.pump();
      switchWatch.stop();
      await _run(tester, const Duration(milliseconds: 600));
      if (view == 'folders') {
        await E2eApp.tap(tester, find.byKey(ValueKey<String>('danaview-folder-${root.value}')), what: 'S2 Stress folder');
        await _run(tester, const Duration(milliseconds: 500));
        await E2eApp.tap(tester, find.byKey(ValueKey<String>('danaview-folder-${bulk.value}')), what: 'Bulk folder');
        await _run(tester, const Duration(milliseconds: 800));
      }
      final s0 = (thumbs.stats.generated, thumbs.stats.diskHits, thumbs.stats.memoryHits, thumbs.stats.coalesced, thumbs.stats.nativeCancels, thumbs.stats.failures);
      final evict0 = thumbs.memory.evictions;
      final rss0 = ProcessInfo.currentRss;
      final timings = <FrameTiming>[];
      void collect(List<FrameTiming> t) => timings.addAll(t);
      SchedulerBinding.instance.addTimingsCallback(collect);
      final scroll = _mainScrollable();
      // Fling script: 3 down, 2 up, each followed by its ballistic run.
      for (final dy in [-2400.0, -2400.0, -2400.0, 2400.0, 2400.0]) {
        await tester.fling(scroll, Offset(0, dy), 6000);
        await _run(tester, const Duration(milliseconds: 1600));
      }
      final flingFrames = List<FrameTiming>.of(timings);
      timings.clear();
      // Drag script: 8 slow drags (no fling), alternating 5 down / 3 up.
      for (var i = 0; i < 8; i++) {
        final dy = i < 5 ? -600.0 : 600.0;
        await tester.timedDrag(scroll, Offset(0, dy), const Duration(milliseconds: 800));
        await _run(tester, const Duration(milliseconds: 300));
      }
      await _run(tester, const Duration(milliseconds: 500));
      SchedulerBinding.instance.removeTimingsCallback(collect);
      final dragFrames = List<FrameTiming>.of(timings);
      final exception = tester.takeException();
      if (exception != null) failures.add('$view: $exception');
      final st = thumbs.stats;
      _report('$view: first frame after tap ${switchWatch.elapsedMilliseconds} ms');
      _report('$view fling: ${_summary(flingFrames)}');
      _report('$view drag: ${_summary(dragFrames)}');
      _report('$view memory: RSS ${_mb(rss0)} → ${_mb(ProcessInfo.currentRss)} MB (max ${_mb(ProcessInfo.maxRss)} MB); '
          'thumb LRU ${_mb(thumbs.memory.bytes)} MB in ${thumbs.memory.length} (peak ${_mb(thumbs.memory.peakBytes)} MB, cap ${_mb(thumbs.memory.maxBytes)} MB), '
          'evictions +${thumbs.memory.evictions - evict0}; generated +${st.generated - s0.$1}, disk hits +${st.diskHits - s0.$2}, '
          'memory hits +${st.memoryHits - s0.$3}, coalesced +${st.coalesced - s0.$4}, cancels +${st.nativeCancels - s0.$5}, '
          'failures +${st.failures - s0.$6}; queued ${thumbs.queued}, running ${thumbs.running}');
      await E2eApp.screenshot(tester, 's2-stress-$view');
      expect(thumbs.memory.peakBytes, lessThanOrEqualTo(64 * 1024 * 1024), reason: 'HOM-04 LRU ≤ 64 MB (§10.1)');
    }
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fadePointers;

    // ---- 3. Leave the library as found ----
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await store.write(_trashOp(root));
    await store.write(_emptyOp());
    expect(store.reader.allEntries().length, before, reason: 'generated entries purged');
    await runtime.dispose();
    expect(failures, isEmpty);
  });
}
