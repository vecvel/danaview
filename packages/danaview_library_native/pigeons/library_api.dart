// OWNER: HOM-02
//
// FROZEN 2026-10-22 by HOM-02 (ARCH v1.2 V2-25): the whole Pigeon surface of
// danaview_library_native. Later tickets implement the native classes behind it (HOM-02A, HOM-04,
// HOM-04A, HOM-20, HOM-20A, HOM-21, HOM-21A, HOM-22, HOM-22A, HOM-26); a change to this file is a
// lead-approved [INTEGRATION] amendment. Regenerate from the package root (Mac only; Windows never
// runs Pigeon) with
//
//   dart run pigeon --input pigeons/library_api.dart
//
// and commit the generated Dart, Swift and Kotlin files (test/photo_library/pigeon_regeneration_test.dart
// fails when they drift). Conventions:
//
// - Every host method that touches media, files or UI replies asynchronously (`@asyncCallback`,
//   completion-handler / callback style, no Kotlin coroutines, as in the editor engine surface).
//   Methods without it are cheap, synchronous on the native side (still a `Future` in Dart).
// - Host handlers run on the platform main thread and never block on media work: they post to a
//   background queue and reply from it.
// - Errors are `FlutterError(code: <LibraryErrorCode>, message: debug text without names or paths,
//   details: null)`. Codes: `notSupportedOnDevice` (the capability does not exist here, or its
//   ticket has not landed), `permissionDenied`, `notFound`, `cancelled`, `unavailableOffline` (an
//   iCloud-only asset: no network is ever used, ARCH §9.1), `ioError`, `invalidArgument`, `busy`,
//   `internal`. A host API that is not registered answers Pigeon's `channel-error`, which the Dart
//   wrappers map to `notSupportedOnDevice` as well.
// - System assets are addressed by their platform id without the V2-09 prefix: a PhotoKit
//   `localIdentifier` (Dart adds `ph:`) or a MediaStore `_ID` as a decimal string (Dart adds `ms:`).
//   A thumbnail `source` is either such a prefixed id (`ph:…`, `ms:…`), an absolute file path or a
//   `content://` URI.
// - Times are integer milliseconds since the Unix epoch (`...Ms`), sizes are bytes, dimensions are
//   pixels. Nothing in this surface sends a byte over the network (rule 21) and save-out is
//   create-new only (rule 26); sources are opened read-only (rule 27).
// - Events: one multiplexed `LibraryEventsApi.libraryEvents` stream (photo library changes,
//   authorization changes, copy progress, Android incoming intents, Share Extension inbox
//   changes), emitted on the main thread; the Dart side keeps exactly one subscription and fans it
//   out (lib/src/pigeon/library_events.dart).

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/pigeon/library_api.g.dart',
    dartOptions: DartOptions(),
    dartPackageName: 'danaview_library_native',
    swiftOut: 'darwin/Classes/Glue/LibraryApi.g.swift',
    swiftOptions: SwiftOptions(errorClassName: 'LibraryPigeonError'),
    kotlinOut: 'android/src/main/kotlin/com/vecvel/danaview/library/pigeon/LibraryApi.g.kt',
    kotlinOptions: KotlinOptions(package: 'com.vecvel.danaview.library.pigeon', errorClassName: 'LibraryPigeonError'),
  ),
)
// ---------------------------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------------------------

/// Photo library authorization (PhotoKit `PHAuthorizationStatus` for `.readWrite`; Android maps
/// `READ_MEDIA_*` / `READ_MEDIA_VISUAL_USER_SELECTED` / `READ_EXTERNAL_STORAGE`).
enum PhotoAuthorizationMsg {
  /// The user has not been asked yet.
  notDetermined,

  /// Parental controls or MDM forbid access; the user cannot change it.
  restricted,

  /// The user refused access.
  denied,

  /// Full library access.
  authorized,

  /// Limited (iOS 14+) or partial (Android 14+) access: only the assets the user selected.
  limited,
}

/// Which system assets a fetch returns.
enum PhotoMediaFilterMsg { all, photos, videos }

/// The kind of one system asset.
enum PhotoAssetKindMsg { photo, video }

