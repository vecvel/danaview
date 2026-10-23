// OWNER: HOM-24
//
// Fakes of danaview_pdf's PdfDocuments and PdfViewController for the viewer widget tests: a
// document with page tokens, an optional password, an outline, thumbnails as a 1×1 PNG, recorded
// calls, and a stand-in for the native view that hands its controller over once.

import 'dart:async';
import 'dart:typed_data';

import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:flutter/widgets.dart';

/// A 1×1 white PNG.
final Uint8List onePixelPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, //
  0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xFF, 0xFF, 0x3F, //
  0x00, 0x05, 0xFE, 0x02, 0xFE, 0xDC, 0xCC, 0x59, 0xE7, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, //
  0x44, 0xAE, 0x42, 0x60, 0x82,
]);

/// Full Apple capabilities.
const PdfCapabilities appleCaps = PdfCapabilities(
  platformView: true,
  search: true,
  selection: true,
  outline: true,
  passwords: true,
  textExtraction: true,
);

/// A fake document store.
class FakePdfDocuments implements PdfDocuments {
  /// A store whose file has [pages] pages, page i containing `TOKEN-<i+1>`.
  FakePdfDocuments({
    this.pages = 12,
    this.password,
    this.caps = appleCaps,
    this.openError,
    this.outlineEntries = const [
      PdfOutlineEntry(title: 'Introduction', pageIndex: 0),
      PdfOutlineEntry(title: 'Details', pageIndex: 4, depth: 1),
      PdfOutlineEntry(title: 'Appendix', pageIndex: 9),
    ],
    this.probeResult,
  });

  /// Page count.
  final int pages;

  /// The password, when the file is encrypted.
  final String? password;

  /// Capabilities.
  final PdfCapabilities caps;

  /// Thrown by open when set.
  final PdfException? openError;

  /// The outline.
  final List<PdfOutlineEntry> outlineEntries;

  /// What probe answers (default: openable).
  final PdfProbe? probeResult;

  /// Calls, by name.
  final List<String> calls = [];

  /// Handles closed.
  final List<int> closed = [];

  /// Passwords tried (tests only; the product never records them).
  final List<String> tried = [];

  bool _unlocked = false;

  PdfDocumentInfo _info({required bool locked}) => PdfDocumentInfo(
        handle: 7,
        pageCount: locked ? 0 : pages,
        encrypted: password != null,
        locked: locked,
        pageSizes: locked ? const [] : [for (var i = 0; i < pages; i++) PdfPageSize(612, 792, i == 2 ? 90 : 0)],
      );

  @override
  Future<PdfCapabilities> capabilities() async {
    calls.add('capabilities');
    return caps;
  }

  @override
  Future<PdfProbe> probe(String path) async {
    calls.add('probe');
    return probeResult ?? PdfProbe(canOpen: true, encrypted: password != null, pageCount: password != null ? -1 : pages);
  }

  @override
  Future<PdfDocumentInfo> open(String path, {String? password}) async {
    calls.add('open');
    if (openError case final e?) throw e;
    return _info(locked: this.password != null && !_unlocked);
  }

  @override
  Future<PdfDocumentInfo?> unlock(int handle, String password) async {
    calls.add('unlock');
    tried.add(password);
    if (password != this.password) return null;
    _unlocked = true;
    return _info(locked: false);
  }

  @override
  Future<List<PdfOutlineEntry>> outline(int handle) async {
    calls.add('outline');
    return outlineEntries;
  }

  @override
  Future<PdfPageImage> thumbnail(int handle, int pageIndex, {required int maxWidth, required int maxHeight}) async {
    calls.add('thumbnail:$pageIndex');
    return PdfPageImage(png: onePixelPng, width: 1, height: 1);
  }

  @override
  Future<void> close(int handle) async {
    calls.add('close');
    closed.add(handle);
  }
}

/// A fake viewer controller over [docs]' page tokens.
final class FakePdfViewController implements PdfViewController {
  /// A controller of a [pageCount]-page view.
  FakePdfViewController(this.pageCount);

  /// Pages.
  final int pageCount;

  /// Calls, by name.
  final List<String> calls = [];

  /// Selected text.
  String? selection;

  final StreamController<PdfViewState> _states = StreamController<PdfViewState>.broadcast();
  PdfViewState _state = const PdfViewState(viewId: 1, pageIndex: 0, pageCount: 0);

  @override
  int get viewId => 1;

  @override
  Stream<PdfViewState> get states => _states.stream;

  void _emit(PdfViewState s) {
    _state = s;
    _states.add(s);
  }

  /// Simulates the user selecting [text].
  void select(String? text) {
    selection = text;
    _emit(_state.copyWith(hasSelection: text != null));
  }

  @override
  Future<PdfViewState> state() async => _state = PdfViewState(
        viewId: 1,
        pageIndex: _state.pageIndex,
        pageCount: pageCount,
        hasSelection: _state.hasSelection,
        displayMode: _state.displayMode,
      );

  @override
  Future<void> goToPage(int pageIndex) async {
    calls.add('goToPage:$pageIndex');
    _emit(_state.copyWith(pageIndex: pageIndex));
  }

  @override
  Future<void> setScale(double scale) async => calls.add('setScale');

  @override
  Future<void> zoomToFit() async => calls.add('zoomToFit');

  @override
  Future<void> setDisplayMode(PdfDisplayMode mode) async {
    calls.add('mode:${mode.name}');
    _emit(_state.copyWith(displayMode: mode));
  }

  @override
  Future<PdfSearchResult> search(String query, {bool caseSensitive = false, int maxHits = 500}) async {
    calls.add('search');
    final hits = <PdfSearchHit>[];
    for (var i = 0; i < pageCount; i++) {
      final token = 'TOKEN-${i + 1}';
      if (token.toLowerCase().contains(query.toLowerCase())) {
        final snippet = 'Sample page $token with some words after it';
        final start = snippet.indexOf(token);
        hits.add(PdfSearchHit(
          index: hits.length,
          pageIndex: i,
          rangeStart: start,
          rangeLength: token.length,
          snippet: snippet,
          snippetMatchStart: start,
          snippetMatchLength: token.length,
        ));
      }
    }
    return PdfSearchResult(hits);
  }

  @override
  Future<void> cancelSearch() async => calls.add('cancelSearch');

  @override
  Future<void> showSearchHit(PdfSearchHit hit) async {
    calls.add('showHit:${hit.pageIndex}');
    _emit(_state.copyWith(pageIndex: hit.pageIndex));
  }

  @override
  Future<void> clearSearch() async => calls.add('clearSearch');

  @override
  Future<String?> selectedText() async => selection;

  @override
  Future<bool> copySelection() async {
    calls.add('copy');
    return selection != null;
  }

  @override
  Future<void> clearSelection() async => select(null);
}

/// A stand-in for the native view: hands [controller] over once and shows a grey box.
class FakeNativeView extends StatefulWidget {
  /// A view for [controller].
  const FakeNativeView({super.key, required this.controller, required this.onCreated});

  /// The controller handed over.
  final FakePdfViewController controller;

  /// The viewer's callback.
  final ValueChanged<PdfViewController> onCreated;

  @override
  State<FakeNativeView> createState() => _FakeNativeViewState();
}

class _FakeNativeViewState extends State<FakeNativeView> {
  @override
  void initState() {
    super.initState();
    scheduleMicrotask(() => widget.onCreated(widget.controller));
  }

  @override
  Widget build(BuildContext context) => Semantics(
      label: 'Document pages', child: const ColoredBox(key: ValueKey('fake-native-pdf'), color: Color(0xFF808080), child: SizedBox.expand()));
}
