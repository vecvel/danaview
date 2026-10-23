// OWNER: HOM-21
//
// InboxHostApi over the App Group inbox of the iOS Share Extension (ARCH v1.2 §5.6; rule 26: the
// only App Group reader). File work runs on a serial background queue; results come back on the
// main thread. The extension's "batch finished" Darwin notification becomes an `inboxChanged`
// library event, so a running app imports at once. macOS has no Share Extension inbox (ARCH v1.2
// §5.2: iOS only): every method answers notSupportedOnDevice there. Nothing is logged (rule 30).

import Foundation

#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

final class InboxHostApiImpl: InboxHostApi {
  private let context: LibraryPluginContext
  private let queue = DispatchQueue(label: "com.vecvel.danaview.library.inbox", qos: .utility)
  #if os(iOS)
  private lazy var store: InboxStore? = InboxStore.shared()
  #endif

  init(context: LibraryPluginContext) {
    self.context = context
    #if os(iOS)
    let observer = Unmanaged.passUnretained(context.events).toOpaque()
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(), observer,
      { _, observer, _, _, _ in
        guard let observer = observer else { return }
        let hub = Unmanaged<LibraryEventHub>.fromOpaque(observer).takeUnretainedValue()
        hub.emit(LibraryEventMsg(kind: .inboxChanged))
      },
      danaviewInboxChangedNotification as CFString, nil, .deliverImmediately)
    #endif
  }

  deinit {
    #if os(iOS)
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(context.events).toOpaque(), nil, nil)
    #endif
  }

  private static func ioError(_ error: Error) -> LibraryPigeonError {
    switch error as? InboxCoreError {
    case .invalidPath?: return LibraryErrors.error(.invalidArgument, "path outside the inbox")
    case .missing?: return LibraryErrors.error(.notFound, "inbox item not found")
    case .io(let text)?: return LibraryErrors.error(.ioError, text)
    case nil: return LibraryErrors.error(.ioError, "inbox failure")
    }
  }

  private func run<T>(_ completion: @escaping (Result<T, Error>) -> Void, _ work: @escaping (InboxStore) throws -> T) {
    #if os(iOS)
    guard let store = store else {
      return completion(.failure(LibraryErrors.error(.notFound, "App Group container missing")))
    }
    queue.async {
      let result: Result<T, Error>
      do { result = .success(try work(store)) } catch { result = .failure(InboxHostApiImpl.ioError(error)) }
      DispatchQueue.main.async { completion(result) }
    }
    #endif
  }

  func isAvailable() throws -> Bool {
    #if os(iOS)
    return store != nil
    #else
    throw LibraryErrors.notSupported("HOM-21: iOS only")
    #endif
  }

  func listBatches(completion: @escaping (Result<[InboxBatchMsg], Error>) -> Void) {
    #if os(iOS)
    run(completion) { store in
      store.listBatches().map { b in
        InboxBatchMsg(batchId: b.batchId, createdAtMs: b.createdAtMs, complete: b.complete, targetFolderId: b.targetFolderId,
                      files: b.files.map { InboxFileMsg(relativePath: $0.relativePath, displayName: $0.displayName, uti: $0.uti, mimeType: $0.mimeType, sizeBytes: $0.sizeBytes) })
      }
    }
    #else
    completion(.failure(LibraryErrors.notSupported("HOM-21: iOS only")))
    #endif
  }

  func takeFile(batchId: String, relativePath: String, destinationPath: String, completion: @escaping (Result<Void, Error>) -> Void) {
    #if os(iOS)
    guard destinationPath.hasPrefix("/") else {
      return completion(.failure(LibraryErrors.error(.invalidArgument, "destination must be an absolute path")))
    }
    run(completion) { store in
      try store.takeFile(batchId: batchId, relativePath: relativePath, destination: URL(fileURLWithPath: destinationPath))
    }
    #else
    completion(.failure(LibraryErrors.notSupported("HOM-21: iOS only")))
    #endif
  }

  func deleteBatch(batchId: String, completion: @escaping (Result<Void, Error>) -> Void) {
    #if os(iOS)
    run(completion) { store in try store.deleteBatch(batchId) }
    #else
    completion(.failure(LibraryErrors.notSupported("HOM-21: iOS only")))
    #endif
  }

  func deleteStaleBatches(olderThanMs: Int64, completion: @escaping (Result<Int64, Error>) -> Void) {
    #if os(iOS)
    run(completion) { store in
      Int64(store.deleteStaleBatches(olderThanMs: olderThanMs, nowMs: Int64((Date().timeIntervalSince1970 * 1000).rounded())))
    }
    #else
    completion(.failure(LibraryErrors.notSupported("HOM-21: iOS only")))
    #endif
  }

  func writeFolderSnapshot(json: FlutterStandardTypedData, completion: @escaping (Result<Void, Error>) -> Void) {
    #if os(iOS)
    let data = json.data
    run(completion) { store in try store.writeFolderSnapshot(data) }
    #else
    completion(.failure(LibraryErrors.notSupported("HOM-21: iOS only")))
    #endif
  }
}