/// Sort order of a system fetch.
enum PhotoSortMsg { creationNewestFirst, creationOldestFirst, modificationNewestFirst }

/// The kind of a system album (V2-108: system albums and device folders coexist).
enum PhotoAlbumKindMsg {
  /// A smart album (Favourites, Screenshots, Live Photos, …) or an Android bucket the OS defines.
  smart,

  /// An album the user made (PhotoKit) or a device folder (`BUCKET_ID` on Android).
  user,

  /// A shared album.
  shared,
}

/// Encoded format of a thumbnail written to disk (V2-28: JPEG/HEIC on Apple, WebP on Android).
enum ThumbnailFormatMsg { jpeg, heic, webp, png }

/// How a thumbnail fits its target box.
enum ThumbnailModeMsg {
  /// Cover the box (centre crop), for grid cells.
  fill,

  /// Fit inside the box keeping the aspect ratio, for viewers and documents.
  fit,
}

/// Where a picked item came from.
enum PickedSourceMsg {
  /// `PHPickerViewController` / Android Photo Picker.
  photoLibrary,

  /// `UIDocumentPickerViewController` / `NSOpenPanel` / SAF `ACTION_OPEN_DOCUMENT`.
  files,
}

/// Where save-out writes (create-new only, rule 26).
enum SaveOutDestinationMsg {
  /// The system file picker (`forExporting:`, save panel, `ACTION_CREATE_DOCUMENT`).
  files,

  /// Android `MediaStore.Downloads` (10+); Apple answers `notSupportedOnDevice`.
  downloads,

  /// The system photo library, add-only (`PHAssetCreationRequest`, MediaStore `Pictures`/`Movies`).
  photos,
}

/// The Android intent action of an incoming batch.
enum IncomingActionMsg { view, send, sendMultiple }

/// The kind of one [LibraryEventMsg].
enum LibraryEventKindMsg {
  /// [LibraryEventMsg.photoChange] is set.
  photoLibraryChanged,

  /// [LibraryEventMsg.authorization] is set.
  photoAuthorizationChanged,

  /// [LibraryEventMsg.copyProgress] is set.
  copyProgress,

  /// [LibraryEventMsg.incoming] is set (Android).
  incoming,

  /// The Share Extension inbox gained a complete batch (Apple); no payload.
  inboxChanged,
}

// ---------------------------------------------------------------------------------------------
// Photo library messages
// ---------------------------------------------------------------------------------------------

/// One page request of a system fetch.
class PhotoFetchRequestMsg {
  PhotoFetchRequestMsg({
    required this.filter,
    required this.sort,
    required this.offset,
    required this.limit,
  });

  PhotoMediaFilterMsg filter;
  PhotoSortMsg sort;

  /// Album to list ([PhotoAlbumMsg.albumId]); null for the whole library.
  String? albumId;

  /// Index of the first asset, >= 0.
  int offset;

  /// Page size, 1…500 (the Home grid uses 200).
  int limit;

  /// The [PhotoPageMsg.changeToken] of the previous page, if any; when the snapshot changed since,
  /// the reply sets [PhotoPageMsg.tokenStale] and the caller restarts paging.
  String? changeToken;
}

/// One system asset as the grid needs it (cheap fields only; EXIF is [PhotoAssetDetailMsg]).
class PhotoAssetMsg {
  PhotoAssetMsg({
    required this.localIdentifier,
    required this.kind,
    required this.widthPx,
    required this.heightPx,
    required this.durationMs,
    required this.isFavorite,
    required this.isRaw,
    required this.isHdr,
    required this.isLivePhoto,
    required this.isScreenshot,
  });

  /// PhotoKit `localIdentifier` or MediaStore `_ID` (no `ph:` / `ms:` prefix).
  String localIdentifier;
  PhotoAssetKindMsg kind;
  int widthPx;
  int heightPx;

  /// Capture (creation) time, if known.
  int? creationTimeMs;

  /// Last modification time, if known.
  int? modificationTimeMs;

  /// Video length; 0 for photos.
  int durationMs;
  bool isFavorite;

