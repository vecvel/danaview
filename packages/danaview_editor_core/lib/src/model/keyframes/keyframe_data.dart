// OWNER: CORE-03
//
// Keyframe data types (ARCH §6.7). The PropertyKey registry and evaluation are CORE-05.

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../../ids/ids.dart';
import '../../time/time.dart';

/// One key: value [v] at item-local time [t] (on the project grid). Interpolation is linear.
@immutable
final class Keyframe {
  /// Creates a key.
  const Keyframe(this.t, this.v);

  /// Item-local time in µs.
  final TimeUs t;

  /// Value in model units (see the property's `PropertyKey`).
  final double v;

  /// A copy with the given fields replaced.
  Keyframe copyWith({TimeUs? t, double? v}) => Keyframe(t ?? this.t, v ?? this.v);

  @override
  bool operator ==(Object other) => other is Keyframe && other.t == t && other.v == v;

  @override
  int get hashCode => Object.hash(t, v);

  @override
  String toString() => 'Keyframe($t, $v)';
}

/// Keys of one channel, sorted by time with unique times (≥ 1 key).
@immutable
final class KeyframeTrack {
  /// Creates a track; [keys] must be sorted with unique `t`.
  KeyframeTrack(List<Keyframe> keys) : keys = List.unmodifiable(keys);

  /// Keys (unmodifiable).
  final List<Keyframe> keys;

  /// A copy with the given keys.
  KeyframeTrack copyWith({List<Keyframe>? keys}) => KeyframeTrack(keys ?? this.keys);

  @override
  bool operator ==(Object other) =>
      other is KeyframeTrack && const ListEquality<Keyframe>().equals(other.keys, keys);

  @override
  int get hashCode => Object.hashAll(keys);
}

/// Keyframe tracks of an item by channel id (`transform.position.x`, `adjust.exposure`,
/// `audio.volume`, …). Vec2 properties write both channels at the same time.
@immutable
final class KeyframeSet {
  /// Creates a set (the map is copied and made unmodifiable).
  KeyframeSet(Map<String, KeyframeTrack> byChannel) : byChannel = Map.unmodifiable(byChannel);

  const KeyframeSet._empty() : byChannel = const {};

  /// No keyframes.
  static const KeyframeSet empty = KeyframeSet._empty();

  /// Tracks by channel id.
  final Map<String, KeyframeTrack> byChannel;

  /// Whether no channel has keys.
  bool get isEmpty => byChannel.isEmpty;

  /// A copy with the given channel map.
  KeyframeSet copyWith({Map<String, KeyframeTrack>? byChannel}) =>
      byChannel == null ? this : (byChannel.isEmpty ? KeyframeSet.empty : KeyframeSet(byChannel));

  /// The track of [channel], if any.
  KeyframeTrack? operator [](String channel) => byChannel[channel];

  @override
  bool operator ==(Object other) =>
      other is KeyframeSet && const MapEquality<String, KeyframeTrack>().equals(other.byChannel, byChannel);

  @override
  int get hashCode => const MapEquality<String, KeyframeTrack>().hash(byChannel);
}

/// Addresses one key of one property of one item (UI selection of keyframe diamonds).
@immutable
final class KeyframeRef {
  /// Creates a reference.
  const KeyframeRef(this.item, this.property, this.t);

  /// Item.
  final ItemId item;

  /// PropertyKey id (e.g. `transform.position`).
  final String property;

  /// Item-local time of the key.
  final TimeUs t;

  /// A copy with the given fields replaced.
  KeyframeRef copyWith({ItemId? item, String? property, TimeUs? t}) =>
      KeyframeRef(item ?? this.item, property ?? this.property, t ?? this.t);

  @override
  bool operator ==(Object other) =>
      other is KeyframeRef && other.item == item && other.property == property && other.t == t;

  @override
  int get hashCode => Object.hash(item, property, t);
}
