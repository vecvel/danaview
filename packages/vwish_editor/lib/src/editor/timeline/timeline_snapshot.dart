// OWNER: UX-10
//
// The timeline view model (ux.md §8.2, ARCH §17.4): an immutable TimelineSnapshot of the committed
// project in display order (D-09), with everything the painters and hit tests need precomputed per
// item (visual kind, label, badges, keyframe union, audio fades and volume) and per lane (cuts with
// their transitions, main-lane gaps).
//
// * TimelineSnapshotBuilder.build(project) reuses the previous LaneModel and ItemModel instances
//   whenever the domain Track/TimelineItem objects are `identical` (and the item's media state is
//   unchanged), so the cost is proportional to what changed: a split touches one lane. A lane's
//   `revision` bumps only when its model is rebuilt (tile invalidation for UX-43).
// * The snapshot follows the committed project: during an open transaction it keeps the committed
//   one (drag ghosts are drawn by the interaction layer, ux.md §8.7).
// * Keyframe times are item-local (as in the domain); `ItemModel.keyframeAt` converts.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vwish_editor_core/eval.dart' show speedTimeFactor;
import 'package:vwish_editor_core/model.dart';

import '../../app/editor_providers.dart' show editorControllerProvider, editorSessionProvider;
import '../state/editor_state.dart' show EditorState, MediaHealth;
import 'timeline_metrics.dart' show LaneHeightPreset;

// -------------------------------------------------------------------------------------------------
// Media
// -------------------------------------------------------------------------------------------------

/// What the timeline needs to know about one pool asset (ux.md §8.2).
@immutable
final class MediaVisual {
  /// Creates a media visual.
  const MediaVisual({
    required this.kind,
    this.displayName = '',
    this.hasVideo = false,
    this.hasAudio = false,
    this.offline = false,
    this.pending = false,
    this.proxyReady = false,
    this.aspect = 16 / 9,
    this.still = false,
  });

  /// A referenced asset that is not in the pool (drawn as missing).
  static const MediaVisual missing = MediaVisual(kind: MediaKind.video, offline: true);

  /// Builds the visual of [asset]; [offline] comes from the editor's media health.
  factory MediaVisual.of(MediaAsset asset, {bool offline = false}) {
    final p = asset.probe;
    final w = p.width, h = p.height;
    final swap = p.rotation % 180 != 0;
    final aspect = w != null && h != null && w > 0 && h > 0 ? (swap ? h / w : w / h) : 16 / 9;
    return MediaVisual(
      kind: asset.kind,
      displayName: asset.displayName,
      hasVideo: p.hasVideo,
      hasAudio: p.hasAudio,
      offline: offline || asset.status is FailedStatus,
      pending: asset.status is PendingStatus,
      proxyReady: asset.proxy == ProxyState.ready,
      aspect: aspect,
      still: asset.derived is StillSpec,
    );
  }

  /// Media kind.
  final MediaKind kind;

  /// File name shown as the clip label when the item has none.
  final String displayName;

  /// Whether the media has a video stream (or is an image).
  final bool hasVideo;

  /// Whether the media has an audio stream.
  final bool hasAudio;

  /// Whether the media is missing (offline, failed or not in the pool).
  final bool offline;

  /// Whether the media is still being made (reversed copy, freeze still).
  final bool pending;

  /// Whether a proxy is ready.
  final bool proxyReady;

  /// Display aspect (width / height, rotation applied).
  final double aspect;

  /// Whether the asset is a freeze-frame still.
  final bool still;

  @override
  bool operator ==(Object other) =>
      other is MediaVisual &&
      other.kind == kind &&
      other.displayName == displayName &&
      other.hasVideo == hasVideo &&
      other.hasAudio == hasAudio &&
      other.offline == offline &&
      other.pending == pending &&
      other.proxyReady == proxyReady &&
      other.aspect == aspect &&
      other.still == still;

  @override
  int get hashCode => Object.hash(kind, displayName, hasVideo, hasAudio, offline, pending, proxyReady, aspect, still);
}

// -------------------------------------------------------------------------------------------------
// Items
// -------------------------------------------------------------------------------------------------

