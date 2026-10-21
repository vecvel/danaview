// OWNER: HOM-22
//
// Placeholder (D-33) created by HOM-02. HOM-22 replaces this file: Open in another app (UIDocumentInteractionController,
// NSWorkspace), ARCH v1.2 §3.
// Until then every method answers `notSupportedOnDevice` (ARCH v1.2 V2-25). Keep the class name
// and `init(context:)`: the Glue (DanaviewLibraryNativePlugin.swift) constructs it.

import Foundation

final class OpenInHostApiImpl: OpenInHostApi {
  init(context: LibraryPluginContext) {}

  func openIn(request: OpenInRequestMsg, completion: @escaping (Result<Bool, Error>) -> Void) {
    completion(.failure(LibraryErrors.notSupported("HOM-22")))
  }
}
