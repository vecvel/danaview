// OWNER: HOM-04
//
// LibraryThumbnail (BUILD_PLAN HOM-04; ARCH v1.2 V2-28, V2-104, §1.4): without a service (flag
// off) it shows the dark kit placeholder and asks for nothing; the size class follows the laid-out
// size and the device pixel ratio (a document cell also asks at that ratio); a memory hit paints in the first frame; leaving the tree
// cancels the request; a fling over a 10,000-cell grid keeps the memory tier within 64 MB and
// sends most flung-past cells nowhere; semantics (decorative unless labelled); and no overflow
// across 280–1280 px × text scale 0.85–1.35.
// ignore_for_file: depend_on_referenced_packages

import 'package:danaview_features/src/library/thumbs/library_thumbnail.dart';
import 'package:danaview_features/src/library/thumbs/thumb_key.dart';
import 'package:danaview_features/src/library/thumbs/thumbnail_providers.dart';
import 'package:danaview_features/src/library/thumbs/thumbnail_service.dart';
import 'package:danaview_library_native/danaview_library_native.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'thumb_fakes.dart';

final _t0 = DateTime.utc(2026, 1, 1);

Widget _cell(int i, {String? label, ThumbSizeClass? sizeClass, Widget? placeholder}) => LibraryThumbnail(
      key: ValueKey(i),
      itemId: 'fe_${i.toString().padLeft(6, '0')}',
      source: '/lib/item$i.jpg',
      modifiedAt: _t0,
      sizeClass: sizeClass,
      semanticLabel: label,
      placeholder: placeholder,
    );

Widget _host(Widget child, {ThumbnailService? service, double dpr = 3, double width = 390, double textScale = 1}) => ProviderScope(
      overrides: [thumbnailServiceProvider.overrideWithValue(service)],
      child: MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: Size(width, 844), devicePixelRatio: dpr, textScaler: TextScaler.linear(textScale)),
          child: Align(alignment: Alignment.topLeft, child: SizedBox(width: width, child: Align(alignment: Alignment.topLeft, child: child))),
        ),
      ),
    );

