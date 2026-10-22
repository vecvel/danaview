// OWNER: HOM-20
//
// PickerHostApi on Apple (ARCH v1.2 §5.6, V2-116, BUILD_PLAN HOM-20):
//
// * pickPhotos: `PHPickerViewController` (iOS 15+, macOS 13+) without a photo library, so no
//   library permission is asked, with the `.current` representation; each pick's file
//   representation (valid only inside its callback) is copied into the request's app-owned
//   staging directory. macOS before 13 falls back to an `NSOpenPanel` for images and movies.
// * pickDocuments: `UIDocumentPickerViewController` in import mode (`asCopy`, multiple), whose
//   app-owned copies move into the staging directory; on macOS an `NSOpenPanel`, whose URLs the
//   import reads directly (read-only).
// * copyToFile: the streamed, resumable copy of PickerCore on a background queue, with progress
//   events on the library event stream; cancelCopy stops it; release gives up held
//   security-scoped access.
//
// Sources are opened read-only (rule 27); only the staging directory and the requested
// destination are written. Replies arrive on the main thread. Nothing is logged (rule 30).

import Foundation

#if os(iOS)
import Flutter
import PhotosUI
import UIKit
import UniformTypeIdentifiers
#elseif os(macOS)
import Cocoa
import FlutterMacOS
import PhotosUI
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
#endif

final class PickerHostApiImpl: PickerHostApi {
  private let context: LibraryPluginContext
  private let copies = CopyRegistry()
  /// Security-scoped access held until `release` (HOM-21's Open-with URLs register here too).
  let scopedAccess = ScopedAccessRegistry()
  private let copyQueue = DispatchQueue(label: "danaview.library.pickers.copy", qos: .userInitiated, attributes: .concurrent)
  /// The picker on screen (one at a time), kept alive until it finishes.
  private var session: AnyObject?

  init(context: LibraryPluginContext) {
    self.context = context
  }

  // MARK: Conversions

  static func msg(_ f: PickedFile) -> PickedItemMsg {
    PickedItemMsg(
      uri: f.uri,
      path: f.path,
      displayName: f.displayName,
      uti: f.uti,
      mimeType: f.mimeType,
      sizeBytes: f.sizeBytes,
      modifiedTimeMs: f.modifiedTimeMs,
      assetIdentifier: f.assetIdentifier,
      source: f.fromPhotoLibrary ? .photoLibrary : .files,
      needsCopy: f.needsCopy
    )
  }

  static func error(_ f: PickerFailure) -> LibraryPigeonError {
    LibraryPigeonError(code: f.code, message: f.message, details: nil)
  }

  private func reply<T>(_ completion: @escaping (Result<T, Error>) -> Void, _ result: Result<T, Error>) {
    if Thread.isMainThread {
      completion(result)
    } else {
      DispatchQueue.main.async { completion(result) }
    }
  }

  private func finish<T>(_ completion: @escaping (Result<T, Error>) -> Void, _ result: Result<T, Error>) {
    session = nil
    reply(completion, result)
  }

  // MARK: Photo picker

