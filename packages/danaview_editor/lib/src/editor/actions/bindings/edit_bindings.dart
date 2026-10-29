// OWNER: UX-13
//
// The edit action bindings (merged by wiring/action_bindings.dart, ARCH §17.6, ux.md §8.9, §14.4):
// split, delete, rippleDelete, deleteGap, copy, cut, paste, duplicate, selectAll, escape,
// multiSelect, moveToTrack, toggleSnapping and toggleRipple. Labels, icons and shortcuts come from
// the registry (UX-15); copy from app/strings/edit_strings.dart.
//
// * Every edit is one `EditorController.apply` (one history entry; rejections toast through the
//   controller). The commands come from `EditOperations`, which tests drive without widgets.
// * Split: at the playhead's frame; the selected items under it (cues through `SplitCue`), else the
//   unlocked main-lane clip under it (core `SelectionRules.splitTargets`); nothing there shows
//   "Move the playhead over a clip to split it." Haptic `lightImpact` on success.
// * Delete leaves a gap unless ripple mode is on; Ripple delete always closes it; a selected gap
//   is removed by Delete, Ripple delete and Delete gap; Delete also removes a selected transition
//   or marker.
// * Clipboard (editor_clipboard.dart): copy (no history), cut = copy + delete as one entry "Cut"
//   (D-16), paste at the playhead (selected lane when compatible), duplicate after the selection.
// * Escape runs the back chain without ever closing the editor: cancel the drag or transaction ->
//   close the panel -> leave multi-select mode -> clear the selection -> leave fullscreen.
// * Move to track: a sheet of the unlocked compatible lanes of a single-lane selection.

import 'dart:async';

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter/widgets.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../../app/editor_providers.dart';
import '../../../app/strings/edit_strings.dart';
import '../../../app/strings/track_strings.dart';
import '../../contracts/contracts.dart';
import '../../editor_lifecycle.dart' show EditorBackDispatcher, EditorBackStep;
import '../../state/editor_clipboard.dart';
import '../../state/editor_controller.dart';
import '../../state/editor_state.dart';
import '../../timeline/timeline_interaction.dart';
import '../../timeline/timeline_semantics.dart' show editorAnnounce;
import '../../timeline/track_headers.dart' show trackKindIcon;

// -------------------------------------------------------------------------------------------------
// Operations
// -------------------------------------------------------------------------------------------------

/// The commands behind the edit actions (ux.md §8.9, §14.4), over one project's controller.
final class EditOperations {
  /// Creates the operations; [state] reads the current editor state, [playhead] the playhead.
  EditOperations({
    required this.controller,
    required EditorState Function() state,
    required TimeUs Function() playhead,
    required this.clipboard,
  })  : _state = state,
        _playhead = playhead;

  /// The operations of the action context's project.
  factory EditOperations.of(EditorActionContext ctx) {
    final id = ctx.projectId;
    final controller = ctx.read(editorControllerProvider(id).notifier);
    return EditOperations(
      controller: controller,
      state: () => ctx.read(editorControllerProvider(id)),
      playhead: () => ctx.read(playheadProvider(id)).value,
      clipboard: ctx.read(editorClipboardProvider.notifier),
    );
  }

  /// The project's controller.
  final EditorController controller;

  /// The in-app clipboard.
  final EditorClipboardController clipboard;

  final EditorState Function() _state;
  final TimeUs Function() _playhead;

  EditorState get _s => _state();

  /// The current project, or null when it is not open.
  EditProject? get project => _s.project;

  /// Whether the project accepts edits.
  bool get canEdit => controller.canEdit && project != null;

  /// The selected items that still exist.
  Set<ItemId> get selectedItems {
    final p = project;
    if (p == null) return const {};
    return SelectionRules.surviving(p, _s.selection.items);
  }

  /// Whether items are selected.
  bool get hasItems => selectedItems.isNotEmpty;

  /// The selected gap.
  GapRef? get gap => _s.selection.gap;

  // ---- Split ------------------------------------------------------------------------------------

