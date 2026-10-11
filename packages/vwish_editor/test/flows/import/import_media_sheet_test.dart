// OWNER: UX-06
//
// ImportMediaSheet (ux.md §5.3, ARCH §9.1, D-13) with fakes: success (closes by itself), partial
// failure, nothing added, cancel mid-copy (partial file deleted, later items skipped), the
// free-space refusal (nothing copied) and retry, unsupported files with platform copy, the
// iOS-only Photos hint, back while importing cancels, a failing job, and the surface matrix.

import 'package:flutter/material.dart' show Icons, Scaffold;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/editor/flows/import_media_sheet.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart' show EditSession;
import 'package:vwish_editor_core/testing.dart';
import 'package:vwish_features/storage.dart' show formatDataSize;
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import '../../support/support.dart';
import 'import_fakes.dart';

const _mb = 1024 * 1024;

const _iosPhone = EditorSurface(Size(390, 844), platform: TargetPlatform.iOS);

/// Opens the sheet from a host page and keeps its result.
class _Opened {
  Future<ImportSheetResult?>? result;
  ImportSheetResult? value;
  bool closed = false;
}

Future<_Opened> _open(
  WidgetTester tester,
  EditorTestHarness h,
  List<PickedMedia> picks,
  ImportJob job, {
  EditorSurface surface = SurfaceMatrix.phone,
  bool closeWhenAllAdded = true,
}) async {
  final opened = _Opened();
  await h.pumpApp(
    tester,
    Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: VwishButton.primary(
            label: 'Import',
            onPressed: () {
              opened.result = showImportMediaSheet(context, picks: picks, job: job, closeWhenAllAdded: closeWhenAllAdded)
                ..then((value) {
                  opened
                    ..value = value
                    ..closed = true;
                });
            },
          ),
        ),
      ),
    ),
    surface: surface,
  );
  await tester.tap(find.text('Import'));
  await _settle(tester);
  return opened;
}

/// Pumps a few frames (indeterminate progress bars never settle).
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

EditSession _session() => EditSession(FakeProjectRepository().seedEmpty('Open project'));

Finder _item(int i) => find.byKey(ValueKey('import-item-$i'));

String _statusOf(WidgetTester tester, int i) => tester.widget<ImportItemTile>(_item(i)).status;

/// Scrolls [finder] into the sheet's view, then checks it is on screen.
Future<void> _expectReachable(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  expectInside(tester, finder);
}