  func pickPhotos(request: PhotoPickRequestMsg, completion: @escaping (Result<[PickedItemMsg], Error>) -> Void) {
    guard request.selectionLimit >= 0, !request.destinationDirectory.isEmpty else {
      return completion(.failure(Self.error(.invalid("bad photo pick request"))))
    }
    guard session == nil else { return completion(.failure(Self.error(.busy("a picker is open")))) }
    let staging = URL(fileURLWithPath: request.destinationDirectory, isDirectory: true)
    let filter = PickerMediaFilter(rawValue: request.filter.rawValue) ?? .all
    #if os(iOS)
    presentPhotoPicker(limit: Int(request.selectionLimit), filter: filter, staging: staging, completion: completion)
    #elseif os(macOS)
    if #available(macOS 13.0, *) {
      presentPhotoPicker(limit: Int(request.selectionLimit), filter: filter, staging: staging, completion: completion)
    } else {
      let types = filter == .videos ? ["public.movie"] : (filter == .photos ? ["public.image"] : ["public.image", "public.movie"])
      presentOpenPanel(multiple: request.selectionLimit != 1, utis: types, completion: completion)
    }
    #endif
  }

  @available(iOS 14.0, macOS 13.0, *)
  private func presentPhotoPicker(limit: Int, filter: PickerMediaFilter, staging: URL, completion: @escaping (Result<[PickedItemMsg], Error>) -> Void) {
    var config = PHPickerConfiguration()
    config.selectionLimit = limit
    config.preferredAssetRepresentationMode = .current
    switch filter {
    case .all: config.filter = .any(of: [.images, .videos])
    case .photos: config.filter = .images
    case .videos: config.filter = .videos
    }
    #if os(iOS)
    if #available(iOS 15.0, *) { config.selection = .ordered }
    #endif
    let picker = PHPickerViewController(configuration: config)
    let delegate = PhotoPickerDelegate(filter: filter, staging: staging) { [weak self] result in
      guard let self = self else { return }
      self.finish(completion, result.map { $0.map(Self.msg) }.mapError { Self.error($0) as Error })
    }
    picker.delegate = delegate
    session = delegate
    #if os(iOS)
    guard let host = context.presentingViewController() else {
      return finish(completion, .failure(Self.error(.io("no window to present from"))))
    }
    host.present(picker, animated: true)
    #elseif os(macOS)
    guard let host = context.presentingWindow()?.contentViewController else {
      return finish(completion, .failure(Self.error(.io("no window to present from"))))
    }
    host.presentAsSheet(picker)
    #endif
  }

  // MARK: Document picker

  func pickDocuments(request: DocumentPickRequestMsg, completion: @escaping (Result<[PickedItemMsg], Error>) -> Void) {
    guard session == nil else { return completion(.failure(Self.error(.busy("a picker is open")))) }
    let staging = request.destinationDirectory.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    #if os(iOS)
    let types = request.utis.compactMap { UTType($0) }
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: types.isEmpty ? [.item] : types, asCopy: true)
    picker.allowsMultipleSelection = request.allowMultiple
    let delegate = DocumentPickerDelegate(staging: staging) { [weak self] result in
      guard let self = self else { return }
      self.finish(completion, result.map { $0.map(Self.msg) }.mapError { Self.error($0) as Error })
    }
    picker.delegate = delegate
    session = delegate
    guard let host = context.presentingViewController() else {
      return finish(completion, .failure(Self.error(.io("no window to present from"))))
    }
    host.present(picker, animated: true)
    #elseif os(macOS)
    presentOpenPanel(multiple: request.allowMultiple, utis: request.utis, completion: completion)
    #endif
  }

  #if os(macOS)
  private func presentOpenPanel(multiple: Bool, utis: [String], completion: @escaping (Result<[PickedItemMsg], Error>) -> Void) {
    // A sheet on the app's window only: without one (a test runner, a headless process) a modeless
    // panel would wait for a person forever.
    guard let window = context.presentingWindow() else {
      return completion(.failure(Self.error(.io("no window to present from"))))
    }
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = multiple
    panel.resolvesAliases = true
    if !utis.isEmpty {
      #if canImport(UniformTypeIdentifiers)
      if #available(macOS 11.0, *) {
        panel.allowedContentTypes = utis.compactMap { UTType($0) }
      } else {
        panel.allowedFileTypes = utis
      }
      #else
      panel.allowedFileTypes = utis
      #endif
    }
    session = panel
    panel.beginSheetModal(for: window) { [weak self] response in
      guard let self = self else { return }
      guard response == .OK else { return self.finish(completion, .success([])) }
      // The user's own files: read directly (read-only) by the import, never staged or moved.
      let files = panel.urls.map { PickerCore.pickedFile(at: $0, fromPhotoLibrary: false, needsCopy: false) }
      self.finish(completion, .success(files.map(Self.msg)))
    }
  }
  #endif

  // MARK: Copy

  func copyToFile(request: CopyRequestMsg, completion: @escaping (Result<CopyResultMsg, Error>) -> Void) {
    guard let url = URL(string: request.sourceUri), url.isFileURL else {
      return completion(.failure(Self.error(.invalid("not a file URL"))))
    }
    guard !request.destinationPath.isEmpty, request.resumeFromOffset >= 0 else {
      return completion(.failure(Self.error(.invalid("bad copy request"))))
    }
    let id = request.requestId
    guard copies.start(id) else { return completion(.failure(Self.error(.busy("copy id in use")))) }
    let events = context.events
    copyQueue.async { [copies] in
      let scoped = url.startAccessingSecurityScopedResource()
      defer {
        if scoped { url.stopAccessingSecurityScopedResource() }
        copies.finish(id)
      }
      do {
        let r = try PickerCore.streamCopy(
          from: url,
          to: request.destinationPath,
          resumeFrom: request.resumeFromOffset,
          isCancelled: { copies.isCancelled(id) },
          progress: { done, total in
            events.emit(LibraryEventMsg(kind: .copyProgress, copyProgress: CopyProgressMsg(requestId: id, bytesDone: done, bytesTotal: total)))
          }
        )
        DispatchQueue.main.async { completion(.success(CopyResultMsg(bytesCopied: r.copied, totalBytes: r.total))) }
      } catch let f as PickerFailure {
        DispatchQueue.main.async { completion(.failure(Self.error(f))) }
      } catch {
        DispatchQueue.main.async { completion(.failure(Self.error(.io("copy failed")))) }
      }
    }
  }

  func cancelCopy(requestId: String) throws {
    copies.cancel(requestId)
  }

  func release(uri: String) throws {
    scopedAccess.release(uri)
  }
}

