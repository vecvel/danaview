// OWNER: HOM-19
//
// Where a sort is remembered (HOM plan §8.1 "remembered per folder"). A Danaview folder keeps its
// sort in library.db (`folders.sort_mode`, `sort_desc`, ARCH §5.3), so it travels with backups and
// survives a rename or a move. Every other list (the All, Videos, Photos and Documents tabs,
// Favourites, a linked folder, the system library) keeps it in a small key-value store the app
// root backs with SharedPreferences (the FEAT adapter); keys are `organise.sort.<scope key>`.

import 'package:meta/meta.dart';

import '../model/ids.dart';

/// A list whose sort is remembered.
@immutable
sealed class SortScope {
  const SortScope();

  /// A Danaview folder (stored in library.db).
  const factory SortScope.folder(FolderId id) = FolderSortScope;

  /// Any other list, named by a stable [key] (`tab:all`, `favourites`, `linked:<path>`, …).
  const factory SortScope.named(String key) = NamedSortScope;
}

/// A Danaview folder's sort.
final class FolderSortScope extends SortScope {
  /// The scope of folder [id].
  const FolderSortScope(this.id);

  /// The folder.
  final FolderId id;

  @override
  bool operator ==(Object other) => other is FolderSortScope && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// A named list's sort.
final class NamedSortScope extends SortScope {
  /// The scope named [key].
  const NamedSortScope(this.key);

  /// The All tab.
  static const NamedSortScope allTab = NamedSortScope('tab:all');

  /// The Videos tab.
  static const NamedSortScope videosTab = NamedSortScope('tab:videos');

  /// The Photos tab.
  static const NamedSortScope photosTab = NamedSortScope('tab:photos');

  /// The Documents tab.
  static const NamedSortScope documentsTab = NamedSortScope('tab:documents');

  /// The Favourites list.
  static const NamedSortScope favourites = NamedSortScope('favourites');

  /// The scope of a linked folder at [path] (the 1.1 folder browser).
  factory NamedSortScope.linkedFolder(String path) => NamedSortScope('linked:$path');

  /// The stable name.
  final String key;

  /// The preference key it is stored under.
  String get preferenceKey => 'organise.sort.$key';

  @override
  bool operator ==(Object other) => other is NamedSortScope && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// The key-value store of named sorts (SharedPreferences in the app).
abstract interface class SortPreferenceStore {
  /// The value under [key], or null.
  String? read(String key);

  /// Stores [value] under [key] (null removes it).
  Future<void> write(String key, String? value);
}

/// A [SortPreferenceStore] in memory (tests, and the app before preferences load).
final class InMemorySortPreferenceStore implements SortPreferenceStore {
  /// An empty store, or one holding [initial].
  InMemorySortPreferenceStore([Map<String, String>? initial]) : values = {...?initial};

  /// What it holds.
  final Map<String, String> values;

  @override
  String? read(String key) => values[key];

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}
