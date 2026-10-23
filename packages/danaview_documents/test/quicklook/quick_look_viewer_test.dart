// OWNER: HOM-26
//
// BUILD_PLAN HOM-26 Quick Look viewer (HOM plan §8.4, ARCH §3, V2-120): with Quick Look registered,
// docx, xlsx, pptx, txt and csv open in Quick Look on iOS and macOS and an unknown type gets the
// file card ("previewed or carded"); a type Quick Look can't preview goes on to the next candidate;
// the preview opens with the file, closing it closes the viewer (or offers "Show preview again"),
// a preview that fails to open falls back through the host; the probe never throws; and the ARCH
// §1.4 matrix: no overflow at 280–1280 px × text scale 0.85–1.35, targets ≥ 44 px, labelled
// controls.

import 'dart:async';

import 'package:danaview_documents/danaview_documents.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../card/doc_harness.dart';

/// Quick Look by extension, with presentations the test completes or fails.
final class FakeQuickLook implements QuickLookPort {
  /// Extensions it previews.
  Set<String> previewable = {'docx', 'xlsx', 'pptx', 'txt', 'csv', 'pdf'};

  /// Thrown by canPreview when set.
  Object? probeError;

  /// Thrown by present when set.
  Object? presentError;

  /// Every presentation: files and the completer that dismisses it.
  final List<(List<ViewerFile>, Completer<void>)> shown = [];

  @override
  Future<bool> canPreview(ViewerFile file) async {
    if (probeError case final e?) throw e;
    return previewable.contains(file.extension);
  }

  @override
  Future<void> present(List<ViewerFile> files, {int initialIndex = 0}) {
    if (presentError case final e?) return Future.error(e);
    final c = Completer<void>();
    shown.add((files, c));
    return c.future;
  }

  /// Dismisses the last preview.
  void dismiss() => shown.last.$2.complete();
}

ViewerFile _file(String name, {String path = '/lib/files/fe_x/blob'}) =>
    ViewerFile(path: path, displayName: name, kind: FileKind.document, sizeBytes: 2048, modifiedAt: DateTime(2026, 10, 21, 14, 30));

Widget _host(ViewerFile file, FakeQuickLook ql, {required List<ViewerKind> shown, ViewerPlatform platform = ViewerPlatform.iOS, VoidCallback? onClose}) =>
    DocumentViewer(
      file: file,
      platform: platform,
      viewers: {ViewerKind.quickLook: quickLookViewerBuilder(ql)},
      probes: FunctionProbes({ViewerKind.quickLook: quickLookProbe(ql)}),
      onResolved: shown.add,
      onClose: onClose,
    );

void main() {
  for (final platform in [ViewerPlatform.iOS, ViewerPlatform.macOS]) {
    testWidgets('${platform.name}: Office, text and CSV are previewed, an unknown type is carded', (tester) async {
      for (final name in ['Report.docx', 'Budget.xlsx', 'Deck.pptx', 'notes.txt', 'table.csv', 'blob.qqzz']) {
        final ql = FakeQuickLook();
        final shown = <ViewerKind>[];
        await tester.pumpWidget(docApp(KeyedSubtree(key: ValueKey(name), child: _host(_file(name), ql, shown: shown, platform: platform))));
        await tester.pump();
        await tester.pump();
        final expected = name.endsWith('.qqzz') ? ViewerKind.fileCard : ViewerKind.quickLook;
        expect(shown, [expected], reason: name);
        if (expected == ViewerKind.quickLook) {
          expect(ql.shown, hasLength(1), reason: name);
          expect(ql.shown.single.$1.single.displayName, name);
          ql.dismiss();
          await tester.pump();
          await tester.pump();
        } else {
          expect(ql.shown, isEmpty, reason: name);
          expect(find.text('Open in another app'), findsNothing, reason: 'no port in this test');
        }
      }
    });
  }

  testWidgets('a type Quick Look turns down goes on to the in-app viewer or the card', (tester) async {
    final ql = FakeQuickLook()..previewable = {};
    final shown = <ViewerKind>[];
    await tester.pumpWidget(docApp(_host(_file('Report.docx'), ql, shown: shown)));
    await tester.pump();
    expect(shown, [ViewerKind.fileCard]);
    expect(ql.shown, isEmpty);
  });

  testWidgets('the probe never throws: an error counts as "can not"', (tester) async {
    final ql = FakeQuickLook()..probeError = StateError('notFound');
    expect(await quickLookProbe(ql)(_file('Report.docx')), isFalse);
    ql.probeError = null;
    expect(await quickLookProbe(ql)(_file('Report.docx')), isTrue);
    expect(await quickLookProbe(ql)(_file('blob.qqzz')), isFalse);
  });

  testWidgets('closing the preview closes the viewer', (tester) async {
    final ql = FakeQuickLook();
    var closed = 0;
    await tester.pumpWidget(docApp(_host(_file('Report.docx'), ql, shown: [], onClose: () => closed++)));
    await tester.pump();
    await tester.pump();
    expect(ql.shown, hasLength(1));
    expect(find.text('Showing the preview.'), findsOneWidget);
    expect(find.text('Report.docx'), findsOneWidget);
    expect(closed, 0);
    ql.dismiss();
    await tester.pump();
    await tester.pump();
    expect(closed, 1);
  });

  testWidgets('without a close callback the screen offers the preview again', (tester) async {
    final ql = FakeQuickLook();
    await tester.pumpWidget(docApp(QuickLookViewer(file: _file('Budget.xlsx'), port: ql)));
    await tester.pump();
    expect(ql.shown, hasLength(1));
    expect(find.text('Show preview again'), findsNothing);
    ql.dismiss();
    await tester.pump();
    await tester.pump();
    expect(find.text('Preview closed.'), findsOneWidget);
    await tester.tap(find.text('Show preview again'));
    await tester.pump();
    expect(ql.shown, hasLength(2));
    expect(find.text('Show preview again'), findsNothing);
  });

  testWidgets('a preview that fails to open falls back to the next candidate', (tester) async {
    final ql = FakeQuickLook()..presentError = StateError('ioError');
    final shown = <ViewerKind>[];
    await tester.pumpWidget(docApp(_host(_file('Deck.pptx'), ql, shown: shown)));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(shown, [ViewerKind.quickLook, ViewerKind.fileCard]);
    expect(find.text('This file can\'t be shown here.'), findsOneWidget);
  });

  testWidgets('matrix: no overflow, targets and labels while showing and after closing', (tester) async {
    final name = 'Quarterly report with a rather long name for small phones and big text.docx';
    for (final surface in docMatrix) {
      applyDocSurface(tester, surface);
      final ql = FakeQuickLook();
      await tester.pumpWidget(docApp(
        KeyedSubtree(key: ValueKey(surface.toString()), child: QuickLookViewer(file: _file(name), port: ql)),
        textScale: surface.textScale,
      ));
      await tester.pump();
      expectNoLayoutErrors(tester, surface);
      ql.dismiss();
      await tester.pump();
      await tester.pump();
      expectNoLayoutErrors(tester, surface);
      await expectTargetsAndLabels(tester);
    }
    final ql = FakeQuickLook();
    await tester.pumpWidget(docApp(KeyedSubtree(key: const ValueKey('bar'), child: QuickLookViewer(file: _file(name), port: ql, onClose: () {}))));
    await tester.pump();
    expect(find.bySemanticsLabel('Back'), findsOneWidget);
    expect(find.bySemanticsLabel('Document'), findsWidgets, reason: 'the type tile is labelled');
  });
}
