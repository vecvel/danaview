// OWNER: CORE-04
//
// The media access port (ARCH §9.2). Defined in core (model/pool) so the engine API can implement
// it at M0; `DartIoMediaAccess` (CORE-27) implements it for plain paths.

import 'package:meta/meta.dart';

import 'media_locator.dart';
import 'picked_media.dart';
import 'resolved_media.dart';

const Object _keep = Object();

/// File metadata returned by [MediaAccessPort.stat].
@immutable
final class MediaStat {
  /// Creates a stat result.
  const MediaStat({required this.sizeBytes, this.modifiedMs});

  /// Size in bytes.
  final int sizeBytes;

  /// Modification time (ms since epoch), when available.
  final int? modifiedMs;

  /// A copy with the given fields replaced; pass `modifiedMs: null` to clear it.
  MediaStat copyWith({int? sizeBytes, Object? modifiedMs = _keep}) => MediaStat(
        sizeBytes: sizeBytes ?? this.sizeBytes,
        modifiedMs: identical(modifiedMs, _keep) ? this.modifiedMs : modifiedMs as int?,
      );

  @override
  bool operator ==(Object other) =>
      other is MediaStat && other.sizeBytes == sizeBytes && other.modifiedMs == modifiedMs;

  @override
  int get hashCode => Object.hash(sizeBytes, modifiedMs);

  @override
  String toString() => 'MediaStat($sizeBytes bytes, modifiedMs: $modifiedMs)';
}

/// Why access to media failed.
enum MediaAccessFailureKind {
  /// A grant was revoked or a bookmark can no longer be resolved.
  accessLost,

  /// The OS denied access.
  permissionDenied,

  /// Not found.
  notFound,

  /// The operation targeted a path outside the editor roots (a bug; never performed).
  outsideEditorRoots,

  /// Other I/O failure.
  io,
}

/// Typed media access failure (never contains paths in [debugDetail]).
final class MediaAccessFailure implements Exception {
  /// Creates a failure.
  const MediaAccessFailure(this.kind, [this.debugDetail = '']);

  /// Kind.
  final MediaAccessFailureKind kind;

  /// Diagnostic text without paths or user content.
  final String debugDetail;

  /// A copy with the given fields replaced.
  MediaAccessFailure copyWith({MediaAccessFailureKind? kind, String? debugDetail}) =>
      MediaAccessFailure(kind ?? this.kind, debugDetail ?? this.debugDetail);

  @override
  bool operator ==(Object other) =>
      other is MediaAccessFailure && other.kind == kind && other.debugDetail == debugDetail;

  @override
  int get hashCode => Object.hash(kind, debugDetail);

  @override
  String toString() => 'MediaAccessFailure($kind${debugDetail.isEmpty ? '' : ': $debugDetail'})';
}

/// Platform access to media files: resolve locators, stat, hash, persist grants/bookmarks.
///
/// Implemented by the engine plugin (`MediaAccess`, ENG-03 + IOS-15/AND-14) and by
/// `DartIoMediaAccess` (CORE-27) for plain paths.
abstract interface class MediaAccessPort {
  /// Resolves [locator] for the engine, refreshing stale bookmarks.
  Future<ResolvedMedia> resolve(MediaLocator locator);

  /// Size and modification time, or null when the file is missing. Throws
  /// [MediaAccessFailure] (`accessLost`) when a grant/bookmark no longer works.
  Future<MediaStat?> stat(MediaLocator locator);

  /// `quickHash` of the file (same algorithm as `computeQuickHash`).
  Future<String> quickHash(MediaLocator locator);

  /// Turns a picked item into a durable locator (bookmark, persisted URI grant or app-relative
  /// path). Managed copies are made by `ManagedStore` (CORE-27), not here.
  Future<MediaLocator> persist(PickedMediaHandle handle);

  /// Releases a bookmark or URI grant no project references any more.
  Future<void> release(MediaLocator locator);

  /// Marks [dirPath] excluded from device backups. Implementations must refuse (throw
  /// [MediaAccessFailure] `outsideEditorRoots`) any path outside the editor/speech roots.
  Future<void> excludeFromBackup(String dirPath);

  /// Persisted URI grants still available (Android); a large number on iOS.
  Future<int> remainingGrantBudget();
}
