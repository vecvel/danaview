// OWNER: HOM-11
//
// The photo viewer's info sheet data (ARCH v1.2 V2-106, §9.4; BUILD_PLAN HOM-11): EXIF capture
// date, camera, lens, exposure (shutter, aperture, ISO, focal length), dimensions, size, format and
// where the photo lives. System photos ask `SystemPhotoLibrary.assetDetail` (PhotoKit /
// MediaStore; an iCloud-only original has no EXIF and the sheet says so, no network, §9.1);
// Danaview photos read library.db (entry + meta, folder, how it arrived); desktop photos use the
// facts their scan found. The rows are computed by a pure function so the sheet stays dumb and
// the formatting is unit tested. Location is never shown or read here (§9.4). Nothing is logged
// (rule 30).

import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_library_native/danaview_library_native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../tools/media_tool_format.dart' show formatDataSize;
import '../files/library_store_providers.dart';
import '../photos/photo_date_groups.dart' show photoMonthName;
import '../photos/photo_grid_item.dart';
import '../sources/system_photos_source.dart';
import 'photo_viewer_entry.dart';

/// Where a photo lives, for the info sheet's Source row.
enum PhotoInfoSource {
  /// A Danaview folder (library.db).
  danaviewFolder,

  /// The system photo library.
  photoLibrary,

  /// A desktop Pictures folder.
  picturesFolder,
}

/// Everything the info sheet shows about one photo.
@immutable
final class PhotoInfo {
  /// Facts of one photo; every EXIF field is null when unknown.
  const PhotoInfo({
    required this.name,
    required this.source,
    this.folderName,
    this.importedFrom,
    this.takenAt,
    this.addedAt,
    this.modifiedAt,
    this.cameraMake,
    this.cameraModel,
    this.lensModel,
    this.exposureSeconds,
    this.aperture,
    this.iso,
    this.focalLengthMm,
    this.width = 0,
    this.height = 0,
    this.sizeBytes,
    this.formatLabel,
    this.colorProfile,
    this.bitDepth,
    this.isRaw = false,
    this.isHdr = false,
    this.isLivePhoto = false,
    this.locallyAvailable = true,
  });

  /// The display name.
  final String name;

  /// Where it lives.
  final PhotoInfoSource source;

  /// The Danaview folder's name.
  final String? folderName;

  /// How a Danaview photo arrived (import source).
  final SourceHint? importedFrom;

  /// EXIF capture time.
  final DateTime? takenAt;

  /// When it was added to Danaview.
  final DateTime? addedAt;

  /// Last modification.
  final DateTime? modifiedAt;

  /// Camera make.
  final String? cameraMake;

  /// Camera model.
  final String? cameraModel;

  /// Lens model.
  final String? lensModel;

  /// Exposure time in seconds.
  final double? exposureSeconds;

  /// f-number.
  final double? aperture;

  /// ISO speed.
  final int? iso;

  /// Focal length in millimetres.
  final double? focalLengthMm;

  /// Pixel width (0 when unknown).
  final int width;

  /// Pixel height (0 when unknown).
  final int height;

  /// Size in bytes.
  final int? sizeBytes;

  /// `JPEG`, `HEIC`, `RAW · DNG`, …
  final String? formatLabel;

  /// Colour profile name.
  final String? colorProfile;

  /// Bits per component.
  final int? bitDepth;

  /// A RAW capture.
  final bool isRaw;

  /// An HDR capture.
  final bool isHdr;

  /// A Live Photo.
  final bool isLivePhoto;

  /// False when the original is only in iCloud (EXIF unknown).
  final bool locallyAvailable;
}

/// One row of the info sheet.
@immutable
final class PhotoInfoRow {
  /// A row.
  const PhotoInfoRow(this.id, this.label, this.value);

  /// A stable id (tests, keys).
  final String id;

  /// The label (`Taken`, `Camera`, …).
  final String label;

  /// The value.
  final String value;

  @override
  bool operator ==(Object other) => other is PhotoInfoRow && other.id == id && other.label == label && other.value == value;

  @override
  int get hashCode => Object.hash(id, label, value);

  @override
  String toString() => 'PhotoInfoRow($id)';
}

String _two(int v) => v.toString().padLeft(2, '0');

/// `21 October 2026, 09:05`.
String formatPhotoDateTime(DateTime time) {
  final t = time.toLocal();
  return '${t.day} ${photoMonthName(t.month)} ${t.year}, ${_two(t.hour)}:${_two(t.minute)}';
}

