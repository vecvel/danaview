// OWNER: UX-11
//
// The track menu sheet and the add-track sheet (ux.md §8.10), through `showDanaviewSheet`.
//
// A track's menu has: its name (rename), switches for Visible, Locked, Muted and Solo (the ones
// its kind has, ux.md §8.3), the audio role of an audio track, the height of the lanes (Compact,
// Normal, Large: a timeline-wide mode), Move up and Move down inside the kind's group, Select all
// on track, the subtitle rows for subtitle tracks, Add track (per kind) and Delete track
// (confirmed when it is not empty; the main track is protected).
//
// Subtitle rows are slots: Style, Import and Export SRT/VTT and Regenerate run the editor's
// actions (`captions`, `importSubtitles`, `exportSubtitles`, `regenerateCaptions`; UX-31, UX-32 and
// UX-37 bind them) after selecting the lane; a row whose action nobody binds yet is disabled with
// the registry's reason. "Burn into video" is the CORE-15 `SetBurnIn` switch.
//
// [TrackMenuModel] decides what is offered (pure, unit-tested), [TrackMenuView] draws it,
// [TrackMenuSheet] feeds it from the providers and keeps it live while commands apply.

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show maxTrackNameLength;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../../app/strings/track_strings.dart';
import '../actions/editor_action_registry.dart';
import '../contracts/contracts.dart';
import 'timeline_metrics.dart';
import 'timeline_snapshot.dart';
import 'track_headers.dart';

// -------------------------------------------------------------------------------------------------
// Model
// -------------------------------------------------------------------------------------------------

/// What the menu of one lane offers (pure).
@immutable
final class TrackMenuModel {
  /// Creates a model.
  const TrackMenuModel({
    required this.lane,
    required this.canEdit,
    required this.showsVisible,
    required this.showsMute,
    required this.showsSolo,
    required this.showsRole,
    required this.isSubtitle,
    required this.moveUpTo,
    required this.moveDownTo,
    required this.moveUpReason,
    required this.moveDownReason,
    required this.canDelete,
    required this.deleteReason,
    required this.itemCount,
    required this.burnIn,
    required this.regenerate,
  });

  /// The model of [lane] in [tracks] (the project's `Timeline.tracks`). A read-only project
  /// ([readOnly]) can't edit.
  factory TrackMenuModel.of({required LaneModel lane, required List<Track> tracks, bool readOnly = false}) {
    final kind = lane.kind;
    final flags = TrackFlags.applicable(lane);
    final index = tracks.indexWhere((t) => t.id == lane.id);
    final visual = kind.isVisual;
    // Visual lanes are drawn in reverse z order (D-09): "up" is the next higher index. Audio lanes
    // are listed in canonical order: "up" is the previous index.
    int? up, down;
    if (index >= 0) {
      final upIndex = visual ? index + 1 : index - 1;
      final downIndex = visual ? index - 1 : index + 1;
      bool sameKind(int i) => i >= 0 && i < tracks.length && tracks[i].kind == kind;
      if (sameKind(upIndex)) up = upIndex;
      // Nothing moves below the main lane.
      if (sameKind(downIndex) && !tracks[downIndex].isMain) down = downIndex;
    }
    String? upReason, downReason;
    if (lane.isMain) {
      upReason = downReason = TrackStrings.mainCantMove;
      up = down = null;
    } else if (lane.locked) {
      upReason = downReason = TrackStrings.unlockFirst;
      up = down = null;
    } else {
      if (up == null) upReason = TrackStrings.moveUpTop;
      if (down == null) downReason = TrackStrings.moveDownBottom;
    }
    final String? deleteReason = lane.isMain ? TrackStrings.mainCantDelete : (lane.locked ? TrackStrings.unlockFirst : null);
    // Read the project's track, not `lane.source`: the snapshot reuses a lane model when only
    // subtitle data changed, so the lane's source can be stale for burn-in and provenance.
    final data = (index >= 0 ? tracks[index] : lane.source).subtitle;
    return TrackMenuModel(
      lane: lane,
      canEdit: !readOnly,
      showsVisible: flags.contains(TrackFlag.hidden),
      showsMute: flags.contains(TrackFlag.muted),
      showsSolo: flags.contains(TrackFlag.solo),
      showsRole: kind == TrackKind.audio,
      isSubtitle: kind == TrackKind.subtitle,
      moveUpTo: up,
      moveDownTo: down,
      moveUpReason: upReason,
      moveDownReason: downReason,
      canDelete: deleteReason == null,
      deleteReason: deleteReason,
      itemCount: lane.items.length,
      burnIn: data?.burnIn ?? true,
      regenerate: data?.provenance != null,
    );
  }

