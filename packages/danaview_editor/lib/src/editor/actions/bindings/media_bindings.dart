// OWNER: UX-36
//
// The media action binding (merged by wiring/action_bindings.dart, ARCH §17.6, ux.md §10.1) and
// `MediaOperations`, the commands behind the media bin, the timeline drop target and external
// drops. `media` opens the Media panel; the context menu's "Add media here" seeks first, so the
// bin then adds at that time.
//
// * Everything goes through `EditorController.apply` (one history entry; refusals toast through the
//   controller) or `applyPoolEdit` (Remove from project: undoable, only for unused media).
// * Add at the playhead is `InsertMedia(mode: auto)`: a ripple insert on the main lane while ripple
//   is on, else the media lands at the playhead and goes to the nearest free lane (D-11). A visual
//   and an audio asset in one call become two `InsertMedia` commands inside one `CompositeCommand`
//   (core rejects a mixed list), so the whole add is one history entry.
// * Add as overlay puts visual media on the topmost overlay lane that is free over the clip's
//   range, creating a lane when there is none; the clips get the picture-in-picture default (40 %,
//   centre-right, ux.md §10.13). The lane creation and the insert are one history entry (the
//   second command coalesces into the first).
// * Replace uses `ReplaceMedia` on the primary selected clip; the reasons it is unavailable are
//   explained by `replaceBlocker` (no clip, locked lane, kind mismatch).
// * The timeline drop target builds its commands with `insertCommand` and previews them with the
//   session's `dryRun`, so what the ghost shows is what the drop commits.

import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderListenable;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:danaview_editor_core/store.dart' show ImportedMedia, ImportOutcome, MediaPoolService;

import '../../../app/editor_providers.dart';
import '../../../app/strings/media_strings.dart';
import '../../contracts/contracts.dart';
import '../../flows/import_media_sheet.dart';
import '../../state/editor_controller.dart';
import '../../state/editor_session.dart';
import '../../state/editor_state.dart';

/// Whether [kind] is placed on video and overlay lanes.
bool isVisualMediaKind(MediaKind kind) => kind == MediaKind.video || kind == MediaKind.image || kind == MediaKind.still;

/// Whether [kind] is placed on audio lanes.
bool isAudioMediaKind(MediaKind kind) => kind == MediaKind.audio || kind == MediaKind.recording;

/// Whether media of [kind] belongs on a lane of [lane] when the user chose that lane (a drop):
/// pictures on video and overlay lanes, sound on audio lanes.
bool laneAcceptsMedia(TrackKind lane, MediaKind kind) =>
    (isVisualMediaKind(kind) && (lane == TrackKind.video || lane == TrackKind.overlay)) ||
    (isAudioMediaKind(kind) && lane == TrackKind.audio);

/// How many clips use each asset (assets that are not used are absent).
Map<MediaId, int> mediaUsageOf(EditProject project) {
  final cached = _usageCache[project.timeline];
  if (cached != null) return cached;
  final counts = <MediaId, int>{};
  for (final track in project.timeline.tracks) {
    for (final item in track.items) {
      if (item is MediaClip) counts[item.media] = (counts[item.media] ?? 0) + 1;
    }
  }
  return _usageCache[project.timeline] = Map.unmodifiable(counts);
}

final Expando<Map<MediaId, int>> _usageCache = Expando<Map<MediaId, int>>('mediaUsage');

/// The picture-in-picture placement of a new overlay (ux.md §10.13): 40 % of the canvas, centred
/// vertically on the right.
const VisualProps pictureInPictureDefault = VisualProps(transform: Transform2D(position: Vec2(0.28, 0), scale: 0.4));

/// The commands behind the media bin, drop target and external drops (see the file header).
final class MediaOperations {
  /// Creates the operations over [controller]; [state] reads the editor state, [playhead] the
  /// playhead, [session] dry-runs commands.
  MediaOperations({
    required this.controller,
    required EditorState Function() state,
    required TimeUs Function() playhead,
    required this.session,
  })  : _state = state,
        _playhead = playhead;

  /// The operations of the action context's project.
  factory MediaOperations.of(EditorActionContext ctx) => MediaOperations.forProject(ctx.projectId, ctx.read);

  /// The operations of project [id], reading providers with [read].
  factory MediaOperations.forProject(ProjectId id, T Function<T>(ProviderListenable<T> provider) read) => MediaOperations(
        controller: read(editorControllerProvider(id).notifier),
        state: () => read(editorControllerProvider(id)),
        playhead: () => read(playheadProvider(id)).value,
        session: read(editorSessionProvider(id)),
      );

  /// The project's controller.
  final EditorController controller;

  /// The open session (dry runs).
  final EditorSession session;

  final EditorState Function() _state;
  final TimeUs Function() _playhead;

  EditorState get _s => _state();

  /// The current project, or null when it is not open.
  EditProject? get project => _s.project;

  /// Whether the project accepts edits.
  bool get canEdit => controller.canEdit && project != null;

