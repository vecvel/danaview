// OWNER: HOM-20
//
// Placeholder (D-33) created by HOM-02. HOM-20 replaces this file: the Apple pickers (PHPickerViewController,
// UIDocumentPickerViewController, NSOpenPanel) and streamed copies of picked items (ARCH v1.2 §5.6).
// Until then every method answers `notSupportedOnDevice` (ARCH v1.2 V2-25). Keep the class name
// and `init(context:)`: the Glue (DanaviewLibraryNativePlugin.swift) constructs it.

import Foundation

final class PickerHostApiImpl: PickerHostApi {
  init(context: LibraryPluginContext) {}

  func pickPhotos(request: PhotoPickRequestMsg, completion: @escaping (Result<[PickedItemMsg], Error>) -> Void) {
    completion(.failure(LibraryErrors.notSupported("HOM-20")))
  }

  func pickDocuments(request: DocumentPickRequestMsg, completion: @escaping (Result<[PickedItemMsg], Error>) -> Void) {
    completion(.failure(LibraryErrors.notSupported("HOM-20")))
  }

  func copyToFile(request: CopyRequestMsg, completion: @escaping (Result<CopyResultMsg, Error>) -> Void) {
    completion(.failure(LibraryErrors.notSupported("HOM-20")))
  }

  func cancelCopy(requestId: String) throws { throw LibraryErrors.notSupported("HOM-20") }

  func release(uri: String) throws { throw LibraryErrors.notSupported("HOM-20") }
}
