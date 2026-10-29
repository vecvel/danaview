// OWNER: HOM-24
// EXTENDED: HOM-29 (a viewer can be in annotate mode: [PdfViewController.annotate] holds the
// session of Annotate/PdfAnnotateView.swift, which previews annotations on the in-memory document
// and is ended, previews removed, when the viewer goes.)
//
// The PDFKit viewer as a Flutter platform view (ARCH v1.2 §8 "PDF viewer", V2-120): a `PDFView` in a
// `UiKitView` (iOS) or `AppKitView` (macOS), view type `com.vecvel.danaview.pdf/view`, creation
// params `{handle, page, displayMode}` in the standard codec. Zoom (pinch, scroll, auto-scale),
// text selection and copy are PDFKit's own; page, zoom and selection changes go to Dart as events.
// The view keeps its PDFDocument alive after the handle is closed, and never writes it (rule 27).
// Dark UI: the view background is DanaviewColors.background (0xFF07080C) behind the white pages.

import Foundation
import PDFKit

#if os(iOS)
import Flutter
import UIKit
typealias PdfNativeView = UIView
typealias PdfNativeColor = UIColor
#elseif os(macOS)
import AppKit
import FlutterMacOS
typealias PdfNativeView = NSView
typealias PdfNativeColor = NSColor
#endif

/// The live viewers by view id (main thread). Holds them weakly: Flutter owns their lifetime.
final class PdfViewRegistry {
  private let table = NSMapTable<NSNumber, PdfViewController>.strongToWeakObjects()

  func add(_ controller: PdfViewController) {
    table.setObject(controller, forKey: NSNumber(value: controller.viewId))
  }

  func remove(_ viewId: Int64) {
    table.removeObject(forKey: NSNumber(value: viewId))
  }

  /// The viewer of [viewId] (`notFound` when it is gone).
  func controller(_ viewId: Int64) throws -> PdfViewController {
    guard let controller = table.object(forKey: NSNumber(value: viewId)) else {
      throw PdfFailure(.notFound, "no such view")
    }
    return controller
  }

  var count: Int { table.objectEnumerator()?.allObjects.count ?? 0 }
}

/// The container a platform view shows: a PDFView filling it.
final class PdfContainerView: PdfNativeView {
  #if os(macOS)
  /// On macOS Flutter owns the NSView, so the view owns its controller.
  var owner: PdfViewController?
  override var isFlipped: Bool { true }
  #endif
}

/// One PDFKit viewer.
final class PdfViewController: NSObject {
  let viewId: Int64
  let pdfView: PDFView
  let handle: Int64
  private weak var registry: PdfViewRegistry?
  private weak var events: PdfEventHub?
  private var observers: [NSObjectProtocol] = []
  private(set) var displayMode: PdfDisplayModeMsg = .continuous

  /// The annotate mode (HOM-29), or nil while plain viewing.
  var annotate: PdfAnnotateSession?

  #if os(iOS)
  private let container: PdfContainerView
  #else
  private weak var container: PdfContainerView?
  #endif

  /// A viewer of [document] starting at [page].
  init(viewId: Int64, handle: Int64, document: PDFDocument, page: Int, mode: PdfDisplayModeMsg,
       registry: PdfViewRegistry?, events: PdfEventHub?) {
    self.viewId = viewId
    self.handle = handle
    self.registry = registry
    self.events = events
    let container = PdfContainerView(frame: .zero)
    pdfView = PDFView(frame: .zero)
    self.container = container
    super.init()
    let background = PdfNativeColor(red: 0x07 / 255.0, green: 0x08 / 255.0, blue: 0x0C / 255.0, alpha: 1)
    #if os(iOS)
    pdfView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    container.backgroundColor = background
    pdfView.backgroundColor = background
    pdfView.pageShadowsEnabled = false
    #else
    pdfView.autoresizingMask = [.width, .height]
    pdfView.backgroundColor = background
    container.wantsLayer = true
    container.layer?.backgroundColor = background.cgColor
    container.owner = self
    #endif
    pdfView.frame = container.bounds
    container.addSubview(pdfView)
    pdfView.autoScales = true
    pdfView.displaysPageBreaks = true
    pdfView.document = document
    apply(mode)
    if page > 0, page < document.pageCount, let target = document.page(at: page) {
      pdfView.go(to: target)
    }
    let center = NotificationCenter.default
    for (name, kind) in [
      (Notification.Name.PDFViewPageChanged, PdfEventKindMsg.viewPageChanged),
      (.PDFViewScaleChanged, .viewScaleChanged),
      (.PDFViewSelectionChanged, .viewSelectionChanged),
    ] {
      observers.append(center.addObserver(forName: name, object: pdfView, queue: .main) { [weak self] _ in
        self?.emit(kind)
      })
    }
    registry?.add(self)
  }

  deinit {
    annotate?.end()
    observers.forEach(NotificationCenter.default.removeObserver)
    registry?.remove(viewId)
  }

  /// The view Flutter embeds.
  var nativeView: PdfContainerView? { container }

  var document: PDFDocument? { pdfView.document }

