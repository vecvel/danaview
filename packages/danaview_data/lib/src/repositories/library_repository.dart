import 'dart:convert';
import 'dart:io';
import 'package:danaview_domain/danaview_domain.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../scanner/natural_sort.dart';
import '../storage/library_storage.dart';

/// Thrown by playlist mutations; [message] is safe to show to the user.
class PlaylistException implements Exception {
  final String message;

  const PlaylistException(this.message);

  @override
  String toString() => message;
}

/// Library state (folders, playlists, history) stored as rows that point at paths.
/// Nothing here writes to, moves, or deletes user media (§7.0).
class LibraryRepository {
  final SharedPreferences _prefs;
  final LibraryStorage _storage;

  LibraryRepository(this._prefs, {LibraryStorage? storage}) : _storage = storage ?? LibraryStorage();

  /// See [LibraryStorage.resolveStoredPath].
  String resolveStoredPath(String path) => _storage.resolveStoredPath(path);

  static Future<LibraryRepository> create() async {
    final prefs = await SharedPreferences.getInstance();
    return LibraryRepository(prefs);
  }

  static const _kPlaylists = 'saved_playlists';
  static const _kPlaylistPrefix = 'playlist_';
  static const _kHistory = 'recent_history';
  static const _kFolders = 'library_folders';
  static const _historyLimit = 50;
  static const _maxPlaylistNameLength = 100;
  static const _countedSubfolderLimit = 64;

  static const deviceFolderLabel = 'On This Device';

  static const Set<String> videoExtensions = {
    '.mkv', '.mp4', '.m4v', '.mov', '.avi', '.webm', '.ts', '.m2ts', '.mts',
    '.flv', '.wmv', '.ogv', '.3gp', '.mpg', '.mpeg',
  };

  static const _systemEntryNames = {
    r'$recycle.bin', 'system volume information', 'lost+found', '@eadir', '#recycle', '#snapshot', '__macosx',
  };

  static bool isVideoPath(String path) => videoExtensions.contains(p.extension(path).toLowerCase());

  /// A local [MediaRef] for [path] with episode numbers parsed from the file name.
  static MediaRef mediaRefForFile(String path) {
    final name = p.basename(path);
    final episode = EpisodeParser.parse(name);
    return MediaRef(
      id: path,
      title: name,
      pathOrUri: path,
      seasonNumber: episode.season,
      episodeNumber: episode.episode,
    );
  }

  /// False only for local media whose file no longer exists; remote media is always true.
  static bool mediaExists(MediaRef media) => media.isRemote || File(media.pathOrUri).existsSync();

  // Library folders

  /// User-added library roots, in the order they were added. Excludes the device folder.
  List<LibraryFolder> getFolders() {
    final folders = <LibraryFolder>[];
    for (final raw in _readStringList(_kFolders)) {
      final folder = _decodeFolder(raw);
      if (folder != null && !folders.any((f) => p.equals(f.path, folder.path))) folders.add(folder);
    }
    return folders;
  }

  /// Adds a library root (the path is normalized; an existing root is returned as-is).
  /// Throws [ArgumentError] for an empty path. Never touches the disk.
  Future<LibraryFolder> addFolder(String path, {String? label}) async {
    final normalized = _normalizeFolderPath(path);
    if (normalized.isEmpty) throw ArgumentError.value(path, 'path', 'must not be empty');
    final folders = getFolders();
    for (final folder in folders) {
      if (p.equals(folder.path, normalized)) return folder;
    }
    final trimmedLabel = label?.trim() ?? '';
    final folder = LibraryFolder(
      path: normalized,
      label: trimmedLabel.isNotEmpty ? trimmedLabel : _defaultLabel(normalized),
      addedAt: DateTime.fromMillisecondsSinceEpoch(DateTime.now().millisecondsSinceEpoch),
    );
    await _writeFolders([...folders, folder]);
    return folder;
  }

  /// Removes a library root from the app only; the folder and its files stay on disk.
  Future<void> removeFolder(String path) async {
    final normalized = _normalizeFolderPath(path);
    final folders = getFolders();
    final kept = folders.where((f) => !p.equals(f.path, normalized)).toList();
    if (kept.length != folders.length) await _writeFolders(kept);
  }

  /// The app's Documents folder as a non-removable library root on iOS/Android; null on desktop.
  Future<LibraryFolder?> getDeviceFolder() async {
    final dir = await _storage.deviceDirectory();
    if (dir == null) return null;
    return LibraryFolder(path: dir.path, label: deviceFolderLabel, isDevice: true);
  }

