// OWNER: HOM-16
//
// FileEntry, one row per Danaview folder file (ARCH v1.2 §5.1, §5.3 `entries`). The kind is kept
// both decoded ([FileEntry.kind]) and raw ([FileEntry.kindCode]): a 1.3.0 library row with kind
// `savedCode` reads as FileKind.other here and is written back as `savedCode` (BUILD_PLAN HOM-16).
// The `library.db` row mapping itself belongs to HOM-17; [FileEntry.toJson] / [FileEntry.fromJson]
// are the lossless plain-value form it and the tests build on.

import 'package:meta/meta.dart';

import 'document_item.dart';
import 'file_kind.dart';
import 'ids.dart';
import 'source_hint.dart';

const Object _unset = Object();

/// One Danaview folder file (a `library.db` `entries` row, ARCH v1.2 §5.1). Value equality over
/// every field.
@immutable
final class FileEntry {
  /// An entry. [kindCode] is the stored kind string; it defaults to `kind.code` and, when given,
  /// must decode to [kind] (so an unknown code always goes with [FileKind.other]).
  FileEntry({
    required this.id,
    required this.folderId,
    required this.displayName,
    required this.kind,
    String? kindCode,
    this.subKind,
    required this.sizeBytes,
    required this.addedAt,
    required this.modifiedAt,
    this.lastOpenedAt,
    this.isFavourite = false,
    required this.sourceHint,
    this.quickHash,
    this.trashedAt,
    this.expiresAt,
  }) : kindCode = kindCode ?? kind.code {
    if (FileKind.decode(this.kindCode) != kind) {
      throw ArgumentError.value(this.kindCode, 'kindCode', 'does not decode to ${kind.code}');
    }
    if (displayName.isEmpty) throw ArgumentError.value(displayName, 'displayName', 'empty');
    if (sizeBytes < 0) throw ArgumentError.value(sizeBytes, 'sizeBytes', 'negative');
    if ((trashedAt == null) != (expiresAt == null)) {
      throw ArgumentError('trashedAt and expiresAt are set together or not at all');
    }
  }

  /// An entry whose kind is read from the stored string [kindCode] (unknown → [FileKind.other],
  /// the string kept).
  factory FileEntry.stored({
    required EntryId id,
    required FolderId folderId,
    required String displayName,
    required String kindCode,
    String? subKind,
    required int sizeBytes,
    required DateTime addedAt,
    required DateTime modifiedAt,
    DateTime? lastOpenedAt,
    bool isFavourite = false,
    required SourceHint sourceHint,
    String? quickHash,
    DateTime? trashedAt,
    DateTime? expiresAt,
  }) =>
      FileEntry(
        id: id,
        folderId: folderId,
        displayName: displayName,
        kind: FileKind.decode(kindCode),
        kindCode: kindCode,
        subKind: subKind,
        sizeBytes: sizeBytes,
        addedAt: addedAt,
        modifiedAt: modifiedAt,
        lastOpenedAt: lastOpenedAt,
        isFavourite: isFavourite,
        sourceHint: sourceHint,
        quickHash: quickHash,
        trashedAt: trashedAt,
        expiresAt: expiresAt,
      );

  /// The entry id (`fe_…`).
  final EntryId id;

  /// The folder holding the entry (`fd_…`; for a trashed entry, the folder it was in).
  final FolderId folderId;

  /// The file name shown and used on export.
  final String displayName;

  /// The decoded kind ([FileKind.other] for a kind this build doesn't know).
  final FileKind kind;

  /// The kind string as stored; equals `kind.code` unless a later version wrote a new kind.
  final String kindCode;

  /// The sub-kind as stored: a [DocumentKind] code for documents, otherwise free-form or null.
  final String? subKind;

  /// File size in bytes.
  final int sizeBytes;

  /// When the file was added to the library.
  final DateTime addedAt;

  /// When the content last changed.
  final DateTime modifiedAt;

  /// When a viewer last opened it, if ever.
  final DateTime? lastOpenedAt;

  /// Starred.
  final bool isFavourite;

  /// Where it was imported from.
  final SourceHint sourceHint;

  /// The quick-hash fingerprint (size plus sampled bytes), when computed.
  final String? quickHash;

  /// When it was moved to Recently deleted, if it is there.
  final DateTime? trashedAt;

  /// When Recently deleted removes it for good (set with [trashedAt]).
  final DateTime? expiresAt;

  /// True when the stored kind is one this build knows.
  bool get hasKnownKind => FileKind.isKnownCode(kindCode);

  /// True while the entry is in Recently deleted.
  bool get isTrashed => trashedAt != null;

  /// The document type for a document entry (unknown sub-kind → [DocumentKind.other]), else null.
  DocumentKind? get docKind => kind == FileKind.document ? DocumentKind.decode(subKind) : null;