/// How an item is drawn (ux.md §8.2).
enum ItemVisualKind {
  /// Video clip (thumbnail strip).
  video,

  /// Still image (one thumbnail repeated).
  image,

  /// Freeze frame (a still made from a video frame).
  freeze,

  /// Audio clip (waveform).
  audio,

  /// Text overlay (excerpt).
  text,

  /// Subtitle cue (excerpt).
  cue,
}

/// Badge bits of [ItemModel.badges] (ux.md §8.6 item 4), in the order they are painted.
abstract final class ItemBadges {
  /// Constant speed other than 1×.
  static const int speed = 1 << 0;

  /// Speed ramp.
  static const int ramp = 1 << 1;

  /// Reversed playback.
  static const int reversed = 1 << 2;

  /// Clip audio muted.
  static const int muted = 1 << 3;

  /// Detail effects (sharpness, blur, vignette).
  static const int fx = 1 << 4;

  /// Colour adjustments.
  static const int color = 1 << 5;

  /// A look or imported LUT.
  static const int lut = 1 << 6;

  /// Chroma key.
  static const int chroma = 1 << 7;

  /// Mask.
  static const int mask = 1 << 8;

  /// Keyframes.
  static const int keyframes = 1 << 9;

  /// Media still being made.
  static const int pending = 1 << 10;

  /// Freeze frame.
  static const int freeze = 1 << 11;

  /// Every bit in paint order.
  static const List<int> all = [speed, ramp, reversed, freeze, muted, fx, color, lut, chroma, mask, keyframes, pending];

  /// Number of set bits of [badges].
  static int count(int badges) {
    var n = 0;
    for (final b in all) {
      if (badges & b != 0) n++;
    }
    return n;
  }
}

/// One item of a lane (ux.md §8.2). Built by [TimelineSnapshotBuilder]; reused while its domain
/// item is identical.
@immutable
final class ItemModel {
  /// Creates an item model.
  ItemModel({
    required this.source,
    required this.kind,
    required this.label,
    this.media,
    this.visual,
    this.avgSpeed = 1,
    this.badges = 0,
    List<TimeUs> keyframeTimes = const [],
    List<String> keyframeProperties = const [],
    this.hasAudio = false,
    this.volume = 1,
    List<Keyframe> volumeKeys = const [],
    this.fadeIn = 0,
    this.fadeOut = 0,
  })  : assert(keyframeTimes.length == keyframeProperties.length),
        keyframeTimes = List.unmodifiable(keyframeTimes),
        keyframeProperties = List.unmodifiable(keyframeProperties),
        volumeKeys = List.unmodifiable(volumeKeys);

  /// The domain item this model was built from (identity is the reuse key).
  final TimelineItem source;

  /// How the item is drawn.
  final ItemVisualKind kind;

  /// The label: the item's label, else the media name, else the text.
  final String label;

  /// Media of a media clip.
  final MediaId? media;

  /// The media's visual state when this model was built.
  final MediaVisual? visual;

  /// Average speed (`1 / timeFactor`; 1 for non-media items).
  final double avgSpeed;

  /// [ItemBadges] bits.
  final int badges;

  /// Item-local times of every keyframe (union over properties), sorted, unique.
  final List<TimeUs> keyframeTimes;

  /// The property id of each [keyframeTimes] entry (the first, alphabetically, when several
  /// properties share the time).
  final List<String> keyframeProperties;

  /// Whether the item plays audio (audio clips, video clips with audio that is not detached).
  final bool hasAudio;

  /// Clip volume (linear, 0…2).
  final double volume;

  /// Volume keyframes (item-local), for the volume line.
  final List<Keyframe> volumeKeys;

  /// Audio fade-in length.
  final TimeUs fadeIn;

  /// Audio fade-out length.
  final TimeUs fadeOut;

  /// Item id.
  ItemId get id => source.id;

  /// Start on the timeline.
  TimeUs get start => source.start;

  /// End on the timeline (exclusive).
  TimeUs get end => source.end;

  /// Duration.
  TimeUs get duration => source.duration;

  /// Source in-point of a media clip (0 otherwise).
  TimeUs get sourceIn => switch (source) {
        MediaClip(:final sourceIn) => sourceIn,
        _ => 0,
      };

