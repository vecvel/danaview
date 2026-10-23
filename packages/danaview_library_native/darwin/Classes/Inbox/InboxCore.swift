// OWNER: HOM-21
//
// The Flutter-free core of the Share Extension inbox (ARCH v1.2 §5.6, rule 26: the plugin's Inbox
// class is the only App Group reader). Layout inside the App Group container (shared with
// ios/DanaviewShare/InboxWriter.swift, which writes it):
//
//   Inbox/                            excluded from backups (ARCH §5.2)
//     <batchId>/items/<n>/<name>      streamed copies of the shared items
//     <batchId>/manifest.json         written last, atomically: the batch is complete
//   folder-snapshot.json              the app's folder list for the extension's picker
//
// manifest.json: {"format":"danaview.inbox","schema":1,"createdAt":<ms>,
//                 "items":[{"file":"items/0/x.pdf","name":"x.pdf","uti":"…","mime":"…","size":n,
//                           "targetFolderId":"fd_…"|null}]}
//
// Nothing here logs a name or a path (rule 30); errors carry no names either.

import Foundation

/// The App Group shared by the app and the DanaviewShare extension (Runner.entitlements,
/// DanaviewShare.entitlements).
let danaviewAppGroupIdentifier = "group.com.vecvel.danaview"

/// One file of an inbox batch.
struct InboxCoreFile: Equatable {
  var relativePath: String
  var displayName: String
  var uti: String?
  var mimeType: String?
  var sizeBytes: Int64
}

/// One batch directory.
struct InboxCoreBatch: Equatable {
  var batchId: String
  var createdAtMs: Int64
  var complete: Bool
  var targetFolderId: String?
  var files: [InboxCoreFile]
}

/// Inbox failures (no names or paths in the text, rule 30).
enum InboxCoreError: Error, Equatable {
  /// A batch id or relative path that would leave the inbox.
  case invalidPath
  /// The file or batch is not there.
  case missing
  /// A file-system failure.
  case io(String)
}

/// The inbox of one App Group container.
final class InboxStore {
  static let manifestName = "manifest.json"
  static let manifestFormat = "danaview.inbox"
  static let snapshotName = "folder-snapshot.json"

  /// The App Group container.
  let groupRoot: URL
  private let fm = FileManager.default

  init(groupRoot: URL) {
    self.groupRoot = groupRoot
  }

