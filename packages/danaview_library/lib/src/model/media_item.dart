// OWNER: HOM-01
//
// The library item model (ARCH v1.2 §5.1, BUILD_PLAN HOM-01): a sealed MediaItem with
// VideoMediaItem, PhotoMediaItem and the DocumentMediaItem slot HOM-16's DocumentItem fills.
// A sealed class only admits direct subclasses from its own library, so the document slot is an
// abstract base class here that HOM-16 extends from `document_item.dart`; switches over MediaItem
// stay exhaustive. Items compare and hash by id only (V2-09). The player keeps receiving MediaRef:
// VideoMediaItem.toMediaRef() and MediaRefBridge.fromMediaRef() (media_ref_bridge.dart) round-trip
// every MediaRef field (HOM plan §4.1, ARCH §1.5).

import 'package:danaview_domain/danaview_domain.dart';
import 'package:meta/meta.dart';

import 'ids.dart';

/// One item the Files & Media Home shows: a video, a photo or a document (ARCH v1.2 §5.1).
///
/// Equality and hashing are by [id] only: two values with the same id are the same item, whatever
/// their metadata snapshot.
@immutable
sealed class MediaItem {
  MediaItem({
    required this.id,
    required this.uri,
    required this.name,
    required this.modifiedAt,
    required this.mimeType,
    this.sizeBytes,
  }) {
    if (id.namespace == IdNamespace.folder) {
      throw ArgumentError.value(id, 'id', 'a folder id (fd_) is not an item id');
    }
    if (sizeBytes != null && sizeBytes! < 0) throw ArgumentError.value(sizeBytes, 'sizeBytes', 'negative');
  }

  /// The V2-09 id (`fe_`, `lk:`, `ph:`, `ms:`, or a legacy v1.1 `MediaRef.id`).
  final ItemId id;

  /// Where the bytes are: a file path, a `danaview-library://`, `content://` or `ph://` URI, or a
  /// stream URL.
  final String uri;

  /// The name shown in the UI.
  final String name;

  /// Size in bytes; null when unknown (remote streams, assets whose size isn't fetched yet, v1.1
  /// refs without a size).
  final int? sizeBytes;

  /// Last modification time of the content.
  final DateTime modifiedAt;

  /// MIME type (`video/mp4`, `image/heic`, …; `application/octet-stream` when unknown).
  final String mimeType;

  @override
  bool operator ==(Object other) => identical(this, other) || other is MediaItem && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => '$runtimeType(${id.value})';
}

/// A video item. Wraps every field of the v1.1 `MediaRef` so [toMediaRef] gives the player the same
/// value it received in 1.1 (HOM plan §4.1).
final class VideoMediaItem extends MediaItem {
  /// A video item. [duration] is [Duration.zero] when unknown, [frameRate] 0 when unknown.
  VideoMediaItem({
    required super.id,
    required super.uri,
    required super.name,
    required super.modifiedAt,
    required super.mimeType,
    super.sizeBytes,
    this.duration = Duration.zero,
    this.frameRate = 0,
    this.codec,
    this.hasAudio = true,
    this.resumePosition,
    this.isRemote = false,
    this.width,
    this.height,
    this.audioCodec,
    this.container,
    this.quickHash,
    this.posterPath,
    this.seasonNumber = 0,
    this.episodeNumber = 0,
  }) {
    if (frameRate < 0 || frameRate.isNaN) throw ArgumentError.value(frameRate, 'frameRate', 'not >= 0');
  }

  /// Length of the video; [Duration.zero] when unknown.
  final Duration duration;

  /// Frames per second; 0 when unknown.
  final double frameRate;

  /// Video codec (`MediaRef.videoCodec`).
  final String? codec;

  /// Whether the video has an audio track (true when unknown).
  final bool hasAudio;

  /// Where playback resumes (Continue watching), if anywhere.
  final Duration? resumePosition;

  /// True for a stream URL (`MediaRef.isRemote`).
  final bool isRemote;

  /// Picture width in pixels, if known.
  final int? width;

  /// Picture height in pixels, if known.
  final int? height;

  /// Audio codec, if known.
  final String? audioCodec;

  /// Container format, if known.
  final String? container;

  /// The v1.1 quick-hash fingerprint, if computed.
  final String? quickHash;

  /// Path of a poster image, if any.
  final String? posterPath;

  /// Season parsed from the name (0 when none).
  final int seasonNumber;

  /// Episode parsed from the name (0 when none).
  final int episodeNumber;

  /// The `MediaRef` the player, `LibraryController` and `danaviewPlayItems(ref, items)` receive.
  /// Every `MediaRef` field round-trips through `MediaRefBridge.fromMediaRef`.
  MediaRef toMediaRef() => MediaRef(
        id: id.value,
        title: name,
        pathOrUri: uri,
        isRemote: isRemote,
        duration: duration,
        width: width,
        height: height,
        videoCodec: codec,
        audioCodec: audioCodec,
        container: container,
        fileSize: sizeBytes,
        quickHash: quickHash,
        posterPath: posterPath,
        seasonNumber: seasonNumber,
        episodeNumber: episodeNumber,
      );
}

/// A still photo item (ARCH v1.2 §5.1).
final class PhotoMediaItem extends MediaItem {
  /// A photo item; [width] and [height] are 0 when unknown.
  PhotoMediaItem({
    required super.id,
    required super.uri,
    required super.name,
    required super.modifiedAt,
    required super.mimeType,
    super.sizeBytes,
    this.width = 0,
    this.height = 0,
    this.isRaw = false,
    this.isHdr = false,
    this.isLivePhoto = false,
    this.iso,
    this.aperture,
    this.cameraModel,
    this.takenAt,
  }) {
    if (width < 0) throw ArgumentError.value(width, 'width', 'negative');
    if (height < 0) throw ArgumentError.value(height, 'height', 'negative');
  }

  /// Pixel width (0 when unknown).
  final int width;

  /// Pixel height (0 when unknown).
  final int height;

  /// A RAW capture (DNG, CR3, NEF, ARW, …, or a PhotoKit RAW resource).
  final bool isRaw;

  /// An HDR capture (gain map or HDR flag).
  final bool isHdr;

  /// A Live Photo (still with a paired movie).
  final bool isLivePhoto;

  /// EXIF ISO, if known.
  final int? iso;

  /// EXIF f-number, if known.
  final double? aperture;

  /// EXIF camera model, if known.
  final String? cameraModel;

  /// Capture time, if known.
  final DateTime? takenAt;

  /// Megapixels (0 when the size is unknown).
  double get megapixels => width * height / 1e6;
}

/// The document slot of the sealed [MediaItem] hierarchy. HOM-16's `DocumentItem`
/// (`document_item.dart`: `docKind`, `pageCount`, `textEncoding`) extends it; code switching over
/// [MediaItem] matches documents with this type.
abstract base class DocumentMediaItem extends MediaItem {
  /// A document item.
  DocumentMediaItem({
    required super.id,
    required super.uri,
    required super.name,
    required super.modifiedAt,
    required super.mimeType,
    super.sizeBytes,
  });
}
