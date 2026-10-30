// OWNER: HOM-31
// EXTENDED: S4-W (outPath is created exclusively through PdfNewFiles (Tools/PdfNewFiles.swift); a
// failed write deletes it only when this job created it, never a file that appeared there.)
//
// PDF compress on iOS and macOS (HOM plan §8.5, D-98j; BUILD_PLAN HOM-31), Flutter-free so its
// XCTests run on the iOS Simulator and macOS without the app (Tests/Compress/). Two stages:
//
// 1. PDFKit `write(to:withOptions:)` with `saveImagesAsJPEGOption` (every image re-encoded as
//    JPEG) and, for Medium and Small, `optimizeImagesForScreenOption` (images above about 144 dpi
//    downsampled) on iOS 16.4+ / macOS 13.4+, where the options exist. Text, fonts, vectors and
//    annotations are written back as they are: text stays selectable and searchable.
// 2. PDFKit has no JPEG quality and only one resolution step, so the three presets would collapse
//    into two (and High would leave a PDF of camera JPEGs as it is). [PdfImageRewriter] therefore
//    re-encodes the image XObjects of stage 1's file (Quartz writes a classic cross-reference
//    table) at the preset's JPEG quality and pixel scale, object by object: content streams, fonts
//    and every other object are copied byte for byte, so only pictures change. An image is
//    replaced only when that saves at least 10 %. Below iOS 16.4 / macOS 13.4 stage 1 is a plain
//    PDFKit write and stage 2 does all the work (scale 0.75 / 0.5 stands in for the screen step).
//
// The source is opened read-only (rule 27); intermediate files live in a private temporary
// directory that is always removed; only `outPath` is written, once, at the end (created
// exclusively), and never left on cancel or failure. An encrypted source is written back encrypted with the password it was
// opened with. Nothing is logged (rule 30).

import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Compression

/// The compression presets (pigeons/pdf_api.dart `PdfCompressPresetMsg`).
enum PdfCompressPreset: Int, CaseIterable {
  case high
  case medium
  case small
}

/// What one preset does.
struct PdfCompressSettings: Equatable {
  /// JPEG quality of re-encoded images (0…1).
  let jpegQuality: Double

  /// Pixel scale of re-encoded images (1 keeps their resolution).
  let scale: Double

  /// Ask PDFKit for `optimizeImagesForScreenOption` (about 144 dpi).
  let screen: Bool

  /// A replaced image must be at most this fraction of the original's bytes.
  static let minimumSaving = 0.9

  /// The settings of [preset]; [pdfKitOptions] says whether PDFKit's write options exist here.
  static func of(_ preset: PdfCompressPreset, pdfKitOptions: Bool = PdfCompressCore.pdfKitOptionsAvailable) -> PdfCompressSettings {
    switch preset {
    case .high: return PdfCompressSettings(jpegQuality: 0.75, scale: 1, screen: false)
    case .medium: return PdfCompressSettings(jpegQuality: 0.6, scale: pdfKitOptions ? 1 : 0.75, screen: true)
    case .small: return PdfCompressSettings(jpegQuality: 0.45, scale: pdfKitOptions ? 0.67 : 0.5, screen: true)
    }
  }
}

/// What a compress run wrote.
struct PdfCompressOutcome: Equatable {
  let pageCount: Int
  let sizeBytes: Int64
  /// Image XObjects stage 2 looked at and replaced (diagnostics for the tests).
  let imagesSeen: Int
  let imagesReplaced: Int
}

/// Estimated sizes of the three presets.
struct PdfCompressEstimate: Equatable {
  let sourceBytes: Int64
  /// Bytes per preset, in [PdfCompressPreset] order.
  let presetBytes: [Int64]
  /// True when the sizes come from a sample of pages; false when every page was compressed.
  let sampled: Bool
}

enum PdfCompressCore {
  /// PDFKit's JPEG and screen write options exist (iOS 16.4+, macOS 13.4+).
  static var pdfKitOptionsAvailable: Bool {
    if #available(iOS 16.4, macOS 13.4, *) { return true }
    return false
  }

  /// Files with at most this many pages are estimated by compressing all of them.
  static let fullEstimatePages = 4