  /// The lane.
  final LaneModel lane;

  /// False in a read-only project.
  final bool canEdit;

  /// Whether the Visible switch exists.
  final bool showsVisible;

  /// Whether the Muted switch exists.
  final bool showsMute;

  /// Whether the Solo switch exists.
  final bool showsSolo;

  /// Whether the audio role choice exists.
  final bool showsRole;

  /// Whether the subtitle rows exist.
  final bool isSubtitle;

  /// The `MoveTrack` target of "Move up" (an index of `Timeline.tracks`), or null.
  final int? moveUpTo;

  /// The `MoveTrack` target of "Move down", or null.
  final int? moveDownTo;

  /// Why Move up is disabled, or null.
  final String? moveUpReason;

  /// Why Move down is disabled, or null.
  final String? moveDownReason;

  /// Whether "Delete track" is enabled.
  final bool canDelete;

  /// Why Delete track is disabled, or null.
  final String? deleteReason;

  /// Items on the lane (a delete of a non-empty lane is confirmed).
  final int itemCount;

  /// The subtitle lane's burn-in default.
  final bool burnIn;

  /// Whether the subtitle lane was generated (Regenerate is offered).
  final bool regenerate;

  /// Whether commands that edit the lane (rename, role, move, delete) are allowed.
  bool get canEditLane => canEdit && !lane.locked;

  @override
  bool operator ==(Object other) =>
      other is TrackMenuModel &&
      identical(other.lane, lane) &&
      other.canEdit == canEdit &&
      other.moveUpTo == moveUpTo &&
      other.moveDownTo == moveDownTo &&
      other.itemCount == itemCount &&
      other.burnIn == burnIn &&
      other.regenerate == regenerate;

  @override
  int get hashCode => Object.hash(lane, canEdit, moveUpTo, moveDownTo, itemCount, burnIn, regenerate);
}

/// What a subtitle slot row needs from the action registry.
@immutable
final class TrackActionSlot {
  /// Creates the slot state.
  const TrackActionSlot({required this.label, required this.enabled, this.reason});

  /// The row label.
  final String label;

  /// Whether a feature binds the action and it is enabled now.
  final bool enabled;

  /// Why it is disabled, or null.
  final String? reason;
}

// -------------------------------------------------------------------------------------------------
// View
// -------------------------------------------------------------------------------------------------

/// The content of the track menu: pure, driven by [model].
class TrackMenuView extends StatelessWidget {
  /// Creates the menu.
  const TrackMenuView({
    super.key,
    required this.model,
    required this.laneHeight,
    required this.actions,
    required this.onClose,
    this.slots = const {},
    this.onSlot,
  });

  /// What to offer.
  final TrackMenuModel model;

  /// The current lane height mode.
  final LaneHeightPreset laneHeight;

  /// Where commands go.
  final TrackActions actions;

  /// Closes the sheet.
  final VoidCallback onClose;

  /// The subtitle action slots by id (Style, Import, Export, Regenerate).
  final Map<EditorActionId, TrackActionSlot> slots;

  /// Runs a subtitle action slot (select the lane, close the sheet, invoke the action).
  final void Function(EditorActionId id)? onSlot;

  /// The subtitle slots in display order.
  static const List<EditorActionId> subtitleSlots = [
    EditorActionId.captions,
    EditorActionId.importSubtitles,
    EditorActionId.exportSubtitles,
    EditorActionId.regenerateCaptions,
  ];