  /// A RAW capture or a RAW+JPEG pair (DNG, CR2/CR3, NEF, ARW, …).
  bool isRaw;

  /// An HDR capture (PhotoKit `photoHDR`, Android Ultra HDR / HDR video).
  bool isHdr;

  /// A Live Photo (still with a paired movie; Android motion photos are false in 1.2.0).
  bool isLivePhoto;
  bool isScreenshot;

  /// Original file name of the primary resource, if known (never logged, rule 30).
  String? originalFilename;

  /// Uniform type identifier of the primary resource (Apple), if known.
  String? uti;

  /// MIME type of the primary resource, if known.
  String? mimeType;

  /// Size of the primary resource, when the platform reports it cheaply (MediaStore `SIZE`).
  int? sizeBytes;
}

/// One page of a system fetch.
class PhotoPageMsg {
  PhotoPageMsg({
    required this.assets,
    required this.offset,
    required this.totalCount,
    required this.changeToken,
    required this.tokenStale,
  });

  List<PhotoAssetMsg> assets;

  /// The offset this page starts at (the request's).
  int offset;

  /// Number of assets of the whole fetch in this snapshot.
  int totalCount;

  /// Opaque token of the snapshot this page was read from; changes whenever the library does.
  String changeToken;

  /// True when the request's token named an older snapshot (restart paging from 0).
  bool tokenStale;
}

/// One system album or device folder.
class PhotoAlbumMsg {
  PhotoAlbumMsg({required this.albumId, required this.title, required this.kind, required this.estimatedCount});

  /// PhotoKit collection `localIdentifier` or Android `BUCKET_ID`.
  String albumId;

  /// Localized title (never logged, rule 30).
  String title;
  PhotoAlbumKindMsg kind;

  /// Asset count, possibly estimated; -1 when unknown.
  int estimatedCount;
}

/// EXIF basics and format flags of one asset (the photo viewer's info panel, HOM-11).
class PhotoAssetDetailMsg {
  PhotoAssetDetailMsg({
    required this.localIdentifier,
    required this.isRaw,
    required this.isHdr,
    required this.isLivePhoto,
    required this.locallyAvailable,
  });

  String localIdentifier;
  int? iso;
  double? aperture;
  double? exposureSeconds;
  double? focalLengthMm;
  String? cameraMake;
  String? cameraModel;
  String? lensModel;

  /// EXIF `DateTimeOriginal` (with its offset when present).
  int? takenAtMs;
  double? latitude;
  double? longitude;

  /// Colour profile name (`Display P3`, `sRGB IEC61966-2.1`, …).
  String? colorProfile;

  /// Bits per component of the primary image, if known.
  int? bitDepth;
  bool isRaw;
  bool isHdr;
  bool isLivePhoto;
  String? uti;
  String? mimeType;
  String? originalFilename;
  int? sizeBytes;

  /// False when the original is only in iCloud: the EXIF fields are then null (no network, §9.1).
  bool locallyAvailable;
}

/// Copy of an asset's original resource into an app directory (viewer, editor import V2-34,
/// sharing a system photo). Never uses the network.
class PhotoCopyRequestMsg {
  PhotoCopyRequestMsg({
    required this.requestId,
    required this.localIdentifier,
    required this.destinationDirectory,
    required this.pairedVideo,
  });

  /// Caller-chosen id for [LibraryEventKindMsg.copyProgress] events and cancellation.
  String requestId;
  String localIdentifier;

  /// An existing app-owned directory (cache or temporary); the file is created new inside it.
  String destinationDirectory;

  /// Copy the Live Photo's paired movie instead of the still.
  bool pairedVideo;
}

/// The file [PhotoLibraryHostApi.copyAsset] wrote.
class PhotoCopyResultMsg {
  PhotoCopyResultMsg({required this.path, required this.sizeBytes});

  String path;
  String? uti;
  String? mimeType;
  int sizeBytes;
}

/// What changed in the system library (PhotoKit `PHChange`, Android `ContentObserver`), V2-111.
class PhotoLibraryChangeMsg {
  PhotoLibraryChangeMsg({
    required this.changeToken,
    required this.incremental,
    required this.inserted,
    required this.removed,
    required this.changed,
  });

