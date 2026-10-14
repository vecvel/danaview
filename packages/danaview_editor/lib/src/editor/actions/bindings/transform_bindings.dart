// OWNER: UX-23
//
// The transform action bindings (merged by wiring/action_bindings.dart, ARCH §17.6, ux.md §10.2,
// §10.10, §7.5). Labels, icons and shortcuts come from the registry (UX-15); copy from
// `TransformStrings`.
//
// * `transform` opens the Transform panel on the selected video, image, overlay or text item.
// * `crop` opens the Crop panel (crop mode) and `mask` the Mask panel on the selected picture clip.
// * `resetTransform` (context menu of the preview, the tool strip) runs core `ResetTransform` on the
//   selected item: one history entry "Reset transform".
// * Each is enabled while the project accepts edits and the selection's primary item supports the
//   panel (`ToolSets.supports`) on an unlocked track; disabled tiles say why.

import 'package:danaview_editor_core/model.dart' show ItemId;
import 'package:danaview_editor_core/ops.dart' show ResetTransform;

import '../../../app/editor_providers.dart';
import '../../../app/strings/transform_strings.dart';
import '../../contracts/contracts.dart';
import '../../toolbar/tool_sets.dart';

/// The item [route] would open on: the primary selected item when it supports the panel, else
/// null. [unlocked] additionally requires its track to be unlocked.
ItemId? transformTarget(EditorActionContext ctx, InspectorRoute Function(ItemId item) route, {bool unlocked = false}) {
  final state = ctx.read(editorControllerProvider(ctx.projectId));
  final project = state.project;
  final primary = state.selection.primary ?? (state.selection.items.length == 1 ? state.selection.items.first : null);
  if (project == null || primary == null) return null;
  final loc = project.index.locate(primary);
  if (loc == null || !ToolSets.supports(route(primary), loc.item, loc.track, project.pool)) return null;
  if (unlocked && loc.track.locked) return null;
  return primary;
}

TransformInspector _transformRoute(ItemId item) => TransformInspector(item);

CropInspector _cropRoute(ItemId item) => CropInspector(item);

MaskInspector _maskRoute(ItemId item) => MaskInspector(item);

bool _canEdit(EditorActionContext ctx) => ctx.read(editorControllerProvider(ctx.projectId).notifier).canEdit;

bool _enabled(EditorActionContext ctx, InspectorRoute Function(ItemId item) route) =>
    _canEdit(ctx) && transformTarget(ctx, route, unlocked: true) != null;

String? _reason(EditorActionContext ctx, InspectorRoute Function(ItemId item) route, String select) {
  if (!_canEdit(ctx)) return TransformStrings.notOpen;
  if (transformTarget(ctx, route) == null) return select;
  return TransformStrings.trackLocked;
}

void _open(EditorActionContext ctx, InspectorRoute Function(ItemId item) route) {
  final item = transformTarget(ctx, route, unlocked: true);
  if (item == null) return;
  ctx.read(editorControllerProvider(ctx.projectId).notifier).openInspector(route(item));
}

bool _transformEnabled(EditorActionContext ctx) => _enabled(ctx, _transformRoute);

bool _cropEnabled(EditorActionContext ctx) => _enabled(ctx, _cropRoute);

bool _maskEnabled(EditorActionContext ctx) => _enabled(ctx, _maskRoute);

String? _transformReason(EditorActionContext ctx) => _reason(ctx, _transformRoute, TransformStrings.selectItem);

String? _cropReason(EditorActionContext ctx) => _reason(ctx, _cropRoute, TransformStrings.selectClip);

String? _maskReason(EditorActionContext ctx) => _reason(ctx, _maskRoute, TransformStrings.selectClip);

void _openTransform(EditorActionContext ctx) => _open(ctx, _transformRoute);

void _openCrop(EditorActionContext ctx) => _open(ctx, _cropRoute);

void _openMask(EditorActionContext ctx) => _open(ctx, _maskRoute);

void _resetTransform(EditorActionContext ctx) {
  final item = transformTarget(ctx, _transformRoute, unlocked: true);
  if (item == null) return;
  ctx.read(editorControllerProvider(ctx.projectId).notifier).apply(ResetTransform([item]));
}

/// The transform actions bound by UX-23 (ARCH §17.6). The same instances on every read, so two
/// merges of the bindings compare equal (the wiring test relies on it).
List<EditorActionBinding> get transformBindings => _transformBindings;

final List<EditorActionBinding> _transformBindings = List.unmodifiable(<EditorActionBinding>[
  const EditorActionBinding(
      id: EditorActionId.transform, handler: _openTransform, isEnabled: _transformEnabled, disabledReason: _transformReason),
  const EditorActionBinding(id: EditorActionId.crop, handler: _openCrop, isEnabled: _cropEnabled, disabledReason: _cropReason),
  const EditorActionBinding(id: EditorActionId.mask, handler: _openMask, isEnabled: _maskEnabled, disabledReason: _maskReason),
  const EditorActionBinding(
      id: EditorActionId.resetTransform, handler: _resetTransform, isEnabled: _transformEnabled, disabledReason: _transformReason),
]);
