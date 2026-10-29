// OWNER: HOM-29
// EXTENDED: HOM-30 (a stamp turned a quarter (90° or 270°) still fills its rect: the image is drawn
// with its sides swapped before the turn, so a signature placed upright on a rotated page covers
// exactly the rect the viewer hit-tests, moves and resizes.)
//
// The Flutter-free core of annotate and highlight on iOS and macOS (HOM plan §8.5, D-98j; ARCH v1.2
// rule 27): builds real PDFKit annotations (highlight, underline, strikeOut with one quadrilateral
// per text line; ink with one path per stroke; freeText; a text note) and image stamps (HOM-30's
// signatures), writes them into a NEW file, or burns them into the page content (`burnIn`). The
// source is opened read-only and only changed in memory; only `outPath` is written, once, at the
// end, and deleted again on cancel or failure (no partial file). Page content streams are kept, so
// text stays text; existing annotations stay as they are. An encrypted source gives an encrypted
// output with the password it was opened with (PdfPageToolsCore.write). The viewer's annotate
// mode (PdfAnnotateView.swift) builds its preview with the same functions, so what the user sees
// is what is saved. XCTest runs this file without Flutter (Tests/Annotate/). Nothing here logs a
// name, a path or document text (rule 30).
//
// Geometry follows the Pigeon surface: page space in points with the origin at the bottom-left of
// the crop box, unrotated ([PdfAnnotateGeometry] converts to and from PDFKit's page space).

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit

#if os(iOS)
import UIKit
typealias PdfAnnotateColor = UIColor
typealias PdfAnnotateFont = UIFont
typealias PdfAnnotatePath = UIBezierPath
#elseif os(macOS)
import AppKit
typealias PdfAnnotateColor = NSColor
typealias PdfAnnotateFont = NSFont
typealias PdfAnnotatePath = NSBezierPath
#endif

/// The kinds of [PdfAnnotationSpec] (pigeons/pdf_api.dart `PdfAnnotationKindMsg`, same order).
enum PdfAnnotationKind: Int, CaseIterable {
  case highlight
  case underline
  case strikeOut
  case ink
  case freeText
  case note

  /// Text markup over line rects.
  var isMarkup: Bool { self == .highlight || self == .underline || self == .strikeOut }

  /// The PDF subtype PDFKit writes.
  var subtype: PDFAnnotationSubtype {
    switch self {
    case .highlight: return .highlight
    case .underline: return .underline
    case .strikeOut: return .strikeOut
    case .ink: return .ink
    case .freeText: return .freeText
    case .note: return .text
    }
  }
}

/// One annotation to add, in Pigeon page space.
struct PdfAnnotationSpec: Equatable {
  let kind: PdfAnnotationKind
  let pageIndex: Int
  /// Markup: one rect per text line; freeText / note: the box (its top edge and width count for
  /// freeText, the height grows to fit the text) or the icon position.
  let rects: [CGRect]
  /// Ink strokes, each a list of points.
  let strokes: [[CGPoint]]
  /// 0xAARRGGBB.
  let colorArgb: UInt32
  /// Ink and border width in points.
  let lineWidth: CGFloat
  /// freeText and note content.
  let text: String?

  init(kind: PdfAnnotationKind, pageIndex: Int, rects: [CGRect] = [], strokes: [[CGPoint]] = [], colorArgb: UInt32 = 0xFFFF_D60A,
       lineWidth: CGFloat = 2, text: String? = nil) {
    self.kind = kind
    self.pageIndex = pageIndex
    self.rects = rects
    self.strokes = strokes
    self.colorArgb = colorArgb
    self.lineWidth = lineWidth
    self.text = text
  }
}

/// One image stamp (HOM-30's visual signature), in Pigeon page space.
struct PdfStampSpec: Equatable {
  let pageIndex: Int
  let rect: CGRect
  /// A PNG (transparency kept) or JPEG file.
  let imagePath: String
  /// Clockwise around the rect's centre.
  let rotationDegrees: CGFloat