  /// The token pages read from now on carry.
  String changeToken;

  /// False when the platform could not say what changed: reload everything.
  bool incremental;
  List<String> inserted;
  List<String> removed;
  List<String> changed;
}

// ---------------------------------------------------------------------------------------------
// Thumbnail messages (HOM-04, HOM-04A, HOM-26)
// ---------------------------------------------------------------------------------------------

/// A thumbnail of a system asset or a media file, written to [outputPath].
class MediaThumbnailRequestMsg {
  MediaThumbnailRequestMsg({
    required this.requestId,
    required this.source,
    required this.widthPx,
    required this.heightPx,
    required this.mode,
    required this.format,
    required this.quality,
    required this.outputPath,
  });

  /// Caller-chosen id for [ThumbnailHostApi.cancel].
  String requestId;

  /// `ph:<id>`, `ms:<id>`, an absolute file path or a `content://` URI (opened read-only).
  String source;
  int widthPx;
  int heightPx;
  ThumbnailModeMsg mode;
  ThumbnailFormatMsg format;

  /// Encoder quality 0…1.
  double quality;

  /// The file to create (in the thumbnail cache, V2-28).
  String outputPath;
}

/// A thumbnail of a document's first page or Quick Look preview (HOM-26 on Apple).
class DocumentThumbnailRequestMsg {
  DocumentThumbnailRequestMsg({
    required this.requestId,
    required this.path,
    required this.widthPx,
    required this.heightPx,
    required this.scale,
    required this.format,
    required this.quality,
    required this.outputPath,
  });

  String requestId;

  /// Absolute path of the document (opened read-only).
  String path;
  int widthPx;
  int heightPx;

  /// Screen scale the size is meant for.
  double scale;
  ThumbnailFormatMsg format;
  double quality;
  String outputPath;
}

/// A thumbnail written to disk.
class ThumbnailResultMsg {
  ThumbnailResultMsg({required this.path, required this.widthPx, required this.heightPx, required this.format});

  String path;
  int widthPx;
  int heightPx;
  ThumbnailFormatMsg format;
}

/// Prefetch window of the native image cache (`PHCachingImageManager`).
class ThumbnailCachingMsg {
  ThumbnailCachingMsg({
    required this.startSources,
    required this.stopSources,
    required this.widthPx,
    required this.heightPx,
    required this.mode,
  });

  List<String> startSources;
  List<String> stopSources;
  int widthPx;
  int heightPx;
  ThumbnailModeMsg mode;
}

// ---------------------------------------------------------------------------------------------
// Picker and copy messages (HOM-20, HOM-20A; copy also serves HOM-21A)
// ---------------------------------------------------------------------------------------------

/// The system photo picker (no library permission needed).
class PhotoPickRequestMsg {
  PhotoPickRequestMsg({required this.selectionLimit, required this.filter, required this.destinationDirectory});

  /// Maximum number of items; 0 for no limit.
  int selectionLimit;
  PhotoMediaFilterMsg filter;

  /// App-owned staging directory the picked files are copied into (`.current` representation on
  /// Apple; the picker's temporary files vanish after the callback). Never the library root.
  String destinationDirectory;
}

/// The system document picker (import mode).
class DocumentPickRequestMsg {
  DocumentPickRequestMsg({required this.allowMultiple, required this.utis, required this.mimeTypes});

  bool allowMultiple;

  /// Allowed types on Apple (empty: any).
  List<String> utis;

  /// Allowed types on Android (empty: any).
  List<String> mimeTypes;

  /// App-owned staging directory for copies, or null to return security-scoped / content URIs to
  /// copy later with [PickerHostApi.copyToFile].
  String? destinationDirectory;
}

/// One picked item.
class PickedItemMsg {
  PickedItemMsg({required this.uri, required this.displayName, required this.source, required this.needsCopy});

  /// `file://` URL or `content://` URI.
  String uri;

  /// Local path when [uri] is a file already copied into the staging directory.
  String? path;
  String displayName;
  String? uti;
  String? mimeType;
  int? sizeBytes;
  int? modifiedTimeMs;

