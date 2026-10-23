// OWNER: HOM-24
//
// danaview_pdf's Dart wrappers over the Pigeon surface (BUILD_PLAN HOM-24), checked from here
// because HOM-24 owns no test directory inside packages/danaview_pdf: messages map to the public
// types, platform errors to PdfException (no plugin → notSupportedOnDevice, capabilities → none),
// view events are filtered per view, and the Android texture layout finds pages.

// The wrappers take the generated host APIs; the tests subclass them.
// ignore_for_file: implementation_imports

import 'dart:async';

import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:danaview_pdf/src/pigeon/pdf_api.g.dart';
import 'package:danaview_pdf/src/pigeon/pdf_channels.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Docs extends PdfDocumentHostApi {
  final List<String> calls = [];
  PdfOpenRequestMsg? lastOpen;

  @override
  Future<PdfCapabilitiesMsg> capabilities() async => PdfCapabilitiesMsg(
        platformView: true,
        textureView: false,
        search: true,
        selection: true,
        outline: true,
        passwords: true,
        textExtraction: true,
        tools: [PdfToolKindMsg.merge, PdfToolKindMsg.compress],
      );

  @override
  Future<PdfProbeMsg> probe(String path) async => PdfProbeMsg(canOpen: true, encrypted: true, pageCount: -1);

  @override
  Future<PdfDocumentInfoMsg> open(PdfOpenRequestMsg request) async {
    lastOpen = request;
    return PdfDocumentInfoMsg(
      handle: 3,
      pageCount: 2,
      encrypted: false,
      locked: false,
      allowsCopying: true,
      allowsPrinting: false,
      pageSizes: [PdfPageSizeMsg(width: 612, height: 792, rotation: 0), PdfPageSizeMsg(width: 612, height: 792, rotation: 90)],
      title: 'T',
    );
  }

  @override
  Future<PdfDocumentInfoMsg?> unlock(int handle, String password) async => null;

  @override
  Future<List<PdfOutlineItemMsg>> outline(int handle) async => [PdfOutlineItemMsg(title: 'A', pageIndex: 1, depth: 2)];

  @override
  Future<void> close(int handle) async => throw PlatformException(code: 'notFound', message: 'no such document');
}

final class _Views extends PdfViewHostApi {
  PdfSearchHitMsg? shown;

  @override
  Future<PdfImageMsg> pageThumbnail(PdfThumbnailRequestMsg request) async =>
      PdfImageMsg(png: Uint8List.fromList([1, 2]), widthPx: request.maxWidthPx, heightPx: request.maxHeightPx);

  @override
  Future<PdfSearchResultMsg> search(int viewId, PdfSearchOptionsMsg options) async => PdfSearchResultMsg(
        hits: [
          PdfSearchHitMsg(
            index: 0,
            pageIndex: 4,
            rangeStart: 10,
            rangeLength: 5,
            snippet: 'abc MATCH def',
            snippetMatchStart: 4,
            snippetMatchLength: 5,
            bounds: PdfRectMsg(x: 1, y: 2, width: 3, height: 4),
          ),
        ],
        truncated: true,
      );

  @override
  Future<void> showSearchHit(int viewId, PdfSearchHitMsg hit) async => shown = hit;

  @override
  Future<PdfViewStateMsg> state(int viewId) async => PdfViewStateMsg(
        viewId: viewId,
        pageIndex: 1,
        pageCount: 9,
        scale: 1.5,
        minScale: 0.5,
        maxScale: 4,
        hasSelection: true,
        displayMode: PdfDisplayModeMsg.twoUpContinuous,
      );

  @override
  Future<void> cancelSearch(int viewId) async => throw PlatformException(code: 'cancelled');
}

final class _Text extends PdfTextHostApi {
  PdfTextRequestMsg? last;

  @override
  Future<PdfTextResultMsg> extractText(PdfTextRequestMsg request) async {
    last = request;
    return PdfTextResultMsg(documentPageCount: 5, pages: [PdfPageTextMsg(pageIndex: 2, text: 'hello')], truncated: true);
  }
}

