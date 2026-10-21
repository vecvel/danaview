// OWNER: HOM-01
//
// Namespaced item ids (ARCH v1.2 V2-09, BUILD_PLAN HOM-01):
//
//   fe_<token>                       a Danaview folder entry (a row of library.db `entries`)
//   fd_<token>                       a Danaview folder (a row of library.db `folders`)
//   lk:<linkedRootId>/<relativePath> a file in a linked folder (read-only, listed live)
//   ph:<localIdentifier>             a PhotoKit asset (listed live)
//   ms:<id>                          a MediaStore item (listed live)
//
// Ids are zero-cost extension types over String, so they serialise as the plain string and compare
// with `==` like strings. `ItemId.parse` / `tryParse` validate strictly; `ItemId.opaque` carries a
// v1.1 `MediaRef.id` (a path or URL) unchanged so the MediaRef bridge never loses or rejects one.

import 'dart:math';

/// The namespace of an [ItemId] (V2-09).
enum IdNamespace {
  /// `fe_…`: a Danaview folder entry.
  entry('fe_'),

  /// `fd_…`: a Danaview folder.
  folder('fd_'),

  /// `lk:<linkedRootId>/<relativePath>`: a file in a linked folder.
  linked('lk:'),

  /// `ph:<localIdentifier>`: a PhotoKit asset.
  photoKit('ph:'),

  /// `ms:<id>`: a MediaStore item.
  mediaStore('ms:'),

  /// A v1.1 `MediaRef.id` (a file path or a URL) that carries no V2-09 namespace.
  legacy('');

  const IdNamespace(this.prefix);

  /// The id prefix of this namespace (empty for [legacy]).
  final String prefix;

  /// The namespaces whose ids have a prefix, in matching order.
  static const List<IdNamespace> prefixed = [entry, folder, linked, photoKit, mediaStore];
}

/// Thrown by the strict id parsers for a malformed id.
class MalformedIdException extends FormatException {
  /// A malformed-id error for [source] with the reason [message].
  const MalformedIdException(super.message, String super.source);
}

/// The longest id accepted (linked ids carry a relative path).
const int maxItemIdLength = 4096;

/// Longest token of `fe_`, `fd_` and a linked root id.
const int maxTokenLength = 64;

/// Longest PhotoKit local identifier accepted.
const int maxPhotoKitIdentifierLength = 256;

final RegExp _token = RegExp(r'^[A-Za-z0-9_-]+$');
final RegExp _digits = RegExp(r'^(0|[1-9][0-9]{0,18})$');
final RegExp _control = RegExp(r'[\x00-\x1F\x7F]');
final RegExp _whitespaceOrControl = RegExp(r'[\s\x00-\x1F\x7F]');

/// The reason [value] is not a valid id of [ns], or null when it is.
String? _problem(IdNamespace ns, String value) {
  if (value.length > maxItemIdLength) return 'id longer than $maxItemIdLength characters';
  if (!value.startsWith(ns.prefix)) return 'id does not start with "${ns.prefix}"';
  final body = value.substring(ns.prefix.length);
  switch (ns) {
    case IdNamespace.entry:
    case IdNamespace.folder:
      return _tokenProblem(body, 'token');
    case IdNamespace.linked:
      final slash = body.indexOf('/');
      if (slash < 0) return 'linked id has no "/" between root id and relative path';
      final rootProblem = _tokenProblem(body.substring(0, slash), 'linked root id');
      if (rootProblem != null) return rootProblem;
      return _relativePathProblem(body.substring(slash + 1));
    case IdNamespace.photoKit:
      if (body.isEmpty) return 'empty PhotoKit local identifier';
      if (body.length > maxPhotoKitIdentifierLength) {
        return 'PhotoKit local identifier longer than $maxPhotoKitIdentifierLength characters';
      }
      if (_whitespaceOrControl.hasMatch(body)) return 'PhotoKit local identifier contains whitespace';
      return null;
    case IdNamespace.mediaStore:
      if (!_digits.hasMatch(body)) return 'MediaStore id is not a non-negative 64-bit integer';
      if (BigInt.parse(body) > BigInt.parse('9223372036854775807')) return 'MediaStore id exceeds 64 bits';
      return null;
    case IdNamespace.legacy:
      return 'legacy ids are not parsed; use ItemId.opaque';
  }
}

