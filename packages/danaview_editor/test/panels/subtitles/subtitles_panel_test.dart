// OWNER: UX-31
//
// The captions panel (ux.md §10.9): every action dispatches its CORE-15 command as one history
// entry (add, text, timing nudges, split at the cursor, merge, delete, shift, style, position,
// language, burn-in), the track menu's "Shift all captions…" (one ShiftCues for the whole track or
// the selected range) and "Select all on this lane" (only that track's cues), the start state,
// the locked state, the current-cue highlight, and the matrix (no overflow, owner UI rules).

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/strings/subtitle_strings.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_rows.dart';
import 'package:danaview_editor/src/editor/panels/font_picker.dart';
import 'package:danaview_editor/src/editor/panels/subtitles_panel.dart';
import 'package:danaview_editor/src/editor/state/editor_state.dart' show SelectMode;
import 'package:danaview_editor/src/editor/timeline/timeline_semantics.dart' show EditorAnnouncer;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../support/support.dart';
import 'subtitles_rig.dart';

Finder key(Key k) => find.byKey(k);

/// Builds and scrolls [finder] into view (the panel builds its slivers lazily).
Future<void> reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    final scrollable = find.descendant(of: key(SubtitlesPanelKeys.scroll), matching: find.byType(Scrollable)).first;
    tester.state<ScrollableState>(scrollable).position.jumpTo(0);
    await tester.pump();
    if (finder.evaluate().isEmpty) await tester.scrollUntilVisible(finder, 80, scrollable: scrollable, maxScrolls: 400);
  }
  await tester.ensureVisible(finder);
  await tester.pump();
}

/// Scrolls [finder] into view and taps it.
Future<void> tap(WidgetTester tester, Finder finder) async {
  await reveal(tester, finder);
  await tester.tap(finder);
  await tester.pump();
}

/// Taps the text of a segment inside [within].
Future<void> tapSegment(WidgetTester tester, Key within, String label) =>
    tap(tester, find.descendant(of: key(within), matching: find.text(label)));

