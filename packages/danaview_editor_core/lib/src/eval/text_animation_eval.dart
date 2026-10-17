// OWNER: CORE-07
//
// Text in/out animations (ARCH §6.6, §11.7, domain.md §4.8): the **one** implementation used by
// the preview overlay (UX-19), the boxes ([boxAt]) and the export compiler (CORE-31), so the
// preview and the rendered sprite agree by construction.
//
// Shape: ease-out cubic `e(x) = 1 − (1 − x)³` sampled at 6 linear segments. The 7 samples sit at
// integer breakpoint times `start + round(inDuration·j/6)` (in) and `end − round(outDuration·j/6)`
// (out, mirrored), and the progress is linear in time between them, so a plan channel made of the
// values at [textAnimationBreakpoints] (linear between keys, ARCH §11.1) reproduces
// [evaluateTextAnimation] exactly at every time.
//
// * fade: opacity = p;
// * slide: offset (1 − p)·10%·min(W, H) from/toward the direction, plus fade;
// * scale: scale 0.6 + 0.4·p, plus fade;
// * typewriter (in only): reveals `floor(n·x)` grapheme clusters at a constant rate over the in
//   duration (`x` linear, no easing, no fade), matching the plan's linear `reveal` channel
//   `0 → n` over the in-duration with floor applied (ARCH §11.2, §11.7);
// * out animations mirror the in curve in reverse (p goes 1 → 0 over the last outDuration).
//
// When `inDuration + outDuration` exceeds the item duration (after a trim) both are scaled down
// proportionally ([textAnimationSpans]) so the phases never overlap.

import 'package:meta/meta.dart';

import '../model/items.dart';
import '../model/settings.dart';
import '../model/text_style.dart';
import '../time/time.dart';
import 'geometry.dart';
import 'text_layout_spec.dart';

/// Number of linear segments the ease-out cubic is sampled at.
const int textEaseSegments = 6;

/// Slide distance as a fraction of `min(W, H)`.
const double textSlideFraction = 0.1;

/// Scale at the start of a scale-in (and the end of a scale-out).
const double textScaleFrom = 0.6;

/// `1 − (1 − x)³` for x in [0, 1] (clamped).
double easeOutCubic(double x) {
  final c = x <= 0 ? 0.0 : (x >= 1 ? 1.0 : x);
  final r = 1 - c;
  return 1 - r * r * r;
}

/// The eased value at sample [j] of [textEaseSegments] (`e(j/6)`; exactly 0 at j = 0 and 1 at
/// j = 6).
double easeSample(int j) {
  if (j <= 0) return 0;
  if (j >= textEaseSegments) return 1;
  return easeOutCubic(j / textEaseSegments);
}

/// The text animation state of an item at one time: multipliers and an offset applied on top of
/// the item's (keyframed) transform.
@immutable
final class TextAnimState {
  /// Creates a state.
  const TextAnimState({this.opacity = 1, this.offset = Offset2.zero, this.scale = 1, this.reveal, this.revealCount});

  /// No animation in effect.
  static const TextAnimState identity = TextAnimState();

  /// Opacity multiplier in [0, 1].
  final double opacity;

  /// Offset in canvas px added to the item's centre.
  final Offset2 offset;

  /// Scale multiplier.
  final double scale;

  /// Typewriter only: the continuous reveal value `n·x` (the plan's `reveal` channel value), or
  /// null when the item has no typewriter animation.
  final double? reveal;

  /// Typewriter only: grapheme clusters shown, `floor(n·x)` computed exactly, or null when every
  /// cluster is shown (no typewriter).
  final int? revealCount;

  @override
  bool operator ==(Object other) =>
      other is TextAnimState &&
      other.opacity == opacity &&
      other.offset == offset &&
      other.scale == scale &&
      other.reveal == reveal &&
      other.revealCount == revealCount;

  @override
  int get hashCode => Object.hash(opacity, offset, scale, reveal, revealCount);

  @override
  String toString() => 'TextAnimState(opacity: $opacity, offset: $offset, scale: $scale, reveal: $reveal/$revealCount)';
}

/// The effective in and out durations of [item]'s animation: 0 for `none` (and for a typewriter
/// out, which is not supported), negative values as 0, and both scaled down proportionally
/// (`in' = ⌊D·in/(in + out)⌋`, `out' = D − in'`) when they exceed the item duration D.
({TimeUs inDuration, TimeUs outDuration}) textAnimationSpans(TextItem item) {
  final a = item.animation;
  var inD = a.inKind == TextAnimKind.none || a.inDuration <= 0 ? 0 : a.inDuration;
  var outD = a.outKind == TextAnimKind.none || a.outKind == TextAnimKind.typewriter || a.outDuration <= 0
      ? 0
      : a.outDuration;
  final d = item.duration < 0 ? 0 : item.duration;
  if (inD + outD > d) {
    final total = inD + outD;
    inD = (d * inD) ~/ total;
    outD = outD == 0 ? 0 : d - inD;
  }
  return (inDuration: inD, outDuration: outD);
}