String? _tokenProblem(String token, String what) {
  if (token.isEmpty) return 'empty $what';
  if (token.length > maxTokenLength) return '$what longer than $maxTokenLength characters';
  if (!_token.hasMatch(token)) return '$what has characters outside [A-Za-z0-9_-]';
  return null;
}

String? _relativePathProblem(String path) {
  if (path.isEmpty) return 'empty relative path';
  if (path.startsWith('/')) return 'relative path starts with "/"';
  if (path.contains(r'\')) return r'relative path contains "\" (use "/")';
  if (_control.hasMatch(path)) return 'relative path contains control characters';
  for (final segment in path.split('/')) {
    if (segment.isEmpty) return 'relative path has an empty segment';
    if (segment == '.' || segment == '..') return 'relative path has a "$segment" segment';
  }
  return null;
}

T _parseAs<T>(IdNamespace ns, String value, T Function(String) wrap) {
  final problem = _problem(ns, value);
  if (problem != null) throw MalformedIdException(problem, value);
  return wrap(value);
}

T? _tryParseAs<T>(IdNamespace ns, String value, T Function(String) wrap) =>
    _problem(ns, value) == null ? wrap(value) : null;

/// The namespace [value] validly belongs to, or null when it is malformed or has no prefix.
IdNamespace? _validNamespace(String value) {
  for (final ns in IdNamespace.prefixed) {
    if (value.startsWith(ns.prefix)) return _problem(ns, value) == null ? ns : null;
  }
  return null;
}

/// The id of any library item or folder (V2-09).
extension type const ItemId._(String value) {
  /// Parses a namespaced id; throws [MalformedIdException] when [value] is malformed or has no
  /// V2-09 prefix.
  factory ItemId.parse(String value) {
    for (final ns in IdNamespace.prefixed) {
      if (value.startsWith(ns.prefix)) return _parseAs(ns, value, ItemId._);
    }
    throw MalformedIdException('id has no fe_, fd_, lk:, ph: or ms: prefix', value);
  }

  /// [value] as an id when it is a valid namespaced id, else null.
  static ItemId? tryParse(String value) => _validNamespace(value) == null ? null : ItemId._(value);

  /// A v1.1 `MediaRef.id` (path, URL, or an id already namespaced) carried unchanged. Never
  /// throws: [namespace] says [IdNamespace.legacy] unless [value] is a valid namespaced id.
  const ItemId.opaque(String value) : this._(value);

  /// The namespace of this id; [IdNamespace.legacy] for an opaque v1.1 id.
  IdNamespace get namespace => _validNamespace(value) ?? IdNamespace.legacy;

  /// True for a valid namespaced id (not a legacy v1.1 id).
  bool get isNamespaced => _validNamespace(value) != null;

  /// True for ids whose rows live in `library.db` (`fe_`, `fd_`; V2-09).
  bool get isInLibraryDb => switch (namespace) {
        IdNamespace.entry || IdNamespace.folder => true,
        _ => false,
      };

  /// This id as an [EntryId], or null when it is not one.
  EntryId? get asEntry => EntryId.tryParse(value);

  /// This id as a [FolderId], or null when it is not one.
  FolderId? get asFolder => FolderId.tryParse(value);

  /// This id as a [LinkedItemId], or null when it is not one.
  LinkedItemId? get asLinked => LinkedItemId.tryParse(value);

  /// This id as a [PhotoKitId], or null when it is not one.
  PhotoKitId? get asPhotoKit => PhotoKitId.tryParse(value);

  /// This id as a [MediaStoreId], or null when it is not one.
  MediaStoreId? get asMediaStore => MediaStoreId.tryParse(value);
}

String _randomToken(Random random, int length) {
  const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
  return String.fromCharCodes(
    List.generate(length, (_) => alphabet.codeUnitAt(random.nextInt(alphabet.length))),
  );
}

/// `fe_…`: a Danaview folder entry (a `library.db` `entries` row).
extension type const EntryId._(String value) implements ItemId {
  /// Parses an entry id; throws [MalformedIdException] when malformed.
  factory EntryId.parse(String value) => _parseAs(IdNamespace.entry, value, EntryId._);

  /// [value] as an entry id, or null when malformed.
  static EntryId? tryParse(String value) => _tryParseAs(IdNamespace.entry, value, EntryId._);

  /// A new random entry id (`fe_` + 22 lowercase base-36 characters, about 113 bits).
  factory EntryId.random([Random? random]) => EntryId._('fe_${_randomToken(random ?? Random.secure(), 22)}');

  /// The part after `fe_`.
  String get token => value.substring(3);
}

/// `fd_…`: a Danaview folder (a `library.db` `folders` row).
extension type const FolderId._(String value) implements ItemId {
  /// Parses a folder id; throws [MalformedIdException] when malformed.
  factory FolderId.parse(String value) => _parseAs(IdNamespace.folder, value, FolderId._);

  /// [value] as a folder id, or null when malformed.
  static FolderId? tryParse(String value) => _tryParseAs(IdNamespace.folder, value, FolderId._);

  /// A new random folder id (`fd_` + 22 lowercase base-36 characters, about 113 bits).
  factory FolderId.random([Random? random]) => FolderId._('fd_${_randomToken(random ?? Random.secure(), 22)}');

  /// The part after `fd_`.
  String get token => value.substring(3);
}

/// `lk:<linkedRootId>/<relativePath>`: a file in a linked folder (read-only).
extension type const LinkedItemId._(String value) implements ItemId {
  /// Parses a linked id; throws [MalformedIdException] when malformed.
  factory LinkedItemId.parse(String value) => _parseAs(IdNamespace.linked, value, LinkedItemId._);

  /// [value] as a linked id, or null when malformed.
  static LinkedItemId? tryParse(String value) => _tryParseAs(IdNamespace.linked, value, LinkedItemId._);

  /// The linked id of [relativePath] (`/`-separated) under the linked root [rootId]; throws
  /// [MalformedIdException] when either part is invalid.
  factory LinkedItemId.of(String rootId, String relativePath) => LinkedItemId.parse('lk:$rootId/$relativePath');

  /// The linked root id.
  String get rootId => value.substring(3, value.indexOf('/'));

  /// The `/`-separated path under the linked root.
  String get relativePath => value.substring(value.indexOf('/') + 1);
}

/// `ph:<localIdentifier>`: a PhotoKit asset.
extension type const PhotoKitId._(String value) implements ItemId {
  /// Parses a PhotoKit id; throws [MalformedIdException] when malformed.
  factory PhotoKitId.parse(String value) => _parseAs(IdNamespace.photoKit, value, PhotoKitId._);

  /// [value] as a PhotoKit id, or null when malformed.
  static PhotoKitId? tryParse(String value) => _tryParseAs(IdNamespace.photoKit, value, PhotoKitId._);

  /// The id of the asset with `PHAsset.localIdentifier` [localIdentifier].
  factory PhotoKitId.of(String localIdentifier) => PhotoKitId.parse('ph:$localIdentifier');

  /// The `PHAsset.localIdentifier`.
  String get localIdentifier => value.substring(3);
}

/// `ms:<id>`: a MediaStore item.
extension type const MediaStoreId._(String value) implements ItemId {
  /// Parses a MediaStore id; throws [MalformedIdException] when malformed.
  factory MediaStoreId.parse(String value) => _parseAs(IdNamespace.mediaStore, value, MediaStoreId._);

  /// [value] as a MediaStore id, or null when malformed.
  static MediaStoreId? tryParse(String value) => _tryParseAs(IdNamespace.mediaStore, value, MediaStoreId._);

  /// The id of the MediaStore row with `_ID` [id]; throws [MalformedIdException] when negative.
  factory MediaStoreId.of(int id) => MediaStoreId.parse('ms:$id');

  /// The MediaStore `_ID`.
  int get mediaStoreId => int.parse(value.substring(3));
}
