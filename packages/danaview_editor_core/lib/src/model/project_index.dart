// OWNER: CORE-03
//
// Id lookups over one timeline snapshot (built lazily once per `EditProject`).

import 'package:meta/meta.dart';

import '../ids/ids.dart';
import 'items.dart';
import 'timeline.dart';
import 'track.dart';

/// Where an item lives: its track and its position in the track's item list.
@immutable
final class ItemLocation {
  /// Creates a location.
  const ItemLocation(this.track, this.trackIndex, this.itemIndex, this.item);

  /// The containing track.
  final Track track;

  /// Index of [track] in `Timeline.tracks`.
  final int trackIndex;

  /// Index of [item] in `track.items`.
  final int itemIndex;

  /// The item.
  final TimelineItem item;
}

/// O(1) lookups by id for one immutable [Timeline].
final class ProjectIndex {
  ProjectIndex._(this._tracks, this._items);

  /// Builds the index for [timeline].
  factory ProjectIndex.build(Timeline timeline) {
    final tracks = <TrackId, int>{};
    final items = <ItemId, ItemLocation>{};
    for (var ti = 0; ti < timeline.tracks.length; ti++) {
      final track = timeline.tracks[ti];
      tracks[track.id] = ti;
      for (var ii = 0; ii < track.items.length; ii++) {
        final item = track.items[ii];
        items[item.id] = ItemLocation(track, ti, ii, item);
      }
    }
    return ProjectIndex._(tracks, items);
  }

  final Map<TrackId, int> _tracks;
  final Map<ItemId, ItemLocation> _items;

  /// Index of the track with [id] in `Timeline.tracks`, or null.
  int? trackIndexOf(TrackId id) => _tracks[id];

  /// Location of the item with [id], or null.
  ItemLocation? locate(ItemId id) => _items[id];

  /// The item with [id], or null.
  TimelineItem? item(ItemId id) => _items[id]?.item;

  /// Number of items over all tracks.
  int get itemCount => _items.length;
}