/// `1/120 s`, `0.5 s`, `2 s`, `30 s`.
String formatExposure(double seconds) {
  if (seconds <= 0 || seconds.isNaN) return '–';
  if (seconds < 0.3) {
    final denominator = (1 / seconds).round();
    return '1/$denominator s';
  }
  final rounded = (seconds * 10).round() / 10;
  final text = rounded == rounded.roundToDouble() ? rounded.toInt().toString() : rounded.toString();
  return '$text s';
}

/// `ƒ/1.8`, `ƒ/11`.
String formatAperture(double f) {
  final rounded = (f * 10).round() / 10;
  final text = rounded == rounded.roundToDouble() ? rounded.toInt().toString() : rounded.toString();
  return 'ƒ/$text';
}

/// `26 mm`, `5.7 mm`.
String formatFocalLength(double mm) {
  final rounded = (mm * 10).round() / 10;
  final text = rounded == rounded.roundToDouble() ? rounded.toInt().toString() : rounded.toString();
  return '$text mm';
}

/// `4032 × 3024 · 12.2 MP`.
String formatPhotoDimensions(int width, int height) {
  final mp = width * height / 1e6;
  return '$width × $height · ${mp.toStringAsFixed(1)} MP';
}

/// The import source in words.
String importedFromLabel(SourceHint hint) => switch (hint) {
      SourceHint.photos => 'Photos',
      SourceHint.files => 'Files',
      SourceHint.openWith => 'Opened with Danaview',
      SourceHint.shareExtension => 'Shared to Danaview',
      SourceHint.linkedFolder => 'Linked folder',
      SourceHint.editorExport => 'Editor export',
      SourceHint.player => 'Player',
      SourceHint.unknown => 'Unknown',
    };

/// The camera line: make and model without the make repeated (`Apple iPhone 15 Pro`).
String? cameraLine(String? make, String? model) {
  final m = model?.trim();
  final k = make?.trim();
  if ((m == null || m.isEmpty) && (k == null || k.isEmpty)) return null;
  if (m == null || m.isEmpty) return k;
  if (k == null || k.isEmpty) return m;
  return m.toLowerCase().startsWith(k.toLowerCase()) ? m : '$k $m';
}

/// The sheet's rows for [info], in display order; unknown facts are left out.
List<PhotoInfoRow> photoInfoRows(PhotoInfo info) {
  final rows = <PhotoInfoRow>[];
  void add(String id, String label, String? value) {
    if (value == null || value.trim().isEmpty) return;
    rows.add(PhotoInfoRow(id, label, value));
  }

  add('name', 'Name', info.name);
  final taken = info.takenAt;
  add('taken', 'Taken', taken == null ? null : formatPhotoDateTime(taken));
  add('camera', 'Camera', cameraLine(info.cameraMake, info.cameraModel));
  add('lens', 'Lens', info.lensModel);
  final exposure = [
    if (info.exposureSeconds case final s?) formatExposure(s),
    if (info.aperture case final f?) formatAperture(f),
    if (info.iso case final iso?) 'ISO $iso',
    if (info.focalLengthMm case final mm?) formatFocalLength(mm),
  ];
  add('exposure', 'Exposure', exposure.isEmpty ? null : exposure.join(' · '));
  add('dimensions', 'Dimensions', info.width > 0 && info.height > 0 ? formatPhotoDimensions(info.width, info.height) : null);
  final size = info.sizeBytes;
  add('size', 'Size', size == null || size < 0 ? null : formatDataSize(size));
  final label = info.formatLabel;
  final raw = info.isRaw || (label?.startsWith('RAW · ') ?? false);
  final format = [
    if (label != null) label.startsWith('RAW · ') ? label.substring(6) : label,
    if (raw) 'RAW',
    if (info.isHdr) 'HDR',
    if (info.isLivePhoto) 'Live Photo',
    if (info.bitDepth case final b? when b > 0) '$b-bit',
  ];
  add('format', 'Format', format.isEmpty ? null : format.join(' · '));
  add('colour', 'Colour profile', info.colorProfile);
  add('source', 'Source', switch (info.source) {
    PhotoInfoSource.danaviewFolder => info.folderName == null ? 'Danaview folder' : 'Danaview folder · ${info.folderName}',
    PhotoInfoSource.photoLibrary => 'Photo library',
    PhotoInfoSource.picturesFolder => 'Pictures folder',
  });
  add('imported', 'Added from', info.importedFrom == null || info.importedFrom == SourceHint.unknown ? null : importedFromLabel(info.importedFrom!));
  final added = info.addedAt;
  add('added', 'Added', added == null ? null : formatPhotoDateTime(added));
  final modified = info.modifiedAt;
  add('modified', 'Modified', modified == null ? null : formatPhotoDateTime(modified));
  if (!info.locallyAvailable) add('icloud', 'Original', 'In iCloud only: camera details appear once it is downloaded');
  return rows;
}

