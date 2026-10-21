// OWNER: HOM-02
//
// PhotoLibraryHostApi on Apple: converts Pigeon messages to the Flutter-free PhotoLibraryService
// (PhotoLibrary/) and back, replies on the main thread, forwards service events to the library
// event stream, and presents the limited-library picker (iOS 15+; macOS has no limited access).

import Foundation
import Photos

#if os(iOS)
import Flutter
import PhotosUI
import UIKit
#elseif os(macOS)
import Cocoa
import FlutterMacOS
#endif

final class PhotoLibraryHostApiImpl: PhotoLibraryHostApi, PhotoLibraryEventSink {
  private let context: LibraryPluginContext
  let service: PhotoLibraryService

  init(context: LibraryPluginContext, service: PhotoLibraryService = PhotoLibraryService()) {
    self.context = context
    self.service = service
    service.sink = self
  }

  // MARK: Conversions

  static func msg(_ a: PhotoAuthorization) -> PhotoAuthorizationMsg {
    switch a {
    case .notDetermined: return .notDetermined
    case .restricted: return .restricted
    case .denied: return .denied
    case .authorized: return .authorized
    case .limited: return .limited
    }
  }

  static func key(_ r: PhotoFetchRequestMsg) -> PhotoFetchKey {
    let filter: PhotoMediaFilter
    switch r.filter {
    case .all: filter = .all
    case .photos: filter = .photos
    case .videos: filter = .videos
    }
    let sort: PhotoSort
    switch r.sort {
    case .creationNewestFirst: sort = .creationNewestFirst
    case .creationOldestFirst: sort = .creationOldestFirst
    case .modificationNewestFirst: sort = .modificationNewestFirst
    }
    return PhotoFetchKey(filter: filter, sort: sort, albumId: r.albumId)
  }

  static func msg(_ a: PhotoAssetRecord) -> PhotoAssetMsg {
    PhotoAssetMsg(
      localIdentifier: a.localIdentifier, kind: a.kind == .video ? .video : .photo,
      widthPx: Int64(a.widthPx), heightPx: Int64(a.heightPx),
      creationTimeMs: a.creationTimeMs, modificationTimeMs: a.modificationTimeMs,
      durationMs: a.durationMs, isFavorite: a.isFavorite, isRaw: a.isRaw, isHdr: a.isHdr,
      isLivePhoto: a.isLivePhoto, isScreenshot: a.isScreenshot,
      originalFilename: a.originalFilename, uti: a.uti, mimeType: a.mimeType, sizeBytes: nil)
  }

  static func msg(_ p: PhotoPageRecord) -> PhotoPageMsg {
    PhotoPageMsg(
      assets: p.assets.map(msg), offset: Int64(p.offset), totalCount: Int64(p.totalCount),
      changeToken: p.changeToken, tokenStale: p.tokenStale)
  }

  static func msg(_ c: PhotoChangeRecord) -> PhotoLibraryChangeMsg {
    PhotoLibraryChangeMsg(changeToken: c.changeToken, incremental: c.incremental, inserted: c.inserted, removed: c.removed, changed: c.changed)
  }

  static func msg(_ d: PhotoDetailRecord) -> PhotoAssetDetailMsg {
    PhotoAssetDetailMsg(
      localIdentifier: d.localIdentifier, iso: d.iso.map(Int64.init), aperture: d.aperture,
      exposureSeconds: d.exposureSeconds, focalLengthMm: d.focalLengthMm, cameraMake: d.cameraMake,
      cameraModel: d.cameraModel, lensModel: d.lensModel, takenAtMs: d.takenAtMs, latitude: d.latitude,
      longitude: d.longitude, colorProfile: d.colorProfile, bitDepth: d.bitDepth.map(Int64.init),
      isRaw: d.isRaw, isHdr: d.isHdr, isLivePhoto: d.isLivePhoto, uti: d.uti, mimeType: d.mimeType,
      originalFilename: d.originalFilename, sizeBytes: d.sizeBytes, locallyAvailable: d.locallyAvailable)
  }

  static func msg(_ a: PhotoAlbumRecord) -> PhotoAlbumMsg {
    let kind: PhotoAlbumKindMsg
    switch a.kind {
    case .smart: kind = .smart
    case .user: kind = .user
    case .shared: kind = .shared
    }
    return PhotoAlbumMsg(albumId: a.albumId, title: a.title, kind: kind, estimatedCount: Int64(a.estimatedCount))
  }

