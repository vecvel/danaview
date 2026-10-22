// OWNER: HOM-22
//
// ExportOutHostApi on Apple (ARCH v1.2 §8 "Getting files out", rule 26, V2-117; HOM plan §8.3):
//
// * files, iOS: "Save to Files", `UIDocumentPickerViewController(forExporting:asCopy: true)` over
//   temporary read-only copies named as the user sees them; the picker writes new files where the
//   user chose and the library file is never moved.
// * files, macOS: a save panel for one file, an open panel choosing a folder ("Save Here") for
//   several; the copies are created new in the chosen folder (`Name (2).ext` when the name is taken,
//   even after the panel's own "Replace" answer: save-out never writes over a file it didn't create).
// * photos: "Save to Photos", add-only (`PHPhotoLibrary` `.addOnly` authorization,
//   `PHAssetCreationRequest` with `shouldMoveFile = false`); items that aren't photos or videos are
//   counted as failed.
// * downloads: Android only; Apple answers `notSupportedOnDevice`.
//
// One export at a time (`busy` otherwise). The presenter and the photo saver are protocols so the
// XCTests drive the flow without system UI. Replies arrive on the main thread. Nothing is logged.

import Foundation

#if os(iOS)
import Flutter
import Photos
import UIKit
import UniformTypeIdentifiers
#elseif os(macOS)
import Cocoa
import FlutterMacOS
import Photos
#endif

/// What the system export UI did.
enum ExportPick {
  /// The user cancelled.
  case cancelled

  /// The system wrote these new files itself (iOS document picker).
  case exported([URL])

  /// The user chose a folder; the plugin writes create-new copies there, named [names] (one per
  /// item) or the items' display names.
  case directory(URL, names: [String]?)
}

/// Shows the system "save a copy" UI.
protocol ExportPresenter: AnyObject {
  /// Presents the export UI for [files] whose temporary copies are [batch].
  func presentExport(files: [OutFile], batch: TempBatch, anchor: CGRect?, completion: @escaping (Result<ExportPick, OutFailure>) -> Void)
}

/// Adds photos and videos to the system photo library (add-only).
protocol PhotoSaver: AnyObject {
  /// Saves each item; the result has one asset id per item (nil where that item failed).
  func save(_ items: [(file: OutFile, kind: OutMediaKind)], completion: @escaping (Result<[String?], OutFailure>) -> Void)
}

final class ExportOutHostApiImpl: ExportOutHostApi {
  private let presenter: ExportPresenter
  private let photoSaver: PhotoSaver
  let temp: TempCopyStore
  private var busy = false

  convenience init(context: LibraryPluginContext) {
    self.init(presenter: SystemExportPresenter(context: context), photoSaver: SystemPhotoSaver(), temp: TempCopyStore())
    DispatchQueue.global(qos: .utility).async { [temp] in temp.sweepStale() }
  }

  init(presenter: ExportPresenter, photoSaver: PhotoSaver, temp: TempCopyStore) {
    self.presenter = presenter
    self.photoSaver = photoSaver
    self.temp = temp
  }

  func saveOut(request: SaveOutRequestMsg, completion: @escaping (Result<SaveOutResultMsg, Error>) -> Void) {
    let files = request.items.map(FileOutGlue.outFile)
    do {
      try FileOutCore.validate(files)
    } catch {
      return FileOutGlue.reply(completion, .failure(FileOutGlue.error(error)))
    }
    switch request.destination {
    case .downloads:
      return FileOutGlue.reply(completion, .failure(FileOutGlue.error(OutFailure.unsupported("Save to Downloads is Android only"))))
    case .photos:
      return saveToPhotos(files, completion)
    case .files:
      return saveToFiles(files, anchor: FileOutGlue.rect(request.anchor), completion)
    }
  }

  // MARK: Save to Files

  private func saveToFiles(_ files: [OutFile], anchor: CGRect?, _ completion: @escaping (Result<SaveOutResultMsg, Error>) -> Void) {
    guard !busy else { return FileOutGlue.reply(completion, .failure(FileOutGlue.error(OutFailure.busy("an export is open")))) }
    let batch: TempBatch
    do {
      batch = try temp.makeBatch(files)
    } catch {
      return FileOutGlue.reply(completion, .failure(FileOutGlue.error(error)))
    }
    busy = true
    presenter.presentExport(files: files, batch: batch, anchor: anchor) { [weak self] result in
      guard let self = self else { return }
      let outcome: Result<SaveOutResultMsg, Error>
      switch result {
      case .failure(let f):
        outcome = .failure(FileOutGlue.error(f))
      case .success(.cancelled):
        outcome = .success(SaveOutResultMsg(cancelled: true, savedUris: [], failedCount: 0))
      case .success(.exported(let urls)):
        outcome = .success(SaveOutResultMsg(cancelled: false, savedUris: urls.map { $0.absoluteString }, failedCount: Int64(max(0, files.count - urls.count))))
      case .success(.directory(let dir, let names)):
        outcome = .success(Self.copy(files, into: dir, names: names))
      }
      self.temp.remove(batch)
      self.busy = false
      FileOutGlue.reply(completion, outcome)
    }
  }

