// OWNER: HOM-19
//
// Name search (HOM plan §8.1, D-98f / V2-119; ARCH §7.6 "HOM-19's name search is the fallback and
// the default when the index is off or still building"). As-you-type matching of names, folder
// names and file types across Danaview folders, linked folders and (when shown) the system
// library. Each source hands the index a snapshot of [SearchItem]s; the index keeps them in
// natural name order, so a query is one linear pass that drops each hit into a rank bucket and
// never sorts: ≤ 50 ms per keystroke over 50,000 names on the mid tier (test/organise/
// name_search_benchmark_test.dart). A query that extends the previous one only rescans the
// previous hits.
//
// Matching: the query splits on white space; every word must match the name, the folder name or a
// type term (kind, plural, sub-kind, extension) as a substring (type terms by prefix, from two
// characters). Ranks: name starts with the first word, a name word starts with it, the name
// contains every word, a folder name matches, only the type matches. Folders rank with files.
//
// [SearchBackend] is the hook AIS-51 replaces with the on-device index (AIS-50) when it is enabled;
// [NameSearchBackend] is the default and the fallback. Trashed rows never reach the index (the
// library source reads live rows only, V2-08). Nothing here logs a name or a query (rule 30).

import 'dart:async';

import 'package:meta/meta.dart';

import '../model/document_item.dart';
import '../model/file_kind.dart';
import '../model/ids.dart';
import 'natural_order.dart';

/// Where a search item lives.
enum SearchOrigin {
  /// A Danaview folder entry or folder (library.db).
  danaview,

  /// A file or folder in a linked folder (the 1.1 browser; read-only).
  linked,

  /// The system photo library (PhotoKit, MediaStore).
  system,
}

/// One searchable file or folder.
@immutable
final class SearchItem {
  /// An item. [kind] is null for a folder. [path] is the file path of a linked item (to open it).
  const SearchItem({
    required this.id,
    required this.name,
    required this.origin,
    this.kind,
    this.subKind,
    this.folderName,
    this.path,
  });

  /// The item id (`fe_`, `fd_`, `lk:`, `ph:`, `ms:` or an opaque v1.1 path).
  final ItemId id;

  /// The name shown.
  final String name;

  /// Where it lives.
  final SearchOrigin origin;

  /// The file kind, or null for a folder.
  final FileKind? kind;

  /// The sub-kind (a Documents sub-filter code).
  final String? subKind;

  /// The name of the folder holding it (null at the top level).
  final String? folderName;

  /// The file path of a linked item.
  final String? path;

  /// True for a folder.
  bool get isFolder => kind == null;

  @override
  bool operator ==(Object other) =>
      other is SearchItem &&
      other.id == id &&
      other.name == name &&
      other.origin == origin &&
      other.kind == kind &&
      other.subKind == subKind &&
      other.folderName == folderName &&
      other.path == path;

  @override
  int get hashCode => Object.hash(id, name, origin, kind, subKind, folderName, path);

  @override
  String toString() => 'SearchItem(${id.value})';
}

/// What a query asks for.
@immutable
final class SearchQuery {
  /// A query for [text], at most [limit] hits, optionally only [kinds] (folders match only when
  /// [includeFolders]).
  const SearchQuery(this.text, {this.limit = 100, this.kinds, this.includeFolders = true});

  /// The typed text.
  final String text;

  /// The most hits returned.
  final int limit;

  /// Only these kinds, or every kind.
  final Set<FileKind>? kinds;

  /// Whether folders are returned.
  final bool includeFolders;

  /// True when the text has no word to match.
  bool get isBlank => text.trim().isEmpty;
}

/// Why a hit matched, best first (the rank).
enum SearchMatch {
  /// The name starts with the first word.
  namePrefix,

  /// A word of the name starts with the first word.
  nameWord,

  /// The name contains every word.
  name,

  /// The folder name matched.
  folder,

  /// Only the type matched.
  type,
}

/// One hit.
@immutable
final class SearchHit {
  /// A hit.
  const SearchHit(this.item, this.match);