  /// Calls [completion] on the main thread with the converted result.
  private func reply<T, M>(_ completion: @escaping (Result<M, Error>) -> Void, _ convert: @escaping (T) -> M) -> (Result<T, PhotoLibraryFailure>) -> Void {
    return { result in
      DispatchQueue.main.async {
        switch result {
        case .success(let value): completion(.success(convert(value)))
        case .failure(let failure): completion(.failure(LibraryErrors.from(failure)))
        }
      }
    }
  }

  // MARK: PhotoLibraryHostApi

  func authorizationStatus() throws -> PhotoAuthorizationMsg { Self.msg(service.authorizationStatus()) }

  func requestAuthorization(completion: @escaping (Result<PhotoAuthorizationMsg, Error>) -> Void) {
    service.requestAuthorization { status in
      DispatchQueue.main.async { completion(.success(Self.msg(status))) }
    }
  }

  func presentLimitedLibraryPicker(completion: @escaping (Result<[String], Error>) -> Void) {
    #if os(iOS)
    guard service.authorizationStatus() == .limited else {
      return completion(.failure(LibraryErrors.error(.invalidArgument, "access is not limited")))
    }
    guard let presenter = context.presentingViewController() else {
      return completion(.failure(LibraryErrors.error(.internal, "no view controller to present from")))
    }
    if #available(iOS 15.0, *) {
      PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presenter) { ids in
        DispatchQueue.main.async { completion(.success(ids)) }
      }
    } else {
      completion(.failure(LibraryErrors.notSupported("iOS 15+")))
    }
    #else
    completion(.failure(LibraryErrors.notSupported("no limited access on macOS")))
    #endif
  }

  func openAppSettings() throws -> Bool {
    #if os(iOS)
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return false }
    UIApplication.shared.open(url)
    return true
    #else
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") else { return false }
    return NSWorkspace.shared.open(url)
    #endif
  }

  func startObserving() throws { service.startObserving() }

  func stopObserving() throws { service.stopObserving() }

  func fetchPage(request: PhotoFetchRequestMsg, completion: @escaping (Result<PhotoPageMsg, Error>) -> Void) {
    service.fetchPage(
      key: Self.key(request), offset: Int(request.offset), limit: Int(request.limit), token: request.changeToken,
      completion: reply(completion, Self.msg as (PhotoPageRecord) -> PhotoPageMsg))
  }

  func fetchAssets(localIdentifiers: [String], completion: @escaping (Result<[PhotoAssetMsg], Error>) -> Void) {
    service.fetchAssets(localIdentifiers, completion: reply(completion) { (records: [PhotoAssetRecord]) in records.map(Self.msg) })
  }

  func fetchAlbums(completion: @escaping (Result<[PhotoAlbumMsg], Error>) -> Void) {
    service.fetchAlbums(reply(completion) { (records: [PhotoAlbumRecord]) in records.map(Self.msg) })
  }

  func assetDetail(localIdentifier: String, completion: @escaping (Result<PhotoAssetDetailMsg, Error>) -> Void) {
    service.assetDetail(localIdentifier, completion: reply(completion, Self.msg as (PhotoDetailRecord) -> PhotoAssetDetailMsg))
  }

  func copyAsset(request: PhotoCopyRequestMsg, completion: @escaping (Result<PhotoCopyResultMsg, Error>) -> Void) {
    service.copyAsset(
      requestId: request.requestId, id: request.localIdentifier, directory: request.destinationDirectory,
      pairedVideo: request.pairedVideo,
      completion: reply(completion) { (r: PhotoCopyRecord) in
        PhotoCopyResultMsg(path: r.path, uti: r.uti, mimeType: r.mimeType, sizeBytes: r.sizeBytes)
      })
  }

  func cancelCopy(requestId: String) throws { service.cancelCopy(requestId) }

  // MARK: PhotoLibraryEventSink

  func photoLibraryDidChange(_ change: PhotoChangeRecord) {
    context.events.emit(LibraryEventMsg(kind: .photoLibraryChanged, photoChange: Self.msg(change)))
  }

  func photoAuthorizationDidChange(_ authorization: PhotoAuthorization) {
    context.events.emit(LibraryEventMsg(kind: .photoAuthorizationChanged, authorization: Self.msg(authorization)))
  }

  func photoCopyProgress(requestId: String, bytesDone: Int64, bytesTotal: Int64?) {
    context.events.emit(LibraryEventMsg(
      kind: .copyProgress, copyProgress: CopyProgressMsg(requestId: requestId, bytesDone: bytesDone, bytesTotal: bytesTotal)))
  }
}
