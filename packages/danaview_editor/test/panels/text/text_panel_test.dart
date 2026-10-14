// OWNER: UX-30
//
// The text panel (ux.md §10.8): every tab dispatches CORE-14 commands (one history entry each,
// one per slider/colour gesture), typing coalesces into one entry per run (1 s idle or blur), a
// blank text is never sent, undo updates the field, the animation loop preview plays the item's
// range and restores the transport, a locked lane disables the panel, and the matrix (no
// overflow, owner UI rules) including the keyboard inset and the live text chip of degrade
// step 5.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/strings/text_strings.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_rows.dart';
import 'package:danaview_editor/src/editor/panels/font_picker.dart';
import 'package:danaview_editor/src/editor/panels/text_panel.dart';
import 'package:danaview_editor/src/editor/text/font_catalog.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_semantics.dart' show EditorAnnouncer;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../support/support.dart';
import 'text_rig.dart';

Finder key(String k) => find.byKey(ValueKey<String>(k));

/// Every curated family, as if all were bundled.
final FontCatalog allFonts = FontCatalog(bundled: {for (final f in contentFontFamilies) f.id});

Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

Future<void> openTab(WidgetTester tester, TextPanelTab tab) async {
  await tap(tester, key(TextPanelModel.tabKey(tab)));
}

Finder get field => find.descendant(of: key('text.field'), matching: find.byType(EditableText));

InspectorSliderRow slider(WidgetTester tester, String k) => tester.widget<InspectorSliderRow>(key(k));

/// Runs a slider gesture of [values] on row [k] (start, changes, end).
void drag(WidgetTester tester, String k, List<double> values) {
  final row = slider(tester, k);
  row.onChangeStart!(values.first);
  for (final v in values) {
    slider(tester, k).onChanged!(v);
  }
  slider(tester, k).onChangeEnd!(values.last);
}

void testText(String description, Future<void> Function(WidgetTester tester) body) => testWidgets(description, (tester) async {
      try {
        await body(tester);
        await tester.pump(const Duration(seconds: 5));
      } finally {
        EditorAnnouncer.instance.reset();
      }
    });

