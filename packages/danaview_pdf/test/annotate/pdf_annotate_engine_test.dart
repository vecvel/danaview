// OWNER: HOM-29
//
// The annotate Dart contract (lib/src/pdf_annotate.dart) against fake Pigeon host APIs: the mode,
// preview and selection calls map to the HOM-29 amendment's messages, events from
// `PdfAnnotateEventsApi` reach the right viewer, the save maps annotations (markup rects, ink
// strokes flattened, text) and HOM-30's stamps and burn-in, malformed saves fail before the engine,
// progress is filtered to the job, cancel reaches `PdfToolsHostApi.cancel`, and a missing host API
// is notSupportedOnDevice.

// The wrapper takes the generated host APIs; the tests subclass them.
// ignore_for_file: implementation_imports

import 'dart:async';
import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:danaview_pdf/src/pigeon/pdf_api.g.dart';
import 'package:danaview_pdf/src/pigeon/pdf_channels.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Annotate extends PdfAnnotateHostApi {
  final List<(int, PdfAnnotateModeMsg?)> modes = [];
  final List<(int, List<PdfAnnotateItemMsg>, String?)> shown = [];
  final List<PdfAnnotateSaveRequestMsg> saves = [];
  Completer<PdfToolResultMsg>? pending;
  bool missing = false;

  void _check() {
    if (missing) throw PlatformException(code: 'channel-error', message: 'Unable to establish connection on channel.');
  }

  @override
  Future<void> setAnnotateMode(int viewId, PdfAnnotateModeMsg? mode) async {
    _check();
    modes.add((viewId, mode));
  }

  @override
  Future<void> showAnnotations(int viewId, List<PdfAnnotateItemMsg> items, String? selectedId) async {
    _check();
    shown.add((viewId, items, selectedId));
  }

  @override
  Future<List<PdfPageRectsMsg>> selectionLines(int viewId) async {
    _check();
    return [
      PdfPageRectsMsg(pageIndex: 2, rects: [PdfRectMsg(x: 1, y: 2, width: 30, height: 12), PdfRectMsg(x: 1, y: 20, width: 40, height: 12)]),
    ];
  }

  @override
  Future<PdfToolResultMsg> save(PdfAnnotateSaveRequestMsg request) {
    _check();
    saves.add(request);
    return pending?.future ?? Future.value(PdfToolResultMsg(outPaths: [request.outPath], pageCounts: [3], sizesBytes: [900]));
  }
}

final class _Tools extends PdfToolsHostApi {
  final List<String> cancelled = [];
  _Annotate? host;

