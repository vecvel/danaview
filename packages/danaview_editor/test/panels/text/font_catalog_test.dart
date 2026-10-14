// OWNER: UX-30
//
// FontCatalog (ARCH §17.8, D-30): the ten curated ids, package-qualified families, unknown and
// unbundled ids resolve to Figtree (API-04's FontResolver contract), search, and the font picker
// (each family drawn in itself, search, selection, the empty state, owner UI rules).

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/strings/text_strings.dart';
import 'package:danaview_editor/src/editor/contracts/content_text.dart';
import 'package:danaview_editor/src/editor/panels/font_picker.dart';
import 'package:danaview_editor/src/editor/text/font_catalog.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show FontResolver, TextLayoutEngine;
import 'package:danaview_editor_fonts/danaview_editor_fonts.dart' show bundledContentFontIds;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../support/support.dart';

final FontCatalog all = FontCatalog(bundled: {for (final f in contentFontFamilies) f.id});

void main() {
  group('FontCatalog', () {
    test('the ten curated families in order, with stable ids', () {
      expect(contentFontFamilies.map((f) => f.id), [
        'figtree', 'inter', 'montserrat', 'oswald', 'bebas', 'playfair', 'lora', 'caveat', 'pacifico', 'jetbrains', //
      ]);
      expect(contentFontFamilies.map((f) => f.family), [
        'Figtree', 'Inter', 'Montserrat', 'Oswald', 'Bebas Neue', 'Playfair Display', 'Lora', 'Caveat', 'Pacifico', 'JetBrains Mono', //
      ]);
      expect(defaultContentFontId, 'figtree');
      expect(bundledContentFontIds, contains('figtree'), reason: 'the default is always bundled');
    });

    test('resolve: package-qualified family; unknown, empty and unbundled ids -> Figtree', () {
      final FontResolver r = all.resolver;
      expect(r('inter'), 'packages/danaview_editor_fonts/Inter');
      expect(r('playfair'), 'packages/danaview_editor_fonts/Playfair Display');
      expect(r('noSuchFont'), 'packages/danaview_editor_fonts/Figtree');
      expect(r(''), 'packages/danaview_editor_fonts/Figtree');
      final onlyFigtree = FontCatalog(bundled: {'figtree'});
      expect(onlyFigtree.resolve('inter'), 'packages/danaview_editor_fonts/Figtree');
      expect(onlyFigtree.available.map((f) => f.id), ['figtree']);
      expect(onlyFigtree.displayName('inter'), 'Figtree');
      expect(all.displayName('bebas'), 'Bebas Neue');
      expect(FontCatalog.instance.resolve('figtree'), 'packages/danaview_editor_fonts/Figtree');
    });

    test('the resolver plugs into API-04 TextLayoutEngine', () {
      final engine = TextLayoutEngine(fontResolver: all.resolve);
      expect(engine.fontResolver('lora'), 'packages/danaview_editor_fonts/Lora');
    });

    test('search: display name, id and category; case, spaces and hyphens ignored', () {
      List<String> ids(String q) => all.search(q).map((f) => f.id).toList();
      expect(ids(''), hasLength(10));
      expect(ids('   '), hasLength(10));
      expect(ids('PLAYFAIR d'), ['playfair']);
      expect(ids('playfair-display'), ['playfair']);
      expect(ids('serif'), ['playfair', 'lora']);
      expect(ids('mono'), ['jetbrains']);
      expect(ids('bebas'), ['bebas']);
      expect(ids('handwriting'), ['caveat', 'pacifico']);
      expect(ids('zzz'), isEmpty);
    });
  });

  group('FontPicker', () {
    Future<List<String>> pump(WidgetTester tester, EditorSurface surface, {String selected = 'inter', List<String>? picks}) async {
      applySurface(tester, surface);
      await tester.pumpWidget(surfaceApp(
        surface,
        DefaultTextStyle(
          style: DanaviewTextStyles.body.copyWith(fontFamily: DanaviewFonts.family),
          child: ColoredBox(
            color: DanaviewColors.surfaceElevated,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: FontPicker(catalog: all, selectedId: selected, onSelected: (id) => picks?.add(id)),
            ),
          ),
        ),
      ));
      await tester.pump();
      return picks ?? const [];
    }

    testWidgets('each family is drawn in itself (content region) and picks report the id', (tester) async {
      final picks = <String>[];
      await pump(tester, const EditorSurface(Size(390, 1600)), picks: picks);
      for (final f in contentFontFamilies) {
        final row = find.byKey(FontPicker.rowKey(f.id));
        expect(row, findsOneWidget);
        final name = find.descendant(of: row, matching: find.text(f.family));
        expect(tester.widget<Text>(name).style!.fontFamily, f.packagedFamily);
        expect(find.ancestor(of: name, matching: find.byType(EditorContentTextRegion)), findsOneWidget);
      }
      expect(find.descendant(of: find.byKey(FontPicker.rowKey('inter')), matching: find.byType(Icon)), findsOneWidget,
          reason: 'the selected row shows a check');
      await tester.tap(find.byKey(FontPicker.rowKey('caveat')));
      await tester.pump();
      expect(picks, ['caveat']);
      expectOwnerUiRules(tester);
    });

    testWidgets('search filters; no match shows the empty state', (tester) async {
      await pump(tester, const EditorSurface(Size(390, 1600)));
      final field = find.descendant(of: find.byKey(FontPicker.searchKey), matching: find.byType(EditableText));
      await tester.enterText(field, 'lo');
      await tester.pump();
      expect(find.byKey(FontPicker.rowKey('lora')), findsOneWidget);
      expect(find.byKey(FontPicker.rowKey('inter')), findsNothing);
      await tester.enterText(field, 'comic');
      await tester.pump();
      expect(find.text(TextStrings.noFonts('comic')), findsOneWidget);
      await tester.enterText(field, '');
      await tester.pump();
      expect(find.byKey(FontPicker.rowKey('inter')), findsOneWidget);
    });

    testSurfaces('no overflow, owner UI rules', (tester, surface) async {
      await pump(tester, surface);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      expectInside(tester, find.byKey(FontPicker.searchKey));
    });
  });
}
