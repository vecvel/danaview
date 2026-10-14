// OWNER: UX-28
//
// The overlay action bindings (merged by wiring/action_bindings.dart, ARCH §17.6, ux.md §10.10,
// §10.13) and `OverlayOperations`, the commands behind the Overlay panel. Labels, icons and
// shortcuts come from the registry (UX-15); copy from `OverlayStrings`.
//
// * `addOverlay` (the top-level Overlay tool) opens the Overlay panel; its buttons pick a video or a
//   photo, import it (UX-06's import sheet) and place it with `MediaOperations.addAsOverlay`: the
//   topmost overlay lane free at the playhead (a new lane when there is none), 40 % at centre-right,
//   one history entry. The new overlay is selected and the Transform panel opens.
// * `chromaKey` opens the Chroma key panel on the selected video or photo clip (unlocked track).
// * `bringForward` / `sendBackward` move the selected overlay clip between overlay lanes (a higher
//   lane composites on top, D-09). One step passes the nearest lane in that direction holding an
//   overlay that overlaps the clip in time: the clip goes to the first free, unlocked lane beyond
//   it, or to a new lane at the top (forward) or bottom (backward) of the overlay group when there
//   is none. With nothing overlapping in that direction the clip moves to the adjacent lane. Each
//   press is one history entry ("Bring overlay forward" / "Send overlay backward"); a new lane and
//   the move are joined into that entry. Disabled at the frontmost / backmost overlay lane, and on
//   locked lanes, with a reason.

import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderListenable;
import 'package:flutter/foundation.dart' show immutable;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:danaview_editor_core/store.dart' show MediaPoolService;

import '../../../app/editor_providers.dart';
import '../../../app/strings/overlay_strings.dart';
import '../../contracts/contracts.dart';
import '../../flows/import_media_sheet.dart';
import '../../state/editor_controller.dart';
import '../../state/editor_state.dart';
import 'media_bindings.dart';
import 'transform_bindings.dart' show transformTarget;

/// One overlay clip as the Overlay panel lists it.
@immutable
final class OverlayClipEntry {
  /// Creates the entry.
  const OverlayClipEntry({required this.clip, required this.lane, required this.laneName, required this.laneOrdinal});

  /// The clip.
  final MediaClip clip;

  /// Its lane.
  final Track lane;

  /// The lane's display name ("Overlay 2").
  final String laneName;

  /// 1 for the bottom overlay lane, counting up.
  final int laneOrdinal;
}

/// Where a z move puts an overlay clip.
@immutable
final class OverlayZMove {
  /// Creates the move; a null [lane] means a new lane.
  const OverlayZMove({required this.item, required this.forward, this.lane});

  /// The clip.
  final ItemId item;

  /// Towards the front.
  final bool forward;

  /// The existing lane it goes to, or null for a new lane at the top (forward) or the bottom
  /// (backward) of the overlay group.
  final TrackId? lane;

  @override
  bool operator ==(Object other) => other is OverlayZMove && other.item == item && other.forward == forward && other.lane == lane;

  @override
  int get hashCode => Object.hash(item, forward, lane);

  @override
  String toString() => 'OverlayZMove($item, ${forward ? 'forward' : 'backward'} → ${lane ?? 'new lane'})';
}

/// Pure z-order helpers over a project (see the file header).
abstract final class OverlayZOrder {
  /// The overlay lanes, bottom to top.
  static List<Track> lanes(EditProject project) => [
        for (final t in project.timeline.tracks)
          if (t.kind == TrackKind.overlay) t,
      ];

  /// The overlay clips front to back: top lane first, each lane's clips in time order.
  static List<OverlayClipEntry> entries(EditProject project) {
    final all = lanes(project);
    return [
      for (var i = all.length - 1; i >= 0; i--)
        for (final item in all[i].items)
          if (item is MediaClip) OverlayClipEntry(clip: item, lane: all[i], laneName: OverlayStrings.laneName(all[i].name, i + 1), laneOrdinal: i + 1),
    ];
  }

  /// The location of [item] when it is a clip on an overlay lane, else null.
  static ItemLocation? overlayClip(EditProject project, ItemId item) {
    final loc = project.index.locate(item);
    if (loc == null || loc.track.kind != TrackKind.overlay || loc.item is! MediaClip) return null;
    return loc;
  }

