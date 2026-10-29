// OWNER: HOM-29
// EXTENDED: HOM-30 (the `place` input's stamp drags go back through `PdfAnnotateEventsApi.itemMoved`.)
//
// The HOM-29 amendment's `PdfAnnotateHostApi` on Apple: annotate mode of a viewer (main thread,
// Annotate/PdfAnnotateView.swift), and the annotate save as a tool job on the shared registry
// (`PdfToolsHostApi.cancel` stops it; progress events carry `tool: annotate`). Strokes and taps go
// back to Dart through `PdfAnnotateEventsApi`.

import CoreGraphics
import Foundation

#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

final class PdfAnnotateHostApiImpl: PdfAnnotateHostApi {
  let registry: PdfViewRegistry
  let tools: PdfToolsHostApiImpl
  /// Native → Dart events; nil in tests (the session callbacks are then not wired).
  let events: PdfAnnotateEventsApiProtocol?

  init(registry: PdfViewRegistry, tools: PdfToolsHostApiImpl, events: PdfAnnotateEventsApiProtocol?) {
    self.registry = registry
    self.tools = tools
    self.events = events
  }

  private func view(_ viewId: Int64) throws -> PdfViewController {
    do {
      return try registry.controller(viewId)
    } catch {
      throw PdfErrors.from(error)
    }
  }

  func setAnnotateMode(viewId: Int64, mode: PdfAnnotateModeMsg?) throws {
    let controller = try view(viewId)
    guard let mode else {
      controller.annotate?.end()
      controller.annotate = nil
      return
    }
    guard mode.inkWidth.isFinite, mode.inkWidth > 0 else { throw PdfErrors.error(.invalidArgument, "bad ink width") }
    let session = controller.annotate ?? makeSession(controller)
    controller.annotate = session
    session.apply(
      input: PdfAnnotateInput(rawValue: mode.input.rawValue) ?? .select,
      color: UInt32(truncatingIfNeeded: mode.inkColorArgb), width: CGFloat(mode.inkWidth))
  }

  private func makeSession(_ controller: PdfViewController) -> PdfAnnotateSession {
    let session = PdfAnnotateSession(pdfView: controller.pdfView)
    let viewId = controller.viewId
    if let events {
      session.onInk = { page, points in
        let flat = points.flatMap { [Double($0.x), Double($0.y)] }
        Task { @MainActor in try? await events.inkStroke(viewId: viewId, pageIndex: Int64(page), points: flat) }
      }
      session.onTap = { page, point, item in
        Task { @MainActor in try? await events.tapped(viewId: viewId, pageIndex: Int64(page), x: Double(point.x), y: Double(point.y), itemId: item) }
      }
      session.onMoved = { item, page, rect in
        let msg = PdfRectMsg(x: Double(rect.minX), y: Double(rect.minY), width: Double(rect.width), height: Double(rect.height))
        Task { @MainActor in try? await events.itemMoved(viewId: viewId, itemId: item, pageIndex: Int64(page), rect: msg) }
      }
    }
    return session
  }

  func showAnnotations(viewId: Int64, items: [PdfAnnotateItemMsg], selectedId: String?) throws {
    guard let session = try view(viewId).annotate else { throw PdfErrors.error(.invalidArgument, "not in annotate mode") }
    session.show(items, selectedId: selectedId)
  }

  func selectionLines(viewId: Int64) throws -> [PdfPageRectsMsg] {
    let controller = try view(viewId)
    let session = controller.annotate ?? PdfAnnotateSession(pdfView: controller.pdfView)
    return session.selectionLines().map { line in
      PdfPageRectsMsg(
        pageIndex: Int64(line.pageIndex),
        rects: line.rects.map { PdfRectMsg(x: Double($0.minX), y: Double($0.minY), width: Double($0.width), height: Double($0.height)) })
    }
  }

  func save(request: PdfAnnotateSaveRequestMsg, completion: @escaping (Result<PdfToolResultMsg, Error>) -> Void) {
    tools.run(request.jobId, .annotate, completion) { tools.annotator.save(request, job: $0, completion: $1) }
  }
}