  init(pageIndex: Int, rect: CGRect, imagePath: String, rotationDegrees: CGFloat = 0) {
    self.pageIndex = pageIndex
    self.rect = rect
    self.imagePath = imagePath
    self.rotationDegrees = rotationDegrees
  }
}

/// Conversions between Pigeon page space (origin at the crop box's bottom-left) and PDFKit's.
enum PdfAnnotateGeometry {
  static func origin(_ page: PDFPage) -> CGPoint { page.bounds(for: .cropBox).origin }

  static func toKit(_ p: CGPoint, _ page: PDFPage) -> CGPoint {
    let o = origin(page)
    return CGPoint(x: p.x + o.x, y: p.y + o.y)
  }

  static func toKit(_ r: CGRect, _ page: PDFPage) -> CGRect { r.offsetBy(dx: origin(page).x, dy: origin(page).y) }

  static func fromKit(_ p: CGPoint, _ page: PDFPage) -> CGPoint {
    let o = origin(page)
    return CGPoint(x: p.x - o.x, y: p.y - o.y)
  }

  static func fromKit(_ r: CGRect, _ page: PDFPage) -> CGRect { r.offsetBy(dx: -origin(page).x, dy: -origin(page).y) }
}

/// A Stamp annotation that draws an image (PDFKit writes what `draw` paints as its appearance
/// stream, so other apps show and can move it).
final class PdfImageStampAnnotation: PDFAnnotation {
  var image: CGImage?
  /// Clockwise degrees around the bounds' centre.
  var imageRotation: CGFloat = 0

  override func draw(with box: PDFDisplayBox, in context: CGContext) {
    guard let image else { return }
    PdfAnnotateCore.drawImage(image, in: bounds, rotation: imageRotation, context: context)
  }
}

/// Annotate and highlight.
enum PdfAnnotateCore {
  /// Text boxes use this font size (points).
  static let freeTextFontSize: CGFloat = 14

  /// Inner padding of a text box (points).
  static let freeTextPadding: CGFloat = 4

  /// The note icon's side (points).
  static let noteSize: CGFloat = 24

  /// Most points in one ink stroke and most strokes in one ink annotation (a sanity bound).
  static let maxStrokePoints = 20_000
  static let maxStrokes = 500

  // -------------------------------------------------------------------------------------------
  // Building annotations

  static func color(_ argb: UInt32) -> PdfAnnotateColor {
    let a = CGFloat((argb >> 24) & 0xFF) / 255
    let r = CGFloat((argb >> 16) & 0xFF) / 255
    let g = CGFloat((argb >> 8) & 0xFF) / 255
    let b = CGFloat(argb & 0xFF) / 255
    return PdfAnnotateColor(red: r, green: g, blue: b, alpha: a)
  }

