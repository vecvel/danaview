// OWNER: CORE-04
//
// Content fingerprints (ARCH §6.8). `quickHash` reproduces danaview_data's
// `MediaIdentityService.computeQuickHash` byte for byte, so player, editor caches and AI
// transcripts agree.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

import '../../time/time.dart';

const Object _keep = Object();

/// Bytes read from each end of a file for [computeQuickHash].
const int quickHashChunkBytes = 64 * 1024;

/// `sha1(head + tail + utf8(':$size'))` where `head` is the first `min(size, 64 KiB)` bytes and
/// `tail` is the last 64 KiB **only when `size > 64 KiB`** (overlapping head when size < 128 KiB).
/// An empty file hashes to `''`. Callers read the bytes (dart:io under `store/`, or natively).
String computeQuickHash(Uint8List head, Uint8List tail, int size) {
  if (size == 0) return '';
  final b = BytesBuilder(copy: false)
    ..add(head)
    ..add(size > quickHashChunkBytes ? tail : Uint8List(0))
    ..add(utf8.encode(':$size'));
  return sha1.convert(b.takeBytes()).toString();
}

/// Identity of a media file's content at import time.
@immutable
final class MediaFingerprint {
  /// Creates a fingerprint.
  const MediaFingerprint({required this.sizeBytes, required this.quickHash, this.modifiedMs, this.duration = 0});

  /// File size in bytes.
  final int sizeBytes;

  /// See [computeQuickHash]. Also the key of every editor cache (D-26).
  final String quickHash;

  /// Modification time (ms since epoch), when known.
  final int? modifiedMs;

  /// Probed duration.
  final TimeUs duration;

  /// A copy with the given fields replaced; pass `modifiedMs: null` to clear it.
  MediaFingerprint copyWith({int? sizeBytes, String? quickHash, Object? modifiedMs = _keep, TimeUs? duration}) =>
      MediaFingerprint(
        sizeBytes: sizeBytes ?? this.sizeBytes,
        quickHash: quickHash ?? this.quickHash,
        modifiedMs: identical(modifiedMs, _keep) ? this.modifiedMs : modifiedMs as int?,
        duration: duration ?? this.duration,
      );

  @override
  bool operator ==(Object other) =>
      other is MediaFingerprint &&
      other.sizeBytes == sizeBytes &&
      other.quickHash == quickHash &&
      other.modifiedMs == modifiedMs &&
      other.duration == duration;

  @override
  int get hashCode => Object.hash(sizeBytes, quickHash, modifiedMs, duration);

  @override
  String toString() => 'MediaFingerprint($sizeBytes bytes, $quickHash)';
}