  /// Compresses [path] with [preset] into the new file [outPath] (which must not exist).
  /// [isCancelled] is polled between stages and images; [progress] gets 0…1 from any thread.
  static func compress(
    path: String, password: String?, preset: PdfCompressPreset, outPath: String,
    isCancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in }
  ) throws -> PdfCompressOutcome {
    let out = URL(fileURLWithPath: outPath)
    guard !outPath.isEmpty, !FileManager.default.fileExists(atPath: outPath) else {
      throw PdfFailure(.invalidArgument, "output exists")
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: out.deletingLastPathComponent().path, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw PdfFailure(.invalidArgument, "no output directory")
    }
    let document = try PdfReader.open(path: path, password: password)
    guard !document.isLocked else { throw PdfFailure(.passwordRequired, "document is locked") }
    progress(0.02)
    // PDFKit writes an unlocked encrypted document back encrypted, which stage 2 can't read: the
    // pages are compressed from an unencrypted copy and the result encrypted again.
    let encrypted = document.isEncrypted
    let subject = encrypted ? decryptedCopy(of: document) : document
    let result = try compressedData(subject, settings: .of(preset), isCancelled: isCancelled) { progress(0.02 + 0.9 * $0) }
    var data = result.data
    if encrypted, let password, !password.isEmpty {
      data = try reencrypt(data, password: password)
    }
    if isCancelled() { throw PdfFailure(.cancelled, "cancelled") }
    // Created exclusively first (S4-W): a file that appeared at outPath since the check above is
    // never written over or deleted; on a failed write only the file this job created is removed.
    let files = PdfNewFiles()
    try files.claim(outPath)
    do {
      try data.write(to: out)
    } catch {
      files.removeAll()
      throw writeFailure(error)
    }
    progress(1)
    return PdfCompressOutcome(pageCount: document.pageCount, sizeBytes: Int64(data.count), imagesSeen: result.seen, imagesReplaced: result.replaced)
  }

  /// The sizes each preset would give for [path]: exact for short files, from up to four
  /// evenly spread pages otherwise (their compressed share of a plain write of the same pages).
  static func estimate(path: String, password: String?, isCancelled: () -> Bool = { false }) throws -> PdfCompressEstimate {
    let opened = try PdfReader.open(path: path, password: password)
    guard !opened.isLocked else { throw PdfFailure(.passwordRequired, "document is locked") }
    let document = opened.isEncrypted ? decryptedCopy(of: opened) : opened
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    let sourceBytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    let count = document.pageCount
    let sampled = count > fullEstimatePages
    let subject: PDFDocument
    var baseline = Double(sourceBytes)
    if sampled {
      let sample = PDFDocument()
      let picks = Array(Set((0..<fullEstimatePages).map { $0 * (count - 1) / (fullEstimatePages - 1) })).sorted()
      for index in picks {
        guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
        sample.insert(page, at: sample.pageCount)
      }
      guard sample.pageCount > 0, let plain = sample.dataRepresentation() else { throw PdfFailure(.damaged, "no pages to sample") }
      subject = PDFDocument(data: plain) ?? sample
      baseline = Double(plain.count)
    } else {
      subject = document
    }
    var sizes: [Int64] = []
    for preset in PdfCompressPreset.allCases {
      if isCancelled() { throw PdfFailure(.cancelled, "cancelled") }
      let bytes = Double(try compressedData(subject, settings: .of(preset), isCancelled: isCancelled) { _ in }.data.count)
      let ratio = baseline > 0 ? bytes / baseline : 1
      sizes.append(Int64((Double(sourceBytes) * ratio).rounded()))
    }
    return PdfCompressEstimate(sourceBytes: sourceBytes, presetBytes: sizes, sampled: sampled)
  }

  /// Stage 1 and 2 on an open, unlocked [document]; the result opens in PDFKit with the same
  /// page count (else the stage 1 file is used).
  static func compressedData(
    _ document: PDFDocument, settings: PdfCompressSettings, isCancelled: () -> Bool, progress: (Double) -> Void
  ) throws -> (data: Data, seen: Int, replaced: Int) {
    if isCancelled() { throw PdfFailure(.cancelled, "cancelled") }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dv_pdf_compress_\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let stage1 = dir.appendingPathComponent("stage1.pdf")
    var options: [PDFDocumentWriteOption: Any] = [:]
    if #available(iOS 16.4, macOS 13.4, *) {
      options[.saveImagesAsJPEGOption] = true
      if settings.screen { options[.optimizeImagesForScreenOption] = true }
    }
    guard document.write(to: stage1, withOptions: options) else { throw PdfFailure(.ioError, "write failed") }
    progress(0.45)
    if isCancelled() { throw PdfFailure(.cancelled, "cancelled") }
    let written = try Data(contentsOf: stage1, options: .alwaysMapped)
    let rewrite = try PdfImageRewriter.rewrite(written, settings: settings, isCancelled: isCancelled) { progress(0.45 + 0.5 * $0) }
    if let rewrite, rewrite.replaced > 0, let check = PDFDocument(data: rewrite.data), check.pageCount == document.pageCount {
      progress(1)
      return (rewrite.data, rewrite.seen, rewrite.replaced)
    }
    progress(1)
    return (Data(written), rewrite?.seen ?? 0, 0)
  }

  /// An unencrypted document with copies of [document]'s pages, its attributes and its outline
  /// (destinations moved to the copied pages).
  static func decryptedCopy(of document: PDFDocument) -> PDFDocument {
    let copy = PDFDocument()
    var pages: [PDFPage] = []
    for index in 0..<document.pageCount {
      guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
      copy.insert(page, at: copy.pageCount)
      pages.append(page)
    }
    copy.documentAttributes = document.documentAttributes
    if let root = document.outlineRoot, pages.count == document.pageCount {
      func clone(_ node: PDFOutline) -> PDFOutline {
        let out = PDFOutline()
        out.label = node.label
        out.isOpen = node.isOpen
        if let destination = node.destination, let page = destination.page {
          let index = document.index(for: page)
          if index >= 0, index < pages.count { out.destination = PDFDestination(page: pages[index], at: destination.point) }
        }
        for i in 0..<node.numberOfChildren {
          if let child = node.child(at: i) { out.insertChild(clone(child), at: out.numberOfChildren) }
        }
        return out
      }
      copy.outlineRoot = clone(root)
    }
    return copy
  }

  /// [data] written again, encrypted with [password] as both user and owner password.
  static func reencrypt(_ data: Data, password: String) throws -> Data {
    guard let document = PDFDocument(data: data) else { throw PdfFailure(.internal, "re-open failed") }
    let options: [PDFDocumentWriteOption: Any] = [.userPasswordOption: password, .ownerPasswordOption: password]
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dv_pdf_compress_\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("encrypted.pdf")
    guard document.write(to: url, withOptions: options) else { throw PdfFailure(.ioError, "encrypt failed") }
    return try Data(contentsOf: url)
  }

  private static func writeFailure(_ error: Error) -> PdfFailure {
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError { return PdfFailure(.noSpace, "out of space") }
    if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) { return PdfFailure(.noSpace, "out of space") }
    return PdfFailure(.ioError, "write failed")
  }
}