  /// Checks [spec] against a page of [pageCount] pages.
  static func validate(_ spec: PdfAnnotationSpec, pageCount: Int) throws {
    guard spec.pageIndex >= 0, spec.pageIndex < pageCount else { throw PdfFailure(.invalidArgument, "page out of range") }
    guard spec.lineWidth.isFinite, spec.lineWidth >= 0, spec.lineWidth <= 200 else { throw PdfFailure(.invalidArgument, "bad line width") }
    let finite = { (r: CGRect) in r.origin.x.isFinite && r.origin.y.isFinite && r.width.isFinite && r.height.isFinite && r.width >= 0 && r.height >= 0 }
    guard spec.rects.allSatisfy(finite) else { throw PdfFailure(.invalidArgument, "bad rect") }
    switch spec.kind {
    case .highlight, .underline, .strikeOut:
      guard !spec.rects.isEmpty, spec.rects.allSatisfy({ $0.width > 0 && $0.height > 0 }) else {
        throw PdfFailure(.invalidArgument, "markup needs line rects")
      }
    case .ink:
      guard !spec.strokes.isEmpty, spec.strokes.count <= maxStrokes,
            spec.strokes.allSatisfy({ !$0.isEmpty && $0.count <= maxStrokePoints && $0.allSatisfy { $0.x.isFinite && $0.y.isFinite } })
      else { throw PdfFailure(.invalidArgument, "ink needs strokes") }
    case .freeText, .note:
      guard let first = spec.rects.first, first.width >= 0 else { throw PdfFailure(.invalidArgument, "text needs a box") }
      guard let text = spec.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw PdfFailure(.invalidArgument, "text is empty")
      }
    }
  }

  /// The PDFKit annotation of [spec] on [page] (validated against the page's document first).
  static func makeAnnotation(_ spec: PdfAnnotationSpec, on page: PDFPage) throws -> PDFAnnotation {
    try validate(spec, pageCount: Int.max)
    let color = self.color(spec.colorArgb)
    switch spec.kind {
    case .highlight, .underline, .strikeOut:
      let rects = spec.rects.map { PdfAnnotateGeometry.toKit($0, page) }
      let bounds = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
      let annotation = PDFAnnotation(bounds: bounds, forType: spec.kind.subtype, withProperties: nil)
      annotation.quadrilateralPoints = quadrilaterals(rects, relativeTo: bounds.origin)
      annotation.color = color
      return annotation
    case .ink:
      let strokes = spec.strokes.map { $0.map { PdfAnnotateGeometry.toKit($0, page) } }
      let pad = max(spec.lineWidth, 1)
      let all = strokes.flatMap { $0 }
      var bounds = CGRect(origin: all[0], size: .zero)
      for p in all { bounds = bounds.union(CGRect(origin: p, size: .zero)) }
      bounds = bounds.insetBy(dx: -pad, dy: -pad)
      let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
      for stroke in strokes {
        annotation.add(path(stroke, relativeTo: bounds.origin))
      }
      let border = PDFBorder()
      border.lineWidth = spec.lineWidth
      annotation.border = border
      annotation.color = color
      return annotation
    case .freeText:
      let box = freeTextBounds(text: spec.text ?? "", in: PdfAnnotateGeometry.toKit(spec.rects[0], page), page: page)
      let annotation = PDFAnnotation(bounds: box, forType: .freeText, withProperties: nil)
      annotation.contents = spec.text
      annotation.font = PdfAnnotateFont.systemFont(ofSize: freeTextFontSize)
      annotation.fontColor = color
      annotation.color = PdfAnnotateColor.clear
      annotation.alignment = .left
      let border = PDFBorder()
      border.lineWidth = 0
      annotation.border = border
      return annotation
    case .note:
      let r = PdfAnnotateGeometry.toKit(spec.rects[0], page)
      let annotation = PDFAnnotation(bounds: CGRect(x: r.minX, y: r.minY, width: noteSize, height: noteSize), forType: .text, withProperties: nil)
      annotation.contents = spec.text
      annotation.color = color
      annotation.iconType = .note
      return annotation
    }
  }

  /// A Stamp annotation showing [image] at [spec]'s rect on [page].
  static func makeStamp(_ spec: PdfStampSpec, image: CGImage, on page: PDFPage) -> PdfImageStampAnnotation {
    let annotation = PdfImageStampAnnotation(bounds: PdfAnnotateGeometry.toKit(spec.rect, page), forType: .stamp, withProperties: nil)
    annotation.image = image
    annotation.imageRotation = spec.rotationDegrees
    return annotation
  }

  /// Quadrilateral points of [rects] (top-left, top-right, bottom-left, bottom-right each, PDFKit's
  /// order), relative to [origin] (the annotation's bounds).
  static func quadrilaterals(_ rects: [CGRect], relativeTo origin: CGPoint) -> [NSValue] {
    var out: [NSValue] = []
    for r in rects {
      let rr = r.offsetBy(dx: -origin.x, dy: -origin.y)
      for p in [CGPoint(x: rr.minX, y: rr.maxY), CGPoint(x: rr.maxX, y: rr.maxY), CGPoint(x: rr.minX, y: rr.minY), CGPoint(x: rr.maxX, y: rr.minY)] {
        #if os(iOS)
        out.append(NSValue(cgPoint: p))
        #else
        out.append(NSValue(point: p))
        #endif
      }
    }
    return out
  }

  static func path(_ points: [CGPoint], relativeTo origin: CGPoint) -> PdfAnnotatePath {
    let path = PdfAnnotatePath()
    let shifted = points.map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) }
    path.move(to: shifted[0])
    if shifted.count == 1 {
      // A dot: a zero-length segment, drawn with round caps.
      #if os(iOS)
      path.addLine(to: shifted[0])
      #else
      path.line(to: shifted[0])
      #endif
    }
    for p in shifted.dropFirst() {
      #if os(iOS)
      path.addLine(to: p)
      #else
      path.line(to: p)
      #endif
    }
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    return path
  }

  /// The box of a text annotation: [box]'s top edge and width (at least 40 points, at most what
  /// fits on [page]), the height fitted to [text] at [freeTextFontSize].
  static func freeTextBounds(text: String, in box: CGRect, page: PDFPage) -> CGRect {
    let crop = page.bounds(for: .cropBox)
    let left = min(max(box.minX, crop.minX), crop.maxX - 40)
    let width = min(max(box.width, 40), crop.maxX - left)
    let top = min(max(box.maxY, crop.minY + freeTextFontSize * 1.5), crop.maxY)
    let font = CTFontCreateWithName("Helvetica" as CFString, freeTextFontSize, nil)
    let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
    let setter = CTFramesetterCreateWithAttributedString(attributed)
    let inner = max(width - 2 * freeTextPadding, 1)
    let fitted = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil, CGSize(width: inner, height: .greatestFiniteMagnitude), nil)
    // A little room for the system font's line height, which is taller than Helvetica's.
    let height = ceil(fitted.height * 1.25) + 2 * freeTextPadding
    return CGRect(x: left, y: top - height, width: width, height: height)
  }

  /// Draws [image] filling [rect], turned [rotation] degrees clockwise around its centre. A
  /// quarter turn (90° or 270°) swaps the image's sides first, so it still fills [rect].
  static func drawImage(_ image: CGImage, in rect: CGRect, rotation: CGFloat, context: CGContext) {
    context.saveGState()
    context.translateBy(x: rect.midX, y: rect.midY)
    if rotation != 0 { context.rotate(by: -rotation * .pi / 180) }
    context.interpolationQuality = .high
    let quarter = Int((rotation / 90).rounded())
    let swap = abs(rotation - CGFloat(quarter) * 90) < 0.01 && quarter % 2 != 0
    let w = swap ? rect.height : rect.width
    let h = swap ? rect.width : rect.height
    context.draw(image, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
    context.restoreGState()
  }

  /// The image of a stamp (PNG or JPEG; orientation applied, at most 2048 px on its longer side).
  static func loadImage(_ path: String) throws -> CGImage {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
      throw PdfFailure(.notFound, "no such image")
    }
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
      throw PdfFailure(.invalidArgument, "not a readable image")
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: 2048,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      throw PdfFailure(.invalidArgument, "not a readable image")
    }
    return image
  }

  // -------------------------------------------------------------------------------------------
  // Saving

  /// Writes [input] with [annotations] and [stamps] added into the new file [outPath]. With
  /// [burnIn] they are drawn into the page content instead (the pages' existing annotations stay
  /// annotations). Progress counts the pages touched, then the write.
  static func annotate(
    _ input: PdfToolSource, annotations: [PdfAnnotationSpec], stamps: [PdfStampSpec] = [], burnIn: Bool = false,
    outPath: String, control: PdfToolControl
  ) throws -> PdfWrittenFile {
    guard !input.isImage else { throw PdfFailure(.invalidArgument, "annotate needs a PDF") }
    try PdfPageToolsCore.checkNewFile(outPath, inputs: [input.path])
    let document = try PdfReader.open(path: input.path, password: input.password)
    if document.isLocked { throw PdfFailure(.passwordRequired, "document is locked") }
    guard document.pageCount > 0 else { throw PdfFailure(.damaged, "document has no pages") }
    guard document.allowsCommenting else { throw PdfFailure(.unsupported, "document forbids annotations") }
    if burnIn, !document.allowsDocumentChanges { throw PdfFailure(.unsupported, "document forbids changes") }
    for spec in annotations { try validate(spec, pageCount: document.pageCount) }
    for stamp in stamps {
      guard stamp.pageIndex >= 0, stamp.pageIndex < document.pageCount else { throw PdfFailure(.invalidArgument, "page out of range") }
      guard stamp.rect.width > 0, stamp.rect.height > 0, stamp.rect.width.isFinite, stamp.rect.height.isFinite,
            stamp.rotationDegrees.isFinite else { throw PdfFailure(.invalidArgument, "bad stamp rect") }
    }
    let images = try stamps.map { try loadImage($0.imagePath) }
    let encryption = PdfOutputEncryption.of(document, password: input.password)
    let pages = Array(Set(annotations.map(\.pageIndex) + stamps.map(\.pageIndex))).sorted()
    let total = pages.count + 1
    return try PdfPageToolsCore.writingNewFiles([outPath]) {
      var done = 0
      control.progress(done: 0, total: total)
      for index in pages {
        try PdfPageToolsCore.checkCancelled(control)
        guard let page = document.page(at: index) else { throw PdfFailure(.damaged, "unreadable page") }
        try autoreleasepool {
          var added: [PDFAnnotation] = []
          for spec in annotations where spec.pageIndex == index {
            added.append(try makeAnnotation(spec, on: page))
          }
          for (stamp, image) in zip(stamps, images) where stamp.pageIndex == index {
            added.append(makeStamp(stamp, image: image, on: page))
          }
          if burnIn {
            let burned = try burn(added, into: page)
            document.removePage(at: index)
            document.insert(burned, at: index)
            repoint(document, from: page, to: burned)
          } else {
            for annotation in added { page.addAnnotation(annotation) }
          }
        }
        done += 1
        control.progress(done: done, total: total)
      }
      let written = try PdfPageToolsCore.write(document, to: outPath, control: control, keepAlive: nil, encryption: encryption)
      control.progress(done: total, total: total)
      return written
    }
  }

  /// A copy of [page] whose content is the page's own content with [annotations] drawn over it
  /// (vector content and text are kept: Quartz re-emits the page's content stream), with the
  /// page's boxes, rotation and existing annotations.
  static func burn(_ annotations: [PDFAnnotation], into page: PDFPage) throws -> PDFPage {
    guard let ref = page.pageRef else { throw PdfFailure(.damaged, "unreadable page") }
    var media = page.bounds(for: .mediaBox)
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &media, nil) else {
      throw PdfFailure(.internal, "no PDF context")
    }
    let existing = page.annotations
    let boxData = withUnsafeBytes(of: &media) { Data($0) }
    context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
    context.drawPDFPage(ref)
    // On the page while they draw (some appearances need their page), then off again.
    for annotation in annotations {
      page.addAnnotation(annotation)
      context.saveGState()
      annotation.draw(with: .mediaBox, in: context)
      context.restoreGState()
      page.removeAnnotation(annotation)
    }
    context.endPDFPage()
    context.closePDF()
    guard let single = PDFDocument(data: data as Data), let burned = single.page(at: 0) else {
      throw PdfFailure(.internal, "burned page not created")
    }
    for box in [PDFDisplayBox.cropBox, .bleedBox, .trimBox, .artBox] {
      burned.setBounds(page.bounds(for: box), for: box)
    }
    burned.rotation = page.rotation
    // Existing annotations move over; a popup travels with its parent.
    for annotation in existing where annotation.type != "Popup" {
      page.removeAnnotation(annotation)
      burned.addAnnotation(annotation)
    }
    // The page's document keeps it alive until the write.
    withExtendedLifetime(single) {}
    return burned
  }

  /// Points the outline entries and link annotations of [document] that went to [old] at [new]
  /// (a burned page replaces its original).
  static func repoint(_ document: PDFDocument, from old: PDFPage, to new: PDFPage) {
    func fix(_ destination: PDFDestination?) -> PDFDestination? {
      guard let destination, destination.page === old else { return nil }
      return PDFDestination(page: new, at: destination.point)
    }
    if let root = document.outlineRoot {
      var stack = [root]
      var visited = 0
      while let node = stack.popLast(), visited < PdfReader.maxOutlineEntries {
        visited += 1
        if let moved = fix(node.destination) { node.destination = moved }
        for i in 0..<node.numberOfChildren {
          if let child = node.child(at: i) { stack.append(child) }
        }
      }
    }
    for index in 0..<document.pageCount {
      guard let page = document.page(at: index) else { continue }
      for annotation in page.annotations where annotation.type == "Link" {
        if let moved = fix(annotation.destination) { annotation.destination = moved }
      }
    }
  }

  // -------------------------------------------------------------------------------------------
  // The viewer's helpers

  /// The text of [selection] as one rect per line, grouped by page index in [document] (Pigeon
  /// page space), pages in document order.
  static func lineRects(_ selection: PDFSelection, in document: PDFDocument) -> [(pageIndex: Int, rects: [CGRect])] {
    var byPage: [Int: [CGRect]] = [:]
    for line in selection.selectionsByLine() {
      for page in line.pages {
        let index = document.index(for: page)
        guard index != NSNotFound else { continue }
        let r = line.bounds(for: page)
        guard r.width > 0, r.height > 0 else { continue }
        byPage[index, default: []].append(PdfAnnotateGeometry.fromKit(r, page))
      }
    }
    return byPage.keys.sorted().map { ($0, byPage[$0]!) }
  }

  /// The id of the topmost of [items] (back to front) under [point] (Pigeon page space) on its
  /// page: markup lines and boxes contain it, ink passes within [tolerance] of it.
  static func hitTest(_ items: [(id: String, kind: PdfAnnotationKind?, bounds: CGRect, rects: [CGRect], strokes: [[CGPoint]], lineWidth: CGFloat)],
                      at point: CGPoint, tolerance: CGFloat) -> String? {
    for item in items.reversed() {
      switch item.kind {
      case .some(.ink):
        let reach = tolerance + item.lineWidth / 2
        guard item.bounds.insetBy(dx: -reach, dy: -reach).contains(point) else { continue }
        for stroke in item.strokes {
          if stroke.count == 1, hypot(stroke[0].x - point.x, stroke[0].y - point.y) <= reach { return item.id }
          for (a, b) in zip(stroke, stroke.dropFirst()) where distance(point, a, b) <= reach { return item.id }
        }
      case .some(.highlight), .some(.underline), .some(.strikeOut):
        if item.rects.contains(where: { $0.insetBy(dx: -tolerance / 2, dy: -tolerance / 2).contains(point) }) { return item.id }
      default:
        if item.bounds.insetBy(dx: -tolerance / 2, dy: -tolerance / 2).contains(point) { return item.id }
      }
    }
    return nil
  }

  /// Distance from [p] to the segment [a]–[b].
  static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x
    let dy = b.y - a.y
    let length2 = dx * dx + dy * dy
    guard length2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length2))
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
  }
}
