// OWNER: HOM-24
//
// The Flutter-free core of the PDFKit viewer (ARCH v1.2 §8 "PDF viewer", V2-120): read-only opens
// (rule 27: `PDFDocument(url:)`, never written back), password unlock, page geometry, outline and
// page rendering, plus the handle table the glue and the platform views share. XCTest runs it
// without an app host (Tests/Viewer/run_xctests.sh). Nothing here logs a name, a path or document
// text (rule 30); failure messages are fixed debug strings.

import CoreGraphics
import Foundation
import ImageIO
import PDFKit

/// Error codes of the PDF surface (pigeons/pdf_api.dart, "Errors").
enum PdfErrorCode: String {
  case notSupportedOnDevice
  case passwordRequired
  case unsupported
  case damaged
  case cancelled
  case noSpace
  case notFound
  case invalidArgument
  case ioError
  case `internal`
}

/// A failure of a PDF operation; `message` is debug text without names, paths or document text.
struct PdfFailure: Error, Equatable {
  let code: PdfErrorCode
  let message: String

  init(_ code: PdfErrorCode, _ message: String) {
    self.code = code
    self.message = message
  }
}

/// The crop box of a page in points (unrotated) and its rotation.
struct PdfPageGeometry: Equatable {
  let width: Double
  let height: Double
  let rotation: Int
}

/// What the Dart side learns about an open document.
struct PdfDocumentSummary: Equatable {
  let handle: Int64
  let pageCount: Int
  let encrypted: Bool
  let locked: Bool
  let allowsCopying: Bool
  let allowsPrinting: Bool
  let pages: [PdfPageGeometry]
  let title: String?
}

/// One outline entry, flattened depth-first.
struct PdfOutlineEntry: Equatable {
  let title: String
  let pageIndex: Int
  let depth: Int
}

/// A cheap open-and-close result.
struct PdfProbeResult: Equatable {
  let canOpen: Bool
  let encrypted: Bool
  let pageCount: Int
}

/// An encoded page image.
struct PdfRenderedImage {
  let png: Data
  let width: Int
  let height: Int
}

/// Read-only PDF access with PDFKit.
enum PdfReader {
  /// The most outline entries returned (a damaged outline can be cyclic or huge).
  static let maxOutlineEntries = 5000

  /// Opens [path] read-only: `notFound` when there is no file, `damaged` when PDFKit can't parse it.
  static func open(path: String) throws -> PDFDocument {
    var isDirectory: ObjCBool = false
    guard !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
      throw PdfFailure(.notFound, "no such file")
    }
    guard FileManager.default.isReadableFile(atPath: path) else { throw PdfFailure(.ioError, "file not readable") }
    guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else {
      throw PdfFailure(.damaged, "not a readable PDF")
    }
    return document
  }

  /// Opens [path] and unlocks it with [password] (an empty password is always tried by PDFKit).
  /// A wrong or missing password leaves the document locked.
  static func open(path: String, password: String?) throws -> PDFDocument {
    let document = try open(path: path)
    if document.isLocked, let password, !password.isEmpty {
      _ = document.unlock(withPassword: password)
    }
    return document
  }

  /// A probe that never throws for a damaged file.
  static func probe(path: String) throws -> PdfProbeResult {
    do {
      let document = try open(path: path)
      return PdfProbeResult(canOpen: true, encrypted: document.isLocked, pageCount: document.isLocked ? -1 : document.pageCount)
    } catch let failure as PdfFailure where failure.code == .damaged {
      return PdfProbeResult(canOpen: false, encrypted: false, pageCount: -1)
    }
  }

  /// The summary of [document] under [handle].
  static func summary(of document: PDFDocument, handle: Int64) -> PdfDocumentSummary {
    let locked = document.isLocked
    var pages: [PdfPageGeometry] = []
    if !locked {
      pages.reserveCapacity(document.pageCount)
      for i in 0..<document.pageCount {
        guard let page = document.page(at: i) else {
          pages.append(PdfPageGeometry(width: 612, height: 792, rotation: 0))
          continue
        }
        let box = page.bounds(for: .cropBox)
        pages.append(PdfPageGeometry(width: Double(box.width), height: Double(box.height), rotation: normalizedRotation(page.rotation)))
      }
    }
    let title = locked ? nil : (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 }
    return PdfDocumentSummary(
      handle: handle,
      pageCount: locked ? 0 : document.pageCount,
      encrypted: document.isEncrypted,
      locked: locked,
      allowsCopying: !locked && document.allowsCopying,
      allowsPrinting: !locked && document.allowsPrinting,
      pages: pages,
      title: title)
  }

  /// The outline of [document], depth-first, at most [maxOutlineEntries] entries.
  static func outline(of document: PDFDocument) -> [PdfOutlineEntry] {
    guard !document.isLocked, let root = document.outlineRoot else { return [] }
    var out: [PdfOutlineEntry] = []
    func walk(_ node: PDFOutline, depth: Int) {
      guard depth < 32 else { return }
      for i in 0..<node.numberOfChildren {
        guard out.count < maxOutlineEntries, let child = node.child(at: i) else { return }
        var pageIndex = -1
        if let page = child.destination?.page {
          let index = document.index(for: page)
          if index != NSNotFound, index >= 0, index < document.pageCount { pageIndex = index }
        }
        out.append(PdfOutlineEntry(title: child.label ?? "", pageIndex: pageIndex, depth: depth))
        walk(child, depth: depth + 1)
      }
    }
    walk(root, depth: 0)
    return out
  }

  /// Renders page [index] of [document] fitted into `maxWidth × maxHeight` pixels, honouring the
  /// page rotation, on a white background, as PNG.
  static func render(_ document: PDFDocument, page index: Int, maxWidth: Int, maxHeight: Int) throws -> PdfRenderedImage {
    guard !document.isLocked else { throw PdfFailure(.passwordRequired, "document is locked") }
    guard maxWidth > 0, maxHeight > 0, maxWidth <= 8192, maxHeight <= 8192 else {
      throw PdfFailure(.invalidArgument, "thumbnail size out of range")
    }
    guard index >= 0, index < document.pageCount, let page = document.page(at: index) else {
      throw PdfFailure(.notFound, "no such page")
    }
    let box = page.bounds(for: .cropBox)
    let rotation = normalizedRotation(page.rotation)
    let quarter = rotation == 90 || rotation == 270
    let pageW = Double(quarter ? box.height : box.width)
    let pageH = Double(quarter ? box.width : box.height)
    guard pageW > 0, pageH > 0 else { throw PdfFailure(.damaged, "empty page box") }
    let scale = min(Double(maxWidth) / pageW, Double(maxHeight) / pageH)
    let width = max(1, Int((pageW * scale).rounded()))
    let height = max(1, Int((pageH * scale).rounded()))
    guard let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw PdfFailure(.internal, "no bitmap context") }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.interpolationQuality = .high
    context.scaleBy(x: CGFloat(Double(width) / pageW), y: CGFloat(Double(height) / pageH))
    // PDFPage.draw(with:to:) applies the crop box origin and the page rotation itself.
    page.draw(with: .cropBox, to: context)
    guard let image = context.makeImage() else { throw PdfFailure(.internal, "no image") }
    return PdfRenderedImage(png: try encodePng(image), width: width, height: height)
  }

  static func encodePng(_ image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
      throw PdfFailure(.internal, "no PNG encoder")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw PdfFailure(.internal, "PNG encoding failed") }
    return data as Data
  }

  static func normalizedRotation(_ degrees: Int) -> Int {
    let r = ((degrees % 360) + 360) % 360
    return (r / 90) * 90
  }
}

