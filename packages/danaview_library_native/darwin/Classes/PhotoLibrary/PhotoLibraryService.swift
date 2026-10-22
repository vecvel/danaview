// OWNER: HOM-02
//
// The PhotoKit library (ARCH v1.2 §8, V2-103, V2-111): authorization, paged fetches over cached
// `PHFetchResult` snapshots with change tokens (kept current by the change observer while
// observing; re-fetched and compared on every page while not), albums, EXIF basics, create-new copies of
// originals, and `PHPhotoLibraryChangeObserver` → change events. Limited access is honoured by
// PhotoKit itself (fetches return only the selected assets). Every PhotoKit call runs on one serial
// background queue; completions are called on that queue (the Glue hops to the main thread). No
// network: `isNetworkAccessAllowed` is false everywhere, so an iCloud-only original answers
// `unavailableOffline` (§9.1, rule 21).

import Foundation
import ImageIO
import Photos

/// Reads and requests the photo library authorization (injectable for tests).
protocol PhotoAuthorizing: AnyObject {
  func status() -> PhotoAuthorization
  func request(_ completion: @escaping (PhotoAuthorization) -> Void)
}

/// The system authorization (`PHPhotoLibrary`, `.readWrite` level where it exists).
final class SystemPhotoAuthorizing: PhotoAuthorizing {
  func status() -> PhotoAuthorization {
    if #available(iOS 14.0, macOS 11.0, *) {
      return Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }
    return Self.map(PHPhotoLibrary.authorizationStatus())
  }

  func request(_ completion: @escaping (PhotoAuthorization) -> Void) {
    if #available(iOS 14.0, macOS 11.0, *) {
      PHPhotoLibrary.requestAuthorization(for: .readWrite) { completion(Self.map($0)) }
    } else {
      PHPhotoLibrary.requestAuthorization { completion(Self.map($0)) }
    }
  }

  static func map(_ status: PHAuthorizationStatus) -> PhotoAuthorization {
    switch status {
    case .authorized: return .authorized
    case .denied: return .denied
    case .restricted: return .restricted
    case .notDetermined: return .notDetermined
    case .limited: return .limited
    @unknown default: return .denied
    }
  }
}

final class PhotoLibraryService: NSObject, PHPhotoLibraryChangeObserver {
  /// Most fetch snapshots kept at once (least recently used dropped; the baseline always stays).
  static let maxSnapshots = 8

  let queue = DispatchQueue(label: "com.vecvel.danaview.library.photos", qos: .userInitiated)
  private let authorizing: PhotoAuthorizing
  private let library: () -> PHPhotoLibrary
  weak var sink: PhotoLibraryEventSink?

  // State below is touched only on `queue`.
  private var book = PhotoSnapshotBook()
  private var snapshots: [PhotoFetchKey: PHFetchResult<PHAsset>] = [:]
  private var lru: [PhotoFetchKey] = []
  private var observing = false
  private var lastAuthorization: PhotoAuthorization?
  private var cancelledCopies: Set<String> = []
  private var runningCopies: Set<String> = []

  init(authorizing: PhotoAuthorizing = SystemPhotoAuthorizing(), library: @escaping () -> PHPhotoLibrary = { PHPhotoLibrary.shared() }) {
    self.authorizing = authorizing
    self.library = library
    super.init()
  }

  deinit {
    if observing { library().unregisterChangeObserver(self) }
  }

  // MARK: Authorization

  func authorizationStatus() -> PhotoAuthorization { authorizing.status() }

  func requestAuthorization(_ completion: @escaping (PhotoAuthorization) -> Void) {
    authorizing.request { [weak self] status in
      guard let self = self else { return completion(status) }
      self.queue.async {
        self.noteAuthorization(status)
        completion(status)
      }
    }
  }

