// OWNER: HOM-20
//
// The Flutter-free core of the Apple import pickers (ARCH v1.2 §5.6, rule 27): naming and staging
// of picked files, the representation a photo pick is loaded as, the facts reported per item, and
// the streamed, resumable copy of a source URL into an app file (the source is opened read-only;
// only the destination part file is written). PickerHostApiImpl maps these to the Pigeon messages;
// XCTests (Tests/Pickers/) run this file without an app host. Nothing here logs (rule 30).

import Foundation

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// A failure of a picker operation; `code` is a `LibraryErrorCode` raw value, `message` debug text
/// without names or paths.
struct PickerFailure: Error, Equatable {
  let code: String
  let message: String

  static func notFound(_ m: String) -> PickerFailure { PickerFailure(code: "notFound", message: m) }
  static func cancelled(_ m: String) -> PickerFailure { PickerFailure(code: "cancelled", message: m) }
  static func io(_ m: String) -> PickerFailure { PickerFailure(code: "ioError", message: m) }
  static func invalid(_ m: String) -> PickerFailure { PickerFailure(code: "invalidArgument", message: m) }
  static func busy(_ m: String) -> PickerFailure { PickerFailure(code: "busy", message: m) }
}

/// One picked file, before it becomes a `PickedItemMsg`.
struct PickedFile: Equatable {
  var uri: String
  var path: String?
  var displayName: String
  var uti: String?
  var mimeType: String?
  var sizeBytes: Int64?
  var modifiedTimeMs: Int64?
  var assetIdentifier: String?
  var fromPhotoLibrary: Bool
  var needsCopy: Bool
}

/// Which items the photo picker offers (the Pigeon `PhotoMediaFilterMsg` order).
enum PickerMediaFilter: Int {
  case all = 0
  case photos = 1
  case videos = 2
}

enum PickerCore {
  // MARK: Types

