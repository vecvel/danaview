// OWNER: UX-17
//
// The pure parts of the marker sheet (MarkerDraft, MarkerListModel, MarkerStrings) and the marker
// operations over a real EditorController: add at the playhead (frame grid, selection, one history
// entry, never two markers on a frame), update (one entry) and delete.

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/state/edit_transaction.dart' show EditApplied;
import 'package:danaview_editor/src/editor/timeline/marker_sheet.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';

import 'marker_support.dart';

const FrameRate rate = FrameRate.fps30;

Marker marker({String name = '', int color = 0, String? note, TimeUs time = 0}) =>
    Marker(id: const MarkerId('mk_000000000001'), time: time, name: name, colorIndex: color, note: note);

void main() {
  group('MarkerDraft', () {
    test('a draft of the marker itself changes nothing', () {
      final m = marker(name: 'Intro', color: 2, note: 'Hello');
      expect(MarkerDraft.of(m).commandFor(m), isNull);
      expect(MarkerDraft.of(marker()).commandFor(marker()), isNull);
    });

    test('a name with only surrounding spaces is the same name', () {
      final m = marker(name: 'Intro');
      expect(const MarkerDraft(name: '  Intro ', colorIndex: 0, note: '').commandFor(m), isNull);
    });

    test('each field becomes one UpdateMarker and the others are kept', () {
      final project = projectWith(marker(name: 'Intro', color: 2, note: 'Hello'));
      MarkerDraft draft(MarkerDraft Function(MarkerDraft d) f) => f(MarkerDraft.of(project.markers.single));
      Marker apply(MarkerDraft d) {
        final session = EditSession(project, ids: SeededIdGenerator(1));
        final out = session.apply(d.commandFor(project.markers.single)!);
        expect(out.changed, isTrue);
        return session.committedProject.markers.single;
      }

      final renamed = apply(draft((d) => d.copyWith(name: ' Verse ')));
      expect((renamed.name, renamed.colorIndex, renamed.note), ('Verse', 2, 'Hello'));
      final recolored = apply(draft((d) => d.copyWith(colorIndex: 5)));
      expect((recolored.name, recolored.colorIndex, recolored.note), ('Intro', 5, 'Hello'));
      final renoted = apply(draft((d) => d.copyWith(note: 'Other')));
      expect((renoted.name, renoted.colorIndex, renoted.note), ('Intro', 2, 'Other'));
      final cleared = apply(draft((d) => d.copyWith(note: '  \n ')));
      expect(cleared.note, isNull, reason: 'a blank note clears it');
      final all = apply(draft((d) => d.copyWith(name: 'A', colorIndex: 0, note: 'B')));
      expect((all.name, all.colorIndex, all.note), ('A', 0, 'B'));
    });

    test('equality is by value', () {
      expect(const MarkerDraft(name: 'a', colorIndex: 1, note: 'n'), const MarkerDraft(name: 'a', colorIndex: 1, note: 'n'));
      expect(const MarkerDraft(name: 'a', colorIndex: 1, note: 'n'), isNot(const MarkerDraft(name: 'a', colorIndex: 2, note: 'n')));
    });
  });

  group('MarkerListModel', () {
    test('rows keep the marker order, with the display name, the timecode and the first line of the note', () {
      final markers = [
        marker(name: 'Intro', time: 1 * s, note: '\n  First\nSecond'),
        Marker(id: const MarkerId('mk_000000000002'), time: FrameRate.fps30.timeOfFrame(65)),
        const Marker(id: MarkerId('mk_000000000003'), time: 3 * s, note: ' \n '),
      ];
      final model = MarkerListModel.of(markers, rate, selected: const MarkerId('mk_000000000002'));
      expect(model.isEmpty, isFalse);
      expect([for (final r in model.rows) r.title], ['Intro', 'Marker', 'Marker']);
      expect(model.rows[0].time, '00:01:00');
      expect(model.rows[0].note, 'First');
      expect(model.rows[0].subtitle, '00:01:00 · First');
      expect(model.rows[1].time, '00:02:05');
      expect(model.rows[1].subtitle, '00:02:05');
      expect(model.rows[2].note, isNull);
      expect([for (final r in model.rows) r.selected], [false, true, false]);
    });

    test('no markers is empty', () => expect(MarkerListModel.of(const [], rate).isEmpty, isTrue));
  });

  group('MarkerStrings', () {
    test('there is a name for every palette colour, and the default name for a newer index', () {
      expect(MarkerStrings.colorNames, hasLength(markerPaletteSize));
      expect(MarkerStrings.colorNames.toSet(), hasLength(markerPaletteSize),
          reason: 'colour never carries meaning alone, so the names differ');
      expect(MarkerStrings.colorName(99), MarkerStrings.colorNames.first);
      expect(MarkerStrings.colorName(-1), MarkerStrings.colorNames.first);
    });

    test('labels name the marker and its time', () {
      expect(MarkerStrings.rowLabel(marker(name: 'Intro', time: 1 * s), rate), 'Jump to Intro at 00:01:00');
      expect(MarkerStrings.rowLabel(marker(time: 1 * s), rate), 'Jump to Marker at 00:01:00');
      expect(MarkerStrings.added(4 * s, rate), 'Marker added at 00:04:00');
      expect(MarkerStrings.noteLeft(500), isNull);
      expect(MarkerStrings.noteLeft(3), '3 characters left');
    });
  });

  group('MarkerOperations', () {
    MarkerOperations opsOf(WidgetTester tester, TransportRig rig) => MarkerOperations(
          controller: rig.editor,
          state: () => stateOf(rig),
          playhead: () => rig.playhead.value,
        );

    testWidgets('add puts a marker at the playhead frame, selects it and is one history entry', (tester) async {
      final rig = await pumpMarkers(tester);
      final ops = opsOf(tester, rig);
      await rig.real(() => rig.playhead.seekExact(rate.timeOfFrame(33)));
      final before = stateOf(rig).history.length;
      final outcome = ops.add();
      expect(outcome, isA<MarkerAdded>());
      final added = (outcome as MarkerAdded).marker;
      expect(added.time, rate.timeOfFrame(33), reason: 'the playhead frame, on the grid');
      expect(markersOf(rig).map((m) => m.time), [added.time, 4 * s]);
      expect(stateOf(rig).selection.marker, added.id);
      expect(stateOf(rig).history.length, before + 1);
      expect(stateOf(rig).history.undoLabel, 'Add marker');
      rig.editor.undo();
      expect(markersOf(rig).map((m) => m.time), [4 * s]);
    });

    testWidgets('add at a given time quantizes it and clamps below zero', (tester) async {
      final rig = await pumpMarkers(tester);
      final ops = opsOf(tester, rig);
      expect((ops.add(at: 2 * s + 10000) as MarkerAdded).marker.time, 2 * s);
      expect((ops.add(at: -5 * s) as MarkerAdded).marker.time, 0);
    });

    testWidgets('add on a frame that has a marker selects it and changes nothing', (tester) async {
      final rig = await pumpMarkers(tester);
      final ops = opsOf(tester, rig);
      final existing = markersOf(rig).single;
      rig.editor.clearSelection();
      final before = stateOf(rig).history.length;
      final outcome = ops.add(at: 4 * s);
      expect(outcome, isA<MarkerExists>());
      expect((outcome as MarkerExists).marker, existing);
      expect(markersOf(rig), hasLength(1));
      expect(stateOf(rig).history.length, before);
      expect(stateOf(rig).selection.marker, existing.id);
    });

    testWidgets('add on a project that is not open does nothing', (tester) async {
      final rig = await pumpMarkers(tester, open: false);
      expect(opsOf(tester, rig).add(), isA<MarkerNotAdded>());
      expect(opsOf(tester, rig).canEdit, isFalse);
      expect(opsOf(tester, rig).markers, isEmpty);
    });

    testWidgets('update applies a draft as one entry and a no-change draft is no entry', (tester) async {
      final rig = await pumpMarkers(tester);
      final ops = opsOf(tester, rig);
      final m = markersOf(rig).single;
      final before = stateOf(rig).history.length;
      expect(ops.update(m.id, MarkerDraft.of(m)), isNull);
      expect(stateOf(rig).history.length, before);
      expect(ops.update(m.id, MarkerDraft.of(m).copyWith(name: 'Drop', colorIndex: 3, note: 'Big')), isA<EditApplied>());
      final updated = markersOf(rig).single;
      expect((updated.name, updated.colorIndex, updated.note), ('Drop', 3, 'Big'));
      expect(stateOf(rig).history.length, before + 1);
      expect(stateOf(rig).history.undoLabel, 'Edit marker');
    });

    testWidgets('delete removes the marker as one entry; an unknown marker is nothing', (tester) async {
      final rig = await pumpMarkers(tester);
      final ops = opsOf(tester, rig);
      final m = markersOf(rig).single;
      expect(ops.delete(const MarkerId('mk_000000000999')), isNull);
      expect(ops.delete(m.id), isA<EditApplied>());
      expect(markersOf(rig), isEmpty);
      expect(stateOf(rig).history.undoLabel, 'Delete marker');
    });

    testWidgets('selected is the selected marker only while it exists', (tester) async {
      final rig = await pumpMarkers(tester);
      final ops = opsOf(tester, rig);
      expect(ops.selected, isNull);
      final m = markersOf(rig).single;
      rig.editor.selectMarker(m.id);
      expect(ops.selected, m);
      ops.delete(m.id);
      expect(ops.selected, isNull);
    });
  });
}

EditProject projectWith(Marker m) => EditProject(
      id: const ProjectId('pr_000000000001'),
      meta: ProjectMeta(name: 'Markers', createdAt: DateTime.utc(2026, 10, 1), updatedAt: DateTime.utc(2026, 10, 1)),
      timeline: Timeline(markers: [m]),
    );