// MARK: - Stage 2: image XObjects

/// Re-encodes the image XObjects of a PDF with a classic cross-reference table (what Quartz and
/// PDFKit write) and copies every other object byte for byte. Answers nil for a file it does not
/// handle (cross-reference streams, incremental updates, encryption): the caller then keeps the
/// file as it is.
enum PdfImageRewriter {
  /// Images smaller than this on their short side are left alone (icons, rules).
  static let minimumSide = 16

  /// Images with more pixels than this are left alone (memory).
  static let maximumPixels = 80_000_000

  struct Result {
    let data: Data
    let seen: Int
    let replaced: Int
  }

  static func rewrite(_ data: Data, settings: PdfCompressSettings, isCancelled: () -> Bool, progress: (Double) -> Void) throws -> Result? {
    let bytes = [UInt8](data)
    guard let file = PdfObjectFile(bytes) else { return nil }
    let images = file.objects.filter { file.isImage($0) }
    let masks = file.softMaskTargets()
    var replacements: [Int: [UInt8]] = [:]
    var seen = 0
    for (i, object) in images.enumerated() {
      if isCancelled() { throw PdfFailure(.cancelled, "cancelled") }
      progress(Double(i) / Double(max(1, images.count)))
      guard !masks.contains(object.number) else { continue }
      seen += 1
      if let segment = autoreleasepool(invoking: { reencode(object, in: file, settings: settings) }) {
        replacements[object.number] = segment
      }
    }
    progress(1)
    guard !replacements.isEmpty else { return Result(data: data, seen: seen, replaced: 0) }
    return Result(data: file.assemble(replacing: replacements), seen: seen, replaced: replacements.count)
  }

