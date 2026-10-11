// OWNER: CORE-03
//
// The history-tracked subtree of a project (ARCH §6.1, §7.3): undo stores snapshots of this root.

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../time/time.dart';
import 'marker.dart';
import 'settings.dart';
import 'track.dart';

/// Settings, tracks and markers. Structurally shared between snapshots.
@immutable
final class Timeline {
  /// Creates a timeline. [tracks] must be in canonical order; [markers] sorted by time.
  Timeline({
    this.settings = const ProjectSettings(),
    List<Track> tracks = const [],
    List<Marker> markers = const [],
    this.revision = 0,
  })  : tracks = List.unmodifiable(tracks),
        markers = List.unmodifiable(markers);

  /// Project settings.
  final ProjectSettings settings;

  /// Tracks in canonical order (unmodifiable).
  final List<Track> tracks;

  /// Markers sorted by time (unmodifiable).
  final List<Marker> markers;

  /// Session-monotonic revision stamp; never reused, even across undo.
  final int revision;

  /// The main track (the first video track), or null when the timeline has no video lane.
  Track? get mainTrack => TrackOrder.mainTrack(tracks);

  /// End of the last item over all tracks (cached).
  late final TimeUs duration = _computeDuration();

  TimeUs _computeDuration() {
    var end = 0;
    for (final t in tracks) {
      if (t.items.isNotEmpty) {
        final last = t.items.last.end;
        if (last > end) end = last;
      }
    }
    return end;
  }

  /// A copy with the given fields replaced.
  Timeline copyWith({ProjectSettings? settings, List<Track>? tracks, List<Marker>? markers, int? revision}) =>
      Timeline(
        settings: settings ?? this.settings,
        tracks: tracks ?? this.tracks,
        markers: markers ?? this.markers,
        revision: revision ?? this.revision,
      );

  @override
  bool operator ==(Object other) =>
      other is Timeline &&
      other.settings == settings &&
      other.revision == revision &&
      const ListEquality<Track>().equals(other.tracks, tracks) &&
      const ListEquality<Marker>().equals(other.markers, markers);

  @override
  int get hashCode => Object.hash(settings, revision, Object.hashAll(tracks), Object.hashAll(markers));
}
