// OWNER: CORE-11
//
// The in-app clipboard (ARCH §7.2, domain.md §6.8, ux.md §14.4): `copyItems` turns a selection
// into a self-contained `ClipboardPayload` — the items (with their lanes' kinds and roles and
// their offsets from the earliest start), the transitions between copied clips, and every pool
// asset the items reference (media, imported LUTs, the sources of derived assets and the reversed
// renditions reversed clips use) — so `PasteItems` can paste into another project, adding the
// missing assets to its pool exactly once and minting fresh ids.
//
// Cut is copy + `DeleteItems` in one `CompositeCommand` labelled "Cut" (D-16, [cutItems]).
// The payload is an in-memory value (the UX clipboard holds it; it is never written to disk and
// never touches the system clipboard).

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../ids/ids.dart';
import '../model/items.dart';
import '../model/pool/media_asset.dart';
import '../model/project.dart';
import '../model/track.dart';
import '../model/transition.dart';
import '../model/visual_props.dart';
import '../time/time.dart';
import 'edit_command.dart';

/// A source lane of a [ClipboardPayload]: its kind and audio role.
@immutable
final class ClipboardLane {
  /// Creates a lane description.
  const ClipboardLane({required this.kind, this.role, this.sourceTrack});

  /// Lane kind.
  final TrackKind kind;

  /// Audio role of an audio lane (a paste that creates an audio lane gives it this role).
  final AudioRole? role;

  /// The lane the items were copied from (in the source project).
  final TrackId? sourceTrack;

  @override
  bool operator ==(Object other) =>
      other is ClipboardLane && other.kind == kind && other.role == role && other.sourceTrack == sourceTrack;

  @override
  int get hashCode => Object.hash(kind, role, sourceTrack);
}

/// One copied item: the item as it was (original ids and times), its lane and its offset.
@immutable
final class ClipboardItem {
  /// Creates a copied item.
  const ClipboardItem({required this.item, required this.lane, required this.offset});

  /// The item as copied.
  final TimelineItem item;

  /// Index of its lane in [ClipboardPayload.lanes].
  final int lane;

  /// `item.start − anchor` (µs on the source project's grid).
  final TimeUs offset;

  @override
  bool operator ==(Object other) =>
      other is ClipboardItem && other.item == item && other.lane == lane && other.offset == offset;

  @override
  int get hashCode => Object.hash(item, lane, offset);
}

/// A copied transition between two copied clips of lane [lane].
@immutable
final class ClipboardTransition {
  /// Creates a copied transition.
  const ClipboardTransition({required this.lane, required this.transition});

  /// Index of the lane in [ClipboardPayload.lanes].
  final int lane;

  /// The transition as copied (original ids).
  final Transition transition;

  @override
  bool operator ==(Object other) => other is ClipboardTransition && other.lane == lane && other.transition == transition;

  @override
  int get hashCode => Object.hash(lane, transition);
}

/// A self-contained copy of timeline items (ARCH §7.2 `copyItems`).
@immutable
final class ClipboardPayload {
  /// Creates a payload.
  ClipboardPayload({
    this.schema = currentSchema,
    required this.source,
    required this.rate,
    required this.anchor,
    required List<ClipboardLane> lanes,
    required List<ClipboardItem> items,
    List<ClipboardTransition> transitions = const [],
    Map<MediaId, MediaAsset> media = const {},
  })  : lanes = List.unmodifiable(lanes),
        items = List.unmodifiable(items),
        transitions = List.unmodifiable(transitions),
        media = Map.unmodifiable(media);

  /// The payload format version.
  static const int currentSchema = 1;

  /// Format version.
  final int schema;

  /// The project the items were copied from.
  final ProjectId source;

  /// The source project's frame rate (offsets and lengths are on its grid; a paste into a project
  /// of another rate re-quantizes them).
  final FrameRate rate;

  /// The earliest start of the copied items.
  final TimeUs anchor;

  /// Source lanes, in source canonical order.
  final List<ClipboardLane> lanes;

  /// Copied items, by lane then time.
  final List<ClipboardItem> items;

  /// Transitions between copied clips.
  final List<ClipboardTransition> transitions;

  /// Every pool asset the items reference, by their source ids.
  final Map<MediaId, MediaAsset> media;

  /// Whether nothing was copied.
  bool get isEmpty => items.isEmpty;

  /// Ids of the copied items (source ids).
  Set<ItemId> get itemIds => {for (final i in items) i.item.id};

  /// From the earliest start to the latest end of the copied items.
  TimeUs get extent {
    var end = 0;
    for (final i in items) {
      final e = i.offset + i.item.duration;
      if (e > end) end = e;
    }
    return end;
  }

