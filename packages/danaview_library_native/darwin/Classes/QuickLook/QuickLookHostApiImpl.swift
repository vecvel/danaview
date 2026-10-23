// OWNER: HOM-26
//
// QuickLookHostApi on Apple (ARCH v1.2 §3 "Office / other files", "Text / CSV", V2-120, G-R3; HOM
// plan §8.4; BUILD_PLAN HOM-26): Quick Look previews of Office, iWork, text, CSV, PDF and other
// types the system can show, with editing disabled.
//
// * canPreview: the file is readable and its type is one Quick Look previews (QuickLookCore.swift
//   QuickLookPolicy), and on iOS `QLPreviewController.canPreview` agrees. False sends the viewer
//   router on to the file card.
// * present: the items are copied into a temporary read-only batch (ExportOut/FileOutCore.swift
//   TempCopyStore), so Quick Look never sees a library file; the preview shows those copies with
//   editing off: iOS `QLPreviewController` (`editingModeFor` → `.disabled`; edited copies it might
//   report are ignored and deleted with the batch), macOS a sheet with a `QLPreviewView` (no
//   Markup there) and a Done button. The reply arrives when the preview is dismissed; the batch is
//   removed then. One preview at a time (`busy` otherwise).
//
// The presenter is a protocol so the XCTests drive the flow without system UI. Replies arrive on the
// main thread. Nothing is logged (rule 30).

import Foundation

#if os(iOS)
import Flutter
import QuickLook
import UIKit
#elseif os(macOS)
import Cocoa
import FlutterMacOS
import Quartz
#endif

/// Shows Quick Look previews.
protocol QuickLookPresenter: AnyObject {
  /// The system's own answer for [url] (iOS asks `QLPreviewController`; macOS trusts the policy).
  func systemCanPreview(_ url: URL) -> Bool

  /// Shows [urls] (read-only copies) titled [titles], starting at [initialIndex]. [shown] runs once
  /// with whether the preview appeared; [dismissed] runs once when it closes.
  func present(urls: [URL], titles: [String], initialIndex: Int, shown: @escaping (Result<Void, OutFailure>) -> Void, dismissed: @escaping () -> Void)
}

final class QuickLookHostApiImpl: QuickLookHostApi {
  private let presenter: QuickLookPresenter
  let temp: TempCopyStore
  private var busy = false

  convenience init(context: LibraryPluginContext) {
    self.init(presenter: SystemQuickLookPresenter(context: context), temp: TempCopyStore())
  }

  init(presenter: QuickLookPresenter, temp: TempCopyStore) {
    self.presenter = presenter
    self.temp = temp
  }

  func canPreview(item: FileItemMsg, completion: @escaping (Result<Bool, Error>) -> Void) {
    if let problem = QuickLookPolicy.fileProblem(item.path) {
      // A missing or unreadable file is a typed error; the Dart probe treats it as "can't".
      return FileOutGlue.reply(completion, .failure(FileOutGlue.error(problem)))
    }
    let ok = QuickLookPolicy.canPreview(path: item.path, displayName: item.displayName, uti: item.uti)
      && presenter.systemCanPreview(URL(fileURLWithPath: item.path))
    FileOutGlue.reply(completion, .success(ok))
  }

  func present(request: QuickLookRequestMsg, completion: @escaping (Result<Void, Error>) -> Void) {
    guard !busy else { return FileOutGlue.reply(completion, .failure(FileOutGlue.error(OutFailure.busy("a preview is open")))) }
    guard !request.items.isEmpty else { return FileOutGlue.reply(completion, .failure(FileOutGlue.error(OutFailure.invalid("no items")))) }
    guard request.initialIndex >= 0, request.initialIndex < Int64(request.items.count) else {
      return FileOutGlue.reply(completion, .failure(FileOutGlue.error(OutFailure.invalid("initial index out of range"))))
    }
    let files = request.items.map(FileOutGlue.outFile)
    let batch: TempBatch
    do {
      batch = try temp.makeBatch(files)
    } catch {
      return FileOutGlue.reply(completion, .failure(FileOutGlue.error(error)))
    }
    busy = true
    var replied = false
    var removed = false
    let finish: (Result<Void, Error>) -> Void = { [weak self] result in
      if !removed {
        removed = true
        self?.temp.remove(batch)
      }
      self?.busy = false
      guard !replied else { return }
      replied = true
      FileOutGlue.reply(completion, result)
    }
    presenter.present(
      urls: batch.urls,
      titles: files.map { $0.displayName },
      initialIndex: Int(request.initialIndex),
      shown: { result in
        if case .failure(let f) = result {
          DispatchQueue.main.async { finish(.failure(FileOutGlue.error(f))) }
        }
      },
      dismissed: {
        DispatchQueue.main.async { finish(.success(())) }
      }
    )
  }
}

// MARK: - System presenter

#if os(iOS)
/// One previewed copy with the name the user knows.
final class QuickLookItem: NSObject, QLPreviewItem {
  let previewItemURL: URL?
  let previewItemTitle: String?

  init(url: URL, title: String) {
    previewItemURL = url
    previewItemTitle = title
  }
}
#endif

