// OWNER: HOM-30
//
// The signature sheets (lib/src/signatures/): "New signature" draws on the pad (undo, clear, ink),
// types a name in the app's script fonts (or the italic fallback) and imports a photo (its problem
// explained), and saves each kind into the store; a full store is explained and Save stays off;
// Cancel saves nothing. "Saved signatures" uses one again, deletes one, keeps the ones on the open
// PDF, and deletes all after asking. Settings › Privacy shows how many are saved and deletes all.
// All of it fits 280 / 375 / 1280 px at text scale 0.85 and 1.35 with 44 px labelled targets.

import 'dart:typed_data';

import 'package:danaview_documents/danaview_documents.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../card/doc_harness.dart';
import 'signature_fakes.dart';

Finder _key(String key) => find.byKey(ValueKey(key));

bool _enabled(WidgetTester tester, Finder f) => switch (tester.widget(f)) {
      final DanaviewButton b => b.onPressed != null,
      final DanaviewIconButton b => b.onPressed != null,
      final w => throw StateError('unexpected ${w.runtimeType}'),
    };

const _fonts = [
  SignatureFont('Caveat', 'Caveat', package: 'danaview_editor_fonts'),
  SignatureFont('Pacifico', 'Pacifico', package: 'danaview_editor_fonts'),
  SignatureFont('Playfair italic', 'Playfair Display', package: 'danaview_editor_fonts', italic: true),
];

