// OWNER: HOM-31
//
// danaview_pdf's compress wrapper (BUILD_PLAN HOM-31) over fake host APIs: requests carry the
// preset, input and output; progress events of the job (and only of the job) reach onProgress;
// platform errors become PdfException; a missing estimate API answers null; cancel goes through.

// The wrapper takes the generated host APIs; the tests subclass them.
// ignore_for_file: implementation_imports

import 'dart:async';

import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:danaview_pdf/src/pigeon/pdf_api.g.dart';
import 'package:danaview_pdf/src/pigeon/pdf_channels.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Tools extends PdfToolsHostApi {
  PdfCompressRequestMsg? last;
  final List<String> cancelled = [];
  Object? fail;
  Completer<void>? gate;

  @override
  Future<PdfToolResultMsg> compress(PdfCompressRequestMsg request) async {
    last = request;
    await gate?.future;
    if (fail case final f?) throw f;
    return PdfToolResultMsg(outPaths: [request.outPath], pageCounts: [3], sizesBytes: [1234]);
  }

  @override
  Future<void> cancel(String jobId) async => cancelled.add(jobId);
}

final class _Estimates extends PdfCompressHostApi {
  Object? fail;
  PdfToolInputMsg? last;

  @override
  Future<PdfCompressEstimateMsg> estimate(PdfToolInputMsg input) async {
    last = input;
    if (fail case final f?) throw f;
    return PdfCompressEstimateMsg(sourceBytes: 1000, highBytes: 800, mediumBytes: 300, smallBytes: 100, sampled: true);
  }
}

PdfEventMsg _progress(String job, double fraction) => PdfEventMsg(
      kind: PdfEventKindMsg.toolProgress,
      toolProgress: PdfToolProgressMsg(jobId: job, tool: PdfToolKindMsg.compress, fraction: fraction, pagesDone: 0, pagesTotal: 0),
    );

void main() {
  late _Tools tools;
  late _Estimates estimates;
  late StreamController<PdfEventMsg> events;
  late PlatformPdfCompressEngine engine;

  setUp(() {
    tools = _Tools();
    estimates = _Estimates();
    events = StreamController<PdfEventMsg>.broadcast();
    engine = PlatformPdfCompressEngine(toolsApi: tools, compressApi: estimates, events: PdfEventHub.over(() => events.stream));
  });

  tearDown(() => events.close());

  test('compress sends the request and maps the result', () async {
    final out = await engine.compress(jobId: 'j', path: '/in.pdf', preset: PdfCompressPreset.small, outPath: '/out.pdf', password: 'pw');
    expect(tools.last!.jobId, 'j');
    expect(tools.last!.preset, PdfCompressPresetMsg.small);
    expect(tools.last!.input.path, '/in.pdf');
    expect(tools.last!.input.password, 'pw');
    expect(tools.last!.input.isImage, isFalse);
    expect(tools.last!.outPath, '/out.pdf');
    expect(out.path, '/out.pdf');
    expect(out.sizeBytes, 1234);
    expect(out.pageCount, 3);
  });

  test('onProgress gets this job\'s progress only, until the job ends', () async {
    tools.gate = Completer<void>();
    final seen = <double>[];
    final run = engine.compress(jobId: 'mine', path: '/a', preset: PdfCompressPreset.high, outPath: '/b', onProgress: seen.add);
    await pumpEventQueue();
    events
      ..add(_progress('other', 0.9))
      ..add(_progress('mine', 0.25))
      ..add(PdfEventMsg(kind: PdfEventKindMsg.viewPageChanged))
      ..add(_progress('mine', 1.5));
    await pumpEventQueue();
    tools.gate!.complete();
    await run;
    events.add(_progress('mine', 0.5));
    await pumpEventQueue();
    expect(seen, [0.25, 1.0]);
  });

  test('platform errors become PdfException; cancel reaches the host', () async {
    tools.fail = PlatformException(code: 'cancelled', message: 'cancelled');
    await expectLater(
      engine.compress(jobId: 'j', path: '/a', preset: PdfCompressPreset.medium, outPath: '/b'),
      throwsA(isA<PdfException>().having((e) => e.code, 'code', PdfErrorCode.cancelled)),
    );
    tools.fail = PlatformException(code: 'passwordRequired');
    await expectLater(
      engine.compress(jobId: 'j', path: '/a', preset: PdfCompressPreset.medium, outPath: '/b'),
      throwsA(isA<PdfException>().having((e) => e.code, 'code', PdfErrorCode.passwordRequired)),
    );
    await engine.cancel('j');
    expect(tools.cancelled, ['j']);
  });

  test('estimate maps every preset; a missing API answers null; other errors throw', () async {
    final e = await engine.estimate('/a.pdf', password: 'pw');
    expect(estimates.last!.password, 'pw');
    expect(e!.sourceBytes, 1000);
    expect(e.bytes, {PdfCompressPreset.high: 800, PdfCompressPreset.medium: 300, PdfCompressPreset.small: 100});
    expect(e.sampled, isTrue);
    estimates.fail = PlatformException(code: 'channel-error');
    expect(await engine.estimate('/a.pdf'), isNull);
    estimates.fail = PlatformException(code: 'damaged');
    await expectLater(engine.estimate('/a.pdf'), throwsA(isA<PdfException>().having((e) => e.code, 'code', PdfErrorCode.damaged)));
  });
}
