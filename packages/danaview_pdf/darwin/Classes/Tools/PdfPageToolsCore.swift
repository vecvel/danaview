// OWNER: HOM-28
//
// The Flutter-free core of the PDF page tools on iOS and macOS (HOM plan §8.5, D-98j; ARCH v1.2
// rule 27): merge (PDFs and images), split, and organise (reorder, rotate, delete, extract) with
// PDFKit. Sources are opened read-only and only ever changed in memory; each tool writes only the
// new file(s) it is given, which must not exist yet, and deletes them again on cancel or failure
// (no partial file). Pages keep their content streams, so text stays text (selectable, searchable).
// Callers run these off the main thread with their own PDFDocument instances; every page step
// polls `control.isCancelled` and reports progress. XCTest runs this file without Flutter
// (Tests/Tools/, run_xctests.sh: macOS and the iOS Simulator). Nothing here logs a name, a path or
// document text (rule 30); failure messages are fixed debug strings.

import CoreGraphics
import Foundation
import ImageIO
import PDFKit

/// Cancel flag and progress sink of one running tool (the glue's PdfJob).
protocol PdfToolControl: AnyObject {
  /// True once the caller cancelled (any thread).
  var isCancelled: Bool { get }

  /// [done] of [total] steps (any thread).
  func progress(done: Int, total: Int)
}

/// One input of a tool.
struct PdfToolSource: Equatable {
  let path: String
  let password: String?
  /// A JPEG, PNG, HEIC, … that becomes one page (merge only).
  let isImage: Bool

  init(path: String, password: String? = nil, isImage: Bool = false) {
    self.path = path
    self.password = password
    self.isImage = isImage
  }
}

/// One page of an organised document: input page [sourcePage] turned by [rotation] more degrees.
struct PdfPagePlanItem: Equatable {
  let sourcePage: Int
  let rotation: Int

  init(_ sourcePage: Int, rotation: Int = 0) {
    self.sourcePage = sourcePage
    self.rotation = rotation
  }
}

/// A file a tool wrote.
struct PdfWrittenFile: Equatable {
  let path: String
  let pageCount: Int
  let sizeBytes: Int
}

/// The page tools.
enum PdfPageToolsCore {
  /// Images become pages whose longer side is this many points (A4's long side), aspect kept.
  static let imagePageLongSide: CGFloat = 842

  /// Images are downscaled to at most this many pixels on their longer side before embedding.
  static let imageMaxPixels = 4096

  /// JPEG quality of re-encoded opaque images.
  static let imageJpegQuality: CGFloat = 0.9

  // -------------------------------------------------------------------------------------------
  // Merge

  /// Merges [inputs] in order into [outPath]. The first PDF keeps its metadata and outline; the
  /// pages of the other inputs follow it. At least two inputs.
  static func merge(_ inputs: [PdfToolSource], outPath: String, control: PdfToolControl) throws -> PdfWrittenFile {
    guard inputs.count >= 2 else { throw PdfFailure(.invalidArgument, "merge needs at least two inputs") }
    try checkNewFile(outPath, inputs: inputs.map(\.path))
    return try writingNewFiles([outPath]) {
      // Open everything first, so a bad input fails before any work and the totals are known.
      var parts: [(document: PDFDocument?, image: PDFDocument?)] = []
      var total = 0
      for input in inputs {
        try checkCancelled(control)
        if input.isImage {
          let page = try imageDocument(path: input.path)
          parts.append((nil, page))
          total += 1
        } else {
          let document = try openForWrite(input)
          parts.append((document, nil))
          total += document.pageCount
        }
      }
      // The output is the first PDF itself (its pages are already in place) or a new document.
      let firstIsPdf = parts.first?.document != nil
      let output = firstIsPdf ? parts[0].document! : PDFDocument()
      var done = firstIsPdf ? output.pageCount : 0
      control.progress(done: done, total: total)
      for (i, part) in parts.enumerated() where !(i == 0 && firstIsPdf) {
        let source = part.document ?? part.image!
        // Collect the pages first: inserting a page into another document may take it out of its
        // own, which would shift the indices of a live loop.
        let pages = (0..<source.pageCount).compactMap { source.page(at: $0) }
        guard pages.count == source.pageCount else { throw PdfFailure(.damaged, "unreadable page") }
        for page in pages {
          try checkCancelled(control)
          autoreleasepool { output.insert(page, at: output.pageCount) }
          done += 1
          control.progress(done: done, total: total)
        }
      }
      // Keep every source alive until the write: the inserted pages draw from them.
      return try write(output, to: outPath, control: control, keepAlive: parts)
    }
  }

