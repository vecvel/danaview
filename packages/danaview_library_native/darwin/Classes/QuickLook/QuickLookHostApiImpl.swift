// OWNER: HOM-26
//
// Placeholder (D-33) created by HOM-02. HOM-26 replaces this file: Quick Look (QLPreviewController / QLPreviewView) with
// editing disabled (V2-120).
// Until then every method answers `notSupportedOnDevice` (ARCH v1.2 V2-25). Keep the class name
// and `init(context:)`: the Glue (DanaviewLibraryNativePlugin.swift) constructs it.

import Foundation

final class QuickLookHostApiImpl: QuickLookHostApi {
  init(context: LibraryPluginContext) {}

  func canPreview(item: FileItemMsg, completion: @escaping (Result<Bool, Error>) -> Void) {
    completion(.failure(LibraryErrors.notSupported("HOM-26")))
  }

  func present(request: QuickLookRequestMsg, completion: @escaping (Result<Void, Error>) -> Void) {
    completion(.failure(LibraryErrors.notSupported("HOM-26")))
  }
}