  /// The new object text of [object], or nil to keep it.
  static func reencode(_ object: PdfObjectFile.Object, in file: PdfObjectFile, settings: PdfCompressSettings) -> [UInt8]? {
    guard let dict = object.dict, let stream = file.streamData(object) else { return nil }
    let keys = Set(dict.map(\.key))
    // Masks, decode arrays and colour-key masking change what the samples mean; leave them be.
    for key in ["/ImageMask", "/Mask", "/Decode", "/SMaskInData", "/DecodeParms", "/Alternates"] where keys.contains(key) {
      if key == "/ImageMask", file.value(dict, key) == "false" { continue }
      return nil
    }
    guard let width = file.int(dict, "/Width"), let height = file.int(dict, "/Height"),
          width >= minimumSide, height >= minimumSide, width * height <= maximumPixels else { return nil }
    guard let components = file.colorComponents(dict) else { return nil }
    let filter = file.value(dict, "/Filter")?.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let image: CGImage
    switch filter {
    case "/DCTDecode":
      guard let source = CGImageSourceCreateWithData(Data(stream) as CFData, nil),
            let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
            decoded.width == width, decoded.height == height,
            decoded.colorSpace?.numberOfComponents == components else { return nil }
      image = decoded
    case "/FlateDecode":
      guard file.int(dict, "/BitsPerComponent") == 8,
            let raw = inflate(stream, expected: width * height * components),
            let decoded = rawImage(raw, width: width, height: height, components: components) else { return nil }
      image = decoded
    default:
      return nil // JPX, JBIG2, CCITT, LZW, run-length, uncompressed: already small or not worth it
    }
    let scale = min(1, max(0.05, settings.scale))
    let targetWidth = max(1, Int((Double(width) * scale).rounded()))
    let targetHeight = max(1, Int((Double(height) * scale).rounded()))
    guard let resampled = resample(image, width: targetWidth, height: targetHeight, components: components),
          let jpeg = encodeJpeg(resampled, quality: settings.jpegQuality),
          Double(jpeg.count) <= Double(stream.count) * PdfCompressSettings.minimumSaving else { return nil }
    var entries: [(String, String)] = []
    let replaced: Set<String> = ["/Width", "/Height", "/Length", "/Filter", "/DecodeParms", "/BitsPerComponent"]
    for (key, value) in dict where !replaced.contains(key) {
      entries.append((key, value))
    }
    entries += [("/Width", "\(targetWidth)"), ("/Height", "\(targetHeight)"), ("/BitsPerComponent", "8"),
                ("/Filter", "/DCTDecode"), ("/Length", "\(jpeg.count)")]
    let head = "\(object.number) \(object.generation) obj\n<< " + entries.map { "\($0.0) \($0.1)" }.joined(separator: " ") + " >>\nstream\n"
    return Array(head.utf8) + jpeg + Array("\nendstream\nendobj\n".utf8)
  }

  /// Inflates a zlib stream to exactly [expected] bytes, or nil.
  static func inflate(_ input: ArraySlice<UInt8>, expected: Int) -> [UInt8]? {
    guard input.count > 6, expected > 0 else { return nil }
    let start = input.startIndex
    let cmf = input[start], flags = input[start + 1]
    // A zlib header: deflate, no preset dictionary.
    guard cmf & 0x0F == 8, (UInt16(cmf) << 8 | UInt16(flags)) % 31 == 0, flags & 0x20 == 0 else { return nil }
    var output = [UInt8](repeating: 0, count: expected + 1)
    let written = input.withUnsafeBufferPointer { src -> Int in
      output.withUnsafeMutableBufferPointer { dst in
        compression_decode_buffer(dst.baseAddress!, dst.count, src.baseAddress! + 2, src.count - 2, nil, COMPRESSION_ZLIB)
      }
    }
    guard written == expected else { return nil }
    output.removeLast()
    return output
  }

