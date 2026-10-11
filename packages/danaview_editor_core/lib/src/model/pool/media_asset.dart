// OWNER: CORE-04
//
// Pool assets (ARCH §6.8). The pool is outside undo snapshots (ARCH §7.3).

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

import '../../ids/ids.dart';
import '../../time/time.dart';
import 'fingerprint.dart';
import 'media_locator.dart';
import 'media_probe.dart';
import 'picked_media.dart';

const Object _keep = Object();

/// Who owns the file behind an asset. **External files are never modified, moved, renamed or
/// deleted** (G2); only `managedCopy` and `projectOwned` files may be deleted, and only through
/// `OwnedFileDeleter` (ARCH §9.6).
enum MediaOwnership {
  /// The user's original (Files bookmark, content URI, Documents file).
  external,

  /// A content-addressed copy under `<support>/danaview/editor/media/` shared by projects.
  managedCopy,

  /// Made for a project (recording, still, LUT, reversed rendition).
  projectOwned,
}

/// How a derived asset is produced from another asset.
@immutable
sealed class DerivedSpec {
  const DerivedSpec();

  /// Stable content key used for `derived/<specHash>.mp4` and cache lookups.
  String get specHash;
}

/// A reversed rendition of [range] of [media].
final class ReversedSpec extends DerivedSpec {
  /// Creates a reversed spec.
  const ReversedSpec(this.media, this.range, {required this.sourceQuickHash});

  /// Source asset.
  final MediaId media;

  /// Source range reversed.
  final TimeRange range;

  /// `quickHash` of the source (so the spec hash survives relink to the same content).
  final String sourceQuickHash;

  /// A copy with the given fields replaced.
  ReversedSpec copyWith({MediaId? media, TimeRange? range, String? sourceQuickHash}) => ReversedSpec(
        media ?? this.media,
        range ?? this.range,
        sourceQuickHash: sourceQuickHash ?? this.sourceQuickHash,
      );

  @override
  String get specHash =>
      sha1.convert(utf8.encode('reverse:$sourceQuickHash:${range.start}:${range.end}')).toString();

  @override
  bool operator ==(Object other) =>
      other is ReversedSpec && other.media == media && other.range == range && other.sourceQuickHash == sourceQuickHash;

  @override
  int get hashCode => Object.hash(media, range, sourceQuickHash);
}

/// A freeze-frame still of [media] at [sourceTime].
final class StillSpec extends DerivedSpec {
  /// Creates a still spec.
  const StillSpec(this.media, this.sourceTime, {required this.sourceQuickHash});

  /// Source asset.
  final MediaId media;

  /// Source time of the frame.
  final TimeUs sourceTime;

  /// `quickHash` of the source.
  final String sourceQuickHash;

  /// A copy with the given fields replaced.
  StillSpec copyWith({MediaId? media, TimeUs? sourceTime, String? sourceQuickHash}) => StillSpec(
        media ?? this.media,
        sourceTime ?? this.sourceTime,
        sourceQuickHash: sourceQuickHash ?? this.sourceQuickHash,
      );

  @override
  String get specHash => sha1.convert(utf8.encode('still:$sourceQuickHash:$sourceTime')).toString();

  @override
  bool operator ==(Object other) =>
      other is StillSpec && other.media == media && other.sourceTime == sourceTime && other.sourceQuickHash == sourceQuickHash;

  @override
  int get hashCode => Object.hash(media, sourceTime, sourceQuickHash);
}

/// Readiness of an asset.
@immutable
sealed class AssetStatus {
  const AssetStatus();

  /// Ready to use.
  static const AssetStatus ready = ReadyStatus();
}

/// Ready.
final class ReadyStatus extends AssetStatus {
  /// Creates the ready status.
  const ReadyStatus();

  @override
  bool operator ==(Object other) => other is ReadyStatus;

  @override
  int get hashCode => 0;
}

/// Being produced by engine job [jobId] (reverse, freeze frame).
final class PendingStatus extends AssetStatus {
  /// Creates a pending status.
  const PendingStatus(this.jobId);