  /// The command "Split" runs at [at] (default: the playhead), or null when nothing is under it.
  EditCommand? splitCommand({TimeUs? at}) {
    final p = project;
    if (p == null) return null;
    final t = p.settings.frameRate.quantize(at ?? _playhead());
    final selected = selectedItems;
    final index = p.index;
    final items = SelectionRules.splitTargets(p, t, selected);
    final cues = <ItemId>[
      for (final id in selected)
        if (index.locate(id) case final loc? when !loc.track.locked && loc.item is SubtitleCue && loc.item.start < t && t < loc.item.end) id,
    ];
    // splitTargets falls back to the main lane when no selected clip is under the playhead; a
    // selected cue there is the target instead.
    final clips = cues.isNotEmpty && !items.any(selected.contains) ? const <ItemId>{} : items;
    final commands = <EditCommand>[
      if (clips.isNotEmpty) SplitItems(clips, t),
      for (final cue in cues) SplitCue(cue, t),
    ];
    if (commands.isEmpty) return null;
    return commands.length == 1 ? commands.single : CompositeCommand(EditStrings.split, commands);
  }

  /// Splits at [at] (default: the playhead); null when nothing is there to split.
  EditResult? split({TimeUs? at}) {
    final command = splitCommand(at: at);
    return command == null ? null : controller.apply(command);
  }

  // ---- Delete -----------------------------------------------------------------------------------

  /// The command Delete ([ripple] null: the ripple mode) or Ripple delete runs, or null.
  EditCommand? deleteCommand({bool? ripple}) {
    final s = _s;
    final items = selectedItems;
    final closeGap = ripple ?? s.modes.ripple;
    if (items.isNotEmpty) return DeleteItems(items, ripple: closeGap);
    final g = s.selection.gap;
    if (g != null) return DeleteGap(g);
    if (ripple == null) {
      final t = s.selection.transition;
      if (t != null) return SetTransition(t, null);
      final m = s.selection.marker;
      if (m != null) return DeleteMarker(m);
    }
    return null;
  }

  /// Delete: leaves a gap unless ripple mode is on (ux.md §8.9).
  EditResult? delete() => _run(deleteCommand());

  /// Ripple delete: always closes the gap.
  EditResult? rippleDelete() => _run(deleteCommand(ripple: true));

  /// Removes the selected gap.
  EditResult? deleteGap() {
    final g = gap;
    return g == null ? null : controller.apply(DeleteGap(g));
  }

  // ---- Clipboard --------------------------------------------------------------------------------

  /// Copies the selected items (no history entry); the number copied.
  int copy() {
    final p = project;
    final items = selectedItems;
    if (p == null || items.isEmpty) return 0;
    final payload = copyItems(p, items);
    clipboard.put(payload);
    return payload.items.length;
  }

  /// Cut (D-16): copy, then delete as one history entry "Cut"; the clipboard changes only when the
  /// delete is applied.
  EditResult? cut() {
    final p = project;
    final items = selectedItems;
    if (p == null || items.isEmpty) return null;
    final cut = cutItems(p, items, ripple: _s.modes.ripple);
    final result = controller.apply(cut.command);
    if (result is EditApplied) clipboard.put(cut.payload);
    return result;
  }

  /// Pastes the clipboard at [at] (default: the playhead) on [lane] (default: the selected lane).
  EditResult? paste({TimeUs? at, TrackId? lane}) {
    final contents = clipboard.contents;
    final p = project;
    if (contents == null || contents.isEmpty || p == null) return null;
    final t = p.settings.frameRate.quantizeNearest(at ?? _playhead());
    return controller.apply(PasteItems(contents.payload, t < 0 ? 0 : t, preferTrack: lane ?? _s.selection.lane, ripple: _s.modes.ripple));
  }

  /// Duplicates the selected items right after the selection.
  EditResult? duplicate() {
    final items = selectedItems;
    return items.isEmpty ? null : controller.apply(DuplicateItems(items, ripple: _s.modes.ripple));
  }

  // ---- Selection and modes ----------------------------------------------------------------------

  /// Selects every unlocked item (of the selected lane when only a lane is selected).
  void selectAll() {
    final s = _s;
    controller.selectAll(lane: s.selection.items.isEmpty ? s.selection.lane : null);
  }