  @override
  bool operator ==(Object other) =>
      other is ClipboardPayload &&
      other.schema == schema &&
      other.source == source &&
      other.rate == rate &&
      other.anchor == anchor &&
      const ListEquality<ClipboardLane>().equals(other.lanes, lanes) &&
      const ListEquality<ClipboardItem>().equals(other.items, items) &&
      const ListEquality<ClipboardTransition>().equals(other.transitions, transitions) &&
      const MapEquality<MediaId, MediaAsset>().equals(other.media, media);

  @override
  int get hashCode => Object.hash(schema, source, rate, anchor, Object.hashAll(lanes), Object.hashAll(items),
      Object.hashAll(transitions), const MapEquality<MediaId, MediaAsset>().hash(media));
}

/// Copies [ids] of [project] (pure). Link partners are copied with their items (links duplicate
/// together); unknown ids are ignored. Items on locked lanes may be copied (copying is
/// read-only). Returns an empty payload when nothing is found.
ClipboardPayload copyItems(EditProject project, Set<ItemId> ids) {
  final index = project.index;
  final wanted = <ItemId>{};
  Map<LinkId, List<ItemId>>? groups;
  for (final id in ids) {
    final item = index.item(id);
    if (item == null) continue;
    wanted.add(id);
    final link = item.link;
    if (link != null) {
      groups ??= _linkGroups(project);
      wanted.addAll(groups[link] ?? const []);
    }
  }
  final rate = project.settings.frameRate;
  if (wanted.isEmpty) {
    return ClipboardPayload(source: project.id, rate: rate, anchor: 0, lanes: const [], items: const []);
  }
  var anchor = maxProjectDurationUs;
  for (final id in wanted) {
    final s = index.item(id)!.start;
    if (s < anchor) anchor = s;
  }
  final lanes = <ClipboardLane>[];
  final items = <ClipboardItem>[];
  final transitions = <ClipboardTransition>[];
  for (final track in project.tracks) {
    final copied = [for (final i in track.items) if (wanted.contains(i.id)) i];
    if (copied.isEmpty) continue;
    final lane = lanes.length;
    lanes.add(ClipboardLane(kind: track.kind, role: track.audioRole, sourceTrack: track.id));
    for (final i in copied) {
      items.add(ClipboardItem(item: i, lane: lane, offset: i.start - anchor));
    }
    for (final tr in track.transitions) {
      if (wanted.contains(tr.left) && wanted.contains(tr.right)) {
        transitions.add(ClipboardTransition(lane: lane, transition: tr));
      }
    }
  }
  return ClipboardPayload(
    source: project.id,
    rate: rate,
    anchor: anchor,
    lanes: lanes,
    items: items,
    transitions: transitions,
    media: _referencedMedia(project, items),
  );
}

/// Cut (D-16): the payload of [ids] plus the command that deletes them, one `CompositeCommand`
/// labelled "Cut" (one history entry). [ripple] closes the gaps (ripple delete).
({ClipboardPayload payload, EditCommand command}) cutItems(EditProject project, Set<ItemId> ids, {bool ripple = false}) {
  final payload = copyItems(project, ids);
  return (
    payload: payload,
    command: CompositeCommand('Cut', [DeleteItems(payload.itemIds, ripple: ripple)]),
  );
}

Map<LinkId, List<ItemId>> _linkGroups(EditProject project) {
  final m = <LinkId, List<ItemId>>{};
  for (final t in project.tracks) {
    for (final i in t.items) {
      final l = i.link;
      if (l != null) (m[l] ??= <ItemId>[]).add(i.id);
    }
  }
  return m;
}

/// The pool assets [items] need, closed over derived sources and reversed renditions.
Map<MediaId, MediaAsset> _referencedMedia(EditProject project, List<ClipboardItem> items) {
  final pool = project.pool;
  final out = <MediaId, MediaAsset>{};
  final reversedSources = <MediaId>{};
  void add(MediaId id) {
    if (out.containsKey(id)) return;
    final asset = pool[id];
    if (asset == null) return;
    out[id] = asset;
    switch (asset.derived) {
      case ReversedSpec(:final media):
        add(media);
      case StillSpec(:final media):
        add(media);
      case null:
        break;
    }
  }

  for (final ci in items) {
    final item = ci.item;
    if (item is! MediaClip) continue;
    add(item.media);
    if (item.reversed) reversedSources.add(item.media);
    final look = item.visual?.look;
    if (look is ImportedLut) add(look.lut);
  }
  if (reversedSources.isNotEmpty) {
    for (final asset in pool.assets.values) {
      final d = asset.derived;
      if (d is ReversedSpec && reversedSources.contains(d.media)) add(asset.id);
    }
  }
  return out;
}
