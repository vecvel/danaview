// OWNER: CORE-03
//
// Transitions between touching clips on video/overlay lanes (ARCH §6.6, D-16). Lowered to layers
// by the compiler (CORE-31); engines never see transition kinds (D-01).

import 'package:meta/meta.dart';

import '../ids/ids.dart';

/// The seven owner transitions.
enum TransitionKind {
  /// Outgoing fades to the canvas background, then incoming fades in (no overlap).
  fade,

  /// Overlapping blend using handles.
  crossDissolve,

  /// Through a black solid.
  dipToBlack,

  /// Through a white solid.
  dipToWhite,

  /// Incoming pushes the outgoing along a direction (uses handles).
  slide,

  /// A moving edge reveals the incoming (uses handles).
  wipe,

  /// Zoom in or out between the clips (uses handles).
  zoom;

  /// Whether this kind overlaps the clips and therefore needs handles (ARCH §7.2).
  bool get needsHandles => this == crossDissolve || this == slide || this == wipe || this == zoom;
}

/// Direction of a slide/wipe (`left|right|up|down`) or a zoom (`zoomIn|zoomOut`).
enum TransitionDirection {
  /// Toward the left.
  left,

  /// Toward the right.
  right,

  /// Upward.
  up,

  /// Downward.
  down,

  /// Zoom in.
  zoomIn,

  /// Zoom out.
  zoomOut,
}

/// A transition centred on the cut between [left] and [right]:
/// `[cut − ⌊n/2⌋ frames, cut + ⌈n/2⌉ frames)` where n = [durationFrames].
@immutable
final class Transition {
  /// Creates a transition.
  const Transition({
    required this.id,
    required this.left,
    required this.right,
    required this.kind,
    required this.durationFrames,
    this.direction,
  });

  /// Stable id.
  final TransitionId id;

  /// Outgoing item (its end touches [right]'s start).
  final ItemId left;

  /// Incoming item.
  final ItemId right;

  /// Kind.
  final TransitionKind kind;

  /// Length in project frames (≥ 1, ≤ `TransitionLimits.of`).
  final int durationFrames;

  /// Direction for slide/wipe/zoom; null for the others.
  final TransitionDirection? direction;

  /// A copy with the given fields replaced.
  Transition copyWith({TransitionKind? kind, int? durationFrames, TransitionDirection? direction}) => Transition(
        id: id,
        left: left,
        right: right,
        kind: kind ?? this.kind,
        durationFrames: durationFrames ?? this.durationFrames,
        direction: direction ?? this.direction,
      );

  @override
  bool operator ==(Object other) =>
      other is Transition &&
      other.id == id &&
      other.left == left &&
      other.right == right &&
      other.kind == kind &&
      other.durationFrames == durationFrames &&
      other.direction == direction;

  @override
  int get hashCode => Object.hash(id, left, right, kind, durationFrames, direction);
}

/// Addresses the cut between two items on a track (used by transition commands and the UI).
@immutable
final class TransitionRef {
  /// Creates a reference to the cut [left] | [right] on [track].
  const TransitionRef(this.track, this.left, this.right);

  /// Track holding both items.
  final TrackId track;

  /// Outgoing item.
  final ItemId left;

  /// Incoming item.
  final ItemId right;

  /// A copy with the given fields replaced.
  TransitionRef copyWith({TrackId? track, ItemId? left, ItemId? right}) =>
      TransitionRef(track ?? this.track, left ?? this.left, right ?? this.right);

  @override
  bool operator ==(Object other) =>
      other is TransitionRef && other.track == track && other.left == left && other.right == right;

  @override
  int get hashCode => Object.hash(track, left, right);
}