  /// Lanes the selection may move to ("Move to track…").
  List<TrackId> moveTargets() {
    final p = project;
    final items = selectedItems;
    if (p == null || items.isEmpty) return const [];
    return SelectionRules.moveTargets(p, items);
  }

  /// Moves the selection to [lane] at the same time.
  EditResult? moveToTrack(TrackId lane) {
    final items = selectedItems;
    if (items.isEmpty) return null;
    return controller.apply(MoveItems(items, 0, toTrack: lane, ripple: _s.modes.ripple));
  }

  /// Toggles snapping; the new state.
  bool toggleSnapping() {
    controller.setModes((m) => m.copyWith(snapping: !m.snapping));
    return _s.modes.snapping;
  }

  /// Toggles ripple editing; the new state.
  bool toggleRipple() {
    controller.setModes((m) => m.copyWith(ripple: !m.ripple));
    return _s.modes.ripple;
  }

  /// Toggles touch multi-select mode; the new state.
  bool toggleMultiSelect() {
    controller.setModes((m) => m.copyWith(multiSelect: !m.multiSelect));
    return _s.modes.multiSelect;
  }

  EditResult? _run(EditCommand? command) => command == null ? null : controller.apply(command);
}

// -------------------------------------------------------------------------------------------------
// Handlers
// -------------------------------------------------------------------------------------------------

EditOperations _ops(EditorActionContext ctx) => EditOperations.of(ctx);

bool _canEdit(EditorActionContext ctx) => _ops(ctx).canEdit;

bool _hasItems(EditorActionContext ctx) {
  final o = _ops(ctx);
  return o.canEdit && o.hasItems;
}

String? _notEditable(EditorActionContext ctx) => EditStrings.notEditable;

String? _selectFirst(EditorActionContext ctx) => _ops(ctx).canEdit ? EditStrings.selectClipFirst : EditStrings.notEditable;

void _say(EditorActionContext ctx, String message, {bool toast = true, IconData? icon}) {
  final context = ctx.context;
  if (!context.mounted) return;
  if (toast) DanaviewToast.show(context, message, icon: icon);
  editorAnnounce(context, message);
}

void _split(EditorActionContext ctx) {
  final result = _ops(ctx).split();
  if (result == null) {
    HapticFeedback.selectionClick();
    _say(ctx, EditStrings.splitNoTarget, icon: Icons.content_cut_rounded);
  } else if (result is EditApplied) {
    HapticFeedback.lightImpact();
  }
}

bool _canDelete(EditorActionContext ctx) {
  final o = _ops(ctx);
  return o.canEdit && o.deleteCommand() != null;
}

bool _canRippleDelete(EditorActionContext ctx) {
  final o = _ops(ctx);
  return o.canEdit && o.deleteCommand(ripple: true) != null;
}

bool _hasGap(EditorActionContext ctx) {
  final o = _ops(ctx);
  return o.canEdit && o.gap != null;
}

String? _gapReason(EditorActionContext ctx) => _ops(ctx).canEdit ? EditStrings.selectGapFirst : EditStrings.notEditable;

bool _canCopy(EditorActionContext ctx) => _ops(ctx).hasItems;

String? _copyReason(EditorActionContext ctx) => EditStrings.selectClipFirst;

void _copy(EditorActionContext ctx) {
  final n = _ops(ctx).copy();
  if (n > 0) _say(ctx, EditStrings.copied(n), icon: Icons.content_copy_rounded);
}

void _cut(EditorActionContext ctx) {
  final o = _ops(ctx);
  final n = o.selectedItems.length;
  if (o.cut() is EditApplied) _say(ctx, EditStrings.cut(n), toast: false);
}

bool _canPaste(EditorActionContext ctx) => _ops(ctx).canEdit && ctx.read(editorClipboardProvider.notifier).hasContent;

String? _pasteReason(EditorActionContext ctx) => _ops(ctx).canEdit ? EditStrings.clipboardEmpty : EditStrings.notEditable;

bool _canSelectAll(EditorActionContext ctx) {
  final p = _ops(ctx).project;
  return p != null && SelectionRules.all(p).isNotEmpty;
}