  /// Engine job id.
  final String jobId;

  /// A copy with the given job id.
  PendingStatus copyWith({String? jobId}) => PendingStatus(jobId ?? this.jobId);

  @override
  bool operator ==(Object other) => other is PendingStatus && other.jobId == jobId;

  @override
  int get hashCode => jobId.hashCode;
}

/// Production failed.
final class FailedStatus extends AssetStatus {
  /// Creates a failed status.
  const FailedStatus(this.reason);

  /// Machine-readable reason (an `EngineErrorCode` name).
  final String reason;

  /// A copy with the given reason.
  FailedStatus copyWith({String? reason}) => FailedStatus(reason ?? this.reason);

  @override
  bool operator ==(Object other) => other is FailedStatus && other.reason == reason;

  @override
  int get hashCode => reason.hashCode;
}

/// Proxy rendition state (ARCH §9.5). Proxies live in `<cache>/danaview/editor/proxies/`.
enum ProxyState {
  /// No proxy.
  none,

  /// Being made.
  pending,

  /// Ready (540 p).
  ready,

  /// Failed.
  failed,
}

/// One asset of a project's media pool.
@immutable
final class MediaAsset {
  /// Creates an asset.
  const MediaAsset({
    required this.id,
    required this.kind,
    required this.displayName,
    required this.locator,
    required this.ownership,
    required this.fingerprint,
    required this.probe,
    required this.origin,
    this.derived,
    this.status = AssetStatus.ready,
    this.proxy = ProxyState.none,
    required this.addedAt,
  });

  /// Stable id within the project.
  final MediaId id;

  /// Kind.
  final MediaKind kind;

  /// Name shown in the media bin.
  final String displayName;

  /// Where the file is.
  final MediaLocator locator;

  /// Who owns the file.
  final MediaOwnership ownership;

  /// Content identity at import.
  final MediaFingerprint fingerprint;

  /// Probe result.
  final MediaProbe probe;

  /// Where it came from.
  final MediaOrigin origin;

  /// How a derived asset is produced, or null.
  final DerivedSpec? derived;

  /// Readiness.
  final AssetStatus status;

  /// Proxy state.
  final ProxyState proxy;

  /// When it was imported (UTC).
  final DateTime addedAt;

  /// A copy with the given fields replaced; pass `derived: null` to clear it.
  MediaAsset copyWith({
    MediaId? id,
    MediaKind? kind,
    String? displayName,
    MediaLocator? locator,
    MediaOwnership? ownership,
    MediaFingerprint? fingerprint,
    MediaProbe? probe,
    MediaOrigin? origin,
    Object? derived = _keep,
    AssetStatus? status,
    ProxyState? proxy,
    DateTime? addedAt,
  }) =>
      MediaAsset(
        id: id ?? this.id,
        kind: kind ?? this.kind,
        displayName: displayName ?? this.displayName,
        locator: locator ?? this.locator,
        ownership: ownership ?? this.ownership,
        fingerprint: fingerprint ?? this.fingerprint,
        probe: probe ?? this.probe,
        origin: origin ?? this.origin,
        derived: identical(derived, _keep) ? this.derived : derived as DerivedSpec?,
        status: status ?? this.status,
        proxy: proxy ?? this.proxy,
        addedAt: addedAt ?? this.addedAt,
      );

  @override
  bool operator ==(Object other) =>
      other is MediaAsset &&
      other.id == id &&
      other.kind == kind &&
      other.displayName == displayName &&
      other.locator == locator &&
      other.ownership == ownership &&
      other.fingerprint == fingerprint &&
      other.probe == probe &&
      other.origin == origin &&
      other.derived == derived &&
      other.status == status &&
      other.proxy == proxy &&
      other.addedAt == addedAt;

  @override
  int get hashCode =>
      Object.hash(id, kind, displayName, locator, ownership, fingerprint, probe, origin, derived, status, proxy, addedAt);
}
