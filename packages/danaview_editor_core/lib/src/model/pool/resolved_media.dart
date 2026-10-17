// OWNER: CORE-04

import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

const Object _keep = Object();

/// A media file resolved for the engine at this moment (D-27; `EngineMedia` is a typedef of
/// this type). Never persisted.
@immutable
final class ResolvedMedia {
  /// Creates a resolved media reference.
  const ResolvedMedia({required this.uri, required this.fingerprint, this.bookmark, this.isProxy = false});

  /// `file://` or `content://` URI (never http).
  final String uri;

  /// `quickHash` of the original (cache key).
  final String fingerprint;

  /// iOS security-scoped bookmark; the engine refcounts access per session.
  final Uint8List? bookmark;

  /// Whether [uri] is a proxy rendition (same timestamps as the original).
  final bool isProxy;

  /// A copy with the given fields replaced; pass `bookmark: null` to clear it.
  ResolvedMedia copyWith({String? uri, String? fingerprint, Object? bookmark = _keep, bool? isProxy}) =>
      ResolvedMedia(
        uri: uri ?? this.uri,
        fingerprint: fingerprint ?? this.fingerprint,
        bookmark: identical(bookmark, _keep) ? this.bookmark : bookmark as Uint8List?,
        isProxy: isProxy ?? this.isProxy,
      );

  @override
  bool operator ==(Object other) =>
      other is ResolvedMedia &&
      other.uri == uri &&
      other.fingerprint == fingerprint &&
      other.isProxy == isProxy &&
      const ListEquality<int>().equals(other.bookmark, bookmark);

  @override
  int get hashCode => Object.hash(uri, fingerprint, isProxy, bookmark == null ? null : Object.hashAll(bookmark!));
}
