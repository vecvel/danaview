// OWNER: HOM-22
//
// OpenInHostApi on Apple (ARCH v1.2 §3, §8 "Getting files out", V2-117; HOM plan §8.3, D-98h,
// D-98k): "Open in another app" over a temporary read-only copy (ExportOut/FileOutCore.swift
// TempCopyStore), so the other app can read the file but never change the library copy:
//
// * iOS: `UIDocumentInteractionController.presentOpenInMenu`; the reply says whether the menu was
//   shown (false when no app takes the file); the copy is removed when the menu closes without a
//   choice or the chosen app has received the file.
// * macOS: `NSWorkspace.open` with the default app; the reply says whether an app opened it. The
//   app keeps reading the copy after the reply, so it stays until the next start's sweep (a day).
//
// One menu at a time (`busy` otherwise). The presenter is a protocol so the XCTests drive the
// flow without system UI. Replies arrive on the main thread. Nothing is logged.

import Foundation

#if os(iOS)
import Flutter
import UIKit
#elseif os(macOS)
import Cocoa
import FlutterMacOS
#endif

/// Hands one file to another app.
protocol OpenInPresenter: AnyObject {
  /// True when [presentOpenIn] calls `released` (its menu stays on screen until then); false when
  /// the file leaves for another app at once and the release can't be known.
  var reportsRelease: Bool { get }

  /// Opens [url]. [shown] runs once with whether an app chooser or app was shown; [released] runs
  /// once when no other app reads the file any more (never, when that can't be known).
  func presentOpenIn(url: URL, uti: String?, anchor: CGRect?, shown: @escaping (Result<Bool, OutFailure>) -> Void, released: @escaping () -> Void)
}

final class OpenInHostApiImpl: OpenInHostApi {
  private let presenter: OpenInPresenter
  let temp: TempCopyStore
  private var busy = false

  convenience init(context: LibraryPluginContext) {
    self.init(presenter: SystemOpenInPresenter(context: context), temp: TempCopyStore())
  }

  init(presenter: OpenInPresenter, temp: TempCopyStore) {
    self.presenter = presenter
    self.temp = temp
  }

  func openIn(request: OpenInRequestMsg, completion: @escaping (Result<Bool, Error>) -> Void) {
    guard !busy else { return FileOutGlue.reply(completion, .failure(FileOutGlue.error(OutFailure.busy("an open-in menu is open")))) }
    let file = FileOutGlue.outFile(request.item)
    let batch: TempBatch
    do {
      batch = try temp.makeBatch([file])
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
    presenter.presentOpenIn(
      url: batch.urls[0],
      uti: file.uti,
      anchor: FileOutGlue.rect(request.anchor),
      shown: { [weak self] result in
        guard !replied else { return }
        replied = true
        switch result {
        case .success(let wasShown):
          if !wasShown {
            release()
            self?.busy = false
          } else if self?.presenter.reportsRelease == false {
            self?.busy = false
          }
          FileOutGlue.reply(completion, .success(wasShown))
        case .failure(let f):
          release()
          self?.busy = false
          FileOutGlue.reply(completion, .failure(FileOutGlue.error(f)))
        }
      },
      released: { [weak self] in
        DispatchQueue.main.async {
          release()
          self?.busy = false
        }
      }
    )
  }
}

// MARK: - System presenter

final class SystemOpenInPresenter: NSObject, OpenInPresenter {
  private let context: LibraryPluginContext
  #if os(iOS)
  private var controller: UIDocumentInteractionController?
  private var released: (() -> Void)?
  private var sending = false
  #endif

  init(context: LibraryPluginContext) {
    self.context = context
  }

  #if os(iOS)
  var reportsRelease: Bool { true }
  #else
  var reportsRelease: Bool { false }
  #endif

  func presentOpenIn(url: URL, uti: String?, anchor: CGRect?, shown: @escaping (Result<Bool, OutFailure>) -> Void, released: @escaping () -> Void) {
    #if os(iOS)
    guard let host = context.presentingViewController() else { return shown(.failure(.io("no window to present from"))) }
    let controller = UIDocumentInteractionController(url: url)
    if let uti = uti { controller.uti = uti }
    controller.delegate = self
    self.controller = controller
    self.released = released
    sending = false
    let rect = FileOutGlue.anchor(anchor, in: host.view.bounds)
    let ok = controller.presentOpenInMenu(from: rect, in: host.view, animated: true)
    if !ok {
      self.controller = nil
      self.released = nil
    }
    shown(.success(ok))
    #elseif os(macOS)
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    NSWorkspace.shared.open(url, configuration: config) { app, _ in
      DispatchQueue.main.async { shown(.success(app != nil)) }
    }
    #endif
  }
}

#if os(iOS)
extension SystemOpenInPresenter: UIDocumentInteractionControllerDelegate {
  func documentInteractionController(_ controller: UIDocumentInteractionController, willBeginSendingToApplication application: String?) {
    sending = true
  }

  func documentInteractionController(_ controller: UIDocumentInteractionController, didEndSendingToApplication application: String?) {
    finish()
  }

  func documentInteractionControllerDidDismissOpenInMenu(_ controller: UIDocumentInteractionController) {
    if !sending { finish() }
  }

  private func finish() {
    let done = released
    released = nil
    controller = nil
    sending = false
    done?()
  }
}
#endif