void main() {
  late DateTime now;
  setUp(() {
    EditorAnnouncer.instance.reset();
    now = DateTime.utc(2026, 10, 14, 9);
    InspectorRows.clock = () => now;
    TextTypingRun.now = () => now;
    TextPanel.focusRequest.value = null;
  });
  tearDown(() {
    InspectorRows.clock = DateTime.now;
    TextTypingRun.now = DateTime.now;
  });

  group('TextTypingRun', () {
    test('one key per run; a new run after 1 s idle or end()', () {
      var t = DateTime.utc(2026);
      final run = TextTypingRun(clock: () => t);
      const cmd = SetTextKey.cmd;
      final a = run.keyFor(cmd);
      t = t.add(const Duration(milliseconds: 900));
      expect(run.keyFor(cmd), a);
      t = t.add(const Duration(milliseconds: 999));
      expect(run.keyFor(cmd), a, reason: 'idle is measured from the last keystroke');
      t = t.add(const Duration(seconds: 1));
      final b = run.keyFor(cmd);
      expect(b, isNot(a));
      run.end();
      expect(run.keyFor(cmd), isNot(b));
      expect(a, startsWith('text:it_x#'));
    });
  });

  group('edit', () {
    testText('opens on Edit with the item text; typing is one history entry per run', (tester) async {
      final rig = await TextRig.pump(tester);
      expect(find.byType(TextPanel), findsOneWidget);
      expect(tester.widget<EditableText>(field).controller.text, 'Hello');
      final before = rig.entries;
      await tester.enterText(field, 'Hello ');
      await tester.pump();
      await tester.enterText(field, 'Hello w');
      await tester.pump();
      await tester.enterText(field, 'Hello world');
      await tester.pump();
      expect(rig.text(Ids.t1).text, 'Hello world');
      expect(rig.entries, before + 1, reason: 'one coalesced "Edit text" entry');

      now = now.add(const Duration(milliseconds: 1500));
      await tester.enterText(field, 'Hello world!');
      await tester.pump();
      expect(rig.entries, before + 2, reason: 'a new run after 1 s idle');
      expect(rig.text(Ids.t1).text, 'Hello world!');

      expect(rig.editor.undo(), isTrue);
      await tester.pump();
      expect(rig.text(Ids.t1).text, 'Hello world');
      expect(tester.widget<EditableText>(field).controller.text, 'Hello world', reason: 'undo updates the field');
      expect(rig.editor.undo(), isTrue);
      await tester.pump();
      expect(rig.text(Ids.t1).text, 'Hello');
      expect(tester.widget<EditableText>(field).controller.text, 'Hello');
    });

    testText('losing focus ends the run', (tester) async {
      final rig = await TextRig.pump(tester);
      final before = rig.entries;
      await tester.enterText(field, 'Hello a');
      await tester.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await tester.enterText(field, 'Hello ab');
      await tester.pump();
      expect(rig.entries, before + 2);
    });

    testText('a blank text is never sent; blur restores the last text', (tester) async {
      final rig = await TextRig.pump(tester);
      final before = rig.entries;
      await tester.enterText(field, '   ');
      await tester.pump();
      expect(rig.text(Ids.t1).text, 'Hello');
      expect(rig.entries, before);
      expect(find.text(TextStrings.emptyText), findsOneWidget);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(tester.widget<EditableText>(field).controller.text, 'Hello');
      expect(find.text(TextStrings.emptyText), findsNothing);
    });

    testText('duration trims the tail (one entry, whole frames)', (tester) async {
      final rig = await TextRig.pump(tester);
      final before = rig.entries;
      tester.widget<InspectorNumberRow>(key('text.duration')).onChanged!(1.5);
      await tester.pump();
      expect(rig.text(Ids.t1).start, 1 * s);
      expect(rig.text(Ids.t1).duration, 1500000);
      expect(rig.entries, before + 1);
    });

    testText('a focus request focuses the field (Add text brings the keyboard up)', (tester) async {
      final rig = await TextRig.pump(tester, open: null);
      TextPanel.focusRequest.value = Ids.t2;
      await rig.openPanel(Ids.t2, tab: TextPanelTab.font);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey<String>('text.field')), findsOneWidget, reason: 'switched to Edit');
      expect(tester.widget<EditableText>(field).focusNode.hasFocus, isTrue);
      expect(TextPanel.focusRequest.value, isNull);
    });
  });

  group('font', () {
    testText('picking a family dispatches SetTextStyle(fontFamily); size, bold, italic', (tester) async {
      final rig = await TextRig.pump(tester, tab: TextPanelTab.font, overrides: [fontCatalogProvider.overrideWithValue(allFonts)]);
      expect(find.byType(FontPicker), findsOneWidget);
      final before = rig.entries;
      await tap(tester, find.byKey(FontPicker.rowKey('playfair')));
      expect(rig.text(Ids.t1).style.fontFamily, 'playfair');
      expect(rig.entries, before + 1);

      slider(tester, 'text.size').onSubmitted!(72);
      await tester.pump();
      expect(rig.text(Ids.t1).style.fontSizePt, 72);
      slider(tester, 'text.size').onSubmitted!(500);
      await tester.pump();
      expect(rig.text(Ids.t1).style.fontSizePt, 200, reason: 'clamped to the 8–200 range');

      drag(tester, 'text.size', [60, 64, 70]);
      await tester.pump();
      expect(rig.text(Ids.t1).style.fontSizePt, 70);
      expect(rig.entries, before + 4, reason: 'a drag is one entry');

      await tap(tester, find.descendant(of: key('text.bold'), matching: find.byType(DanaviewSwitchRow)));
      expect(rig.text(Ids.t1).style.bold, isTrue);
      await tap(tester, find.descendant(of: key('text.italic'), matching: find.byType(DanaviewSwitchRow)));
      expect(rig.text(Ids.t1).style.italic, isTrue);
      expect(rig.entries, before + 6);
    });

    testText('search narrows the list', (tester) async {
      await TextRig.pump(tester, tab: TextPanelTab.font, overrides: [fontCatalogProvider.overrideWithValue(allFonts)]);
      final search = find.descendant(of: find.byKey(FontPicker.searchKey), matching: find.byType(EditableText));
      await tester.enterText(search, 'mono');
      await tester.pump();
      expect(find.byKey(FontPicker.rowKey('jetbrains')), findsOneWidget);
      expect(find.byKey(FontPicker.rowKey('figtree')), findsNothing);
    });
  });

  group('style', () {
    testText('colour gesture, opacity, alignment, letter and line spacing', (tester) async {
      final rig = await TextRig.pump(tester, tab: TextPanelTab.style);
      final before = rig.entries;
      final color = tester.widget<InspectorColorRow>(key('text.color'));
      color.onChangeStart!(const Color(0xFFFF0000));
      tester.widget<InspectorColorRow>(key('text.color')).onChanged(const Color(0xFFFF0000));
      tester.widget<InspectorColorRow>(key('text.color')).onChanged(const Color(0xFF00FF00));
      tester.widget<InspectorColorRow>(key('text.color')).onChangeEnd!(const Color(0xFF00FF00));
      await tester.pump();
      expect(rig.text(Ids.t1).style.color, 0xFF00FF00);
      expect(rig.entries, before + 1);

      final opacity = find.descendant(of: key('text.opacity'), matching: find.byType(InspectorSliderRow));
      tester.widget<InspectorSliderRow>(opacity).onSubmitted!(0.5);
      await tester.pump();
      expect(rig.text(Ids.t1).transform.opacity, 0.5);
      expect(rig.entries, before + 2);

      await tap(tester, find.descendant(of: key('text.align'), matching: find.text(TextStrings.align(TextAlignH.left))));
      expect(rig.text(Ids.t1).style.align, TextAlignH.left);

      slider(tester, 'text.letterSpacing').onSubmitted!(12);
      await tester.pump();
      expect(rig.text(Ids.t1).style.letterSpacing, 12);
      slider(tester, 'text.lineHeight').onSubmitted!(2);
      await tester.pump();
      expect(rig.text(Ids.t1).style.lineHeight, 2);
      expect(rig.entries, before + 5);
    });
  });

  group('background, stroke, shadow', () {
    Future<void> toggle(WidgetTester tester, String k) =>
        tap(tester, find.descendant(of: key(k), matching: find.byType(DanaviewSwitchRow)));

    testText('background box', (tester) async {
      final rig = await TextRig.pump(tester, tab: TextPanelTab.background);
      expect(key('text.background.off'), findsOneWidget);
      await toggle(tester, 'text.background');
      expect(rig.text(Ids.t1).style.background, const BoxStyle());
      slider(tester, 'text.background.opacity').onSubmitted!(0.25);
      await tester.pump();
      slider(tester, 'text.background.padding').onSubmitted!(20);
      await tester.pump();
      slider(tester, 'text.background.cornerRadius').onSubmitted!(4);
      await tester.pump();
      tester.widget<InspectorColorRow>(key('text.background.color')).onChanged(const Color(0xFF112233));
      await tester.pump();
      expect(rig.text(Ids.t1).style.background,
          const BoxStyle(color: 0xFF112233, opacity: 0.25, paddingPt: 20, cornerRadiusPt: 4));
      await toggle(tester, 'text.background');
      expect(rig.text(Ids.t1).style.background, isNull);
    });

    testText('stroke', (tester) async {
      final rig = await TextRig.pump(tester, tab: TextPanelTab.stroke);
      await toggle(tester, 'text.stroke');
      expect(rig.text(Ids.t1).style.stroke, const StrokeStyle());
      slider(tester, 'text.stroke.width').onSubmitted!(30);
      await tester.pump();
      expect(rig.text(Ids.t1).style.stroke!.widthPt, 20, reason: 'clamped to 0–20');
      tester.widget<InspectorColorRow>(key('text.stroke.color')).onChanged(const Color(0xFFFFFF00));
      await tester.pump();
      expect(rig.text(Ids.t1).style.stroke, const StrokeStyle(color: 0xFFFFFF00, widthPt: 20));
      await toggle(tester, 'text.stroke');
      expect(rig.text(Ids.t1).style.stroke, isNull);
    });

    testText('shadow', (tester) async {
      final rig = await TextRig.pump(tester, tab: TextPanelTab.shadow);
      await toggle(tester, 'text.shadow');
      expect(rig.text(Ids.t1).style.shadow, const ShadowStyle());
      for (final (k, v) in [('opacity', 0.8), ('blur', 10.0), ('distance', 7.0), ('angle', 45.0)]) {
        slider(tester, 'text.shadow.$k').onSubmitted!(v);
        await tester.pump();
      }
      expect(rig.text(Ids.t1).style.shadow, const ShadowStyle(opacity: 0.8, blurPt: 10, distancePt: 7, angleDeg: 45));
      await toggle(tester, 'text.shadow');
      expect(rig.text(Ids.t1).style.shadow, isNull);
    });
  });

  group('animation', () {
    testText('in/out kinds, slide direction, durations; typewriter is in only', (tester) async {
      final rig = await TextRig.pump(tester, tab: TextPanelTab.animation);
      expect(key('text.anim.out.typewriter'), findsNothing);
      expect(key('text.anim.in.typewriter'), findsOneWidget);
      final before = rig.entries;
      await tap(tester, key('text.anim.in.slide'));
      var a = rig.text(Ids.t1).animation;
      expect(a.inKind, TextAnimKind.slide);
      expect(a.inDuration, 500000);
      await tap(tester, find.descendant(of: key('text.anim.in.direction'), matching: find.text(TextStrings.slideDirection(TextSlideDirection.left))));
      expect(rig.text(Ids.t1).animation.inDirection, TextSlideDirection.left);
      slider(tester, 'text.anim.in.duration').onSubmitted!(1.0);
      await tester.pump();
      expect(rig.text(Ids.t1).animation.inDuration, 1000000);

      await tap(tester, key('text.anim.out.fade'));
      a = rig.text(Ids.t1).animation;
      expect(a.outKind, TextAnimKind.fade);
      expect(a.outDuration, 500000);
      drag(tester, 'text.anim.out.duration', [0.8, 1.2, 2.0]);
      await tester.pump();
      a = rig.text(Ids.t1).animation;
      expect(a.inDuration + a.outDuration, lessThanOrEqualTo(rig.text(Ids.t1).duration));
      expect(a.outDuration, 2000000);
      expect(rig.entries, before + 5);

      await tap(tester, key('text.anim.in.none'));
      expect(rig.text(Ids.t1).animation.inKind, TextAnimKind.none);
      expect(rig.text(Ids.t1).animation.inDuration, 0);
    });

    testText('typewriter in with a 3 s item that is too short for in + out', (tester) async {
      final rig = await TextRig.pump(tester, tab: TextPanelTab.animation);
      await tap(tester, key('text.anim.in.typewriter'));
      slider(tester, 'text.anim.in.duration').onSubmitted!(2);
      await tester.pump();
      await tap(tester, key('text.anim.out.scale'));
      slider(tester, 'text.anim.out.duration').onSubmitted!(2);
      await tester.pump();
      final a = rig.text(Ids.t1).animation;
      expect(a.inKind, TextAnimKind.typewriter);
      expect(a.inDuration, 2000000);
      expect(a.outDuration, 1000000, reason: 'the command fits in + out into the 3 s item');
      expect(key('text.anim.shortened'), findsOneWidget);
    });

    testText('Preview loops the item range and restores the transport on close', (tester) async {
      final rig = await TextRig.pump(tester, tab: TextPanelTab.animation);
      await rig.seek(5 * s);
      await tap(tester, key('text.preview'));
      await rig.settle();
      expect(rig.transport.loop.value, TimeRange(1 * s, 4 * s));
      expect(rig.transport.playing.value, isTrue);
      expect(find.text(TextStrings.stopPreview), findsOneWidget);
      await rig.closePanel();
      expect(rig.transport.playing.value, isFalse);
      expect(rig.transport.loop.value, isNull);
      expect(rig.playhead.value, 5 * s);
    });
  });

  group('states', () {
    testText('a locked lane shows a notice and disables the controls', (tester) async {
      final rig = await TextRig.pump(tester, open: Ids.lockedText);
      expect(key('text.locked'), findsOneWidget);
      expect(tester.widget<EditableText>(field).readOnly || !tester.widget<EditableText>(field).focusNode.canRequestFocus, isTrue);
      await openTab(tester, TextPanelTab.style);
      expect(slider(tester, 'text.letterSpacing').enabled, isFalse);
      expect(rig.entries, 0);
    });

    testText('deleting the item while the panel is open is safe (the host closes it)', (tester) async {
      final rig = await TextRig.pump(tester);
      rig.editor.apply(DeleteItems({Ids.t1}));
      await tester.pump();
      await rig.settle();
      expectNoOverflow(tester);
      expect(find.byType(TextPanel), findsNothing);
    });
  });

  group('matrix', () {
    for (final tab in TextPanelTab.values) {
      testSurfaces('tab ${tab.name}: no overflow, owner UI rules', (tester, surface) async {
        try {
          final rig = await TextRig.pump(tester, surface: surface, tab: tab);
          // Long content: every switch on, slide animations, a long text.
          rig.editor.apply(SetTextStyle([Ids.t1], background: const BoxStyle(), stroke: const StrokeStyle(), shadow: const ShadowStyle()));
          rig.editor.apply(SetTextAnimation([Ids.t1], const TextAnimation(
            inKind: TextAnimKind.slide, inDuration: 500000, outKind: TextAnimKind.slide, outDuration: 500000)));
          rig.editor.apply(SetText(Ids.t1, 'A much longer piece of text that wraps over several lines in the field ' * 3));
          await tester.pump();
          expectNoOverflow(tester);
          expectOwnerUiRules(tester);
          expectInside(tester, key(TextPanelModel.tabKey(TextPanelTab.edit)));
          final spec = frameSpec(tester);
          if (tab == TextPanelTab.edit) {
            expect(key('text.liveChip'), spec.previewHidden && spec.keyboardVisible ? findsOneWidget : findsNothing);
          }
        } finally {
          await tester.pump(const Duration(seconds: 5));
          EditorAnnouncer.instance.reset();
        }
      });
    }

    testSurfaces('keyboard up in compact portrait: the live text chip replaces the hidden preview', (tester, surface) async {
      try {
        await TextRig.pump(tester, surface: surface);
        final spec = frameSpec(tester);
        expect(spec.keyboardVisible, isTrue);
        if (surface.size.height < 600) expect(spec.previewHidden, isTrue, reason: 'degrade step 5 on short phones');
        if (spec.previewHidden) {
          expect(key('text.liveChip'), findsOneWidget);
          expectInside(tester, key('text.liveChip'));
        }
        expectInside(tester, key('text.field'));
        expectNoOverflow(tester);
        expectOwnerUiRules(tester);
      } finally {
        await tester.pump(const Duration(seconds: 5));
        EditorAnnouncer.instance.reset();
      }
    }, surfaces: const [
      EditorSurface(Size(390, 844), keyboardFraction: 0.4, platform: TargetPlatform.iOS),
      EditorSurface(Size(320, 568), keyboardFraction: 0.4, textScale: 1.35),
      EditorSurface(Size(280, 500), keyboardFraction: 0.4, textScale: 1.35),
    ]);
  });
}

/// A SetText for the typing-run unit test.
abstract final class SetTextKey {
  static const SetText cmd = SetText(ItemId('it_x'), 'x');
}