  /// Where one step [forward] (or backward) takes [item], or null when it can't move that way.
  static OverlayZMove? plan(EditProject project, ItemId item, {required bool forward}) {
    final loc = overlayClip(project, item);
    if (loc == null || loc.track.locked) return null;
    final all = lanes(project);
    final pos = all.indexWhere((t) => t.id == loc.track.id);
    final beyond = forward ? all.sublist(pos + 1) : all.sublist(0, pos).reversed.toList();
    if (beyond.isEmpty) return null;
    final ranges = [loc.item.range];
    final ignore = {item};
    bool free(Track t) => LanePlacement.isFree(t, ranges, ignore: ignore);
    final blocker = beyond.indexWhere((t) => !free(t));
    if (blocker < 0) {
      // Nothing overlaps in that direction: the adjacent (unlocked) lane.
      for (final t in beyond) {
        if (!t.locked) return OverlayZMove(item: item, forward: forward, lane: t.id);
      }
      return null;
    }
    for (final t in beyond.skip(blocker + 1)) {
      if (!t.locked && free(t)) return OverlayZMove(item: item, forward: forward, lane: t.id);
    }
    return OverlayZMove(item: item, forward: forward);
  }

  /// Why [item] can't move [forward] (or backward), or null when it can.
  static String? blocker(EditProject? project, ItemId? item, {required bool forward}) {
    if (project == null) return OverlayStrings.notOpen;
    if (item == null) return OverlayStrings.selectOverlay;
    final loc = overlayClip(project, item);
    if (loc == null) return OverlayStrings.selectOverlay;
    if (loc.track.locked) return OverlayStrings.trackLocked;
    if (plan(project, item, forward: forward) != null) return null;
    final all = lanes(project);
    final pos = all.indexWhere((t) => t.id == loc.track.id);
    final edge = forward ? pos == all.length - 1 : pos == 0;
    if (edge) return forward ? OverlayStrings.alreadyFront : OverlayStrings.alreadyBack;
    return OverlayStrings.targetLocked;
  }
}

/// The commands behind the Overlay panel and the overlay actions (see the file header).
final class OverlayOperations {
  /// Creates the operations over [controller]; [state] reads the editor state.
  OverlayOperations({required this.controller, required EditorState Function() state, required this.media}) : _state = state;

  /// The operations of project [id], reading providers with [read].
  factory OverlayOperations.forProject(ProjectId id, T Function<T>(ProviderListenable<T> provider) read) => OverlayOperations(
        controller: read(editorControllerProvider(id).notifier),
        state: () => read(editorControllerProvider(id)),
        media: MediaOperations.forProject(id, read),
      );

  /// The operations of the action context's project.
  factory OverlayOperations.of(EditorActionContext ctx) => OverlayOperations.forProject(ctx.projectId, ctx.read);

  /// The project's controller.
  final EditorController controller;

  /// The media operations (placement as overlay, imports).
  final MediaOperations media;

  final EditorState Function() _state;

  static int _serial = 0;

  /// The current project, or null.
  EditProject? get project => _state().project;

  /// The primary selected item (or the only one), or null.
  ItemId? get selected {
    final s = _state().selection;
    return s.primary ?? (s.items.length == 1 ? s.items.first : null);
  }

  /// The selected overlay clip, or null.
  ItemId? get selectedOverlay {
    final p = project;
    final id = selected;
    if (p == null || id == null) return null;
    return OverlayZOrder.overlayClip(p, id) == null ? null : id;
  }

  /// Whether new overlays can be added (an editable project that is not read-only).
  bool get canAdd => media.canEdit && !media.readOnly;

  /// Why the selected overlay can't move [forward] (or backward), or null.
  String? zBlocker({required bool forward}) {
    if (!controller.canEdit) return OverlayStrings.notOpen;
    return OverlayZOrder.blocker(project, selected, forward: forward);
  }

  /// Moves [item] one step [forward] (or backward); null when it can't move.
  EditResult? moveZ(ItemId item, {required bool forward}) {
    final p = project;
    if (p == null || !controller.canEdit) return null;
    final plan = OverlayZOrder.plan(p, item, forward: forward);
    if (plan == null) return null;
    final label = forward ? OverlayStrings.historyForward : OverlayStrings.historyBackward;
    final lane = plan.lane;
    if (lane != null) return controller.apply(CompositeCommand(label, [MoveItems({item}, 0, toTrack: lane)]));
    // A new lane: created, placed and filled as one history entry.
    final key = 'overlay.z#${_serial++}';
    final before = {for (final t in p.timeline.tracks) t.id};
    final added = controller.apply(CompositeCommand(label, const [AddTrack(TrackKind.overlay)]), coalesceKey: key);
    if (added is! EditApplied) return added;
    final now = project;
    if (now == null) return added;
    TrackId? created;
    var firstOverlay = -1;
    final tracks = now.timeline.tracks;
    for (var i = 0; i < tracks.length; i++) {
      final t = tracks[i];
      if (t.kind != TrackKind.overlay) continue;
      if (firstOverlay < 0) firstOverlay = i;
      if (!before.contains(t.id)) created = t.id;
    }
    if (created == null) return added;
    final result = controller.apply(
      CompositeCommand(label, [
        if (!forward && tracks.indexWhere((t) => t.id == created) != firstOverlay) MoveTrack(created, firstOverlay),
        MoveItems({item}, 0, toTrack: created),
      ]),
      coalesceKey: key,
    );
    // Don't leave an empty lane behind when the move was refused.
    if (result is! EditApplied) controller.undo();
    return result;
  }

