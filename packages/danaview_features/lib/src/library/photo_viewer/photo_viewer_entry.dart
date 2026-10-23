// OWNER: HOM-11
//
// What the fullscreen photo viewer knows about one photo (ARCH v1.2 V2-106, §5.1; BUILD_PLAN
// HOM-11). The viewer is opened with the grid items of the Photos tab or the Recent photos tray
// (`PhotoGridItem`); this file resolves each one to the facts the viewer draws without decoding
// anything: its format flags (RAW, HDR, Live Photo), whether a full-resolution layer can be
// decoded in Dart for deep zoom, and the `PhotoMediaItem` that the toolbar's Edit hands to
// `HomeCallbacks.onEditPhoto` (wired by INT-105). Danaview photos read their facts from
// library.db; system and desktop photos carry their `PhotoMediaItem`. Nothing here logs names, ids
// or paths (rule 30), and nothing opens a file for writing (rule 27).

import 'package:danaview_library/danaview_library.dart';
import 'package:flutter/foundation.dart';

import '../photos/photo_grid_item.dart';

/// The lower-case extension of [name] without the dot, or '' when it has none.
String photoExtensionOf(String name) {
  final slash = name.lastIndexOf(RegExp(r'[/\\]'));
  final base = slash < 0 ? name : name.substring(slash + 1);
  final dot = base.lastIndexOf('.');
  if (dot <= 0 || dot == base.length - 1) return '';
  return base.substring(dot + 1).toLowerCase();
}

/// RAW camera formats by extension (the HOM-16 type table's RAW rows).
const Set<String> rawPhotoExtensions = {'dng', 'cr2', 'cr3', 'nef', 'arw', 'raf', 'orf', 'rw2'};

const Map<String, String> _mimeByExtension = {
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'heic': 'image/heic',
  'heif': 'image/heif',
  'avif': 'image/avif',
  'gif': 'image/gif',
  'tif': 'image/tiff',
  'tiff': 'image/tiff',
  'webp': 'image/webp',
  'bmp': 'image/bmp',
  'dng': 'image/x-adobe-dng',
  'cr2': 'image/x-canon-cr2',
  'cr3': 'image/x-canon-cr3',
  'nef': 'image/x-nikon-nef',
  'arw': 'image/x-sony-arw',
  'raf': 'image/x-fuji-raf',
  'orf': 'image/x-olympus-orf',
  'rw2': 'image/x-panasonic-rw2',
};

/// The MIME type of a photo named [name] ('application/octet-stream' when the extension is unknown).
String photoMimeTypeOf(String name) => _mimeByExtension[photoExtensionOf(name)] ?? 'application/octet-stream';

/// A short format label (`JPEG`, `HEIC`, `RAW · DNG`) from [mimeType] or [name]; null when unknown.
String? photoFormatLabel({String? mimeType, String? uti, required String name}) {
  var ext = photoExtensionOf(name);
  if (ext.isEmpty && mimeType != null) {
    for (final e in _mimeByExtension.entries) {
      if (e.value == mimeType) {
        ext = e.key;
        break;
      }
    }
  }
  if (ext.isEmpty && uti != null) {
    final u = uti.toLowerCase();
    if (u.contains('heic') || u.contains('heif')) ext = 'heic';
    if (u.contains('jpeg')) ext = 'jpg';
    if (u.contains('png')) ext = 'png';
    if (u.contains('raw') || u.contains('dng')) ext = 'dng';
  }
  if (ext.isEmpty) return null;
  final label = switch (ext) {
    'jpg' || 'jpeg' => 'JPEG',
    'tif' || 'tiff' => 'TIFF',
    'heif' => 'HEIF',
    _ => ext.toUpperCase(),
  };
  return rawPhotoExtensions.contains(ext) ? 'RAW · $label' : label;
}

/// Formats the engine decodes on [platform] without a platform view (JPEG, PNG, GIF, WebP and BMP
/// everywhere; HEIC/HEIF/AVIF where the platform codec has them). RAW and TIFF never: those are
/// shown through the native thumbnailer's large size class only.
bool dartDecodablePhoto(String name, TargetPlatform platform) {
  final ext = photoExtensionOf(name);
  const everywhere = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'};
  if (everywhere.contains(ext)) return true;
  const platformCodec = {'heic', 'heif', 'avif'};
  return platformCodec.contains(ext) &&
      (platform == TargetPlatform.iOS || platform == TargetPlatform.macOS || platform == TargetPlatform.android);
}

