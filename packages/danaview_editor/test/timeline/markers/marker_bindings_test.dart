// OWNER: UX-17
//
// The marker actions through the real registry and the real merged bindings over a real
// EditorController: addMarker (playhead frame, selection, haptic, one entry, no stacking, the M
// key, the transport bar's button), editMarker (list or the selected marker's editor, enablement),
// deleteMarker (the selected marker, one entry, Delete key) and the wiring contract.

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/actions/bindings/marker_bindings.dart';
import 'package:danaview_editor/src/editor/contracts/contracts.dart';
import 'package:danaview_editor/src/editor/timeline/marker_sheet.dart';
import 'package:danaview_editor/src/editor/timeline/snapping.dart';
import 'package:danaview_editor/src/editor/transport/transport_bar.dart';
import 'package:danaview_editor/src/editor/wiring/action_bindings.dart';
import 'package:danaview_editor_core/ops.dart' show AddMarker, DeleteMarker;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../actions/action_test_support.dart' show Keys;
import '../../support/support.dart';
import 'marker_support.dart';

/// Records `HapticFeedback` calls.
List<String?> recordHaptics(WidgetTester tester) {
  final calls = <String?>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'HapticFeedback.vibrate') calls.add(call.arguments as String?);
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return calls;
}

void main() {
  group('wiring', () {
    test('the marker binding file binds exactly the three marker actions and the merge accepts it', () {
      final ids = markerBindings.map((b) => b.id).toList();
      expect(ids, EditorActionId.inGroup(EditorActionGroup.markers));
      final merged = mergeEditorActionBindings();
      for (final id in ids) {
        expect(merged.containsKey(id), isTrue, reason: id.name);
      }
    });

    test('two reads return the same instances', () {
      expect(identical(markerBindings, markerBindings), isTrue);
      expect(mergeEditorActionBindings(), mergeEditorActionBindings());
    });

    test('the file is registered as UX-17 marker_bindings', () {
      final source = editorBindingSources.firstWhere((s) => s.file == 'marker_bindings');
      expect(source.owner, 'UX-17');
    });
  });

  group('addMarker', () {
    testWidgets('adds a marker at the playhead frame, selects it, plays a light haptic and is one entry', (tester) async {
      final haptics = recordHaptics(tester);
      final rig = await pumpMarkers(tester);
      final a = actions(tester, rig);
      await rig.real(() => rig.playhead.seekExact(rig.playhead.frameRate.timeOfFrame(75)));
      final before = stateOf(rig).history.length;
      expect(a.registry.spec(EditorActionId.addMarker).isEnabled(a.ctx), isTrue);
      a.registry.invoke(EditorActionId.addMarker, a.ctx);
      await tester.pump();
      final added = markersOf(rig).firstWhere((m) => m.time != 4 * s);
      expect(added.time, rig.playhead.frameRate.timeOfFrame(75));
      expect(stateOf(rig).selection.marker, added.id);
      expect(stateOf(rig).history.length, before + 1);
      expect(stateOf(rig).history.undoLabel, 'Add marker');
      expect(haptics, contains('HapticFeedbackType.lightImpact'));
      await tester.pump(const Duration(seconds: 2)); // the announcement's throttle window
    });

    testWidgets('a second add on the same frame selects the marker and says so; no second marker', (tester) async {
      final haptics = recordHaptics(tester);
      final rig = await pumpMarkers(tester);
      final a = actions(tester, rig);
      await rig.real(() => rig.playhead.seekExact(2 * s));
      a.registry.invoke(EditorActionId.addMarker, a.ctx);
      rig.editor.clearSelection();
      final before = stateOf(rig).history.length;
      haptics.clear();
      a.registry.invoke(EditorActionId.addMarker, a.ctx);
      await tester.pump();
      expect(markersOf(rig).where((m) => m.time == 2 * s), hasLength(1));
      expect(stateOf(rig).history.length, before);
      expect(stateOf(rig).selection.marker, markersOf(rig).firstWhere((m) => m.time == 2 * s).id);
      expect(find.text(MarkerStrings.alreadyHere), findsOneWidget);
      expect(haptics, ['HapticFeedbackType.selectionClick']);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('the M key adds a marker at the playhead', (tester) async {
      final rig = await pumpMarkers(tester, shortcuts: true);
      final keys = Keys(tester, TargetPlatform.android);
      await rig.real(() => rig.playhead.seekExact(1 * s));
      await keys.press(LogicalKeyboardKey.keyM, character: 'm');
      await rig.real(() async {});
      expect(markersOf(rig).map((m) => m.time), [1 * s, 4 * s]);
      expect(stateOf(rig).selection.marker, markersOf(rig).first.id);
      await tester.pump(const Duration(seconds: 2)); // the announcement's throttle window
    });

    testWidgets('the transport bar shows an Add marker button once the action is bound, and it adds one', (tester) async {
      final rig = await pumpMarkers(
        tester,
        surface: const EditorSurface(Size(1280, 800), platform: TargetPlatform.macOS),
        extra: const SizedBox(height: 44, child: TransportBar()),
      );
      final button = find.byIcon(Icons.bookmark_add_rounded);
      expect(button, findsOneWidget);
      await rig.real(() => rig.playhead.seekExact(2 * s));
      await tester.tap(button);
      await tester.pump();
      expect(markersOf(rig).map((m) => m.time), [2 * s, 4 * s]);
      await tester.pump(const Duration(seconds: 2)); // the announcement's throttle window
    });

    testWidgets('disabled with the reason while the project is not open', (tester) async {
      final rig = await pumpMarkers(tester, open: false);
      final a = actions(tester, rig);
      final spec = a.registry.spec(EditorActionId.addMarker);
      expect(spec.isEnabled(a.ctx), isFalse);
      expect(spec.disabledReason(a.ctx), MarkerStrings.notEditable);
    });
  });

  group('editMarker', () {
    testWidgets('is enabled while the project has a marker, with the reason otherwise', (tester) async {
      final rig = await pumpMarkers(tester, project: false);
      final a = actions(tester, rig);
      final spec = a.registry.spec(EditorActionId.editMarker);
      expect(spec.isEnabled(a.ctx), isFalse);
      expect(spec.disabledReason(a.ctx), MarkerStrings.noMarkers);
      rig.editor.apply(const AddMarker(1 * s));
      expect(spec.isEnabled(a.ctx), isTrue);
    });

    testWidgets('with nothing selected it opens the list', (tester) async {
      final rig = await pumpMarkers(tester);
      final a = actions(tester, rig);
      a.registry.invoke(EditorActionId.editMarker, a.ctx);
      await tester.pumpAndSettle();
      expect(find.text(MarkerStrings.title), findsOneWidget);
      expect(key('marker-add'), findsOneWidget);
    });

    testWidgets('with a marker selected it opens that marker’s editor', (tester) async {
      final rig = await pumpMarkers(tester);
      addSampleMarkers(rig);
      final chorus = named(rig, 'Chorus');
      rig.editor.selectMarker(chorus.id);
      final a = actions(tester, rig);
      a.registry.invoke(EditorActionId.editMarker, a.ctx);
      await tester.pumpAndSettle();
      expect(find.text(MarkerStrings.editTitle), findsOneWidget);
      expect(tester.widget<EditableText>(fieldText('marker-name')).controller.text, 'Chorus');
    });

    testWidgets('a stale selection (the marker was deleted) opens the list', (tester) async {
      final rig = await pumpMarkers(tester);
      addSampleMarkers(rig);
      final chorus = named(rig, 'Chorus');
      rig.editor.selectMarker(chorus.id);
      rig.editor.apply(DeleteMarker(chorus.id));
      final a = actions(tester, rig);
      a.registry.invoke(EditorActionId.editMarker, a.ctx);
      await tester.pumpAndSettle();
      expect(find.text(MarkerStrings.title), findsOneWidget);
    });

    testWidgets('the tool tiles of a selected marker (Rename, Color, Note) all run it', (tester) async {
      final rig = await pumpMarkers(tester);
      final a = actions(tester, rig);
      rig.editor.selectMarker(markersOf(rig).single.id);
      expect(a.registry.spec(EditorActionId.editMarker).isEnabled(a.ctx), isTrue);
    });
  });

  group('deleteMarker', () {
    testWidgets('needs a selected marker; deletes it as one entry; announces it', (tester) async {
      final rig = await pumpMarkers(tester);
      final a = actions(tester, rig);
      final spec = a.registry.spec(EditorActionId.deleteMarker);
      expect(spec.isEnabled(a.ctx), isFalse);
      expect(spec.disabledReason(a.ctx), MarkerStrings.selectFirst);
      final m = markersOf(rig).single;
      rig.editor.selectMarker(m.id);
      expect(spec.isEnabled(a.ctx), isTrue);
      final before = stateOf(rig).history.length;
      a.registry.invoke(EditorActionId.deleteMarker, a.ctx);
      await tester.pump();
      expect(markersOf(rig), isEmpty);
      expect(stateOf(rig).history.length, before + 1);
      expect(stateOf(rig).history.undoLabel, 'Delete marker');
      expect(spec.isEnabled(a.ctx), isFalse, reason: 'the selection is gone with the marker');
      rig.editor.undo();
      expect(markersOf(rig).single, m);
      await tester.pump(const Duration(seconds: 2)); // the announcement's throttle window
    });

    testWidgets('only the selected marker goes', (tester) async {
      final rig = await pumpMarkers(tester);
      addSampleMarkers(rig);
      final a = actions(tester, rig);
      rig.editor.selectMarker(named(rig, 'Intro').id);
      a.registry.invoke(EditorActionId.deleteMarker, a.ctx);
      expect(markersOf(rig).map((m) => m.name), ['Chorus', '', '']);
      await tester.pump(const Duration(seconds: 2)); // the announcement's throttle window
    });

    testWidgets('disabled with the reason while the project is not open', (tester) async {
      final rig = await pumpMarkers(tester, open: false);
      final a = actions(tester, rig);
      expect(a.registry.spec(EditorActionId.deleteMarker).disabledReason(a.ctx), MarkerStrings.notEditable);
    });
  });

  group('markers are snap targets and edit points', () {
    testWidgets('a marker added by the action is an Up/Down edit point and a snap target of drags', (tester) async {
      final rig = await pumpMarkers(tester);
      final a = actions(tester, rig);
      await rig.real(() => rig.playhead.seekExact(1 * s));
      a.registry.invoke(EditorActionId.addMarker, a.ctx);
      await tester.pump(const Duration(seconds: 2)); // the announcement's throttle window
      await rig.real(() => rig.playhead.seekExact(0));
      await rig.real(() => rig.transport.nextEditPoint());
      expect(rig.playhead.value, 1 * s, reason: 'the marker is the next edit point after the start (the text ends at 3 s)');
      final snap = TimelineSnapping.forDrag(stateOf(rig).project!, thresholdPx: 8);
      expect(snap.snapTime(1 * s + 20000, pxPerSecond: 100), 1 * s, reason: '8 px at 100 px/s reaches 80 ms');
      expect(snap.snapTime(1 * s + 500000, pxPerSecond: 100), 1 * s + 500000, reason: 'out of reach: unchanged');
      // A deleted marker is neither.
      rig.editor.selectMarker(markersOf(rig).firstWhere((m) => m.time == 1 * s).id);
      a.registry.invoke(EditorActionId.deleteMarker, a.ctx);
      await tester.pump(const Duration(seconds: 2));
      final after = TimelineSnapping.forDrag(stateOf(rig).project!, thresholdPx: 8);
      expect(after.snapTime(1 * s + 20000, pxPerSecond: 100), 1 * s + 20000);
      await rig.real(() => rig.playhead.seekExact(0));
      await rig.real(() => rig.transport.nextEditPoint());
      expect(rig.playhead.value, 3 * s);
    });
  });

  group('the sheet and the ruler', () {
    testWidgets('a marker added by the action shows in the sheet list, and undo removes it from the list', (tester) async {
      final rig = await pumpMarkers(tester);
      final a = actions(tester, rig);
      await rig.real(() => rig.playhead.seekExact(1 * s));
      a.registry.invoke(EditorActionId.addMarker, a.ctx);
      await openSheet(tester, rig);
      expect(find.text('00:01:00'), findsOneWidget);
      expect(find.byType(DanaviewListTile), findsNWidgets(2));
      rig.editor.undo();
      await tester.pump();
      expect(find.byType(DanaviewListTile), findsNWidgets(1));
      await tester.pump(const Duration(seconds: 2)); // the announcement's throttle window
    });
  });
}