  /// The PhotoKit / MediaStore id when the platform reports it (no permission implied).
  String? assetIdentifier;
  PickedSourceMsg source;

  /// True when the bytes must still be copied with [PickerHostApi.copyToFile] (a content URI or a
  /// security-scoped URL).
  bool needsCopy;
}

/// A streamed, resumable copy of a picked or incoming item into an app path.
class CopyRequestMsg {
  CopyRequestMsg({
    required this.requestId,
    required this.sourceUri,
    required this.destinationPath,
    required this.resumeFromOffset,
  });

  String requestId;

  /// A [PickedItemMsg.uri] or an [IncomingItemMsg.uri] (opened read-only, rule 27).
  String sourceUri;

  /// The file to create, or to append to from [resumeFromOffset] (an `imports/<job>.part` the
  /// import service names; the native side writes only that one file).
  String destinationPath;

  /// Bytes already copied by an interrupted run; 0 for a fresh copy.
  int resumeFromOffset;
}

/// The outcome of a finished copy.
class CopyResultMsg {
  CopyResultMsg({required this.bytesCopied, required this.totalBytes});

  /// Bytes in [CopyRequestMsg.destinationPath] after the copy.
  int bytesCopied;

  /// Size of the source, or -1 when it was unknown before the copy finished.
  int totalBytes;
}

/// Progress of a running copy (at most 4 Hz).
class CopyProgressMsg {
  CopyProgressMsg({required this.requestId, required this.bytesDone});

  String requestId;
  int bytesDone;
  int? bytesTotal;
}

// ---------------------------------------------------------------------------------------------
// Getting files out, share, open in, Quick Look (HOM-22, HOM-22A, HOM-26)
// ---------------------------------------------------------------------------------------------

/// One app file handed to the system.
class FileItemMsg {
  FileItemMsg({required this.path, required this.displayName});

  /// Absolute path (a library file or a temporary read-only copy).
  String path;

  /// The name the receiver sees.
  String displayName;
  String? mimeType;
  String? uti;
}

/// Where a popover anchors on iPad and macOS (logical pixels in the Flutter view).
class AnchorRectMsg {
  AnchorRectMsg({required this.x, required this.y, required this.width, required this.height});

  double x;
  double y;
  double width;
  double height;
}

/// Save copies of [items] outside the app (create-new only, rule 26).
class SaveOutRequestMsg {
  SaveOutRequestMsg({required this.items, required this.destination});

  List<FileItemMsg> items;
  SaveOutDestinationMsg destination;

  /// Sub-folder for [SaveOutDestinationMsg.downloads] (`Download/Danaview`), else ignored.
  String? subdirectory;
  AnchorRectMsg? anchor;
}

/// What save-out did.
class SaveOutResultMsg {
  SaveOutResultMsg({required this.cancelled, required this.savedUris, required this.failedCount});

  bool cancelled;

  /// The created files (URLs, content URIs or asset ids).
  List<String> savedUris;
  int failedCount;
}

/// The system share sheet.
class ShareRequestMsg {
  ShareRequestMsg({required this.items});

  List<FileItemMsg> items;
  String? subject;
  AnchorRectMsg? anchor;
}

/// What the share sheet did.
class ShareResultMsg {
  ShareResultMsg({required this.completed});

  bool completed;

  /// The activity the user chose, if the platform says.
  String? activityType;
}

/// Open a file in another app.
class OpenInRequestMsg {
  OpenInRequestMsg({required this.item});

  FileItemMsg item;
  AnchorRectMsg? anchor;
}

/// Quick Look preview of one or more files (editing disabled, V2-120).
class QuickLookRequestMsg {
  QuickLookRequestMsg({required this.items, required this.initialIndex});

  List<FileItemMsg> items;
  int initialIndex;
}

// ---------------------------------------------------------------------------------------------
// Share Extension inbox (HOM-21, Apple) and incoming intents (HOM-21A, Android)
// ---------------------------------------------------------------------------------------------

/// One file of an inbox batch.
class InboxFileMsg {
  InboxFileMsg({required this.relativePath, required this.displayName, required this.sizeBytes});