/// One photo as the viewer sees it.
@immutable
final class PhotoViewerEntry {
  /// The facts of [item].
  const PhotoViewerEntry({
    required this.item,
    required this.isRaw,
    required this.isHdr,
    required this.isLivePhoto,
    required this.mimeType,
    this.filePath,
    this.sizeBytes,
    this.cameraModel,
  });

  /// The grid item the viewer was opened with.
  final PhotoGridItem item;

  /// A RAW capture.
  final bool isRaw;

  /// An HDR capture.
  final bool isHdr;

  /// A Live Photo (the indicator in the top bar).
  final bool isLivePhoto;

  /// MIME type, 'application/octet-stream' when unknown.
  final String mimeType;

  /// A local file the viewer may read (read-only) for the full-resolution layer: Danaview and
  /// desktop photos. Null for system assets (`ph:`/`ms:`), which are drawn by the thumbnailer.
  final String? filePath;

  /// Size in bytes, when known.
  final int? sizeBytes;

  /// Camera model, when known.
  final String? cameraModel;

  /// The V2-09 id.
  ItemId get id => item.id;

  /// The entry id of a Danaview photo, else null.
  EntryId? get entryId => item.origin == PhotoOrigin.danaview ? EntryId.tryParse(item.id.value) : null;

  /// Whether the full-resolution layer can be decoded in Dart on [platform].
  bool canDecodeFullResolution(TargetPlatform platform) =>
      filePath != null && !isRaw && dartDecodablePhoto(filePath!, platform);

  /// The `PhotoMediaItem` Edit hands to the editor (Still Photo Mode, INT-105).
  PhotoMediaItem toPhotoMediaItem({LibraryStore? store}) {
    final media = item.media;
    if (media is PhotoMediaItem) return media;
    EntryMeta? meta;
    final entry = entryId;
    if (entry != null && store != null) meta = store.reader.meta(entry);
    return PhotoMediaItem(
      id: item.id,
      uri: filePath ?? item.thumbSource,
      name: item.name,
      modifiedAt: item.modifiedAt,
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      width: item.width,
      height: item.height,
      isRaw: isRaw,
      isHdr: isHdr,
      isLivePhoto: isLivePhoto,
      cameraModel: cameraModel ?? meta?.camera,
      takenAt: meta?.takenAt ?? (item.date == item.modifiedAt ? null : item.date),
    );
  }

  // Never prints the name, id or path (rule 30).
  @override
  String toString() => 'PhotoViewerEntry(${item.origin.name})';
}

/// Resolves [item] against [store] (Danaview photos read their flags and size from library.db).
PhotoViewerEntry resolvePhotoViewerEntry(PhotoGridItem item, {LibraryStore? store}) {
  final media = item.media;
  if (media is PhotoMediaItem) {
    final local = item.origin == PhotoOrigin.desktop || _isLocalPath(media.uri) ? media.uri : null;
    final ext = photoExtensionOf(media.name.isEmpty ? media.uri : media.name);
    return PhotoViewerEntry(
      item: item,
      isRaw: media.isRaw || rawPhotoExtensions.contains(ext),
      isHdr: media.isHdr,
      isLivePhoto: media.isLivePhoto,
      mimeType: media.mimeType == 'application/octet-stream' ? photoMimeTypeOf(media.name) : media.mimeType,
      filePath: local,
      sizeBytes: media.sizeBytes,
      cameraModel: media.cameraModel,
    );
  }
  final entryId = item.origin == PhotoOrigin.danaview ? EntryId.tryParse(item.id.value) : null;
  final reader = store?.reader;
  final meta = entryId == null ? null : reader?.meta(entryId);
  final entry = entryId == null ? null : reader?.entry(entryId);
  final flags = meta?.flags ?? 0;
  final ext = photoExtensionOf(item.name);
  return PhotoViewerEntry(
    item: item,
    isRaw: flags & EntryMeta.flagRaw != 0 || rawPhotoExtensions.contains(ext),
    isHdr: flags & EntryMeta.flagHdr != 0,
    isLivePhoto: flags & EntryMeta.flagLive != 0,
    mimeType: photoMimeTypeOf(item.name),
    filePath: _isLocalPath(item.thumbSource) ? item.thumbSource : null,
    sizeBytes: entry?.sizeBytes,
    cameraModel: meta?.camera,
  );
}

bool _isLocalPath(String source) =>
    source.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(source) || source.startsWith(r'\\');
