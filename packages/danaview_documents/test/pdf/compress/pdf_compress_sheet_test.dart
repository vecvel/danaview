// OWNER: HOM-31
//
// The compress sheet (BUILD_PLAN HOM-31) over a fake engine: idle (size now, every preset with its
// estimate, then its measured size), running (progress, presets locked), cancel (back to idle,
// nothing saved, temporary file gone), done (a NEW file "<name> (compressed).pdf" saved, before →
// after and the saving shown), not smaller (said plainly, nothing saved), error (plain message,
// Try again); closing mid-run cancels the job; and the §1.4 matrix at 280 / 375 / 1280 px × text
// scale 0.85 / 1.35 in every state with 44 px labelled targets.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:danaview_documents/danaview_documents.dart';
import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../card/doc_harness.dart';
import 'compress_fakes.dart';

/// A 10,000-byte "PDF" (the engine is fake; only its size matters).
String _source(Directory dir, {int bytes = 10000}) {
  final f = File('${dir.path}/Report.pdf')..writeAsBytesSync(Uint8List(bytes));
  return f.path;
}

class _Harness {
  _Harness(this.engine, this.dir, {this.saveError});

  final FakeCompressEngine engine;
  final Directory dir;
  final Object? saveError;
  final List<(String, String, bool)> saved = []; // (temp, name, temp existed)
  late PdfCompressController controller;
  bool closed = false;

  Widget panel({String? password}) => Padding(
        padding: const EdgeInsets.all(16),
        child: PdfCompressPanel(
          controller: () => controller = PdfCompressController(
            engine: engine,
            path: _source(dir),
            displayName: 'Report.pdf',
            password: password,
            tempDirectory: '${dir.path}/tmp',
            save: (temp, name) async {
              saved.add((temp, name, File(temp).existsSync()));
              if (saveError case final e?) throw e;
              return name;
            },
          ),
          onClose: () => closed = true,
        ),
      );

  List<FileSystemEntity> temps() {
    final t = Directory('${dir.path}/tmp');
    return t.existsSync() ? t.listSync() : const [];
  }
}

const _estimate = PdfCompressEstimate(
  sourceBytes: 10000,
  bytes: {PdfCompressPreset.high: 8100, PdfCompressPreset.medium: 3100, PdfCompressPreset.small: 1100},
);

