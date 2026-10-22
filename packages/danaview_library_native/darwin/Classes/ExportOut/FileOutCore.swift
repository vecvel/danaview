// OWNER: HOM-22
//
// The Flutter-free core of getting files out on Apple (ARCH v1.2 §8 "Getting files out", rule 26,
// V2-117, V2-118; HOM plan §8.3), shared by ExportOut/, Share/ and OpenIn/:
//
// * OutFile and OutFailure: one file handed out and the failures (codes are LibraryErrorCode names).
// * TempCopyStore: share sheets and "Open in another app" never receive a library file. Each
//   request gets its own batch directory under `<tmp>/danaview-out/`, holding create-new copies
//   with the names the receiver should see, made read-only (0444) so nothing outside Danaview can
//   change the library copy. The batch is removed when the system UI finishes; batches a crash or
//   a long-lived "Open in" left behind are swept on the next start (older than a day).
// * exportCopy / uniqueDestination: save-out into a folder the user picked writes create-new
//   copies only (`Name (2).ext` when the name is taken) and never moves, renames or rewrites the
//   source (rule 26).
//
// Nothing here logs; failure messages carry no names or paths (rule 30).

import Foundation

/// A failure of a file-out operation; `code` is a `LibraryErrorCode` name.
struct OutFailure: Error, Equatable {
  let code: String
  let message: String

  static func notFound(_ m: String) -> OutFailure { OutFailure(code: "notFound", message: m) }
  static func io(_ m: String) -> OutFailure { OutFailure(code: "ioError", message: m) }
  static func invalid(_ m: String) -> OutFailure { OutFailure(code: "invalidArgument", message: m) }
  static func busy(_ m: String) -> OutFailure { OutFailure(code: "busy", message: m) }
  static func denied(_ m: String) -> OutFailure { OutFailure(code: "permissionDenied", message: m) }
  static func unsupported(_ m: String) -> OutFailure { OutFailure(code: "notSupportedOnDevice", message: m) }
}

/// One app file handed to the system.
struct OutFile: Equatable {
  var path: String
  var displayName: String
  var uti: String?
  var mimeType: String?
}

/// What a file is, for Save to Photos.
enum OutMediaKind: Equatable {
  case photo
  case video
  case other
}

enum FileOutCore {
  private static let imageExtensions: Set<String> = [
    "jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp", "dng", "raw", "cr2", "cr3", "nef",
    "arw", "orf", "rw2", "raf", "avif",
  ]
  private static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "3gp", "avi", "mkv", "webm", "mts", "m2ts"]

  /// [name] safe as one path component: separators and control characters become `_`, leading dots
  /// are dropped, at most 255 UTF-8 bytes (the extension kept); empty becomes [fallback].
  static func safeName(_ name: String, fallback: String = "file") -> String {
    var cleaned = String(name.unicodeScalars.map { s -> Character in
      if s == "/" || s == ":" || s == "\\" || s.properties.generalCategory == .control { return "_" }
      return Character(s)
    })
    while cleaned.hasPrefix(".") { cleaned.removeFirst() }
    cleaned = cleaned.trimmingCharacters(in: .whitespaces)
    if cleaned.isEmpty { return fallback }
    if cleaned.utf8.count <= 255 { return cleaned }
    let ext = (cleaned as NSString).pathExtension
    var base = (cleaned as NSString).deletingPathExtension
    let suffix = ext.isEmpty ? "" : ".\(ext)"
    while !base.isEmpty && (base + suffix).utf8.count > 255 { base.removeLast() }
    return base.isEmpty ? fallback : base + suffix
  }

  /// `Name.ext`, `Name (2).ext`, `Name (3).ext`, … for the [n]th use of [name].
  static func numbered(_ name: String, _ n: Int) -> String {
    guard n > 1 else { return name }
    let ext = (name as NSString).pathExtension
    let base = (name as NSString).deletingPathExtension
    return ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
  }

  /// The first `Name (n).ext` in [directory] that doesn't exist yet.
  static func uniqueDestination(in directory: URL, name: String, fileManager: FileManager = .default) -> URL {
    let safe = safeName(name)
    var n = 1
    while true {
      let candidate = directory.appendingPathComponent(numbered(safe, n), isDirectory: false)
      if !fileManager.fileExists(atPath: candidate.path) { return candidate }
      n += 1
    }
  }

  /// Checks that every file of a request is a readable regular file.
  static func validate(_ files: [OutFile], fileManager: FileManager = .default) throws {
    guard !files.isEmpty else { throw OutFailure.invalid("no items") }
    for f in files {
      guard !f.path.isEmpty, f.path.hasPrefix("/") else { throw OutFailure.invalid("item path is not absolute") }
      var isDir: ObjCBool = false
      guard fileManager.fileExists(atPath: f.path, isDirectory: &isDir), !isDir.boolValue else {
        throw OutFailure.notFound("item file is missing")
      }
      guard fileManager.isReadableFile(atPath: f.path) else { throw OutFailure.io("item file is not readable") }
    }
  }

  /// Copies [file] into [directory] as a new file (never over an existing one) and returns it.
  /// The source is only read.
  static func exportCopy(_ file: OutFile, toDirectory directory: URL, fileManager: FileManager = .default) throws -> URL {
    let target = uniqueDestination(in: directory, name: file.displayName, fileManager: fileManager)
    do {
      try fileManager.copyItem(at: URL(fileURLWithPath: file.path), to: target)
    } catch {
      throw OutFailure.io("copy failed")
    }
    return target
  }

  /// Photo, video or neither, from the UTType, then the MIME type, then the extension.
  static func mediaKind(_ file: OutFile) -> OutMediaKind {
    if let uti = file.uti?.lowercased() {
      if uti.contains("movie") || uti.contains("video") || uti == "com.apple.quicktime-movie" || uti == "public.mpeg-4" { return .video }
      if uti.contains("image") || uti == "public.jpeg" || uti == "public.png" || uti == "public.heic" || uti.hasSuffix(".raw-image") {
        return .photo
      }
    }
    if let mime = file.mimeType?.lowercased() {
      if mime.hasPrefix("video/") { return .video }
      if mime.hasPrefix("image/") { return .photo }
    }
    let ext = (file.displayName as NSString).pathExtension.lowercased()
    let pathExt = (file.path as NSString).pathExtension.lowercased()
    for e in [ext, pathExt] where !e.isEmpty {
      if videoExtensions.contains(e) { return .video }
      if imageExtensions.contains(e) { return .photo }
    }
    return .other
  }
}