/// The open documents of one plugin instance, by handle. Thread-safe: opens run on a background
/// queue, views and host calls read from the main thread.
final class PdfDocumentStore {
  private struct Entry {
    let document: PDFDocument
    let path: String
    var password: String?
  }

  private let lock = NSLock()
  private var entries: [Int64: Entry] = [:]
  private var nextHandle: Int64 = 1

  /// Number of open handles (tests).
  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return entries.count
  }

  /// Opens [path] read-only (call off the main thread); an encrypted file with no or a wrong
  /// password opens locked.
  func open(path: String, password: String?) throws -> PdfDocumentSummary {
    let document = try PdfReader.open(path: path, password: password)
    lock.lock()
    let handle = nextHandle
    nextHandle += 1
    entries[handle] = Entry(document: document, path: path, password: document.isLocked ? nil : password)
    lock.unlock()
    return PdfReader.summary(of: document, handle: handle)
  }

  /// Unlocks [handle]; nil when [password] is wrong.
  func unlock(handle: Int64, password: String) throws -> PdfDocumentSummary? {
    let document = try self.document(handle)
    if document.isLocked {
      guard !password.isEmpty, document.unlock(withPassword: password) else { return nil }
      lock.lock()
      entries[handle]?.password = password
      lock.unlock()
    }
    return PdfReader.summary(of: document, handle: handle)
  }

  /// The document of [handle] (`notFound` after `close`).
  func document(_ handle: Int64) throws -> PDFDocument {
    lock.lock()
    defer { lock.unlock() }
    guard let entry = entries[handle] else { throw PdfFailure(.notFound, "no such document") }
    return entry.document
  }

  /// A second, independent read-only open of [handle]'s file, unlocked like it (background work
  /// such as search never shares a PDFDocument with a view that draws on the main thread).
  func twin(_ handle: Int64) throws -> PDFDocument {
    lock.lock()
    let entry = entries[handle]
    lock.unlock()
    guard let entry else { throw PdfFailure(.notFound, "no such document") }
    if entry.document.isLocked { throw PdfFailure(.passwordRequired, "document is locked") }
    let twin = try PdfReader.open(path: entry.path, password: entry.password)
    if twin.isLocked { throw PdfFailure(.passwordRequired, "document is locked") }
    return twin
  }

  /// Releases [handle]; views keep their own reference to the document.
  func close(_ handle: Int64) {
    lock.lock()
    entries[handle] = nil
    lock.unlock()
  }
}