  // -------------------------------------------------------------------------------------------
  // Split

  /// Writes one file per range: `ranges[i]` (pages `[lowerBound, upperBound)`) → `outPaths[i]`.
  static func split(_ input: PdfToolSource, ranges: [Range<Int>], outPaths: [String], control: PdfToolControl) throws -> [PdfWrittenFile] {
    guard !input.isImage else { throw PdfFailure(.invalidArgument, "split needs a PDF") }
    guard !ranges.isEmpty, ranges.count == outPaths.count else { throw PdfFailure(.invalidArgument, "one output per range") }
    guard Set(outPaths).count == outPaths.count else { throw PdfFailure(.invalidArgument, "duplicate output") }
    for path in outPaths { try checkNewFile(path, inputs: [input.path]) }
    let source = try openForWrite(input)
    let count = source.pageCount
    for range in ranges where range.isEmpty || range.lowerBound < 0 || range.upperBound > count {
      throw PdfFailure(.invalidArgument, "range out of bounds")
    }
    let total = ranges.reduce(0) { $0 + $1.count }
    return try writingNewFiles(outPaths) {
      var done = 0
      var out: [PdfWrittenFile] = []
      control.progress(done: 0, total: total)
      for (range, path) in zip(ranges, outPaths) {
        let part = PDFDocument()
        if let attributes = source.documentAttributes { part.documentAttributes = attributes }
        for index in range {
          try checkCancelled(control)
          // A copy, so overlapping ranges and later ranges still find every source page.
          guard let page = source.page(at: index)?.copy() as? PDFPage else { throw PdfFailure(.damaged, "unreadable page") }
          autoreleasepool { part.insert(page, at: part.pageCount) }
          done += 1
          control.progress(done: done, total: total)
        }
        out.append(try write(part, to: path, control: control, keepAlive: source))
      }
      return out
    }
  }

  /// `[0, n)`, `[n, 2n)`, … covering [pageCount] pages (the last range may be shorter).
  static func rangesEvery(_ n: Int, pageCount: Int) -> [Range<Int>] {
    guard n > 0, pageCount > 0 else { return [] }
    return stride(from: 0, to: pageCount, by: n).map { $0..<min($0 + n, pageCount) }
  }

  // -------------------------------------------------------------------------------------------
  // Organise (reorder, rotate, delete, extract)