  static func rawImage(_ raw: [UInt8], width: Int, height: Int, components: Int) -> CGImage? {
    let space = components == 3 ? CGColorSpaceCreateDeviceRGB() : CGColorSpaceCreateDeviceGray()
    guard let provider = CGDataProvider(data: Data(raw) as CFData) else { return nil }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * components, bytesPerRow: width * components,
      space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
      decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }

  /// [image] drawn at [width] × [height] in a device RGB or grey bitmap (no alpha).
  static func resample(_ image: CGImage, width: Int, height: Int, components: Int) -> CGImage? {
    let rgb = components == 3
    guard let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: rgb ? CGColorSpaceCreateDeviceRGB() : CGColorSpaceCreateDeviceGray(),
      bitmapInfo: rgb ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.none.rawValue)
    else { return nil }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
  }

  /// Baseline JPEG bytes of [image] without metadata segments (EXIF, ICC, Photoshop), which a PDF
  /// image ignores: its colour space is in the XObject dictionary.
  static func encodeJpeg(_ image: CGImage, quality: Double) -> [UInt8]? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return stripMetadata([UInt8](data as Data))
  }

  /// [jpeg] without APP1, APP2 and APP13 segments.
  static func stripMetadata(_ jpeg: [UInt8]) -> [UInt8] {
    guard jpeg.count > 4, jpeg[0] == 0xFF, jpeg[1] == 0xD8 else { return jpeg }
    var out: [UInt8] = [0xFF, 0xD8]
    var i = 2
    while i + 4 <= jpeg.count, jpeg[i] == 0xFF {
      let marker = jpeg[i + 1]
      if marker == 0xDA { break } // start of scan: the rest is entropy-coded data
      let length = Int(jpeg[i + 2]) << 8 | Int(jpeg[i + 3])
      guard length >= 2, i + 2 + length <= jpeg.count else { return jpeg }
      if marker != 0xE1, marker != 0xE2, marker != 0xED { out += jpeg[i..<(i + 2 + length)] }
      i += 2 + length
    }
    out += jpeg[i...]
    return out
  }
}

// MARK: - A PDF with a classic cross-reference table

/// The objects of a PDF whose last section is a classic `xref` table without `/Prev`, `/XRefStm`
/// or `/Encrypt`, located through that table (never by scanning the bytes, which streams can
/// fool), and its re-assembly with some objects replaced.
struct PdfObjectFile {
  struct Object {
    let number: Int
    let generation: Int
    let offset: Int
    let end: Int
    /// The dictionary entries (key, raw value text) of a dictionary or stream object.
    let dict: [(key: String, value: String)]?
    /// Where the dictionary ends (the stream keyword follows for a stream).
    let dictEnd: Int
  }

  let bytes: [UInt8]
  let objects: [Object]
  let byNumber: [Int: Object]
  let headerEnd: Int
  let trailer: ArraySlice<UInt8>
  let size: Int

