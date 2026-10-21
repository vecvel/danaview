// OWNER: HOM-22
//
// Placeholder (D-33) created by HOM-02. HOM-22 replaces this file: Save to Files and Save to Photos (add-only), create-new
// only (ARCH v1.2 rule 26, V2-117).
// Until then every method answers `notSupportedOnDevice` (ARCH v1.2 V2-25). Keep the class name
// and `init(context:)`: the Glue (DanaviewLibraryNativePlugin.swift) constructs it.

import Foundation

final class ExportOutHostApiImpl: ExportOutHostApi {
  init(context: LibraryPluginContext) {}

  func saveOut(request: SaveOutRequestMsg, completion: @escaping (Result<SaveOutResultMsg, Error>) -> Void) {
    completion(.failure(LibraryErrors.notSupported("HOM-22")))
  }
}
