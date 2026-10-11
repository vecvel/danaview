// OWNER: UX-25
//
// The speed action binding (merged by wiring/action_bindings.dart, ARCH §17.6, ux.md §10.3).
//
// * `speed` opens the speed panel on the selected video or audio clip (the context tool tile and
//   the semantics action both run it). It is enabled while the project accepts edits and the
//   selection's primary item is a clip that supports speed (`ToolSets.supports`: images and freeze
//   frames do not) on an unlocked track.
// * Reverse and freeze frame are bound by UX-35 (clip_bindings.dart); the speed panel's two buttons
//   run those actions through the registry.
// * Labels, icons and shortcuts come from the registry (UX-15); copy from `SpeedStrings`.

import 'package:vwish_editor_core/model.dart' show ItemId;

import '../../../app/editor_providers.dart';
import '../../../app/strings/speed_strings.dart';
import '../../contracts/contracts.dart';
import '../../toolbar/tool_sets.dart';

/// The clip the speed action would edit: the primary selected item when it supports the speed
/// panel, else null. [unlocked] additionally requires its track to be unlocked.
ItemId? speedTarget(EditorActionContext ctx, {bool unlocked = false}) {
  final state = ctx.read(editorControllerProvider(ctx.projectId));
  final project = state.project;
  final primary = state.selection.primary;
  if (project == null || primary == null) return null;
  final loc = project.index.locate(primary);
  if (loc == null || !ToolSets.supports(SpeedInspector(primary), loc.item, loc.track, project.pool)) return null;
  if (unlocked && loc.track.locked) return null;
  return primary;
}

bool _canOpen(EditorActionContext ctx) => ctx.read(editorControllerProvider(ctx.projectId).notifier).canEdit && speedTarget(ctx, unlocked: true) != null;

String? _reason(EditorActionContext ctx) {
  if (!ctx.read(editorControllerProvider(ctx.projectId).notifier).canEdit) return SpeedStrings.notEditable;
  if (speedTarget(ctx) == null) return SpeedStrings.selectClip;
  return SpeedStrings.actionTrackLocked;
}

void _open(EditorActionContext ctx) {
  final item = speedTarget(ctx, unlocked: true);
  if (item == null) return;
  ctx.read(editorControllerProvider(ctx.projectId).notifier).openInspector(SpeedInspector(item));
}

/// The speed actions bound by UX-25 (ARCH §17.6). The same instances on every read, so two merges
/// of the bindings compare equal (the wiring test relies on it).
List<EditorActionBinding> get speedBindings => _speedBindings;

final List<EditorActionBinding> _speedBindings = List.unmodifiable(<EditorActionBinding>[
  const EditorActionBinding(id: EditorActionId.speed, handler: _open, isEnabled: _canOpen, disabledReason: _reason),
]);