  /// Whether the media is missing.
  bool get offline => visual?.offline ?? false;

  /// Whether the media is still being made.
  bool get pending => badges & ItemBadges.pending != 0;

  /// Whether the item has keyframes.
  bool get hasKeyframes => keyframeTimes.isNotEmpty;

  /// Whether the item shows a thumbnail strip.
  bool get showsThumbnails => kind == ItemVisualKind.video || kind == ItemVisualKind.image || kind == ItemVisualKind.freeze;

  /// Whether the item is drawn with a text excerpt.
  bool get isTextLike => kind == ItemVisualKind.text || kind == ItemVisualKind.cue;

  /// The timeline time of keyframe [index].
  TimeUs keyframeAt(int index) => start + keyframeTimes[index];

  @override
  String toString() => 'ItemModel($id, $kind, $start..$end)';
}

// -------------------------------------------------------------------------------------------------
// Lanes
// -------------------------------------------------------------------------------------------------

/// A cut between two touching items of a video or overlay lane, with its transition if any.
@immutable
final class CutModel {
  /// Creates a cut.
  const CutModel({required this.ref, required this.at, required this.leftIndex, this.transition});

  /// Lane and the two items.
  final TransitionRef ref;

  /// Time of the cut (left end = right start).
  final TimeUs at;

  /// Index of the left item in the lane's items.
  final int leftIndex;

  /// The transition at this cut, or null (the "+" button on the main lane).
  final Transition? transition;

  /// Whether a transition exists.
  bool get hasTransition => transition != null;

  @override
  bool operator ==(Object other) =>
      other is CutModel && other.ref == ref && other.at == at && other.leftIndex == leftIndex && other.transition == transition;

  @override
  int get hashCode => Object.hash(ref, at, leftIndex, transition);
}

/// One lane of a snapshot (ux.md §8.2), display order.
@immutable
final class LaneModel {
  /// Creates a lane model.
  LaneModel({
    required this.source,
    required this.displayName,
    required this.height,
    required List<ItemModel> items,
    List<CutModel> cuts = const [],
    List<TimeRange> gaps = const [],
    required this.revision,
  })  : items = List.unmodifiable(items),
        cuts = List.unmodifiable(cuts),
        gaps = List.unmodifiable(gaps);

  /// The domain track (identity is the reuse key).
  final Track source;

  /// The track name, or a derived one ("Video 2", "Audio 1").
  final String displayName;

  /// Height preset.
  final LaneHeightPreset height;

  /// Items sorted by start, non-overlapping.
  final List<ItemModel> items;

  /// Cuts (touching neighbours) sorted by time; video and overlay lanes only.
  final List<CutModel> cuts;

  /// Empty spans of the main lane (from 0 to the last item), sorted; empty on other lanes.
  final List<TimeRange> gaps;

  /// Bumps only when this lane's model was rebuilt.
  final int revision;

  /// Track id.
  TrackId get id => source.id;

  /// Track kind.
  TrackKind get kind => source.kind;

  /// Track name as stored (may be empty).
  String get name => source.name;

  /// Whether this is the main lane.
  bool get isMain => source.isMain;

  /// Locked.
  bool get locked => source.locked;

  /// Hidden.
  bool get hidden => source.hidden;

  /// Muted.
  bool get muted => source.muted;

  /// Solo.
  bool get solo => source.solo;

  /// Audio role.
  AudioRole? get audioRole => source.audioRole;