/// Reads the info of [item]. [system] answers for `ph:`/`ms:` photos; [store] for Danaview ones.
Future<PhotoInfo> loadPhotoInfo(PhotoGridItem item, {LibraryStore? store, SystemPhotoLibrary? system}) async {
  final entry = resolvePhotoViewerEntry(item, store: store);
  final media = item.media;
  switch (item.origin) {
    case PhotoOrigin.danaview:
      final id = EntryId.tryParse(item.id.value);
      final reader = store?.reader;
      final e = id == null ? null : reader?.entry(id);
      final meta = id == null ? null : reader?.meta(id);
      final folder = e == null ? null : reader?.folder(e.folderId);
      return PhotoInfo(
        name: e?.displayName ?? item.name,
        source: PhotoInfoSource.danaviewFolder,
        folderName: folder?.name,
        importedFrom: e?.sourceHint,
        takenAt: meta?.takenAt,
        addedAt: e?.addedAt,
        modifiedAt: e?.modifiedAt ?? item.modifiedAt,
        cameraModel: meta?.camera,
        width: meta?.width ?? item.width,
        height: meta?.height ?? item.height,
        sizeBytes: e?.sizeBytes,
        formatLabel: photoFormatLabel(name: item.name),
        isRaw: entry.isRaw,
        isHdr: entry.isHdr,
        isLivePhoto: entry.isLivePhoto,
      );
    case PhotoOrigin.system:
      final photo = media is PhotoMediaItem ? media : null;
      final localId = switch (item.id.value) {
        final v when v.startsWith('ph:') => v.substring(3),
        final v when v.startsWith('ms:') => v.substring(3),
        final v => v,
      };
      SystemPhotoDetail? detail;
      if (system != null) {
        try {
          detail = await system.assetDetail(localId);
        } on LibraryNativeException {
          detail = null;
        }
      }
      final name = (detail?.originalFilename?.isNotEmpty ?? false) ? detail!.originalFilename! : item.name;
      return PhotoInfo(
        name: name,
        source: PhotoInfoSource.photoLibrary,
        takenAt: detail?.takenAt ?? photo?.takenAt,
        modifiedAt: item.modifiedAt,
        cameraMake: detail?.cameraMake,
        cameraModel: detail?.cameraModel ?? photo?.cameraModel,
        lensModel: detail?.lensModel,
        exposureSeconds: detail?.exposureSeconds,
        aperture: detail?.aperture ?? photo?.aperture,
        iso: detail?.iso ?? photo?.iso,
        focalLengthMm: detail?.focalLengthMm,
        width: item.width,
        height: item.height,
        sizeBytes: detail?.sizeBytes ?? photo?.sizeBytes,
        formatLabel: photoFormatLabel(name: name, mimeType: detail?.mimeType ?? photo?.mimeType, uti: detail?.uti),
        colorProfile: detail?.colorProfile,
        bitDepth: detail?.bitDepth,
        isRaw: (detail?.isRaw ?? false) || entry.isRaw,
        isHdr: (detail?.isHdr ?? false) || entry.isHdr,
        isLivePhoto: (detail?.isLivePhoto ?? false) || entry.isLivePhoto,
        locallyAvailable: detail?.locallyAvailable ?? true,
      );
    case PhotoOrigin.desktop:
      final photo = media is PhotoMediaItem ? media : null;
      return PhotoInfo(
        name: item.name,
        source: PhotoInfoSource.picturesFolder,
        takenAt: photo?.takenAt,
        modifiedAt: item.modifiedAt,
        cameraModel: photo?.cameraModel,
        aperture: photo?.aperture,
        iso: photo?.iso,
        width: item.width,
        height: item.height,
        sizeBytes: photo?.sizeBytes,
        formatLabel: photoFormatLabel(name: item.name, mimeType: photo?.mimeType),
        isRaw: entry.isRaw,
        isHdr: entry.isHdr,
        isLivePhoto: entry.isLivePhoto,
      );
  }
}

/// The info of one photo (re-read after library writes).
final photoInfoProvider = FutureProvider.autoDispose.family<PhotoInfo, PhotoGridItem>((ref, item) {
  final store = ref.watch(libraryStoreProvider);
  if (item.origin == PhotoOrigin.danaview) ref.watch(libraryRevisionProvider);
  return loadPhotoInfo(item, store: store, system: ref.watch(systemPhotoLibraryProvider));
});