void main() {
  late MemorySignatureStore store;
  late FakeSignatureImageMaker maker;
  late List<SavedSignature?> done;
  late int picks;
  Uint8List? pickBytes;

  setUp(() {
    store = MemorySignatureStore();
    maker = FakeSignatureImageMaker();
    done = [];
    picks = 0;
    pickBytes = Uint8List.fromList([1, 2, 3]);
  });

  Widget panel({List<SignatureFont> fonts = _fonts, bool canImport = true}) => docApp(
        Padding(
          padding: const EdgeInsets.all(16),
          child: SignatureCreatePanel(
            store: store,
            fonts: fonts,
            maker: maker,
            pickPhoto: canImport
                ? (context) async {
                    picks++;
                    return pickBytes;
                  }
                : null,
            onDone: done.add,
          ),
        ),
      );

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.tap(_key(key));
    await tester.pumpAndSettle();
  }

  Future<void> drawOn(WidgetTester tester) async {
    final pad = tester.getRect(_key('signature-pad'));
    final g = await tester.startGesture(pad.centerLeft + const Offset(30, 0));
    await g.moveBy(const Offset(40, -20));
    await g.moveBy(const Offset(40, 30));
    await g.up();
    await tester.pumpAndSettle();
  }

  testWidgets('Draw: strokes on the pad, undo and clear, the ink, then Save adds a drawn signature', (tester) async {
    await tester.pumpWidget(panel());
    await tester.pumpAndSettle();
    expect(find.text('Sign here'), findsOneWidget);
    expect(_enabled(tester, _key('signature-create-save')), isFalse, reason: 'nothing drawn');
    expect(_enabled(tester, _key('signature-pad-undo')), isFalse);

    await drawOn(tester);
    expect(find.text('Sign here'), findsNothing);
    expect(_enabled(tester, _key('signature-create-save')), isTrue);
    await tap(tester, 'signature-pad-undo');
    expect(_enabled(tester, _key('signature-create-save')), isFalse);
    await drawOn(tester);
    await drawOn(tester);
    await tap(tester, 'signature-pad-clear');
    expect(find.text('Sign here'), findsOneWidget);

    await drawOn(tester);
    await tap(tester, 'signature-ink-ff1a2f8a');
    await tap(tester, 'signature-create-save');
    final (strokes, size, color) = maker.drawnCalls.single;
    expect(strokes, hasLength(1));
    expect(strokes.single.length, greaterThan(2));
    expect(size.width, greaterThan(200));
    expect(color, const Color(0xFF1A2F8A));
    final saved = done.single!;
    expect(saved.kind, SignatureKind.drawn);
    expect((await store.list()).single, saved);
  });

  testWidgets('Type: the name in each script font, the chosen one and ink are used', (tester) async {
    await tester.pumpWidget(panel());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Type'));
    await tester.pumpAndSettle();
    expect(find.text('Your name'), findsWidgets);
    for (var i = 0; i < _fonts.length; i++) {
      expect(_key('signature-type-font-$i'), findsOneWidget);
    }
    expect(_enabled(tester, _key('signature-create-save')), isFalse);
    await tester.enterText(_key('signature-type-name'), 'Ada Lovelace');
    await tester.pumpAndSettle();
    expect(find.text('Ada Lovelace'), findsNWidgets(_fonts.length + 1), reason: 'the field and one preview per font');
    final preview = tester.widget<Text>(find.descendant(of: _key('signature-type-font-1'), matching: find.text('Ada Lovelace')));
    expect(preview.style?.fontFamily, 'packages/danaview_editor_fonts/Pacifico');
    await tap(tester, 'signature-type-font-1');
    await tap(tester, 'signature-ink-ff1a2f8a');
    await tap(tester, 'signature-create-save');
    final (name, font, color) = maker.typedCalls.single;
    expect(name, 'Ada Lovelace');
    expect(font.label, 'Pacifico');
    expect(color, const Color(0xFF1A2F8A));
    expect(done.single!.kind, SignatureKind.typed);
  });

  testWidgets('Type without bundled fonts uses the app font in italic', (tester) async {
    await tester.pumpWidget(panel(fonts: const []));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Type'));
    await tester.pumpAndSettle();
    expect(_key('signature-type-font-0'), findsOneWidget);
    expect(_key('signature-type-font-1'), findsNothing);
    final preview = tester.widget<Text>(find.descendant(of: _key('signature-type-font-0'), matching: find.byType(Text)).first);
    expect(preview.style?.fontStyle, FontStyle.italic);
    expect(preview.style?.fontFamily, DanaviewFonts.family);
  });

  testWidgets('Import: a photo is cleaned and previewed, a bad one explained, then saved', (tester) async {
    await tester.pumpWidget(panel());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    expect(_enabled(tester, _key('signature-create-save')), isFalse);

    maker.photoProblem = SignaturePhotoProblem.notOnPaper;
    await tap(tester, 'signature-import-pick');
    expect(find.text(signaturePhotoProblemText(SignaturePhotoProblem.notOnPaper)), findsOneWidget);
    expect(_enabled(tester, _key('signature-create-save')), isFalse);

    pickBytes = null; // the picker was cancelled
    await tap(tester, 'signature-import-pick');
    expect(maker.photoCalls, 1);

    pickBytes = Uint8List.fromList([4, 5, 6]);
    maker.photoProblem = null;
    await tap(tester, 'signature-import-pick');
    expect(_key('signature-import-preview'), findsOneWidget);
    expect(find.text('Choose another photo'), findsOneWidget);
    await tap(tester, 'signature-create-save');
    expect(done.single!.kind, SignatureKind.imported);
    expect(picks, 3);
  });

  testWidgets('without a photo picker there is no Import', (tester) async {
    await tester.pumpWidget(panel(canImport: false));
    await tester.pumpAndSettle();
    expect(find.text('Import'), findsNothing);
    expect(find.text('Draw'), findsOneWidget);
  });

  testWidgets('a full store is explained and Save stays off; Cancel saves nothing', (tester) async {
    store = MemorySignatureStore(count: SignatureStore.maxCount);
    await tester.pumpWidget(panel());
    await tester.pumpAndSettle();
    expect(find.text(signatureStoreFullText), findsOneWidget);
    await drawOn(tester);
    expect(_enabled(tester, _key('signature-create-save')), isFalse);
    await tap(tester, 'signature-create-cancel');
    expect(done, [null]);
    expect(await store.count(), SignatureStore.maxCount);
  });

  testWidgets('Saved signatures: use one, delete one, keep the ones on the PDF, delete all after asking', (tester) async {
    store = MemorySignatureStore(count: 3);
    final list = await store.list();
    final used = <SavedSignature>[];
    await tester.pumpWidget(docApp(Padding(
      padding: const EdgeInsets.all(16),
      child: SavedSignaturesPanel(store: store, inUse: {list[0].path}, onUse: used.add),
    )));
    await tester.pumpAndSettle();
    expect(find.text('On this PDF'), findsOneWidget);
    expect(_enabled(tester, _key('saved-signature-delete-${list[0].id}')), isFalse, reason: 'placed in the open PDF');
    expect(_key('saved-signatures-delete-all'), findsNothing, reason: 'not while one is on the PDF');

    await tap(tester, 'saved-signature-delete-${list[1].id}');
    expect((await store.list()).map((s) => s.id), [list[0].id, list[2].id]);
    await tester.tap(_key('saved-signature-${list[2].id}'));
    await tester.pumpAndSettle();
    expect(used.single.id, list[2].id);

    await tester.pumpWidget(docApp(Padding(
      padding: const EdgeInsets.all(16),
      child: SavedSignaturesPanel(key: UniqueKey(), store: store, onUse: used.add),
    )));
    await tester.pumpAndSettle();
    await tap(tester, 'saved-signatures-delete-all');
    expect(find.text('Delete all saved signatures?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await store.count(), 2);
    await tap(tester, 'saved-signatures-delete-all');
    await tester.tap(find.text('Delete all').last);
    await tester.pumpAndSettle();
    expect(await store.count(), 0);
    expect(_key('saved-signatures-empty'), findsOneWidget);
  });

  testWidgets('Settings › Privacy: the count and Delete all', (tester) async {
    store = MemorySignatureStore(count: 2);
    await tester.pumpWidget(docApp(Padding(padding: const EdgeInsets.all(16), child: SavedSignaturesSettingsSection(store: store))));
    await tester.pumpAndSettle();
    expect(find.text('2 saved on this device'), findsOneWidget);
    await tap(tester, 'privacy-saved-signatures-delete-all');
    await tester.tap(find.text('Delete all').last);
    await tester.pumpAndSettle();
    expect(store.deleteAlls, 1);
    expect(find.text('None saved'), findsOneWidget);
    expect(_enabled(tester, _key('privacy-saved-signatures-delete-all')), isFalse);
    await tester.pump(const Duration(seconds: 3));
  });

  group('surface matrix: 280 / 375 / 1280 px × text scale 0.85 / 1.35', () {
    for (final size in const [Size(280, 560), Size(375, 812), Size(1280, 800)]) {
      for (final scale in const [0.85, 1.35]) {
        final surface = DocSurface(size, scale);
        testWidgets('no overflow and 44 px labelled targets at $surface', (tester) async {
          applyDocSurface(tester, surface);
          final handle = tester.ensureSemantics();
          store = MemorySignatureStore(count: 2);
          await tester.pumpWidget(docApp(
            Builder(
              builder: (context) => Center(
                child: DanaviewButton.primary(
                  label: 'Open',
                  onPressed: () => showSignatureCreateSheet(context, store: store, fonts: _fonts, maker: maker, pickPhoto: (_) async => pickBytes),
                ),
              ),
            ),
            textScale: scale,
          ));
          await tester.tap(find.text('Open'));
          await tester.pumpAndSettle();
          expectNoLayoutErrors(tester, '$surface draw');
          await expectTargetsAndLabels(tester);
          await tester.tap(find.text('Type'));
          await tester.pumpAndSettle();
          await tester.enterText(_key('signature-type-name'), 'Grace Hopper');
          await tester.pumpAndSettle();
          expectNoLayoutErrors(tester, '$surface type');
          await expectTargetsAndLabels(tester);
          await tester.tap(find.text('Import'));
          await tester.pumpAndSettle();
          await tester.tap(_key('signature-import-pick'));
          await tester.pumpAndSettle();
          expectNoLayoutErrors(tester, '$surface import');
          await expectTargetsAndLabels(tester);
          await tester.tap(_key('signature-create-cancel'));
          await tester.pumpAndSettle();

          await tester.pumpWidget(docApp(
            Builder(
              builder: (context) => Center(
                child: DanaviewButton.primary(label: 'Saved', onPressed: () => showSavedSignaturesSheet(context, store: store)),
              ),
            ),
            textScale: scale,
          ));
          await tester.tap(find.text('Saved'));
          await tester.pumpAndSettle();
          expectNoLayoutErrors(tester, '$surface saved sheet');
          await expectTargetsAndLabels(tester);

          await tester.pumpWidget(docApp(
            SingleChildScrollView(padding: const EdgeInsets.all(16), child: SavedSignaturesSettingsSection(store: store)),
            textScale: scale,
          ));
          await tester.pumpAndSettle();
          expectNoLayoutErrors(tester, '$surface settings');
          await expectTargetsAndLabels(tester);
          handle.dispose();
        });
      }
    }
  });
}