void main() {
  test('names and messages', () {
    expect(compressedPdfName('Report.pdf'), 'Report (compressed).pdf');
    expect(compressedPdfName('scan.PDF'), 'scan (compressed).pdf');
    expect(compressedPdfName('notes'), 'notes (compressed).pdf');
    expect(compressedPdfName('.pdf'), 'Document (compressed).pdf');
    expect(compressErrorMessage(const PdfException(PdfErrorCode.passwordRequired, '')), contains('protected'));
    expect(compressErrorMessage(const PdfException(PdfErrorCode.noSpace, '')), contains('space'));
    expect(compressErrorMessage(const PdfException(PdfErrorCode.damaged, '')), contains('couldn’t read'));
    expect(compressErrorMessage(StateError('x')), 'That didn’t work. Try again.');
  });

  testWidgets('idle: size now and each preset\'s estimate; Medium is chosen', (tester) async {
    final h = _Harness(FakeCompressEngine(estimateResult: _estimate), docTempDir());
    await tester.pumpWidget(docApp(h.panel()));
    await tester.pump();
    expect(find.text('Size now: 10 KB'), findsOneWidget);
    expect(find.text('about 8.1 KB'), findsOneWidget);
    expect(find.text('about 3.1 KB'), findsOneWidget);
    expect(find.text('about 1.1 KB'), findsOneWidget);
    expect(h.controller.preset, PdfCompressPreset.medium);
    await tester.tap(find.text('Small file'));
    await tester.pump();
    expect(h.controller.preset, PdfCompressPreset.small);
    expect(find.bySemanticsLabel(RegExp('Compress with Small file')), findsOneWidget);
  });

  testWidgets('no estimate on this device: sizes appear once a preset ran', (tester) async {
    final h = _Harness(FakeCompressEngine(), docTempDir());
    await tester.pumpWidget(docApp(h.panel()));
    await tester.pump();
    expect(find.textContaining('about'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('compress-run')));
    await tester.pump();
    await tester.pump();
    expect(find.text('3 KB'), findsOneWidget, reason: 'the measured size of Medium');
  });

  testWidgets('running shows progress and locks the presets; done saves a new file', (tester) async {
    final engine = FakeCompressEngine(estimateResult: _estimate)..gate = Completer<void>();
    final h = _Harness(engine, docTempDir());
    await tester.pumpWidget(docApp(h.panel(password: 'pw')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('compress-run')));
    await tester.pump();
    expect(h.controller.phase, PdfCompressPhase.running);
    expect(find.text('Compressing… 40 %'), findsOneWidget);
    expect(find.byKey(const ValueKey('compress-progress')), findsOneWidget);
    await tester.tap(find.text('Small file'));
    await tester.pump();
    expect(h.controller.preset, PdfCompressPreset.medium, reason: 'presets are locked while running');
    engine.gate!.complete();
    await tester.pump();
    await tester.pump();
    expect(h.controller.phase, PdfCompressPhase.done);
    expect(engine.runs.single.$2, PdfCompressPreset.medium);
    expect(engine.runs.single.$4, 'pw', reason: 'the unlock password goes to the engine');
    expect(engine.runs.single.$3, startsWith('${h.dir.path}/tmp/'), reason: 'the engine writes an app-owned temporary file');
    expect(h.saved.single.$2, 'Report (compressed).pdf');
    expect(h.saved.single.$3, isTrue, reason: 'the temporary file exists while it is saved');
    expect(find.text('Saved as “Report (compressed).pdf”'), findsOneWidget);
    expect(find.text('10 KB → 3 KB · 70 % smaller'), findsOneWidget);
    expect(find.text('3 KB'), findsOneWidget, reason: 'the preset row shows the measured size');
    expect(h.temps(), isEmpty, reason: 'the temporary file is gone after the save');
    expect(File(h.controller.path).lengthSync(), 10000, reason: 'the original is untouched');
    await tester.tap(find.byKey(const ValueKey('compress-close')));
    expect(h.closed, isTrue);
  });

  testWidgets('cancel: back to idle, nothing saved, no temporary file', (tester) async {
    final engine = FakeCompressEngine(estimateResult: _estimate)..gate = Completer<void>();
    final h = _Harness(engine, docTempDir());
    await tester.pumpWidget(docApp(h.panel()));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('compress-run')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('compress-cancel')));
    await tester.pump();
    await tester.pump();
    expect(engine.cancelled, hasLength(1));
    expect(h.controller.phase, PdfCompressPhase.idle);
    expect(find.text('Cancelled. Nothing was saved.'), findsOneWidget);
    expect(h.saved, isEmpty);
    expect(h.temps(), isEmpty);
    expect(find.byKey(const ValueKey('compress-run')), findsOneWidget, reason: 'the user can run again');
  });

  testWidgets('not smaller: said plainly, nothing saved, temporary file deleted', (tester) async {
    final engine = FakeCompressEngine(sizes: const {
      PdfCompressPreset.high: 10400,
      PdfCompressPreset.medium: 10000,
      PdfCompressPreset.small: 10000,
    });
    final h = _Harness(engine, docTempDir());
    await tester.pumpWidget(docApp(h.panel()));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('compress-run')));
    await tester.pump();
    await tester.pump();
    expect(h.controller.phase, PdfCompressPhase.notSmaller);
    expect(find.text('This PDF is already as small as Medium can make it. Nothing was saved.'), findsOneWidget);
    expect(find.text('The result was 10 KB; the file is 10 KB now.'), findsOneWidget);
    expect(h.saved, isEmpty);
    expect(h.temps(), isEmpty);
    await tester.tap(find.byKey(const ValueKey('compress-again')));
    await tester.pump();
    expect(h.controller.phase, PdfCompressPhase.idle);
  });

  testWidgets('errors: a failed run and a failed save say so; Try again goes back', (tester) async {
    final engine = FakeCompressEngine()..fail = const PdfException(PdfErrorCode.passwordRequired, 'locked');
    final h = _Harness(engine, docTempDir());
    await tester.pumpWidget(docApp(h.panel()));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('compress-run')));
    await tester.pump();
    await tester.pump();
    expect(h.controller.phase, PdfCompressPhase.error);
    expect(find.text('This PDF is protected. Open it with its password, then compress it.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('compress-retry')));
    await tester.pump();
    expect(h.controller.phase, PdfCompressPhase.idle);

    await tester.pumpWidget(const SizedBox());
    final h2 = _Harness(FakeCompressEngine(), docTempDir(), saveError: StateError('disk'));
    await tester.pumpWidget(docApp(h2.panel()));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('compress-run')));
    await tester.pump();
    await tester.pump();
    expect(h2.controller.phase, PdfCompressPhase.error);
    expect(find.text('The compressed copy couldn’t be saved.'), findsOneWidget);
    expect(h2.temps(), isEmpty);
  });

  testWidgets('an estimate failure is quiet; closing mid-run cancels the job', (tester) async {
    final engine = FakeCompressEngine()
      ..estimateError = const PdfException(PdfErrorCode.damaged, 'x')
      ..gate = Completer<void>();
    final h = _Harness(engine, docTempDir());
    await tester.pumpWidget(docApp(h.panel()));
    await tester.pump();
    expect(h.controller.phase, PdfCompressPhase.idle);
    await tester.tap(find.byKey(const ValueKey('compress-run')));
    await tester.pump();
    await tester.pumpWidget(docApp(const SizedBox()));
    await tester.pump();
    expect(engine.cancelled, hasLength(1));
    expect(h.saved, isEmpty);
    expect(h.temps(), isEmpty);
  });

  testWidgets('showPdfCompressSheet opens the sheet and Done closes it', (tester) async {
    final dir = docTempDir();
    final path = _source(dir);
    final engine = FakeCompressEngine(estimateResult: _estimate);
    final names = <String>[];
    await tester.pumpWidget(docApp(Builder(
      builder: (context) => DanaviewButton.primary(
        label: 'Open',
        onPressed: () => showPdfCompressSheet(
          context,
          path: path,
          displayName: 'Report.pdf',
          engine: engine,
          tempDirectory: '${dir.path}/tmp',
          save: (temp, name) async {
            names.add(name);
            return 'Report (compressed) (2).pdf';
          },
        ),
      ),
    )));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Compress PDF'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('compress-run')));
    await tester.pump();
    await tester.pump();
    expect(find.text('Saved as “Report (compressed) (2).pdf”'), findsOneWidget, reason: 'the name the library gave it');
    await tester.tap(find.byKey(const ValueKey('compress-close')));
    await tester.pumpAndSettle();
    expect(find.text('Compress PDF'), findsNothing);
    expect(names, ['Report (compressed).pdf']);
  });

  group('surface matrix (280 / 375 / 1280 px × text scale 0.85 / 1.35)', () {
    const sizes = [Size(280, 640), Size(375, 812), Size(1280, 800)];
    const scales = [0.85, 1.35];

    Future<void> check(WidgetTester tester, String state, Future<void> Function(_Harness h) drive, FakeCompressEngine Function() engine) async {
      final handle = tester.ensureSemantics();
      for (final size in sizes) {
        for (final scale in scales) {
          final surface = DocSurface(size, scale);
          applyDocSurface(tester, surface);
          final h = _Harness(engine(), docTempDir());
          await tester.pumpWidget(docApp(SingleChildScrollView(child: h.panel()), textScale: scale));
          await tester.pump();
          await drive(h);
          expectNoLayoutErrors(tester, '$state $surface');
          await expectTargetsAndLabels(tester);
          final gate = h.engine.gate;
          if (gate != null && !gate.isCompleted) gate.complete();
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
        }
      }
      handle.dispose();
    }

    Future<void> run(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('compress-run')));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('idle', (tester) => check(tester, 'idle', (_) async {}, () => FakeCompressEngine(estimateResult: _estimate)));
    testWidgets('running', (tester) => check(tester, 'running', (_) => run(tester), () => FakeCompressEngine(estimateResult: _estimate)..gate = Completer<void>()));
    testWidgets('cancelled', (tester) => check(tester, 'cancelled', (h) async {
          await run(tester);
          await tester.tap(find.byKey(const ValueKey('compress-cancel')));
          await tester.pump();
          await tester.pump();
          expect(find.text('Cancelled. Nothing was saved.'), findsOneWidget);
        }, () => FakeCompressEngine(estimateResult: _estimate)..gate = Completer<void>()));
    testWidgets('done', (tester) => check(tester, 'done', (_) async {
          await run(tester);
          expect(find.byKey(const ValueKey('compress-done')), findsOneWidget);
        }, () => FakeCompressEngine(estimateResult: _estimate)));
    testWidgets('not smaller', (tester) => check(tester, 'notSmaller', (_) async {
          await run(tester);
          expect(find.byKey(const ValueKey('compress-not-smaller')), findsOneWidget);
        }, () => FakeCompressEngine(sizes: const {PdfCompressPreset.high: 20000, PdfCompressPreset.medium: 20000, PdfCompressPreset.small: 20000})));
    testWidgets('error', (tester) => check(tester, 'error', (_) async {
          await run(tester);
          expect(find.byKey(const ValueKey('compress-error')), findsOneWidget);
        }, () => FakeCompressEngine()..fail = const PdfException(PdfErrorCode.noSpace, 'x')));
  });

  test('status colours keep contrast on the sheet surface', () {
    for (final c in [DanaviewColors.success, DanaviewColors.error, DanaviewColors.textSecondary]) {
      expect(DanaviewColors.contrastRatio(c, DanaviewColors.surface), greaterThanOrEqualTo(3.0));
    }
  });
}