  /// Path inside the batch directory.
  String relativePath;
  String displayName;
  String? uti;
  String? mimeType;
  int sizeBytes;
}

/// One Share Extension batch (`Inbox/<batchId>/`, `manifest.json` written last).
class InboxBatchMsg {
  InboxBatchMsg({required this.batchId, required this.createdAtMs, required this.complete, required this.files});

  String batchId;
  int createdAtMs;

  /// True once `manifest.json` exists.
  bool complete;

  /// The Danaview folder the user picked in the extension (`fd_…`), if any.
  String? targetFolderId;
  List<InboxFileMsg> files;
}

/// One item of an Android incoming intent.
class IncomingItemMsg {
  IncomingItemMsg({required this.uri});

  /// `content://` or `file://` URI (read grant held until acknowledged).
  String uri;
  String? displayName;
  String? mimeType;
  int? sizeBytes;
}

/// One Android `VIEW` / `SEND` / `SEND_MULTIPLE` intent.
class IncomingBatchMsg {
  IncomingBatchMsg({required this.batchId, required this.action, required this.items});

  String batchId;
  IncomingActionMsg action;
  List<IncomingItemMsg> items;
}

// ---------------------------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------------------------

/// One event of the multiplexed library stream; exactly the field [kind] names is set.
class LibraryEventMsg {
  LibraryEventMsg({required this.kind});

  LibraryEventKindMsg kind;
  PhotoLibraryChangeMsg? photoChange;
  PhotoAuthorizationMsg? authorization;
  CopyProgressMsg? copyProgress;
  IncomingBatchMsg? incoming;
}

// ---------------------------------------------------------------------------------------------
// Host APIs
// ---------------------------------------------------------------------------------------------

/// The system photo library (PhotoKit: HOM-02; MediaStore: HOM-02A).
@HostApi()
abstract class PhotoLibraryHostApi {
  /// Current authorization, without prompting.
  PhotoAuthorizationMsg authorizationStatus();

  /// Prompts the first time (Photos tab's system view only, V2-103); later calls return the state.
  @asyncCallback
  PhotoAuthorizationMsg requestAuthorization();

  /// Lets a limited-access user change the selection (iOS 15+ `presentLimitedLibraryPicker`,
  /// Android 14+ re-request). Returns the identifiers selected now. `notSupportedOnDevice` where
  /// limited access doesn't exist (macOS).
  @asyncCallback
  List<String> presentLimitedLibraryPicker();

  /// Opens the app's page in the system settings (denied access). False when it couldn't.
  bool openAppSettings();

  /// Starts delivering [LibraryEventKindMsg.photoLibraryChanged] and
  /// [LibraryEventKindMsg.photoAuthorizationChanged] events. Call after access was granted:
  /// registering a PhotoKit observer earlier can prompt.
  void startObserving();

  /// Stops the change events.
  void stopObserving();

  /// One page of the library or of an album.
  @asyncCallback
  PhotoPageMsg fetchPage(PhotoFetchRequestMsg request);

  /// Assets by id, in the given order; unknown or inaccessible ids are left out.
  @asyncCallback
  List<PhotoAssetMsg> fetchAssets(List<String> localIdentifiers);

  /// System albums and device folders that hold photos, counted by their photos (video-only ones are left out).
  @asyncCallback
  List<PhotoAlbumMsg> fetchAlbums();

  /// EXIF basics of one asset; `notFound` when it is gone.
  @asyncCallback
  PhotoAssetDetailMsg assetDetail(String localIdentifier);

  /// Copies the original resource into an app directory (create-new, no network).
  @asyncCallback
  PhotoCopyResultMsg copyAsset(PhotoCopyRequestMsg request);

  /// Cancels a running [copyAsset]; it then fails with `cancelled`.
  void cancelCopy(String requestId);
}

/// System pickers and streamed copies of what they return (HOM-20, HOM-20A).
@HostApi()
abstract class PickerHostApi {
  /// The photo picker; empty when the user cancelled.
  @asyncCallback
  List<PickedItemMsg> pickPhotos(PhotoPickRequestMsg request);

