import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_domain/danaview_domain.dart';

/// A history entry with its saved resume point and whether its file is still reachable.
@immutable
class LibraryRecentItem {
  const LibraryRecentItem({required this.media, this.resume, this.exists = true});

  final MediaRef media;
  final ResumeInfo? resume;

  /// False when a local file has been moved or deleted; remote links are always true.
  final bool exists;

  double get progress => resume?.progress ?? 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LibraryRecentItem && media == other.media && resume == other.resume && exists == other.exists;

  @override
  int get hashCode => Object.hash(media, resume, exists);
}

@immutable
class LibraryState {
  const LibraryState({
    this.recent = const [],
    this.playlists = const [],
    this.roots = const [],
    this.isLoading = false,
    this.hasLoaded = false,
    this.error,
    this.playlistRevision = 0,
  });

  final List<LibraryRecentItem> recent;
  final List<PlaylistSummary> playlists;

  /// The device folder (mobile only) first, then the user's folders.
  final List<LibraryFolder> roots;
  final bool isLoading;

  /// True once the first load finished; later refreshes keep showing the previous data.
  final bool hasLoaded;
  final String? error;

  /// Bumped whenever playlist contents may have changed, so item lists recompute.
  final int playlistRevision;

  LibraryFolder? get deviceFolder {
    for (final root in roots) {
      if (root.isDevice) return root;
    }
    return null;
  }

  List<LibraryFolder> get userFolders => [for (final root in roots) if (!root.isDevice) root];

  LibraryState copyWith({
    List<LibraryRecentItem>? recent,
    List<PlaylistSummary>? playlists,
    List<LibraryFolder>? roots,
    bool? isLoading,
    bool? hasLoaded,
    String? Function()? error,
    int? playlistRevision,
  }) {
    return LibraryState(
      recent: recent ?? this.recent,
      playlists: playlists ?? this.playlists,
      roots: roots ?? this.roots,
      isLoading: isLoading ?? this.isLoading,
      hasLoaded: hasLoaded ?? this.hasLoaded,
      error: error != null ? error() : this.error,
      playlistRevision: playlistRevision ?? this.playlistRevision,
    );
  }
}

/// Home/library state: continue-watching history, playlists and library folders.
///
/// Playlist mutations rethrow [PlaylistException]; its message is safe to show to the user.
class LibraryController extends StateNotifier<LibraryState> {
  LibraryController(this._repo, this._session) : super(const LibraryState(isLoading: true)) {
    refresh();
  }

  final LibraryRepository _repo;
  final SessionRepository _session;
  int _refreshToken = 0;

  Future<void> refresh() async {
    final token = ++_refreshToken;
    state = state.copyWith(isLoading: true);
    try {
      final recent = _loadRecent();
      final playlists = _repo.getPlaylistSummaries();
      final roots = await _repo.getLibraryRoots();
      if (!mounted || token != _refreshToken) return;
      state = state.copyWith(
        recent: recent,
        playlists: playlists,
        roots: roots,
        isLoading: false,
        hasLoaded: true,
        error: () => null,
        playlistRevision: state.playlistRevision + 1,
      );
    } catch (e) {
      debugPrint('[LibraryController] refresh failed: $e');
      if (!mounted || token != _refreshToken) return;
      state = state.copyWith(
        isLoading: false,
        hasLoaded: true,
        error: () => "Couldn't load your library.",
      );
    }
  }

  ResumeInfo? resumeInfoFor(MediaRef media) => _session.getResumeInfo(media.id);

  String? validatePlaylistName(String name, {String? renaming}) =>
      _repo.validatePlaylistName(name, renaming: renaming);

  bool hasPlaylist(String name) => _repo.getSavedPlaylistNames().contains(name);

  List<MediaRef> playlistItems(String name) => _repo.getPlaylist(name);

  Future<void> removeFromHistory(MediaRef media) async {
    await _repo.removeFromHistory(media.pathOrUri);
    await _session.clearResumePosition(media.id);
    _reloadRecent();
  }

  /// Clears history and the resume points of the cleared entries.
  Future<void> clearHistory() async {
    final cleared = _repo.getRecentlyPlayed();
    await _repo.clearHistory();
    for (final media in cleared) {
      await _session.clearResumePosition(media.id);
    }
    _reloadRecent();
  }

  Future<String> createPlaylist(String name) async {
    final created = await _repo.createPlaylist(name);
    _reloadPlaylists();
    return created;
  }

  Future<String> renamePlaylist(String oldName, String newName) async {
    final renamed = await _repo.renamePlaylist(oldName, newName);
    _reloadPlaylists();
    return renamed;
  }

  Future<void> deletePlaylist(String name) async {
    await _repo.deletePlaylist(name);
    _reloadPlaylists();
  }

  /// Returns how many items were added (items already in the playlist are skipped).
  Future<int> addToPlaylist(String name, List<MediaRef> items) async {
    final added = await _repo.addToPlaylist(name, items);
    _reloadPlaylists();
    return added;
  }

  Future<void> removeFromPlaylist(String name, int index) async {
    await _repo.removeFromPlaylist(name, index);
    _reloadPlaylists();
  }

  /// Moves the item at [from] so it ends up at index [to].
  Future<void> movePlaylistItem(String name, int from, int to) async {
    await _repo.movePlaylistItem(name, from, to);
    _reloadPlaylists();
  }

  Future<LibraryFolder> addFolder(String path) async {
    final folder = await _repo.addFolder(path);
    await _reloadRoots();
    return folder;
  }

  /// Removes the folder from the library only; nothing on disk changes.
  Future<void> removeFolder(String path) async {
    await _repo.removeFolder(path);
    await _reloadRoots();
  }

  List<LibraryRecentItem> _loadRecent() => [
        for (final media in _repo.getRecentlyPlayed())
          LibraryRecentItem(
            media: media,
            resume: _session.getResumeInfo(media.id),
            exists: LibraryRepository.mediaExists(media),
          ),
      ];

  void _reloadRecent() {
    if (mounted) state = state.copyWith(recent: _loadRecent());
  }

  void _reloadPlaylists() {
    if (!mounted) return;
    state = state.copyWith(
      playlists: _repo.getPlaylistSummaries(),
      playlistRevision: state.playlistRevision + 1,
    );
  }

  Future<void> _reloadRoots() async {
    final roots = await _repo.getLibraryRoots();
    if (mounted) state = state.copyWith(roots: roots);
  }
}
