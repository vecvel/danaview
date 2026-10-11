// OWNER: UX-17
//
// Test support for the marker sheet and the marker actions: the transport rig (a real
// EditorController over FakeEditorEngine, the playhead and the transport) with a host widget that
// opens the sheet, a few markers with names, colours and notes, and the registry with every
// binding merged.

import 'dart:async';

import 'package:flutter/material.dart' show Material;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/app/editor_providers.dart';
import 'package:vwish_editor/src/editor/actions/editor_action_registry.dart';
import 'package:vwish_editor/src/editor/actions/editor_shortcuts.dart';
import 'package:vwish_editor/src/editor/contracts/contracts.dart';
import 'package:vwish_editor/src/editor/state/edit_transaction.dart' show EditApplied;
import 'package:vwish_editor/src/editor/timeline/marker_sheet.dart';
import 'package:vwish_editor/src/editor/state/editor_state.dart';
import 'package:vwish_editor/src/editor/wiring/action_bindings.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart';

import '../../support/support.dart';
import '../../transport/transport_rig.dart';

export '../../transport/transport_rig.dart' show TransportRig, s;

/// The key of the host box the sheet is opened from.
const Key hostKey = ValueKey('marker-host');

/// Pumps the host in the transport rig (a project with text items and one marker at 4 s).
///
/// With [shortcuts] the host sits in the editor's shortcut scope (keys reach the real actions);
/// [extra] is shown above the host.
Future<TransportRig> pumpMarkers(
  WidgetTester tester, {
  EditorSurface surface = SurfaceMatrix.phone,
  bool project = true,
  bool open = true,
  bool shortcuts = false,
  Widget? extra,
}) =>
    TransportRig.pump(
      tester,
      (id) {
        Widget host = Material(
          child: Column(children: [if (extra != null) extra, const Expanded(child: SizedBox.expand(key: hostKey))]),
        );
        if (shortcuts) host = EditorShortcuts(child: host);
        return host;
      },
      surface: surface,
      project: project,
      open: open,
    );

/// Opens the marker sheet (the list, or the editor of [marker]) from the host.
Future<void> openSheet(WidgetTester tester, TransportRig rig, {MarkerId? marker}) async {
  unawaited(MarkerSheet.show(tester.element(find.byKey(hostKey)), projectId: rig.id, marker: marker));
  await tester.pumpAndSettle();
}

/// The editor state.
EditorState stateOf(TransportRig rig) => rig.container.read(editorControllerProvider(rig.id));

/// The project's markers.
List<Marker> markersOf(TransportRig rig) => stateOf(rig).project!.markers;

/// The marker with [name].
Marker named(TransportRig rig, String name) => markersOf(rig).firstWhere((m) => m.name == name);

/// Adds the markers of [specs] (time, name, colour, note) as history entries.
void addMarkers(TransportRig rig, List<(TimeUs, String, int, String?)> specs) {
  for (final (t, name, color, note) in specs) {
    final r = rig.editor.apply(AddMarker(t, name: name, colorIndex: color, note: note));
    if (r is! EditApplied) throw StateError('AddMarker($t) -> $r');
  }
}

/// Three markers besides the sample's one at 4 s: "Intro" (1 s, colour 1, with a two-line note),
/// "Chorus" (2 s, colour 2) and one unnamed (6 s).
void addSampleMarkers(TransportRig rig) => addMarkers(rig, [
      (1 * s, 'Intro', 1, 'Start here\nSecond line'),
      (2 * s, 'Chorus', 2, null),
      (6 * s, '', 0, null),
    ]);

/// The registry with every binding merged and a keyboard context for [rig].
({EditorActionRegistry registry, WidgetActionContext ctx}) actions(WidgetTester tester, TransportRig rig) {
  final registry = EditorActionRegistry(bindings: mergeEditorActionBindings());
  final ctx = WidgetActionContext.container(
    projectId: rig.id,
    context: tester.element(find.byKey(hostKey)),
    container: rig.container,
    source: EditorActionSource.keyboard,
  );
  return (registry: registry, ctx: ctx);
}

/// Finds a row or control by its key string.
Finder key(String k) => find.byKey(ValueKey(k));

/// The editable text inside the field with key [k].
Finder fieldText(String k) => find.descendant(of: key(k), matching: find.byType(EditableText));