  /// The document picker; empty when the user cancelled.
  @asyncCallback
  List<PickedItemMsg> pickDocuments(DocumentPickRequestMsg request);

  /// Streams a picked or incoming item into an app file, resumable from an offset.
  @asyncCallback
  CopyResultMsg copyToFile(CopyRequestMsg request);

  /// Cancels a running [copyToFile]; it then fails with `cancelled`.
  void cancelCopy(String requestId);

  /// Gives up a security-scoped URL or persisted URI grant held for [uri].
  void release(String uri);
}

/// Native thumbnailers (HOM-04, HOM-04A; documents HOM-26 on Apple).
@HostApi()
abstract class ThumbnailHostApi {
  /// A thumbnail of a system asset or a media file.
  @asyncCallback
  ThumbnailResultMsg mediaThumbnail(MediaThumbnailRequestMsg request);

  /// A thumbnail of a document; null when the platform has none for it.
  @asyncCallback
  ThumbnailResultMsg? documentThumbnail(DocumentThumbnailRequestMsg request);

  /// Cancels a pending thumbnail; it then fails with `cancelled`.
  void cancel(String requestId);

  /// Moves the native prefetch window (cells entering and leaving the viewport).
  void updateCaching(ThumbnailCachingMsg window);
}

/// Save to Files / Downloads / Photos, create-new only (HOM-22, HOM-22A).
@HostApi()
abstract class ExportOutHostApi {
  @asyncCallback
  SaveOutResultMsg saveOut(SaveOutRequestMsg request);
}

/// The system share sheet (HOM-22, HOM-22A).
@HostApi()
abstract class ShareHostApi {
  @asyncCallback
  ShareResultMsg share(ShareRequestMsg request);
}

/// Open in another app (HOM-22, HOM-22A).
@HostApi()
abstract class OpenInHostApi {
  /// True when an app chooser or the default app was shown.
  @asyncCallback
  bool openIn(OpenInRequestMsg request);
}

/// Quick Look (HOM-26, Apple; Android answers `notSupportedOnDevice`).
@HostApi()
abstract class QuickLookHostApi {
  @asyncCallback
  bool canPreview(FileItemMsg item);

  /// Completes when the preview is dismissed.
  @asyncCallback
  void present(QuickLookRequestMsg request);
}

/// The App Group inbox of the Share Extension (HOM-21, Apple; rule 26: the only App Group reader).
@HostApi()
abstract class InboxHostApi {
  /// False when the App Group container is missing (no entitlement).
  bool isAvailable();

  @asyncCallback
  List<InboxBatchMsg> listBatches();

  /// Moves one file of a batch to [destinationPath] (an app path the import service names).
  @asyncCallback
  void takeFile(String batchId, String relativePath, String destinationPath);

  @asyncCallback
  void deleteBatch(String batchId);

  /// Deletes incomplete batches older than [olderThanMs] (24 h); returns how many.
  @asyncCallback
  int deleteStaleBatches(int olderThanMs);

  /// Writes the folder list snapshot the extension's folder picker reads (UTF-8 JSON).
  @asyncCallback
  void writeFolderSnapshot(Uint8List json);
}

/// Android incoming intents (HOM-21A; Apple answers `notSupportedOnDevice`).
@HostApi()
abstract class IncomingHostApi {
  /// Intents received before Dart listened (cold start), each returned once.
  List<IncomingBatchMsg> takePending();

  /// Releases the URI grants of a handled batch.
  void acknowledge(String batchId);
}

/// Backup exclusion of app paths (Apple `NSURLIsExcludedFromBackupKey`, used by HOM-17's
/// `BackupFlagPort` for `imports/`; Android answers `notSupportedOnDevice`: its rules are XML,
/// INT-104).
@HostApi()
abstract class BackupFlagHostApi {
  @asyncCallback
  void setExcludedFromBackup(String path, bool excluded);

  @asyncCallback
  bool isExcludedFromBackup(String path);
}

/// The multiplexed library event stream.
@EventChannelApi()
abstract class LibraryEventsApi {
  LibraryEventMsg libraryEvents();
}
