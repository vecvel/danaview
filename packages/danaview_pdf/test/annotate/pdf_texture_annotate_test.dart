// OWNER: HOM-29A
// EXTENDED: HOM-30A (place: move and resize of the selected stamp on a texture view).
//
// The Android annotate input (lib/src/pdf_texture_annotate.dart and the texture view in
// lib/src/pdf_view.dart): page space ↔ displayed space for every rotation, the hit test (markup,
// ink within reach, boxes, topmost first), stamp move / resize rules, and the texture view turning
// its gestures into PdfAnnotateEventsApi events through the real engine: a one-finger stroke in ink
// mode, a dot for a tap, two fingers draw nothing, taps with the item under them, a stamp dragged
// and resized in place mode (live preview through showAnnotations, one itemMoved at the end), and
// nothing outside annotate mode.

// The tests subclass the generated host APIs.
// ignore_for_file: implementation_imports

import 'dart:async';

import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:danaview_pdf/src/pdf_texture_annotate.dart';
import 'package:danaview_pdf/src/pigeon/pdf_api.g.dart';
import 'package:danaview_pdf/src/pigeon/pdf_channels.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Views extends PdfViewHostApi {
  @override
  Future<PdfTextureViewMsg> createTextureView(PdfTextureViewRequestMsg request) async => PdfTextureViewMsg(
        viewId: 41,
        textureId: 9,
        state: PdfViewStateMsg(
          viewId: 41,
          pageIndex: 0,
          pageCount: 1,
          scale: 1,
          minScale: 1,
          maxScale: 8,
          hasSelection: false,
          displayMode: PdfDisplayModeMsg.continuous,
        ),
      );

  @override
  Future<void> setTextureViewport(int viewId, PdfViewportMsg viewport) async {}

  @override
  Future<void> disposeTextureView(int viewId) async {}
}

final class _Annotate extends PdfAnnotateHostApi {
  final List<(int, List<PdfAnnotateItemMsg>, String?)> shown = [];

  @override
  Future<void> setAnnotateMode(int viewId, PdfAnnotateModeMsg? mode) async {}

  @override
  Future<void> showAnnotations(int viewId, List<PdfAnnotateItemMsg> items, String? selectedId) async => shown.add((viewId, items, selectedId));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('page space', () {
    test('displayed points round-trip for every rotation', () {
      for (final rotation in [0, 90, 180, 270]) {
        final page = PdfPageSize(600, 800, rotation);
        for (final p in const [Offset(0, 0), Offset(600, 800), Offset(10, 700), Offset(333, 5)]) {
          final back = PdfPageSpace.fromDisplay(page, PdfPageSpace.toDisplay(page, p));
          expect(back.dx, closeTo(p.dx, 1e-9), reason: 'rotation $rotation');
          expect(back.dy, closeTo(p.dy, 1e-9), reason: 'rotation $rotation');
        }
      }
    });

    test('the bottom-left page corner shows where each rotation puts it', () {
      const corner = Offset(0, 0);
      expect(PdfPageSpace.toDisplay(const PdfPageSize(600, 800), corner), const Offset(0, 800));
      expect(PdfPageSpace.toDisplay(const PdfPageSize(600, 800, 90), corner), Offset.zero);
      expect(PdfPageSpace.toDisplay(const PdfPageSize(600, 800, 180), corner), const Offset(600, 0));
      expect(PdfPageSpace.toDisplay(const PdfPageSize(600, 800, 270), corner), const Offset(800, 600));
    });

    test('rects map both ways', () {
      for (final rotation in [0, 90, 180, 270]) {
        final page = PdfPageSize(600, 800, rotation);
        final r = PdfRectMsg(x: 50, y: 60, width: 120, height: 40);
        final d = PdfPageSpace.rectToDisplay(page, r);
        expect(d.width * d.height, closeTo(120 * 40, 1e-9));
        final back = PdfPageSpace.rectFromDisplay(page, d);
        expect([back.x, back.y, back.width, back.height], [50, 60, 120, 40], reason: 'rotation $rotation');
      }
    });
  });