/// Opens the track menu and taps [label].
Future<void> menu(WidgetTester tester, String label) async {
  await tap(tester, find.descendant(of: key(SubtitlesPanelKeys.menu), matching: find.byType(DanaviewIconButton)));
  await tester.pump(const Duration(milliseconds: 300));
  final item = find.text(label).last;
  await tester.ensureVisible(item);
  await tester.pump();
  await tester.tap(item);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void testSubtitles(String description, Future<void> Function(WidgetTester tester) body) => testWidgets(description, (tester) async {
      try {
        await body(tester);
        await tester.pump(const Duration(seconds: 5));
      } finally {
        EditorAnnouncer.instance.reset();
        DanaviewToast.dismiss();
      }
    });

void testSubtitleSurfaces(String description, Future<void> Function(WidgetTester tester, EditorSurface surface) body) =>
    testSurfaces(description, (tester, surface) async {
      try {
        await body(tester, surface);
        await tester.pump(const Duration(seconds: 5));
      } finally {
        EditorAnnouncer.instance.reset();
        DanaviewToast.dismiss();
      }
    });

void main() {
  late DateTime now;
  setUp(() {
    EditorAnnouncer.instance.reset();
    now = DateTime.utc(2026, 10, 14, 9);
    InspectorRows.clock = () => now;
  });
  tearDown(() => InspectorRows.clock = DateTime.now);

  Finder row(ItemId c) => key(SubtitlesPanelKeys.row(c));

  Future<void> focusRow(WidgetTester tester, ItemId c) async {
    await reveal(tester, row(c));
    await tap(tester, find.descendant(of: row(c), matching: find.byType(DanaviewPressable)).first);
    await tester.pump();
  }

  group('cue list', () {
    testSubtitles('lists the cues of the track with tabular timing; the header counts them', (tester) async {
      final rig = await SubtitlesRig.pump(tester);
      expect(find.byType(SubtitlesPanel), findsOneWidget);
      expect(find.text('Hello world'), findsOneWidget);
      expect(find.text('Bee one'), findsNothing, reason: 'another track');
      expect(find.text(SubtitleStrings.cueCount(4)), findsOneWidget);
      expect(find.text(SubtitleStrings.timing('00:01:00', '00:03:00')), findsOneWidget);
      expect(rig.state.inspector, const SubtitlesInspector(track: Subs.a));
      expect(key(SubtitlesPanelKeys.editor), findsNothing, reason: 'no row is expanded without a focused cue');
    });

    testSubtitles('tapping a row focuses the cue, selects it and moves the playhead to its start', (tester) async {
      final rig = await SubtitlesRig.pump(tester);
      final before = rig.entries;
      await focusRow(tester, Subs.a2);
      expect(rig.state.inspector, const SubtitlesInspector(track: Subs.a, cue: Subs.a2));
      expect(rig.state.selection.items, {Subs.a2});
      expect(rig.state.selection.primary, Subs.a2);
      expect(rig.playhead.value, 4 * s);
      expect(key(SubtitlesPanelKeys.editor), findsOneWidget);
      expect(tester.getRect(key(SubtitlesPanelKeys.editor)).top, moreOrLessEquals(tester.getRect(row(Subs.a2)).bottom, epsilon: 2),
          reason: 'the row expands into the editor directly below it');
      expect(rig.entries, before, reason: 'selection is not history');
      // Another row keeps the panel open on the new cue.
      await focusRow(tester, Subs.a3);
      expect(rig.state.inspector, const SubtitlesInspector(track: Subs.a, cue: Subs.a3));
      expect(rig.playhead.value, 8 * s);
    });

    testSubtitles('the cue under the playhead is highlighted and follows the playhead', (tester) async {
      final rig = await SubtitlesRig.pump(tester);
      Finder current(ItemId c) => find.descendant(
            of: row(c),
            matching: find.byWidgetPredicate((w) => w is Semantics && w.properties.value == SubtitleStrings.current),
          );
      await rig.seek(frames(135)); // 4.5 s
      await tester.pump();
      expect(current(Subs.a2), findsOneWidget);
      expect(current(Subs.a1), findsNothing);
      await rig.seek(frames(240)); // 8 s
      await tester.pump();
      expect(current(Subs.a3), findsOneWidget);
      expect(current(Subs.a2), findsNothing);
      await rig.seek(frames(210)); // 7 s: between cues
      await tester.pump();
      for (final c in [Subs.a1, Subs.a2, Subs.a3, Subs.a4]) {
        expect(current(c), findsNothing);
      }
    });

    testSubtitles('a focused cue far down a long list is scrolled into view', (tester) async {
      final rig = await SubtitlesRig.pump(tester, cueCount: 3000, open: null);
      await rig.openPanel(SubtitlesInspector(track: Subs.a, cue: Subs.many(2000)));
      await tester.pump();
      await tester.pump();
      expect(row(Subs.many(2000)), findsOneWidget);
      final r = tester.getRect(row(Subs.many(2000)));
      final view = tester.getRect(key(SubtitlesPanelKeys.scroll));
      expect(r.top, greaterThanOrEqualTo(view.top - 1));
      expect(r.top, lessThan(view.bottom));
    });
  });

  group('add', () {
    testSubtitles('Add puts a 2 s caption at the playhead on this track: one AddCue, focused', (tester) async {
      final rig = await SubtitlesRig.pump(tester, playheadAt: 6 * s + frames(15));
      final before = rig.entries;
      await tap(tester, key(SubtitlesPanelKeys.add));
      final cues = rig.cues(Subs.a);
      expect(cues, hasLength(5));
      final added = cues.firstWhere((c) => c.text == SubtitleStrings.newCueText);
      expect(added.start, 6 * s + frames(15));
      expect(added.end, 8 * s, reason: 'shortened to fit before the next caption');
      expect(rig.entries, before + 1);
      expect(rig.state.history.undoLabel, 'Add caption');
      expect(rig.state.inspector, SubtitlesInspector(track: Subs.a, cue: added.id));
      expect(rig.state.selection.primary, added.id);
      expect(key(SubtitlesPanelKeys.editor), findsOneWidget);
    });

    testSubtitles('Add where a caption already is shows the rejection and adds nothing', (tester) async {
      final rig = await SubtitlesRig.pump(tester, playheadAt: 2 * s);
      final before = rig.entries;
      await tap(tester, key(SubtitlesPanelKeys.add));
      expect(rig.cues(Subs.a), hasLength(4));
      expect(rig.entries, before);
    });
  });

  group('focused cue', () {
    testSubtitles('text: Return inserts a line break, Done commits one SetCueText', (tester) async {
      final rig = await SubtitlesRig.pump(tester);
      await focusRow(tester, Subs.a1);
      final before = rig.entries;
      await tester.enterText(key(SubtitlesPanelKeys.text), 'Line one\nLine two');
      await tester.pump();
      expect(rig.cueOf(Subs.a1)!.text, 'Hello world', reason: 'not committed while typing');
      await tap(tester, key(SubtitlesPanelKeys.done));
      expect(rig.cueOf(Subs.a1)!.text, 'Line one\nLine two');
      expect(rig.entries, before + 1);
      expect(rig.state.history.undoLabel, 'Edit caption');
    });

    testSubtitles('blank text is refused with a next step', (tester) async {
      final rig = await SubtitlesRig.pump(tester);
      await focusRow(tester, Subs.a1);
      final before = rig.entries;
      await tester.enterText(key(SubtitlesPanelKeys.text), '   ');
      await tester.pump();
      await tap(tester, key(SubtitlesPanelKeys.done));
      expect(find.text(SubtitleStrings.emptyText), findsOneWidget);
      expect(rig.cueOf(Subs.a1)!.text, 'Hello world');
      expect(rig.entries, before);
    });

    testSubtitles('start and end nudge by one frame, by 0.1 s and to the playhead: one SetCueRange each', (tester) async {
      final rig = await SubtitlesRig.pump(tester);
      await focusRow(tester, Subs.a2); // 4–6 s, playhead at 4 s
      var entries = rig.entries;
      Future<void> step(String edge, IconData icon) =>
          tap(tester, find.descendant(of: key(SubtitlesPanelKeys.field(edge)), matching: find.byIcon(icon)));

      await step('start', Icons.add_rounded);
      expect(rig.cueOf(Subs.a2)!.start, frames(121));
      expect(rig.entries, ++entries);
      expect(rig.state.history.undoLabel, 'Retime caption');
      await step('start', Icons.remove_rounded);
      expect(rig.cueOf(Subs.a2)!.start, frames(120));
      expect(rig.entries, ++entries);
      await step('end', Icons.remove_rounded);
      expect(rig.cueOf(Subs.a2)!.end, frames(179));
      expect(rig.entries, ++entries);

      await tap(tester, key(SubtitlesPanelKeys.plus100('end')));
      expect(rig.cueOf(Subs.a2)!.end, frames(182));
      expect(rig.entries, ++entries);
      await tap(tester, key(SubtitlesPanelKeys.minus100('start')));
      expect(rig.cueOf(Subs.a2)!.start, frames(117));
      expect(rig.entries, ++entries);

      await rig.seek(5 * s);
      await tap(tester, key(SubtitlesPanelKeys.toPlayhead('end')));
      expect(rig.cueOf(Subs.a2)!.end, 5 * s);
      expect(rig.entries, ++entries);
      await rig.seek(frames(100));
      await tap(tester, key(SubtitlesPanelKeys.toPlayhead('start')));
      expect(rig.cueOf(Subs.a2)!.start, frames(100));
      expect(rig.entries, ++entries);
    });

    testSubtitles('a nudge into the previous caption is rejected (no overlap) and nothing changes', (tester) async {
      final rig = await SubtitlesRig.pump(tester);
      await focusRow(tester, Subs.a2);
      await rig.seek(2 * s); // inside a1
      final before = rig.entries;
      await tap(tester, key(SubtitlesPanelKeys.toPlayhead('start')));
      expect(rig.cueOf(Subs.a2)!.start, 4 * s);
      expect(rig.entries, before);
    });

    testSubtitles('typing a timecode into Start sets it', (tester) async {
      final rig = await SubtitlesRig.pump(tester);
      await focusRow(tester, Subs.a2);
      final field = find.descendant(of: key(SubtitlesPanelKeys.field('start')), matching: find.byType(EditableText));
      await reveal(tester, field);
      await tester.tap(field);
      await tester.pump();
      await tester.enterText(field, '00:03:15');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(rig.cueOf(Subs.a2)!.start, frames(105));
    });

    testSubtitles('split at the playhead splits the text at the cursor: one SplitCue', (tester) async {
      final rig = await SubtitlesRig.pump(tester);
      await focusRow(tester, Subs.a2); // "Second caption" 4–6 s
      await rig.seek(5 * s);
      final field = find.descendant(of: key(SubtitlesPanelKeys.text), matching: find.byType(EditableText));
      await tester.tap(field);
      await tester.pump();
      tester.state<EditableTextState>(field).userUpdateTextEditingValue(
            const TextEditingValue(text: 'Second caption', selection: TextSelection.collapsed(offset: 3)),
            SelectionChangedCause.tap,
          );
      await tester.pump();
      final before = rig.entries;
      await tap(tester, key(SubtitlesPanelKeys.split));
      final cues = rig.cues(Subs.a);
      expect(cues, hasLength(5));
      expect(rig.cueOf(Subs.a2)!.text, 'Sec');
      expect(rig.cueOf(Subs.a2)!.end, 5 * s);
      expect(cues.firstWhere((c) => c.start == 5 * s).text, 'ond caption');
      expect(rig.entries, before + 1);
      expect(rig.state.history.undoLabel, 'Split caption');
    });

    testSubtitles('split without a placed cursor uses the word boundary nearest the middle', (tester) async {
      final rig = await SubtitlesRig.pump(tester);
      await focusRow(tester, Subs.a1); // "Hello world" 1–3 s
      await rig.seek(2 * s);
      await tap(tester, key(SubtitlesPanelKeys.split));
      expect(rig.cueOf(Subs.a1)!.text, 'Hello');
      expect(rig.cues(Subs.a).firstWhere((c) => c.start == 2 * s).text, 'world');
    });

    testSubtitles('split is disabled while the playhead is outside the caption', (tester) async {
      final rig = await SubtitlesRig.pump(tester);
      await focusRow(tester, Subs.a1); // playhead moves to its start: not strictly inside
      expect(tester.widget<DanaviewButton>(key(SubtitlesPanelKeys.split)).onPressed, isNull);
      await rig.seek(2 * s);
      expect(tester.widget<DanaviewButton>(key(SubtitlesPanelKeys.split)).onPressed, isNotNull);
    });

    testSubtitles('merge with next: one MergeCues, texts joined, the panel stays on the cue', (tester) async {
      final rig = await SubtitlesRig.pump(tester);
      await focusRow(tester, Subs.a1);
      final before = rig.entries;
      await tap(tester, key(SubtitlesPanelKeys.merge));
      final merged = rig.cueOf(Subs.a1)!;
      expect(merged.text, 'Hello world Second caption');
      expect(merged.start, 1 * s);
      expect(merged.end, 6 * s);
      expect(rig.cueOf(Subs.a2), isNull);
      expect(rig.entries, before + 1);
      expect(rig.state.history.undoLabel, 'Merge captions');
      expect(rig.state.inspector, const SubtitlesInspector(track: Subs.a, cue: Subs.a1));
    });

    testSubtitles('merge is disabled on the last caption', (tester) async {
      await SubtitlesRig.pump(tester);
      await focusRow(tester, Subs.a4);
      expect(tester.widget<DanaviewButton>(key(SubtitlesPanelKeys.merge)).onPressed, isNull);
    });

    testSubtitles('delete: one DeleteCues and the panel stays open on the track', (tester) async {
      final rig = await SubtitlesRig.pump(tester);
      await focusRow(tester, Subs.a3);
      final before = rig.entries;
      await tap(tester, key(SubtitlesPanelKeys.delete));
      expect(rig.cueOf(Subs.a3), isNull);
      expect(rig.cues(Subs.a), hasLength(3));
      expect(rig.entries, before + 1);
      expect(rig.state.history.undoLabel, 'Delete caption');
      expect(rig.state.inspector, const SubtitlesInspector(track: Subs.a));
      expect(find.byType(SubtitlesPanel), findsOneWidget);
      rig.editor.undo();
      await tester.pump();
      expect(rig.cueOf(Subs.a3), isNotNull);
    });

    testSubtitles('Go to start moves the playhead to the caption', (tester) async {
      final rig = await SubtitlesRig.pump(tester);
      await focusRow(tester, Subs.a2);
      await rig.seek(20 * s);
      await tap(tester, key(SubtitlesPanelKeys.jump));
      await rig.real(() async {});
      expect(rig.playhead.value, 4 * s);
    });
  });

  group('track menu', () {
    testSubtitles('Shift all captions… re-times the whole track by +2.5s as one history entry', (tester) async {
      final rig = await SubtitlesRig.pump(tester);
      final starts = [for (final c in rig.cues(Subs.a)) c.start];
      final before = rig.entries;
      await menu(tester, SubtitleStrings.shiftAll);
      expect(find.text(SubtitleStrings.shiftAllMessage(4)), findsOneWidget);
      await tester.enterText(find.byType(EditableText).last, '+2.5s');
      await tester.pump();
      await tester.tap(find.text(SubtitleStrings.shiftConfirm));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect([for (final c in rig.cues(Subs.a)) c.start], [for (final t in starts) t + frames(75)]);
      expect([for (final c in rig.cues(Subs.b)) c.start], [0, 3 * s], reason: 'other tracks stay');
      expect(rig.entries, before + 1);
      expect(rig.state.history.undoLabel, 'Shift captions');
      expect(find.text(SubtitleStrings.shifted('+2.50 s')), findsOneWidget);
      rig.editor.undo();
      await tester.pump();
      expect([for (final c in rig.cues(Subs.a)) c.start], starts, reason: 'one undo restores every caption');
    });

    testSubtitles('Shift with two captions selected re-times only the selected range (-10f)', (tester) async {
      final rig = await SubtitlesRig.pump(tester);
      rig.editor
        ..select(Subs.a2)
        ..select(Subs.a3, mode: SelectMode.extend);
      await tester.pump();
      final before = rig.entries;
      await menu(tester, SubtitleStrings.shiftSelected);
      expect(find.text(SubtitleStrings.shiftRangeMessage(2)), findsOneWidget);
      await tester.enterText(find.byType(EditableText).last, '-10f');
      await tester.pump();
      await tester.tap(find.text(SubtitleStrings.shiftConfirm));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(rig.cueOf(Subs.a1)!.start, 1 * s);
      expect(rig.cueOf(Subs.a2)!.start, frames(110));
      expect(rig.cueOf(Subs.a3)!.start, frames(230));
      expect(rig.cueOf(Subs.a4)!.start, 10 * s);
      expect(rig.entries, before + 1);
    });

    testSubtitles('Shift refuses input that is not a time', (tester) async {
      final rig = await SubtitlesRig.pump(tester);
      final before = rig.entries;
      await menu(tester, SubtitleStrings.shiftAll);
      await tester.enterText(find.byType(EditableText).last, 'soon');
      await tester.pump();
      await tester.tap(find.text(SubtitleStrings.shiftConfirm));
      await tester.pump();
      expect(find.text(SubtitleStrings.shiftInvalid), findsOneWidget);
      await tester.tap(find.text(SubtitleStrings.cancel));
      await tester.pump(const Duration(milliseconds: 300));
      expect(rig.entries, before);
    });

    testSubtitles('Select all on this lane selects only this track\'s cues', (tester) async {
      final rig = await SubtitlesRig.pump(tester);
      await focusRow(tester, Subs.a1);
      await menu(tester, SubtitleStrings.selectAll);
      expect(rig.state.selection.items, {Subs.a1, Subs.a2, Subs.a3, Subs.a4});
      expect(rig.state.selection.lane, Subs.a);
      expect(find.byType(SubtitlesPanel), findsOneWidget, reason: 'the panel stays open');
    });

    testSubtitles('Burn into video toggles SetBurnIn', (tester) async {
      final rig = await SubtitlesRig.pump(tester);
      expect(rig.data(Subs.a).burnIn, isTrue);
      final before = rig.entries;
      await menu(tester, SubtitleStrings.burnIn);
      expect(rig.data(Subs.a).burnIn, isFalse);
      expect(rig.entries, before + 1);
    });

    testSubtitles('the menu switches to another subtitle track', (tester) async {
      final rig = await SubtitlesRig.pump(tester);
      await menu(tester, 'English');
      expect(rig.state.inspector, const SubtitlesInspector(track: Subs.b));
      expect(find.text('Bee one'), findsOneWidget);
    });

    testSubtitles('Delete track asks first, then deletes and shows the start state', (tester) async {
      final rig = await SubtitlesRig.pump(tester);
      await menu(tester, SubtitleStrings.deleteTrack);
      expect(find.text(SubtitleStrings.deleteMessage(4)), findsOneWidget);
      await tester.tap(find.text(SubtitleStrings.deleteConfirm));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(rig.project.tracks.any((t) => t.id == Subs.a), isFalse);
      expect(key(SubtitlesPanelKeys.start), findsOneWidget);
    });

    testSubtitles('unbound actions (Import, Export, Auto captions) are disabled with a reason', (tester) async {
      await SubtitlesRig.pump(tester);
      await tap(tester, find.descendant(of: key(SubtitlesPanelKeys.menu), matching: find.byType(DanaviewIconButton)));
      await tester.pump(const Duration(milliseconds: 300));
      for (final label in [SubtitleStrings.importFile, SubtitleStrings.exportFile, SubtitleStrings.autoCaptions]) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text(SubtitleStrings.notAvailable), findsWidgets);
    });
  });

  group('style', () {
    Future<SubtitlesRig> openStyle(WidgetTester tester, {EditorSurface surface = const EditorSurface(Size(1280, 900))}) =>
        SubtitlesRig.pump(tester, surface: surface, open: const SubtitlesInspector(track: Subs.a, section: SubtitlesPanelSection.style));

    testSubtitles('the section switcher opens Style and Position', (tester) async {
      final rig = await SubtitlesRig.pump(tester);
      await tapSegment(tester, SubtitlesPanelKeys.sections, SubtitleStrings.section(SubtitlesPanelSection.style));
      expect(rig.state.inspector, const SubtitlesInspector(track: Subs.a, section: SubtitlesPanelSection.style));
      expect(key(SubtitlesPanelKeys.style('size')), findsOneWidget);
      await tapSegment(tester, SubtitlesPanelKeys.sections, SubtitleStrings.section(SubtitlesPanelSection.position));
      expect(key(SubtitlesPanelKeys.style('placement')), findsOneWidget);
    });

    testSubtitles('switches: bold, italic, box, outline, shadow are one SetSubtitleStyle each', (tester) async {
      final rig = await openStyle(tester);
      var entries = rig.entries;
      Future<void> flip(String k, String label) async {
        await tap(tester, find.descendant(of: key(SubtitlesPanelKeys.style(k)), matching: find.text(label)));
        expect(rig.entries, ++entries, reason: k);
        expect(rig.state.history.undoLabel, 'Caption style');
      }

      await flip('bold', SubtitleStrings.bold);
      expect(rig.data(Subs.a).style.bold, isTrue);
      await flip('italic', SubtitleStrings.italic);
      expect(rig.data(Subs.a).style.italic, isTrue);
      await flip('box', SubtitleStrings.box);
      expect(rig.data(Subs.a).style.background, isNull);
      await flip('outline', SubtitleStrings.outline);
      expect(rig.data(Subs.a).style.outline, const StrokeStyle());
      expect(key(SubtitlesPanelKeys.style('outlineWidth')), findsOneWidget);
      await flip('shadow', SubtitleStrings.shadow);
      expect(rig.data(Subs.a).style.shadow, const ShadowStyle());
      expect(rig.data(Subs.b).style, const SubtitleStyle(), reason: 'other tracks keep their style');
    });

    testSubtitles('lines per caption and alignment', (tester) async {
      final rig = await openStyle(tester);
      await tapSegment(tester, SubtitlesPanelKeys.style('maxLines'), '3');
      expect(rig.data(Subs.a).style.maxLines, 3);
      await tapSegment(tester, SubtitlesPanelKeys.style('align'), SubtitleStrings.align(TextAlignH.left));
      expect(rig.data(Subs.a).style.align, TextAlignH.left);
    });

    testSubtitles('a size drag is one history entry', (tester) async {
      final rig = await openStyle(tester);
      final before = rig.entries;
      final slider = find.descendant(of: key(SubtitlesPanelKeys.style('size')), matching: find.byType(DanaviewSlider));
      await reveal(tester, slider);
      await tester.pump();
      final g = await tester.startGesture(tester.getCenter(slider));
      await tester.pump();
      for (var i = 0; i < 5; i++) {
        await g.moveBy(const Offset(12, 0));
        await tester.pump();
      }
      await g.up();
      await tester.pump();
      expect(rig.data(Subs.a).style.fontSizePt, isNot(42));
      expect(rig.entries, before + 1);
    });

    testSubtitles('font: picking a family sets it', (tester) async {
      final rig = await openStyle(tester);
      await tap(tester, key(SubtitlesPanelKeys.style('fontToggle')));
      final picker = tester.widget<FontPicker>(key(SubtitlesPanelKeys.style('fonts')));
      expect(picker.selectedId, 'figtree');
      final before = rig.entries;
      picker.onSelected('inter');
      await tester.pump();
      expect(rig.entries, before + 1);
      expect(rig.data(Subs.a).style.fontFamily, 'inter');
    });

    testSubtitles('language tag: a valid tag is set, an invalid one explains', (tester) async {
      final rig = await openStyle(tester);
      final field = find.descendant(of: key(SubtitlesPanelKeys.style('language')), matching: find.byType(EditableText));
      await reveal(tester, field);
      await tester.tap(field);
      await tester.pump();
      await tester.enterText(field, 'pt-BR');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(rig.data(Subs.a).language, 'pt-BR');
      expect(rig.state.history.undoLabel, 'Caption language');
      await tester.tap(field);
      await tester.pump();
      await tester.enterText(field, 'not a tag!');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(rig.data(Subs.a).language, 'pt-BR');
      expect(find.text(SubtitleStrings.languageInvalid), findsOneWidget);
    });

    testSubtitles('burn-in switch in the style section', (tester) async {
      final rig = await openStyle(tester);
      await tap(tester, find.descendant(of: key(SubtitlesPanelKeys.style('burnIn')), matching: find.text(SubtitleStrings.burnIn)));
      expect(rig.data(Subs.a).burnIn, isFalse);
    });
  });

  group('position', () {
    testSubtitles('Top, Custom with the vertical slider, Bottom: one SetSubtitlePosition each', (tester) async {
      final rig = await SubtitlesRig.pump(tester, open: const SubtitlesInspector(track: Subs.a, section: SubtitlesPanelSection.position));
      var entries = rig.entries;
      await tapSegment(tester, SubtitlesPanelKeys.style('placement'), SubtitleStrings.top);
      expect(rig.data(Subs.a).position, SubtitlePosition.top);
      expect(rig.entries, ++entries);
      expect(rig.state.history.undoLabel, 'Caption position');
      expect(key(SubtitlesPanelKeys.style('offset')), findsNothing);
      await tapSegment(tester, SubtitlesPanelKeys.style('placement'), SubtitleStrings.custom);
      expect(rig.data(Subs.a).position, const CustomSubtitlePosition(SubtitlesPanelModel.defaultCustomY));
      expect(rig.entries, ++entries);
      expect(key(SubtitlesPanelKeys.style('offset')), findsOneWidget);
      expect(find.text(SubtitleStrings.dragHint), findsOneWidget);
      final slider = find.descendant(of: key(SubtitlesPanelKeys.style('offset')), matching: find.byType(DanaviewSlider));
      final g = await tester.startGesture(tester.getCenter(slider));
      await tester.pump();
      for (var i = 0; i < 4; i++) {
        await g.moveBy(const Offset(-15, 0));
        await tester.pump();
      }
      await g.up();
      await tester.pump();
      final y = (rig.data(Subs.a).position as CustomSubtitlePosition).yFraction;
      expect(y, lessThan(SubtitlesPanelModel.defaultCustomY));
      expect(rig.entries, ++entries, reason: 'the drag is one entry');
      await tapSegment(tester, SubtitlesPanelKeys.style('placement'), SubtitleStrings.bottom);
      expect(rig.data(Subs.a).position, SubtitlePosition.bottom);
    });
  });

  group('start and locked states', () {
    testSubtitles('without subtitle tracks: Add subtitle track creates one and opens it', (tester) async {
      final rig = await SubtitlesRig.pump(tester, subtitles: false, open: const SubtitlesInspector());
      expect(key(SubtitlesPanelKeys.start), findsOneWidget);
      expect(find.text(SubtitleStrings.emptyTitle), findsOneWidget);
      final before = rig.entries;
      await tap(tester, key(SubtitlesPanelKeys.addTrack));
      final subs = rig.project.tracks.where((t) => t.kind == TrackKind.subtitle).toList();
      expect(subs, hasLength(1));
      expect(rig.entries, before + 1);
      expect(rig.state.inspector, SubtitlesInspector(track: subs.single.id));
      expect(key(SubtitlesPanelKeys.add), findsOneWidget);
      expect(find.text(SubtitleStrings.noCues), findsOneWidget);
    });

    testSubtitles('a route without a track lists the subtitle tracks to open', (tester) async {
      final rig = await SubtitlesRig.pump(tester, open: const SubtitlesInspector());
      expect(find.text('English'), findsOneWidget);
      await tap(tester, key(const ValueKey<String>('subtitles.track.tr_b')));
      expect(rig.state.inspector, const SubtitlesInspector(track: Subs.b));
    });

    testSubtitles('a locked track shows the notice and disables editing', (tester) async {
      final rig = await SubtitlesRig.pump(tester, open: const SubtitlesInspector(track: Subs.locked));
      expect(key(SubtitlesPanelKeys.locked), findsOneWidget);
      expect(tester.widget<DanaviewButton>(key(SubtitlesPanelKeys.add)).onPressed, isNull);
      await focusRow(tester, Subs.l1);
      expect(rig.state.inspector, const SubtitlesInspector(track: Subs.locked, cue: Subs.l1));
      expect(tester.widget<DanaviewButton>(key(SubtitlesPanelKeys.delete)).onPressed, isNull);
      expect(tester.widget<DanaviewButton>(key(SubtitlesPanelKeys.plus100('start'))).onPressed, isNull);
    });
  });

  group('matrix (no overflow, owner UI rules)', () {
    testSubtitleSurfaces('cue list with an expanded caption', (tester, surface) async {
      final rig = await SubtitlesRig.pump(tester, surface: surface);
      await rig.openPanel(const SubtitlesInspector(track: Subs.a, cue: Subs.a2));
      await tester.pump();
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      for (final k in [SubtitlesPanelKeys.text, SubtitlesPanelKeys.field('end'), SubtitlesPanelKeys.delete, SubtitlesPanelKeys.toPlayhead('end')]) {
        await reveal(tester, key(k));
        await tester.pump();
        final r = tester.getRect(key(k));
        expect(r.left, greaterThanOrEqualTo(0), reason: '$k');
        expect(r.right, lessThanOrEqualTo(surface.size.width), reason: '$k');
      }
      expectNoOverflow(tester);
    });

    testSubtitleSurfaces('style with box, outline and shadow', (tester, surface) async {
      final rig = await SubtitlesRig.pump(tester, surface: surface, open: const SubtitlesInspector(track: Subs.a, section: SubtitlesPanelSection.style));
      await tap(tester, find.descendant(of: key(SubtitlesPanelKeys.style('outline')), matching: find.text(SubtitleStrings.outline)));
      await tap(tester, find.descendant(of: key(SubtitlesPanelKeys.style('shadow')), matching: find.text(SubtitleStrings.shadow)));
      await tap(tester, key(SubtitlesPanelKeys.style('fontToggle')));
      expect(rig.data(Subs.a).style.outline, isNotNull);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      await reveal(tester, key(SubtitlesPanelKeys.style('burnIn')));
      await tester.pump();
      expectNoOverflow(tester);
    });

    testSubtitleSurfaces('custom position', (tester, surface) async {
      final rig = await SubtitlesRig.pump(tester, surface: surface, open: const SubtitlesInspector(track: Subs.a, section: SubtitlesPanelSection.position));
      await tapSegment(tester, SubtitlesPanelKeys.style('placement'), SubtitleStrings.custom);
      expect(rig.data(Subs.a).position, isA<CustomSubtitlePosition>());
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
    });

    testSubtitleSurfaces('start state and locked track', (tester, surface) async {
      final rig = await SubtitlesRig.pump(tester, surface: surface, subtitles: false, open: const SubtitlesInspector());
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      await tap(tester, key(SubtitlesPanelKeys.addTrack));
      expectNoOverflow(tester);
      expect(rig.project.tracks.where((t) => t.kind == TrackKind.subtitle), hasLength(1));
    });

    testSubtitleSurfaces('locked track with the menu open', (tester, surface) async {
      await SubtitlesRig.pump(tester, surface: surface, open: const SubtitlesInspector(track: Subs.locked));
      expect(key(SubtitlesPanelKeys.locked), findsOneWidget);
      await tap(tester, find.descendant(of: key(SubtitlesPanelKeys.menu), matching: find.byType(DanaviewIconButton)));
      await tester.pump(const Duration(milliseconds: 300));
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
    });
  });
}
