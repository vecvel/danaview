// OWNER: HOM-29
//
// Annotate mode of the PDFKit viewer (HOM plan §8.5; the HOM-29 Pigeon amendment). The session's
// annotations live in Dart (undo / redo); this file shows them as a preview on the viewer's
// in-memory document (PDFKit annotations built by PdfAnnotateCore, read-only, removed again when
// the mode ends; the file is never written, rule 27) and turns input into events:
//
// - select: PDFKit's own scrolling, zoom and text selection; a tap reports the session item
//   under it (or none) so Dart can select or deselect it.
// - ink: iOS draws with PencilKit (`PKCanvasView` over the pages, its colours fixed to the light
//   appearance so ink isn't inverted in dark mode): Apple Pencil and a finger draw, two fingers
//   scroll and zoom; when the system prefers Pencil-only drawing a finger scrolls instead. macOS
//   draws with the mouse or trackpad on an overlay; scrolling and magnifying pass through. Each
//   finished stroke goes to Dart in page space and stays on screen until the next preview.
// - text and erase: a tap reports its page point and the item under it.
//
// Pre-existing annotations of the file are shown by PDFKit as they are and never touched. All
// work here is on the main thread. Nothing is logged (rule 30).

import Foundation
import PDFKit

#if os(iOS)
import PencilKit
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// What a touch does in annotate mode (`PdfAnnotateInputMsg`).
enum PdfAnnotateInput: Int {
  case select
  case ink
  case text
  case erase
}

/// One shown session item.
struct PdfAnnotateShownItem {
  let id: String
  let pageIndex: Int
  let kind: PdfAnnotationKind?
  /// Pigeon page space.
  let bounds: CGRect
  let rects: [CGRect]
  let strokes: [[CGPoint]]
  let lineWidth: CGFloat
  let annotations: [PDFAnnotation]
}

/// The annotate mode of one viewer.
final class PdfAnnotateSession: NSObject {
  let pdfView: PDFView
  private(set) var input: PdfAnnotateInput = .select
  private(set) var inkColor: UInt32 = 0xFFE5_3935
  private(set) var inkWidth: CGFloat = 2
  private(set) var shown: [PdfAnnotateShownItem] = []
  private var selectionMarker: (page: PDFPage, annotation: PDFAnnotation)?
  private var stampImages: [String: CGImage] = [:]

  /// A finished stroke: page index and points in Pigeon page space.
  var onInk: ((Int, [CGPoint]) -> Void)?

  /// A tap: page index, point in Pigeon page space, the item under it.
  var onTap: ((Int, CGPoint, String?) -> Void)?

  #if os(iOS)
  private var tap: UITapGestureRecognizer?
  private var canvas: PKCanvasView?
  private var committedStrokes = 0
  private var clearingCanvas = false
  private var scrollPan: UIPanGestureRecognizer?
  private var pinch: UIPinchGestureRecognizer?
  private var pinchStart: CGFloat = 1
  #else
  private var click: NSClickGestureRecognizer?
  private var mouseInk: PdfMouseInkView?
  #endif

  init(pdfView: PDFView) {
    self.pdfView = pdfView
    super.init()
  }

  /// Taps reach this far (view points) around thin items.
  static let tapReach: CGFloat = 12

  // -------------------------------------------------------------------------------------------
  // Mode

  func apply(input: PdfAnnotateInput, color: UInt32, width: CGFloat) {
    inkColor = color
    inkWidth = max(0.5, min(width, 100))
    if input != self.input || !installed {
      self.input = input
      uninstallInput()
      installInput()
    }
    updateInkTool()
  }

  private var installed = false

  /// Leaves annotate mode: the preview and every recognizer and overlay go.
  func end() {
    show([], selectedId: nil)
    uninstallInput()
  }

  // -------------------------------------------------------------------------------------------
  // Preview

  /// Replaces the preview with [items] (any that can't be built are skipped).
  func show(_ items: [PdfAnnotateItemMsg], selectedId: String?) {
    for item in shown {
      for annotation in item.annotations { annotation.page?.removeAnnotation(annotation) }
    }
    if let marker = selectionMarker { marker.page.removeAnnotation(marker.annotation) }
    selectionMarker = nil
    shown = []
    guard let document = pdfView.document else { return }
    for item in items {
      if let built = build(item, in: document) {
        shown.append(built)
      }
    }
    if let selectedId, let item = shown.first(where: { $0.id == selectedId }), let page = document.page(at: item.pageIndex) {
      let marker = PDFAnnotation(bounds: PdfAnnotateGeometry.toKit(item.bounds, page).insetBy(dx: -4, dy: -4), forType: .square, withProperties: nil)
      let border = PDFBorder()
      border.lineWidth = 1
      border.style = .dashed
      border.dashPattern = [4, 3]
      marker.border = border
      marker.color = PdfAnnotateColor(white: 0.55, alpha: 0.9)
      marker.isReadOnly = true
      page.addAnnotation(marker)
      selectionMarker = (page, marker)
    }
    clearLiveInk()
  }

