// OWNER: HOM-26
//
// The Flutter-free core of Quick Look and document thumbnails on Apple (ARCH v1.2 §3 "Office /
// other files", V2-120, V2-28, G-R3; HOM plan §8.4; BUILD_PLAN HOM-26):
//
// * QuickLookPolicy: which files Quick Look is asked to preview (by UTType: PDF, text, CSV, rich
//   text, images, audio/video, Office and iWork documents; an unknown type goes to the file card)
//   and the editing rule: Quick Look editing (Markup) is always off, and the preview only ever sees
//   a temporary read-only copy (ExportOut/FileOutCore.swift TempCopyStore), so the stored file
//   can't change (rule 26, G-R3).
// * DocumentThumbnailer: the thumbnail of a document for the HOM-04 cache. PDFs render their first
//   page through CoreGraphics at the caller's scale (screen pixels per PDF point), bounded by the
//   box: an encrypted PDF that opens with the empty password gets a thumbnail, one that needs a
//   password answers nil (the Home shows the lock), a damaged PDF answers nil. Other documents go
//   through `QLThumbnailGenerator` asking for a real thumbnail only (`.thumbnail`, never the type
//   icon): nil when Quick Look has none, so the Home draws its own type icon.
//
// Sources are opened read-only (rule 27); only the output file in the thumbnail cache is written,
// atomically, by ThumbnailEncoder (Thumbnails/ThumbnailCore.swift). Nothing here logs names, paths
// or document text (rule 30) or opens a socket (rule 21).

import CoreGraphics
import Foundation
import QuickLookThumbnailing

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

enum QuickLookPolicy {
  /// Quick Look editing (Markup) is never allowed (V2-120): the iOS controller's
  /// `editingModeFor` answers `.disabled` and edited copies it reports are discarded.
  static let editingAllowed = false

  /// Type identifiers Quick Look previews on iOS and macOS (a type conforming to one of them is
  /// previewable). Plain archives and unknown (dynamic) types are not: they get the file card.
  static let previewableTypes: [String] = [
    "com.adobe.pdf",
    "public.text",  // plain text, CSV/TSV, source, JSON, XML, HTML, Markdown, logs
    "public.rtf",
    "com.apple.rtfd",
    "com.apple.flat-rtfd",
    "public.image",
    "public.audiovisual-content",
    "public.spreadsheet",
    "public.presentation",
    "org.openxmlformats.wordprocessingml.document",
    "org.openxmlformats.spreadsheetml.sheet",
    "org.openxmlformats.presentationml.presentation",
    "com.microsoft.word.doc",
    "com.microsoft.excel.xls",
    "com.microsoft.powerpoint.ppt",
    "com.apple.iwork.pages.sffpages",
    "com.apple.iwork.numbers.sffnumbers",
    "com.apple.iwork.keynote.sffkey",
    "com.apple.pages.pages",
    "com.apple.numbers.numbers",
    "com.apple.keynote.key",
    "org.idpf.epub-container",
    "com.pixar.universal-scene-description-mobile",
  ]

  /// The extensions treated as previewable when UTType can't be asked (pre-iOS 14 fallback).
  static let previewableExtensions: Set<String> = [
    "pdf", "txt", "text", "log", "md", "markdown", "csv", "tsv", "tab", "json", "xml", "html", "htm", "rtf", "rtfd",
    "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "jpg", "jpeg", "png", "heic", "heif",
    "gif", "tif", "tiff", "bmp", "mov", "mp4", "m4v", "mp3", "m4a", "wav", "aac", "epub", "usdz",
  ]

  /// The lower-case extension of [path] (empty when none).
  static func pathExtension(_ path: String) -> String { (path as NSString).pathExtension.lowercased() }

