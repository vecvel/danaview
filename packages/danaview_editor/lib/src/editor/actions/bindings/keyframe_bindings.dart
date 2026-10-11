// OWNER: UX-26
//
// The keyframe action bindings (merged by wiring/action_bindings.dart, ARCH §17.6, ux.md §9.2,
// §10.11). Labels, icons and shortcuts come from the registry (UX-15); copy from `KeyframeStrings`.
//
// * `keyframes` opens the Keyframes panel on the selected clip or text (or on the item of the
//   selected keyframe: the timeline's long-press menu selects the diamond first, so the panel opens
//   with that key's card). Enabled while the project accepts edits and the item's track is unlocked.
// * `keyframeAtPlayhead` adds or removes keys at the playhead in one history entry: on the property
//   of the selected keyframe when there is one, else on the item's animated properties, else (first
//   use) on position, scale, rotation and opacity (volume for an audio clip). It needs the playhead
//   over the item.
// * Both explain themselves when disabled.

import 'package:danaview_editor_core/model.dart';

import '../../../app/editor_providers.dart';
import '../../../app/strings/keyframe_strings.dart';
import '../../contracts/contracts.dart';
import '../../panels/keyframes_panel.dart';
import '../../state/editor_controller.dart';
import '../../toolbar/tool_sets.dart';

/// The item the keyframe actions edit and what was selected on it.
final class KeyframeTarget {
  /// Creates the target.
  const KeyframeTarget(this.item, {required this.locked, this.property});

  /// The clip or text.
  final ItemId item;

  /// Whether its track is locked.
  final bool locked;

  /// The property of the selected keyframe, when one is selected on [item].
  final PropertyKey<Object?>? property;
}

/// The item the keyframe actions would edit in the open project, or null: a single selected clip or
/// text, or the item of the selected keyframe.
KeyframeTarget? keyframeTarget(EditorActionContext ctx) {
  final state = ctx.read(editorControllerProvider(ctx.projectId));
  final project = state.project;
  if (project == null) return null;
  final selection = state.selection;
  if (selection.items.length > 1) return null;
  final keyframe = selection.keyframe;
  final id = keyframe?.item ?? selection.primary ?? selection.items.firstOrNull;
  if (id == null) return null;
  final loc = project.index.locate(id);
  if (loc == null || !KeyframeCommands.animatable(loc.item)) return null;
  if (!ToolSets.supportsItem(KeyframesInspector(id), id, project)) return null;
  final property = keyframe != null && keyframe.item == id ? KeyframeCommands.resolve(keyframe.property) : null;
  return KeyframeTarget(id, locked: loc.track.locked, property: property);
}

bool _canEdit(EditorActionContext ctx) => ctx.read(editorControllerProvider(ctx.projectId).notifier).canEdit;

bool _canOpen(EditorActionContext ctx) {
  final target = keyframeTarget(ctx);
  return _canEdit(ctx) && target != null && !target.locked;
}

String? _openReason(EditorActionContext ctx) {
  if (!ctx.read(editorControllerProvider(ctx.projectId)).isReady) return KeyframeStrings.notOpen;
  if (!_canEdit(ctx)) return KeyframeStrings.notEditable;
  final target = keyframeTarget(ctx);
  if (target == null) return KeyframeStrings.selectItem;
  return target.locked ? KeyframeStrings.actionTrackLocked : null;
}

void _open(EditorActionContext ctx) {
  final target = keyframeTarget(ctx);
  if (target == null) return;
  ctx.read(editorControllerProvider(ctx.projectId).notifier).openInspector(KeyframesInspector(target.item));
}

bool _playheadInside(EditorActionContext ctx, KeyframeTarget target) {
  final item = ctx.read(editorControllerProvider(ctx.projectId)).project?.index.item(target.item);
  if (item == null) return false;
  final t = ctx.read(playheadProvider(ctx.projectId)).value;
  return t >= item.start && t < item.end;
}

bool _canKeyframe(EditorActionContext ctx) {
  final target = keyframeTarget(ctx);
  return _canEdit(ctx) && target != null && !target.locked && _playheadInside(ctx, target);
}

String? _keyframeReason(EditorActionContext ctx) {
  final reason = _openReason(ctx);
  if (reason != null) return reason;
  final target = keyframeTarget(ctx);
  return target != null && !_playheadInside(ctx, target) ? KeyframeStrings.playheadOutside : null;
}

void _keyframeAtPlayhead(EditorActionContext ctx) {
  final target = keyframeTarget(ctx);
  if (target == null || !_playheadInside(ctx, target)) return;
  final state = ctx.read(editorControllerProvider(ctx.projectId));
  final project = state.project;
  final item = project?.index.item(target.item);
  if (project == null || item == null) return;
  final at = ctx.read(playheadProvider(ctx.projectId)).value;
  final EditorController editor = ctx.read(editorControllerProvider(ctx.projectId).notifier);
  editor.apply(KeyframeCommands.atPlayhead(item, project.pool, at, selected: target.property));
}

/// The keyframe actions bound by UX-26 (ARCH §17.6). The same instances on every read, so two merges
/// of the bindings compare equal (the wiring test relies on it).
List<EditorActionBinding> get keyframeBindings => _keyframeBindings;

final List<EditorActionBinding> _keyframeBindings = List.unmodifiable(<EditorActionBinding>[
  const EditorActionBinding(id: EditorActionId.keyframes, handler: _open, isEnabled: _canOpen, disabledReason: _openReason),
  const EditorActionBinding(
    id: EditorActionId.keyframeAtPlayhead,
    handler: _keyframeAtPlayhead,
    isEnabled: _canKeyframe,
    disabledReason: _keyframeReason,
  ),
]);
