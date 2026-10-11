// OWNER: CORE-03
//
// Speed of a media clip (ARCH §6.4, D-15). The time map itself is CORE-06 (eval/clip_time_map.dart).

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

const Object _keep = Object();

/// Lowest supported speed (0.1×).
const double minClipSpeed = 0.1;

/// Highest supported speed (10×).
const double maxClipSpeed = 10;

/// The owner's speed presets.
const List<double> speedPresets = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4];

/// Speed of a clip: constant or a ramp.
@immutable
sealed class SpeedSpec {
  const SpeedSpec();

  /// Normal speed.
  static const SpeedSpec normal = ConstantSpeed(1);
}

/// A constant rate in [[minClipSpeed], [maxClipSpeed]].
final class ConstantSpeed extends SpeedSpec {
  /// Creates a constant speed.
  const ConstantSpeed(this.rate);

  /// Playback rate (1 = normal).
  final double rate;

  /// A copy with the given rate.
  ConstantSpeed copyWith({double? rate}) => ConstantSpeed(rate ?? this.rate);

  @override
  bool operator ==(Object other) => other is ConstantSpeed && other.rate == rate;

  @override
  int get hashCode => rate.hashCode;

  @override
  String toString() => 'ConstantSpeed($rate)';
}

/// One point of a speed ramp: speed [y] at normalized **source** position [x].
@immutable
final class SpeedPoint {
  /// Creates a ramp point.
  const SpeedPoint(this.x, this.y);

  /// Normalized source position in [0, 1].
  final double x;

  /// Speed in [[minClipSpeed], [maxClipSpeed]].
  final double y;

  /// A copy with the given fields replaced.
  SpeedPoint copyWith({double? x, double? y}) => SpeedPoint(x ?? this.x, y ?? this.y);

  @override
  bool operator ==(Object other) => other is SpeedPoint && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);
}

/// A speed ramp: 2–16 points with strictly increasing x from 0 to 1, linear speed between points.
final class SpeedRamp extends SpeedSpec {
  /// Creates a ramp.
  SpeedRamp(List<SpeedPoint> points, {this.presetId}) : points = List.unmodifiable(points);

  /// Ramp points (unmodifiable).
  final List<SpeedPoint> points;

  /// `montage | hero | bullet | jumpCut | flashIn | flashOut`, or null for a custom curve.
  final String? presetId;

  /// A copy with the given fields replaced; pass `presetId: null` to mark the curve custom.
  SpeedRamp copyWith({List<SpeedPoint>? points, Object? presetId = _keep}) => SpeedRamp(
        points ?? this.points,
        presetId: identical(presetId, _keep) ? this.presetId : presetId as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is SpeedRamp && other.presetId == presetId && const ListEquality<SpeedPoint>().equals(other.points, points);

  @override
  int get hashCode => Object.hash(presetId, Object.hashAll(points));
}