void main() {
  group('ImportMediaSheet', () {
    testWidgets('everything added: the sheet closes by itself with the result', (tester) async {
      final h = EditorTestHarness();
      final pool = ScriptedPool();
      final opened = await _open(tester, h, [pickOf('a.mp4'), pickOf('b.jpg')], sessionImportJob(pool: pool, session: _session()));
      expect(opened.closed, isTrue);
      expect(opened.value!.exit, ImportSheetExit.finished);
      expect(opened.value!.job!.allAdded, isTrue);
      expect(find.byKey(const ValueKey('import-media-sheet')), findsNothing);
      expectNoOverflow(tester);
    });

    testWidgets('a successful import can show its summary', (tester) async {
      final h = EditorTestHarness();
      final opened = await _open(
        tester,
        h,
        [pickOf('a.mp4'), pickOf('b.jpg')],
        sessionImportJob(pool: ScriptedPool(), session: _session()),
        closeWhenAllAdded: false,
      );
      expect(find.text('2 items added'), findsOneWidget);
      expect(_statusOf(tester, 0), 'Added');
      await tester.tap(find.byKey(const ValueKey('import-finish')));
      await _settle(tester);
      expect(opened.value!.exit, ImportSheetExit.finished);
    });

    testWidgets('partial failure: a summary, inline errors with platform copy, and Done keeps what was added', (tester) async {
      final h = EditorTestHarness();
      final pool = ScriptedPool()..steps['holiday.mkv'] = const RejectStep('containerUnsupportedIos');
      final opened = await _open(
        tester,
        h,
        [pickOf('a.mp4'), pickOf('holiday.mkv'), pickOf('c.mp4')],
        sessionImportJob(pool: pool, session: _session()),
        surface: _iosPhone,
      );
      expect(opened.closed, isFalse);
      expect(find.text('2 of 3 added'), findsOneWidget);
      expect(find.text("1 item couldn't be added."), findsOneWidget);
      expect(_statusOf(tester, 1), "MKV, WebM and AVI videos can't be edited on iPhone and iPad. Convert it to MP4 or MOV first.");
      expect(find.descendant(of: _item(1), matching: find.byIcon(Icons.error_outline_rounded)), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('import-finish')));
      await _settle(tester);
      expect(opened.value!.job!.addedCount, 2);
      expectNoOverflow(tester);
    });

    testWidgets('nothing added: every error is inline and Close returns the result', (tester) async {
      final h = EditorTestHarness();
      final pool = ScriptedPool()
        ..steps['song.xyz'] = const RejectStep('unsupported')
        ..steps['locked.mp4'] = const RejectStep('accessDenied')
        ..steps['huge.mov'] = const RejectStep('diskFull');
      final opened = await _open(
        tester,
        h,
        [pickOf('song.xyz'), pickOf('locked.mp4'), pickOf('huge.mov')],
        sessionImportJob(pool: pool, session: _session()),
      );
      expect(find.text('Nothing was added'), findsOneWidget);
      expect(_statusOf(tester, 0), 'This format is not supported for editing.');
      expect(_statusOf(tester, 1), contains('not allowed to read this file'));
      expect(_statusOf(tester, 2), contains('Not enough storage space'));
      expect(find.byKey(const ValueKey('import-finish')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('import-back')));
      await _settle(tester);
      expect(opened.value!.job!.failedCount, 3);
    });

    testWidgets('cancel mid-copy: the partial copy is deleted and later items are not imported', (tester) async {
      final h = EditorTestHarness();
      final fs = MemoryStoreFs();
      final copy = CopyStep(fraction: 0.4);
      final pool = ScriptedPool(fs: fs)..steps['big.mov'] = copy;
      final session = _session();
      final opened = await _open(
        tester,
        h,
        [pickOf('first.mp4'), pickOf('big.mov', origin: MediaOrigin.drop, size: 300 * _mb), pickOf('later.mp4')],
        sessionImportJob(pool: pool, session: session),
      );
      expect(copy.started.isCompleted, isTrue);
      expect(_statusOf(tester, 0), 'Added');
      expect(_statusOf(tester, 1), 'Copying into Vwish… 40%');
      expect(find.descendant(of: _item(1), matching: find.byType(VwishProgressBar)), findsOneWidget);
      expect(_statusOf(tester, 2), 'Waiting');
      expect(fs.filePaths.single, endsWith('big.mov.part-1'));

      await tester.tap(find.byKey(const ValueKey('import-cancel')));
      await _settle(tester);

      expect(fs.filePaths, isEmpty, reason: 'the partial copy is deleted');
      expect(pool.imported, ['first.mp4', 'big.mov']);
      expect(find.text('Import cancelled'), findsOneWidget);
      expect(find.text('1 item was added before you cancelled.'), findsOneWidget);
      expect(_statusOf(tester, 1), 'Cancelled');
      expect(_statusOf(tester, 2), 'Cancelled');
      expect(session.project.pool.assets, hasLength(1));
      await tester.tap(find.byKey(const ValueKey('import-finish')));
      await _settle(tester);
      expect(opened.value!.job!.cancelled, isTrue);
    });

    testWidgets('closing the sheet while importing cancels instead of leaving it running', (tester) async {
      final h = EditorTestHarness();
      final copy = CopyStep();
      final pool = ScriptedPool()..steps['big.mov'] = copy;
      final opened = await _open(tester, h, [pickOf('big.mov'), pickOf('next.mp4')], sessionImportJob(pool: pool, session: _session()));
      await tester.tap(find.byTooltip('Close'));
      await _settle(tester);
      expect(find.byKey(const ValueKey('import-media-sheet')), findsOneWidget, reason: 'the sheet stays to show the outcome');
      expect(find.text('Import cancelled'), findsOneWidget);
      expect(pool.imported, ['big.mov']);
      expect(opened.closed, isFalse);
    });

    testWidgets('free-space refusal: nothing is imported, the sizes are shown, and Try again runs once space is free', (tester) async {
      final h = EditorTestHarness();
      h.engine.freeBytesValue = 100 * _mb;
      final pool = ScriptedPool();
      final opened = await _open(
        tester,
        h,
        [pickOf('drop.mov', origin: MediaOrigin.drop, size: 200 * _mb), pickOf('ref.mp4', size: 5000 * _mb)],
        sessionImportJob(pool: pool, session: _session()),
      );
      expect(find.text('Not enough space'), findsOneWidget);
      expect(
        find.textContaining(
            'Copying needs about ${formatDataSize(200 * _mb)} plus 64 MB to spare, and ${formatDataSize(100 * _mb)} is free.'),
        findsOneWidget,
      );
      expect(pool.calls, isEmpty, reason: 'no copy starts');
      expect(h.engine.calls, contains('freeBytes'));
      expect(find.byKey(const ValueKey('import-item-0')), findsNothing);
      expectNoOverflow(tester);

      h.engine.freeBytesValue = 264 * _mb + 1;
      await tester.tap(find.byKey(const ValueKey('import-retry')));
      await _settle(tester);
      expect(opened.closed, isTrue);
      expect(pool.imported, ['drop.mov', 'ref.mp4']);
    });

    testWidgets('a refusal can be closed', (tester) async {
      final h = EditorTestHarness();
      h.engine.freeBytesValue = 10 * _mb;
      final opened = await _open(
        tester,
        h,
        [pickOf('drop.mov', origin: MediaOrigin.drop, size: 20 * _mb)],
        sessionImportJob(pool: ScriptedPool(), session: _session()),
      );
      await tester.tap(find.byKey(const ValueKey('import-back')));
      await _settle(tester);
      expect(opened.value!.exit, ImportSheetExit.closed);
      expect(opened.value!.job, isNull);
    });

    testWidgets('a job that fails as a whole says so and can be retried', (tester) async {
      final h = EditorTestHarness();
      var attempts = 0;
      final opened = await _open(tester, h, [pickOf('a.mp4')], (run) async {
        attempts++;
        if (attempts == 1) throw StateError('repository gone');
        return ImportJobResult([const ImportItemResult.added()]);
      });
      expect(find.text("Couldn't finish the import"), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('import-retry')));
      await _settle(tester);
      expect(attempts, 2);
      expect(opened.closed, isTrue);
    });

    group('the Photos hint (D-13)', () {
      Future<void> pumpWith(WidgetTester tester, List<PickedMedia> picks, EditorSurface surface) async {
        final copy = CopyStep();
        final pool = ScriptedPool()..steps[picks.first.displayName] = copy;
        await _open(tester, EditorTestHarness(), picks, sessionImportJob(pool: pool, session: _session()), surface: surface);
      }

      testWidgets('shows for iOS Photos picks', (tester) async {
        await pumpWith(tester, [pickOf('IMG_0001.mov', origin: MediaOrigin.photos, temporary: true)], _iosPhone);
        expect(find.byKey(const ValueKey('import-photos-hint')), findsOneWidget);
        expect(find.text('Videos from Photos are copied into Vwish so your project keeps working.'), findsOneWidget);
      });

      testWidgets('not for iOS Files picks', (tester) async {
        await pumpWith(tester, [pickOf('clip.mov')], _iosPhone);
        expect(find.byKey(const ValueKey('import-photos-hint')), findsNothing);
      });

      testWidgets('not for Android Gallery picks', (tester) async {
        await pumpWith(tester, [pickOf('clip.mp4', origin: MediaOrigin.photos)], SurfaceMatrix.phone);
        expect(find.byKey(const ValueKey('import-photos-hint')), findsNothing);
      });
    });

    testSurfaces('no overflow while copying, with long names, errors and the hint', (tester, surface) async {
      final h = EditorTestHarness();
      final copy = CopyStep(fraction: 0.75);
      final long = 'A family holiday video with a very long file name that keeps going and going.mov';
      final pool = ScriptedPool()
        ..steps['rejected-${'x' * 60}.mkv'] = const RejectStep('containerUnsupportedIos')
        ..steps[long] = copy;
      await _open(
        tester,
        h,
        [
          pickOf('rejected-${'x' * 60}.mkv', origin: MediaOrigin.photos),
          pickOf(long, origin: MediaOrigin.photos, temporary: true),
          pickOf('waiting.mp4'),
        ],
        sessionImportJob(pool: pool, session: _session()),
        surface: surface.copyWith(platform: TargetPlatform.iOS),
      );
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      await _expectReachable(tester, find.byKey(const ValueKey('import-cancel')));
      await tester.tap(find.byKey(const ValueKey('import-cancel')));
      await _settle(tester);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      expect(find.text('Import cancelled'), findsOneWidget);
      await _expectReachable(tester, find.byKey(const ValueKey('import-back')));
    });

    testSurfaces('no overflow on the free-space refusal', (tester, surface) async {
      final h = EditorTestHarness();
      h.engine.freeBytesValue = 1;
      await _open(
        tester,
        h,
        [pickOf('drop.mov', origin: MediaOrigin.drop, size: 987654 * _mb)],
        sessionImportJob(pool: ScriptedPool(), session: _session()),
        surface: surface,
      );
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      await _expectReachable(tester, find.byKey(const ValueKey('import-retry')));
    });
  });
}