  /// Create-new copies of [files] in [dir] (see the file header).
  static func copy(_ files: [OutFile], into dir: URL, names: [String]?) -> SaveOutResultMsg {
    var saved: [String] = []
    var failed = 0
    for (i, f) in files.enumerated() {
      var named = f
      if let names = names, i < names.count, !names[i].isEmpty { named.displayName = names[i] }
      if let url = try? FileOutCore.exportCopy(named, toDirectory: dir) {
        saved.append(url.absoluteString)
      } else {
        failed += 1
      }
    }
    return SaveOutResultMsg(cancelled: false, savedUris: saved, failedCount: Int64(failed))
  }

  // MARK: Save to Photos

  private func saveToPhotos(_ files: [OutFile], _ completion: @escaping (Result<SaveOutResultMsg, Error>) -> Void) {
    let media = files.map { (file: $0, kind: FileOutCore.mediaKind($0)) }
    let savable = media.filter { $0.kind != .other }
    let skipped = media.count - savable.count
    guard !savable.isEmpty else {
      return FileOutGlue.reply(completion, .success(SaveOutResultMsg(cancelled: false, savedUris: [], failedCount: Int64(skipped))))
    }
    photoSaver.save(savable) { result in
      switch result {
      case .failure(let f):
        FileOutGlue.reply(completion, .failure(FileOutGlue.error(f)))
      case .success(let ids):
        let saved = ids.compactMap { $0 }
        FileOutGlue.reply(completion, .success(SaveOutResultMsg(
          cancelled: false,
          savedUris: saved,
          failedCount: Int64(skipped + savable.count - saved.count)
        )))
      }
    }
  }
}

// MARK: - System presenter

final class SystemExportPresenter: NSObject, ExportPresenter {
  private let context: LibraryPluginContext
  private var pending: ((Result<ExportPick, OutFailure>) -> Void)?

  init(context: LibraryPluginContext) {
    self.context = context
  }

  func presentExport(files: [OutFile], batch: TempBatch, anchor: CGRect?, completion: @escaping (Result<ExportPick, OutFailure>) -> Void) {
    #if os(iOS)
    guard let host = context.presentingViewController() else { return completion(.failure(.io("no window to present from"))) }
    let picker = UIDocumentPickerViewController(forExporting: batch.urls, asCopy: true)
    picker.delegate = self
    picker.modalPresentationStyle = .formSheet
    if let pop = picker.popoverPresentationController {
      pop.sourceView = host.view
      pop.sourceRect = FileOutGlue.anchor(anchor, in: host.view.bounds)
    }
    pending = completion
    host.present(picker, animated: true)
    #elseif os(macOS)
    let window = context.presentingWindow()
    if files.count == 1 {
      let panel = NSSavePanel()
      panel.nameFieldStringValue = FileOutCore.safeName(files[0].displayName)
      panel.canCreateDirectories = true
      panel.isExtensionHidden = false
      let done: (NSApplication.ModalResponse) -> Void = { response in
        guard response == .OK, let url = panel.url else { return completion(.success(.cancelled)) }
        completion(.success(.directory(url.deletingLastPathComponent(), names: [url.lastPathComponent])))
      }
      if let w = window { panel.beginSheetModal(for: w, completionHandler: done) } else { done(panel.runModal()) }
    } else {
      let panel = NSOpenPanel()
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      panel.canCreateDirectories = true
      panel.allowsMultipleSelection = false
      panel.prompt = "Save Here"
      let done: (NSApplication.ModalResponse) -> Void = { response in
        guard response == .OK, let url = panel.url else { return completion(.success(.cancelled)) }
        completion(.success(.directory(url, names: nil)))
      }
      if let w = window { panel.beginSheetModal(for: w, completionHandler: done) } else { done(panel.runModal()) }
    }
    #endif
  }
}

#if os(iOS)
extension SystemExportPresenter: UIDocumentPickerDelegate {
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    let done = pending
    pending = nil
    done?(.success(.exported(urls)))
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let done = pending
    pending = nil
    done?(.success(.cancelled))
  }
}
#endif

// MARK: - Photos (add-only)

final class SystemPhotoSaver: PhotoSaver {
  func save(_ items: [(file: OutFile, kind: OutMediaKind)], completion: @escaping (Result<[String?], OutFailure>) -> Void) {
    let proceed: (PHAuthorizationStatus) -> Void = { status in
      var allowed = status == .authorized
      if #available(iOS 14.0, macOS 11.0, *) { allowed = allowed || status == .limited }
      guard allowed else {
        return completion(.failure(.denied("adding to Photos was not allowed")))
      }
      var placeholders: [PHObjectPlaceholder?] = []
      PHPhotoLibrary.shared().performChanges({
        placeholders = items.map { item -> PHObjectPlaceholder? in
          let request = PHAssetCreationRequest.forAsset()
          let options = PHAssetResourceCreationOptions()
          options.shouldMoveFile = false
          options.originalFilename = FileOutCore.safeName(item.file.displayName)
          request.addResource(with: item.kind == .video ? .video : .photo, fileURL: URL(fileURLWithPath: item.file.path), options: options)
          return request.placeholderForCreatedAsset
        }
      }, completionHandler: { ok, _ in
        if ok {
          completion(.success(placeholders.map { $0?.localIdentifier }))
        } else {
          completion(.failure(.io("the photo library refused the items")))
        }
      })
    }
    if #available(iOS 14.0, macOS 11.0, *) {
      let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
      if current == .notDetermined {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { proceed($0) }
      } else {
        proceed(current)
      }
    } else {
      PHPhotoLibrary.requestAuthorization { proceed($0) }
    }
  }
}
