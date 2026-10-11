// OWNER: CORE-05
//
// `evaluate<T>(item, key, t)` (ux.md §2.1, ARCH §6.7): the keyframed value of a property at
// item-local time [t], or its static value when the channel has no keys. Linear interpolation,
// held before the first and after the last key, rotation in plain degrees (no wrapping), Vec2
// properties from their `.x` and `.y` channels. Keys outside `[0, item.duration)` are kept in the
// model but ignored here. The one implementation used by the preview overlay, handles and the
// compiler.

import '../model/keyframes/keyframe_data.dart';
import '../model/keyframes/keyframe_ops.dart';
import '../model/keyframes/property_keys.dart';
import '../model/items.dart';
import '../model/visual_props.dart';
import '../time/time.dart';

/// The value of [track] at item-local [t] for an item of [duration], or null when the track has
/// no key inside `[0, duration)`.
double? evaluateTrack(KeyframeTrack track, TimeUs t, {required TimeUs duration}) =>
    valueAtLocalTime(track.keys, t, duration);

/// The value of [key] on [item] at item-local time [t] (µs from the item's start).
///
/// Non-keyframable keys, keys without tracks, and channels whose keys all lie outside the item's
/// range return the static value ([PropertyKey.read]). Throws [ArgumentError] when [key] does not
/// apply to [item].
T evaluate<T>(TimelineItem item, PropertyKey<T> key, TimeUs t) {
  final base = key.read(item);
  if (!key.keyframable) return base;
  final keyframes = keyframesOf(item);
  if (keyframes.isEmpty) return base;
  final channels = key.channels;
  if (channels.length == 1) {
    final track = keyframes[channels[0]];
    if (track == null) return base;
    final v = evaluateTrack(track, t, duration: item.duration);
    return v == null ? base : v as T;
  }
  // Vec2: x and y evaluate independently; a missing channel keeps its static component.
  final b = base as Vec2;
  final tx = keyframes[channels[0]];
  final ty = keyframes[channels[1]];
  final x = tx == null ? null : evaluateTrack(tx, t, duration: item.duration);
  final y = ty == null ? null : evaluateTrack(ty, t, duration: item.duration);
  if (x == null && y == null) return base;
  return Vec2(x ?? b.x, y ?? b.y) as T;
}

/// Whether [key] has at least one key in [item]'s keyframes (including keys outside the range).
bool isAnimated(TimelineItem item, PropertyKey<Object?> key) => KeyframeOps.isAnimated(keyframesOf(item), key);
