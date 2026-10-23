// OWNER: HOM-02
//
// Pure helpers of the PhotoKit library, unit-tested without a photo library: change tokens and
// page windows (PhotoSnapshotBook), type mapping (UTI → MIME, RAW detection; closes the Apple half
// of V2-V2: HEIC, AVIF, RAW, Live), create-new file naming for copies (rule 26) and the album
// listing filter (photo-only albums, parity with Android 5ee89f2).

import Foundation

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
#if canImport(CoreServices)
import CoreServices
#endif

/// Change tokens of the cached fetch snapshots and the page window arithmetic.
///
/// The token is one generation counter for the whole library: it moves when a change inserts,
/// removes or moves assets of any cached fetch (indices shift) or when PhotoKit could not describe
/// a change incrementally. A change that only updates assets in place (favourite, edit) keeps the
/// token, so a pager can refresh those cells without restarting.
struct PhotoSnapshotBook {
  private(set) var generation: Int64 = 1

  /// The current token.
  var token: String { "g\(generation)" }

  /// True when [token] is set and is not the current one.
  func isStale(_ token: String?) -> Bool {
    guard let token = token else { return false }
    return token != self.token
  }

  /// Records a change; returns the token pages carry from now on.
  @discardableResult
  mutating func record(shiftsIndices: Bool) -> String {
    if shiftsIndices { generation += 1 }
    return token
  }

  /// The index range of a page request against a fetch of [count] assets. Offsets past the end give
  /// an empty range; [limit] is clamped to 1…500.
  static func window(offset: Int, limit: Int, count: Int) throws -> Range<Int> {
    guard offset >= 0 else { throw PhotoLibraryFailure(.invalidArgument, "offset < 0") }
    guard limit > 0 else { throw PhotoLibraryFailure(.invalidArgument, "limit < 1") }
    let clamped = min(limit, 500)
    let start = min(offset, count)
    let end = min(count, start + clamped)
    return start..<end
  }
}

/// Type mapping for PhotoKit resources.
enum PhotoTypes {
  /// UTIs of RAW captures PhotoKit reports (as `public.camera-raw-image` or vendor types).
  static let rawUtis: Set<String> = [
    "public.camera-raw-image", "com.adobe.raw-image", "com.canon.cr2-raw-image", "com.canon.cr3-raw-image",
    "com.canon.crw-raw-image", "com.nikon.raw-image", "com.nikon.nrw-raw-image", "com.sony.arw-raw-image",
    "com.sony.raw-image", "com.sony.sr2-raw-image", "com.fuji.raw-image", "com.olympus.raw-image",
    "com.olympus.or-raw-image", "com.panasonic.raw-image", "com.panasonic.rw2-raw-image", "com.pentax.raw-image",
    "com.leica.raw-image", "com.leica.rwl-raw-image", "com.hasselblad.3fr-raw-image",
    "com.hasselblad.fff-raw-image", "com.samsung.raw-image", "com.phaseone.raw-image", "com.epson.raw-image",
    "com.konicaminolta.raw-image", "com.kodak.raw-image", "com.apple.proraw",
  ]

  /// MIME types of the UTIs PhotoKit commonly reports, for systems without `UTType`.
  static let mimeByUti: [String: String] = [
    "public.jpeg": "image/jpeg",
    "public.heic": "image/heic",
    "public.heif": "image/heif",
    "public.avif": "image/avif",
    "public.avci": "image/avci",
    "public.png": "image/png",
    "com.compuserve.gif": "image/gif",
    "public.tiff": "image/tiff",
    "org.webmproject.webp": "image/webp",
    "com.microsoft.bmp": "image/bmp",
    "com.adobe.raw-image": "image/x-adobe-dng",
    "com.canon.cr2-raw-image": "image/x-canon-cr2",
    "com.canon.cr3-raw-image": "image/x-canon-cr3",
    "com.nikon.raw-image": "image/x-nikon-nef",
    "com.sony.arw-raw-image": "image/x-sony-arw",
    "com.fuji.raw-image": "image/x-fuji-raf",
    "com.olympus.or-raw-image": "image/x-olympus-orf",
    "com.panasonic.rw2-raw-image": "image/x-panasonic-rw2",
    "com.apple.quicktime-movie": "video/quicktime",
    "public.mpeg-4": "video/mp4",
    "com.apple.m4v-video": "video/x-m4v",
    "public.avi": "video/x-msvideo",
    "public.3gpp": "video/3gpp",
  ]

