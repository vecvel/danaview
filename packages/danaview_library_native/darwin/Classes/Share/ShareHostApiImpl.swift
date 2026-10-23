// OWNER: HOM-22
//
// ShareHostApi on Apple (ARCH v1.2 §8 "Getting files out", V2-117, V2-118; HOM plan §8.3): the
// system share sheet over temporary read-only copies (ExportOut/FileOutCore.swift TempCopyStore),
// so nothing outside Danaview can change the library copy:
//
// * iOS: `UIActivityViewController`, anchored as a popover on iPad; the copies are removed when
//   the sheet's completion handler runs (the chosen activity has finished with them).
// * macOS: `NSSharingServicePicker` (the request's subject goes to services that use one, e.g. Mail); the reply comes when the user picks a service (or closes the
//   picker), the copies go when the service reports it shared or failed (a crash leaves them to the
//   next start's sweep).
//
// One share sheet at a time (`busy` otherwise). The presenter is a protocol so the XCTests drive
// the flow without system UI. Replies arrive on the main thread. Nothing is logged.

import Foundation

#if os(iOS)
import Flutter
import UIKit
#elseif os(macOS)
import Cocoa
import FlutterMacOS
#endif

/// What the share sheet did.
struct ShareOutcome: Equatable {
  var completed: Bool
  var activityType: String?
}

/// Shows the system share sheet.
protocol SharePresenter: AnyObject {
  /// Presents the sheet for [urls]. [chosen] runs once, when the user finished or closed the sheet;
  /// [released] runs once, when the system no longer reads the files (it may run with [chosen]).
  func presentShare(
    urls: [URL],
    subject: String?,
    anchor: CGRect?,
    chosen: @escaping (Result<ShareOutcome, OutFailure>) -> Void,
    released: @escaping () -> Void
  )
}

final class ShareHostApiImpl: ShareHostApi {
  private let presenter: SharePresenter
  let temp: TempCopyStore
  private var busy = false

  convenience init(context: LibraryPluginContext) {
    self.init(presenter: SystemSharePresenter(context: context), temp: TempCopyStore())
  }

  init(presenter: SharePresenter, temp: TempCopyStore) {
    self.presenter = presenter
    self.temp = temp
  }

  func share(request: ShareRequestMsg, completion: @escaping (Result<ShareResultMsg, Error>) -> Void) {
    guard !busy else { return FileOutGlue.reply(completion, .failure(FileOutGlue.error(OutFailure.busy("a share sheet is open")))) }
    let batch: TempBatch
    do {
      batch = try temp.makeBatch(request.items.map(FileOutGlue.outFile))
    } catch {
      return FileOutGlue.reply(completion, .failure(FileOutGlue.error(error)))
    }
    busy = true
    var replied = false
    var removed = false
    let release = { [weak self] in
      guard let self = self, !removed else { return }
      removed = true
      self.temp.remove(batch)
    }
    presenter.presentShare(
      urls: batch.urls,
      subject: request.subject,
      anchor: FileOutGlue.rect(request.anchor),
      chosen: { [weak self] result in
        guard !replied else { return }
        replied = true
        self?.busy = false
        switch result {
        case .success(let o):
          FileOutGlue.reply(completion, .success(ShareResultMsg(completed: o.completed, activityType: o.activityType)))
        case .failure(let f):
          release()
          FileOutGlue.reply(completion, .failure(FileOutGlue.error(f)))
        }
      },
      released: { DispatchQueue.main.async(execute: release) }
    )
  }
}

// MARK: - System presenter

final class SystemSharePresenter: NSObject, SharePresenter {
  private let context: LibraryPluginContext
  #if os(macOS)
  private var picker: NSSharingServicePicker?
  private var chosen: ((Result<ShareOutcome, OutFailure>) -> Void)?
  private var released: (() -> Void)?
  private var service: NSSharingService?
  private var subject: String?
  #endif

  init(context: LibraryPluginContext) {
    self.context = context
  }

  func presentShare(
    urls: [URL],
    subject: String?,
    anchor: CGRect?,
    chosen: @escaping (Result<ShareOutcome, OutFailure>) -> Void,
    released: @escaping () -> Void
  ) {
    #if os(iOS)
    guard let host = context.presentingViewController() else {
      chosen(.failure(.io("no window to present from")))
      return released()
    }
    let sheet = UIActivityViewController(activityItems: urls, applicationActivities: nil)
    if let pop = sheet.popoverPresentationController {
      pop.sourceView = host.view
      pop.sourceRect = FileOutGlue.anchor(anchor, in: host.view.bounds)
    }
    sheet.completionWithItemsHandler = { activity, completed, _, _ in
      chosen(.success(ShareOutcome(completed: completed, activityType: activity?.rawValue)))
      released()
    }
    host.present(sheet, animated: true)
    #elseif os(macOS)
    guard let view = context.presentingWindow()?.contentView else {
      chosen(.failure(.io("no window to present from")))
      return released()
    }
    let picker = NSSharingServicePicker(items: urls)
    picker.delegate = self
    self.picker = picker
    self.chosen = chosen
    self.released = released
    self.subject = subject
    // Flutter's view is flipped relative to AppKit: y grows downwards in the Flutter view.
    var rect = FileOutGlue.anchor(anchor, in: CGRect(origin: .zero, size: view.bounds.size))
    if !view.isFlipped { rect.origin.y = view.bounds.height - rect.origin.y - rect.height }
    picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
    #endif
  }
}

#if os(macOS)
extension SystemSharePresenter: NSSharingServicePickerDelegate, NSSharingServiceDelegate {
  func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
    let done = chosen
    chosen = nil
    picker = nil
    guard let service = service else {
      done?(.success(ShareOutcome(completed: false, activityType: nil)))
      finish()
      return
    }
    self.service = service
    service.delegate = self
    if let subject = subject { service.subject = subject }
    done?(.success(ShareOutcome(completed: true, activityType: service.title)))
  }

  func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
    finish()
  }

  func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
    finish()
  }

  private func finish() {
    let done = released
    released = nil
    service = nil
    done?()
  }
}
#endif