  /// The device folder (mobile only) followed by the user-added roots.
  Future<List<LibraryFolder>> getLibraryRoots() async {
    final device = await getDeviceFolder();
    return [if (device != null) device, ...getFolders()];
  }

  /// One level of [path]: naturally sorted subfolders and video files, hidden/system
  /// entries skipped. Never throws; unreadable folders return a listing with [DirectoryListing.error].
  static Future<DirectoryListing> browseDirectory(String path) async {
    final name = _defaultLabel(path);
    final dir = Directory(path);
    try {
      if (!await dir.exists()) {
        return DirectoryListing(
          path: path,
          name: name,
          error: "This folder isn't available. It may have been moved, renamed, or be on a drive that isn't connected.",
        );
      }

      final folderPaths = <String>[];
      final files = <String>[];
      await for (final entity in dir.list(followLinks: true)) {
        final entryName = p.basename(entity.path);
        if (_isHiddenOrSystem(entryName)) continue;
        if (entity is Directory) {
          folderPaths.add(entity.path);
        } else if (entity is File && isVideoPath(entity.path)) {
          files.add(entity.path);
        }
      }

      folderPaths.sort((a, b) => NaturalSortComparator.compare(p.basename(a), p.basename(b)));
      files.sort((a, b) => NaturalSortComparator.compare(p.basename(a), p.basename(b)));

      final countSubfolders = folderPaths.length <= _countedSubfolderLimit;
      final folders = await Future.wait(folderPaths.map((folderPath) async => LibraryFolderEntry(
            name: p.basename(folderPath),
            path: folderPath,
            mediaCount: countSubfolders ? await _countMedia(folderPath) : null,
          )));

      return DirectoryListing(
        path: path,
        name: name,
        folders: folders,
        media: files.map(mediaRefForFile).toList(),
      );
    } on FileSystemException catch (e) {
      final code = e.osError?.errorCode;
      final denied = code == 1 || code == 5 || code == 13;
      return DirectoryListing(
        path: path,
        name: name,
        error: denied
            ? "Danaview doesn't have permission to read this folder. Add it again to grant access."
            : "Couldn't read this folder.",
      );
    } catch (_) {
      return DirectoryListing(path: path, name: name, error: "Couldn't read this folder.");
    }
  }

  /// Video files directly inside [directoryPath], naturally sorted.
  static Future<List<MediaRef>> scanDirectory(String directoryPath) async =>
      (await browseDirectory(directoryPath)).media;

  // Playlists

  List<String> getSavedPlaylistNames() {
    final names = <String>[];
    for (final name in _readStringList(_kPlaylists)) {
      if (name.trim().isNotEmpty && !names.contains(name)) names.add(name);
    }
    return names;
  }