  /// True when Quick Look should be asked to preview a file with [uti] (preferred) or the
  /// extension of [name].
  static func isPreviewableType(uti: String?, name: String) -> Bool {
    #if canImport(UniformTypeIdentifiers)
    if #available(iOS 14.0, macOS 11.0, *) {
      var type: UTType?
      if let u = uti, !u.isEmpty, let t = UTType(u), !t.isDynamic { type = t }
      if type == nil, !pathExtension(name).isEmpty { type = UTType(filenameExtension: pathExtension(name)) }
      guard let type = type, !type.isDynamic else { return false }
      return previewableTypes.contains { id in UTType(id).map { type.conforms(to: $0) } ?? false }
    }
    #endif
    return previewableExtensions.contains(pathExtension(name))
  }

  /// The failure of a file Quick Look can't read at all, or nil when it is a readable regular file.
  static func fileProblem(_ path: String, fileManager: FileManager = .default) -> OutFailure? {
    guard path.hasPrefix("/") else { return .invalid("path is not absolute") }
    var isDir: ObjCBool = false
    guard fileManager.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return .notFound("no such file") }
    guard fileManager.isReadableFile(atPath: path) else { return .denied("file not readable") }
    return nil
  }

  /// True when the readable file at [path] is a type Quick Look previews.
  static func canPreview(path: String, displayName: String, uti: String?, fileManager: FileManager = .default) -> Bool {
    guard fileProblem(path, fileManager: fileManager) == nil else { return false }
    // The display name carries the user's extension; library files may be stored without one.
    return isPreviewableType(uti: uti, name: displayName) || isPreviewableType(uti: nil, name: path)
  }
}

/// Thumbnails of documents (PDF first pages, Quick Look thumbnails of everything else).
final class DocumentThumbnailer {
  /// Largest accepted screen scale.
  static let maxScale: Double = 8

  /// Waiting limit for Quick Look before a request answers nil.
  var timeout: TimeInterval = 20

  /// When false, non-PDF documents answer nil without asking Quick Look (tests).
  var useQuickLook = true

  init() {}

  /// The validation failure of a request, or nil when it is well-formed.
  static func validate(requestId: String, path: String, widthPx: Int64, heightPx: Int64, scale: Double, quality: Double, outputPath: String) -> ThumbnailFailure? {
    let side = Int64(ThumbnailGeometry.maxSide)
    if requestId.isEmpty { return .invalid("empty request id") }
    if widthPx < 1 || heightPx < 1 || widthPx > side || heightPx > side { return .invalid("box out of range") }
    if !scale.isFinite || scale <= 0 || scale > maxScale { return .invalid("scale out of range") }
    if !(0...1).contains(quality) { return .invalid("quality out of range") }
    if !path.hasPrefix("/") { return .invalid("document path is not absolute") }
    if !outputPath.hasPrefix("/") { return .invalid("output path is not absolute") }
    return nil
  }

  /// True when [url] is a PDF: by extension, or by the `%PDF-` header within the first 1 KB.
  static func isPDF(_ url: URL) -> Bool {
    if url.pathExtension.lowercased() == "pdf" { return true }
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    let head = handle.readData(ofLength: 1024)
    return head.range(of: Data("%PDF-".utf8)) != nil
  }

  /// The pixel size of a page of [points] drawn at [scale], shrunk to fit [box]; at least 1 px.
  static func pageSize(points: CGSize, scale: CGFloat, box: CGSize) -> CGSize {
    guard points.width > 0, points.height > 0 else { return CGSize(width: 1, height: 1) }
    let s = min(scale, box.width / points.width, box.height / points.height)
    return CGSize(width: max(1, (points.width * s).rounded()), height: max(1, (points.height * s).rounded()))
  }

