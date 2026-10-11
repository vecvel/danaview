// OWNER: CORE-22
//
// Encoded-fragment cache for incremental project encoding (ARCH §8.3, domain.md §9.5).
//
// The model is immutable and structurally shared: after a one-item edit, every other item, every
// other track and every pool asset is the *identical* object it was before. `FragmentCache` keeps
// the canonical JSON text of each encoded node in an `Expando` keyed by object identity, so the
// next encode re-serializes only the nodes that are new (the edited item, its track, the timeline
// root and the meta) and splices the cached text of everything else. Entries die with their nodes
// (Expandos hold keys weakly), so the cache needs no eviction.

/// Hit and miss counters of a [FragmentCache] (tests and diagnostics).
final class FragmentCacheStats {
  /// Creates a snapshot of counters.
  const FragmentCacheStats({required this.hits, required this.misses});

  /// Lookups answered from the cache.
  final int hits;

  /// Fragments encoded and stored.
  final int misses;

  @override
  String toString() => 'FragmentCacheStats(hits: $hits, misses: $misses)';
}

/// Canonical JSON text of encoded model nodes, keyed by node identity.
///
/// A fragment depends only on its node and on the codec configuration that produced it (for
/// example the path relativizer used for pool locators), so one cache must only be shared between
/// codecs with the same configuration. `ProjectJsonCodec` owns one by default.
final class FragmentCache {
  /// Creates an empty cache.
  FragmentCache();

  final Expando<String> _fragments = Expando<String>('danaview.editor.projectFragment');
  int _hits = 0;
  int _misses = 0;

  /// The cached fragment of [node], or the result of [encode] (which is then cached).
  ///
  /// [node] must be an immutable model object (a track, an item, an asset, …); numbers, strings,
  /// booleans, records and null cannot be keys.
  String fragment(Object node, String Function() encode) {
    final cached = _fragments[node];
    if (cached != null) {
      _hits++;
      return cached;
    }
    final text = encode();
    _fragments[node] = text;
    _misses++;
    return text;
  }

  /// The cached fragment of [node], if any (does not count as a hit).
  String? peek(Object node) => _fragments[node];

  /// Drops the fragment of [node].
  void invalidate(Object node) => _fragments[node] = null;

  /// Current counters.
  FragmentCacheStats get stats => FragmentCacheStats(hits: _hits, misses: _misses);

  /// Resets the counters (the fragments stay).
  void resetStats() {
    _hits = 0;
    _misses = 0;
  }
}
