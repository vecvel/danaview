// OWNER: HOM-19
//
// Name search (HOM plan §8.1, D-98f / V2-119; ARCH §7.6 "HOM-19's name search is the fallback and
// the default when the index is off or still building"). As-you-type matching of names, folder
// names and file types across Danaview folders, linked folders and (when shown) the system
// library. Each source hands the index a snapshot of [SearchItem]s, kept in natural name order
// per source ([prepareSearchSource] sorts it, on a background isolate for the Danaview folders), so
// a query is one linear pass per source that drops each hit into a rank bucket, then merges only
// the bucketed hits: ≤ 50 ms per keystroke over 50,000 names on the mid tier (test/organise/
// name_search_benchmark_test.dart). Swapping a source in is O(1) and never re-sorts the others. A
// query that extends the previous one only rescans the previous hits.
//
// Matching: the query splits on white space; every word must match the name, the folder name or a
// type term (kind, plural, sub-kind, extension) as a substring (type terms by prefix). Ranks: name starts with the first word, a name word starts with it, the name
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
      : key = NaturalSortKey(item.name),
        name = item.name.toLowerCase(),
        folder = item.folderName?.toLowerCase(),
        types = _typeTerms(item);

  final SearchItem item;

  /// The natural-order key of the name.
  final NaturalSortKey key;
  final String name;
  final String? folder;

  /// Every type term, each after a `\u0001`, so "a term starts with w" is one `contains('\u0001w')`.
  final String types;
}

