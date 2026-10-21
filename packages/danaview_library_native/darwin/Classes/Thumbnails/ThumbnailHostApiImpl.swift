// OWNER: HOM-04
//
// Placeholder (D-33) created by HOM-02. HOM-04 replaces this file: the Apple thumbnailers (PHCachingImageManager for ph: assets,
// QLThumbnailGenerator for files; documents from HOM-26), ARCH v1.2 V2-28.
// Until then every method answers `notSupportedOnDevice` (ARCH v1.2 V2-25). Keep the class name
// and `init(context:)`: the Glue (DanaviewLibraryNativePlugin.swift) constructs it.

import Foundation

final class ThumbnailHostApiImpl: ThumbnailHostApi {
  init(context: LibraryPluginContext) {}

  func mediaThumbnail(request: MediaThumbnailRequestMsg, completion: @escaping (Result<ThumbnailResultMsg, Error>) -> Void) {
    completion(.failure(LibraryErrors.notSupported("HOM-04")))
  }

  func documentThumbnail(request: DocumentThumbnailRequestMsg, completion: @escaping (Result<ThumbnailResultMsg?, Error>) -> Void) {
    completion(.failure(LibraryErrors.notSupported("HOM-26")))
  }

  func cancel(requestId: String) throws { throw LibraryErrors.notSupported("HOM-04") }

  func updateCaching(window: ThumbnailCachingMsg) throws { throw LibraryErrors.notSupported("HOM-04") }
}