  /// Whether the project was opened read-only (D-12): edits stay in memory and nothing is saved, so
  /// imports (which copy files into the editor's storage) are not offered.
  bool get readOnly => controller.readOnly;

  /// The playhead.
  TimeUs get playhead => _playhead();

  /// The pool assets of [media] that can go on the timeline, in the order given (LUTs, failed and
  /// unknown assets are left out).
  List<MediaAsset> placeable(Iterable<MediaId> media) {
    final pool = project?.pool;
    if (pool == null) return const [];
    return [
      for (final id in media)
        if (pool[id] case final asset? when asset.kind != MediaKind.lut && asset.status is! FailedStatus) asset,
    ];
  }

  // ---- Insert -----------------------------------------------------------------------------------

  /// The command that adds [media] back to back at [at] (default: the playhead), or null when
  /// nothing of it can be placed. [lane] is the lane the user chose (a drop): it takes the media
  /// that belongs on it, the rest goes to its default lane. Visual and audio media become two
  /// `InsertMedia` commands in one composite (one history entry).
  EditCommand? insertCommand(Iterable<MediaId> media, {TimeUs? at, TrackId? lane, InsertMode mode = InsertMode.auto}) {
    final p = project;
    if (p == null) return null;
    final assets = placeable(media);
    if (assets.isEmpty) return null;
    final t = _quantized(p, at ?? _playhead());
    TrackKind? laneKind;
    if (lane != null) {
      for (final track in p.timeline.tracks) {
        if (track.id == lane) laneKind = track.kind;
      }
    }
    final visual = [
      for (final a in assets)
        if (isVisualMediaKind(a.kind)) a.id
    ];
    final audio = [
      for (final a in assets)
        if (isAudioMediaKind(a.kind)) a.id
    ];
    TrackId? laneFor(bool visualGroup) =>
        lane != null && laneKind != null && laneAcceptsMedia(laneKind, visualGroup ? MediaKind.video : MediaKind.audio) ? lane : null;
    final commands = <EditCommand>[
      if (visual.isNotEmpty) InsertMedia(visual, t, track: laneFor(true), mode: mode),
      if (audio.isNotEmpty) InsertMedia(audio, t, track: laneFor(false), mode: mode),
    ];
    if (commands.isEmpty) return null;
    return commands.length == 1 ? commands.single : CompositeCommand(assets.length == 1 ? 'Add clip' : 'Add clips', commands);
  }

  /// What [insertCommand] would do, without doing it (the drop ghost); a rejected preview when
  /// there is nothing to place.
  EditPreview preview(EditCommand command) => session.dryRun(command);

  /// Adds [media] at the playhead (see the file header).
  EditResult? addAtPlayhead(Iterable<MediaId> media) => insertAt(media);

  /// Adds [media] at [at] (default: the playhead) on [lane] (default lanes when null).
  EditResult? insertAt(Iterable<MediaId> media, {TimeUs? at, TrackId? lane}) {
    final command = insertCommand(media, at: at, lane: lane);
    return command == null ? null : controller.apply(command);
  }

  /// Adds the visual media of [media] as a picture-in-picture overlay at [at] (default: the
  /// playhead) on the topmost free overlay lane, creating one when needed.
  EditResult? addAsOverlay(Iterable<MediaId> media, {TimeUs? at}) {
    final p = project;
    if (p == null) return null;
    final visual = [
      for (final a in placeable(media))
        if (isVisualMediaKind(a.kind)) a.id
    ];
    if (visual.isEmpty) return null;
    final t = _quantized(p, at ?? _playhead());
    const key = 'media.overlay';
    // The topmost overlay lane (highest index first) that takes the clips in place.
    final overlays = [
      for (final track in p.timeline.tracks)
        if (track.kind == TrackKind.overlay && !track.locked) track
    ];
    for (final lane in overlays.reversed) {
      final command = InsertMedia(visual, t, track: lane.id, mode: InsertMode.newLane);
      final preview = session.dryRun(command);
      if (preview.isRejected || preview.placements.isEmpty) continue;
      if (preview.placements.values.any((pl) => pl.track != lane.id || pl.onNewTrack)) continue;
      return _insertOverlay(command, key);
    }
    // No overlay lane is free there: make one and place the clips on it, as one entry.
    final before = {for (final track in p.timeline.tracks) track.id};
    final added = controller.apply(const AddTrack(TrackKind.overlay), coalesceKey: key);
    if (added is! EditApplied) return added;
    final now = project;
    TrackId? created;
    if (now != null) {
      for (final track in now.timeline.tracks) {
        if (track.kind == TrackKind.overlay && !before.contains(track.id)) created = track.id;
      }
    }
    if (created == null) return added;
    return _insertOverlay(InsertMedia(visual, t, track: created, mode: InsertMode.newLane), key);
  }