  init?(_ bytes: [UInt8]) {
    self.bytes = bytes
    let lexer = PdfLexer(bytes)
    guard let startxref = lexer.lastIndex(of: "startxref", within: 2048),
          let (xrefText, afterNumber) = lexer.token(at: startxref + 9), let xref = Int(xrefText), afterNumber <= bytes.count,
          xref > 0, xref < startxref, lexer.token(at: xref)?.0 == "xref" else { return nil }
    var i = xref + 4
    var entries: [(number: Int, generation: Int, offset: Int)] = []
    while true {
      guard let (first, next) = lexer.token(at: i) else { return nil }
      if first == "trailer" { i = next; break }
      guard let start = Int(first), let (countText, afterCount) = lexer.token(at: next), let count = Int(countText), count >= 0, count < 10_000_000 else { return nil }
      i = afterCount
      for k in 0..<count {
        guard let (offsetText, a) = lexer.token(at: i), let (genText, b) = lexer.token(at: a), let (kind, c) = lexer.token(at: b),
              let offset = Int(offsetText), let generation = Int(genText) else { return nil }
        i = c
        if kind == "n", offset > 0 { entries.append((start + k, generation, offset)) } else if kind != "f" { return nil }
      }
    }
    let dictStart = lexer.skipSpace(i)
    guard dictStart + 1 < bytes.count, bytes[dictStart] == UInt8(ascii: "<"), bytes[dictStart + 1] == UInt8(ascii: "<"),
          let trailerEnd = lexer.valueEnd(dictStart), let trailerDict = lexer.dictEntries(dictStart) else { return nil }
    let trailerKeys = Set(trailerDict.map(\.key))
    guard !trailerKeys.contains("/Prev"), !trailerKeys.contains("/XRefStm"), !trailerKeys.contains("/Encrypt"),
          let sizeText = trailerDict.first(where: { $0.key == "/Size" })?.value, let size = Int(sizeText) else { return nil }
    trailer = bytes[dictStart..<trailerEnd]
    self.size = size
    let sorted = entries.sorted { $0.offset < $1.offset }
    guard let first = sorted.first, Set(sorted.map(\.offset)).count == sorted.count, sorted.last!.offset < xref,
          sorted.allSatisfy({ $0.number < size }) else { return nil }
    headerEnd = first.offset
    var objects: [Object] = []
    for (index, entry) in sorted.enumerated() {
      let end = index + 1 < sorted.count ? sorted[index + 1].offset : xref
      guard let (numberText, a) = lexer.token(at: entry.offset), Int(numberText) == entry.number,
            let (genText, b) = lexer.token(at: a), Int(genText) == entry.generation,
            let (keyword, c) = lexer.token(at: b), keyword == "obj" else { return nil }
      let body = lexer.skipSpace(c)
      var dict: [(key: String, value: String)]?
      var dictEnd = body
      if body + 1 < end, bytes[body] == UInt8(ascii: "<"), bytes[body + 1] == UInt8(ascii: "<") {
        guard let e = lexer.valueEnd(body), e <= end else { return nil }
        dict = lexer.dictEntries(body)
        dictEnd = e
      }
      objects.append(Object(number: entry.number, generation: entry.generation, offset: entry.offset, end: end, dict: dict, dictEnd: dictEnd))
    }
    self.objects = objects
    byNumber = Dictionary(objects.map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
  }

  /// The raw value of [key] in [dict].
  func value(_ dict: [(key: String, value: String)], _ key: String) -> String? {
    dict.first(where: { $0.key == key })?.value
  }

  /// The integer value of [key], following an indirect reference.
  func int(_ dict: [(key: String, value: String)], _ key: String) -> Int? {
    guard let raw = value(dict, key) else { return nil }
    if let v = Int(raw) { return v }
    guard let target = resolve(raw) else { return nil }
    let lexer = PdfLexer(bytes)
    guard let (numberText, a) = lexer.token(at: target.offset), Int(numberText) != nil,
          let (_, b) = lexer.token(at: a), let (_, c) = lexer.token(at: b), let (text, _) = lexer.token(at: c) else { return nil }
    return Int(text)
  }

  /// The object an `N G R` reference names.
  func resolve(_ reference: String) -> Object? {
    let parts = reference.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" })
    guard parts.count == 3, parts[2] == "R", let number = Int(parts[0]) else { return nil }
    return byNumber[number]
  }

  func isImage(_ object: Object) -> Bool {
    guard let dict = object.dict else { return false }
    return value(dict, "/Subtype") == "/Image"
  }

  /// Objects used as an image's `/SMask` (alpha stays lossless).
  func softMaskTargets() -> Set<Int> {
    var out = Set<Int>()
    for object in objects {
      if let dict = object.dict, let raw = value(dict, "/SMask"), let target = resolve(raw) { out.insert(target.number) }
    }
    return out
  }

  /// The stream data of [object], or nil when it is not a stream.
  func streamData(_ object: Object) -> ArraySlice<UInt8>? {
    guard let dict = object.dict, let length = int(dict, "/Length"), length >= 0 else { return nil }
    let lexer = PdfLexer(bytes)
    guard let (keyword, after) = lexer.token(at: object.dictEnd), keyword == "stream" else { return nil }
    var start = after
    if start < bytes.count, bytes[start] == 13 { start += 1 }
    if start < bytes.count, bytes[start] == 10 { start += 1 }
    guard start + length <= object.end else { return nil }
    return bytes[start..<(start + length)]
  }

  /// The colour components of an image's `/ColorSpace` (1 or 3), or nil for one stage 2 leaves
  /// alone (CMYK, indexed, separation, Lab, …).
  func colorComponents(_ dict: [(key: String, value: String)]) -> Int? {
    guard var raw = value(dict, "/ColorSpace") else { return nil }
    if let target = resolve(raw) {
      let lexer = PdfLexer(bytes)
      guard let (_, a) = lexer.token(at: target.offset), let (_, b) = lexer.token(at: a), let (_, c) = lexer.token(at: b) else { return nil }
      let start = lexer.skipSpace(c)
      guard let end = lexer.valueEnd(start), end <= target.end else { return nil }
      raw = String(decoding: bytes[start..<end], as: UTF8.self)
    }
    let compact = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    switch compact {
    case "/DeviceRGB", "/RGB": return 3
    case "/DeviceGray", "/G": return 1
    default: break
    }
    guard compact.hasPrefix("[") else { return nil }
    let inner = compact.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
    if inner.hasPrefix("/CalRGB") { return 3 }
    if inner.hasPrefix("/CalGray") { return 1 }
    if inner.hasPrefix("/ICCBased") {
      let reference = inner.dropFirst("/ICCBased".count).trimmingCharacters(in: .whitespacesAndNewlines)
      guard let profile = resolve(reference), let profileDict = profile.dict, let n = int(profileDict, "/N"), n == 1 || n == 3 else { return nil }
      return n
    }
    return nil
  }

  /// The file with [replacements] (object number → new object text) and a rebuilt
  /// cross-reference table; the header, every other object and the trailer are copied.
  func assemble(replacing replacements: [Int: [UInt8]]) -> Data {
    var out = Data(capacity: bytes.count)
    out.append(contentsOf: bytes[0..<headerEnd])
    var offsets: [Int: (Int, Int)] = [:]
    for object in objects {
      offsets[object.number] = (out.count, object.generation)
      if let replacement = replacements[object.number] {
        out.append(contentsOf: replacement)
      } else {
        out.append(contentsOf: bytes[object.offset..<object.end])
      }
    }
    let xref = out.count
    var table = "xref\n0 \(size)\n"
    table.reserveCapacity(20 * size + 32)
    for number in 0..<size {
      if let (offset, generation) = offsets[number] {
        table += String(format: "%010d %05d n\r\n", offset, generation)
      } else {
        table += number == 0 ? "0000000000 65535 f\r\n" : "0000000000 00000 f\r\n"
      }
    }
    table += "trailer\n"
    out.append(contentsOf: Array(table.utf8))
    out.append(contentsOf: trailer)
    out.append(contentsOf: Array("\nstartxref\n\(xref)\n%%EOF\n".utf8))
    return out
  }
}

/// A minimal PDF tokenizer: white space, comments, names, numbers, keywords, strings, arrays and
/// dictionaries, enough to find values and their extents.
struct PdfLexer {
  let b: [UInt8]