  Future<void> _rename(BuildContext context) async {
    final lane = model.lane;
    final name = await showDanaviewPrompt(
      context,
      title: TrackStrings.renameTitle,
      message: TrackStrings.renameMessage,
      hint: lane.displayName,
      initialValue: lane.name,
      confirmLabel: TrackStrings.renameConfirm,
      cancelLabel: TrackStrings.cancel,
      validator: (v) => v.characters.length > maxTrackNameLength ? TrackStrings.nameTooLong : null,
    );
    if (name != null) actions.rename(lane.id, name);
  }

  Future<void> _delete(BuildContext context) async {
    final lane = model.lane;
    if (model.itemCount > 0) {
      final ok = await showDanaviewConfirm(
        context,
        title: TrackStrings.deleteTitle(lane.displayName),
        message: TrackStrings.deleteMessage(model.itemCount),
        confirmLabel: TrackStrings.deleteConfirm,
        cancelLabel: TrackStrings.cancel,
        destructive: true,
        icon: Icons.delete_outline_rounded,
      );
      if (!ok) return;
    }
    actions.delete(lane.id);
    onClose();
  }

  @override
  Widget build(BuildContext context) {
    final lane = model.lane;
    final edit = model.canEdit;
    final editLane = model.canEditLane;
    final children = <Widget>[
      DanaviewListTile(
        key: const ValueKey('track-name'),
        title: TrackStrings.nameRow,
        subtitle: lane.displayName,
        leading: DanaviewTileIcon(trackKindIcon(lane.kind)),
        trailing: const Icon(Icons.edit_rounded, size: 18, color: DanaviewColors.textMuted),
        enabled: editLane,
        onTap: editLane ? () => _rename(context) : null,
      ),
      if (model.showsVisible)
        DanaviewSwitchRow(
          key: const ValueKey('track-visible'),
          title: TrackStrings.visible,
          value: !lane.hidden,
          onChanged: edit ? (_) => actions.toggle(lane, TrackFlag.hidden) : null,
        ),
      DanaviewSwitchRow(
        key: const ValueKey('track-locked'),
        title: TrackStrings.locked,
        subtitle: TrackStrings.lockedHint,
        value: lane.locked,
        onChanged: edit ? (_) => actions.toggle(lane, TrackFlag.lock) : null,
      ),
      if (model.showsMute)
        DanaviewSwitchRow(
          key: const ValueKey('track-muted'),
          title: TrackStrings.muted,
          value: lane.muted,
          onChanged: edit ? (_) => actions.toggle(lane, TrackFlag.muted) : null,
        ),
      if (model.showsSolo)
        DanaviewSwitchRow(
          key: const ValueKey('track-solo'),
          title: TrackStrings.solo,
          subtitle: TrackStrings.soloHint,
          value: lane.solo,
          onChanged: edit ? (_) => actions.toggle(lane, TrackFlag.solo) : null,
        ),
      if (model.showsRole) ...[
        const DanaviewSectionHeader(TrackStrings.roleSection),
        Wrap(
          key: const ValueKey('track-roles'),
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final role in AudioRole.values)
              DanaviewChoiceChip(
                label: TrackStrings.roleName(role),
                selected: lane.audioRole == role,
                onTap: editLane ? () => actions.setRole(lane.id, role) : null,
              ),
          ],
        ),
      ],
      const DanaviewSectionHeader(TrackStrings.heightSection, subtitle: TrackStrings.heightHint),
      Wrap(
        key: const ValueKey('track-heights'),
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final h in LaneHeightPreset.values)
            DanaviewChoiceChip(
              label: switch (h) {
                LaneHeightPreset.compact => TrackStrings.heightCompact,
                LaneHeightPreset.normal => TrackStrings.heightNormal,
                LaneHeightPreset.large => TrackStrings.heightLarge,
              },
              selected: laneHeight == h,
              onTap: () => actions.setLaneHeight(h),
            ),
        ],
      ),
      const SizedBox(height: 8),
      DanaviewListTile(
        key: const ValueKey('track-move-up'),
        title: TrackStrings.moveUp,
        subtitle: model.moveUpTo == null ? model.moveUpReason : null,
        leading: const DanaviewTileIcon(Icons.arrow_upward_rounded),
        enabled: edit && model.moveUpTo != null,
        onTap: edit && model.moveUpTo != null ? () => actions.move(lane.id, model.moveUpTo!) : null,
      ),
      DanaviewListTile(
        key: const ValueKey('track-move-down'),
        title: TrackStrings.moveDown,
        subtitle: model.moveDownTo == null ? model.moveDownReason : null,
        leading: const DanaviewTileIcon(Icons.arrow_downward_rounded),
        enabled: edit && model.moveDownTo != null,
        onTap: edit && model.moveDownTo != null ? () => actions.move(lane.id, model.moveDownTo!) : null,
      ),
      DanaviewListTile(
        key: const ValueKey('track-select-all'),
        title: TrackStrings.selectAll,
        subtitle: model.itemCount == 0 ? TrackStrings.selectAllEmpty : null,
        leading: const DanaviewTileIcon(Icons.select_all_rounded),
        enabled: model.itemCount > 0,
        onTap: model.itemCount > 0
            ? () {
                actions.selectAllOn(lane.id);
                onClose();
              }
            : null,
      ),
      if (model.isSubtitle) ..._subtitleRows(context),
      const DanaviewSectionHeader(TrackStrings.addSection),
      Wrap(
        key: const ValueKey('track-add'),
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final kind in TrackKind.values)
            DanaviewChoiceChip(
              label: TrackStrings.kindName(kind),
              icon: trackKindIcon(kind),
              selected: false,
              onTap: edit
                  ? () {
                      actions.add(kind);
                      onClose();
                    }
                  : null,
            ),
        ],
      ),
      const SizedBox(height: 8),
      DanaviewListTile(
        key: const ValueKey('track-delete'),
        title: TrackStrings.delete,
        subtitle: model.deleteReason,
        destructive: true,
        leading: const DanaviewTileIcon(Icons.delete_outline_rounded, color: DanaviewColors.errorLight),
        enabled: edit && model.canDelete,
        onTap: edit && model.canDelete ? () => _delete(context) : null,
      ),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  List<Widget> _subtitleRows(BuildContext context) {
    final lane = model.lane;
    return [
      const DanaviewSectionHeader(TrackStrings.subtitlesSection),
      for (final id in subtitleSlots)
        if (id != EditorActionId.regenerateCaptions || model.regenerate) _slotRow(id),
      DanaviewSwitchRow(
        key: const ValueKey('track-burn-in'),
        title: TrackStrings.burnIn,
        subtitle: TrackStrings.burnInHint,
        value: model.burnIn,
        onChanged: model.canEdit ? (v) => actions.setBurnIn(lane.id, v) : null,
      ),
    ];
  }

  Widget _slotRow(EditorActionId id) {
    final slot = slots[id];
    final label = switch (id) {
      EditorActionId.captions => TrackStrings.subtitleStyle,
      EditorActionId.importSubtitles => TrackStrings.subtitleImport,
      EditorActionId.exportSubtitles => TrackStrings.subtitleExport,
      _ => TrackStrings.subtitleRegenerate,
    };
    final icon = switch (id) {
      EditorActionId.captions => Icons.style_rounded,
      EditorActionId.importSubtitles => Icons.file_download_outlined,
      EditorActionId.exportSubtitles => Icons.file_upload_outlined,
      _ => Icons.refresh_rounded,
    };
    final enabled = slot?.enabled ?? false;
    return DanaviewListTile(
      key: ValueKey('track-slot-${id.name}'),
      title: label,
      subtitle: enabled ? null : slot?.reason,
      leading: DanaviewTileIcon(icon),
      enabled: enabled,
      onTap: enabled ? () => onSlot?.call(id) : null,
    );
  }
}