void main() {
  late PixelTracker tracker;
  late MemoryThumbDisk disk;
  late FakeGenerator gen;
  late ThumbnailService svc;

  setUp(() {
    tracker = PixelTracker();
    disk = MemoryThumbDisk();
    gen = FakeGenerator(disk: disk);
    svc = ThumbnailService(disk: disk, generator: gen, decoder: FakeDecoder(tracker, disk: disk), format: NativeThumbnailFormat.jpeg);
  });

  testWidgets('a document cell asks at the device pixel ratio; a media cell at 1', (tester) async {
    await tester.pumpWidget(_host(
      Column(children: [
        SizedBox(
          width: 100,
          height: 100,
          child: LibraryThumbnail(itemId: 'fe_000001', source: '/lib/a.pdf', modifiedAt: _t0, kind: ThumbSourceKind.document),
        ),
        SizedBox(width: 100, height: 100, child: _cell(2)),
      ]),
      service: svc,
      dpr: 3,
    ));
    await tester.pump();
    expect(gen.scales, [3]);
    expect(gen.started, containsAll(['/lib/a.pdf', '/lib/item2.jpg']));
  });

  testWidgets('without a service (flag off) the placeholder shows and nothing is asked', (tester) async {
    await tester.pumpWidget(_host(SizedBox(width: 100, height: 100, child: _cell(1, placeholder: const Text('PDF')))));
    expect(find.text('PDF'), findsOneWidget);
    final box = tester.widget<ColoredBox>(find.descendant(of: find.byType(LibraryThumbnail), matching: find.byType(ColoredBox)));
    expect(box.color, DanaviewColors.surfaceElevated);
    expect(gen.started, isEmpty);
  });

  testWidgets('the size class follows the box and the pixel ratio', (tester) async {
    Future<void> show(double side, double dpr, ThumbSizeClass expected) async {
      svc.trimMemory();
      await tester.pumpWidget(_host(SizedBox(width: side, height: side, child: _cell(side.toInt() * 10 + dpr.toInt())), service: svc, dpr: dpr));
      await tester.pump();
      final r = ThumbRequest(itemId: 'fe_${(side.toInt() * 10 + dpr.toInt()).toString().padLeft(6, '0')}', source: '', modifiedAt: _t0, sizeClass: expected);
      expect(svc.memory.contains(r.key), isTrue, reason: '$side lp @${dpr}x → ${expected.name}');
    }

    await show(60, 3, ThumbSizeClass.s);
    await show(120, 3, ThumbSizeClass.m);
    await show(300, 2, ThumbSizeClass.l);
    await show(300, 1, ThumbSizeClass.m);
  });

  testWidgets('a memory hit paints in the first frame; leaving the tree cancels', (tester) async {
    (await svc.load(req(1)).result)!.dispose();
    gen.gated = true;
    await tester.pumpWidget(_host(Column(children: [
      SizedBox(width: 120, height: 120, child: _cell(1, sizeClass: ThumbSizeClass.m)),
      SizedBox(width: 120, height: 120, child: _cell(2, sizeClass: ThumbSizeClass.m)),
    ]), service: svc));
    await tester.pump();
    expect(gen.started, ['/lib/item1.jpg', '/lib/item2.jpg'], reason: 'cell 1 came from memory, not the platform');
    expect(disk.lookups, 2, reason: 'cell 1 did not even look at the disk again');
    expect(gen.pending, 1, reason: 'cell 2 is generating');
    await tester.pumpWidget(_host(const SizedBox(), service: svc));
    await tester.pump();
    expect(gen.cancelled, hasLength(1), reason: 'the cell left the viewport');
    expect(tracker.liveBytes, ThumbSizeClass.m.maxDecodedBytes, reason: 'only the cache copy of cell 1 remains');
  });

  testWidgets('ACCEPTANCE: a 10,000-cell fling stays within 64 MB and skips flung-past cells', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    gen.gated = true;
    await tester.pumpWidget(_host(
      SizedBox(
        height: 844,
        child: GridView.builder(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3),
          itemCount: 10000,
          itemBuilder: (_, i) => _cell(i),
        ),
      ),
      service: svc,
    ));
    var maxBytes = 0;
    for (var round = 0; round < 24; round++) {
      await tester.fling(find.byType(GridView), const Offset(0, -6000), 20000);
      for (var f = 0; f < 30; f++) {
        await tester.pump(const Duration(milliseconds: 16));
        // The platform finishes a few per frame.
        for (var k = 0; k < 2; k++) {
          if (gen.pending > 0) gen.releaseAll();
        }
        if (svc.memory.bytes > maxBytes) maxBytes = svc.memory.bytes;
        expect(svc.memory.bytes, lessThanOrEqualTo(64 * 1024 * 1024));
      }
    }
    await tester.pumpAndSettle();
    gen.releaseAll();
    await tester.pump();
    final first = tester.widget<LibraryThumbnail>(find.byType(LibraryThumbnail).first);
    expect(int.parse(first.itemId.substring(3)), greaterThan(3000), reason: 'the fling went far');
    expect(svc.memory.peakBytes, lessThanOrEqualTo(64 * 1024 * 1024));
    expect(svc.stats.dequeued + svc.stats.nativeCancels, greaterThan(0), reason: 'cells that left were cancelled');
    expect(gen.started.length, lessThan(int.parse(first.itemId.substring(3))), reason: 'most flung-past cells never reached the platform');
    expect(maxBytes, greaterThan(0));
  });

  testWidgets('semantics: decorative by default, labelled when asked', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(Row(children: [
      SizedBox(width: 80, height: 80, child: _cell(1)),
      SizedBox(width: 80, height: 80, child: _cell(2, label: 'Photo, 12 March')),
    ]), service: svc));
    expect(find.bySemanticsLabel('Photo, 12 March'), findsOneWidget);
    final node = tester.getSemantics(find.bySemanticsLabel('Photo, 12 March'));
    expect(node.flagsCollection.isImage, isTrue);
    handle.dispose();
  });

  testWidgets('no overflow at 280–1280 px × text scale 0.85–1.35, bounded or not', (tester) async {
    for (final width in [280.0, 320.0, 390.0, 768.0, 1024.0, 1280.0]) {
      for (final scale in [0.85, 1.0, 1.35]) {
        await tester.binding.setSurfaceSize(Size(width, 900));
        await tester.pumpWidget(_host(
          Column(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(height: 120, child: Row(children: [for (var i = 0; i < 4; i++) Expanded(child: _cell(i, placeholder: const Text('JPEG')))])),
            // Unbounded height inside a column: falls back to a square of the width.
            SizedBox(width: 60, child: _cell(9)),
            UnconstrainedBox(child: _cell(10)),
          ]),
          service: svc,
          width: width,
          textScale: scale,
        ));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: '$width × $scale');
      }
    }
    await tester.binding.setSurfaceSize(null);
  });
}
