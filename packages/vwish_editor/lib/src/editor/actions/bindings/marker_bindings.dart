// OWNER: UX-17
//
// The marker action bindings (merged by wiring/action_bindings.dart, ARCH §17.6, ux.md §8.5):
// addMarker, editMarker and deleteMarker. Labels, icons and shortcuts (M) come from the registry
// (UX-15); copy from `MarkerStrings` (timeline/marker_sheet.dart).
//
// * Add marker: at the playhead's frame, selects the new marker, light haptic and an
//   announcement. A marker already on that frame is selected instead, with a toast (never two on
//   one frame). One history entry "Add marker".
// * Edit marker: opens the marker sheet. With a marker selected it opens that marker's editor,
//   otherwise the list. Enabled while the project has a marker.
// * Delete marker: removes the selected marker (one history entry "Delete marker").
// * Markers are edit points for Up/Down (UX-14) and snap targets for drags (UX-13); neither needs
//   a binding.

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter/widgets.dart';
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import '../../contracts/contracts.dart';
import '../../timeline/marker_sheet.dart';
import '../../timeline/timeline_semantics.dart' show editorAnnounce;

MarkerOperations _ops(EditorActionContext ctx) => MarkerOperations.of(ctx);

void _say(EditorActionContext ctx, String message, {bool toast = false, IconData? icon}) {
  final context = ctx.context;
  if (!context.mounted) return;
  if (toast) VwishToast.show(context, message, icon: icon);
  editorAnnounce(context, message);
}

bool _canAdd(EditorActionContext ctx) => _ops(ctx).canEdit;

String? _notEditable(EditorActionContext ctx) => MarkerStrings.notEditable;

void _add(EditorActionContext ctx) {
  final ops = _ops(ctx);
  switch (ops.add()) {
    case MarkerAdded(:final marker):
      HapticFeedback.lightImpact();
      _say(ctx, MarkerStrings.added(marker.time, ops.project!.settings.frameRate));
    case MarkerExists():
      HapticFeedback.selectionClick();
      _say(ctx, MarkerStrings.alreadyHere, toast: true, icon: Icons.bookmark_rounded);
    case MarkerNotAdded():
      break;
  }
}

bool _canEdit(EditorActionContext ctx) {
  final ops = _ops(ctx);
  return ops.canEdit && ops.markers.isNotEmpty;
}

String? _editReason(EditorActionContext ctx) => _ops(ctx).canEdit ? MarkerStrings.noMarkers : MarkerStrings.notEditable;

Future<void> _edit(EditorActionContext ctx) async {
  final ops = _ops(ctx);
  final context = ctx.context;
  if (ops.markers.isEmpty || !context.mounted) return;
  await MarkerSheet.show(context, projectId: ctx.projectId, marker: ops.selected?.id);
}

bool _canDelete(EditorActionContext ctx) {
  final ops = _ops(ctx);
  return ops.canEdit && ops.selected != null;
}

String? _deleteReason(EditorActionContext ctx) => _ops(ctx).canEdit ? MarkerStrings.selectFirst : MarkerStrings.notEditable;

void _delete(EditorActionContext ctx) {
  final ops = _ops(ctx);
  final marker = ops.selected;
  if (marker == null) return;
  if (ops.delete(marker.id) != null) _say(ctx, MarkerStrings.deleted);
}

/// The marker actions bound by UX-17 (ARCH §17.6). The same instances on every read, so two merges
/// of the bindings compare equal (the wiring test relies on it).
List<EditorActionBinding> get markerBindings => _markerBindings;

final List<EditorActionBinding> _markerBindings = List.unmodifiable(<EditorActionBinding>[
  const EditorActionBinding(id: EditorActionId.addMarker, handler: _add, isEnabled: _canAdd, disabledReason: _notEditable),
  const EditorActionBinding(id: EditorActionId.editMarker, handler: _edit, isEnabled: _canEdit, disabledReason: _editReason),
  const EditorActionBinding(id: EditorActionId.deleteMarker, handler: _delete, isEnabled: _canDelete, disabledReason: _deleteReason),
]);