  /// Writes the input's pages in [plan] order, each turned by its extra rotation; pages not in
  /// the plan are left out. The document keeps its metadata and its outline (entries pointing at
  /// a removed page lose their destination).
  static func organise(_ input: PdfToolSource, plan: [PdfPagePlanItem], outPath: String, control: PdfToolControl) throws -> PdfWrittenFile {
    guard !input.isImage else { throw PdfFailure(.invalidArgument, "organise needs a PDF") }
    guard !plan.isEmpty else { throw PdfFailure(.invalidArgument, "at least one page must remain") }
    try checkNewFile(outPath, inputs: [input.path])
    let document = try openForWrite(input)
    let count = document.pageCount
    var seen = Set<Int>()
    for item in plan {
      guard item.sourcePage >= 0, item.sourcePage < count else { throw PdfFailure(.invalidArgument, "page out of bounds") }
      guard seen.insert(item.sourcePage).inserted else { throw PdfFailure(.invalidArgument, "page listed twice") }
      guard item.rotation % 90 == 0 else { throw PdfFailure(.invalidArgument, "rotation must be a multiple of 90") }
    }
    let pages = (0..<count).compactMap { document.page(at: $0) }
    guard pages.count == count else { throw PdfFailure(.damaged, "unreadable page") }
    return try writingNewFiles([outPath]) {
      let removals = count - plan.count
      let total = removals + plan.count
      var done = 0
      control.progress(done: 0, total: total)
      for item in plan where item.rotation % 360 != 0 {
        let page = pages[item.sourcePage]
        page.rotation = PdfReader.normalizedRotation(page.rotation + item.rotation)
      }
      for index in (0..<count).reversed() where !seen.contains(index) {
        try checkCancelled(control)
        document.removePage(at: index)
        done += 1
        control.progress(done: done, total: total)
      }
      // Selection by swaps: before step `target`, positions 0..<target hold their final pages.
      for (target, item) in plan.enumerated() {
        try checkCancelled(control)
        let current = document.index(for: pages[item.sourcePage])
        guard current != NSNotFound, current >= target else { throw PdfFailure(.internal, "page lost while reordering") }
        if current != target { document.exchangePage(at: target, withPageAt: current) }
        done += 1
        control.progress(done: done, total: total)
      }
      return try write(document, to: outPath, control: control, keepAlive: nil)
    }
  }

  /// The plan of a reorder: `order[i]` is the page shown at position i (a permutation of all pages).
  static func reorderPlan(_ order: [Int], pageCount: Int) throws -> [PdfPagePlanItem] {
    guard order.count == pageCount, Set(order) == Set(0..<pageCount) else {
      throw PdfFailure(.invalidArgument, "order is not a permutation of the pages")
    }
    return order.map { PdfPagePlanItem($0) }
  }

  /// The plan of rotating [pages] by [degrees] (a multiple of 90).
  static func rotatePlan(_ pages: [Int], degrees: Int, pageCount: Int) throws -> [PdfPagePlanItem] {
    guard degrees % 90 == 0 else { throw PdfFailure(.invalidArgument, "rotation must be a multiple of 90") }
    let set = Set(pages)
    guard !set.isEmpty, set.allSatisfy({ $0 >= 0 && $0 < pageCount }) else { throw PdfFailure(.invalidArgument, "page out of bounds") }
    return (0..<pageCount).map { PdfPagePlanItem($0, rotation: set.contains($0) ? degrees : 0) }
  }

  /// The plan of deleting [pages] (at least one page must remain).
  static func deletePlan(_ pages: [Int], pageCount: Int) throws -> [PdfPagePlanItem] {
    let set = Set(pages)
    guard !set.isEmpty, set.allSatisfy({ $0 >= 0 && $0 < pageCount }) else { throw PdfFailure(.invalidArgument, "page out of bounds") }
    guard set.count < pageCount else { throw PdfFailure(.invalidArgument, "at least one page must remain") }
    return (0..<pageCount).filter { !set.contains($0) }.map { PdfPagePlanItem($0) }
  }

  /// The page count of the PDF [input] (opened read-only, unlocked with its password).
  static func pageCount(_ input: PdfToolSource) throws -> Int {
    try openForWrite(input).pageCount
  }

  // -------------------------------------------------------------------------------------------
  // Helpers

  /// Opens a PDF input read-only, unlocked, and checks that its permissions allow page assembly.
  static func openForWrite(_ input: PdfToolSource) throws -> PDFDocument {
    let document = try PdfReader.open(path: input.path, password: input.password)
    if document.isLocked { throw PdfFailure(.passwordRequired, "document is locked") }
    guard document.allowsDocumentAssembly else { throw PdfFailure(.unsupported, "document forbids page assembly") }
    guard document.pageCount > 0 else { throw PdfFailure(.damaged, "document has no pages") }
    return document
  }

