// OWNER: HOM-19
//
// The Home name search controller (HOM plan §8.1, D-98f / V2-119; ARCH §7.6). It keeps one
// [NameIndex] filled from three kinds of source:
//
// - the Danaview folders: re-read from the library store after each write (lazily, on the next
//   query; a query on screen is re-run);
// - the linked folders: a bounded background walk of the 1.1 linked roots (names of folders and of
//   the files the 1.1 browser lists), re-walked when the roots change;
// - the system library, when shown: its owner fills the `system` source of
//   [nameSearchIndexProvider] (no names are read from PhotoKit / MediaStore here).
//
// Queries go to [searchBackendProvider], the hook AIS-51 overrides with the on-device index while
// it is enabled and built (the name search stays the fallback). Answers that arrive after a newer
// query are dropped. Nothing here logs a name, a path or a query (ARCH rule 30).

import 'dart:async';

import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_library/danaview_library.dart' hide LibraryFolder;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../files/library_store_providers.dart';
import '../library_providers.dart';

export 'package:danaview_library/danaview_library.dart'
    show NameIndex, NameSearchBackend, SearchBackend, SearchHit, SearchItem, SearchMatch, SearchOrigin, SearchQuery, SearchResults;

/// The source id of the linked folders in the name index.
const String linkedSearchSourceId = 'linked';

/// The source id of the system photo library in the name index (filled by its owner).
const String systemSearchSourceId = 'system';

/// Lists one folder level (the 1.1 browser's `LibraryRepository.browseDirectory` in the app).
typedef DirectoryBrowser = Future<DirectoryListing> Function(String path);

/// The walk of the linked folders lists at most this many folders.
const int linkedWalkFolderBudget = 2000;

/// The walk of the linked folders indexes at most this many items.
const int linkedWalkItemBudget = 20000;

/// The walk goes at most this deep below a root.
const int linkedWalkDepth = 8;

/// The one name index of the app.
final nameSearchIndexProvider = Provider<NameIndex>((ref) => NameIndex());

/// The name search over [nameSearchIndexProvider].
final nameSearchBackendProvider = Provider<NameSearchBackend>((ref) => NameSearchBackend(ref.watch(nameSearchIndexProvider)));

/// The engine behind the Home search field: the name search, unless AIS-51 overrides this with the
/// on-device index while it is enabled and built.
final searchBackendProvider = Provider<SearchBackend>((ref) => ref.watch(nameSearchBackendProvider));

/// How the linked-folder walk lists a folder.
final linkedSearchBrowserProvider = Provider<DirectoryBrowser>((ref) => LibraryRepository.browseDirectory);

String _baseName(String path) {
  final cut = path.lastIndexOf(RegExp(r'[/\\]'));
  return cut < 0 || cut == path.length - 1 ? path : path.substring(cut + 1);
}

/// Every name under the linked [roots], breadth first, within the budgets.
Future<List<SearchItem>> walkLinkedFolders(List<LibraryFolder> roots, DirectoryBrowser browse) async {
  final items = <SearchItem>[];
  final queue = <(String path, String name, int depth)>[for (final r in roots) (r.path, r.label, 0)];
  final seen = <String>{};
  var listed = 0;
  for (var i = 0; i < queue.length && listed < linkedWalkFolderBudget && items.length < linkedWalkItemBudget; i++) {
    final (path, name, depth) = queue[i];
    if (!seen.add(path)) continue;
    final DirectoryListing listing;
    try {
      listing = await browse(path);
    } on Object {
      continue;
    }
    listed++;
    if (listing.hasError) continue;
    for (final f in listing.folders) {
      if (items.length >= linkedWalkItemBudget) break;
      items.add(SearchItem(id: ItemId.opaque(f.path), name: f.name, origin: SearchOrigin.linked, folderName: name, path: f.path));
      if (depth + 1 <= linkedWalkDepth) queue.add((f.path, f.name, depth + 1));
    }
    for (final m in listing.media) {
      if (items.length >= linkedWalkItemBudget) break;
      final filePath = m.pathOrUri;
      items.add(SearchItem(
        id: ItemId.opaque(m.id),
        name: _baseName(filePath),
        origin: SearchOrigin.linked,
        kind: FileKind.video,
        folderName: name,
        path: filePath,
      ));
    }
  }
  return items;
}

