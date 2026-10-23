// OWNER: HOM-19
//
// Natural name order (HOM plan §8.1 "name (natural order, as today)"). A faithful port of the 1.1
// `NaturalSortComparator.compare` (danaview_data/lib/src/scanner/natural_sort.dart), which this
// pure package can't import (ARCH rule 20). Names split into digit and non-digit runs; two digit
// runs compare by value, anything else case-insensitively; a shorter run list sorts first.
// test/v12/organise/natural_order_parity_test.dart pins the parity with the 1.1 comparator.
//
// [NaturalSortKey] precomputes the runs once so sorting 50,000 names doesn't re-split them on
// every comparison; `NaturalSortKey(a).compareTo(NaturalSortKey(b)) == compareNatural(a, b)`.

final RegExp _runs = RegExp(r'(\d+|\D+)');

/// Compares [a] and [b] in natural order: `Episode 2` before `Episode 10`, case-insensitive.
int compareNatural(String a, String b) => NaturalSortKey(a).compareTo(NaturalSortKey(b));

/// One run of a name: its lower-cased text and, for a run the 1.1 comparator reads as a number,
/// its value.
final class _Run {
  _Run(String text)
      : lower = text.toLowerCase(),
        value = int.tryParse(text) == null ? null : BigInt.parse(text);

  final String lower;

  /// Non-null when `int.tryParse` accepts the run (the 1.1 rule; a digit run longer than 64 bits
  /// is compared as text there, and so here).
  final BigInt? value;
}

/// A name split into runs once, for repeated natural-order comparisons.
final class NaturalSortKey implements Comparable<NaturalSortKey> {
  /// The key of [name].
  NaturalSortKey(this.name) : _parts = [for (final m in _runs.allMatches(name)) _Run(m.group(0)!)];

  /// The name.
  final String name;

  final List<_Run> _parts;

  @override
  int compareTo(NaturalSortKey other) {
    final a = _parts;
    final b = other._parts;
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      final x = a[i];
      final y = b[i];
      final xv = x.value;
      final yv = y.value;
      final c = xv != null && yv != null ? xv.compareTo(yv) : x.lower.compareTo(y.lower);
      if (c != 0) return c;
    }
    return a.length.compareTo(b.length);
  }
}