/// Item-local breakpoint `j` (0…6) of an in phase of length [span]: `round(span·j/6)`.
TimeUs _inPoint(TimeUs span, int j) => (span * j + textEaseSegments ~/ 2) ~/ textEaseSegments;

/// The eased progress over a phase whose 7 sample times are `at(j)` (ascending in j), at time
/// [x] (same units): linear between samples, `e(j/6)` exactly at `at(j)`.
double _progress(TimeUs x, TimeUs Function(int j) at) {
  if (x <= at(0)) return 0;
  if (x >= at(textEaseSegments)) return 1;
  var j = 0;
  while (j < textEaseSegments - 1 && at(j + 1) <= x) {
    j++;
  }
  final t0 = at(j);
  final t1 = at(j + 1);
  final e0 = easeSample(j);
  if (x == t0) return e0;
  final e1 = easeSample(j + 1);
  return e0 + (e1 - e0) * ((x - t0) / (t1 - t0));
}

/// The unit vector of a slide [direction] (y down): left (−1, 0), right (1, 0), up (0, −1),
/// down (0, 1).
Offset2 slideVector(TextSlideDirection direction) => switch (direction) {
      TextSlideDirection.left => const Offset2(-1, 0),
      TextSlideDirection.right => const Offset2(1, 0),
      TextSlideDirection.up => const Offset2(0, -1),
      TextSlideDirection.down => const Offset2(0, 1),
    };

/// The state of [item]'s in/out animation at timeline time [t] (absolute µs; clamped to the item)
/// on [canvas] (ARCH §6.6). Returns [TextAnimState.identity] outside both phases.
TextAnimState evaluateTextAnimation(TextItem item, TimeUs t, CanvasSpec canvas) {
  final spans = textAnimationSpans(item);
  final d = item.duration;
  var local = t - item.start;
  if (local < 0) local = 0;
  if (local > d) local = d;
  final a = item.animation;
  final inD = spans.inDuration;
  final outD = spans.outDuration;
  if (inD > 0 && local < inD) {
    if (a.inKind == TextAnimKind.typewriter) {
      final n = textGraphemeCount(item.text);
      return TextAnimState(reveal: n * local / inD, revealCount: (n * local) ~/ inD);
    }
    final p = _progress(local, (j) => _inPoint(inD, j));
    return _state(a.inKind, a.inDirection, p, canvas);
  }
  if (outD > 0 && local >= d - outD) {
    // Mirror: sample j sits at d − round(outD·j/6); walk the samples in ascending time.
    final p = _progress(d - local, (j) => _inPoint(outD, j));
    final s = _state(a.outKind, a.outDirection, p, canvas);
    return a.inKind == TextAnimKind.typewriter ? _withFullReveal(s, item) : s;
  }
  if (a.inKind == TextAnimKind.typewriter && inD > 0) {
    final n = textGraphemeCount(item.text);
    return TextAnimState(reveal: n.toDouble(), revealCount: n);
  }
  return TextAnimState.identity;
}

TextAnimState _withFullReveal(TextAnimState s, TextItem item) {
  final n = textGraphemeCount(item.text);
  return TextAnimState(opacity: s.opacity, offset: s.offset, scale: s.scale, reveal: n.toDouble(), revealCount: n);
}

TextAnimState _state(TextAnimKind kind, TextSlideDirection direction, double p, CanvasSpec canvas) {
  switch (kind) {
    case TextAnimKind.none:
    case TextAnimKind.typewriter:
      return TextAnimState.identity;
    case TextAnimKind.fade:
      return TextAnimState(opacity: p);
    case TextAnimKind.slide:
      final dist = textSlideFraction * canvas.sizePx.shortSide * (1 - p);
      return TextAnimState(opacity: p, offset: slideVector(direction) * dist);
    case TextAnimKind.scale:
      return TextAnimState(opacity: p, scale: textScaleFrom + (1 - textScaleFrom) * p);
  }
}

/// The absolute timeline times (ascending, unique) at which [item]'s animation changes slope:
/// the 7 samples of the in phase (or its start and end for a typewriter), the 7 samples of the
/// out phase, and the item start and end around them. Between consecutive breakpoints every
/// value of [evaluateTextAnimation] (opacity, offset, scale, reveal) is linear in time, so the
/// compiler samples it here to build the `xf.op`, `xf.cx/cy`, `xf.s` and `reveal` channels.
/// Empty when the item has no animation.
List<TimeUs> textAnimationBreakpoints(TextItem item) {
  final spans = textAnimationSpans(item);
  final inD = spans.inDuration;
  final outD = spans.outDuration;
  if (inD == 0 && outD == 0) return const [];
  final s = item.start;
  final e = item.end;
  final out = <TimeUs>{s};
  if (inD > 0) {
    if (item.animation.inKind == TextAnimKind.typewriter) {
      out.add(s + inD);
    } else {
      for (var j = 0; j <= textEaseSegments; j++) {
        out.add(s + _inPoint(inD, j));
      }
    }
  }
  if (outD > 0) {
    for (var j = textEaseSegments; j >= 0; j--) {
      out.add(e - _inPoint(outD, j));
    }
  }
  out.add(e);
  return out.toList()..sort();
}