  /// Index of the first item ending after [t] (binary search; `items.length` when none).
  int firstItemEndingAfter(TimeUs t) {
    var lo = 0, hi = items.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (items[mid].end <= t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// Index of the item containing [t], or null.
  int? itemIndexAt(TimeUs t) {
    final i = firstItemEndingAfter(t);
    return i < items.length && items[i].start <= t ? i : null;
  }

  /// Index of the first cut at or after [t].
  int firstCutFrom(TimeUs t) {
    var lo = 0, hi = cuts.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (cuts[mid].at < t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// The gap containing [t], or null.
  TimeRange? gapAt(TimeUs t) {
    for (final g in gaps) {
      if (g.contains(t)) return g;
      if (g.start > t) break;
    }
    return null;
  }

  @override
  String toString() => 'LaneModel($id, $kind, ${items.length} items, rev $revision)';
}

/// Where an item sits in a snapshot.
typedef ItemLocation = ({int lane, int index});

/// The timeline view model of the committed project (ux.md §8.2).
@immutable
final class TimelineSnapshot {
  /// Creates a snapshot.
  TimelineSnapshot({
    required this.revision,
    required this.frameRate,
    required this.duration,
    required List<LaneModel> lanes,
    this.markers = const [],
    this.media = const {},
  }) : lanes = List.unmodifiable(lanes);

  /// The snapshot of no project (editor opening).
  static final TimelineSnapshot empty = TimelineSnapshot(revision: 0, frameRate: FrameRate.fps30, duration: 0, lanes: const []);

  /// Bumps whenever a new snapshot instance is built.
  final int revision;

  /// Project frame rate.
  final FrameRate frameRate;

  /// End of the last item.
  final TimeUs duration;

  /// Lanes in display order, top to bottom (ux.md §8.3).
  final List<LaneModel> lanes;

  /// Markers sorted by time (the ruler paints them): the timeline's own unmodifiable list.
  final List<Marker> markers;

  /// Visual state of every pool asset (an unmodifiable map shared between snapshots while the pool
  /// and the media health are unchanged).
  final Map<MediaId, MediaVisual> media;

  /// Whether any lane is soloed.
  late final bool soloActive = lanes.any((l) => l.solo);

  late final Map<ItemId, ItemLocation> _locations = {
    for (var l = 0; l < lanes.length; l++)
      for (var i = 0; i < lanes[l].items.length; i++) lanes[l].items[i].id: (lane: l, index: i),
  };

  late final Map<TrackId, int> _laneIndex = {for (var l = 0; l < lanes.length; l++) lanes[l].id: l};

  /// Where item [id] sits, or null.
  ItemLocation? locate(ItemId id) => _locations[id];

  /// The model of item [id], or null.
  ItemModel? item(ItemId id) {
    final at = _locations[id];
    return at == null ? null : lanes[at.lane].items[at.index];
  }

  /// The lane holding item [id], or null.
  LaneModel? laneOf(ItemId id) {
    final at = _locations[id];
    return at == null ? null : lanes[at.lane];
  }

  /// Display index of lane [id], or null.
  int? laneIndexOf(TrackId id) => _laneIndex[id];

  /// The lane [id], or null.
  LaneModel? lane(TrackId id) {
    final i = _laneIndex[id];
    return i == null ? null : lanes[i];
  }

  /// Lane kinds in display order (for `TimelineLaneStack.of`).
  List<TrackKind> get laneKinds => [for (final l in lanes) l.kind];

  /// Lane height presets in display order.
  List<LaneHeightPreset> get laneHeights => [for (final l in lanes) l.height];

  @override
  String toString() => 'TimelineSnapshot(rev $revision, ${lanes.length} lanes, ${_locations.length} items)';
}

// -------------------------------------------------------------------------------------------------
// Builder
// -------------------------------------------------------------------------------------------------

/// Builds snapshots, reusing models of identical domain objects (ux.md §8.2).
class TimelineSnapshotBuilder {
  /// Creates a builder with no previous snapshot.
  TimelineSnapshotBuilder();

  TimelineSnapshot? _previous;
  int _revision = 0;
  int _laneRevision = 0;

  // Previous build's inputs.
  MediaPool? _pool;
  MediaHealth? _health;
  Map<MediaId, MediaVisual> _media = const {};
  final Map<TrackId, LaneModel> _lanes = {};
  EditProject? _lastProject;

  /// The last snapshot built (null before the first build).
  TimelineSnapshot? get previous => _previous;

  /// The project of the last [build] call.
  EditProject? get lastProject => _lastProject;

  /// Number of LaneModels built by the last [build] (tests and debug).
  int lastBuiltLanes = 0;

  /// Number of ItemModels built by the last [build] (tests and debug).
  int lastBuiltItems = 0;

  /// The snapshot of [project], with media availability from [health] and lanes at [laneHeight].
  /// Returns the previous snapshot instance when nothing it shows changed.
  TimelineSnapshot build(
    EditProject project, {
    MediaHealth health = MediaHealth.ok,
    LaneHeightPreset laneHeight = LaneHeightPreset.normal,
  }) {
    lastBuiltLanes = 0;
    lastBuiltItems = 0;
    final media = _mediaOf(project.pool, health);
    final timeline = project.timeline;
    final display = TrackOrder.displayOrder(timeline.tracks);
    final ordinals = _ordinals(timeline.tracks);

    final lanes = <LaneModel>[];
    final seen = <TrackId>{};
    for (final track in display) {
      final name = track.name.isNotEmpty ? track.name : _defaultName(track, ordinals[track.id] ?? 1);
      final lane = _lane(track, name, laneHeight, media, _lanes[track.id]);
      lanes.add(lane);
      seen.add(track.id);
      _lanes[track.id] = lane;
    }
    _lanes.removeWhere((id, _) => !seen.contains(id));

    final prev = _previous;
    final rate = timeline.settings.frameRate;
    _lastProject = project;
    if (prev != null &&
        prev.frameRate == rate &&
        prev.duration == timeline.duration &&
        identical(prev.media, media) &&
        (identical(prev.markers, timeline.markers) || listEquals(prev.markers, timeline.markers)) &&
        _allIdentical(prev.lanes, lanes)) {
      return prev;
    }
    final snapshot = TimelineSnapshot(
      revision: ++_revision,
      frameRate: rate,
      duration: timeline.duration,
      lanes: lanes,
      markers: timeline.markers,
      media: media,
    );
    return _previous = snapshot;
  }

  Map<MediaId, MediaVisual> _mediaOf(MediaPool pool, MediaHealth health) {
    if (identical(pool, _pool) && (identical(health, _health) || health == _health)) return _media;
    final next = <MediaId, MediaVisual>{};
    var changed = _media.length != pool.assets.length;
    for (final asset in pool.assets.values) {
      final v = MediaVisual.of(asset, offline: health.missing.contains(asset.id));
      final old = _media[asset.id];
      final keep = old != null && old == v ? old : v;
      if (!identical(keep, old)) changed = true;
      next[asset.id] = keep;
    }
    _pool = pool;
    _health = health;
    if (changed) _media = Map.unmodifiable(next);
    return _media;
  }

  static Map<TrackId, int> _ordinals(List<Track> tracks) {
    final counts = <TrackKind, int>{};
    return {
      for (final t in tracks) t.id: counts.update(t.kind, (n) => n + 1, ifAbsent: () => 1),
    };
  }

  static String _defaultName(Track track, int ordinal) => switch (track.kind) {
        TrackKind.video => track.isMain ? 'Main' : 'Video $ordinal',
        TrackKind.overlay => 'Overlay $ordinal',
        TrackKind.text => 'Text $ordinal',
        TrackKind.subtitle => 'Subtitles $ordinal',
        TrackKind.audio => switch (track.audioRole) {
            AudioRole.voice => 'Voice $ordinal',
            AudioRole.music => 'Music $ordinal',
            AudioRole.effects => 'Effects $ordinal',
            AudioRole.original || null => 'Audio $ordinal',
          },
      };

  LaneModel _lane(Track track, String name, LaneHeightPreset height, Map<MediaId, MediaVisual> media, LaneModel? prev) {
    bool visualOk(ItemModel m) {
      final id = m.media;
      return id == null || (media[id] ?? MediaVisual.missing) == m.visual;
    }

    if (prev != null && identical(prev.source, track) && prev.height == height && prev.displayName == name && prev.items.every(visualOk)) {
      return prev;
    }
    final prevItems = <ItemId, ItemModel>{
      if (prev != null)
        for (final m in prev.items) m.id: m,
    };
    final items = <ItemModel>[];
    for (final item in track.items) {
      final old = prevItems[item.id];
      final visual = item is MediaClip ? (media[item.media] ?? MediaVisual.missing) : null;
      items.add(old != null && identical(old.source, item) && old.visual == visual ? old : _item(item, track.kind, visual));
    }
    if (prev != null &&
        prev.height == height &&
        prev.displayName == name &&
        prev.kind == track.kind &&
        prev.isMain == track.isMain &&
        prev.locked == track.locked &&
        prev.hidden == track.hidden &&
        prev.muted == track.muted &&
        prev.solo == track.solo &&
        prev.audioRole == track.audioRole &&
        (identical(prev.source.transitions, track.transitions) || listEquals(prev.source.transitions, track.transitions)) &&
        _allIdentical(prev.items, items)) {
      // Only the track object changed (for example its `changedAt` stamp): keep the model.
      return prev;
    }
    lastBuiltLanes++;
    return LaneModel(
      source: track,
      displayName: name,
      height: height,
      items: items,
      cuts: _cuts(track, items),
      gaps: track.isMain ? _gaps(items) : const [],
      revision: ++_laneRevision,
    );
  }

  static bool _allIdentical(List<Object> a, List<Object> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  static List<CutModel> _cuts(Track track, List<ItemModel> items) {
    if (track.kind != TrackKind.video && track.kind != TrackKind.overlay) return const [];
    final byPair = <(ItemId, ItemId), Transition>{
      for (final t in track.transitions) (t.left, t.right): t,
    };
    return [
      for (var i = 0; i + 1 < items.length; i++)
        if (items[i].end == items[i + 1].start)
          CutModel(
            ref: TransitionRef(track.id, items[i].id, items[i + 1].id),
            at: items[i].end,
            leftIndex: i,
            transition: byPair[(items[i].id, items[i + 1].id)],
          ),
    ];
  }

  static List<TimeRange> _gaps(List<ItemModel> items) {
    final out = <TimeRange>[];
    var t = 0;
    for (final m in items) {
      if (m.start > t) out.add(TimeRange(t, m.start));
      if (m.end > t) t = m.end;
    }
    return out;
  }

  ItemModel _item(TimelineItem item, TrackKind laneKind, MediaVisual? visual) {
    lastBuiltItems++;
    switch (item) {
      case MediaClip():
        final v = visual ?? MediaVisual.missing;
        final kind = laneKind == TrackKind.audio || v.kind == MediaKind.audio
            ? ItemVisualKind.audio
            : v.still
                ? ItemVisualKind.freeze
                : v.kind == MediaKind.image
                    ? ItemVisualKind.image
                    : ItemVisualKind.video;
        final (times, props) = _keyframeUnion(item.keyframes);
        var badges = 0;
        final speed = item.speed;
        if (speed is SpeedRamp) {
          badges |= ItemBadges.ramp;
        } else if (speed is ConstantSpeed && speed.rate != 1) {
          badges |= ItemBadges.speed;
        }
        if (item.reversed) badges |= ItemBadges.reversed;
        if (kind == ItemVisualKind.freeze) badges |= ItemBadges.freeze;
        final hasAudio = kind == ItemVisualKind.audio || (v.hasAudio && !item.detachedAudio && kind == ItemVisualKind.video);
        if (item.audio.muted && hasAudio) badges |= ItemBadges.muted;
        final vis = item.visual;
        if (vis != null) {
          if (vis.detail != DetailFx.none) badges |= ItemBadges.fx;
          if (!vis.adjust.isNeutral) badges |= ItemBadges.color;
          if (vis.look != null) badges |= ItemBadges.lut;
          if (vis.chroma.enabled) badges |= ItemBadges.chroma;
          if (vis.mask.shape != MaskShape.none) badges |= ItemBadges.mask;
        }
        if (times.isNotEmpty) badges |= ItemBadges.keyframes;
        if (v.pending) badges |= ItemBadges.pending;
        final label = (item.label?.trim().isNotEmpty ?? false) ? item.label!.trim() : v.displayName;
        return ItemModel(
          source: item,
          kind: kind,
          label: label,
          media: item.media,
          visual: v,
          avgSpeed: 1 / speedTimeFactor(speed),
          badges: badges,
          keyframeTimes: times,
          keyframeProperties: props,
          hasAudio: hasAudio,
          volume: item.audio.volume,
          volumeKeys: item.keyframes[PropertyKeys.volume.id]?.keys ?? const [],
          fadeIn: hasAudio ? item.audio.fadeIn : 0,
          fadeOut: hasAudio ? item.audio.fadeOut : 0,
        );
      case TextItem():
        final (times, props) = _keyframeUnion(item.keyframes);
        return ItemModel(
          source: item,
          kind: ItemVisualKind.text,
          label: (item.label?.trim().isNotEmpty ?? false) ? item.label!.trim() : excerpt(item.text),
          badges: times.isNotEmpty ? ItemBadges.keyframes : 0,
          keyframeTimes: times,
          keyframeProperties: props,
        );
      case SubtitleCue():
        return ItemModel(source: item, kind: ItemVisualKind.cue, label: excerpt(item.text));
    }
  }

  /// The first non-empty line of [text], trimmed and shortened to 80 characters.
  static String excerpt(String text) {
    for (final line in text.split('\n')) {
      final t = line.trim();
      if (t.isNotEmpty) return t.length > 80 ? '${t.substring(0, 79)}…' : t;
    }
    return '';
  }

  /// The union of keyframe times over every channel (sorted, unique) and the property of each.
  static (List<TimeUs>, List<String>) _keyframeUnion(KeyframeSet set) {
    if (set.isEmpty) return (const [], const []);
    final byTime = <TimeUs, String>{};
    for (final entry in set.byChannel.entries) {
      final property = propertyOfChannel(entry.key);
      for (final k in entry.value.keys) {
        final existing = byTime[k.t];
        if (existing == null || property.compareTo(existing) < 0) byTime[k.t] = property;
      }
    }
    final times = byTime.keys.toList()..sort();
    return (times, [for (final t in times) byTime[t]!]);
  }

  /// The property id of keyframe channel [channel] (`transform.position.x` -> `transform.position`).
  static String propertyOfChannel(String channel) {
    if (PropertyKeys.lookup(channel) != null) return channel;
    final dot = channel.lastIndexOf('.');
    if (dot > 0) {
      final base = channel.substring(0, dot);
      if (PropertyKeys.lookup(base) != null) return base;
    }
    return channel;
  }
}

// -------------------------------------------------------------------------------------------------
// Provider
// -------------------------------------------------------------------------------------------------

/// What the snapshot provider watches in EditorState: the committed project (identity), the
/// media health and the lane height preset.
@immutable
final class _SnapshotInput {
  const _SnapshotInput(this.project, this.inTransaction, this.media, this.laneHeight);

  factory _SnapshotInput.of(EditorState s) =>
      _SnapshotInput(s.inTransaction ? null : s.project, s.inTransaction, s.media, s.modes.laneHeight);

  final EditProject? project;
  final bool inTransaction;
  final MediaHealth media;
  final LaneHeightPreset laneHeight;

  @override
  bool operator ==(Object other) =>
      other is _SnapshotInput &&
      identical(other.project, project) &&
      other.inTransaction == inTransaction &&
      other.media == media &&
      other.laneHeight == laneHeight;

  @override
  int get hashCode => Object.hash(identityHashCode(project), inTransaction, media, laneHeight);
}

final Expando<TimelineSnapshotBuilder> _builders = Expando('TimelineSnapshotBuilder');

/// Builds the value of `timelineSnapshotProvider` for [id]: the snapshot of the committed project
/// (the working copy of an open transaction is not shown; ghosts are), rebuilt incrementally on
/// every commit, media-health change and lane-height change. [TimelineSnapshot.empty] until the
/// project is open.
TimelineSnapshot buildTimelineSnapshot(Ref<Object?> ref, ProjectId id) {
  final builder = _builders[ref] ??= TimelineSnapshotBuilder();
  final input = ref.watch(editorControllerProvider(id).select(_SnapshotInput.of));
  var project = input.project;
  if (input.inTransaction) {
    project = ref.read(editorSessionProvider(id)).committedProject ?? builder.lastProject;
  }
  if (project == null) return builder.previous ?? TimelineSnapshot.empty;
  return builder.build(project, health: input.media, laneHeight: input.laneHeight);
}
