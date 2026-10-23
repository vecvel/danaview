// OWNER: HOM-01
//
// MediaRef interop (ARCH v1.2 §1.5, HOM plan §4.1): the player, LibraryController and
// danaviewPlayItems(ref, items) keep receiving the v1.1 MediaRef unchanged. fromMediaRef wraps a
// MediaRef as a VideoMediaItem without losing any field; VideoMediaItem.toMediaRef (media_item.dart)
// gives it back. danaview_domain is not changed.

import 'package:danaview_domain/danaview_domain.dart';

import 'ids.dart';
import 'media_item.dart';

/// Converts between the v1.1 `MediaRef` and the 1.2.0 [VideoMediaItem].
abstract final class MediaRefBridge {
  /// The modification time given to items made from a `MediaRef`, which has none.
  static final DateTime unknownModifiedAt = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  /// [ref] as a [VideoMediaItem]. Every `MediaRef` field is kept, so
  /// `fromMediaRef(ref).toMediaRef()` equals [ref] field by field. The id is carried as
  /// [ItemId.opaque] (v1.1 ids are paths or URLs). The extra 1.2.0 fields come from the named
  /// arguments; [mimeType] defaults to one inferred from the file extension.
  static VideoMediaItem fromMediaRef(
    MediaRef ref, {
    DateTime? modifiedAt,
    String? mimeType,
    double frameRate = 0,
    bool hasAudio = true,
    Duration? resumePosition,
  }) =>
      VideoMediaItem(
        id: ItemId.opaque(ref.id),
        uri: ref.pathOrUri,
        name: ref.title,
        modifiedAt: modifiedAt ?? unknownModifiedAt,
        mimeType: mimeType ?? videoMimeTypeFor(ref.pathOrUri, isRemote: ref.isRemote),
        sizeBytes: ref.fileSize,
        duration: ref.duration,
        frameRate: frameRate,
        codec: ref.videoCodec,
        hasAudio: hasAudio,
        resumePosition: resumePosition,
        isRemote: ref.isRemote,
        width: ref.width,
        height: ref.height,
        audioCodec: ref.audioCodec,
        container: ref.container,
        quickHash: ref.quickHash,
        posterPath: ref.posterPath,
        seasonNumber: ref.seasonNumber,
        episodeNumber: ref.episodeNumber,
      );

  /// [item] as the `MediaRef` the player receives (same as [VideoMediaItem.toMediaRef]).
  static MediaRef toMediaRef(VideoMediaItem item) => item.toMediaRef();

  /// The `MediaRef`s of the videos in [items], in order (photos and documents are skipped), for
  /// `danaviewPlayItems(ref, items)` queues.
  static List<MediaRef> playableRefs(Iterable<MediaItem> items) =>
      [for (final item in items) if (item is VideoMediaItem) item.toMediaRef()];

  static const Map<String, String> _videoMimeByExtension = {
    'mp4': 'video/mp4',
    'm4v': 'video/x-m4v',
    'mov': 'video/quicktime',
    'mkv': 'video/x-matroska',
    'webm': 'video/webm',
    'avi': 'video/x-msvideo',
    'ts': 'video/mp2t',
    'm2ts': 'video/mp2t',
    'mts': 'video/mp2t',
    'flv': 'video/x-flv',
    'wmv': 'video/x-ms-wmv',
    'ogv': 'video/ogg',
    '3gp': 'video/3gpp',
    'mpg': 'video/mpeg',
    'mpeg': 'video/mpeg',
  };

  /// The MIME type of the v1.1 video extensions, `application/octet-stream` otherwise. Query and
  /// fragment are ignored for remote URLs. (HOM-16's classifier is the full table, ARCH §5.1.)
  static String videoMimeTypeFor(String pathOrUri, {bool isRemote = false}) {
    var path = pathOrUri;
    if (isRemote) path = path.split(RegExp(r'[?#]')).first;
    final name = path.split(RegExp(r'[/\\]')).last;
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return 'application/octet-stream';
    return _videoMimeByExtension[name.substring(dot + 1).toLowerCase()] ?? 'application/octet-stream';
  }
}