  /// The item.
  final SearchItem item;

  /// Why it matched.
  final SearchMatch match;

  @override
  bool operator ==(Object other) => other is SearchHit && other.item == item && other.match == match;

  @override
  int get hashCode => Object.hash(item, match);
}

/// The answer to a query.
@immutable
final class SearchResults {
  /// Results.
  const SearchResults({required this.query, required this.hits, required this.total, required this.backend});

  /// No results for [query].
  const SearchResults.empty(this.query, {this.backend = NameSearchBackend.backendId})
      : hits = const [],
        total = 0;

  /// The query answered.
  final SearchQuery query;

  /// The best hits, at most `query.limit`, best rank first, then natural name order.
  final List<SearchHit> hits;

  /// How many items matched in all.
  final int total;

  /// The id of the backend that answered ([NameSearchBackend.backendId] or the index's).
  final String backend;

  /// True when more items matched than [hits] holds.
  bool get truncated => total > hits.length;
}

/// A search engine behind the Home search field. The name search is the default; AIS-51 provides
/// the on-device index and swaps it in through the FEAT provider while the index is enabled and
/// built.
abstract interface class SearchBackend {
  /// A stable id (shown nowhere; tells tests and the UI which engine answered).
  String get id;

  /// Answers [query].
  Future<SearchResults> search(SearchQuery query);
}

/// A prepared item: lower-cased fields and type terms.
final class _Prepared {
  _Prepared(this.item)
      : name = item.name.toLowerCase(),
        folder = item.folderName?.toLowerCase(),
        types = _typeTerms(item);

  final SearchItem item;
  final String name;
  final String? folder;
  final List<String> types;
}

List<String> _typeTerms(SearchItem item) {
  final kind = item.kind;
  if (kind == null) return const ['folder', 'folders'];
  final terms = <String>{kind.code, '${kind.code}s'};
  if (kind == FileKind.document) {
    final doc = DocumentKind.decode(item.subKind);
    terms.add(doc.code);
    for (final part in doc.filterLabel.toLowerCase().split('/')) {
      terms.add(part);
    }
  } else if (item.subKind case final sub? when sub.isNotEmpty) {
    terms.add(sub.toLowerCase());
  }
  final dot = item.name.lastIndexOf('.');
  if (dot > 0 && dot < item.name.length - 1) terms.add(item.name.substring(dot + 1).toLowerCase());
  return terms.toList(growable: false);
}

bool _isWordChar(int c) =>
    (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x7a) || (c >= 0x41 && c <= 0x5a) || c > 0x7f;

/// Whether [token] starts a word of [text] (at the start or after a separator, `_`, `-`, `.`).
bool _startsWord(String text, String token) {
  var from = 0;
  while (true) {
    final i = text.indexOf(token, from);
    if (i < 0) return false;
    if (i == 0 || !_isWordChar(text.codeUnitAt(i - 1))) return true;
    from = i + 1;
  }
}

/// The words of [text], lower-cased.
List<String> searchWords(String text) => [
      for (final w in text.toLowerCase().split(RegExp(r'\s+')))
        if (w.isNotEmpty) w,
    ];

/// The in-memory name index over every source's snapshot.
final class NameIndex {
  final Map<String, List<SearchItem>> _sources = {};
  List<_Prepared>? _prepared;
  int _version = 0;

  // The previous query's words and hit positions, for refining as the user types on.
  int _cacheVersion = -1;
  List<String>? _cacheWords;
  List<int>? _cacheHits;

  /// Bumped on every [replaceSource] / [removeSource].
  int get version => _version;

  /// Items across every source.
  int get length => _ensure().length;

  /// Replaces the snapshot of source [sourceId] with [items].
  void replaceSource(String sourceId, Iterable<SearchItem> items) {
    _sources[sourceId] = List.unmodifiable(items);
    _invalidate();
  }

  /// Drops source [sourceId].
  void removeSource(String sourceId) {
    if (_sources.remove(sourceId) != null) _invalidate();
  }

