// OWNER: HOM-02
//
// Plain value types of the PhotoKit library (ARCH v1.2 §8, V2-111). The PhotoLibrary/ sources are
// Flutter-free (Foundation, Photos, ImageIO only) so XCTest runs them without an app host; the
// Glue/ adapter converts these values to and from the Pigeon messages. Nothing here logs names,
// identifiers or paths (rule 30) or opens a socket (rule 21).

import Foundation

/// Error codes of the library surface (pigeons/library_api.dart, "Errors").
enum LibraryErrorCode: String {
  case notSupportedOnDevice
  case permissionDenied
  case notFound
  case cancelled
  case unavailableOffline
  case ioError
  case invalidArgument
  case busy
  case `internal`
}

/// A failure of a PhotoLibrary operation; `message` is debug text without names or paths.
struct PhotoLibraryFailure: Error, Equatable {
  let code: LibraryErrorCode
  let message: String

  init(_ code: LibraryErrorCode, _ message: String) {
    self.code = code
    self.message = message
  }
}

/// Photo library authorization for read-write access.
enum PhotoAuthorization: Equatable {
  case notDetermined
  case restricted
  case denied
  case authorized
  case limited

  /// True when assets can be listed (full or limited access).
  var canRead: Bool { self == .authorized || self == .limited }
}

/// Which assets a fetch lists.
enum PhotoMediaFilter: Hashable {
  case all
  case photos
  case videos
}

/// Sort order of a fetch.
enum PhotoSort: Hashable {
  case creationNewestFirst
  case creationOldestFirst
  case modificationNewestFirst
}

/// The kind of an asset.
enum PhotoAssetKind: Equatable {
  case photo
  case video
}

/// The kind of an album.
enum PhotoAlbumKind: Equatable {
  case smart
  case user
  case shared
}

/// One fetch: the library (album nil) or one album, filtered and sorted.
struct PhotoFetchKey: Hashable {
  let filter: PhotoMediaFilter
  let sort: PhotoSort
  let albumId: String?

  /// The fetch the change observer always keeps, so library changes are seen even before a page
  /// of another fetch was read.
  static let baseline = PhotoFetchKey(filter: .all, sort: .creationNewestFirst, albumId: nil)
}

/// One asset as a grid page carries it.
struct PhotoAssetRecord: Equatable {
  var localIdentifier: String
  var kind: PhotoAssetKind
  var widthPx: Int
  var heightPx: Int
  var creationTimeMs: Int64?
  var modificationTimeMs: Int64?
  var durationMs: Int64
  var isFavorite: Bool
  var isRaw: Bool
  var isHdr: Bool
  var isLivePhoto: Bool
  var isScreenshot: Bool
  var originalFilename: String?
  var uti: String?
  var mimeType: String?
}

/// One page of a fetch.
struct PhotoPageRecord: Equatable {
  var assets: [PhotoAssetRecord]
  var offset: Int
  var totalCount: Int
  var changeToken: String
  var tokenStale: Bool
}

/// One album.
struct PhotoAlbumRecord: Equatable {
  var albumId: String
  var title: String
  var kind: PhotoAlbumKind
  var estimatedCount: Int
}

/// EXIF basics of one asset.
struct PhotoDetailRecord: Equatable {
  var localIdentifier: String
  var iso: Int?
  var aperture: Double?
  var exposureSeconds: Double?
  var focalLengthMm: Double?
  var cameraMake: String?
  var cameraModel: String?
  var lensModel: String?
  var takenAtMs: Int64?
  var latitude: Double?
  var longitude: Double?
  var colorProfile: String?
  var bitDepth: Int?
  var isRaw: Bool
  var isHdr: Bool
  var isLivePhoto: Bool
  var uti: String?
  var mimeType: String?
  var originalFilename: String?
  var sizeBytes: Int64?
  var locallyAvailable: Bool
}

/// The file a copy wrote.
struct PhotoCopyRecord: Equatable {
  var path: String
  var uti: String?
  var mimeType: String?
  var sizeBytes: Int64
}

/// What changed in the library (V2-111).
struct PhotoChangeRecord: Equatable {
  var changeToken: String
  var incremental: Bool
  var inserted: [String]
  var removed: [String]
  var changed: [String]
}

/// Receives the service's events (the Glue forwards them to the Dart event stream).
protocol PhotoLibraryEventSink: AnyObject {
  func photoLibraryDidChange(_ change: PhotoChangeRecord)
  func photoAuthorizationDidChange(_ authorization: PhotoAuthorization)
  func photoCopyProgress(requestId: String, bytesDone: Int64, bytesTotal: Int64?)
}