  private func noteAuthorization(_ status: PhotoAuthorization) {
    let previous = lastAuthorization
    lastAuthorization = status
    if !status.canRead {
      snapshots.removeAll()
      lru.removeAll()
    }
    if let previous = previous, previous != status { sink?.photoAuthorizationDidChange(status) }
  }

  // MARK: Observing

  /// Registers the change observer; call after access was granted (an earlier registration can
  /// prompt). Idempotent.
  func startObserving() {
    queue.async {
      self.lastAuthorization = self.authorizing.status()
      guard !self.observing, self.lastAuthorization?.canRead == true else { return }
      // Changes made while nobody observed were never applied: start from fresh snapshots and
      // make every earlier token stale.
      self.resetSnapshots()
      self.observing = true
      _ = self.snapshot(for: .baseline)
      self.library().register(self)
    }
  }

  func stopObserving() {
    queue.async {
      guard self.observing else { return }
      self.observing = false
      self.library().unregisterChangeObserver(self)
      // Nothing keeps the snapshots current from here on.
      self.resetSnapshots()
    }
  }

  /// Drops every cached snapshot and moves the token (earlier pages are stale). On `queue`.
  private func resetSnapshots() {
    snapshots.removeAll()
    lru.removeAll()
    book.record(shiftsIndices: true)
  }

  /// PhotoKit change callback (any queue).
  func photoLibraryDidChange(_ changeInstance: PHChange) {
    queue.async {
      let status = self.authorizing.status()
      if status != self.lastAuthorization { self.noteAuthorization(status) }
      if let change = self.apply({ changeInstance.changeDetails(for: $0) }) {
        self.sink?.photoLibraryDidChange(change)
      }
    }
  }

  /// Applies change details to every cached snapshot and returns what changed, or nil when no
  /// snapshot was affected. Runs on `queue`; tests pass details built with
  /// `PHFetchResultChangeDetails(from:to:changedObjects:)`.
  func apply(_ detailsFor: (PHFetchResult<PHAsset>) -> PHFetchResultChangeDetails<PHAsset>?) -> PhotoChangeRecord? {
    var inserted: [String] = [], removed: [String] = [], changed: [String] = []
    var seenInserted = Set<String>(), seenRemoved = Set<String>(), seenChanged = Set<String>()
    var affected = false, shifts = false, incremental = true
    for key in lru {
      guard let result = snapshots[key], let details = detailsFor(result) else { continue }
      affected = true
      snapshots[key] = details.fetchResultAfterChanges
      guard details.hasIncrementalChanges else {
        incremental = false
        shifts = true
        continue
      }
      if !details.insertedObjects.isEmpty || !details.removedObjects.isEmpty || details.hasMoves { shifts = true }
      for a in details.insertedObjects where seenInserted.insert(a.localIdentifier).inserted { inserted.append(a.localIdentifier) }
      for a in details.removedObjects where seenRemoved.insert(a.localIdentifier).inserted { removed.append(a.localIdentifier) }
      for a in details.changedObjects where seenChanged.insert(a.localIdentifier).inserted { changed.append(a.localIdentifier) }
    }
    guard affected else { return nil }
    let token = book.record(shiftsIndices: shifts)
    return PhotoChangeRecord(
      changeToken: token,
      incremental: incremental,
      inserted: inserted,
      removed: removed.filter { !seenInserted.contains($0) },
      changed: changed.filter { !seenInserted.contains($0) && !seenRemoved.contains($0) }
    )
  }

  // MARK: Fetching

  /// The fetch options of [key]'s filter and sort.
  static func options(for key: PhotoFetchKey) -> PHFetchOptions {
    let o = PHFetchOptions()
    switch key.filter {
    case .all:
      o.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
    case .photos:
      o.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
    case .videos:
      o.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
    }
    switch key.sort {
    case .creationNewestFirst: o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    case .creationOldestFirst: o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
    case .modificationNewestFirst: o.sortDescriptors = [NSSortDescriptor(key: "modificationDate", ascending: false)]
    }
    return o
  }