  /// True for a RAW capture UTI.
  static func isRaw(uti: String?) -> Bool {
    guard let uti = uti else { return false }
    if rawUtis.contains(uti) { return true }
    #if canImport(UniformTypeIdentifiers)
    if #available(iOS 14.0, macOS 11.0, *), let type = UTType(uti), let raw = UTType("public.camera-raw-image") {
      return type.conforms(to: raw)
    }
    #endif
    return uti.hasSuffix("raw-image")
  }

  /// The MIME type of [uti], or nil.
  static func mimeType(uti: String?) -> String? {
    guard let uti = uti else { return nil }
    if let known = mimeByUti[uti] { return known }
    #if canImport(UniformTypeIdentifiers)
    if #available(iOS 14.0, macOS 11.0, *), let mime = UTType(uti)?.preferredMIMEType { return mime }
    #endif
    return nil
  }

  /// The MIME type of a file name's extension (fallback when a resource has no usable UTI).
  static func mimeType(fileName: String?) -> String? {
    guard let ext = fileName.map({ ($0 as NSString).pathExtension.lowercased() }), !ext.isEmpty else { return nil }
    #if canImport(UniformTypeIdentifiers)
    if #available(iOS 14.0, macOS 11.0, *), let mime = UTType(filenameExtension: ext)?.preferredMIMEType { return mime }
    #endif
    switch ext {
    case "jpg", "jpeg": return "image/jpeg"
    case "heic": return "image/heic"
    case "heif": return "image/heif"
    case "avif": return "image/avif"
    case "png": return "image/png"
    case "dng": return "image/x-adobe-dng"
    case "mov": return "video/quicktime"
    case "mp4": return "video/mp4"
    default: return nil
    }
  }
}

/// Create-new file naming inside an app directory (copies never overwrite, rule 26).
enum CopyNaming {
  /// [name] reduced to a safe single path component (no separators, no leading dots), or
  /// [fallback] when nothing is left.
  static func sanitize(_ name: String?, fallback: String) -> String {
    var s = (name ?? "").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
    s = s.replacingOccurrences(of: "\0", with: "")
    while s.hasPrefix(".") { s.removeFirst() }
    s = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.count > 200 {
      let ext = (s as NSString).pathExtension
      let base = String((s as NSString).deletingPathExtension.prefix(180))
      s = ext.isEmpty ? base : "\(base).\(ext)"
    }
    return s.isEmpty ? fallback : s
  }

  /// The first of `name`, `name (2).ext`, `name (3).ext`, … for which [exists] is false.
  static func unique(directory: String, name: String, exists: (String) -> Bool) -> String? {
    let dir = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
    let ext = (name as NSString).pathExtension
    let base = (name as NSString).deletingPathExtension
    for n in 1...999 {
      let candidate = n == 1 ? name : (ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
      let path = "\(dir)/\(candidate)"
      if !exists(path) { return path }
    }
    return nil
  }
}

/// Which albums `fetchAlbums` lists (HOM-02; parity with Android 5ee89f2): only albums that hold
/// photos, counted by their photos. Video-only and empty albums are left out (a page of one can
/// still be fetched by id), as are the hidden album and the library itself (smart "Recents" /
/// "All Photos", which the library tab already is).
enum PhotoAlbumListing {
  /// One collection PhotoKit returned, reduced to what the filter needs.
  struct Candidate: Equatable {
    var albumId: String
    var title: String?
    var isSmart: Bool
    var isCloudShared: Bool
    /// The hidden album or the user library smart album.
    var isExcludedSmart: Bool
    /// Its photos (images only; videos do not count).
    var photoCount: Int
  }

  /// The records of [candidates] that hold photos, in order.
  static func records(_ candidates: [Candidate]) -> [PhotoAlbumRecord] {
    candidates.compactMap { c in
      if c.isSmart && c.isExcludedSmart { return nil }
      guard c.photoCount > 0 else { return nil }
      let kind: PhotoAlbumKind = c.isSmart ? .smart : (c.isCloudShared ? .shared : .user)
      return PhotoAlbumRecord(albumId: c.albumId, title: c.title ?? "", kind: kind, estimatedCount: c.photoCount)
    }
  }
}