  /// True when [identifier] conforms to [parent] (`public.movie`, `public.image`, …).
  static func conforms(_ identifier: String, to parent: String) -> Bool {
    if identifier == parent { return true }
    #if canImport(UniformTypeIdentifiers)
    if #available(iOS 14.0, macOS 11.0, *) {
      guard let type = UTType(identifier), let p = UTType(parent) else { return false }
      return type.conforms(to: p)
    }
    #endif
    let movies: Set<String> = ["public.movie", "public.mpeg-4", "com.apple.quicktime-movie", "public.avi", "public.3gpp"]
    let images: Set<String> = ["public.image", "public.jpeg", "public.png", "public.heic", "public.heif", "public.tiff", "com.compuserve.gif", "public.camera-raw-image", "com.adobe.raw-image", "org.webmproject.webp"]
    switch parent {
    case "public.movie": return movies.contains(identifier)
    case "public.image": return images.contains(identifier)
    default: return false
    }
  }

  /// The type identifier a photo pick is loaded as: a movie for videos, else the first still image
  /// representation (never the Live Photo bundle, which is no file), else the first registered one.
  static func bestTypeIdentifier(registered: [String], filter: PickerMediaFilter) -> String? {
    let usable = registered.filter { $0 != "com.apple.live-photo-bundle" && $0 != "com.apple.private.photos.thumbnail.standard" }
    let movie = usable.first { conforms($0, to: "public.movie") }
    let image = usable.first { conforms($0, to: "public.image") }
    switch filter {
    case .videos: return movie
    case .photos: return image
    case .all: return movie ?? image ?? usable.first
    }
  }

  /// The preferred file extension of [identifier], or nil.
  static func preferredExtension(_ identifier: String?) -> String? {
    guard let id = identifier else { return nil }
    #if canImport(UniformTypeIdentifiers)
    if #available(iOS 14.0, macOS 11.0, *) {
      return UTType(id)?.preferredFilenameExtension
    }
    #endif
    let table = ["public.jpeg": "jpeg", "public.png": "png", "public.heic": "heic", "com.apple.quicktime-movie": "mov", "public.mpeg-4": "mp4", "com.adobe.pdf": "pdf"]
    return table[id]
  }

  /// The UTType and MIME type of a file at [url] (from its extension).
  static func types(of url: URL) -> (uti: String?, mime: String?) {
    #if canImport(UniformTypeIdentifiers)
    if #available(iOS 14.0, macOS 11.0, *) {
      if let values = try? url.resourceValues(forKeys: [.contentTypeKey]), let type = values.contentType {
        return (type.identifier, type.preferredMIMEType)
      }
      if let type = UTType(filenameExtension: url.pathExtension) {
        return (type.identifier, type.preferredMIMEType)
      }
    }
    #endif
    return (nil, nil)
  }

  // MARK: Names and staging

  /// The name to import a pick as: [suggested] (the item provider's name, usually without an
  /// extension) with the extension of [typeIdentifier] added when it has none, else [fallback]'s
  /// last path component. Path separators and control characters are replaced.
  static func displayName(suggested: String?, typeIdentifier: String?, fallback: URL?) -> String {
    var name = (suggested?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
      ?? fallback?.lastPathComponent
      ?? "Imported file"
    name = String(name.map { c -> Character in
      if c == "/" || c == "\\" || c == ":" { return "_" }
      if c.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return "_" }
      return c
    })
    if name == "." || name == ".." { name = "Imported file" }
    let ext = (name as NSString).pathExtension
    if ext.isEmpty, let preferred = preferredExtension(typeIdentifier) ?? fallback.map({ $0.pathExtension }), !preferred.isEmpty {
      name += "." + preferred
    }
    return name
  }

  /// A file URL in [directory] for [name] that doesn't exist yet: `Name.ext`, `Name (2).ext`, …
  static func uniqueURL(in directory: URL, name: String, fileManager: FileManager = .default) -> URL {
    let ext = (name as NSString).pathExtension
    let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
    var candidate = directory.appendingPathComponent(name)
    var n = 2
    while fileManager.fileExists(atPath: candidate.path) {
      candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
      n += 1
    }
    return candidate
  }

  /// Copies the picker's temporary file [temporary] (valid only during the picker callback) into
  /// the staging [directory] as [name] (create-new, a clone on APFS). The temporary is only read.
  static func stage(copyOf temporary: URL, into directory: URL, name: String, fileManager: FileManager = .default) throws -> URL {
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      let target = uniqueURL(in: directory, name: name, fileManager: fileManager)
      try fileManager.copyItem(at: temporary, to: target)
      return target
    } catch {
      throw PickerFailure.io("staging copy failed")
    }
  }

  /// Moves an app-owned copy [ownCopy] (the document picker's import-mode copy in the app's
  /// `tmp/…-Inbox`) into the staging [directory] (create-new).
  static func stage(moving ownCopy: URL, into directory: URL, fileManager: FileManager = .default) throws -> URL {
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      let target = uniqueURL(in: directory, name: ownCopy.lastPathComponent, fileManager: fileManager)
      try fileManager.moveItem(at: ownCopy, to: target)
      return target
    } catch {
      throw PickerFailure.io("staging move failed")
    }
  }

  /// The facts of a picked file at [url].
  static func pickedFile(at url: URL, displayName: String? = nil, typeIdentifier: String? = nil, fromPhotoLibrary: Bool, needsCopy: Bool, assetIdentifier: String? = nil) -> PickedFile {
    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    var (uti, mime) = types(of: url)
    if let id = typeIdentifier {
      uti = id
      #if canImport(UniformTypeIdentifiers)
      if #available(iOS 14.0, macOS 11.0, *), let m = UTType(id)?.preferredMIMEType { mime = m }
      #endif
    }
    return PickedFile(
      uri: url.absoluteString,
      path: needsCopy ? nil : url.path,
      displayName: displayName ?? url.lastPathComponent,
      uti: uti,
      mimeType: mime,
      sizeBytes: values?.fileSize.map { Int64($0) },
      modifiedTimeMs: values?.contentModificationDate.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) },
      assetIdentifier: assetIdentifier,
      fromPhotoLibrary: fromPhotoLibrary,
      needsCopy: needsCopy
    )
  }

  // MARK: Streamed copy

  /// Copies [source] (opened read-only) into the file at [destination], appending from
  /// [resumeFrom] after truncating the destination to it (0: a fresh file). Calls [progress] with
  /// the bytes in the destination (fsynced first, so each report is a durable checkpoint) every
  /// [progressEvery] bytes and at the end; stops with
  /// `cancelled` when [isCancelled] turns true. The destination is fsynced before returning.
  /// Returns the bytes in the destination and the source size.
  static func streamCopy(
    from source: URL,
    to destination: String,
    resumeFrom: Int64,
    chunkBytes: Int = 1 << 20,
    progressEvery: Int64 = 4 << 20,
    isCancelled: () -> Bool = { false },
    progress: (Int64, Int64?) -> Void = { _, _ in }
  ) throws -> (copied: Int64, total: Int64) {
    guard resumeFrom >= 0 else { throw PickerFailure.invalid("negative offset") }
    let reader: FileHandle
    do {
      reader = try FileHandle(forReadingFrom: source)
    } catch {
      throw PickerFailure.notFound("source can't be opened")
    }
    defer { try? reader.close() }
    let total = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map { Int64($0) }

    let fm = FileManager.default
    var offset = resumeFrom
    if offset > 0 {
      let have = ((try? fm.attributesOfItem(atPath: destination)[.size]) as? NSNumber)?.int64Value ?? 0
      if have < offset { offset = have }
      if let t = total, offset > t { offset = 0 }
    }
    if offset == 0 {
      // A fresh copy: create (or empty) the destination part.
      guard fm.createFile(atPath: destination, contents: nil) else { throw PickerFailure.io("destination can't be created") }
    } else if truncate(destination, off_t(offset)) != 0 {
      throw PickerFailure.io("destination can't be truncated")
    }
    guard let out = OutputStream(toFileAtPath: destination, append: true) else { throw PickerFailure.io("destination can't be opened") }
    out.open()
    defer { out.close() }
    // A read-only descriptor of the destination for fsync: every progress report is a durable
    // checkpoint (the import stores it as `bytes_done`), so the bytes are on disk before it.
    let syncFd = open(destination, O_RDONLY)
    defer { if syncFd >= 0 { close(syncFd) } }

    do {
      try seekHandle(reader, to: UInt64(offset))
    } catch {
      throw PickerFailure.io("source seek failed")
    }
    var copied = offset
    var sinceProgress: Int64 = 0
    while true {
      if isCancelled() { throw PickerFailure.cancelled("copy cancelled") }
      let data: Data
      do {
        data = try readChunk(reader, upTo: chunkBytes)
      } catch {
        throw PickerFailure.io("source read failed")
      }
      if data.isEmpty { break }
      let written = data.withUnsafeBytes { raw -> Int in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
        var done = 0
        while done < data.count {
          let n = out.write(base + done, maxLength: data.count - done)
          if n <= 0 { return -1 }
          done += n
        }
        return done
      }
      if written != data.count { throw PickerFailure.io("destination write failed") }
      copied += Int64(written)
      sinceProgress += Int64(written)
      if sinceProgress >= progressEvery {
        sinceProgress = 0
        if syncFd >= 0 { fsync(syncFd) }
        progress(copied, total)
      }
    }
    out.close()
    if syncFd >= 0 { fsync(syncFd) }
    progress(copied, total)
    return (copied, total ?? copied)
  }

  private static func seekHandle(_ handle: FileHandle, to offset: UInt64) throws {
    if #available(iOS 13.4, macOS 10.15.4, *) {
      try handle.seek(toOffset: offset)
    } else {
      handle.seek(toFileOffset: offset)
    }
  }

  private static func readChunk(_ handle: FileHandle, upTo count: Int) throws -> Data {
    if #available(iOS 13.4, macOS 10.15.4, *) {
      return try handle.read(upToCount: count) ?? Data()
    }
    return handle.readData(ofLength: count)
  }
}

