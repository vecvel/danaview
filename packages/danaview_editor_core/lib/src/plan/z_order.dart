// OWNER: CORE-30
//
// Z order and compositing bands of the RenderPlan (ARCH §11.4, D-05, D-09):
//
//   z = band·10000 + (laneIndexInBand + 1)·10 + sub
//
// * bands bottom → top: video 0 (the main lane is the lowest), overlay 1, text 2, subtitle 3;
// * `laneIndexInBand` counts the lanes of the same kind in canonical track order, hidden lanes
//   included, so hiding or showing a lane never moves the others (stable ids and z for diffs);
// * `sub` is 0 for clip layers, +5 for transition helper solids (`#tx`) and −5 for blurred
//   backdrops (`#bd`).
//
// Examples: the main lane is 10 and its backdrop 5; the first overlay lane 10010; the first text
// lane 20010; the first subtitle track 30010. Engines treat `z` as an opaque sort key; within one
// `z` a later `t0` draws on top. `laneZ` in `eval/visual_packing.dart` (CORE-36) computes the same
// clip z for the packing inputs; a test pins the two together.

import 'package:meta/meta.dart';

import '../model/track.dart';

/// The z formula of ARCH §11.4 and its constants.
abstract final class PlanZ {
  /// Distance between two bands.
  static const int bandStride = 10000;

  /// Distance between two lanes of one band.
  static const int laneStride = 10;

  /// `sub` of clip, text and cue layers.
  static const int clipSub = 0;

  /// `sub` of transition helper solids (`#tx`, CORE-31).
  static const int transitionHelperSub = 5;

  /// `sub` of blurred backdrops (`#bd`).
  static const int backdropSub = -5;

  /// Lanes a band can hold before its z values would reach the next band.
  static const int maxLanesPerBand = bandStride ~/ laneStride - 1;

  /// Band of the video lanes.
  static const int videoBand = 0;

  /// Band of the overlay lanes.
  static const int overlayBand = 1;

  /// Band of the text lanes.
  static const int textBand = 2;

  /// Band of the subtitle lanes.
  static const int subtitleBand = 3;

  /// `band·10000 + (laneIndexInBand + 1)·10 + sub`.
  ///
  /// Throws [RangeError] when [band] is not 0…3, [laneIndexInBand] is negative or not below
  /// [maxLanesPerBand], or [sub] is outside −5…5.
  static int of({required int band, required int laneIndexInBand, int sub = clipSub}) {
    RangeError.checkValueInInterval(band, videoBand, subtitleBand, 'band');
    RangeError.checkValueInInterval(laneIndexInBand, 0, maxLanesPerBand - 1, 'laneIndexInBand');
    RangeError.checkValueInInterval(sub, backdropSub, transitionHelperSub, 'sub');
    return band * bandStride + (laneIndexInBand + 1) * laneStride + sub;
  }

  /// The clip-layer z of the [laneIndexInBand]-th lane of [kind]. Throws [ArgumentError] for
  /// audio lanes, which have no z.
  static int lane(TrackKind kind, int laneIndexInBand) {
    final band = kind.band;
    if (band == null) throw ArgumentError.value(kind, 'kind', 'audio lanes have no z');
    return of(band: band, laneIndexInBand: laneIndexInBand);
  }

  /// The z of the blurred backdrops of a lane whose clip layers sit at [laneZ].
  static int backdrop(int laneZ) => laneZ + backdropSub;

  /// The z of the transition helper solids of a lane whose clip layers sit at [laneZ].
  static int transitionHelper(int laneZ) => laneZ + transitionHelperSub;

  /// The band a plan `z` belongs to (0 video … 3 subtitle).
  static int bandOf(int z) => z ~/ bandStride;
}

/// One visual lane of a project with its plan z (ARCH §11.4).
@immutable
final class PlanLane {
  /// Creates a lane record.
  const PlanLane({required this.track, required this.band, required this.laneIndexInBand, required this.z});

  /// The track.
  final Track track;

  /// Compositing band (0 video, 1 overlay, 2 text, 3 subtitle).
  final int band;

  /// Index among the lanes of the same kind, in canonical order (hidden lanes included).
  final int laneIndexInBand;

  /// z of the lane's clip layers.
  final int z;

  /// Whether the lane is the main lane (the first video lane).
  bool get isMain => track.isMain;

  /// Whether the lane contributes no visual layers (`hidden`, ARCH §11.7).
  bool get hidden => track.hidden;

  /// z of this lane's `#bd` backdrops.
  int get backdropZ => PlanZ.backdrop(z);

  /// z of this lane's `#tx` transition helper solids.
  int get transitionHelperZ => PlanZ.transitionHelper(z);

  @override
  bool operator ==(Object other) =>
      other is PlanLane &&
      identical(other.track, track) &&
      other.band == band &&
      other.laneIndexInBand == laneIndexInBand &&
      other.z == z;

  @override
  int get hashCode => Object.hash(track.id, band, laneIndexInBand, z);

  @override
  String toString() => 'PlanLane(${track.id}, band $band, lane $laneIndexInBand, z $z)';
}

/// The visual lanes of [tracks] (every kind except audio) bottom → top with their z: lanes keep
/// canonical order, and each kind counts its own lanes from 0 (hidden lanes included, so hiding a
/// lane never changes another lane's z).
List<PlanLane> planLanesOf(List<Track> tracks) {
  final counts = <TrackKind, int>{};
  final out = <PlanLane>[];
  for (final t in tracks) {
    final band = t.kind.band;
    if (band == null) continue;
    final index = counts[t.kind] ?? 0;
    counts[t.kind] = index + 1;
    out.add(PlanLane(track: t, band: band, laneIndexInBand: index, z: PlanZ.of(band: band, laneIndexInBand: index)));
  }
  return out;
}