String? _selectAllReason(EditorActionContext ctx) => EditStrings.nothingToSelect;

bool _isReady(EditorActionContext ctx) => ctx.read(editorControllerProvider(ctx.projectId)).isReady;

TimelineInteractionController? _interaction(EditorActionContext ctx) {
  try {
    return ctx.read(interactionProvider(ctx.projectId));
  } catch (_) {
    return null;
  }
}

bool _canEscape(EditorActionContext ctx) {
  final id = ctx.projectId;
  final controller = ctx.read(editorControllerProvider(id).notifier);
  final s = ctx.read(editorControllerProvider(id));
  if (controller.transaction != null || s.inspector != null || !s.selection.isEmpty || s.modes.multiSelect) return true;
  if (_interaction(ctx)?.isDragging ?? false) return true;
  try {
    return ctx.read(transportProvider(id)).fullscreen.value;
  } catch (_) {
    return false;
  }
}

String? _escapeReason(EditorActionContext ctx) => EditStrings.nothingToCancel;

/// Esc: one step of cancel -> close panel -> leave multi-select -> clear selection -> leave
/// fullscreen. Never closes the editor.
Future<void> _escape(EditorActionContext ctx) async {
  final id = ctx.projectId;
  final controller = ctx.read(editorControllerProvider(id).notifier);
  final interaction = _interaction(ctx);
  if (interaction != null && interaction.isDragging) {
    // The timeline's back handler cancels the arbiter and the drag together.
    final dispatcher = ctx.context.mounted ? EditorBackDispatcher.maybeOf(ctx.context) : null;
    if (dispatcher != null) {
      await dispatcher.handleBack();
    } else {
      interaction.endDrag(cancelled: true);
    }
    return;
  }
  if (controller.dismissForBack(EditorBackStep.cancelGesture)) return;
  if (controller.dismissForBack(EditorBackStep.closePanel)) return;
  if (ctx.read(editorControllerProvider(id)).modes.multiSelect) {
    controller.setModes((m) => m.copyWith(multiSelect: false));
    _say(ctx, EditStrings.multiSelectOff, toast: false);
    return;
  }
  if (controller.dismissForBack(EditorBackStep.clearSelection)) return;
  try {
    final transport = ctx.read(transportProvider(id));
    if (transport.fullscreen.value) transport.setFullscreen(false);
  } catch (_) {}
}

void _multiSelect(EditorActionContext ctx) {
  final on = _ops(ctx).toggleMultiSelect();
  _say(ctx, on ? EditStrings.multiSelectOn : EditStrings.multiSelectOff, toast: false);
}

bool _canMoveToTrack(EditorActionContext ctx) {
  final o = _ops(ctx);
  return o.canEdit && o.moveTargets().isNotEmpty;
}

String? _moveReason(EditorActionContext ctx) {
  final o = _ops(ctx);
  if (!o.canEdit) return EditStrings.notEditable;
  return o.hasItems ? EditStrings.noOtherTrack : EditStrings.selectClipFirst;
}

Future<void> _moveToTrack(EditorActionContext ctx) async {
  final o = _ops(ctx);
  final targets = o.moveTargets();
  final p = o.project;
  if (targets.isEmpty || p == null || !ctx.context.mounted) return;
  final lane = await MoveToTrackSheet.show(ctx.context, project: p, targets: targets, names: _laneNames(ctx));
  if (lane != null) o.moveToTrack(lane);
}

Map<TrackId, String> _laneNames(EditorActionContext ctx) {
  try {
    final snapshot = ctx.read(timelineSnapshotProvider(ctx.projectId));
    return {for (final l in snapshot.lanes) l.id: l.displayName};
  } catch (_) {
    return const {};
  }
}

void _toggleSnapping(EditorActionContext ctx) => _say(ctx, EditStrings.snapping(_ops(ctx).toggleSnapping()));

void _toggleRipple(EditorActionContext ctx) => _say(ctx, EditStrings.ripple(_ops(ctx).toggleRipple()));

/// The edit actions bound by UX-13 (ARCH §17.6). The same instances on every read.
List<EditorActionBinding> get editBindings => _editBindings;

