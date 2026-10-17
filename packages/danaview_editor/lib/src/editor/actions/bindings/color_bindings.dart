// OWNER: UX-24
//
// The colour action bindings (merged by wiring/action_bindings.dart, ARCH §17.6): `adjust` and
// `filters` open the Adjust and Filters & LUT panels (ux.md §9.1, §9.2, §10.6, §10.7). Labels, icons
// and shortcuts come from the registry (UX-15); copy from `ColorStrings`.
//
// * With a picture clip selected (or a multi-selection whose primary item is one) the panel opens on
//   it.
// * Otherwise (the Effects and Filters top-level tools with nothing selected) the panel auto-targets
//   the main-lane clip under the playhead (the nearest one when the playhead sits in a gap), selects
//   it and says "Editing clip at playhead" (ux.md §9.1).
// * Disabled while the project is opening, when the project has no picture clip to target, and when
//   the target's track is locked; each says why.
// * The top-level tool sets itself (`EditorController.setTool`) before invoking the action; the
//   binding only opens the inspector route.

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../../app/editor_providers.dart';
import '../../../app/strings/color_strings.dart';
import '../../contracts/contracts.dart';
import '../../state/editor_controller.dart';
import '../../state/editor_state.dart';
import '../../toolbar/tool_sets.dart';

/// The clip a colour panel opens on and whether it was picked for the user.
@immutable
final class ColorTarget {
  /// Creates the target.
  const ColorTarget(this.item, {required this.autoTargeted, required this.locked});

  /// The clip.
  final ItemId item;

  /// True when the clip was chosen at the playhead (the selection did not name one).
  final bool autoTargeted;

  /// Whether the clip's track is locked.
  final bool locked;

  @override
  bool operator ==(Object other) => other is ColorTarget && other.item == item && other.autoTargeted == autoTargeted && other.locked == locked;

  @override
  int get hashCode => Object.hash(item, autoTargeted, locked);

  @override
  String toString() => 'ColorTarget($item${autoTargeted ? ', auto' : ''}${locked ? ', locked' : ''})';
}

/// The clip the colour panel [route] should open on: the selected clip when it supports the panel,
/// else the main-lane clip under [playhead] (or the nearest one), else null.
ColorTarget? colorTargetOf(EditProject project, EditorSelection selection, TimeUs playhead, InspectorRoute Function(ItemId item) route) {
  final selected = selection.primary ?? (selection.items.length == 1 ? selection.items.first : null);
  if (selected != null && ToolSets.supportsItem(route(selected), selected, project)) {
    final loc = project.index.locate(selected);
    return ColorTarget(selected, autoTargeted: false, locked: loc?.track.locked ?? false);
  }
  final main = project.timeline.mainTrack;
  if (main == null) return null;
  MediaClip? best;
  var bestDistance = -1;
  for (final item in main.items) {
    if (item is! MediaClip || item.visual == null) continue;
    final distance = playhead < item.start ? item.start - playhead : (playhead >= item.end ? playhead - item.end + 1 : 0);
    if (best == null || distance < bestDistance) {
      best = item;
      bestDistance = distance;
    }
  }
  if (best == null || !ToolSets.supportsItem(route(best.id), best.id, project)) return null;
  return ColorTarget(best.id, autoTargeted: true, locked: main.locked);
}

ColorTarget? _target(EditorActionContext ctx, InspectorRoute Function(ItemId item) route) {
  final state = ctx.read(editorControllerProvider(ctx.projectId));
  final project = state.project;
  if (project == null || !state.isReady) return null;
  return colorTargetOf(project, state.selection, ctx.read(playheadProvider(ctx.projectId)).value, route);
}

bool _isEnabled(EditorActionContext ctx, InspectorRoute Function(ItemId item) route) {
  final target = _target(ctx, route);
  return target != null && !target.locked;
}

String? _reason(EditorActionContext ctx, InspectorRoute Function(ItemId item) route) {
  if (!ctx.read(editorControllerProvider(ctx.projectId)).isReady) return ColorStrings.notOpen;
  final target = _target(ctx, route);
  if (target == null) return ColorStrings.noClip;
  return target.locked ? ColorStrings.trackLocked : null;
}

void _open(EditorActionContext ctx, InspectorRoute Function(ItemId item) route) {
  final target = _target(ctx, route);
  if (target == null) return;
  final EditorController editor = ctx.read(editorControllerProvider(ctx.projectId).notifier);
  if (target.autoTargeted) {
    editor.select(target.item);
    final context = ctx.context;
    if (context.mounted) DanaviewToast.show(context, ColorStrings.editingClipAtPlayhead, icon: Icons.tune_rounded);
  }
  editor.openInspector(route(target.item));
}

AdjustInspector _adjustRoute(ItemId item) => AdjustInspector(item);

FiltersInspector _filtersRoute(ItemId item) => FiltersInspector(item);

bool _adjustEnabled(EditorActionContext ctx) => _isEnabled(ctx, _adjustRoute);

bool _filtersEnabled(EditorActionContext ctx) => _isEnabled(ctx, _filtersRoute);

String? _adjustReason(EditorActionContext ctx) => _reason(ctx, _adjustRoute);

String? _filtersReason(EditorActionContext ctx) => _reason(ctx, _filtersRoute);

void _openAdjust(EditorActionContext ctx) => _open(ctx, _adjustRoute);

void _openFilters(EditorActionContext ctx) => _open(ctx, _filtersRoute);

/// The colour actions bound by UX-24 (ARCH §17.6). The same instances on every read, so two merges
/// of the bindings compare equal (the wiring test relies on it).
List<EditorActionBinding> get colorBindings => _colorBindings;

final List<EditorActionBinding> _colorBindings = List.unmodifiable(<EditorActionBinding>[
  const EditorActionBinding(id: EditorActionId.adjust, handler: _openAdjust, isEnabled: _adjustEnabled, disabledReason: _adjustReason),
  const EditorActionBinding(id: EditorActionId.filters, handler: _openFilters, isEnabled: _filtersEnabled, disabledReason: _filtersReason),
]);
