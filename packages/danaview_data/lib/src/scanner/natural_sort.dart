/// Natural sort and episode-aware filename comparator.
/// Implements §7.4 of Danaview TRD.
class NaturalSortComparator {
  static final RegExp _chunkRegex = RegExp(r'(\d+|\D+)');

  /// Compares two strings using natural numerical sort.
  /// Example: 'Episode 2' comes before 'Episode 10'.
  static int compare(String a, String b) {
    final chunksA = _chunkRegex.allMatches(a).map((m) => m.group(0)!).toList();
    final chunksB = _chunkRegex.allMatches(b).map((m) => m.group(0)!).toList();

    final length = chunksA.length < chunksB.length ? chunksA.length : chunksB.length;

    for (var i = 0; i < length; i++) {
      final chunkA = chunksA[i];
      final chunkB = chunksB[i];

      final isNumA = int.tryParse(chunkA) != null;
      final isNumB = int.tryParse(chunkB) != null;

      if (isNumA && isNumB) {
        final numA = BigInt.parse(chunkA);
        final numB = BigInt.parse(chunkB);
        final comp = numA.compareTo(numB);
        if (comp != 0) return comp;
      } else {
        final comp = chunkA.toLowerCase().compareTo(chunkB.toLowerCase());
        if (comp != 0) return comp;
      }
    }

    return chunksA.length.compareTo(chunksB.length);
  }
}

class EpisodeInfo {
  final int season;
  final int episode;
  final bool hasMatch;

  const EpisodeInfo({
    this.season = 1,
    this.episode = 0,
    this.hasMatch = false,
  });

  static const EpisodeInfo none = EpisodeInfo();
}

class EpisodeParser {
  // Regexes for common scene/anime patterns:
  // S01E02, s01e02, 1x02, EP03, ep. 04, [Group] Title - 07 [1080p], Part 2
  static final List<RegExp> _patterns = [
    RegExp(r'\b[sS](\d+)[eE](\d+)\b', caseSensitive: false),
    RegExp(r'\b(\d+)x(\d+)\b', caseSensitive: false),
    RegExp(r'\b(?:ep|episode)[.\s_-]*(\d+)\b', caseSensitive: false),
    RegExp(r'[-_]\s*(\d{1,3})\s*[-_\[\.\(]', caseSensitive: false),
    RegExp(r'\bpart\s*(\d+)\b', caseSensitive: false),
    RegExp(r'\b[eE](\d+)\b', caseSensitive: false),
  ];

  static EpisodeInfo parse(String filename) {
    for (final reg in _patterns) {
      final match = reg.firstMatch(filename);
      if (match != null) {
        if (match.groupCount >= 2) {
          final s = int.tryParse(match.group(1)!) ?? 1;
          final e = int.tryParse(match.group(2)!) ?? 0;
          return EpisodeInfo(season: s, episode: e, hasMatch: true);
        } else if (match.groupCount == 1) {
          final e = int.tryParse(match.group(1)!) ?? 0;
          return EpisodeInfo(season: 1, episode: e, hasMatch: true);
        }
      }
    }
    return EpisodeInfo.none;
  }
}