  /// Writes the thumbnail of the document at [path] to [outputPath], or answers nil when there is
  /// none (password needed, damaged, nothing from Quick Look). Blocks the calling (background)
  /// thread; [token] cancels it.
  func generate(path: String, box: CGSize, scale: CGFloat, format: ThumbnailFileFormat, quality: Double, outputPath: String, token: ThumbnailCancelToken) throws -> ThumbnailOutput? {
    let url = URL(fileURLWithPath: path)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
      throw ThumbnailFailure.notFound("no such file")
    }
    guard FileManager.default.isReadableFile(atPath: url.path) else { throw ThumbnailFailure.permission("file not readable") }
    if token.isCancelled { throw ThumbnailFailure.cancelled() }
    let image: CGImage?
    if DocumentThumbnailer.isPDF(url) {
      image = try pdfFirstPage(url, box: box, scale: scale)
    } else if useQuickLook {
      image = try quickLook(url, box: box, scale: scale, token: token)
    } else {
      image = nil
    }
    if token.isCancelled { throw ThumbnailFailure.cancelled() }
    guard let cg = image else { return nil }
    return try ThumbnailEncoder.write(cg, box: box, fit: .fit, format: format, quality: quality, to: outputPath, token: token)
  }

  /// The first page of the PDF at [url] on white, [scale] pixels per point within [box]; nil when
  /// it is damaged, empty or needs a password (the empty password is tried).
  func pdfFirstPage(_ url: URL, box: CGSize, scale: CGFloat) throws -> CGImage? {
    guard let doc = CGPDFDocument(url as CFURL) else { return nil }
    if doc.isEncrypted && !doc.isUnlocked && !doc.unlockWithPassword("") { return nil }
    guard doc.isUnlocked, doc.numberOfPages >= 1, let page = doc.page(at: 1) else { return nil }
    let crop = page.getBoxRect(.cropBox)
    guard crop.width > 0, crop.height > 0 else { return nil }
    let rotation = ((page.rotationAngle % 360) + 360) % 360
    let turned = rotation == 90 || rotation == 270
    let points = turned ? CGSize(width: crop.height, height: crop.width) : crop.size
    let size = DocumentThumbnailer.pageSize(points: points, scale: scale, box: box)
    let w = Int(size.width), h = Int(size.height)
    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
      throw ThumbnailFailure.io("no bitmap context")
    }
    ctx.interpolationQuality = .high
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.scaleBy(x: CGFloat(w) / points.width, y: CGFloat(h) / points.height)
    // `rotationAngle` turns the page clockwise for display; CG's origin is bottom-left.
    switch rotation {
    case 90:
      ctx.translateBy(x: 0, y: crop.width)
      ctx.rotate(by: -.pi / 2)
    case 180:
      ctx.translateBy(x: crop.width, y: crop.height)
      ctx.rotate(by: .pi)
    case 270:
      ctx.translateBy(x: crop.height, y: 0)
      ctx.rotate(by: .pi / 2)
    default:
      break
    }
    ctx.translateBy(x: -crop.minX, y: -crop.minY)
    ctx.clip(to: crop)
    ctx.drawPDFPage(page)
    guard let out = ctx.makeImage() else { throw ThumbnailFailure.io("could not render") }
    return out
  }

  /// Quick Look's thumbnail of [url] (never its type icon), [scale] pixels per point within [box];
  /// nil when Quick Look has none in time.
  func quickLook(_ url: URL, box: CGSize, scale: CGFloat, token: ThumbnailCancelToken) throws -> CGImage? {
    let points = CGSize(width: max(1, box.width / scale), height: max(1, box.height / scale))
    let request = QLThumbnailGenerator.Request(fileAt: url, size: points, scale: scale, representationTypes: .thumbnail)
    let done = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var out: CGImage?
    let generator = QLThumbnailGenerator.shared
    token.onCancel { generator.cancel(request) }
    generator.generateBestRepresentation(for: request) { rep, _ in
      lock.lock()
      out = rep?.type == .thumbnail ? rep?.cgImage : nil
      lock.unlock()
      done.signal()
    }
    if done.wait(timeout: .now() + timeout) == .timedOut {
      generator.cancel(request)
      return nil
    }
    if token.isCancelled { throw ThumbnailFailure.cancelled() }
    lock.lock()
    defer { lock.unlock() }
    return out
  }
}
