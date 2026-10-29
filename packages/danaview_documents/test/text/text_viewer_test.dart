// OWNER: HOM-23
//
// BUILD_PLAN HOM-23 text viewer (HOM plan §8.4; ARCH §10.1 "Text viewer: 50 MB log scrolls at the
// grid budget; first screen ≤ 300 ms"): rows render virtualised, the change-encoding menu
// re-decodes, wrap toggles, a file over the cap shows "Showing the first …" with "Open in another
// app", an unreadable file reports unavailable, and the 50 MB generated log loads off the UI
// isolate and scrolls with per-frame build+layout inside the grid budget. ARCH §1.4 matrix: no
// overflow at 280–1280 px × 0.85–1.35 with the notice and the menu open, targets ≥ 44 px, labels.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:danaview_documents/danaview_documents.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../card/doc_harness.dart';

ViewerFile _file(String name, {String path = '/x/file'}) =>
    ViewerFile(path: path, displayName: name, kind: FileKind.document, docKind: DocumentKind.text, sizeBytes: 10);

/// DV_PERF_STRICT=1 gates the absolute frame and load budgets (a quiet dev Mac); otherwise the 50 MB
/// log's frames are compared with a same-run 2,000-line baseline.
final bool _perfStrict = Platform.environment['DV_PERF_STRICT'] == '1';

/// How many times the baseline frame (median and p90) the 50 MB log's frames may take.
const int _baselineRatio = 3;

/// Slack (µs) added to the ratio limit, for sub-millisecond baselines.
const int _baselineSlackUs = 2000;

TextDocument _doc(String text) => TextDocument.fromBytes(Uint8List.fromList(utf8.encode(text)));