  private func build(_ item: PdfAnnotateItemMsg, in document: PDFDocument) -> PdfAnnotateShownItem? {
    if let m = item.annotation, let spec = try? PdfAnnotator.spec(m),
       spec.pageIndex >= 0, spec.pageIndex < document.pageCount, let page = document.page(at: spec.pageIndex),
       let annotation = try? PdfAnnotateCore.makeAnnotation(spec, on: page) {
      annotation.isReadOnly = true
      page.addAnnotation(annotation)
      return PdfAnnotateShownItem(
        id: item.id, pageIndex: spec.pageIndex, kind: spec.kind, bounds: PdfAnnotateGeometry.fromKit(annotation.bounds, page),
        rects: spec.rects, strokes: spec.strokes, lineWidth: spec.lineWidth, annotations: [annotation])
    }
    if let m = item.stamp, let spec = try? PdfAnnotator.stamp(m),
       spec.pageIndex >= 0, spec.pageIndex < document.pageCount, let page = document.page(at: spec.pageIndex),
       spec.rect.width > 0, spec.rect.height > 0 {
      let image: CGImage
      if let cached = stampImages[spec.imagePath] {
        image = cached
      } else if let loaded = try? PdfAnnotateCore.loadImage(spec.imagePath) {
        stampImages[spec.imagePath] = loaded
        image = loaded
      } else {
        return nil
      }
      let annotation = PdfAnnotateCore.makeStamp(spec, image: image, on: page)
      annotation.isReadOnly = true
      page.addAnnotation(annotation)
      return PdfAnnotateShownItem(
        id: item.id, pageIndex: spec.pageIndex, kind: nil, bounds: spec.rect, rects: [], strokes: [], lineWidth: 0, annotations: [annotation])
    }
    return nil
  }

  /// The shown item under [point] (Pigeon page space) on [pageIndex].
  func hit(pageIndex: Int, point: CGPoint) -> String? {
    let scale = max(pdfView.scaleFactor, 0.01)
    let items = shown.filter { $0.pageIndex == pageIndex }.map {
      (id: $0.id, kind: $0.kind, bounds: $0.bounds, rects: $0.rects, strokes: $0.strokes, lineWidth: $0.lineWidth)
    }
    return PdfAnnotateCore.hitTest(items, at: point, tolerance: PdfAnnotateSession.tapReach / scale)
  }

  /// The view's text selection as lines per page (Pigeon page space).
  func selectionLines() -> [(pageIndex: Int, rects: [CGRect])] {
    guard let selection = pdfView.currentSelection, let document = pdfView.document, !(selection.string ?? "").isEmpty else { return [] }
    return PdfAnnotateCore.lineRects(selection, in: document)
  }

  /// [viewPoint] (in the PDF view) as a page index and a Pigeon page-space point; [nearest] snaps
  /// a point between pages to the closest page.
  func pagePoint(_ viewPoint: CGPoint, nearest: Bool) -> (Int, PDFPage, CGPoint)? {
    guard let document = pdfView.document, let page = pdfView.page(for: viewPoint, nearest: nearest) else { return nil }
    let index = document.index(for: page)
    guard index != NSNotFound else { return nil }
    return (index, page, PdfAnnotateGeometry.fromKit(pdfView.convert(viewPoint, to: page), page))
  }

  private func handleTap(at viewPoint: CGPoint) {
    guard input != .ink, let (index, _, point) = pagePoint(viewPoint, nearest: false) else { return }
    onTap?(index, point, hit(pageIndex: index, point: point))
  }

  /// Sends a stroke drawn at [viewPoints] (PDF view coordinates) to Dart, on the page of its
  /// first point, clamped to that page.
  private func commitStroke(_ viewPoints: [CGPoint]) {
    guard let first = viewPoints.first, let (index, page, _) = pagePoint(first, nearest: true) else { return }
    let crop = page.bounds(for: .cropBox)
    var points: [CGPoint] = []
    points.reserveCapacity(min(viewPoints.count, PdfAnnotateCore.maxStrokePoints))
    let step = max(1, viewPoints.count / PdfAnnotateCore.maxStrokePoints + 1)
    for (i, p) in viewPoints.enumerated() where i % step == 0 || i == viewPoints.count - 1 {
      let kit = pdfView.convert(p, to: page)
      let clamped = CGPoint(x: min(max(kit.x, crop.minX), crop.maxX), y: min(max(kit.y, crop.minY), crop.maxY))
      points.append(PdfAnnotateGeometry.fromKit(clamped, page))
    }
    onInk?(index, points)
  }