PdfEventMsg _viewEvent(int viewId, int page) => PdfEventMsg(
      kind: PdfEventKindMsg.viewPageChanged,
      viewState: PdfViewStateMsg(
        viewId: viewId,
        pageIndex: page,
        pageCount: 9,
        scale: 1,
        minScale: 1,
        maxScale: 1,
        hasSelection: false,
        displayMode: PdfDisplayModeMsg.continuous,
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('documents map messages to public types', () async {
    final api = _Docs();
    final docs = PlatformPdfDocuments(documentApi: api, viewApi: _Views());
    final caps = await docs.capabilities();
    expect(caps.platformView && caps.search && caps.passwords && caps.canView, isTrue);
    expect(caps.tools, {PdfTool.merge, PdfTool.compress});

    final info = await docs.open('/x.pdf', password: 'pw');
    expect(api.lastOpen!.password, 'pw');
    expect(info.handle, 3);
    expect(info.allowsPrinting, isFalse);
    expect(info.pageSizes[1], const PdfPageSize(612, 792, 90));
    expect(info.pageSizes[1].displayWidth, 792);
    expect(info.pageSizes[1].aspectRatio, closeTo(792 / 612, 1e-9));
    expect(info.toString(), isNot(contains('T')), reason: 'no title in logs');

    expect(await docs.unlock(3, 'bad'), isNull);
    expect(await docs.outline(3), [const PdfOutlineEntry(title: 'A', pageIndex: 1, depth: 2)]);
    final probe = await docs.probe('/x.pdf');
    expect(probe.canOpen && probe.encrypted, isTrue);
    final thumb = await docs.thumbnail(3, 0, maxWidth: 40, maxHeight: 50);
    expect((thumb.width, thumb.height), (40, 50));
    await expectLater(docs.close(3), throwsA(isA<PdfException>().having((e) => e.code, 'code', PdfErrorCode.notFound)));
  });

  test('no plugin: calls fail with notSupportedOnDevice and capabilities are none', () async {
    final docs = PlatformPdfDocuments();
    expect(await docs.capabilities(), same(PdfCapabilities.none));
    await expectLater(docs.open('/x.pdf'), throwsA(isA<PdfException>().having((e) => e.code, 'code', PdfErrorCode.notSupportedOnDevice)));
    await expectLater(
      PlatformPdfTextExtractor().extractText('/x.pdf'),
      throwsA(isA<PdfException>().having((e) => e.code, 'code', PdfErrorCode.notSupportedOnDevice)),
    );
  });

  test('error codes map by name; unknown codes are internal', () async {
    expect(PdfErrorCode.fromCode('passwordRequired'), PdfErrorCode.passwordRequired);
    expect(PdfErrorCode.fromCode('channel-error'), PdfErrorCode.notSupportedOnDevice);
    expect(PdfErrorCode.fromCode('whatever'), PdfErrorCode.internal);
    await expectLater(
      guardPdf<void>(() => throw MissingPluginException()),
      throwsA(isA<PdfException>().having((e) => e.code, 'code', PdfErrorCode.notSupportedOnDevice)),
    );
  });

  test('the view controller maps search hits and state, and filters events per view', () async {
    final source = StreamController<PdfEventMsg>.broadcast();
    addTearDown(source.close);
    final views = _Views();
    final controller = PlatformPdfViewController(5, api: views, events: PdfEventHub.over(() => source.stream));

    final result = await controller.search('match');
    expect(result.truncated, isTrue);
    final hit = result.hits.single;
    expect((hit.pageIndex, hit.before, hit.match, hit.after), (4, 'abc ', 'MATCH', ' def'));
    expect(hit.toString(), isNot(contains('MATCH')), reason: 'no document text in logs');
    await controller.showSearchHit(hit);
    expect((views.shown!.rangeStart, views.shown!.bounds.height), (10, 4.0));

    final state = await controller.state();
    expect((state.pageIndex, state.pageCount, state.hasSelection, state.displayMode), (1, 9, true, PdfDisplayMode.twoUpContinuous));
    await expectLater(controller.cancelSearch(), throwsA(isA<PdfException>().having((e) => e.code, 'code', PdfErrorCode.cancelled)));

    final pages = <int>[];
    final sub = controller.states.listen((s) => pages.add(s.pageIndex));
    source
      ..add(_viewEvent(5, 3))
      ..add(_viewEvent(6, 8))
      ..add(PdfEventMsg(
          kind: PdfEventKindMsg.toolProgress,
          toolProgress: PdfToolProgressMsg(jobId: 'j', tool: PdfToolKindMsg.merge, fraction: 0.5, pagesDone: 1, pagesTotal: 2)))
      ..add(_viewEvent(5, 4));
    await Future<void>.delayed(Duration.zero);
    expect(pages, [3, 4]);
    await sub.cancel();
  });

  test('text extraction passes the range and limits', () async {
    final api = _Text();
    final r = await PlatformPdfTextExtractor(api: api).extractText('/x.pdf', firstPage: 2, pageCount: 1, maxChars: 100);
    expect((api.last!.firstPage, api.last!.pageCount, api.last!.maxChars, api.last!.password), (2, 1, 100, null));
    expect((r.documentPageCount, r.pages.single.pageIndex, r.pages.single.text, r.truncated), (5, 2, 'hello', true));
    expect(r.pages.single.toString(), isNot(contains('hello')));
    await PlatformPdfTextExtractor(api: api).extractText('/x.pdf');
    expect((api.last!.pageCount, api.last!.maxChars), (-1, -1));
  });

  test('the texture layout stacks pages with gaps and finds the page at a height', () {
    final layout = PdfTextureLayout(const [PdfPageSize(600, 800), PdfPageSize(600, 800, 90), PdfPageSize(400, 500)]);
    expect(layout.width, 800);
    expect(layout.topOf(0), 0);
    expect(layout.topOf(1), 808);
    expect(layout.topOf(2), 808 + 600 + 8);
    expect(layout.height, 808 + 608 + 500);
    expect(layout.pageAt(0), 0);
    expect(layout.pageAt(807), 0);
    expect(layout.pageAt(808), 1);
    expect(layout.pageAt(5000), 2);
    expect(PdfTextureLayout(const []).pageAt(10), 0);
  });
}