  group('rules', () {
    PdfAnnotateItemMsg markup(String id, double y) => PdfAnnotateItemMsg(
          id: id,
          annotation: PdfAnnotationMsg(
            kind: PdfAnnotationKindMsg.highlight,
            pageIndex: 0,
            rects: [PdfRectMsg(x: 10, y: y, width: 100, height: 12)],
            strokes: [],
            colorArgb: 0xFFFFD60A,
            lineWidth: 0,
          ),
        );
    final ink = PdfAnnotateItemMsg(
      id: 'ink',
      annotation: PdfAnnotationMsg(
        kind: PdfAnnotationKindMsg.ink,
        pageIndex: 0,
        rects: [],
        strokes: [PdfInkStrokeMsg(points: [0, 0, 100, 0])],
        colorArgb: 0xFF000000,
        lineWidth: 4,
      ),
    );
    final stamp = PdfAnnotateItemMsg(
      id: 'sig',
      stamp: PdfSignatureStampMsg(pageIndex: 1, rect: PdfRectMsg(x: 100, y: 100, width: 80, height: 40), imagePath: '/s.png', rotationDegrees: 0),
    );

    test('hit test: markup lines, ink within reach, boxes, the topmost first, its page only', () {
      final items = [markup('a', 20), markup('b', 20), ink, stamp];
      expect(PdfTextureAnnotateRules.hitTest(items, 0, const Offset(50, 25), 12), 'b');
      expect(PdfTextureAnnotateRules.hitTest(items, 0, const Offset(50, 13), 12), 'ink');
      expect(PdfTextureAnnotateRules.hitTest(items, 0, const Offset(50, 15), 12), 'b');
      expect(PdfTextureAnnotateRules.hitTest(items, 0, const Offset(50, -14), 12), 'ink');
      expect(PdfTextureAnnotateRules.hitTest(items, 0, const Offset(50, -15), 12), isNull);
      expect(PdfTextureAnnotateRules.hitTest(items, 1, const Offset(150, 120), 12), 'sig');
      expect(PdfTextureAnnotateRules.hitTest(items, 0, const Offset(150, 120), 12), isNull);
    });

    test('stamps move inside their page and resize with the aspect kept', () {
      const page = Rect.fromLTWH(0, 0, 600, 800);
      const r = Rect.fromLTWH(100, 100, 80, 40);
      expect(PdfTextureAnnotateRules.move(r, const Offset(10, -20), page), const Rect.fromLTWH(110, 80, 80, 40));
      expect(PdfTextureAnnotateRules.move(r, const Offset(-500, 1000), page), const Rect.fromLTWH(0, 760, 80, 40));
      expect(PdfTextureAnnotateRules.resize(r, const Offset(260, 140), page), const Rect.fromLTWH(100, 100, 160, 80));
      expect(PdfTextureAnnotateRules.resize(r, const Offset(0, 0), page), const Rect.fromLTWH(100, 100, 24, 12));
      expect(PdfTextureAnnotateRules.resize(r, const Offset(5000, 5000), page), const Rect.fromLTWH(100, 100, 500, 250));
    });
  });