  // -------------------------------------------------------------------------------------------
  // Input (iOS)

  #if os(iOS)
  private var container: UIView? { pdfView.superview }

  private func installInput() {
    installed = true
    if input == .ink {
      installCanvas()
    } else {
      let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
      tap.cancelsTouchesInView = false
      tap.delegate = self
      pdfView.addGestureRecognizer(tap)
      self.tap = tap
    }
  }

  private func uninstallInput() {
    installed = false
    if let tap { pdfView.removeGestureRecognizer(tap) }
    tap = nil
    canvas?.removeFromSuperview()
    canvas = nil
    scrollPan = nil
    pinch = nil
    committedStrokes = 0
  }

  @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
    guard recognizer.state == .ended else { return }
    handleTap(at: recognizer.location(in: pdfView))
  }

  /// True when the system prefers Apple Pencil for drawing (a finger then scrolls).
  static var prefersPencilOnly: Bool {
    UIDevice.current.userInterfaceIdiom == .pad && UIPencilInteraction.prefersPencilOnlyDrawing
  }

  private func installCanvas() {
    guard let container else { return }
    let canvas = PKCanvasView(frame: pdfView.frame)
    canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    canvas.backgroundColor = .clear
    canvas.isOpaque = false
    canvas.isScrollEnabled = false
    // PencilKit adapts ink to dark mode; the pages are white, so keep the colours as chosen.
    canvas.overrideUserInterfaceStyle = .light
    canvas.drawingPolicy = PdfAnnotateSession.prefersPencilOnly ? .pencilOnly : .anyInput
    canvas.delegate = self
    canvas.accessibilityLabel = "Drawing area"
    container.addSubview(canvas)
    self.canvas = canvas
    committedStrokes = 0

    // Scrolling and zooming pass to the PDF view: two fingers, or one finger when a Pencil draws.
    let pan = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
    if canvas.drawingPolicy == .pencilOnly {
      pan.minimumNumberOfTouches = 1
      pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
    } else {
      pan.minimumNumberOfTouches = 2
    }
    pan.delegate = self
    canvas.addGestureRecognizer(pan)
    let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
    pinch.delegate = self
    canvas.addGestureRecognizer(pinch)
    scrollPan = pan
    self.pinch = pinch
    updateInkTool()
  }

  private func updateInkTool() {
    guard let canvas else { return }
    let width = inkWidth * max(pdfView.scaleFactor, 0.1)
    canvas.tool = PKInkingTool(.pen, color: PdfAnnotateCore.color(inkColor), width: width)
  }

  private var scrollView: UIScrollView? {
    pdfView.documentView?.superview as? UIScrollView ?? pdfView.subviews.compactMap { $0 as? UIScrollView }.first
  }

  /// Drops a stroke PencilKit started for the first finger of a two-finger gesture.
  private func cancelLiveStroke() {
    guard let canvas else { return }
    canvas.drawingGestureRecognizer.isEnabled = false
    canvas.drawingGestureRecognizer.isEnabled = true
  }

  @objc private func scrolled(_ recognizer: UIPanGestureRecognizer) {
    guard let scroll = scrollView else { return }
    if recognizer.state == .began { cancelLiveStroke() }
    let t = recognizer.translation(in: pdfView)
    recognizer.setTranslation(.zero, in: pdfView)
    let inset = scroll.adjustedContentInset
    let maxX = max(-inset.left, scroll.contentSize.width - scroll.bounds.width + inset.right)
    let maxY = max(-inset.top, scroll.contentSize.height - scroll.bounds.height + inset.bottom)
    let x = min(max(scroll.contentOffset.x - t.x, -inset.left), maxX)
    let y = min(max(scroll.contentOffset.y - t.y, -inset.top), maxY)
    scroll.setContentOffset(CGPoint(x: x, y: y), animated: false)
  }

  @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
    switch recognizer.state {
    case .began:
      cancelLiveStroke()
      pinchStart = pdfView.scaleFactor
      pdfView.autoScales = false
    case .changed:
      pdfView.scaleFactor = min(max(pinchStart * recognizer.scale, pdfView.minScaleFactor), pdfView.maxScaleFactor)
    case .ended, .cancelled:
      updateInkTool()
    default:
      break
    }
  }

  private func clearLiveInk() {
    guard let canvas, !canvas.drawing.strokes.isEmpty else { return }
    clearingCanvas = true
    canvas.drawing = PKDrawing()
    committedStrokes = 0
    clearingCanvas = false
  }
  #endif

  // -------------------------------------------------------------------------------------------
  // Input (macOS)

  #if os(macOS)
  private func installInput() {
    installed = true
    if input == .ink {
      guard let container = pdfView.superview else { return }
      let overlay = PdfMouseInkView(frame: pdfView.frame)
      overlay.autoresizingMask = [.width, .height]
      overlay.pdfView = pdfView
      overlay.color = PdfAnnotateCore.color(inkColor).cgColor
      overlay.onStroke = { [weak self] points in self?.commitStroke(points) }
      container.addSubview(overlay, positioned: .above, relativeTo: pdfView)
      mouseInk = overlay
      updateInkTool()
    } else {
      let click = NSClickGestureRecognizer(target: self, action: #selector(clicked(_:)))
      click.delaysPrimaryMouseButtonEvents = false
      pdfView.addGestureRecognizer(click)
      self.click = click
    }
  }

  private func uninstallInput() {
    installed = false
    if let click { pdfView.removeGestureRecognizer(click) }
    click = nil
    mouseInk?.removeFromSuperview()
    mouseInk = nil
  }

  @objc private func clicked(_ recognizer: NSClickGestureRecognizer) {
    guard recognizer.state == .ended else { return }
    handleTap(at: recognizer.location(in: pdfView))
  }

  private func updateInkTool() {
    mouseInk?.color = PdfAnnotateCore.color(inkColor).cgColor
    mouseInk?.lineWidth = inkWidth * max(pdfView.scaleFactor, 0.1)
  }

  private func clearLiveInk() {
    mouseInk?.clear()
  }
  #endif
}