  EditResult _insertOverlay(InsertMedia command, String key) {
    final result = controller.apply(command, coalesceKey: key);
    if (result is! EditApplied) return result;
    final placed = _state().selection.items;
    if (placed.isNotEmpty) controller.apply(SetVisual(placed, pictureInPictureDefault), coalesceKey: key);
    return result;
  }

  // ---- Replace ----------------------------------------------------------------------------------

  /// The primary selected clip, or null.
  MediaClip? get selectedClip {
    final p = project;
    final id = _s.selection.primary;
    if (p == null || id == null) return null;
    final loc = p.index.locate(id);
    final item = loc?.item;
    return item is MediaClip ? item : null;
  }

  /// Why [asset] can't replace the selected clip's media, or null when it can.
  String? replaceBlocker(MediaAsset asset) {
    final p = project;
    if (p == null || !controller.canEdit) return MediaStrings.notEditable;
    final clip = selectedClip;
    if (clip == null) return MediaStrings.replaceNeedsClip;
    final loc = p.index.locate(clip.id);
    if (loc == null) return MediaStrings.replaceNeedsClip;
    if (loc.track.locked) return MediaStrings.replaceLocked;
    if (asset.status is FailedStatus) return MediaStrings.assetFailed;
    if (asset.kind == MediaKind.lut) return MediaStrings.lutNotPlaceable;
    final fits = switch (loc.track.kind) {
      TrackKind.video || TrackKind.overlay => isVisualMediaKind(asset.kind),
      TrackKind.audio => isAudioMediaKind(asset.kind) || (asset.kind == MediaKind.video && asset.probe.hasAudio),
      _ => false,
    };
    return fits ? null : MediaStrings.replaceKindMismatch;
  }

  /// Replaces the media of the selected clip with [media] (effects, transform and range are kept).
  EditResult? replaceSelected(MediaId media) {
    final clip = selectedClip;
    if (clip == null) return null;
    return controller.apply(ReplaceMedia(clip.id, media));
  }

  // ---- Remove -----------------------------------------------------------------------------------

  /// Why [media] can't be removed from the project, or null when it can (it is unused).
  String? removeBlocker(MediaId media) {
    final p = project;
    if (p == null || !controller.canEdit) return MediaStrings.notEditable;
    if ((mediaUsageOf(p)[media] ?? 0) > 0) return MediaStrings.removeInUse;
    return null;
  }

  /// Removes [media] from the pool as one undoable entry (only while nothing uses it).
  EditResult? remove(MediaId media) {
    if (removeBlocker(media) != null) return null;
    return controller.applyPoolEdit(RemoveAssets({media}), label: MediaStrings.remove);
  }

  // ---- Import -----------------------------------------------------------------------------------

  /// The import job of the Media tool and external drops: copies [pool]'s way into [edit], then
  /// (when [place]) adds what was imported at [at] (default: the playhead) on [lane]. Items added
  /// before a cancel stay in the bin and are placed. The controller's state follows the pool when
  /// the job ends, whatever happened.
  ImportJob importJob({required MediaPoolService pool, required EditSession edit, bool place = true, TimeUs? at, TrackId? lane}) {
    final base = sessionImportJob(
      pool: pool,
      session: edit,
      place: (outcomes) {
        final assets = [
          for (final o in outcomes)
            if (o is ImportedMedia) o.asset
        ];
        controller.applyPoolChange(AddAssets(assets));
        if (!place) return;
        final command = insertCommand([for (final a in assets) a.id], at: at, lane: lane);
        if (command != null) controller.apply(command);
      },
    );
    return (run) async {
      try {
        return await base(run);
      } finally {
        // Imports are sticky pool changes made on the core session: refresh the editor's state.
        controller.applyPoolChange(AddAssets(const []));
      }
    };
  }

  TimeUs _quantized(EditProject p, TimeUs t) {
    final q = p.settings.frameRate.quantizeNearest(t);
    return q < 0 ? 0 : q;
  }

  /// Outcomes of an import as the assets that were added.
  static List<MediaAsset> assetsOf(Iterable<ImportOutcome> outcomes) => [
        for (final o in outcomes)
          if (o is ImportedMedia) o.asset
      ];
}

// -------------------------------------------------------------------------------------------------
// Handlers
// -------------------------------------------------------------------------------------------------

bool _isReady(EditorActionContext ctx) => ctx.read(editorControllerProvider(ctx.projectId)).isReady;

String? _notReady(EditorActionContext ctx) => MediaStrings.notEditable;

void _openMedia(EditorActionContext ctx) {
  ctx.read(editorControllerProvider(ctx.projectId).notifier).openInspector(const MediaInspector());
}

/// The media actions bound by UX-36 (ARCH §17.6): `media` opens the Media panel. The same
/// instances on every read.
List<EditorActionBinding> get mediaBindings => _mediaBindings;

final List<EditorActionBinding> _mediaBindings = List.unmodifiable(const <EditorActionBinding>[
  EditorActionBinding(id: EditorActionId.media, handler: _openMedia, isEnabled: _isReady, disabledReason: _notReady),
]);