final List<EditorActionBinding> _editBindings = List.unmodifiable(<EditorActionBinding>[
  const EditorActionBinding(id: EditorActionId.split, handler: _split, isEnabled: _canEdit, disabledReason: _notEditable),
  EditorActionBinding(id: EditorActionId.delete, handler: (ctx) => _ops(ctx).delete(), isEnabled: _canDelete, disabledReason: _selectFirst),
  EditorActionBinding(
      id: EditorActionId.rippleDelete, handler: (ctx) => _ops(ctx).rippleDelete(), isEnabled: _canRippleDelete, disabledReason: _selectFirst),
  EditorActionBinding(id: EditorActionId.deleteGap, handler: (ctx) => _ops(ctx).deleteGap(), isEnabled: _hasGap, disabledReason: _gapReason),
  const EditorActionBinding(id: EditorActionId.copy, handler: _copy, isEnabled: _canCopy, disabledReason: _copyReason),
  const EditorActionBinding(id: EditorActionId.cut, handler: _cut, isEnabled: _hasItems, disabledReason: _selectFirst),
  EditorActionBinding(id: EditorActionId.paste, handler: (ctx) => _ops(ctx).paste(), isEnabled: _canPaste, disabledReason: _pasteReason),
  EditorActionBinding(
      id: EditorActionId.duplicate, handler: (ctx) => _ops(ctx).duplicate(), isEnabled: _hasItems, disabledReason: _selectFirst),
  EditorActionBinding(
      id: EditorActionId.selectAll, handler: (ctx) => _ops(ctx).selectAll(), isEnabled: _canSelectAll, disabledReason: _selectAllReason),
  const EditorActionBinding(id: EditorActionId.escape, handler: _escape, isEnabled: _canEscape, disabledReason: _escapeReason),
  const EditorActionBinding(id: EditorActionId.multiSelect, handler: _multiSelect, isEnabled: _isReady, disabledReason: _notEditable),
  const EditorActionBinding(id: EditorActionId.moveToTrack, handler: _moveToTrack, isEnabled: _canMoveToTrack, disabledReason: _moveReason),
  const EditorActionBinding(id: EditorActionId.toggleSnapping, handler: _toggleSnapping, isEnabled: _isReady, disabledReason: _notEditable),
  const EditorActionBinding(id: EditorActionId.toggleRipple, handler: _toggleRipple, isEnabled: _isReady, disabledReason: _notEditable),
]);

// -------------------------------------------------------------------------------------------------
// Move to track sheet
// -------------------------------------------------------------------------------------------------

/// "Move to track…": the unlocked lanes of a compatible kind (ux.md §8.9).
class MoveToTrackSheet extends StatelessWidget {
  /// Creates the sheet listing [targets] of [project]; [names] are the lanes' display names.
  const MoveToTrackSheet({super.key, required this.project, required this.targets, this.names = const {}});

  /// Shows the sheet; the chosen lane, or null when dismissed.
  static Future<TrackId?> show(BuildContext context,
          {required EditProject project, required List<TrackId> targets, Map<TrackId, String> names = const {}}) =>
      showDanaviewSheet<TrackId>(context,
          title: EditStrings.moveToTrackTitle, builder: (_) => MoveToTrackSheet(project: project, targets: targets, names: names));

  /// The project.
  final EditProject project;

  /// Lanes the selection may move to.
  final List<TrackId> targets;

  /// Display names of lanes.
  final Map<TrackId, String> names;

  @override
  Widget build(BuildContext context) {
    final tracks = {for (final t in project.tracks) t.id: t};
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final id in targets)
          if (tracks[id] case final track?)
            DanaviewListTile(
              key: ValueKey('move-to-${id.value}'),
              title: names[id] ?? (track.name.isEmpty ? TrackStrings.kindName(track.kind) : track.name),
              subtitle: EditStrings.clipsOnTrack(track.items.length),
              leading: DanaviewIconTile(trackKindIcon(track.kind)),
              onTap: () => Navigator.of(context).pop(id),
            ),
      ],
    );
  }
}