  private func emit(_ kind: PdfEventKindMsg) {
    events?.emit(PdfEventMsg(kind: kind, viewState: state()))
  }

  func state() -> PdfViewStateMsg {
    let doc = pdfView.document
    var index = 0
    if let doc, let page = pdfView.currentPage {
      let i = doc.index(for: page)
      if i != NSNotFound { index = i }
    }
    let selected = pdfView.currentSelection.map { !($0.string ?? "").isEmpty } ?? false
    return PdfViewStateMsg(
      viewId: viewId, pageIndex: Int64(index), pageCount: Int64(doc?.pageCount ?? 0),
      scale: Double(pdfView.scaleFactor), minScale: Double(pdfView.minScaleFactor), maxScale: Double(pdfView.maxScaleFactor),
      hasSelection: selected, displayMode: displayMode)
  }

  func goToPage(_ index: Int) throws {
    guard let doc = pdfView.document, index >= 0, index < doc.pageCount, let page = doc.page(at: index) else {
      throw PdfFailure(.invalidArgument, "page out of range")
    }
    pdfView.go(to: page)
  }

  func setScale(_ scale: Double) throws {
    guard scale.isFinite, scale > 0 else { throw PdfFailure(.invalidArgument, "bad scale") }
    pdfView.autoScales = false
    let clamped = min(max(CGFloat(scale), pdfView.minScaleFactor), pdfView.maxScaleFactor)
    pdfView.scaleFactor = clamped
  }

  func zoomToFit() {
    pdfView.autoScales = true
    pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit
  }

  func apply(_ mode: PdfDisplayModeMsg) {
    displayMode = mode
    switch mode {
    case .continuous: pdfView.displayMode = .singlePageContinuous
    case .singlePage: pdfView.displayMode = .singlePage
    case .twoUpContinuous: pdfView.displayMode = .twoUpContinuous
    }
    pdfView.displayDirection = .vertical
  }

  /// Scrolls to [range] on page [pageIndex] and highlights it.
  func showHit(pageIndex: Int, range: NSRange) throws {
    guard let doc = pdfView.document, pageIndex >= 0, pageIndex < doc.pageCount, let page = doc.page(at: pageIndex),
          let selection = page.selection(for: range)
    else { throw PdfFailure(.invalidArgument, "hit out of range") }
    #if os(iOS)
    selection.color = UIColor(red: 1, green: 0.84, blue: 0.2, alpha: 0.55)
    #else
    selection.color = NSColor(red: 1, green: 0.84, blue: 0.2, alpha: 0.55)
    #endif
    pdfView.highlightedSelections = [selection]
    pdfView.go(to: selection)
  }

  func clearSearch() {
    pdfView.highlightedSelections = nil
  }

  func selectedText() -> String? {
    guard let text = pdfView.currentSelection?.string, !text.isEmpty else { return nil }
    return text
  }

  /// Copies the selection; false without one or when the file forbids copying.
  func copySelection() -> Bool {
    guard let text = selectedText(), pdfView.document?.allowsCopying ?? false else { return false }
    #if os(iOS)
    UIPasteboard.general.string = text
    #else
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
    return true
  }

  func clearSelection() {
    pdfView.clearSelection()
  }
}

#if os(iOS)
extension PdfViewController: FlutterPlatformView {
  func view() -> UIView { container }
}
#endif

/// Creates viewers for `com.vecvel.danaview.pdf/view`.
final class PdfViewFactory: NSObject, FlutterPlatformViewFactory {
  static let viewType = "com.vecvel.danaview.pdf/view"

  private let store: PdfDocumentStore
  private let registry: PdfViewRegistry
  private weak var events: PdfEventHub?

  init(store: PdfDocumentStore, registry: PdfViewRegistry, events: PdfEventHub?) {
    self.store = store
    self.registry = registry
    self.events = events
    super.init()
  }

  #if os(iOS)
  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }
  #else
  func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? {
    FlutterStandardMessageCodec.sharedInstance()
  }
  #endif

  /// A viewer for creation params [args]; an unknown handle shows an empty view (Dart closed the
  /// document first) and never crashes (ARCH §11).
  func makeController(viewId: Int64, args: Any?) -> PdfViewController {
    let params = args as? [String: Any] ?? [:]
    let handle = (params["handle"] as? NSNumber)?.int64Value ?? -1
    let page = (params["page"] as? NSNumber)?.intValue ?? 0
    let mode = PdfViewFactory.mode(params["displayMode"] as? String)
    let document = (try? store.document(handle)) ?? PDFDocument()
    return PdfViewController(viewId: viewId, handle: handle, document: document, page: page, mode: mode,
                             registry: registry, events: events)
  }

  static func mode(_ name: String?) -> PdfDisplayModeMsg {
    switch name {
    case "singlePage": return .singlePage
    case "twoUpContinuous": return .twoUpContinuous
    default: return .continuous
    }
  }

  #if os(iOS)
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    let controller = makeController(viewId: viewId, args: args)
    controller.nativeView?.frame = frame
    return controller
  }
  #else
  func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
    makeController(viewId: viewId, args: args).nativeView ?? NSView()
  }
  #endif
}