  group('texture view', () {
    // One 600 x 800 pt page in a 300 x 400 view: 0.5 logical px per point, page at the origin.
    const doc = PdfDocumentInfo(handle: 1, pageCount: 1, pageSizes: [PdfPageSize(600, 800)]);
    late _Annotate api;
    late PlatformPdfAnnotateEngine engine;
    late List<PdfAnnotateEvent> seen;
    late StreamSubscription<PdfAnnotateEvent> sub;

    Future<void> pumpView(WidgetTester tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: SizedBox(width: 300, height: 400, child: PdfTextureView(document: doc, api: _Views()))),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    Offset at(WidgetTester tester, Offset local) => tester.getTopLeft(find.byType(PdfTextureView)) + local;

    setUp(() {
      api = _Annotate();
      engine = PlatformPdfAnnotateEngine(annotateApi: api, toolsApi: PdfToolsHostApi(), events: PdfEventHub.over(() => const Stream.empty()));
      seen = [];
      sub = engine.events(41).listen(seen.add);
    });

    tearDown(() async {
      await sub.cancel();
      await engine.setMode(41, null);
    });

    testWidgets('outside annotate mode a tap and a drag send nothing', (tester) async {
      await pumpView(tester);
      await tester.tapAt(at(tester, const Offset(100, 100)));
      await tester.dragFrom(at(tester, const Offset(100, 100)), const Offset(0, -60));
      await tester.pumpAndSettle();
      expect(seen, isEmpty);
    });

    testWidgets('ink: one finger draws a stroke in page space, a tap a dot, two fingers nothing', (tester) async {
      await pumpView(tester);
      await engine.setMode(41, const PdfAnnotateMode(input: PdfAnnotateInput.ink, inkColorArgb: 0xFFE53935, inkWidth: 3));
      await tester.pump();
      await tester.dragFrom(at(tester, const Offset(100, 100)), const Offset(50, 50));
      await tester.pumpAndSettle();
      final stroke = seen.single as PdfInkStrokeEvent;
      expect(stroke.pageIndex, 0);
      expect(stroke.points.first, const Offset(200, 600));
      expect(stroke.points.last, const Offset(300, 500));
      expect(stroke.points.length, greaterThan(2));

      seen.clear();
      await tester.tapAt(at(tester, const Offset(30, 40)));
      await tester.pumpAndSettle();
      expect((seen.single as PdfInkStrokeEvent).points, [const Offset(60, 720)]);

      seen.clear();
      final a = await tester.startGesture(at(tester, const Offset(100, 100)));
      final b = await tester.startGesture(at(tester, const Offset(200, 200)), pointer: 7);
      for (var i = 0; i < 5; i++) {
        await a.moveBy(const Offset(0, -10));
        await b.moveBy(const Offset(0, 10));
        await tester.pump();
      }
      await a.up();
      await b.up();
      await tester.pumpAndSettle();
      expect(seen.whereType<PdfInkStrokeEvent>(), isEmpty);
    });

    testWidgets('taps report the page point and the item under them', (tester) async {
      await pumpView(tester);
      await engine.setMode(41, const PdfAnnotateMode(input: PdfAnnotateInput.erase, inkColorArgb: 0, inkWidth: 1));
      await engine.show(41, const [PdfAnnotateItem.annotation('h', PdfAnnotation.markup(PdfAnnotationKind.highlight, 0, [PdfRect(100, 580, 200, 20)], colorArgb: 0x80FFD60A))]);
      await tester.pump();
      await tester.tapAt(at(tester, const Offset(100, 105)));
      await tester.pump();
      await tester.tapAt(at(tester, const Offset(10, 10)));
      await tester.pump();
      final first = seen[0] as PdfAnnotateTapEvent;
      expect(first.point, const Offset(200, 590));
      expect(first.itemId, 'h');
      expect((seen[1] as PdfAnnotateTapEvent).itemId, isNull);
    });

    testWidgets('place: a drag on the selected stamp moves it, one on its handle resizes it', (tester) async {
      await pumpView(tester);
      await engine.setMode(41, const PdfAnnotateMode(input: PdfAnnotateInput.place, inkColorArgb: 0, inkWidth: 1));
      // On screen (0.5 px/pt): page rect 100,600 160x80 → displayed top 120 → screen (50, 60)-(130, 100).
      await engine.show(41, const [PdfAnnotateItem.stamp('s', PdfStamp(pageIndex: 0, rect: PdfRect(100, 600, 160, 80), imagePath: '/s.png'))], selectedId: 's');
      await tester.pump();
      final before = api.shown.length;
      await tester.dragFrom(at(tester, const Offset(80, 80)), const Offset(30, 20));
      await tester.pumpAndSettle();
      final moved = seen.whereType<PdfStampMovedEvent>().single;
      expect(moved.itemId, 's');
      expect([moved.rect.x, moved.rect.y, moved.rect.width, moved.rect.height], [160, 560, 160, 80]);
      expect(api.shown.length, greaterThan(before), reason: 'the drag is shown live');

      seen.clear();
      await tester.dragFrom(at(tester, const Offset(130, 100)), const Offset(40, 40));
      await tester.pumpAndSettle();
      final resized = seen.whereType<PdfStampMovedEvent>().single;
      expect(resized.rect.width / resized.rect.height, closeTo(2, 1e-9));
      expect(resized.rect.width, closeTo(320, 1e-9));
      expect(resized.rect.x, 100, reason: 'the opposite corner stays');
      expect(resized.rect.y + resized.rect.height, closeTo(680, 1e-9));

      seen.clear();
      await tester.dragFrom(at(tester, const Offset(250, 300)), const Offset(0, -40));
      await tester.pumpAndSettle();
      expect(seen.whereType<PdfStampMovedEvent>(), isEmpty, reason: 'other drags scroll');
    });
  });
}
