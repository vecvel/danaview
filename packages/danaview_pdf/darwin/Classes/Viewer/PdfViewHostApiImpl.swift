// OWNER: HOM-24
//
// PdfViewHostApi on Apple: routes view calls to the PDFKit viewers (main thread), runs search on a
// background queue against an independent read-only open of the view's file (a newer search or
// cancelSearch cancels the older one between pages), and renders page thumbnails off the main
// thread. The texture view calls are Android's (HOM-25) and answer notSupportedOnDevice here.

import Foundation
import PDFKit

#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

/// A cancel flag shared between the main thread and a search.
final class PdfCancelToken {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
}

final class PdfViewHostApiImpl: PdfViewHostApi {
  let store: PdfDocumentStore
  let registry: PdfViewRegistry
  private var searches: [Int64: PdfCancelToken] = [:]
  private let searchQueue = DispatchQueue(label: "com.vecvel.danaview.pdf.search", qos: .userInitiated)
  private let renderQueue = DispatchQueue(label: "com.vecvel.danaview.pdf.render", qos: .userInitiated)

  init(store: PdfDocumentStore, registry: PdfViewRegistry) {
    self.store = store
    self.registry = registry
  }

  private func view(_ viewId: Int64) throws -> PdfViewController {
    do {
      return try registry.controller(viewId)
    } catch {
      throw PdfErrors.from(error)
    }
  }

  private func guarded<T>(_ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch {
      throw PdfErrors.from(error)
    }
  }

  func state(viewId: Int64) throws -> PdfViewStateMsg {
    try view(viewId).state()
  }

  func goToPage(viewId: Int64, pageIndex: Int64) throws {
    try guarded { try view(viewId).goToPage(Int(pageIndex)) }
  }

  func setScale(viewId: Int64, scale: Double) throws {
    try guarded { try view(viewId).setScale(scale) }
  }

  func zoomToFit(viewId: Int64) throws {
    try view(viewId).zoomToFit()
  }

  func setDisplayMode(viewId: Int64, mode: PdfDisplayModeMsg) throws {
    try view(viewId).apply(mode)
  }

  func search(viewId: Int64, options: PdfSearchOptionsMsg, completion: @escaping (Result<PdfSearchResultMsg, Error>) -> Void) {
    let controller: PdfViewController
    do {
      controller = try view(viewId)
    } catch {
      completion(.failure(error))
      return
    }
    searches[viewId]?.cancel()
    let token = PdfCancelToken()
    searches[viewId] = token
    let handle = controller.handle
    let fallback = controller.document?.documentURL
    let store = self.store
    searchQueue.async {
      do {
        // An independent open: PDFView draws its own document on the main thread.
        let document: PDFDocument
        if let twin = try? store.twin(handle) {
          document = twin
        } else if let url = fallback, let reopened = PDFDocument(url: url), !reopened.isLocked {
          document = reopened
        } else {
          throw PdfFailure(.notFound, "no document to search")
        }
        let outcome = try PdfSearcher.search(
          document, query: options.query, caseSensitive: options.caseSensitive, maxHits: Int(options.maxHits),
          isCancelled: { token.isCancelled })
        let hits = outcome.matches.enumerated().map { i, m in
          PdfSearchHitMsg(
            index: Int64(i), pageIndex: Int64(m.pageIndex), rangeStart: Int64(m.rangeStart), rangeLength: Int64(m.rangeLength),
            snippet: m.snippet, snippetMatchStart: Int64(m.snippetMatchStart), snippetMatchLength: Int64(m.snippetMatchLength),
            bounds: PdfRectMsg(x: Double(m.bounds.minX), y: Double(m.bounds.minY), width: Double(m.bounds.width), height: Double(m.bounds.height)))
        }
        completion(.success(PdfSearchResultMsg(hits: hits, truncated: outcome.truncated)))
      } catch {
        completion(.failure(PdfErrors.from(error)))
      }
    }
  }

  func cancelSearch(viewId: Int64) throws {
    searches[viewId]?.cancel()
    searches[viewId] = nil
  }

  func showSearchHit(viewId: Int64, hit: PdfSearchHitMsg) throws {
    try guarded {
      try view(viewId).showHit(pageIndex: Int(hit.pageIndex), range: NSRange(location: Int(hit.rangeStart), length: Int(hit.rangeLength)))
    }
  }

  func clearSearch(viewId: Int64) throws {
    try view(viewId).clearSearch()
  }

  func selectedText(viewId: Int64) throws -> String? {
    try view(viewId).selectedText()
  }

  func copySelection(viewId: Int64) throws -> Bool {
    try view(viewId).copySelection()
  }

  func clearSelection(viewId: Int64) throws {
    try view(viewId).clearSelection()
  }

  func pageThumbnail(request: PdfThumbnailRequestMsg, completion: @escaping (Result<PdfImageMsg, Error>) -> Void) {
    let store = self.store
    renderQueue.async {
      do {
        let image = try PdfReader.render(
          try store.document(request.handle), page: Int(request.pageIndex),
          maxWidth: Int(request.maxWidthPx), maxHeight: Int(request.maxHeightPx))
        completion(.success(PdfImageMsg(png: FlutterStandardTypedData(bytes: image.png), widthPx: Int64(image.width), heightPx: Int64(image.height))))
      } catch {
        completion(.failure(PdfErrors.from(error)))
      }
    }
  }

  func createTextureView(request: PdfTextureViewRequestMsg, completion: @escaping (Result<PdfTextureViewMsg, Error>) -> Void) {
    completion(.failure(PdfErrors.notSupported("HOM-25")))
  }

  func setTextureViewport(viewId: Int64, viewport: PdfViewportMsg) throws {
    throw PdfErrors.notSupported("HOM-25")
  }

  func disposeTextureView(viewId: Int64) throws {
    throw PdfErrors.notSupported("HOM-25")
  }
}