void main() {
  testWidgets('shows rows, the encoding and the line count', (tester) async {
    await tester
        .pumpWidget(docApp(TextViewer(file: _file('notes.txt'), document: _doc('first line\nsecond\tline\nthird'), onClose: () {})));
    expect(find.text('first line'), findsOneWidget);
    expect(find.text('second    line'), findsOneWidget);
    expect(find.text('UTF-8 · 3 lines'), findsOneWidget);
    expect(find.textContaining('Showing the first'), findsNothing);
  });

  testWidgets('the change-encoding menu re-decodes the rows', (tester) async {
    final doc = TextDocument.fromBytes(Uint8List.fromList(latin1.encode('café olé')));
    await tester.pumpWidget(docApp(TextViewer(file: _file('legacy.txt'), document: doc)));
    expect(find.text('café olé'), findsOneWidget);
    expect(find.text('Latin-1 · 1 line'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('View options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('UTF-8'));
    await tester.pumpAndSettle();
    expect(find.text('caf� ol�'), findsOneWidget);
    expect(find.text('UTF-8 · 1 line'), findsOneWidget);
  });

  testWidgets('wrap lines is on by default and off for logs; the menu toggles it', (tester) async {
    final long = 'word ' * 200;
    await tester.pumpWidget(docApp(TextViewer(file: _file('a.txt'), document: _doc(long))));
    final wrapped = tester.getSize(find.text(long.trimRight().isEmpty ? long : long)).height;
    expect(wrapped, greaterThan(40));

    await tester.pumpWidget(docApp(TextViewer(key: const ValueKey('log'), file: _file('a.log'), document: _doc(long))));
    expect(tester.getSize(find.text(long)).height, lessThan(30));

    await tester.tap(find.bySemanticsLabel('View options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wrap lines'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.text(long)).height, greaterThan(40));
  });

  testWidgets('over the cap: the notice and "Open in another app" hand the library file over', (tester) async {
    final dir = docTempDir();
    final f = File('${dir.path}/big.log')..writeAsStringSync(List.generate(400, (i) => 'row $i').join('\n'));
    final doc = TextDocument.loadSync(f.path, capBytes: 512);
    final port = RecordingPort();
    final file = _file('big.log', path: f.path);
    await tester.pumpWidget(docApp(TextViewer(file: file, document: doc, fileOut: port)));
    expect(find.text('Showing the first 512 bytes of ${formatByteSize(f.lengthSync())}.'), findsOneWidget);
    await tester.tap(find.text('Open in another app'));
    await tester.pump();
    expect(port.calls.single.$1, 'open');
    expect(port.calls.single.$2.single.path, f.path);
    DanaviewToast.dismiss();
  });

  testWidgets('an unreadable file reports unavailable', (tester) async {
    var unavailable = 0;
    await tester.pumpWidget(docApp(TextViewer(
      file: _file('gone.txt'),
      loader: (_) => Future<TextDocument>.error(const TextLoadException(missing: true)),
      onUnavailable: () => unavailable++,
    )));
    await tester.pump();
    await tester.pump();
    expect(unavailable, 1);
    expect(find.text('Can\'t show this file'), findsOneWidget);
  });

  testWidgets('a 50 MB log: loads off the UI isolate, scrolls within the grid budget', (tester) async {
    final dir = docTempDir();
    final path = '${dir.path}/server.log';
    final smallPath = '${dir.path}/small.log';
    // ~50 MB of generated log lines (no downloads), and a 2,000-line log of the same lines (the
    // same-run frame baseline).
    await tester.runAsync(() async {
      String lines(int from, int count) {
        final chunk = StringBuffer();
        for (var i = from; i < from + count; i++) {
          chunk.writeln(
              '2026-10-23T12:00:${(i % 60).toString().padLeft(2, '0')}Z INFO worker-${i % 16} request $i handled in ${i % 997} ms status=200');
        }
        return chunk.toString();
      }

      final sink = File(path).openWrite();
      var i = 0;
      var written = 0;
      while (written < textViewerCapBytes) {
        final s = lines(i, 2000);
        i += 2000;
        written += s.length;
        sink.write(s);
      }
      await sink.close();
      File(smallPath).writeAsStringSync(lines(0, 2000));
    });
    final size = File(path).lengthSync();
    expect(size, greaterThanOrEqualTo(textViewerCapBytes));

    // Off the UI isolate: the UI isolate's timers keep firing while the 50 MB load runs (a load on
    // this isolate is synchronous, so not one tick would get in before it completes).
    final load = Stopwatch()..start();
    var ticks = 0;
    final doc = (await tester.runAsync(() async {
      final timer = Timer.periodic(const Duration(milliseconds: 1), (_) => ticks++);
      try {
        return await TextDocument.load(path);
      } finally {
        timer.cancel();
      }
    }))!;
    load.stop();
    expect(ticks, greaterThan(0), reason: 'the UI isolate ran while the log loaded');
    expect(doc.rowCount, greaterThan(400000));
    final small = (await tester.runAsync(() => TextDocument.load(smallPath)))!;
    expect(small.rowCount, 2000);

    applyDocSurface(tester, const DocSurface(Size(390, 844), 1));
    final list = find.byKey(const ValueKey('text-viewer-rows'));

    /// Shows [d] and times 180 scroll frames (two flings, a jump to the middle in between), then
    /// jumps to the end; returns the sorted frame times (µs).
    Future<List<int>> scrollFrames(TextDocument d, String name, String p) async {
      await tester.pumpWidget(docApp(TextViewer(key: ValueKey(name), file: _file(name, path: p), document: d)));
      await tester.pump();
      final frames = <int>[];
      Future<void> timed() async {
        for (var f = 0; f < 90; f++) {
          final sw = Stopwatch()..start();
          await tester.pump(const Duration(milliseconds: 16));
          frames.add(sw.elapsedMicroseconds);
        }
      }

      await tester.fling(list, const Offset(0, -3000), 8000);
      await timed();
      // Jump deep into the file and keep scrolling.
      final scrollable = tester.state<ScrollableState>(find.descendant(of: list, matching: find.byType(Scrollable)).first);
      scrollable.position.jumpTo(scrollable.position.maxScrollExtent / 2);
      await tester.pump();
      await tester.fling(list, const Offset(0, 3000), 8000);
      await timed();
      scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
      await tester.pump();
      expect(find.textContaining('handled in'), findsWidgets);
      return frames..sort();
    }

    await scrollFrames(small, 'warmup.log', smallPath); // JIT warm-up, not measured
    final base = await scrollFrames(small, 'small.log', smallPath);
    final frames = await scrollFrames(doc, 'server.log', path);
    int median(List<int> f) => f[f.length ~/ 2];
    int p90(List<int> f) => f[(f.length * 0.9).floor()];

    // ignore: avoid_print
    print('HOM-23 50 MB log: ${formatByteSize(size)}, ${doc.rowCount} rows, load ${load.elapsedMilliseconds} ms, '
        'median frame ${median(frames)} µs, p90 frame ${p90(frames)} µs, max ${frames.last} µs; '
        '2,000-line baseline median ${median(base)} µs, p90 ${p90(base)} µs');
    if (_perfStrict) {
      // ARCH §10.1 grid budget: ≤ 8 ms build+raster per frame at 60 Hz (p90, release, on device).
      // Here (DV_PERF_STRICT=1, a quiet dev Mac): build + layout + test harness in debug JIT, so
      // the typical frame must be inside the budget and the p90 inside one 60 Hz frame (host runs
      // measured p90 4.4–7.1 ms), and the load (device budget ≤ 300 ms on the low tier, recorded
      // on device) within 3 s. The device number is recorded with QA.
      expect(load.elapsedMilliseconds, lessThan(3000), reason: 'load');
      expect(median(frames), lessThan(8000), reason: 'median frame');
      expect(p90(frames), lessThan(16000), reason: 'p90 frame ${p90(frames)} µs');
    } else {
      // CI, a loaded machine: virtualised rows make a 400,000-row log scroll like a 2,000-row
      // one, so its frames are compared with the same-run baseline (host speed and load move both
      // alike; per-row work or a non-lazy list makes the big log many times slower).
      expect(median(frames), lessThanOrEqualTo(median(base) * _baselineRatio + _baselineSlackUs),
          reason: 'median frame ${median(frames)} µs vs baseline ${median(base)} µs');
      expect(p90(frames), lessThanOrEqualTo(p90(base) * _baselineRatio + _baselineSlackUs),
          reason: 'p90 frame ${p90(frames)} µs vs baseline ${p90(base)} µs');
    }
  });

  testWidgets('matrix: no overflow with the notice and the menu, targets ≥ 44 px, labels', (tester) async {
    final handle = tester.ensureSemantics();
    final doc = TextDocument.fromBytes(Uint8List.fromList(utf8.encode(List.generate(200, (i) => 'line $i ${'x' * (i % 90)}').join('\n'))),
        fileSize: 90000000);
    final file = _file('A long log file name that needs to ellipsize on small phones.log');
    for (final surface in docMatrix) {
      applyDocSurface(tester, surface);
      await tester.pumpWidget(
          docApp(TextViewer(file: file, document: doc, fileOut: RecordingPort(), onClose: () {}), textScale: surface.textScale));
      await tester.pump();
      expectNoLayoutErrors(tester, surface);
      await expectTargetsAndLabels(tester);
      await tester.tap(find.bySemanticsLabel('View options'));
      await tester.pumpAndSettle();
      expectNoLayoutErrors(tester, '$surface menu');
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
    }
    handle.dispose();
  });
}