/// One request's read-only copies.
struct TempBatch: Equatable {
  /// The batch directory (`<root>/<uuid>/`).
  let directory: URL

  /// The copies, in request order.
  let urls: [URL]
}

/// Temporary read-only copies for share sheets and "Open in" (see the file header).
final class TempCopyStore {
  /// `<tmp>/danaview-out/`.
  static var defaultRoot: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("danaview-out", isDirectory: true)
  }

  /// Batches older than this are swept on start.
  static let staleAge: TimeInterval = 24 * 60 * 60

  let root: URL
  private let fileManager: FileManager
  private let lock = NSLock()

  init(root: URL = TempCopyStore.defaultRoot, fileManager: FileManager = .default) {
    self.root = root
    self.fileManager = fileManager
  }

  /// Copies [files] into a new batch, each under its (safe, batch-unique) display name, read-only.
  /// On any failure the partial batch is removed.
  func makeBatch(_ files: [OutFile]) throws -> TempBatch {
    try FileOutCore.validate(files, fileManager: fileManager)
    let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    do {
      try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    } catch {
      throw OutFailure.io("cannot create the share directory")
    }
    var urls: [URL] = []
    var used: [String: Int] = [:]
    do {
      for f in files {
        let safe = FileOutCore.safeName(f.displayName.isEmpty ? (f.path as NSString).lastPathComponent : f.displayName)
        var n = (used[safe.lowercased()] ?? 0) + 1
        var target = dir.appendingPathComponent(FileOutCore.numbered(safe, n), isDirectory: false)
        while fileManager.fileExists(atPath: target.path) {
          n += 1
          target = dir.appendingPathComponent(FileOutCore.numbered(safe, n), isDirectory: false)
        }
        used[safe.lowercased()] = n
        try fileManager.copyItem(at: URL(fileURLWithPath: f.path), to: target)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: Int16(0o444))], ofItemAtPath: target.path)
        urls.append(target)
      }
    } catch let failure as OutFailure {
      remove(TempBatch(directory: dir, urls: urls))
      throw failure
    } catch {
      remove(TempBatch(directory: dir, urls: urls))
      throw OutFailure.io("cannot make the temporary copy")
    }
    return TempBatch(directory: dir, urls: urls)
  }

  /// Removes [batch] (its copies are read-only, the directory is not).
  func remove(_ batch: TempBatch) {
    lock.lock()
    defer { lock.unlock() }
    guard batch.directory.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else { return }
    try? fileManager.removeItem(at: batch.directory)
  }

  /// The batch directories currently on disk.
  func batches() -> [URL] {
    (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
  }

  /// Removes batches last modified more than [age] before [now]; returns how many.
  @discardableResult
  func sweepStale(olderThan age: TimeInterval = TempCopyStore.staleAge, now: Date = Date()) -> Int {
    var removed = 0
    for dir in batches() {
      let modified = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
      if now.timeIntervalSince(modified) > age {
        try? fileManager.removeItem(at: dir)
        removed += 1
      }
    }
    return removed
  }
}
