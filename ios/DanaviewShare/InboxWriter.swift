// OWNER: HOM-21 (the file was a placeholder of INT-104, which created the DanaviewShare target)
//
// Streams shared items into `<App Group>/Inbox/<batchId>/` with `manifest.json` written last
// (ARCH v1.2 §5.6). The layout and the manifest are read by the plugin's InboxStore
// (packages/danaview_library_native/darwin/Classes/Inbox/InboxCore.swift):
//
//   Inbox/<batchId>/items/<n>/<name>    one streamed copy per item (FileManager copy: an APFS clone
//                                       or a chunked copy, never the whole file in memory, so a
//                                       2 GB video stays under the extension memory limit)
//   Inbox/<batchId>/manifest.json       {"format":"danaview.inbox","schema":1,"createdAt":<ms>,
//                                        "items":[{"file","name","uti","size","targetFolderId"}]}
//
// Until `finish()` writes the manifest the batch is incomplete: the app never imports it and
// deletes it after 24 h, so an interrupted share leaves no half-imported entry. Backup class (ARCH
// §5.2): `Inbox/` is marked `isExcludedFromBackup` when it is created. Foundation only (no UIKit),
// so the plugin's XCTests round-trip it on macOS. Nothing is logged (rule 30).

import Foundation

enum DanaviewAppGroup {
  static let identifier = "group.com.vecvel.danaview"

  /// The App Group container, or nil without the entitlement.
  static func containerURL() -> URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
  }

  /// The Darwin notification the app's plugin listens for (an `inboxChanged` library event).
  static let inboxChangedNotification = "com.vecvel.danaview.inboxChanged"
}

/// Inbox write failures (no names or paths, rule 30).
enum InboxWriterError: Error, Equatable {
  case notStarted
  case finished
  case noSpace
  case copyFailed
}

/// One shared item written into a batch.
struct InboxWrittenItem: Equatable {
  var file: String
  var name: String
  var uti: String?
  var size: Int64
}

/// Writes one Share Extension batch.
final class InboxWriter {
  static let manifestName = "manifest.json"
  static let manifestFormat = "danaview.inbox"

  /// Space kept free on the volume besides the item itself.
  static let spareBytes: Int64 = 50 * 1024 * 1024

  let groupRoot: URL
  let batchId: String
  let targetFolderId: String?
  private let createdAt: Date
  private let fm = FileManager.default
  private(set) var items: [InboxWrittenItem] = []
  private var started = false
  private var done = false

  /// A batch for [targetFolderId] (nil: `Imported`) under [groupRoot].
  init(groupRoot: URL, targetFolderId: String?, createdAt: Date = Date(), batchId: String? = nil) {
    self.groupRoot = groupRoot
    self.targetFolderId = targetFolderId
    self.createdAt = createdAt
    let ms = Int64((createdAt.timeIntervalSince1970 * 1000).rounded())
    self.batchId = batchId ?? "\(ms)-\(UUID().uuidString.lowercased())"
  }

  var inboxURL: URL { groupRoot.appendingPathComponent("Inbox", isDirectory: true) }
  var batchURL: URL { inboxURL.appendingPathComponent(batchId, isDirectory: true) }

  /// Creates `Inbox/` (excluded from backups) and the batch directory.
  func begin() throws {
    do {
      if !fm.fileExists(atPath: inboxURL.path) {
        try fm.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        var url = inboxURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
      }
      try fm.createDirectory(at: batchURL, withIntermediateDirectories: true)
    } catch {
      throw InboxWriterError.copyFailed
    }
    started = true
  }

  /// A name safe as one path component (the entry keeps it; the app deduplicates).
  static func safeName(_ name: String, fallback: String = "Shared item") -> String {
    var n = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
    n = String(n.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }).trimmingCharacters(in: .whitespacesAndNewlines)
    if n.isEmpty || n == "." || n == ".." { n = fallback }
    if n.hasPrefix(".") { n = "_" + n.dropFirst() }
    while n.utf8.count > 200 { n.removeFirst() }
    return n
  }

  /// True when the volume holding [url] has room for [bytes] plus a margin.
  static func hasRoom(for bytes: Int64, at url: URL) -> Bool {
    guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
          let free = values.volumeAvailableCapacityForImportantUsage else { return true }
    return free >= bytes + spareBytes
  }

  private func slot(_ name: String) throws -> (URL, String) {
    guard started else { throw InboxWriterError.notStarted }
    guard !done else { throw InboxWriterError.finished }
    let safe = InboxWriter.safeName(name)
    let rel = "items/\(items.count)/\(safe)"
    let dir = batchURL.appendingPathComponent("items/\(items.count)", isDirectory: true)
    do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch { throw InboxWriterError.copyFailed }
    return (dir.appendingPathComponent(safe), rel)
  }

  /// Copies the file at [source] (streamed) as [name]; the source is only read.
  @discardableResult
  func addFile(at source: URL, name: String, uti: String?) throws -> InboxWrittenItem {
    let size = (try? fm.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0
    guard InboxWriter.hasRoom(for: size, at: groupRoot) else { throw InboxWriterError.noSpace }
    let (dest, rel) = try slot(name)
    do { try fm.copyItem(at: source, to: dest) } catch { throw InboxWriterError.copyFailed }
    let written = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? size
    let item = InboxWrittenItem(file: rel, name: InboxWriter.safeName(name), uti: uti, size: written)
    items.append(item)
    return item
  }

  /// Writes small in-memory content (shared text) as [name].
  @discardableResult
  func addData(_ data: Data, name: String, uti: String?) throws -> InboxWrittenItem {
    guard InboxWriter.hasRoom(for: Int64(data.count), at: groupRoot) else { throw InboxWriterError.noSpace }
    let (dest, rel) = try slot(name)
    do { try data.write(to: dest, options: .atomic) } catch { throw InboxWriterError.copyFailed }
    let item = InboxWrittenItem(file: rel, name: InboxWriter.safeName(name), uti: uti, size: Int64(data.count))
    items.append(item)
    return item
  }

  /// Writes `manifest.json` last (atomically): the batch is complete.
  func finish() throws {
    guard started else { throw InboxWriterError.notStarted }
    guard !done else { throw InboxWriterError.finished }
    let json: [String: Any] = [
      "format": InboxWriter.manifestFormat,
      "schema": 1,
      "createdAt": Int64((createdAt.timeIntervalSince1970 * 1000).rounded()),
      "items": items.map { item -> [String: Any] in
        var m: [String: Any] = ["file": item.file, "name": item.name, "size": item.size]
        if let uti = item.uti { m["uti"] = uti }
        if let folder = targetFolderId { m["targetFolderId"] = folder }
        return m
      },
    ]
    do {
      let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
      try data.write(to: batchURL.appendingPathComponent(InboxWriter.manifestName), options: .atomic)
    } catch {
      throw InboxWriterError.copyFailed
    }
    done = true
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFNotificationName(DanaviewAppGroup.inboxChangedNotification as CFString), nil, nil, true)
  }

  /// Removes the batch (a cancelled or failed share); never leaves a half batch when it can help it.
  func abandon() {
    done = true
    try? fm.removeItem(at: batchURL)
  }
}