  /// The App Group container of this process, or nil without the entitlement.
  static func shared() -> InboxStore? {
    guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: danaviewAppGroupIdentifier) else { return nil }
    return InboxStore(groupRoot: url)
  }

  var inboxURL: URL { groupRoot.appendingPathComponent("Inbox", isDirectory: true) }
  var snapshotURL: URL { groupRoot.appendingPathComponent(InboxStore.snapshotName, isDirectory: false) }

  /// Every batch directory, oldest first.
  func listBatches() -> [InboxCoreBatch] {
    guard let dirs = try? fm.contentsOfDirectory(at: inboxURL, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey], options: [.skipsHiddenFiles]) else { return [] }
    var out: [InboxCoreBatch] = []
    for dir in dirs {
      guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
      out.append(readBatch(dir))
    }
    return out.sorted { ($0.createdAtMs, $0.batchId) < ($1.createdAtMs, $1.batchId) }
  }

  private func directoryDateMs(_ dir: URL) -> Int64 {
    let values = try? dir.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
    let date = values?.creationDate ?? values?.contentModificationDate ?? Date()
    return Int64((date.timeIntervalSince1970 * 1000).rounded())
  }

  private func readBatch(_ dir: URL) -> InboxCoreBatch {
    let id = dir.lastPathComponent
    let incomplete = InboxCoreBatch(batchId: id, createdAtMs: directoryDateMs(dir), complete: false, targetFolderId: nil, files: [])
    guard let data = try? Data(contentsOf: dir.appendingPathComponent(InboxStore.manifestName)),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          json["format"] as? String == InboxStore.manifestFormat,
          let items = json["items"] as? [[String: Any]] else { return incomplete }
    var files: [InboxCoreFile] = []
    var folder: String?
    for item in items {
      guard let rel = item["file"] as? String, let target = try? resolve(rel, in: dir) else { continue }
      let name = (item["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? target.lastPathComponent
      let actual = (try? fm.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value
      let listed = (item["size"] as? NSNumber)?.int64Value
      files.append(InboxCoreFile(relativePath: rel, displayName: name, uti: item["uti"] as? String,
                                 mimeType: item["mime"] as? String, sizeBytes: actual ?? listed ?? 0))
      if folder == nil, let f = item["targetFolderId"] as? String, !f.isEmpty { folder = f }
    }
    let created = (json["createdAt"] as? NSNumber)?.int64Value ?? incomplete.createdAtMs
    return InboxCoreBatch(batchId: id, createdAtMs: created, complete: true, targetFolderId: folder, files: files)
  }

  /// The batch directory of [batchId] (one plain path component).
  func batchURL(_ batchId: String) throws -> URL {
    guard !batchId.isEmpty, batchId != ".", batchId != "..", !batchId.contains("/"), !batchId.hasPrefix(".") else { throw InboxCoreError.invalidPath }
    return inboxURL.appendingPathComponent(batchId, isDirectory: true)
  }

  /// [relative] inside [dir], refusing anything that would leave it.
  func resolve(_ relative: String, in dir: URL) throws -> URL {
    let parts = relative.split(separator: "/", omittingEmptySubsequences: true)
    guard !parts.isEmpty, !relative.hasPrefix("/"), parts.allSatisfy({ $0 != "." && $0 != ".." }) else { throw InboxCoreError.invalidPath }
    let url = parts.reduce(dir) { $0.appendingPathComponent(String($1)) }
    guard url.standardizedFileURL.path.hasPrefix(dir.standardizedFileURL.path + "/") else { throw InboxCoreError.invalidPath }
    return url
  }

  /// Moves one file of a batch to [destination] (replaced if it exists; its folder is created).
  func takeFile(batchId: String, relativePath: String, destination: URL) throws {
    let source = try resolve(relativePath, in: try batchURL(batchId))
    guard fm.fileExists(atPath: source.path) else { throw InboxCoreError.missing }
    do {
      try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
      do {
        try fm.moveItem(at: source, to: destination)
      } catch {
        // Another volume: copy (APFS clones where it can, streamed otherwise), then remove.
        try fm.copyItem(at: source, to: destination)
        try? fm.removeItem(at: source)
      }
    } catch {
      throw InboxCoreError.io("take failed (\((error as NSError).code))")
    }
  }

  /// Deletes batch [batchId]; a missing batch is not an error.
  func deleteBatch(_ batchId: String) throws {
    let dir = try batchURL(batchId)
    guard fm.fileExists(atPath: dir.path) else { return }
    do { try fm.removeItem(at: dir) } catch { throw InboxCoreError.io("delete failed (\((error as NSError).code))") }
  }

  /// Deletes incomplete batches (no readable manifest) created more than [olderThanMs] before
  /// [nowMs]; returns how many.
  func deleteStaleBatches(olderThanMs: Int64, nowMs: Int64) -> Int {
    var removed = 0
    for batch in listBatches() where !batch.complete && nowMs - batch.createdAtMs > olderThanMs {
      if (try? deleteBatch(batch.batchId)) != nil { removed += 1 }
    }
    return removed
  }

  /// Replaces the folder snapshot atomically (excluded from backups: the app rewrites it).
  func writeFolderSnapshot(_ data: Data) throws {
    do {
      try fm.createDirectory(at: groupRoot, withIntermediateDirectories: true)
      try data.write(to: snapshotURL, options: .atomic)
      var url = snapshotURL
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try? url.setResourceValues(values)
    } catch {
      throw InboxCoreError.io("snapshot write failed (\((error as NSError).code))")
    }
  }
}

/// The Darwin notification the extension posts after finishing a batch.
let danaviewInboxChangedNotification = "com.vecvel.danaview.inboxChanged"
