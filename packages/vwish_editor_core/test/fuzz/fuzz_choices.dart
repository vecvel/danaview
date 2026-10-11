// OWNER: CORE-34
//
// The choice stream of the model fuzzer and its deterministic id generator.
//
// **Choices.** The action generator draws every random decision from a [Choices] stream. A
// random stream records each draw. A replay stream returns recorded draws, reduced modulo the
// current bound. A replay that runs out returns 0. A regression fixture therefore stores one list
// of ints per step, and the minimizer shrinks a failing run by deleting steps and lowering draws
// toward 0. The generator maps small draws to simple choices: the first weight bucket, the first
// item, no optional field.
//
// **FuzzIds.** Session ids come from a counter, so they are deterministic. The runner can rewind
// the counter, so a dry run and the apply that follows it mint the same ids, and their placements
// can be compared by id.

import 'dart:math';

import 'package:vwish_editor_core/model.dart';

/// A recorded or replayed stream of bounded integer choices.
final class Choices {
  /// A stream drawing from [random]. Every draw is recorded in [drawn].
  Choices.random(Random random)
      : _random = random,
        _replay = null;

  /// A stream replaying [draws]. Each draw is reduced modulo its bound, and an exhausted stream
  /// returns 0. The values actually returned are recorded in [drawn].
  Choices.replay(List<int> draws)
      : _random = null,
        _replay = List.unmodifiable(draws);

  final Random? _random;
  final List<int>? _replay;
  int _pos = 0;

  /// The values returned so far, in order (what a fixture stores for this step).
  final List<int> drawn = [];

  /// Whether this stream replays a recording.
  bool get isReplay => _replay != null;

  /// An int in `[0, n)`. A bound of 1 or less returns 0 without drawing. Bounds above 2^32 use
  /// 60 random bits.
  int below(int n) {
    if (n <= 1) return 0;
    final int v;
    final replay = _replay;
    if (replay != null) {
      v = _pos < replay.length ? replay[_pos].abs() % n : 0;
      _pos++;
    } else if (n > 1 << 32) {
      final r = _random!;
      v = ((r.nextInt(1 << 30) << 30) | r.nextInt(1 << 30)) % n;
    } else {
      v = _random!.nextInt(n);
    }
    drawn.add(v);
    return v;
  }

  /// True with probability [num]/[den]. A zero draw gives false, so shrinking turns options off.
  bool chance(int num, int den) => below(den) >= den - num;

  /// A fair coin. A zero draw gives false.
  bool flip() => below(2) == 1;

  /// A double in `[0, 1)` with 20 bits of resolution.
  double unit() => below(1 << 20) / (1 << 20);

  /// A double in `[a, b)`.
  double between(double a, double b) => a + unit() * (b - a);

  /// An element of [xs], which must not be empty.
  T pick<T>(List<T> xs) => xs[below(xs.length)];

  /// The index of a bucket chosen with the given [weights]. A zero draw picks bucket 0.
  int weighted(List<int> weights) {
    var total = 0;
    for (final w in weights) {
      total += w;
    }
    var x = below(total);
    for (var i = 0; i < weights.length; i++) {
      if (x < weights[i]) return i;
      x -= weights[i];
    }
    return weights.length - 1;
  }
}

const String _base62 = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';

/// [n] in base 62, left-padded with '0' to [width] characters.
String base62(int n, int width) {
  final b = <int>[];
  var x = n;
  do {
    b.add(_base62.codeUnitAt(x % 62));
    x ~/= 62;
  } while (x > 0);
  final s = String.fromCharCodes(b.reversed);
  return s.length >= width ? s.substring(s.length - width) : s.padLeft(width, '0');
}

/// A deterministic, rewindable [IdGenerator]. Ids are the kind prefix, `Fz`, four base-62
/// characters of [tag] and six of a counter (12 characters, like production ids).
final class FuzzIds implements IdGenerator {
  /// Creates a generator for run [tag].
  FuzzIds(this.tag);

  /// Distinguishes runs (the fuzz seed).
  final int tag;

  /// Number of ids minted so far. Setting it rewinds or skips ahead.
  int position = 0;

  @override
  String next(IdKind kind) => '${kind.prefix}Fz${base62(tag, 4)}${base62(position++, 6)}';
}