  @override
  Future<void> cancel(String jobId) async {
    cancelled.add(jobId);
    host?.pending?.completeError(PlatformException(code: 'cancelled', message: 'cancelled'));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Annotate annotate;
  late _Tools tools;
  late StreamController<PdfEventMsg> events;
  late StreamController<PdfAnnotateEvent> viewEvents;
  late PlatformPdfAnnotateEngine engine;

  setUp(() {
    annotate = _Annotate();
    tools = _Tools()..host = annotate;
    events = StreamController<PdfEventMsg>.broadcast();
    viewEvents = StreamController<PdfAnnotateEvent>.broadcast();
    engine = PlatformPdfAnnotateEngine(
      annotateApi: annotate,
      toolsApi: tools,
      events: PdfEventHub.over(() => events.stream),
      annotateEvents: viewEvents.stream,
    );
  });

  tearDown(() async {
    await events.close();
    await viewEvents.close();
  });

  const input = PdfToolInput.pdf('/in/a.pdf', password: 'pw');
  const highlight = PdfAnnotation.markup(PdfAnnotationKind.highlight, 0, [PdfRect(10, 20, 100, 14)], colorArgb: 0x80FFD60A);
  const ink = PdfAnnotation.ink(1, [
    [Offset(1, 2), Offset(3, 4)],
    [Offset(5, 6)],
  ], colorArgb: 0xFF000000, lineWidth: 4);
  final text = PdfAnnotation.freeText(2, const Offset(72, 400), 'Hello', colorArgb: 0xFF1E88E5);

  test('mode, preview and selection map to the amendment API', () async {
    await engine.setMode(7, const PdfAnnotateMode(input: PdfAnnotateInput.ink, inkColorArgb: 0xFFE53935, inkWidth: 3));
    await engine.setMode(7, null);
    expect(annotate.modes[0].$1, 7);
    expect(annotate.modes[0].$2!.input, PdfAnnotateInputMsg.ink);
    expect(annotate.modes[0].$2!.inkColorArgb, 0xFFE53935);
    expect(annotate.modes[0].$2!.inkWidth, 3);
    expect(annotate.modes[1].$2, isNull);

    await engine.show(7, [const PdfAnnotateItem.annotation('a', highlight), const PdfAnnotateItem.stamp('s', PdfStamp(pageIndex: 1, rect: PdfRect(1, 2, 3, 4), imagePath: '/sig.png'))], selectedId: 'a');
    final (view, items, selected) = annotate.shown.single;
    expect(view, 7);
    expect(selected, 'a');
    expect(items.map((i) => i.id), ['a', 's']);
    expect(items[0].annotation!.kind, PdfAnnotationKindMsg.highlight);
    expect(items[0].stamp, isNull);
    expect(items[1].stamp!.imagePath, '/sig.png');

    final lines = await engine.selectionLines(7);
    expect(lines.single.pageIndex, 2);
    expect([for (final r in lines.single.rects) (r.x, r.y, r.width, r.height)], [(1, 2, 30, 12), (1, 20, 40, 12)]);
  });

  test('events reach their viewer only; the native hub turns flat points into offsets', () async {
    final seen = <PdfAnnotateEvent>[];
    final sub = engine.events(7).listen(seen.add);
    viewEvents
      ..add(const PdfInkStrokeEvent(7, 0, [Offset(1, 2)]))
      ..add(const PdfAnnotateTapEvent(8, 0, Offset(1, 1), null))
      ..add(const PdfAnnotateTapEvent(7, 1, Offset(5, 6), 'x'));
    await pumpEventQueue();
    await sub.cancel();
    expect(seen, hasLength(2));
    expect((seen[1] as PdfAnnotateTapEvent).itemId, 'x');

    // The hub that the native side calls.
    final hub = PlatformPdfAnnotateEngine.debugHub('test-instance');
    final defaultEngine = PlatformPdfAnnotateEngine(annotateApi: annotate, toolsApi: tools);
    final got = <PdfAnnotateEvent>[];
    final sub2 = defaultEngine.events(3).listen(got.add);
    PlatformPdfAnnotateEngine.debugHub().inkStroke(3, 1, [10, 20, 30, 40]);
    PlatformPdfAnnotateEngine.debugHub().inkStroke(3, 1, []);
    PlatformPdfAnnotateEngine.debugHub().tapped(3, 0, 1.5, 2.5, null);
    await pumpEventQueue();
    await sub2.cancel();
    expect(got, hasLength(2), reason: 'an empty stroke is dropped');
    expect((got[0] as PdfInkStrokeEvent).points, const [Offset(10, 20), Offset(30, 40)]);
    expect((got[1] as PdfAnnotateTapEvent).point, const Offset(1.5, 2.5));
    expect(hub, isNotNull);
  });

  test('save maps annotations, stamps and burn-in, and reports progress for its job only', () async {
    annotate.pending = Completer<PdfToolResultMsg>();
    final job = engine.save(
      input,
      annotations: [highlight, ink, text],
      stamps: const [PdfStamp(pageIndex: 0, rect: PdfRect(5, 6, 70, 30), imagePath: '/sig.png', rotationDegrees: 15)],
      burnIn: true,
      outPath: '/out/a (annotated).pdf',
    );
    final progress = <PdfToolProgress>[];
    final sub = job.progress.listen(progress.add);
    events
      ..add(PdfEventMsg(kind: PdfEventKindMsg.toolProgress, toolProgress: PdfToolProgressMsg(jobId: 'other', tool: PdfToolKindMsg.annotate, fraction: 0.9, pagesDone: 1, pagesTotal: 1)))
      ..add(PdfEventMsg(kind: PdfEventKindMsg.toolProgress, toolProgress: PdfToolProgressMsg(jobId: job.id, tool: PdfToolKindMsg.annotate, fraction: 0.5, pagesDone: 1, pagesTotal: 2)));
    await pumpEventQueue();
    annotate.pending!.complete(PdfToolResultMsg(outPaths: ['/out/a (annotated).pdf'], pageCounts: [3], sizesBytes: [900]));
    final result = await job.result;
    await sub.cancel();
    expect(result.outPaths, ['/out/a (annotated).pdf']);
    expect(progress.map((p) => p.fraction), [0.5]);
    final m = annotate.saves.single;
    expect(m.jobId, job.id);
    expect((m.input.path, m.input.password, m.input.isImage), ('/in/a.pdf', 'pw', false));
    expect(m.burnIn, isTrue);
    expect(m.annotations.map((a) => a.kind), [PdfAnnotationKindMsg.highlight, PdfAnnotationKindMsg.ink, PdfAnnotationKindMsg.freeText]);
    expect(m.annotations[0].colorArgb, 0x80FFD60A);
    expect([for (final r in m.annotations[0].rects) (r.x, r.y, r.width, r.height)], [(10, 20, 100, 14)]);
    expect([for (final s in m.annotations[1].strokes) s.points], [
      [1, 2, 3, 4],
      [5, 6],
    ]);
    expect(m.annotations[1].lineWidth, 4);
    expect(m.annotations[2].text, 'Hello');
    expect(m.annotations[2].rects.single.width, 200);
    expect(m.stamps.single.rotationDegrees, 15);
  });

  test('malformed saves fail before the engine', () async {
    Future<void> rejects(PdfToolJob job) =>
        expectLater(job.result, throwsA(isA<PdfException>().having((e) => e.code, 'code', PdfErrorCode.invalidArgument)));
    await rejects(engine.save(input, annotations: const [], outPath: '/o.pdf'));
    await rejects(engine.save(input, annotations: [highlight], outPath: '/in/a.pdf'));
    await rejects(engine.save(const PdfToolInput.image('/in/c.jpg'), annotations: [highlight], outPath: '/o.pdf'));
    await rejects(engine.save(input, annotations: const [PdfAnnotation.markup(PdfAnnotationKind.underline, 0, [], colorArgb: 0)], outPath: '/o.pdf'));
    await rejects(engine.save(input, annotations: const [PdfAnnotation.ink(0, [[]], colorArgb: 0)], outPath: '/o.pdf'));
    await rejects(engine.save(input, annotations: [PdfAnnotation.freeText(0, Offset.zero, '  ', colorArgb: 0)], outPath: '/o.pdf'));
    await rejects(engine.save(input, annotations: const [], stamps: const [PdfStamp(pageIndex: 0, rect: PdfRect(0, 0, 0, 1), imagePath: '/s.png')], outPath: '/o.pdf'));
    expect(annotate.saves, isEmpty);
  });

  test('cancel reaches PdfToolsHostApi.cancel and the job fails with cancelled', () async {
    annotate.pending = Completer<PdfToolResultMsg>();
    final job = engine.save(input, annotations: [ink], outPath: '/o.pdf');
    await pumpEventQueue();
    await job.cancel();
    await expectLater(job.result, throwsA(isA<PdfException>().having((e) => e.code, 'code', PdfErrorCode.cancelled)));
    expect(tools.cancelled, [job.id]);
  });

  test('a missing host API is notSupportedOnDevice', () async {
    annotate.missing = true;
    await expectLater(engine.setMode(1, null), throwsA(isA<PdfException>().having((e) => e.code, 'code', PdfErrorCode.notSupportedOnDevice)));
    await expectLater(
      engine.save(input, annotations: [ink], outPath: '/o.pdf').result,
      throwsA(isA<PdfException>().having((e) => e.code, 'code', PdfErrorCode.notSupportedOnDevice)),
    );
  });

  test('annotations compare by value and never print their text', () {
    expect(PdfAnnotation.freeText(2, const Offset(72, 400), 'Hello', colorArgb: 0xFF1E88E5), text);
    expect(text.withText('Bye').text, 'Bye');
    expect(text.withText('Bye'), isNot(text));
    expect(text.toString(), isNot(contains('Hello')));
    expect(PdfAnnotationKind.highlight.isMarkup, isTrue);
    expect(PdfAnnotationKind.ink.isMarkup, isFalse);
  });
}
