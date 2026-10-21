// OWNER: HOM-22
//
// Placeholder (D-33) created by HOM-02. HOM-22 replaces this file: the share sheet (UIActivityViewController,
// NSSharingServicePicker) with temporary read-only copies (V2-118).
// Until then every method answers `notSupportedOnDevice` (ARCH v1.2 V2-25). Keep the class name
// and `init(context:)`: the Glue (DanaviewLibraryNativePlugin.swift) constructs it.

import Foundation

final class ShareHostApiImpl: ShareHostApi {
  init(context: LibraryPluginContext) {}

  func share(request: ShareRequestMsg, completion: @escaping (Result<ShareResultMsg, Error>) -> Void) {
    completion(.failure(LibraryErrors.notSupported("HOM-22")))
  }
}