  /// A copy with the given fields replaced. Nullable fields take an explicit `null` to clear them.
  /// Changing [kind] resets [kindCode] to the new kind's code.
  FileEntry copyWith({
    FolderId? folderId,
    String? displayName,
    FileKind? kind,
    Object? subKind = _unset,
    int? sizeBytes,
    DateTime? addedAt,
    DateTime? modifiedAt,
    Object? lastOpenedAt = _unset,
    bool? isFavourite,
    SourceHint? sourceHint,
    Object? quickHash = _unset,
    Object? trashedAt = _unset,
    Object? expiresAt = _unset,
  }) =>
      FileEntry(
        id: id,
        folderId: folderId ?? this.folderId,
        displayName: displayName ?? this.displayName,
        kind: kind ?? this.kind,
        kindCode: kind == null ? kindCode : null,
        subKind: identical(subKind, _unset) ? this.subKind : subKind as String?,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        addedAt: addedAt ?? this.addedAt,
        modifiedAt: modifiedAt ?? this.modifiedAt,
        lastOpenedAt: identical(lastOpenedAt, _unset) ? this.lastOpenedAt : lastOpenedAt as DateTime?,
        isFavourite: isFavourite ?? this.isFavourite,
        sourceHint: sourceHint ?? this.sourceHint,
        quickHash: identical(quickHash, _unset) ? this.quickHash : quickHash as String?,
        trashedAt: identical(trashedAt, _unset) ? this.trashedAt : trashedAt as DateTime?,
        expiresAt: identical(expiresAt, _unset) ? this.expiresAt : expiresAt as DateTime?,
      );

  /// Plain values (strings, ints as UTC milliseconds since the epoch, bools, nulls), lossless: the
  /// raw [kindCode] is written, so an unknown kind round-trips.
  Map<String, Object?> toJson() => {
        'id': id.value,
        'folderId': folderId.value,
        'displayName': displayName,
        'kind': kindCode,
        'subKind': subKind,
        'sizeBytes': sizeBytes,
        'addedAt': _ms(addedAt),
        'modifiedAt': _ms(modifiedAt),
        'lastOpenedAt': _msOrNull(lastOpenedAt),
        'isFavourite': isFavourite,
        'sourceHint': sourceHint.code,
        'quickHash': quickHash,
        'trashedAt': _msOrNull(trashedAt),
        'expiresAt': _msOrNull(expiresAt),
      };

  /// The entry [json] describes (the form [toJson] writes). Throws [FormatException] for a missing
  /// or mistyped field or a malformed id.
  factory FileEntry.fromJson(Map<String, Object?> json) {
    T field<T>(String key) {
      final value = json[key];
      if (value is T) return value;
      throw FormatException('FileEntry field "$key" is not a $T');
    }

    DateTime? time(String key) {
      final ms = field<int?>(key);
      return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    }

    try {
      return FileEntry.stored(
        id: EntryId.parse(field<String>('id')),
        folderId: FolderId.parse(field<String>('folderId')),
        displayName: field<String>('displayName'),
        kindCode: field<String>('kind'),
        subKind: field<String?>('subKind'),
        sizeBytes: field<int>('sizeBytes'),
        addedAt: time('addedAt') ?? (throw const FormatException('FileEntry field "addedAt" is missing')),
        modifiedAt: time('modifiedAt') ?? (throw const FormatException('FileEntry field "modifiedAt" is missing')),
        lastOpenedAt: time('lastOpenedAt'),
        isFavourite: field<bool>('isFavourite'),
        sourceHint: SourceHint.decode(field<String>('sourceHint')),
        quickHash: field<String?>('quickHash'),
        trashedAt: time('trashedAt'),
        expiresAt: time('expiresAt'),
      );
    } on ArgumentError catch (e) {
      throw FormatException('FileEntry is invalid: ${e.message}');
    }
  }

  static int _ms(DateTime t) => t.toUtc().millisecondsSinceEpoch;

  static int? _msOrNull(DateTime? t) => t == null ? null : _ms(t);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FileEntry &&
          other.id == id &&
          other.folderId == folderId &&
          other.displayName == displayName &&
          other.kind == kind &&
          other.kindCode == kindCode &&
          other.subKind == subKind &&
          other.sizeBytes == sizeBytes &&
          other.addedAt.isAtSameMomentAs(addedAt) &&
          other.modifiedAt.isAtSameMomentAs(modifiedAt) &&
          _sameMoment(other.lastOpenedAt, lastOpenedAt) &&
          other.isFavourite == isFavourite &&
          other.sourceHint == sourceHint &&
          other.quickHash == quickHash &&
          _sameMoment(other.trashedAt, trashedAt) &&
          _sameMoment(other.expiresAt, expiresAt);

  static bool _sameMoment(DateTime? a, DateTime? b) => a == null ? b == null : b != null && a.isAtSameMomentAs(b);

  @override
  int get hashCode => Object.hash(
        id,
        folderId,
        displayName,
        kindCode,
        subKind,
        sizeBytes,
        _ms(addedAt),
        _ms(modifiedAt),
        _msOrNull(lastOpenedAt),
        isFavourite,
        sourceHint,
        quickHash,
        _msOrNull(trashedAt),
        _msOrNull(expiresAt),
      );

  @override
  String toString() => 'FileEntry(${id.value}, $kindCode${subKind == null ? '' : '/$subKind'})';
}