  init(_ bytes: [UInt8]) { b = bytes }

  static func isSpace(_ c: UInt8) -> Bool { c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32 }

  static func isDelimiter(_ c: UInt8) -> Bool {
    switch c {
    case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "<"), UInt8(ascii: ">"), UInt8(ascii: "["), UInt8(ascii: "]"),
         UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "/"), UInt8(ascii: "%"):
      return true
    default:
      return false
    }
  }

  func skipSpace(_ start: Int) -> Int {
    var i = start
    while i < b.count {
      if PdfLexer.isSpace(b[i]) {
        i += 1
      } else if b[i] == UInt8(ascii: "%") {
        while i < b.count, b[i] != 10, b[i] != 13 { i += 1 }
      } else {
        break
      }
    }
    return i
  }

  /// The regular token (number or keyword) at [start] after white space, and where it ends.
  func token(at start: Int) -> (String, Int)? {
    let i = skipSpace(start)
    var j = i
    while j < b.count, !PdfLexer.isSpace(b[j]), !PdfLexer.isDelimiter(b[j]) { j += 1 }
    guard j > i else { return nil }
    return (String(decoding: b[i..<j], as: UTF8.self), j)
  }

  /// The start of the last [keyword] in the final [within] bytes.
  func lastIndex(of keyword: String, within: Int) -> Int? {
    let k = Array(keyword.utf8)
    var i = b.count - k.count
    let stop = max(0, b.count - within)
    while i >= stop {
      if b[i] == k[0], Array(b[i..<(i + k.count)]) == k { return i }
      i -= 1
    }
    return nil
  }

  /// Where the value starting at [start] (after white space) ends.
  func valueEnd(_ start: Int) -> Int? {
    var i = skipSpace(start)
    guard i < b.count else { return nil }
    switch b[i] {
    case UInt8(ascii: "/"):
      i += 1
      while i < b.count, !PdfLexer.isSpace(b[i]), !PdfLexer.isDelimiter(b[i]) { i += 1 }
      return i
    case UInt8(ascii: "<"):
      if i + 1 < b.count, b[i + 1] == UInt8(ascii: "<") {
        i += 2
        while true {
          i = skipSpace(i)
          guard i + 1 < b.count else { return nil }
          if b[i] == UInt8(ascii: ">"), b[i + 1] == UInt8(ascii: ">") { return i + 2 }
          guard let next = valueEnd(i) else { return nil }
          i = next
        }
      }
      while i < b.count, b[i] != UInt8(ascii: ">") { i += 1 }
      return i < b.count ? i + 1 : nil
    case UInt8(ascii: "["):
      i += 1
      while true {
        i = skipSpace(i)
        guard i < b.count else { return nil }
        if b[i] == UInt8(ascii: "]") { return i + 1 }
        guard let next = valueEnd(i) else { return nil }
        i = next
      }
    case UInt8(ascii: "("):
      var depth = 0
      while i < b.count {
        let c = b[i]
        if c == UInt8(ascii: "\\") {
          i += 2
          continue
        }
        if c == UInt8(ascii: "(") { depth += 1 }
        if c == UInt8(ascii: ")") {
          depth -= 1
          if depth == 0 { return i + 1 }
        }
        i += 1
      }
      return nil
    case UInt8(ascii: ")"), UInt8(ascii: ">"), UInt8(ascii: "]"), UInt8(ascii: "{"), UInt8(ascii: "}"):
      return nil
    default:
      return token(at: i)?.1
    }
  }

  /// The entries of the dictionary at [start]: keys and raw values (`N G R` references joined).
  func dictEntries(_ start: Int) -> [(key: String, value: String)]? {
    var i = skipSpace(start)
    guard i + 1 < b.count, b[i] == UInt8(ascii: "<"), b[i + 1] == UInt8(ascii: "<") else { return nil }
    i += 2
    var out: [(key: String, value: String)] = []
    while true {
      i = skipSpace(i)
      guard i + 1 < b.count else { return nil }
      if b[i] == UInt8(ascii: ">"), b[i + 1] == UInt8(ascii: ">") { return out }
      guard b[i] == UInt8(ascii: "/"), let keyEnd = valueEnd(i) else { return nil }
      let key = String(decoding: b[i..<keyEnd], as: UTF8.self)
      let valueStart = skipSpace(keyEnd)
      guard var valueEnd = valueEnd(valueStart) else { return nil }
      // `N G R`: two integers and the R keyword make one value.
      if let (first, _) = token(at: valueStart), Int(first) != nil,
         let (second, afterSecond) = token(at: valueEnd), Int(second) != nil,
         let (r, afterR) = token(at: afterSecond), r == "R" {
        valueEnd = afterR
      }
      out.append((key, String(decoding: b[valueStart..<valueEnd], as: UTF8.self)))
      i = valueEnd
    }
  }
}
