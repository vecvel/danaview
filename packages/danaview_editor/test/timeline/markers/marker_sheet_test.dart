// OWNER: UX-17
//
// The marker sheet over a real EditorController: the list (rows by time, jump, select, empty state,
// add), the editor (name, colour, note staged and committed as one entry by Done, back and
// dismissal; delete; go to), semantics, and the no-overflow matrix with long content.

import 'package:flutter/material.dart' show Icons;
import 'dart:ui' show Tristate;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/timeline/marker_sheet.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../support/support.dart';
import 'marker_support.dart';

Future<void> tapKey(WidgetTester tester, String k) async {
  await tester.ensureVisible(key(k));
  await tester.tap(key(k));
  await tester.pumpAndSettle();
}

String rowKey(Marker m) => 'marker-row-${m.id.value}';

void main() {
  group('list', () {
    testWidgets('lists the markers by time with name, timecode, colour and the first line of the note', (tester) async {
      final rig = await pumpMarkers(tester);
      addSampleMarkers(rig);
      await openSheet(tester, rig);
      final markers = markersOf(rig);
      expect(markers.map((m) => m.name), ['Intro', 'Chorus', '', '']);
      final order = [for (final m in markers) tester.getTopLeft(key(rowKey(m))).dy];
      expect(order, [...order]..sort(), reason: 'rows run in time order');
      expect(find.text('Markers'), findsOneWidget);
      expect(find.text('Intro'), findsOneWidget);
      expect(find.text('00:01:00 · Start here'), findsOneWidget);
      expect(find.text('Chorus'), findsOneWidget);
      expect(find.text('00:02:00'), findsOneWidget);
      expect(find.text('Marker'), findsNWidgets(2), reason: 'unnamed markers show "Marker"');
      expect(key('marker-add'), findsOneWidget);
      // The flag takes the marker's palette colour.
      final flag =
          tester.widget<Icon>(find.descendant(of: key(rowKey(named(rig, 'Intro'))), matching: find.byIcon(Icons.bookmark_rounded)));
      expect(flag.color, const Color(0xFFEF4444));
    });

    testWidgets('the selected marker is marked selected', (tester) async {
      final rig = await pumpMarkers(tester);
      addSampleMarkers(rig);
      final chorus = named(rig, 'Chorus');
      rig.editor.selectMarker(chorus.id);
      await openSheet(tester, rig);
      expect(tester.widget<DanaviewListTile>(key(rowKey(chorus))).selected, isTrue);
      expect(tester.widget<DanaviewListTile>(key(rowKey(named(rig, 'Intro')))).selected, isFalse);
    });

    testWidgets('tapping a row jumps the playhead to the marker, selects it and closes the sheet', (tester) async {
      final rig = await pumpMarkers(tester);
      addSampleMarkers(rig);
      await openSheet(tester, rig);
      final chorus = named(rig, 'Chorus');
      await tester.tap(key(rowKey(chorus)));
      await tester.pumpAndSettle();
      await rig.real(() async {});
      expect(rig.playhead.value, chorus.time);
      expect(stateOf(rig).selection.marker, chorus.id);
      expect(find.text('Markers'), findsNothing, reason: 'the sheet closed');
      expect(rig.engine.calls.where((c) => c.contains('seek')), isNotEmpty, reason: 'the preview seeked too');
    });

    testWidgets('jumping while playing pauses first', (tester) async {
      final rig = await pumpMarkers(tester);
      await rig.real(() => rig.transport.play());
      expect(rig.transport.playing.value, isTrue);
      await openSheet(tester, rig);
      await tester.tap(key(rowKey(markersOf(rig).single)));
      await tester.pumpAndSettle();
      await rig.real(() async {});
      expect(rig.transport.playing.value, isFalse);
      expect(rig.playhead.value, 4 * s);
    });

    testWidgets('a jump is not a history entry', (tester) async {
      final rig = await pumpMarkers(tester);
      final before = stateOf(rig).history.length;
      await openSheet(tester, rig);
      await tester.tap(key(rowKey(markersOf(rig).single)));
      await tester.pumpAndSettle();
      expect(stateOf(rig).history.length, before);
    });

    testWidgets('Add marker at playhead adds one, selects it and opens its editor', (tester) async {
      final rig = await pumpMarkers(tester);
      await rig.real(() => rig.playhead.seekExact(2 * s));
      await openSheet(tester, rig);
      await tapKey(tester, 'marker-add');
      expect(markersOf(rig).map((m) => m.time), [2 * s, 4 * s]);
      expect(stateOf(rig).selection.marker, markersOf(rig).first.id);
      expect(stateOf(rig).history.undoLabel, 'Add marker');
      expect(find.text('Edit marker'), findsOneWidget);
      expect(key('marker-name'), findsOneWidget);
    });

    testWidgets('Add on a frame that has a marker opens that marker without adding another', (tester) async {
      final rig = await pumpMarkers(tester);
      await rig.real(() => rig.playhead.seekExact(4 * s));
      final before = stateOf(rig).history.length;
      await openSheet(tester, rig);
      await tapKey(tester, 'marker-add');
      expect(markersOf(rig), hasLength(1));
      expect(stateOf(rig).history.length, before);
      expect(find.text('Edit marker'), findsOneWidget);
    });

    testWidgets('an empty project shows the empty state with the add button', (tester) async {
      final rig = await pumpMarkers(tester, project: false);
      await openSheet(tester, rig);
      expect(key('markers-empty'), findsOneWidget);
      expect(find.text(MarkerStrings.emptyTitle), findsOneWidget);
      await tapKey(tester, 'marker-add');
      expect(markersOf(rig).single.time, 0);
      expect(find.text('Edit marker'), findsOneWidget);
    });

    testWidgets('the list follows undo and redo while it is open', (tester) async {
      final rig = await pumpMarkers(tester);
      await openSheet(tester, rig);
      expect(find.text('Marker'), findsOneWidget);
      rig.editor.apply(const AddMarker(1 * s, name: 'Later'));
      await tester.pump();
      expect(find.text('Later'), findsOneWidget);
      rig.editor.undo();
      await tester.pump();
      expect(find.text('Later'), findsNothing);
    });
  });

  group('editor', () {
    Future<(TransportRig, Marker)> openEditor(WidgetTester tester) async {
      final rig = await pumpMarkers(tester);
      addSampleMarkers(rig);
      final m = named(rig, 'Intro');
      await openSheet(tester, rig);
      await tapKey(tester, 'marker-edit-${m.id.value}');
      return (rig, m);
    }

    testWidgets('the pencil of a row opens the editor with the marker values', (tester) async {
      final (rig, m) = await openEditor(tester);
      expect(find.text('Edit marker'), findsOneWidget);
      expect(tester.widget<EditableText>(fieldText('marker-name')).controller.text, 'Intro');
      expect(tester.widget<EditableText>(fieldText('marker-note')).controller.text, 'Start here\nSecond line');
      expect(find.text(Timecode.format(m.time, rig.playhead.frameRate)), findsOneWidget);
      for (var i = 0; i < markerPaletteSize; i++) {
        expect(key('marker-color-$i'), findsOneWidget);
      }
      final selected = [
        for (var i = 0; i < markerPaletteSize; i++)
          tester.getSemantics(key('marker-color-$i')).getSemanticsData().flagsCollection.isSelected == Tristate.isTrue
      ];
      expect(selected, [false, true, false, false, false, false]);
    });

    testWidgets('unselected swatches use the border token; only the selected swatch keeps its ring', (tester) async {
      await openEditor(tester);
      Border ring(int i) {
        final dot = find.descendant(
          of: key('marker-color-$i'),
          matching: find.byWidgetPredicate((w) => w is Container && w.decoration is BoxDecoration && (w.decoration! as BoxDecoration).shape == BoxShape.circle),
        );
        return (tester.widget<Container>(dot).decoration! as BoxDecoration).border! as Border;
      }
      for (final i in [0, 2, 3, 4, 5]) {
        expect(ring(i).top.color, DanaviewColors.border, reason: 'swatch $i');
      }
      expect(ring(1).top.color, DanaviewColors.textPrimary, reason: 'the selected swatch keeps its meaning-carrying ring');
      expect(find.descendant(of: key('marker-color-1'), matching: find.byIcon(Icons.check_rounded)), findsOneWidget);
      expectNeutralBorders(tester, skip: key('marker-color-1'));
    });

    testWidgets('name, colour and note are committed together as ONE history entry by Done', (tester) async {
      final (rig, m) = await openEditor(tester);
      final before = stateOf(rig).history.length;
      await tester.enterText(fieldText('marker-name'), '  Verse one ');
      await tester.pump();
      await tester.tap(key('marker-color-4'));
      await tester.pump();
      await tester.enterText(fieldText('marker-note'), 'Brighter\nhere');
      await tester.pump();
      expect(markersOf(rig).firstWhere((x) => x.id == m.id).name, 'Intro', reason: 'nothing is committed while typing');
      await tapKey(tester, 'marker-done');
      final u = markersOf(rig).firstWhere((x) => x.id == m.id);
      expect((u.name, u.colorIndex, u.note, u.time), ('Verse one', 4, 'Brighter\nhere', m.time));
      expect(stateOf(rig).history.length, before + 1);
      expect(stateOf(rig).history.undoLabel, 'Edit marker');
      expect(find.text('Edit marker'), findsNothing, reason: 'Done closes the sheet');
      rig.editor.undo();
      expect(markersOf(rig).firstWhere((x) => x.id == m.id), m);
    });

    testWidgets('Done without a change adds no history entry', (tester) async {
      final (rig, _) = await openEditor(tester);
      final before = stateOf(rig).history.length;
      await tapKey(tester, 'marker-done');
      expect(stateOf(rig).history.length, before);
    });

    testWidgets('clearing the note removes it; clearing the name leaves it unnamed', (tester) async {
      final (rig, m) = await openEditor(tester);
      await tester.enterText(fieldText('marker-name'), '');
      await tester.enterText(fieldText('marker-note'), '');
      await tester.pump();
      await tapKey(tester, 'marker-done');
      final u = markersOf(rig).firstWhere((x) => x.id == m.id);
      expect((u.name, u.note), ('', null));
    });

    testWidgets('All markers commits the edit and shows the list with the new name', (tester) async {
      final (rig, m) = await openEditor(tester);
      await tester.enterText(fieldText('marker-name'), 'Renamed');
      await tester.pump();
      await tapKey(tester, 'marker-back');
      expect(find.text('Markers'), findsOneWidget);
      expect(find.text('Renamed'), findsOneWidget);
      expect(markersOf(rig).firstWhere((x) => x.id == m.id).name, 'Renamed');
    });

    testWidgets('dismissing the sheet commits the edit', (tester) async {
      final (rig, m) = await openEditor(tester);
      await tester.tap(key('marker-color-5'));
      await tester.pump();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('Edit marker'), findsNothing);
      expect(markersOf(rig).firstWhere((x) => x.id == m.id).colorIndex, 5);
    });

    testWidgets('Delete removes the marker as one entry and returns to the list', (tester) async {
      final (rig, m) = await openEditor(tester);
      final before = stateOf(rig).history.length;
      await tester.enterText(fieldText('marker-name'), 'Lost change');
      await tapKey(tester, 'marker-delete');
      expect(markersOf(rig).any((x) => x.id == m.id), isFalse);
      expect(stateOf(rig).history.length, before + 1, reason: 'the staged rename is discarded, not committed');
      expect(stateOf(rig).history.undoLabel, 'Delete marker');
      expect(find.text('Markers'), findsOneWidget);
      expect(find.text('Intro'), findsNothing);
      rig.editor.undo();
      expect(markersOf(rig).firstWhere((x) => x.id == m.id), m);
      await tester.pump(const Duration(seconds: 2)); // the announcement's throttle window
    });

    testWidgets('Go to marker jumps and closes', (tester) async {
      final (rig, m) = await openEditor(tester);
      await tester.tap(key('marker-go-to'));
      await tester.pumpAndSettle();
      await rig.real(() async {});
      expect(rig.playhead.value, m.time);
      expect(stateOf(rig).selection.marker, m.id);
      expect(find.text('Edit marker'), findsNothing);
    });

    testWidgets('starting with a marker opens its editor directly', (tester) async {
      final rig = await pumpMarkers(tester);
      await openSheet(tester, rig, marker: markersOf(rig).single.id);
      expect(find.text('Edit marker'), findsOneWidget);
      await tapKey(tester, 'marker-back');
      expect(find.text('Markers'), findsOneWidget);
    });

    testWidgets('a marker removed while its editor is open sends the sheet back to the list', (tester) async {
      final rig = await pumpMarkers(tester);
      await openSheet(tester, rig, marker: markersOf(rig).single.id);
      rig.editor.apply(DeleteMarker(markersOf(rig).single.id));
      await tester.pump();
      expect(find.text('Edit marker'), findsNothing);
      expect(key('markers-empty'), findsOneWidget);
    });

    testWidgets('the name and the note stop at their limits', (tester) async {
      final (_, _) = await openEditor(tester);
      await tester.enterText(fieldText('marker-name'), 'n' * (maxMarkerNameLength + 20));
      await tester.enterText(fieldText('marker-note'), 'x' * (maxMarkerNoteLength + 20));
      await tester.pump();
      expect(tester.widget<EditableText>(fieldText('marker-name')).controller.text.length, maxMarkerNameLength);
      expect(tester.widget<EditableText>(fieldText('marker-note')).controller.text.length, maxMarkerNoteLength);
      expect(find.text('0 characters left'), findsOneWidget);
    });
  });

  group('semantics', () {
    testWidgets('rows are buttons that name the marker and its time; the edit buttons are labelled; colours are named', (tester) async {
      final handle = tester.ensureSemantics();
      final rig = await pumpMarkers(tester);
      addSampleMarkers(rig);
      await openSheet(tester, rig);
      final intro = named(rig, 'Intro');
      final row = tester.getSemantics(key(rowKey(intro)));
      expect(row.label, contains('Jump to Intro at 00:01:00'));
      expect(row.getSemanticsData().flagsCollection.isButton, isTrue);
      expect(find.bySemanticsLabel('Edit marker Intro'), findsOneWidget);
      await tapKey(tester, 'marker-edit-${intro.id.value}');
      for (var i = 0; i < markerPaletteSize; i++) {
        expect(find.bySemanticsLabel('${MarkerStrings.colorNames[i]} marker color'), findsOneWidget);
      }
      expect(find.bySemanticsLabel('Name'), findsWidgets);
      expect(find.bySemanticsLabel('Note'), findsWidgets);
      handle.dispose();
    });
  });

  group('no overflow', () {
    final surfaces = SurfaceMatrix.pr;
    final longName = 'A very long marker name that keeps going ${'x' * 15}';
    final longNote = 'A long note that runs on and on about what happens at this moment of the video. ${'word ' * 30}';

    void addLong(TransportRig rig) {
      addMarkers(rig, [
        for (var i = 0; i < 12; i++) ((i + 1) * s, i.isEven ? longName : '', i % markerPaletteSize, i % 3 == 0 ? longNote : null),
      ]);
    }

    for (final surface in surfaces) {
      testWidgets('list with long names and notes on $surface', (tester) async {
        final rig = await pumpMarkers(tester, surface: surface);
        addLong(rig);
        await openSheet(tester, rig);
        expectNoOverflow(tester);
        expectOwnerUiRules(tester);
        await tester.ensureVisible(key('marker-add'));
        await tester.pump();
        expectNoOverflow(tester);
        expectInside(tester, key('marker-add'), screen: surface.size);
        // Rows stay at least 44 px tall: touch targets.
        expect(tester.getSize(key(rowKey(markersOf(rig).first))).height, greaterThanOrEqualTo(44));
      });

      testWidgets('editor with a long name and note on $surface', (tester) async {
        final rig = await pumpMarkers(tester, surface: surface);
        addLong(rig);
        final m = markersOf(rig).first;
        await openSheet(tester, rig, marker: m.id);
        expectNoOverflow(tester);
        expectOwnerUiRules(tester);
        await tester.enterText(fieldText('marker-note'), longNote * 3);
        await tester.pump();
        expectNoOverflow(tester);
        for (final k in ['marker-done', 'marker-delete']) {
          await tester.ensureVisible(key(k));
          await tester.pump();
          expectInside(tester, key(k), screen: surface.size);
        }
        for (var i = 0; i < markerPaletteSize; i++) {
          await tester.ensureVisible(key('marker-color-$i'));
          expect(tester.getSize(key('marker-color-$i')).shortestSide, greaterThanOrEqualTo(44));
        }
        expectNoOverflow(tester);
      });

      testWidgets('empty list on $surface', (tester) async {
        final rig = await pumpMarkers(tester, surface: surface, project: false);
        await openSheet(tester, rig);
        expectNoOverflow(tester);
        expectOwnerUiRules(tester);
        await tester.ensureVisible(key('marker-add'));
        await tester.pump();
        expectInside(tester, key('marker-add'), screen: surface.size);
      });
    }
  });
}