  /// The snapshot of [key]; nil for an unknown album. On `queue`.
  ///
  /// While observing, the cached snapshot is current (the change observer applies every change)
  /// and is returned as is. While not observing, nothing keeps a cache current, so every call
  /// fetches afresh; when the fresh fetch differs from the previous one in count or in the ids of
  /// [window] (an insert, delete or move that shifts indices), the token moves so pages read
  /// against the old snapshot are stale.
  private func snapshot(for key: PhotoFetchKey, window: (offset: Int, limit: Int)? = nil) -> PHFetchResult<PHAsset>? {
    if observing, let cached = snapshots[key] {
      touch(key)
      return cached
    }
    guard let result = Self.fetch(key) else {
      snapshots[key] = nil
      lru.removeAll { $0 == key }
      return nil
    }
    if !observing, let previous = snapshots[key], Self.shifted(from: previous, to: result, window: window) {
      book.record(shiftsIndices: true)
    }
    snapshots[key] = result
    touch(key)
    while lru.count > Self.maxSnapshots, let victim = lru.first(where: { $0 != .baseline }) {
      lru.removeAll { $0 == victim }
      snapshots[victim] = nil
    }
    return result
  }

  /// A fresh fetch of [key]; nil for an unknown album.
  private static func fetch(_ key: PhotoFetchKey) -> PHFetchResult<PHAsset>? {
    if let albumId = key.albumId {
      guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumId], options: nil).firstObject else {
        return nil
      }
      return PHAsset.fetchAssets(in: collection, options: options(for: key))
    }
    return PHAsset.fetchAssets(with: options(for: key))
  }

  /// True when [next] has another count than [previous] or other ids in the page [window] (the
  /// whole leading page when none is given). Reads identifiers only, never resources.
  static func shifted(from previous: PHFetchResult<PHAsset>, to next: PHFetchResult<PHAsset>, window: (offset: Int, limit: Int)?) -> Bool {
    guard previous.count == next.count else { return true }
    let range = (try? PhotoSnapshotBook.window(offset: window?.offset ?? 0, limit: window?.limit ?? 200, count: next.count)) ?? 0..<0
    guard !range.isEmpty else { return false }
    let indices = IndexSet(integersIn: range)
    return previous.objects(at: indices).map(\.localIdentifier) != next.objects(at: indices).map(\.localIdentifier)
  }

  private func touch(_ key: PhotoFetchKey) {
    lru.removeAll { $0 == key }
    lru.append(key)
  }

  private func requireRead() throws {
    let status = authorizing.status()
    if status != lastAuthorization { noteAuthorization(status) }
    guard status.canRead else { throw PhotoLibraryFailure(.permissionDenied, "photo library access not granted") }
  }

  func fetchPage(key: PhotoFetchKey, offset: Int, limit: Int, token: String?, completion: @escaping (Result<PhotoPageRecord, PhotoLibraryFailure>) -> Void) {
    queue.async {
      do {
        try self.requireRead()
        guard let result = self.snapshot(for: key, window: (offset, limit)) else { throw PhotoLibraryFailure(.notFound, "album not found") }
        let window = try PhotoSnapshotBook.window(offset: offset, limit: limit, count: result.count)
        var assets: [PhotoAssetRecord] = []
        assets.reserveCapacity(window.count)
        if !window.isEmpty {
          for asset in result.objects(at: IndexSet(integersIn: window)) {
            // Cheap fields only: no resource lookups on the page path (see PhotoAssetMapping).
            if let record = PhotoAssetMapping.pageRecord(from: asset) { assets.append(record) }
          }
        }
        completion(.success(PhotoPageRecord(
          assets: assets, offset: offset, totalCount: result.count, changeToken: self.book.token, tokenStale: self.book.isStale(token))))
      } catch let failure as PhotoLibraryFailure {
        completion(.failure(failure))
      } catch {
        completion(.failure(PhotoLibraryFailure(.internal, "fetch failed")))
      }
    }
  }

  func fetchAssets(_ ids: [String], completion: @escaping (Result<[PhotoAssetRecord], PhotoLibraryFailure>) -> Void) {
    queue.async {
      do {
        try self.requireRead()
        guard !ids.isEmpty else { return completion(.success([])) }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var byId: [String: PhotoAssetRecord] = [:]
        result.enumerateObjects { asset, _, _ in
          if let r = PhotoAssetMapping.record(from: asset) { byId[r.localIdentifier] = r }
        }
        completion(.success(ids.compactMap { byId[$0] }))
      } catch let failure as PhotoLibraryFailure {
        completion(.failure(failure))
      } catch {
        completion(.failure(PhotoLibraryFailure(.internal, "fetch failed")))
      }
    }
  }

  func fetchAlbums(_ completion: @escaping (Result<[PhotoAlbumRecord], PhotoLibraryFailure>) -> Void) {
    queue.async {
      do {
        try self.requireRead()
        var out: [PhotoAlbumRecord] = []
        let media = Self.options(for: .baseline)
        let excludedSmart: Set<PHAssetCollectionSubtype> = [.smartAlbumAllHidden, .smartAlbumUserLibrary]
        let groups: [(PHAssetCollectionType, PHAssetCollectionSubtype)] = [(.smartAlbum, .any), (.album, .any)]
        for (type, subtype) in groups {
          let collections = PHAssetCollection.fetchAssetCollections(with: type, subtype: subtype, options: nil)
          collections.enumerateObjects { c, _, _ in
            if type == .smartAlbum && excludedSmart.contains(c.assetCollectionSubtype) { return }
            let count = PHAsset.fetchAssets(in: c, options: media).count
            guard count > 0 else { return }
            let kind: PhotoAlbumKind = type == .smartAlbum ? .smart : (c.assetCollectionSubtype == .albumCloudShared ? .shared : .user)
            out.append(PhotoAlbumRecord(albumId: c.localIdentifier, title: c.localizedTitle ?? "", kind: kind, estimatedCount: count))
          }
        }
        completion(.success(out))
      } catch let failure as PhotoLibraryFailure {
        completion(.failure(failure))
      } catch {
        completion(.failure(PhotoLibraryFailure(.internal, "albums failed")))
      }
    }
  }

  // MARK: Detail

  func assetDetail(_ id: String, completion: @escaping (Result<PhotoDetailRecord, PhotoLibraryFailure>) -> Void) {
    queue.async {
      do {
        try self.requireRead()
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
              let record = PhotoAssetMapping.record(from: asset) else {
          throw PhotoLibraryFailure(.notFound, "asset not found")
        }
        var base = PhotoDetailRecord(
          localIdentifier: id, isRaw: record.isRaw, isHdr: record.isHdr, isLivePhoto: record.isLivePhoto,
          uti: record.uti, mimeType: record.mimeType, originalFilename: record.originalFilename, locallyAvailable: true)
        base.takenAtMs = record.creationTimeMs
        if let location = asset.location {
          base.latitude = location.coordinate.latitude
          base.longitude = location.coordinate.longitude
        }
        guard record.kind == .photo else { return completion(.success(base)) }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false
        options.version = .current
        options.deliveryMode = .highQualityFormat
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
          self.queue.async {
            if (info?[PHImageCancelledKey] as? Bool) == true {
              return completion(.failure(PhotoLibraryFailure(.cancelled, "detail cancelled")))
            }
            guard let data = data else {
              // No local data: the original is only in iCloud (never downloaded), or unreadable.
              var offline = base
              offline.locallyAvailable = !((info?[PHImageResultIsInCloudKey] as? Bool) ?? true)
              return completion(.success(offline))
            }
            var d = base
            d.sizeBytes = Int64(data.count)
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            if let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
               let props = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [String: Any] {
              d = PhotoAssetMapping.detail(from: props, base: d)
            }
            completion(.success(d))
          }
        }
      } catch let failure as PhotoLibraryFailure {
        completion(.failure(failure))
      } catch {
        completion(.failure(PhotoLibraryFailure(.internal, "detail failed")))
      }
    }
  }

  // MARK: Copy

  /// Writes the asset's original (or current edit, or Live Photo movie) into [directory] under a
  /// new name (never overwrites). PhotoKit's local writes report no progress, so one progress
  /// event is sent when the copy completes.
  func copyAsset(requestId: String, id: String, directory: String, pairedVideo: Bool,
                 completion: @escaping (Result<PhotoCopyRecord, PhotoLibraryFailure>) -> Void) {
    queue.async {
      do {
        try self.requireRead()
        guard !self.runningCopies.contains(requestId) else { throw PhotoLibraryFailure(.busy, "request id in use") }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue else {
          throw PhotoLibraryFailure(.invalidArgument, "destination is not a directory")
        }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
              let kind = PhotoAssetMapping.kind(of: asset) else {
          throw PhotoLibraryFailure(.notFound, "asset not found")
        }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = PhotoAssetMapping.copyResource(resources, kind: kind, pairedVideo: pairedVideo) else {
          throw PhotoLibraryFailure(.notFound, "resource not found")
        }
        let fallback = kind == .video || pairedVideo ? "Video.mov" : "Photo.jpg"
        let name = CopyNaming.sanitize(resource.originalFilename, fallback: fallback)
        guard let path = CopyNaming.unique(directory: directory, name: name, exists: { FileManager.default.fileExists(atPath: $0) }) else {
          throw PhotoLibraryFailure(.ioError, "no free name")
        }
        self.runningCopies.insert(requestId)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        let url = URL(fileURLWithPath: path)
        PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
          self.queue.async {
            self.runningCopies.remove(requestId)
            let cancelled = self.cancelledCopies.remove(requestId) != nil
            if cancelled || error != nil {
              try? FileManager.default.removeItem(at: url)
            }
            if cancelled { return completion(.failure(PhotoLibraryFailure(.cancelled, "copy cancelled"))) }
            if let error = error as NSError? {
              return completion(.failure(Self.copyFailure(error)))
            }
            let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
            self.sink?.photoCopyProgress(requestId: requestId, bytesDone: size, bytesTotal: size)
            let uti = resource.uniformTypeIdentifier
            completion(.success(PhotoCopyRecord(
              path: path, uti: uti, mimeType: PhotoTypes.mimeType(uti: uti) ?? PhotoTypes.mimeType(fileName: path), sizeBytes: size)))
          }
        }
      } catch let failure as PhotoLibraryFailure {
        completion(.failure(failure))
      } catch {
        completion(.failure(PhotoLibraryFailure(.internal, "copy failed")))
      }
    }
  }

  func cancelCopy(_ requestId: String) {
    queue.async {
      if self.runningCopies.contains(requestId) { self.cancelledCopies.insert(requestId) }
    }
  }

  /// The failure of a PhotoKit write error: iCloud-only originals are `unavailableOffline`.
  static func copyFailure(_ error: NSError) -> PhotoLibraryFailure {
    // PHPhotosError raw codes (the enum cases need macOS 11/12): 3164 networkAccessRequired,
    // 3310 accessRestricted, 3311 accessUserDenied.
    if error.domain == PHPhotosErrorDomain {
      if error.code == 3164 { return PhotoLibraryFailure(.unavailableOffline, "original is not on this device") }
      if error.code == 3310 || error.code == 3311 { return PhotoLibraryFailure(.permissionDenied, "access denied") }
    }
    if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
      return PhotoLibraryFailure(.ioError, "destination exists")
    }
    return PhotoLibraryFailure(.ioError, "copy failed (\(error.domain) \(error.code))")
  }
}