String _typeTerms(SearchItem item) {
  final kind = item.kind;
  if (kind == null) return '\u0001folder\u0001folders';
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
  return [for (final t in terms) '\u0001$t'].join();
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

/// One source's items, prepared and in natural name order (ties by id), ready to swap into a
/// [NameIndex]. [prepareSearchSource] builds it on any isolate, so a large source (the Danaview
/// folders) is sorted off the UI isolate and swapped in with [NameIndex.replacePreparedSource].
final class PreparedSearchSource {
  PreparedSearchSource._(this._items);

  /// No items.
  static final PreparedSearchSource empty = PreparedSearchSource._(const []);

  final List<_Prepared> _items;

  /// How many items.
  int get length => _items.length;

  /// The items, in natural name order.
  Iterable<SearchItem> get items => _items.map((p) => p.item);
}

int _compareByName(_Prepared a, _Prepared b) {
  final c = a.key.compareTo(b.key);
  return c != 0 ? c : a.item.id.value.compareTo(b.item.id.value);
}

/// Prepares and sorts [items] (O(n log n); safe to run in a background isolate).
PreparedSearchSource prepareSearchSource(Iterable<SearchItem> items) {
  final list = [for (final item in items) _Prepared(item)]..sort(_compareByName);
  return PreparedSearchSource._(List.unmodifiable(list));
}

/// One source in the index, with the previous query's hits over it (for refining as the user types
/// on). A new snapshot of the source is a new [_Source], so the cache can't outlive its items.
final class _Source {
  _Source(this.prepared);

  final PreparedSearchSource prepared;
  List<String>? cacheWords;
  List<int>? cacheHits;
}

/// The in-memory name index over every source's snapshot. Each source is kept sorted on its own;
/// a query scans every source and merges only the ranked hits (at most `limit` per rank and
/// source), so swapping one source in never re-sorts the others.
final class NameIndex {
  final Map<String, _Source> _sources = {};
  int _version = 0;

  /// Bumped on every [replaceSource] / [replacePreparedSource] / [removeSource].
  int get version => _version;

  /// Items across every source.
  int get length {
    var n = 0;
    for (final s in _sources.values) {
      n += s.prepared.length;
    }
    return n;
  }

  /// Replaces the snapshot of source [sourceId] with [items] (prepared and sorted here, on the
  /// calling isolate; use [prepareSearchSource] elsewhere and [replacePreparedSource] for large
  /// sources).
  void replaceSource(String sourceId, Iterable<SearchItem> items) => replacePreparedSource(sourceId, prepareSearchSource(items));

  /// Replaces the snapshot of source [sourceId] with [source] (O(1)).
  void replacePreparedSource(String sourceId, PreparedSearchSource source) {
    _sources[sourceId] = _Source(source);
    _version++;
  }

  /// Drops source [sourceId].
  void removeSource(String sourceId) {
    if (_sources.remove(sourceId) != null) _version++;
  }

  /// The ids of the sources indexed.
  Iterable<String> get sourceIds => _sources.keys;

  SearchMatch? _match(_Prepared p, List<String> words, List<String> typeWords) {
    final first = words.first;
    var allInName = true;
    var anyFolder = false;
    for (var i = 0; i < words.length; i++) {
      final w = words[i];
      if (p.name.contains(w)) continue;
      allInName = false;
      if (p.folder?.contains(w) ?? false) {
        anyFolder = true;
        continue;
      }
      if (p.types.contains(typeWords[i])) continue;
      return null;
    }
    if (allInName) {
      if (p.name.startsWith(first)) return SearchMatch.namePrefix;
      if (_startsWord(p.name, first)) return SearchMatch.nameWord;
      return SearchMatch.name;
    }
    return anyFolder ? SearchMatch.folder : SearchMatch.type;
  }

  /// Scans [source] for [words], filling [buckets] (natural order within each); returns the count
  /// of hits that pass [query]'s filters.
  int _scan(_Source source, SearchQuery query, List<String> words, List<String> typeWords, List<List<_Prepared>> buckets) {
    final all = source.prepared._items;
    // Refine the previous hit set when every previous word is a prefix of the new word in the same
    // position (typing on).
    List<int>? candidates;
    final prevWords = source.cacheWords;
    final prevHits = source.cacheHits;
    if (prevWords != null && prevHits != null && prevWords.length <= words.length) {
      var refines = true;
      for (var i = 0; i < prevWords.length; i++) {
        // A longer word can only drop hits (substrings and term prefixes shrink).
        if (!words[i].startsWith(prevWords[i])) {
          refines = false;
          break;
        }
      }
      if (refines) candidates = prevHits;
    }

    final hits = <int>[];
    final kinds = query.kinds;
    var total = 0;
    final n = candidates?.length ?? all.length;
    for (var c = 0; c < n; c++) {
      final i = candidates == null ? c : candidates[c];
      final p = all[i];
      final m = _match(p, words, typeWords);
      if (m == null) continue;
      hits.add(i);
      final kind = p.item.kind;
      if (kind == null ? !query.includeFolders : (kinds != null && !kinds.contains(kind))) continue;
      total++;
      final bucket = buckets[m.index];
      if (bucket.length < query.limit) bucket.add(p);
    }
    source.cacheWords = words;
    source.cacheHits = hits;
    return total;
  }

  /// Answers [query] synchronously (the benchmark measures this).
  SearchResults search(SearchQuery query) {
    final words = searchWords(query.text);
    if (words.isEmpty || query.limit <= 0) return SearchResults.empty(query);
    final typeWords = [for (final w in words) '\u0001$w'];

    var total = 0;
    final perSource = <List<List<_Prepared>>>[];
    for (final source in _sources.values) {
      final buckets = List<List<_Prepared>>.generate(SearchMatch.values.length, (_) => <_Prepared>[]);
      total += _scan(source, query, words, typeWords, buckets);
      perSource.add(buckets);
    }

    final out = <SearchHit>[];
    for (final match in SearchMatch.values) {
      if (out.length == query.limit) break;
      final List<_Prepared> rank;
      if (perSource.length == 1) {
        rank = perSource.first[match.index];
      } else {
        // Each source's bucket is already in natural order: sorting their union is merging at most
        // `limit` items per source.
        rank = [for (final b in perSource) ...b[match.index]]..sort(_compareByName);
      }
      for (final p in rank) {
        if (out.length == query.limit) break;
        out.add(SearchHit(p.item, match));
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