#if os(iOS)
extension PdfAnnotateSession: UIGestureRecognizerDelegate {
  func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
    true
  }
}

extension PdfAnnotateSession: PKCanvasViewDelegate {
  func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
    guard !clearingCanvas else { return }
    let strokes = canvasView.drawing.strokes
    guard strokes.count > committedStrokes else {
      committedStrokes = strokes.count
      return
    }
    for stroke in strokes[committedStrokes...] {
      var points: [CGPoint] = []
      for p in stroke.path.interpolatedPoints(by: .distance(1.5)) {
        points.append(pdfView.convert(p.location.applying(stroke.transform), from: canvasView))
      }
      if points.isEmpty, let first = stroke.path.first {
        points.append(pdfView.convert(first.location.applying(stroke.transform), from: canvasView))
      }
      if !points.isEmpty { commitStroke(points) }
    }
    committedStrokes = strokes.count
  }
}
#endif

#if os(macOS)
/// The macOS ink overlay: the mouse or trackpad draws a stroke (shown live); scrolling and
/// magnifying pass to the PDF view underneath.
final class PdfMouseInkView: NSView {
  weak var pdfView: PDFView?
  var onStroke: (([CGPoint]) -> Void)?
  var color: CGColor = CGColor(red: 0.9, green: 0.22, blue: 0.21, alpha: 1) {
    didSet { strokes.strokeColor = color; live.strokeColor = color }
  }
  var lineWidth: CGFloat = 2 {
    didSet { live.lineWidth = lineWidth }
  }
  private let live = CAShapeLayer()
  private let strokes = CAShapeLayer()
  private var points: [CGPoint] = []
  private var committed = CGMutablePath()

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    for l in [strokes, live] {
      l.fillColor = nil
      l.lineCap = .round
      l.lineJoin = .round
      l.strokeColor = color
      layer?.addSublayer(l)
    }
    setAccessibilityLabel("Drawing area")
  }

  required init?(coder: NSCoder) { nil }

  override var isFlipped: Bool { true }

  override func layout() {
    super.layout()
    live.frame = bounds
    strokes.frame = bounds
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .crosshair)
  }

  private func viewPoint(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

  override func mouseDown(with event: NSEvent) {
    points = [viewPoint(event)]
    redrawLive()
  }

  override func mouseDragged(with event: NSEvent) {
    points.append(viewPoint(event))
    redrawLive()
  }

  override func mouseUp(with event: NSEvent) {
    points.append(viewPoint(event))
    let finished = points
    points = []
    // Keep the stroke on screen until the preview shows its annotation.
    let path = CGMutablePath()
    path.addLines(between: finished.count == 1 ? [finished[0], finished[0]] : finished)
    committed.addPath(path)
    strokes.path = committed
    strokes.lineWidth = lineWidth
    live.path = nil
    guard let pdfView else { return }
    onStroke?(finished.map { pdfView.convert($0, from: self) })
  }

  private func redrawLive() {
    let path = CGMutablePath()
    path.addLines(between: points.count == 1 ? [points[0], points[0]] : points)
    live.path = path
  }

  func clear() {
    committed = CGMutablePath()
    strokes.path = nil
  }

  override func scrollWheel(with event: NSEvent) { pdfView?.scrollWheel(with: event) }

  override func magnify(with event: NSEvent) { pdfView?.magnify(with: event) }
}
#endif
