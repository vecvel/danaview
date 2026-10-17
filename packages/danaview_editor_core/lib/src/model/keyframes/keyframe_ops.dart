// OWNER: CORE-05
//
// Keyframe operations (ARCH §6.7, domain.md §4.11). Keys are item-local, sorted and unique per
// channel, and stay attached to content:
//
// * a start trim of Δ shifts them by −Δ ([KeyframeOps.shift]);
// * a speed change scales them by `oldDuration / newDuration` ([KeyframeOps.scale]);
// * a split partitions them and inserts boundary keys holding the interpolated value so both
//   halves evaluate exactly like the original at every frame ([KeyframeOps.partition]);
// * keys outside `[0, duration)` are **kept** (un-trim restores them) and **ignored by
//   evaluation** (`evaluate` in eval/evaluate.dart, [valueAtLocalTime] here).
//
// Interpolation is linear, held before the first and after the last in-range key; rotation is
// plain degrees (no wrap). All functions are pure and return new values.
//
// **Time convention.** An item-local key time is `T − item.start` for the absolute frame time
// `T = timeOfFrame(k)` it was authored at. Subtracting grid times is exact, so shifting by a start
// trim or by a split point keeps every key at `T − newStart`; the local times are within 1 µs of
// multiples of the frame length, never snapped to them (platform times differ by the same 1 µs,
// D-35, so nothing downstream can tell). Operations that must pick new frames (speed change,
// boundary keys) take the item's start (`itemStart`, default 0) to snap in absolute time.

import '../../time/time.dart';
import '../items.dart';
import '../visual_props.dart';
import 'keyframe_data.dart';
import 'property_keys.dart';

/// The keyframes of [item] (empty for subtitle cues, which are not animatable).
KeyframeSet keyframesOf(TimelineItem item) => switch (item) {
      MediaClip(:final keyframes) => keyframes,
      TextItem(:final keyframes) => keyframes,
      SubtitleCue() => KeyframeSet.empty,
    };

/// [item] with its keyframes replaced. Throws [ArgumentError] for subtitle cues.
TimelineItem withKeyframes(TimelineItem item, KeyframeSet keyframes) => switch (item) {
      MediaClip() => item.copyWith(keyframes: keyframes),
      TextItem() => item.copyWith(keyframes: keyframes),
      SubtitleCue() => throw ArgumentError.value(item.runtimeType, 'item', 'subtitle cues have no keyframes'),
    };

/// The value of [keys] (sorted, unique times) at item-local [t], using only the keys inside
/// `[0, duration)`: linear between keys, held before the first and after the last. Returns null
/// when no key lies inside the range (the channel is inert).
double? valueAtLocalTime(List<Keyframe> keys, TimeUs t, TimeUs duration) {
  // First in-range key: smallest index with key.t >= 0; one past the last: first key.t >= duration.
  final lo = _lowerBound(keys, 0);
  final hi = _lowerBound(keys, duration); // exclusive
  if (lo >= hi) return null;
  final first = keys[lo];
  if (t <= first.t) return first.v;
  final last = keys[hi - 1];
  if (t >= last.t) return last.v;
  // first.t < t < last.t: find the segment [a, b] with a.t <= t < b.t by binary search.
  var a = lo;
  var b = hi - 1;
  while (b - a > 1) {
    final mid = (a + b) >> 1;
    if (keys[mid].t <= t) {
      a = mid;
    } else {
      b = mid;
    }
  }
  final k0 = keys[a];
  final k1 = keys[b];
  if (t == k0.t) return k0.v;
  return k0.v + (k1.v - k0.v) * ((t - k0.t) / (k1.t - k0.t));
}

