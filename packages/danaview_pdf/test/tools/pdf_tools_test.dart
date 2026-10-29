// OWNER: HOM-28
//
// The page tools' Dart contract (lib/src/pdf_tools.dart) against fake Pigeon host APIs: requests
// map to the messages (merge, split, reorder, rotate, delete, organise), malformed requests fail
// with invalidArgument before reaching the engine, progress is filtered to the job's id and the
// stream closes with the job, cancel reaches `PdfToolsHostApi.cancel` and the job fails with
// `cancelled`, platform errors map to PdfException, a missing plugin is notSupportedOnDevice;
// plus the pure helpers (ranges, plans, parsing) every platform shares.

// The wrapper takes the generated host APIs; the tests subclass them.
// ignore_for_file: implementation_imports

import 'dart:async';

import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:danaview_pdf/src/pigeon/pdf_api.g.dart';
import 'package:danaview_pdf/src/pigeon/pdf_channels.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

PdfToolResultMsg _ok(List<String> paths) =>
    PdfToolResultMsg(outPaths: paths, pageCounts: [for (final _ in paths) 2], sizesBytes: [for (final _ in paths) 1000]);

final class _Tools extends PdfToolsHostApi {
  final List<Object> requests = [];
  final List<String> cancelled = [];
  Completer<PdfToolResultMsg>? pending;
  PlatformException? failWith;

  Future<PdfToolResultMsg> _answer(Object request, List<String> paths) {
    requests.add(request);
    if (failWith != null) return Future.error(failWith!);
    final c = pending;
    if (c != null) return c.future;
    return Future.value(_ok(paths));
  }

  @override
  Future<PdfToolResultMsg> merge(PdfMergeRequestMsg request) => _answer(request, [request.outPath]);

  @override
  Future<PdfToolResultMsg> split(PdfSplitRequestMsg request) => _answer(request, request.outPaths);

  @override
  Future<PdfToolResultMsg> reorder(PdfReorderRequestMsg request) => _answer(request, [request.outPath]);

  @override
  Future<PdfToolResultMsg> rotate(PdfRotateRequestMsg request) => _answer(request, [request.outPath]);

  @override
  Future<PdfToolResultMsg> deletePages(PdfDeletePagesRequestMsg request) => _answer(request, [request.outPath]);

  @override
  Future<void> cancel(String jobId) async {
    cancelled.add(jobId);
    pending?.completeError(PlatformException(code: 'cancelled', message: 'cancelled'));
  }
}

final class _Organise extends PdfOrganiseHostApi {
  final List<PdfOrganiseRequestMsg> requests = [];
  bool missing = false;

  @override
  Future<PdfToolResultMsg> organise(PdfOrganiseRequestMsg request) async {
    if (missing) throw PlatformException(code: 'channel-error', message: 'Unable to establish connection on channel.');
    requests.add(request);
    return _ok([request.outPath]);
  }
}