  /// The ids of the sources indexed.
  Iterable<String> get sourceIds => _sources.keys;

  void _invalidate() {
    _prepared = null;
    _version++;
    _cacheWords = null;
    _cacheHits = null;
  }

  List<_Prepared> _ensure() {
    final ready = _prepared;
    if (ready != null) return ready;
    final keyed = <(NaturalSortKey, _Prepared)>[
      for (final items in _sources.values)
        for (final item in items) (NaturalSortKey(item.name), _Prepared(item)),
    ];
    // Natural name order; ties by id so the order doesn't depend on source order.
    keyed.sort((a, b) {
      final c = a.$1.compareTo(b.$1);
      return c != 0 ? c : a.$2.item.id.value.compareTo(b.$2.item.id.value);
    });
    return _prepared = [for (final k in keyed) k.$2];
  }

  SearchMatch? _match(_Prepared p, List<String> words) {
    final first = words.first;
    var allInName = true;
    var anyFolder = false;
    for (final w in words) {
      if (p.name.contains(w)) continue;
      allInName = false;
      if (p.folder?.contains(w) ?? false) {
        anyFolder = true;
        continue;
      }
      if (w.length >= 2 && p.types.any((t) => t.startsWith(w))) continue;
      return null;
    }
    if (allInName) {
      if (p.name.startsWith(first)) return SearchMatch.namePrefix;
      if (_startsWord(p.name, first)) return SearchMatch.nameWord;
      return SearchMatch.name;
    }
    return anyFolder ? SearchMatch.folder : SearchMatch.type;
  }

  /// Answers [query] synchronously (the benchmark measures this).
  SearchResults search(SearchQuery query) {
    final words = searchWords(query.text);
    if (words.isEmpty || query.limit <= 0) return SearchResults.empty(query);
    final all = _ensure();

    // Refine the previous hit set when every previous word is a prefix of the new word in the same
    // position (typing on) and nothing changed since.
    Iterable<int> candidates = Iterable<int>.generate(all.length);
    final prevWords = _cacheWords;
    final prevHits = _cacheHits;
    if (_cacheVersion == _version && prevWords != null && prevHits != null && prevWords.length <= words.length) {
      var refines = true;
      for (var i = 0; i < prevWords.length; i++) {
        final prev = prevWords[i];
        // A longer word can only drop hits, except that type terms start matching at two letters.
        if (!words[i].startsWith(prev) || (prev.length < 2 && words[i].length >= 2)) {
          refines = false;
          break;
        }
      }
      if (refines) candidates = prevHits;
    }

    final buckets = List<List<SearchHit>>.generate(SearchMatch.values.length, (_) => <SearchHit>[]);
    final hits = <int>[];
    final kinds = query.kinds;
    var total = 0;
    for (final i in candidates) {
      final p = all[i];
      final m = _match(p, words);
      if (m == null) continue;
      hits.add(i);
      final kind = p.item.kind;
      if (kind == null ? !query.includeFolders : (kinds != null && !kinds.contains(kind))) continue;
      total++;
      final bucket = buckets[m.index];
      if (bucket.length < query.limit) bucket.add(SearchHit(p.item, m));
    }
    _cacheVersion = _version;
    _cacheWords = words;
    _cacheHits = hits;

    final out = <SearchHit>[];
    for (final bucket in buckets) {
      for (final hit in bucket) {
        if (out.length == query.limit) break;
        out.add(hit);
      }
    }
    return SearchResults(query: query, hits: List.unmodifiable(out), total: total, backend: NameSearchBackend.backendId);
  }
}

/// The default [SearchBackend]: names, folder names and types over a [NameIndex].
final class NameSearchBackend implements SearchBackend {
  /// A backend over [index] (a new empty one by default).
  NameSearchBackend([NameIndex? index]) : index = index ?? NameIndex();

  /// The id of the name search.
  static const String backendId = 'names';

  /// The index the sources fill.
  final NameIndex index;

  @override
  String get id => backendId;

  @override
  Future<SearchResults> search(SearchQuery query) => Future.sync(() => index.search(query));
}