/// Security-scoped access held for URLs while they are read (copies) and until `release`.
final class ScopedAccessRegistry {
  private var held: [String: URL] = [:]
  private let lock = NSLock()

  /// Starts access to [url] when it is security-scoped; true when access is now held.
  @discardableResult
  func begin(_ url: URL) -> Bool {
    guard url.startAccessingSecurityScopedResource() else { return false }
    lock.lock()
    defer { lock.unlock() }
    if let previous = held[url.absoluteString] { previous.stopAccessingSecurityScopedResource() }
    held[url.absoluteString] = url
    return true
  }

  /// Stops the access held for [uri]; false when none was held.
  @discardableResult
  func release(_ uri: String) -> Bool {
    lock.lock()
    let url = held.removeValue(forKey: uri)
    lock.unlock()
    url?.stopAccessingSecurityScopedResource()
    return url != nil
  }

  /// The URIs with access held (tests).
  var heldURIs: [String] {
    lock.lock()
    defer { lock.unlock() }
    return held.keys.sorted()
  }
}

/// Cancellation flags of running copies by request id.
final class CopyRegistry {
  private var running: [String: Bool] = [:]
  private let lock = NSLock()

  /// Registers [id]; false when a copy with that id runs already.
  func start(_ id: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if running[id] != nil { return false }
    running[id] = false
    return true
  }

  /// Marks [id] cancelled; false when it isn't running.
  @discardableResult
  func cancel(_ id: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard running[id] != nil else { return false }
    running[id] = true
    return true
  }

  /// True when [id] was cancelled.
  func isCancelled(_ id: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return running[id] ?? false
  }

  /// Forgets [id].
  func finish(_ id: String) {
    lock.lock()
    running.removeValue(forKey: id)
    lock.unlock()
  }
}