void main() {
  late _Tools tools;
  late _Organise organise;
  late StreamController<PdfEventMsg> events;
  late PlatformPdfPageTools api;

  setUp(() {
    tools = _Tools();
    organise = _Organise();
    events = StreamController<PdfEventMsg>.broadcast();
    api = PlatformPdfPageTools(toolsApi: tools, organiseApi: organise, events: PdfEventHub.over(() => events.stream));
  });

  tearDown(() => events.close());

  const a = PdfToolInput.pdf('/in/a.pdf');
  const b = PdfToolInput.pdf('/in/b.pdf', password: 'pw');
  const photo = PdfToolInput.image('/in/c.heic');

  group('requests map to the Pigeon messages', () {
    test('merge', () async {
      final r = await api.merge([a, b, photo], outPath: '/out/m.pdf').result;
      final m = tools.requests.single as PdfMergeRequestMsg;
      expect(m.outPath, '/out/m.pdf');
      expect([for (final i in m.inputs) (i.path, i.password, i.isImage)], [('/in/a.pdf', null, false), ('/in/b.pdf', 'pw', false), ('/in/c.heic', null, true)]);
      expect(m.jobId, isNotEmpty);
      expect(r.outPaths, ['/out/m.pdf']);
      expect(r.pageCounts, [2]);
      expect(r.sizesBytes, [1000]);
    });

    test('split', () async {
      await api.split(a, const [PdfPageRange(0, 2), PdfPageRange(2, 5)], outPaths: ['/o/1.pdf', '/o/2.pdf']).result;
      final m = tools.requests.single as PdfSplitRequestMsg;
      expect([for (final r in m.ranges) (r.start, r.end)], [(0, 2), (2, 5)]);
      expect(m.outPaths, ['/o/1.pdf', '/o/2.pdf']);
    });

    test('reorder, rotate, delete', () async {
      await api.reorder(a, [2, 0, 1], outPath: '/o/r.pdf').result;
      await api.rotate(a, [1], degrees: -90, outPath: '/o/t.pdf').result;
      await api.deletePages(a, [0], outPath: '/o/d.pdf').result;
      expect((tools.requests[0] as PdfReorderRequestMsg).order, [2, 0, 1]);
      expect((tools.requests[1] as PdfRotateRequestMsg).degrees, -90);
      expect((tools.requests[2] as PdfDeletePagesRequestMsg).pages, [0]);
    });

    test('organise goes to the HOM-28 amendment API', () async {
      await api.organise(a, const [PdfPagePlan(4, rotation: 90), PdfPagePlan(0)], outPath: '/o/x.pdf').result;
      final m = organise.requests.single;
      expect([for (final p in m.pages) (p.sourcePage, p.rotation)], [(4, 90), (0, 0)]);
      expect(m.input.path, '/in/a.pdf');
    });

    test('every job gets its own id', () async {
      final j1 = api.merge([a, b], outPath: '/o/1.pdf');
      final j2 = api.merge([a, b], outPath: '/o/2.pdf');
      await Future.wait([j1.result, j2.result]);
      expect(j1.id, isNot(j2.id));
      expect([for (final r in tools.requests) (r as PdfMergeRequestMsg).jobId], [j1.id, j2.id]);
    });
  });

  group('malformed requests fail before the engine', () {
    Future<void> rejects(PdfToolJob job) async {
      await expectLater(job.result, throwsA(isA<PdfException>().having((e) => e.code, 'code', PdfErrorCode.invalidArgument)));
    }

    test('each tool', () async {
      await rejects(api.merge([a], outPath: '/o/m.pdf'));
      await rejects(api.merge([a, b], outPath: ''));
      await rejects(api.merge([a, b], outPath: '/in/a.pdf'));
      await rejects(api.split(a, const [PdfPageRange(0, 2)], outPaths: const []));
      await rejects(api.split(a, const [PdfPageRange(2, 2)], outPaths: const ['/o/1.pdf']));
      await rejects(api.split(photo, const [PdfPageRange(0, 1)], outPaths: const ['/o/1.pdf']));
      await rejects(api.split(a, const [PdfPageRange(0, 1), PdfPageRange(1, 2)], outPaths: const ['/o/1.pdf', '/o/1.pdf']));
      await rejects(api.reorder(a, [0, 0, 1], outPath: '/o/r.pdf'));
      await rejects(api.rotate(a, [0], degrees: 45, outPath: '/o/r.pdf'));
      await rejects(api.rotate(a, const [], outPath: '/o/r.pdf'));
      await rejects(api.deletePages(a, const [], outPath: '/o/r.pdf'));
      await rejects(api.organise(a, const [], outPath: '/o/r.pdf'));
      await rejects(api.organise(a, const [PdfPagePlan(1), PdfPagePlan(1)], outPath: '/o/r.pdf'));
      await rejects(api.organise(photo, const [PdfPagePlan(0)], outPath: '/o/r.pdf'));
      expect(tools.requests, isEmpty);
      expect(organise.requests, isEmpty);
    });
  });

  test('progress is filtered to the job and closes with it', () async {
    tools.pending = Completer<PdfToolResultMsg>();
    final job = api.merge([a, b], outPath: '/o/m.pdf');
    final seen = <String>[];
    final closed = Completer<void>();
    job.progress.listen((p) => seen.add('${p.pagesDone}/${p.pagesTotal}'), onDone: closed.complete);
    PdfEventMsg ev(String id, int done) => PdfEventMsg(
          kind: PdfEventKindMsg.toolProgress,
          toolProgress: PdfToolProgressMsg(jobId: id, tool: PdfToolKindMsg.merge, fraction: done / 4, pagesDone: done, pagesTotal: 4),
        );
    events
      ..add(ev(job.id, 1))
      ..add(ev('other', 2))
      ..add(PdfEventMsg(kind: PdfEventKindMsg.viewPageChanged))
      ..add(ev(job.id, 4));
    await pumpEventQueue();
    tools.pending!.complete(_ok(['/o/m.pdf']));
    await job.result;
    await closed.future;
    expect(seen, ['1/4', '4/4']);
  });

  test('cancel reaches the engine and the job fails with cancelled', () async {
    tools.pending = Completer<PdfToolResultMsg>();
    final job = api.merge([a, b], outPath: '/o/m.pdf');
    await job.cancel();
    expect(tools.cancelled, [job.id]);
    await expectLater(job.result, throwsA(isA<PdfException>().having((e) => e.code, 'code', PdfErrorCode.cancelled)));
    // Cancelling a finished job does nothing.
    await job.cancel();
    expect(tools.cancelled, [job.id]);
  });

  test('platform errors map to PdfException; a missing plugin is notSupportedOnDevice', () async {
    tools.failWith = PlatformException(code: 'passwordRequired', message: 'document is locked');
    await expectLater(
      api.rotate(a, [0], outPath: '/o/r.pdf').result,
      throwsA(isA<PdfException>().having((e) => e.code, 'code', PdfErrorCode.passwordRequired)),
    );
    organise.missing = true;
    await expectLater(
      api.organise(a, const [PdfPagePlan(0)], outPath: '/o/r.pdf').result,
      throwsA(isA<PdfException>().having((e) => e.code, 'code', PdfErrorCode.notSupportedOnDevice)),
    );
  });

  group('helpers', () {
    test('rangesEvery', () {
      expect(rangesEvery(2, 5), const [PdfPageRange(0, 2), PdfPageRange(2, 4), PdfPageRange(4, 5)]);
      expect(rangesEvery(10, 3), const [PdfPageRange(0, 3)]);
      expect(rangesEvery(0, 3), isEmpty);
    });

    test('parsePageRanges and formatPageRanges', () {
      expect(parsePageRanges('1-3, 5; 7–9', 10), const [PdfPageRange(0, 3), PdfPageRange(4, 5), PdfPageRange(6, 9)]);
      expect(parsePageRanges(' 2 to 4 ', 10), const [PdfPageRange(1, 4)]);
      expect(parsePageRanges('', 10), isNull);
      expect(parsePageRanges('0-2', 10), isNull);
      expect(parsePageRanges('3-2', 10), isNull);
      expect(parsePageRanges('1-11', 10), isNull);
      expect(parsePageRanges('a', 10), isNull);
      expect(formatPageRanges(const [PdfPageRange(0, 3), PdfPageRange(4, 5)]), '1–3, 5');
    });

    test('plans', () {
      expect(reorderPlan([1, 0]), const [PdfPagePlan(1), PdfPagePlan(0)]);
      expect(() => reorderPlan([1, 1]), throwsA(isA<PdfException>()));
      expect(rotatePlan([1], -90, 3), const [PdfPagePlan(0), PdfPagePlan(1, rotation: 270), PdfPagePlan(2)]);
      expect(deletePlan([0, 2], 3), const [PdfPagePlan(1)]);
      expect(() => deletePlan([0, 1, 2], 3), throwsA(isA<PdfException>()));
      expect(isIdentityPlan(identityPlan(3), 3), isTrue);
      expect(isIdentityPlan(const [PdfPagePlan(0), PdfPagePlan(1, rotation: 90)], 2), isFalse);
      expect(const PdfPagePlan(0, rotation: 270).rotated(90), const PdfPagePlan(0));
      expect(() => validatePlan(const [PdfPagePlan(3)], pageCount: 3), throwsA(isA<PdfException>()));
      expect(canOrganise({PdfTool.reorder, PdfTool.rotate, PdfTool.deletePages}), isTrue);
      expect(canOrganise({PdfTool.reorder, PdfTool.rotate}), isFalse);
    });

    test('toString never prints paths or passwords (rule 30)', () {
      expect(b.toString(), isNot(contains('pw')));
      expect(b.toString(), isNot(contains('/in')));
      expect(const PdfToolResult(outPaths: ['/secret/x.pdf'], pageCounts: [1], sizesBytes: [1]).toString(), isNot(contains('secret')));
    });
  });
}