  /// The import job of the Overlay panel: imports the picks, then places the visual media as an
  /// overlay at [at] (default: the playhead), selects it and opens the Transform panel.
  /// [onPlaced] receives the placement result (null when nothing could be placed).
  ImportJob importJob({
    required MediaPoolService pool,
    required EditSession edit,
    TimeUs? at,
    void Function(EditResult? result)? onPlaced,
  }) {
    final base = sessionImportJob(
      pool: pool,
      session: edit,
      place: (outcomes) {
        final assets = MediaOperations.assetsOf(outcomes);
        controller.applyPoolChange(AddAssets(assets));
        final result = addAsOverlay([for (final a in assets) a.id], at: at);
        onPlaced?.call(result);
      },
    );
    return (run) async {
      try {
        return await base(run);
      } finally {
        controller.applyPoolChange(AddAssets(const []));
      }
    };
  }

  /// Places [media] as an overlay (see the file header); on success selects it and opens the
  /// Transform panel.
  EditResult? addAsOverlay(Iterable<MediaId> media, {TimeUs? at}) {
    final result = this.media.addAsOverlay(media, at: at);
    if (result is EditApplied) {
      final id = selected;
      if (id != null) controller.openInspector(TransformInspector(id));
    }
    return result;
  }
}

// -------------------------------------------------------------------------------------------------
// Handlers
// -------------------------------------------------------------------------------------------------

bool _canEdit(EditorActionContext ctx) => ctx.read(editorControllerProvider(ctx.projectId).notifier).canEdit;

String? _notOpen(EditorActionContext ctx) => OverlayStrings.notOpen;

void _openOverlay(EditorActionContext ctx) {
  ctx.read(editorControllerProvider(ctx.projectId).notifier).openInspector(const OverlayInspector());
}

ChromaInspector _chromaRoute(ItemId item) => ChromaInspector(item);

bool _chromaEnabled(EditorActionContext ctx) => _canEdit(ctx) && transformTarget(ctx, _chromaRoute, unlocked: true) != null;

String? _chromaReason(EditorActionContext ctx) {
  if (!_canEdit(ctx)) return OverlayStrings.notOpen;
  if (transformTarget(ctx, _chromaRoute) == null) return OverlayStrings.selectClip;
  return OverlayStrings.trackLocked;
}

void _openChroma(EditorActionContext ctx) {
  final item = transformTarget(ctx, _chromaRoute, unlocked: true);
  if (item == null) return;
  ctx.read(editorControllerProvider(ctx.projectId).notifier).openInspector(ChromaInspector(item));
}

bool _forwardEnabled(EditorActionContext ctx) => OverlayOperations.of(ctx).zBlocker(forward: true) == null;

bool _backwardEnabled(EditorActionContext ctx) => OverlayOperations.of(ctx).zBlocker(forward: false) == null;

String? _forwardReason(EditorActionContext ctx) => OverlayOperations.of(ctx).zBlocker(forward: true);

String? _backwardReason(EditorActionContext ctx) => OverlayOperations.of(ctx).zBlocker(forward: false);

void _move(EditorActionContext ctx, {required bool forward}) {
  final ops = OverlayOperations.of(ctx);
  final item = ops.selectedOverlay;
  if (item != null) ops.moveZ(item, forward: forward);
}

void _bringForward(EditorActionContext ctx) => _move(ctx, forward: true);

void _sendBackward(EditorActionContext ctx) => _move(ctx, forward: false);

/// The overlay actions bound by UX-28 (ARCH §17.6). The same instances on every read, so two merges
/// of the bindings compare equal (the wiring test relies on it).
List<EditorActionBinding> get overlayBindings => _overlayBindings;

final List<EditorActionBinding> _overlayBindings = List.unmodifiable(const <EditorActionBinding>[
  EditorActionBinding(id: EditorActionId.addOverlay, handler: _openOverlay, isEnabled: _canEdit, disabledReason: _notOpen),
  EditorActionBinding(id: EditorActionId.chromaKey, handler: _openChroma, isEnabled: _chromaEnabled, disabledReason: _chromaReason),
  EditorActionBinding(id: EditorActionId.bringForward, handler: _bringForward, isEnabled: _forwardEnabled, disabledReason: _forwardReason),
  EditorActionBinding(id: EditorActionId.sendBackward, handler: _sendBackward, isEnabled: _backwardEnabled, disabledReason: _backwardReason),
]);