// MARK: - Picker delegates

@available(iOS 14.0, macOS 13.0, *)
private final class PhotoPickerDelegate: NSObject, PHPickerViewControllerDelegate {
  let filter: PickerMediaFilter
  let staging: URL
  let onDone: (Result<[PickedFile], PickerFailure>) -> Void
  private var finished = false

  init(filter: PickerMediaFilter, staging: URL, onDone: @escaping (Result<[PickedFile], PickerFailure>) -> Void) {
    self.filter = filter
    self.staging = staging
    self.onDone = onDone
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    #if os(iOS)
    picker.dismiss(animated: true)
    #elseif os(macOS)
    picker.dismiss(nil)
    #endif
    guard !finished else { return }
    finished = true
    if results.isEmpty { return onDone(.success([])) }
    let group = DispatchGroup()
    let lock = NSLock()
    var files = [PickedFile?](repeating: nil, count: results.count)
    for (index, result) in results.enumerated() {
      let provider = result.itemProvider
      guard let type = PickerCore.bestTypeIdentifier(registered: provider.registeredTypeIdentifiers, filter: filter) else { continue }
      let name = provider.suggestedName
      group.enter()
      provider.loadFileRepresentation(forTypeIdentifier: type) { [staging] url, _ in
        defer { group.leave() }
        // The temporary file is only valid inside this callback: copy it into staging now.
        guard let url = url else { return }
        let display = PickerCore.displayName(suggested: name, typeIdentifier: type, fallback: url)
        guard let staged = try? PickerCore.stage(copyOf: url, into: staging, name: display) else { return }
        let file = PickerCore.pickedFile(at: staged, displayName: display, typeIdentifier: type, fromPhotoLibrary: true, needsCopy: false, assetIdentifier: result.assetIdentifier)
        lock.lock()
        files[index] = file
        lock.unlock()
      }
    }
    group.notify(queue: .main) { [onDone] in
      let picked = files.compactMap { $0 }
      // Every pick failed (iCloud-only originals are never downloaded, ARCH §9.1).
      if picked.isEmpty { return onDone(.failure(.io("no picked item could be loaded"))) }
      onDone(.success(picked))
    }
  }
}

#if os(iOS)
private final class DocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
  let staging: URL?
  let onDone: (Result<[PickedFile], PickerFailure>) -> Void
  private var finished = false

  init(staging: URL?, onDone: @escaping (Result<[PickedFile], PickerFailure>) -> Void) {
    self.staging = staging
    self.onDone = onDone
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard !finished else { return }
    finished = true
    // Import mode (`asCopy`): every URL is the app's own copy in tmp/…-Inbox, never the original.
    var files: [PickedFile] = []
    for url in urls {
      if let staging = staging {
        guard let staged = try? PickerCore.stage(moving: url, into: staging) else { continue }
        files.append(PickerCore.pickedFile(at: staged, fromPhotoLibrary: false, needsCopy: false))
      } else {
        files.append(PickerCore.pickedFile(at: url, fromPhotoLibrary: false, needsCopy: false))
      }
    }
    if files.isEmpty && !urls.isEmpty { return onDone(.failure(.io("no picked document could be staged"))) }
    onDone(.success(files))
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    guard !finished else { return }
    finished = true
    onDone(.success([]))
  }
}
#endif