/// Index of the first key with `key.t >= t` (keys sorted by time).
int _lowerBound(List<Keyframe> keys, TimeUs t) {
  var lo = 0;
  var hi = keys.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (keys[mid].t < t) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

/// Pure operations on [KeyframeSet]s.
abstract final class KeyframeOps {
  /// Moves every key of every channel by [delta] µs. A start trim that moves the item start by Δ
  /// calls `shift(set, -Δ)` (exact under the time convention above); keys that fall before 0 are
  /// kept and the operation is exactly reversible.
  static KeyframeSet shift(KeyframeSet set, TimeUs delta) {
    if (delta == 0 || set.isEmpty) return set;
    return _mapTracks(set, (keys) => [for (final k in keys) Keyframe(k.t + delta, k.v)]);
  }

  /// Scales every key time by `newDuration / oldDuration` (a speed change keeps keys on their
  /// content) and rounds each to the nearest frame of [rate] (in absolute time: the new key time
  /// is `timeOfFrame(k) − itemStart` for the nearest frame to `itemStart + scaled`). Keys that
  /// collapse onto the same frame keep the **later** key's value. Keys outside the old range
  /// scale too.
  static KeyframeSet scale(
    KeyframeSet set, {
    required TimeUs oldDuration,
    required TimeUs newDuration,
    required FrameRate rate,
    TimeUs itemStart = 0,
  }) {
    if (set.isEmpty || oldDuration == newDuration) return set;
    if (oldDuration <= 0 || newDuration <= 0) {
      throw ArgumentError('durations must be positive (old $oldDuration, new $newDuration)');
    }
    final factor = newDuration / oldDuration;
    return _mapTracks(set, (keys) {
      final byTime = <TimeUs, double>{};
      for (final k in keys) {
        byTime[rate.quantizeNearest(itemStart + (k.t * factor).round()) - itemStart] = k.v;
      }
      return [for (final e in byTime.entries) Keyframe(e.key, e.value)];
    });
  }

  /// Splits the keys of an item of [duration] that starts at [itemStart] at item-local time [at]
  /// (`itemStart + at` on the grid of [rate], `0 < at < duration`) into the keys of the left half (times unchanged) and of the right half
  /// (times shifted by `−at`).
  ///
  /// Boundary keys carry the interpolated value so that both halves evaluate like the original at
  /// every frame: the left half gets a key on its last frame when the original continues toward a
  /// key at or after [at]; the right half gets a key at 0 when an earlier in-range key exists and
  /// none sits exactly on [at]. Keys outside the original range stay on the side they fall on.
  static ({KeyframeSet left, KeyframeSet right}) partition(
    KeyframeSet set, {
    required TimeUs at,
    required TimeUs duration,
    required FrameRate rate,
    TimeUs itemStart = 0,
  }) {
    if (at <= 0 || at >= duration) {
      throw RangeError.range(at, 1, duration - 1, 'at', 'split time must lie inside the item');
    }
    if (set.isEmpty) return (left: set, right: set);
    // Local time of the last frame of the left half (the frame before the cut).
    final lastLeft = rate.quantize(itemStart + at - 1) - itemStart;
    final left = <String, KeyframeTrack>{};
    final right = <String, KeyframeTrack>{};
    for (final e in set.byChannel.entries) {
      final keys = e.value.keys;
      final leftKeys = <Keyframe>[for (final k in keys) if (k.t < at) k];
      final rightKeys = <Keyframe>[for (final k in keys) if (k.t >= at) Keyframe(k.t - at, k.v)];
      final inRange = [for (final k in keys) if (k.t >= 0 && k.t < duration) k];
      if (inRange.isNotEmpty) {
        final hasInRangeBefore = inRange.any((k) => k.t < at);
        final hasInRangeFrom = inRange.any((k) => k.t >= at);
        if (hasInRangeFrom && !leftKeys.any((k) => k.t == lastLeft)) {
          final v = valueAtLocalTime(keys, lastLeft, duration)!;
          leftKeys
            ..add(Keyframe(lastLeft, v))
            ..sort((a, b) => a.t.compareTo(b.t));
        }
        if (hasInRangeBefore && !rightKeys.any((k) => k.t == 0)) {
          final v = valueAtLocalTime(keys, at, duration)!;
          rightKeys.insert(0, Keyframe(0, v));
        }
      }
      if (leftKeys.isNotEmpty) left[e.key] = KeyframeTrack(leftKeys);
      if (rightKeys.isNotEmpty) right[e.key] = KeyframeTrack(rightKeys);
    }
    return (left: _build(left), right: _build(right));
  }

  /// Sets the key of [property] at item-local [t] to [value] on every channel of the property
  /// (both channels for Vec2), replacing an existing key at [t]. Throws [ArgumentError] when the
  /// property is not keyframable or [value] has the wrong type.
  static KeyframeSet setKey(KeyframeSet set, PropertyKey<Object?> property, TimeUs t, Object value) {
    final values = channelValues(property, value);
    final out = Map<String, KeyframeTrack>.of(set.byChannel);
    for (var i = 0; i < values.length; i++) {
      final channel = property.channels[i];
      out[channel] = _withKey(out[channel], Keyframe(t, values[i]));
    }
    return _build(out);
  }

  /// Removes the key of [property] at [t] from every channel. A channel left without keys is
  /// dropped, which makes the property static again. Missing keys are ignored.
  static KeyframeSet removeKey(KeyframeSet set, PropertyKey<Object?> property, TimeUs t) {
    _requireKeyframable(property);
    final out = Map<String, KeyframeTrack>.of(set.byChannel);
    for (final channel in property.channels) {
      final track = out[channel];
      if (track == null) continue;
      final keys = [for (final k in track.keys) if (k.t != t) k];
      if (keys.isEmpty) {
        out.remove(channel);
      } else {
        out[channel] = KeyframeTrack(keys);
      }
    }
    return _build(out);
  }

  /// Moves the key of [property] from [from] to [to] on every channel. A key already at [to] is
  /// replaced. Throws [StateError] when no channel has a key at [from].
  static KeyframeSet moveKey(KeyframeSet set, PropertyKey<Object?> property, TimeUs from, TimeUs to) {
    _requireKeyframable(property);
    if (from == to) return set;
    final out = Map<String, KeyframeTrack>.of(set.byChannel);
    var moved = false;
    for (final channel in property.channels) {
      final track = out[channel];
      if (track == null) continue;
      Keyframe? key;
      for (final k in track.keys) {
        if (k.t == from) key = k;
      }
      if (key == null) continue;
      moved = true;
      final without = KeyframeTrack([for (final k in track.keys) if (k.t != from) k]);
      out[channel] = _withKey(without.keys.isEmpty ? null : without, Keyframe(to, key.v));
    }
    if (!moved) throw StateError('property "${property.id}" has no key at $from');
    return _build(out);
  }

  /// Removes every channel of [property], making it static.
  static KeyframeSet clear(KeyframeSet set, PropertyKey<Object?> property) {
    _requireKeyframable(property);
    final out = Map<String, KeyframeTrack>.of(set.byChannel);
    for (final channel in property.channels) {
      out.remove(channel);
    }
    return _build(out);
  }

  /// Whether any channel of [property] has a key.
  static bool isAnimated(KeyframeSet set, PropertyKey<Object?> property) =>
      property.channels.any((c) => set.byChannel[c] != null);

  /// Whether any channel of [property] has a key exactly at [t].
  static bool hasKeyAt(KeyframeSet set, PropertyKey<Object?> property, TimeUs t) {
    for (final c in property.channels) {
      final track = set.byChannel[c];
      if (track != null && track.keys.any((k) => k.t == t)) return true;
    }
    return false;
  }

  /// The sorted distinct times of every key of [property] (all channels merged), including keys
  /// outside the item's range.
  static List<TimeUs> keyTimes(KeyframeSet set, PropertyKey<Object?> property) {
    final times = <TimeUs>{};
    for (final c in property.channels) {
      final track = set.byChannel[c];
      if (track != null) times.addAll(track.keys.map((k) => k.t));
    }
    return times.toList()..sort();
  }

  /// The per-channel numbers of [value] for [property]: one for scalars, `[x, y]` for Vec2.
  /// Throws [ArgumentError] when the property is not keyframable or [value] has the wrong type.
  static List<double> channelValues(PropertyKey<Object?> property, Object value) {
    _requireKeyframable(property);
    if (property.channels.length == 2) {
      if (value is! Vec2) throw ArgumentError.value(value, 'value', '"${property.id}" takes a Vec2');
      return [value.x, value.y];
    }
    if (value is! num) throw ArgumentError.value(value, 'value', '"${property.id}" takes a number');
    return [value.toDouble()];
  }

  static void _requireKeyframable(PropertyKey<Object?> property) {
    if (!property.keyframable) {
      throw ArgumentError.value(property.id, 'property', 'is not keyframable');
    }
  }

  static KeyframeSet _mapTracks(KeyframeSet set, List<Keyframe> Function(List<Keyframe>) f) {
    final out = <String, KeyframeTrack>{};
    for (final e in set.byChannel.entries) {
      final keys = f(e.value.keys);
      if (keys.isNotEmpty) out[e.key] = KeyframeTrack(keys);
    }
    return _build(out);
  }

  static KeyframeTrack _withKey(KeyframeTrack? track, Keyframe key) {
    final keys = [if (track != null) for (final k in track.keys) if (k.t != key.t) k, key]..sort((a, b) => a.t.compareTo(b.t));
    return KeyframeTrack(keys);
  }

  static KeyframeSet _build(Map<String, KeyframeTrack> byChannel) =>
      byChannel.isEmpty ? KeyframeSet.empty : KeyframeSet(byChannel);
}
