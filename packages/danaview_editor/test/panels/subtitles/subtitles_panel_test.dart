// OWNER: UX-31
//
// The captions panel (ux.md §10.9): every action dispatches its CORE-15 command as one history
// entry (add, text, timing nudges, split at the cursor, merge, delete, shift, style, position,
// language, burn-in), the track menu's "Shift all captions…" (one ShiftCues for the whole track or
// the selected range) and "Select all on this lane" (only that track's cues), the start state,
// the locked state, the current-cue highlight, and the matrix (no overflow, owner UI rules).

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/strings/subtitle_strings.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/inspector/inspector_rows.dart';
import 'package:danaview_editor/src/editor/panels/subtitles_panel.dart';
import 'package:danaview_editor/src/editor/timeline/timeline_semantics.dart' show EditorAnnouncer;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../support/support.dart';
import 'subtitles_rig.dart';

Finder key(Key k) => find.byKey(k);

/// Scrolls [finder] into view and taps it.
Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
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
  await tester.tap(find.text(label).last);
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

  group('smoke', () {
    testSubtitles('lists the cues of the track', (tester) async {
      final rig = await SubtitlesRig.pump(tester);
      expect(find.byType(SubtitlesPanel), findsOneWidget);
      expect(find.text('Hello world'), findsOneWidget);
      expect(find.text(SubtitleStrings.cueCount(4)), findsOneWidget);
      expect(rig.state.inspector, const SubtitlesInspector(track: Subs.a));
    });
  });
}