// -------------------------------------------------------------------------------------------------
// Sheets
// -------------------------------------------------------------------------------------------------

/// The track menu of one lane, live over the providers of the open project.
class TrackMenuSheet extends ConsumerWidget {
  /// Creates the menu of [track] in project [projectId]. [host] is the context that opened the
  /// sheet: subtitle actions run with it after the sheet closes.
  const TrackMenuSheet({super.key, required this.track, required this.projectId, this.host});

  /// The lane.
  final TrackId track;

  /// The open project.
  final ProjectId projectId;

  /// The context that opened the sheet (valid after the sheet closes).
  final BuildContext? host;

  /// Shows the menu of [track] as a bottom sheet.
  static Future<void> show(BuildContext context, {required ProjectId projectId, required TrackId track}) => showDanaviewSheet<void>(
        context,
        title: null,
        builder: (_) => TrackMenuSheet(track: track, projectId: projectId, host: context),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(timelineSnapshotProvider(projectId));
    final state = ref.watch(editorControllerProvider(projectId));
    final controller = ref.read(editorControllerProvider(projectId).notifier);
    final lane = snapshot.lane(track);
    if (lane == null) {
      return Padding(padding: const EdgeInsets.all(16), child: Text(TrackStrings.trackGone, style: DanaviewTextStyles.bodySecondary.copyWith(fontFamily: DanaviewFonts.family)));
    }
    final model = TrackMenuModel.of(lane: lane, tracks: state.project?.timeline.tracks ?? const [], readOnly: controller.readOnly);
    final registry = ref.watch(editorActionRegistryProvider);
    final slots = <EditorActionId, TrackActionSlot>{};
    if (model.isSubtitle) {
      final ctx = WidgetActionContext(projectId: projectId, context: context, ref: ref);
      for (final id in TrackMenuView.subtitleSlots) {
        final spec = registry.spec(id);
        final enabled = spec.isBound && spec.isVisible(ctx) && spec.isEnabled(ctx);
        slots[id] = TrackActionSlot(label: spec.label, enabled: enabled, reason: enabled ? null : spec.disabledReason(ctx));
      }
    }
    final actions = TrackActions.of(controller);
    void close() => Navigator.of(context).maybePop();
    return Semantics(
      container: true,
      label: TrackStrings.sheetLabel(lane.displayName),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
            child: Semantics(
              header: true,
              child: Text(TrackStrings.menuTitle(lane.displayName), maxLines: 2, overflow: TextOverflow.ellipsis, style: DanaviewTextStyles.title.copyWith(fontFamily: DanaviewFonts.family)),
            ),
          ),
          TrackMenuView(
            model: model,
            laneHeight: state.modes.laneHeight,
            actions: actions,
            onClose: close,
            slots: slots,
            onSlot: (id) {
              actions.focusLane(lane.id);
              final target = host != null && host!.mounted ? host! : context;
              close();
              final ctx = WidgetActionContext.container(
                projectId: projectId,
                context: target,
                container: ProviderScope.containerOf(context, listen: false),
              );
              registry.invoke(id, ctx);
            },
          ),
        ],
      ),
    );
  }
}

/// A sheet that adds a track of a chosen kind (the `addTrack` action).
class AddTrackSheet extends ConsumerWidget {
  /// Creates the sheet for project [projectId].
  const AddTrackSheet({super.key, required this.projectId});

  /// The open project.
  final ProjectId projectId;

  /// Shows the sheet.
  static Future<void> show(BuildContext context, {required ProjectId projectId}) =>
      showDanaviewSheet<void>(context, title: TrackStrings.addSheetTitle, builder: (_) => AddTrackSheet(projectId: projectId));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(editorControllerProvider(projectId).notifier);
    final actions = TrackActions.of(controller);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final kind in TrackKind.values)
          DanaviewListTile(
            key: ValueKey('add-${kind.name}'),
            title: TrackStrings.addTrack(kind),
            subtitle: TrackStrings.addTrackHint(kind),
            subtitleMaxLines: 2,
            leading: DanaviewTileIcon(trackKindIcon(kind)),
            enabled: !controller.readOnly,
            onTap: controller.readOnly
                ? null
                : () {
                    actions.add(kind);
                    Navigator.of(context).maybePop();
                  },
          ),
      ],
    );
  }
}