  /// A one-page document showing the image at [path], its orientation applied, downscaled to
  /// [imageMaxPixels] and fitted to a page whose longer side is [imagePageLongSide] points.
  /// Opaque images are embedded as JPEG, images with transparency as they are.
  static func imageDocument(path: String) throws -> PDFDocument {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
      throw PdfFailure(.notFound, "no such file")
    }
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
      throw PdfFailure(.damaged, "not a readable image")
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: imageMaxPixels,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary), decoded.width > 0, decoded.height > 0 else {
      throw PdfFailure(.damaged, "not a readable image")
    }
    let image = try embeddable(decoded)
    let w = CGFloat(image.width)
    let h = CGFloat(image.height)
    let scale = imagePageLongSide / max(w, h)
    var box = CGRect(x: 0, y: 0, width: (w * scale).rounded(), height: (h * scale).rounded())
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData),
          let context = CGContext(consumer: consumer, mediaBox: &box, nil)
    else { throw PdfFailure(.internal, "no PDF context") }
    context.beginPDFPage(nil)
    context.interpolationQuality = .high
    context.draw(image, in: box)
    context.endPDFPage()
    context.closePDF()
    guard let document = PDFDocument(data: data as Data), document.pageCount == 1 else {
      throw PdfFailure(.internal, "image page not created")
    }
    return document
  }

  /// [image] as a JPEG-backed image when it is opaque (the PDF then carries the JPEG as is, not
  /// a much larger lossless copy of the decoded pixels); unchanged when it has transparency.
  static func embeddable(_ image: CGImage) throws -> CGImage {
    switch image.alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast:
      break
    default:
      return image
    }
    let jpeg = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(jpeg as CFMutableData, "public.jpeg" as CFString, 1, nil) else {
      return image
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: imageJpegQuality] as CFDictionary)
    guard CGImageDestinationFinalize(destination),
          let provider = CGDataProvider(data: jpeg as CFData),
          let backed = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    else { return image }
    return backed
  }

  /// Fails with `invalidArgument` when [path] exists, is empty, or is one of [inputs]; with
  /// `notFound` when its folder is missing.
  static func checkNewFile(_ path: String, inputs: [String]) throws {
    guard !path.isEmpty else { throw PdfFailure(.invalidArgument, "empty output path") }
    let standard = URL(fileURLWithPath: path).standardizedFileURL.path
    guard !inputs.contains(where: { URL(fileURLWithPath: $0).standardizedFileURL.path == standard }) else {
      throw PdfFailure(.invalidArgument, "output is an input")
    }
    guard !FileManager.default.fileExists(atPath: path) else { throw PdfFailure(.invalidArgument, "output exists") }
    var isDirectory: ObjCBool = false
    let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
    guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw PdfFailure(.notFound, "output folder missing")
    }
  }

  static func checkCancelled(_ control: PdfToolControl) throws {
    if control.isCancelled { throw PdfFailure(.cancelled, "cancelled") }
  }

  /// Runs [body]; when it throws, deletes whichever of [paths] it created, then rethrows.
  static func writingNewFiles<T>(_ paths: [String], _ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch {
      for path in paths { try? FileManager.default.removeItem(atPath: path) }
      throw error
    }
  }

  /// Writes [document] to the new file [path] (exclusive: never over an existing file).
  static func write(_ document: PDFDocument, to path: String, control: PdfToolControl, keepAlive: Any?) throws -> PdfWrittenFile {
    try checkCancelled(control)
    guard !FileManager.default.fileExists(atPath: path) else { throw PdfFailure(.invalidArgument, "output exists") }
    let ok = document.write(to: URL(fileURLWithPath: path))
    withExtendedLifetime(keepAlive) {}
    guard ok, let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
      try? FileManager.default.removeItem(atPath: path)
      if let free = try? URL(fileURLWithPath: path).deletingLastPathComponent()
        .resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity, free < 1_048_576 {
        throw PdfFailure(.noSpace, "out of space")
      }
      throw PdfFailure(.ioError, "write failed")
    }
    // A cancel that arrived during the write still leaves no file.
    try checkCancelled(control)
    let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
    return PdfWrittenFile(path: path, pageCount: document.pageCount, sizeBytes: size)
  }
}