/// The state of the search field.
final class NameSearchState {
  /// A state.
  const NameSearchState({this.query = '', this.kinds, this.results, this.searching = false});

  /// The text typed.
  final String query;

  /// Only these kinds, or all.
  final Set<FileKind>? kinds;

  /// The latest answer for [query], or null before the first.
  final SearchResults? results;

  /// True while an answer for [query] is pending.
  final bool searching;

  /// True when the field holds a query.
  bool get active => query.trim().isNotEmpty;
}

/// Drives the search field.
final class NameSearchController extends StateNotifier<NameSearchState> {
  /// A controller over [_ref]'s providers.
  NameSearchController(this._ref) : super(const NameSearchState());

  final Ref _ref;
  int _seq = 0;
  bool _danaviewStale = true;
  int _linkedWalk = 0;

  /// Most hits asked for.
  static const int limit = 100;

  NameIndex get _index => _ref.read(nameSearchIndexProvider);

  /// Marks the Danaview folders changed; a query on screen is re-run.
  void libraryChanged() {
    _danaviewStale = true;
    if (state.active) unawaited(_run());
  }

  /// Re-walks the linked folders [roots] in the background; a query on screen is re-run after.
  Future<void> linkedRootsChanged(List<LibraryFolder> roots) async {
    final walk = ++_linkedWalk;
    final items = await walkLinkedFolders(roots, _ref.read(linkedSearchBrowserProvider));
    if (!mounted || walk != _linkedWalk) return;
    _index.replaceSource(linkedSearchSourceId, items);
    if (state.active) await _run();
  }

  /// Sets the typed text and searches.
  Future<void> setQuery(String text) {
    state = NameSearchState(query: text, kinds: state.kinds, results: state.results, searching: text.trim().isNotEmpty);
    return _run();
  }

  /// Limits the kinds and searches again.
  Future<void> setKinds(Set<FileKind>? kinds) {
    state = NameSearchState(query: state.query, kinds: kinds, results: state.results, searching: state.active);
    return _run();
  }

  /// Clears the field.
  void clear() {
    _seq++;
    state = NameSearchState(kinds: state.kinds);
  }

  void _syncDanaview() {
    if (!_danaviewStale) return;
    _danaviewStale = false;
    final store = _ref.read(libraryStoreProvider);
    if (store == null) {
      _index.removeSource(danaviewSearchSourceId);
    } else {
      refreshDanaviewSearchSource(_index, store.reader);
    }
  }

  Future<void> _run() async {
    final seq = ++_seq;
    final current = state;
    if (!current.active) {
      state = NameSearchState(query: current.query, kinds: current.kinds);
      return;
    }
    _syncDanaview();
    final query = SearchQuery(current.query, limit: limit, kinds: current.kinds, includeFolders: current.kinds == null);
    SearchResults results;
    try {
      results = await _ref.read(searchBackendProvider).search(query);
    } on Object {
      // An index that fails answers with the name search (ARCH §7.6: the fallback).
      results = await _ref.read(nameSearchBackendProvider).search(query);
    }
    if (!mounted || seq != _seq) return;
    state = NameSearchState(query: current.query, kinds: current.kinds, results: results);
  }
}

/// The search field's controller; it follows library writes and linked-root changes.
final nameSearchControllerProvider = StateNotifierProvider.autoDispose<NameSearchController, NameSearchState>((ref) {
  final controller = NameSearchController(ref);
  ref.listen(libraryRevisionProvider, (_, __) => controller.libraryChanged());
  ref.listen(libraryStoreProvider, (_, __) => controller.libraryChanged());
  ref.listen<List<LibraryFolder>>(
    libraryControllerProvider.select((s) => s.roots),
    (_, roots) => unawaited(controller.linkedRootsChanged(roots)),
    fireImmediately: true,
  );
  return controller;
});
