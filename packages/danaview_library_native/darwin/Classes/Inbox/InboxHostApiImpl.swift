// OWNER: HOM-21
//
// Placeholder (D-33) created by HOM-02. HOM-21 replaces this file: the App Group Share Extension inbox, the only App Group
// reader (ARCH v1.2 §5.6, rule 26).
// Until then every method answers `notSupportedOnDevice` (ARCH v1.2 V2-25). Keep the class name
// and `init(context:)`: the Glue (DanaviewLibraryNativePlugin.swift) constructs it.

import Foundation

#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

final class InboxHostApiImpl: InboxHostApi {
  init(context: LibraryPluginContext) {}

  func isAvailable() throws -> Bool { throw LibraryErrors.notSupported("HOM-21") }

  func listBatches(completion: @escaping (Result<[InboxBatchMsg], Error>) -> Void) {
    completion(.failure(LibraryErrors.notSupported("HOM-21")))
  }

  func takeFile(batchId: String, relativePath: String, destinationPath: String, completion: @escaping (Result<Void, Error>) -> Void) {
    completion(.failure(LibraryErrors.notSupported("HOM-21")))
  }

  func deleteBatch(batchId: String, completion: @escaping (Result<Void, Error>) -> Void) {
    completion(.failure(LibraryErrors.notSupported("HOM-21")))
  }

  func deleteStaleBatches(olderThanMs: Int64, completion: @escaping (Result<Int64, Error>) -> Void) {
    completion(.failure(LibraryErrors.notSupported("HOM-21")))
  }

  func writeFolderSnapshot(json: FlutterStandardTypedData, completion: @escaping (Result<Void, Error>) -> Void) {
    completion(.failure(LibraryErrors.notSupported("HOM-21")))
  }
}