final class SystemQuickLookPresenter: NSObject, QuickLookPresenter {
  private let context: LibraryPluginContext
  #if os(iOS)
  private var items: [QuickLookItem] = []
  private var dismissed: (() -> Void)?
  #elseif os(macOS)
  private var sheet: NSWindow?
  private var previewView: QLPreviewView?
  private var urls: [URL] = []
  private var titles: [String] = []
  private var index = 0
  private var stepper: NSSegmentedControl?
  private var dismissed: (() -> Void)?
  #endif

  init(context: LibraryPluginContext) {
    self.context = context
  }

  func systemCanPreview(_ url: URL) -> Bool {
    #if os(iOS)
    return QLPreviewController.canPreview(url as NSURL)
    #else
    return true
    #endif
  }

  func present(urls: [URL], titles: [String], initialIndex: Int, shown: @escaping (Result<Void, OutFailure>) -> Void, dismissed: @escaping () -> Void) {
    #if os(iOS)
    guard let host = context.presentingViewController() else { return shown(.failure(.io("no window to present from"))) }
    items = zip(urls, titles).map { QuickLookItem(url: $0, title: $1) }
    self.dismissed = dismissed
    let controller = QLPreviewController()
    controller.dataSource = self
    controller.delegate = self
    controller.currentPreviewItemIndex = initialIndex
    host.present(controller, animated: true) { shown(.success(())) }
    #elseif os(macOS)
    guard let parent = context.presentingWindow() else { return shown(.failure(.io("no window to present from"))) }
    self.urls = urls
    self.titles = titles
    self.index = initialIndex
    self.dismissed = dismissed
    let frame = parent.contentLayoutRect.insetBy(dx: 24, dy: 24)
    let size = NSSize(width: max(480, frame.width), height: max(360, frame.height))
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
    let content = NSView(frame: NSRect(origin: .zero, size: size))
    guard let preview = QLPreviewView(frame: .zero, style: .normal) else { return shown(.failure(.unsupported("Quick Look unavailable"))) }
    preview.autostarts = true
    preview.translatesAutoresizingMaskIntoConstraints = false
    let done = NSButton(title: "Done", target: self, action: #selector(close))
    done.keyEquivalent = "\u{1b}"  // Escape closes the preview.
    done.bezelStyle = .rounded
    done.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(preview)
    content.addSubview(done)
    var constraints = [
      preview.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      preview.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      preview.topAnchor.constraint(equalTo: content.topAnchor),
      preview.bottomAnchor.constraint(equalTo: done.topAnchor, constant: -12),
      done.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
      done.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
    ]
    if urls.count > 1 {
      let stepper = NSSegmentedControl(labels: ["‹", "›"], trackingMode: .momentary, target: self, action: #selector(step(_:)))
      stepper.setAccessibilityLabel("Previous or next file")
      stepper.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(stepper)
      constraints += [
        stepper.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
        stepper.centerYAnchor.constraint(equalTo: done.centerYAnchor),
      ]
      self.stepper = stepper
    }
    NSLayoutConstraint.activate(constraints)
    window.contentView = content
    sheet = window
    previewView = preview
    show(index)
    parent.beginSheet(window) { [weak self] _ in self?.finish() }
    shown(.success(()))
    #endif
  }

  #if os(macOS)
  private func show(_ i: Int) {
    guard i >= 0, i < urls.count else { return }
    index = i
    previewView?.previewItem = urls[i] as NSURL
    sheet?.title = titles[i]
    stepper?.setEnabled(i > 0, forSegment: 0)
    stepper?.setEnabled(i < urls.count - 1, forSegment: 1)
  }

  @objc private func step(_ sender: NSSegmentedControl) {
    show(sender.selectedSegment == 0 ? index - 1 : index + 1)
  }

  @objc private func close() {
    guard let window = sheet else { return }
    window.sheetParent?.endSheet(window)
  }

  private func finish() {
    previewView?.close()
    previewView = nil
    sheet = nil
    stepper = nil
    urls = []
    titles = []
    let done = dismissed
    dismissed = nil
    done?()
  }
  #endif
}

#if os(iOS)
extension SystemQuickLookPresenter: QLPreviewControllerDataSource, QLPreviewControllerDelegate {
  func numberOfPreviewItems(in controller: QLPreviewController) -> Int { items.count }

  func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { items[index] }

  /// Markup never edits a stored file (V2-120, G-R3).
  @available(iOS 13.0, *)
  func previewController(_ controller: QLPreviewController, editingModeFor previewItem: QLPreviewItem) -> QLPreviewItemEditingMode {
    QuickLookPolicy.editingAllowed ? .createCopy : .disabled
  }

  /// Edited copies are never kept (editing is off; this is the belt to that brace).
  @available(iOS 13.0, *)
  func previewController(_ controller: QLPreviewController, didSaveEditedCopyOf previewItem: QLPreviewItem, at modifiedContentsURL: URL) {
    try? FileManager.default.removeItem(at: modifiedContentsURL)
  }

  func previewControllerDidDismiss(_ controller: QLPreviewController) {
    items = []
    let done = dismissed
    dismissed = nil
    done?()
  }
}
#endif
