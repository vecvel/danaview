// OWNER: CORE-19
//
// Which media a Timeline references (clips and imported LUT looks). Used by the session for the
// "remove unused media" check and `retainedMedia()` (the GC guard of open sessions, ARCH §9.4).

import 'dart:collection';

import '../ids/ids.dart';
import '../model/items.dart';
import '../model/pool/media_asset.dart';
import '../model/pool/media_pool.dart';
import '../model/timeline.dart';
import '../model/track.dart';
import '../model/visual_props.dart';

/// Collects media ids referenced by Timelines, visiting each (shared) lane object once.
final class MediaRefCollector {
  final Set<Track> _seen = HashSet<Track>.identity();

  /// The ids collected so far.
  final Set<MediaId> ids = <MediaId>{};

  /// Adds every media id [timeline] references.
  void addTimeline(Timeline timeline) {
    for (final t in timeline.tracks) {
      if (!_seen.add(t)) continue;
      for (final item in t.items) {
        if (item is MediaClip) {
          ids.add(item.media);
          final look = item.visual?.look;
          if (look is ImportedLut) ids.add(look.lut);
        }
      }
    }
  }

  /// Adds the sources of derived assets (reverse, still) among the collected ids, looked up in
  /// [pool] and in [extra] asset values, transitively.
  void addDerivedSources(MediaPool pool, [Iterable<MediaAsset> extra = const []]) {
    final byId = <MediaId, MediaAsset>{for (final a in extra) a.id: a, ...pool.assets};
    final pending = [...ids];
    while (pending.isNotEmpty) {
      final source = switch (byId[pending.removeLast()]?.derived) {
        ReversedSpec(:final media) => media,
        StillSpec(:final media) => media,
        null => null,
      };
      if (source != null && ids.add(source)) pending.add(source);
    }
  }
}

/// The media ids [timeline] references (clip media and imported LUTs).
Set<MediaId> mediaReferencedBy(Timeline timeline) => (MediaRefCollector()..addTimeline(timeline)).ids;