  /// Null when [name] can be used for a new playlist (or for renaming [renaming]); otherwise
  /// a user-facing reason. Names are trimmed and compared case-insensitively.
  String? validatePlaylistName(String name, {String? renaming}) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'Enter a playlist name.';
    if (trimmed.length > _maxPlaylistNameLength) return 'Use $_maxPlaylistNameLength characters or fewer.';
    final lower = trimmed.toLowerCase();
    final taken = getSavedPlaylistNames().any((n) => n != renaming && n.toLowerCase() == lower);
    // The verdict comes first so a long name can't push it out of view.
    return taken ? 'That name is already used by another playlist.' : null;
  }

  /// Creates an empty playlist and returns its stored (trimmed) name.
  /// Throws [PlaylistException] when the name is empty, too long, or already used.
  Future<String> createPlaylist(String name) async {
    final error = validatePlaylistName(name);
    if (error != null) throw PlaylistException(error);
    final trimmed = name.trim();
    await _prefs.setStringList(_kPlaylists, [...getSavedPlaylistNames(), trimmed]);
    await _prefs.setStringList('$_kPlaylistPrefix$trimmed', const []);
    return trimmed;
  }

  /// Renames a playlist in place (keeping its position and items) and returns the new name.
  /// Throws [PlaylistException] when [oldName] doesn't exist or [newName] is invalid.
  Future<String> renamePlaylist(String oldName, String newName) async {
    final names = getSavedPlaylistNames();
    final index = names.indexOf(oldName);
    if (index < 0) throw const PlaylistException('This playlist no longer exists.');
    final error = validatePlaylistName(newName, renaming: oldName);
    if (error != null) throw PlaylistException(error);
    final trimmed = newName.trim();
    if (trimmed == oldName) return oldName;

    final items = _readStringList('$_kPlaylistPrefix$oldName');
    await _prefs.setStringList('$_kPlaylistPrefix$trimmed', items);
    names[index] = trimmed;
    await _prefs.setStringList(_kPlaylists, names);
    await _prefs.remove('$_kPlaylistPrefix$oldName');
    return trimmed;
  }

  /// Replaces the items of [name], creating the playlist if needed.
  Future<void> savePlaylist(String name, List<MediaRef> items) async {
    final names = getSavedPlaylistNames();
    if (!names.contains(name)) {
      await _prefs.setStringList(_kPlaylists, [...names, name]);
    }
    await _prefs.setStringList('$_kPlaylistPrefix$name', items.map(_encodeRef).toList());
  }

  /// Items of [name] in order; corrupted entries are skipped.
  List<MediaRef> getPlaylist(String name) => _decodeRefs(_readStringList('$_kPlaylistPrefix$name'));

  /// Appends [items] not already in the playlist (matched by `pathOrUri`) and returns how many
  /// were added. Throws [PlaylistException] when the playlist doesn't exist.
  Future<int> addToPlaylist(String name, List<MediaRef> items) async {
    _requirePlaylist(name);
    final current = getPlaylist(name);
    final seen = current.map((m) => m.pathOrUri).toSet();
    final added = items.where((m) => seen.add(m.pathOrUri)).toList();
    if (added.isNotEmpty) await savePlaylist(name, [...current, ...added]);
    return added.length;
  }

  /// Removes the item at [index]; out-of-range indexes are ignored.
  Future<void> removeFromPlaylist(String name, int index) async {
    final items = getPlaylist(name);
    if (index < 0 || index >= items.length) return;
    items.removeAt(index);
    await savePlaylist(name, items);
  }

  /// Moves the item at [from] so it ends up at index [to]; out-of-range indexes are ignored.
  Future<void> movePlaylistItem(String name, int from, int to) async {
    final items = getPlaylist(name);
    if (from < 0 || from >= items.length || to < 0 || to >= items.length || from == to) return;
    items.insert(to, items.removeAt(from));
    await savePlaylist(name, items);
  }

  List<PlaylistSummary> getPlaylistSummaries() => [
        for (final name in getSavedPlaylistNames())
          PlaylistSummary(name: name, itemCount: getPlaylist(name).length),
      ];

  /// Deletes the playlist only; its media files are untouched.
  Future<void> deletePlaylist(String name) async {
    final names = getSavedPlaylistNames()..remove(name);
    await _prefs.setStringList(_kPlaylists, names);
    await _prefs.remove('$_kPlaylistPrefix$name');
  }

  // History

  /// Most recent first, at most 50 entries.
  List<MediaRef> getRecentlyPlayed() => _decodeRefs(_readStringList(_kHistory));

  /// Moves [media] to the top of history. A zero duration keeps the previously known duration.
  Future<void> recordPlayed(MediaRef media) async {
    final recents = getRecentlyPlayed();
    final previous = recents.where((r) => r.pathOrUri == media.pathOrUri).firstOrNull;
    recents.removeWhere((r) => r.pathOrUri == media.pathOrUri);
    final keepDuration = media.duration == Duration.zero && previous != null;
    recents.insert(0, keepDuration ? media.copyWith(duration: previous.duration) : media);
    await _writeHistory(recents.take(_historyLimit).toList());
  }

  /// Updates the stored duration of a history entry without reordering it.
  Future<void> updateHistoryDuration(String pathOrUri, Duration duration) async {
    if (duration <= Duration.zero) return;
    final recents = getRecentlyPlayed();
    final index = recents.indexWhere((r) => r.pathOrUri == pathOrUri);
    if (index < 0 || recents[index].duration == duration) return;
    recents[index] = recents[index].copyWith(duration: duration);
    await _writeHistory(recents);
  }

  Future<void> removeFromHistory(String pathOrUri) async {
    final recents = getRecentlyPlayed();
    final before = recents.length;
    recents.removeWhere((r) => r.pathOrUri == pathOrUri);
    if (recents.length != before) await _writeHistory(recents);
  }

  Future<void> clearHistory() => _prefs.remove(_kHistory);

  // Sidecar subtitle discovery (Read-only §7.3)
  static Future<List<String>> discoverSidecarSubtitles(String mediaPath) async {
    final file = File(mediaPath);
    if (!await file.exists()) return const [];

    final dir = file.parent;
    final baseName = p.basenameWithoutExtension(mediaPath).toLowerCase();
    const validExts = {'.srt', '.ass', '.ssa', '.vtt', '.sub'};
    final found = <String>{};
    final results = <String>[];
    final visitedDirs = <String>{};

    // file.srt, file.en.srt, ... next to the video or in a Subs/Subtitles folder.
    for (final dirPath in [dir.path, for (final name in ['Subs', 'subs', 'Subtitles', 'subtitles']) p.join(dir.path, name)]) {
      try {
        final candidate = Directory(dirPath);
        if (!await candidate.exists()) continue;
        // 'Subs' and 'subs' are the same folder on case-insensitive filesystems.
        if (!visitedDirs.add(await candidate.resolveSymbolicLinks())) continue;
        await for (final entity in candidate.list()) {
          if (entity is! File) continue;
          if (!validExts.contains(p.extension(entity.path).toLowerCase())) continue;
          if (!p.basenameWithoutExtension(entity.path).toLowerCase().startsWith(baseName)) continue;
          final canonical = await entity.resolveSymbolicLinks();
          if (found.add(canonical)) results.add(entity.path);
        }
      } catch (_) {}
    }
    return results;
  }

  // Storage helpers

  void _requirePlaylist(String name) {
    if (!getSavedPlaylistNames().contains(name)) {
      throw const PlaylistException('This playlist no longer exists.');
    }
  }

  List<String> _readStringList(String key) {
    try {
      return List.of(_prefs.getStringList(key) ?? const <String>[]);
    } catch (_) {
      return <String>[];
    }
  }

  Future<void> _writeHistory(List<MediaRef> items) =>
      _prefs.setStringList(_kHistory, items.map(_encodeRef).toList());

  Future<void> _writeFolders(List<LibraryFolder> folders) => _prefs.setStringList(
        _kFolders,
        folders
            .map((f) => jsonEncode({
                  'path': f.path,
                  'label': f.label,
                  'addedAt': f.addedAt?.millisecondsSinceEpoch,
                }))
            .toList(),
      );

  LibraryFolder? _decodeFolder(String raw) {
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return null;
      final path = map['path'];
      if (path is! String || path.trim().isEmpty) return null;
      final label = map['label'];
      final addedAt = map['addedAt'];
      return LibraryFolder(
        path: path,
        label: label is String && label.isNotEmpty ? label : _defaultLabel(path),
        addedAt: addedAt is int ? DateTime.fromMillisecondsSinceEpoch(addedAt) : null,
      );
    } catch (_) {
      return null;
    }
  }

  static String _encodeRef(MediaRef m) => jsonEncode({
        'id': m.id,
        'title': m.title,
        'pathOrUri': m.pathOrUri,
        'durationMs': m.duration.inMilliseconds,
        'isRemote': m.isRemote,
        'season': m.seasonNumber,
        'episode': m.episodeNumber,
      });

  List<MediaRef> _decodeRefs(List<String> raw) => [
        for (final item in raw)
          if (_decodeRef(item) case final ref?) ref,
      ];

  MediaRef? _decodeRef(String raw) {
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return null;
      final pathOrUri = map['pathOrUri'];
      if (pathOrUri is! String || pathOrUri.isEmpty) return null;
      final isRemote = map['isRemote'] == true;
      final id = map['id'];
      final title = map['title'];
      final durationMs = map['durationMs'];
      final season = map['season'];
      final episode = map['episode'];
      final resolved = isRemote ? pathOrUri : _storage.resolveStoredPath(pathOrUri);
      return MediaRef(
        // Local ids are the path, so they move with the container too.
        id: id is String && id.isNotEmpty && id != pathOrUri ? id : resolved,
        title: title is String && title.isNotEmpty ? title : p.basename(pathOrUri),
        pathOrUri: resolved,
        isRemote: isRemote,
        duration: Duration(milliseconds: durationMs is num ? durationMs.toInt() : 0),
        seasonNumber: season is int ? season : 0,
        episodeNumber: episode is int ? episode : 0,
      );
    } catch (_) {
      return null;
    }
  }

  static String _normalizeFolderPath(String path) {
    final trimmed = path.trim();
    return trimmed.isEmpty ? '' : p.normalize(trimmed);
  }

  static String _defaultLabel(String path) {
    final name = p.basename(p.normalize(path));
    return name.isEmpty || name == p.separator ? path : name;
  }

  static bool _isHiddenOrSystem(String name) =>
      name.startsWith('.') || _systemEntryNames.contains(name.toLowerCase());

  static Future<int?> _countMedia(String path) async {
    try {
      var count = 0;
      await for (final entity in Directory(path).list(followLinks: true)) {
        if (entity is File && !_isHiddenOrSystem(p.basename(entity.path)) && isVideoPath(entity.path)) count++;
      }
      return count;
    } catch (_) {
      return null;
    }
  }
}
