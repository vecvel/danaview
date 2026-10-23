// OWNER: HOM-21
//
// The Share Extension inbox round trip (BUILD_PLAN HOM-21, ARCH v1.2 §5.6): what the extension's
// InboxWriter writes, the plugin's InboxStore reads; a batch is complete only once the manifest is
// written last; an interrupted batch is never listed as complete and is deleted after 24 h; batch
// ids and relative paths can't leave the inbox; the copy is streamed and leaves the source
// untouched; the App Group ids agree; the folder snapshot parses with an Imported fallback.
// Generated local files only.

import Foundation
import XCTest

@testable import DanaviewInboxCore

final class InboxCoreTests: XCTestCase {
  private var root: URL!
  private var src: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("dv_inbox_\(UUID().uuidString)", isDirectory: true)
    src = FileManager.default.temporaryDirectory.appendingPathComponent("dv_inbox_src_\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.removeItem(at: src)
  }

  private func source(_ name: String, size: Int, seed: UInt8 = 7) throws -> URL {
    var bytes = [UInt8](repeating: 0, count: size)
    for i in 0..<size { bytes[i] = UInt8(truncatingIfNeeded: i &* 31 &+ Int(seed)) }
    let url = src.appendingPathComponent(name)
    try Data(bytes).write(to: url)
    return url
  }

  func testWrittenBatchRoundTripsIntoTheReader() throws {
    let photo = try source("IMG_0001.HEIC", size: 4096)
    let pdf = try source("Lease.pdf", size: 10_000)
    let created = Date(timeIntervalSince1970: 1_790_000_000)
    let writer = InboxWriter(groupRoot: root, targetFolderId: "fd_work", createdAt: created, batchId: "b1")
    try writer.begin()
    try writer.addFile(at: photo, name: "IMG_0001.HEIC", uti: "public.heic")
    try writer.addFile(at: pdf, name: "Lease.pdf", uti: "com.adobe.pdf")
    try writer.addData(Data("hello".utf8), name: "Shared text.txt", uti: "public.plain-text")

    let store = InboxStore(groupRoot: root)
    XCTAssertEqual(store.listBatches().map(\.complete), [false], "no manifest yet: incomplete")
    XCTAssertEqual(store.listBatches().first?.files, [])

    try writer.finish()
    let batch = try XCTUnwrap(store.listBatches().first)
    XCTAssertTrue(batch.complete)
    XCTAssertEqual(batch.batchId, "b1")
    XCTAssertEqual(batch.createdAtMs, 1_790_000_000_000)
    XCTAssertEqual(batch.targetFolderId, "fd_work")
    XCTAssertEqual(batch.files.map(\.displayName), ["IMG_0001.HEIC", "Lease.pdf", "Shared text.txt"])
    XCTAssertEqual(batch.files.map(\.sizeBytes), [4096, 10_000, 5])
    XCTAssertEqual(batch.files.map(\.uti), ["public.heic", "com.adobe.pdf", "public.plain-text"])

    // The source was only read.
    XCTAssertEqual(try Data(contentsOf: pdf).count, 10_000)

    // Take moves the file out to an app path; the batch then deletes cleanly.
    let dest = src.appendingPathComponent("staging/0001_Lease.pdf")
    try store.takeFile(batchId: "b1", relativePath: batch.files[1].relativePath, destination: dest)
    XCTAssertEqual(try Data(contentsOf: dest), try Data(contentsOf: pdf))
    XCTAssertThrowsError(try store.takeFile(batchId: "b1", relativePath: batch.files[1].relativePath, destination: dest)) {
      XCTAssertEqual($0 as? InboxCoreError, .missing)
    }
    try store.deleteBatch("b1")
    XCTAssertTrue(store.listBatches().isEmpty)
    try store.deleteBatch("b1") // already gone: fine
  }

  func testInboxIsExcludedFromBackups() throws {
    let writer = InboxWriter(groupRoot: root, targetFolderId: nil)
    try writer.begin()
    let values = try writer.inboxURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
    XCTAssertEqual(values.isExcludedFromBackup, true)
  }

  func testAbandonedAndStaleBatches() throws {
    let a = InboxWriter(groupRoot: root, targetFolderId: nil, batchId: "cancelled")
    try a.begin()
    try a.addFile(at: try source("x.mov", size: 2048), name: "x.mov", uti: "com.apple.quicktime-movie")
    a.abandon()
    XCTAssertTrue(InboxStore(groupRoot: root).listBatches().isEmpty, "a cancelled share leaves nothing")

    // Killed mid-copy: a directory without a manifest.
    let killed = InboxWriter(groupRoot: root, targetFolderId: nil, batchId: "killed")
    try killed.begin()
    try killed.addFile(at: try source("y.mov", size: 2048), name: "y.mov", uti: nil)
    let done = InboxWriter(groupRoot: root, targetFolderId: nil, batchId: "done")
    try done.begin()
    try done.finish()

    let store = InboxStore(groupRoot: root)
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    let day: Int64 = 24 * 3600 * 1000
    XCTAssertEqual(store.deleteStaleBatches(olderThanMs: day, nowMs: now), 0, "a recent incomplete batch may still be writing")
    XCTAssertEqual(store.deleteStaleBatches(olderThanMs: day, nowMs: now + day + 60_000), 1)
    XCTAssertEqual(store.listBatches().map(\.batchId), ["done"], "complete batches are never stale")
  }

  func testAMalformedManifestIsIncomplete() throws {
    let dir = root.appendingPathComponent("Inbox/bad", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("{not json".utf8).write(to: dir.appendingPathComponent("manifest.json"))
    XCTAssertEqual(InboxStore(groupRoot: root).listBatches().map(\.complete), [false])
  }

  func testPathsCannotLeaveTheInbox() throws {
    let store = InboxStore(groupRoot: root)
    let dest = src.appendingPathComponent("out")
    for id in ["", ".", "..", "../x", "a/b", ".hidden"] {
      XCTAssertThrowsError(try store.takeFile(batchId: id, relativePath: "items/0/a", destination: dest)) {
        XCTAssertEqual($0 as? InboxCoreError, .invalidPath, id)
      }
      XCTAssertThrowsError(try store.deleteBatch(id))
    }
    for rel in ["../manifest.json", "/etc/hosts", "items/../../x", "", "./a"] {
      XCTAssertThrowsError(try store.takeFile(batchId: "b", relativePath: rel, destination: dest)) {
        XCTAssertEqual($0 as? InboxCoreError, .invalidPath, rel)
      }
    }
    // A manifest naming a file outside its batch lists nothing for it.
    let dir = root.appendingPathComponent("Inbox/evil", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let manifest = #"{"format":"danaview.inbox","schema":1,"createdAt":1,"items":[{"file":"../../secret","name":"s"}]}"#
    try Data(manifest.utf8).write(to: dir.appendingPathComponent("manifest.json"))
    XCTAssertEqual(InboxStore(groupRoot: root).listBatches().first?.files, [])
  }

  func testNamesAreSafePathComponents() {
    XCTAssertEqual(InboxWriter.safeName("a/b:c.pdf"), "a_b_c.pdf")
    XCTAssertEqual(InboxWriter.safeName(".."), "Shared item")
    XCTAssertEqual(InboxWriter.safeName("  "), "Shared item")
    XCTAssertEqual(InboxWriter.safeName(".env"), "_env")
    XCTAssertLessThanOrEqual(InboxWriter.safeName(String(repeating: "é", count: 300) + ".pdf").utf8.count, 200)
  }

  func testLargeCopyIsStreamed() throws {
    // A 64 MB generated (sparse) file: the copy must not grow resident memory by its size.
    let big = src.appendingPathComponent("big.mov")
    FileManager.default.createFile(atPath: big.path, contents: Data([1]))
    XCTAssertEqual(truncate(big.path, 64 << 20), 0)
    let before = residentBytes()
    let writer = InboxWriter(groupRoot: root, targetFolderId: nil, batchId: "big")
    try writer.begin()
    let item = try writer.addFile(at: big, name: "big.mov", uti: "com.apple.quicktime-movie")
    try writer.finish()
    XCTAssertEqual(item.size, 64 << 20)
    XCTAssertLessThan(residentBytes() - before, 32 << 20, "the copy streams instead of loading the file")
  }

  func testAppGroupIdsAgree() {
    XCTAssertEqual(danaviewAppGroupIdentifier, DanaviewAppGroup.identifier)
    XCTAssertEqual(danaviewInboxChangedNotification, DanaviewAppGroup.inboxChangedNotification)
    XCTAssertEqual(InboxStore.manifestName, InboxWriter.manifestName)
    XCTAssertEqual(InboxStore.manifestFormat, InboxWriter.manifestFormat)
    XCTAssertEqual(InboxStore.snapshotName, FolderSnapshot.fileName)
  }

  func testFolderSnapshotWriteAndParse() throws {
    let store = InboxStore(groupRoot: root)
    let json = #"{"format":"danaview.folderSnapshot","schema":1,"writtenAt":1,"folders":[{"id":"fd_imp","name":"Imported","parentId":null,"depth":0,"imported":true},{"id":"fd_w","name":"Work","parentId":null,"depth":0,"imported":false},{"id":"fd_t","name":"Taxes","parentId":"fd_w","depth":1,"imported":false},{"id":"bad","name":"x"}]}"#
    try store.writeFolderSnapshot(Data(json.utf8))
    let folders = FolderSnapshot.load(groupRoot: root)
    XCTAssertEqual(folders.map(\.name), ["Imported", "Work", "Taxes"])
    XCTAssertEqual(folders.map(\.depth), [0, 0, 1])
    XCTAssertEqual(FolderSnapshot.defaultIndex(folders), 0)
    XCTAssertEqual(try store.snapshotURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)

    XCTAssertEqual(FolderSnapshot.load(groupRoot: nil), FolderSnapshot.importedOnly)
    XCTAssertEqual(FolderSnapshot.parse(Data("{}".utf8)), FolderSnapshot.importedOnly)
    let newer = #"{"format":"danaview.folderSnapshot","schema":2,"folders":[]}"#
    XCTAssertEqual(FolderSnapshot.parse(Data(newer.utf8)), FolderSnapshot.importedOnly)
    let noImported = #"{"format":"danaview.folderSnapshot","schema":1,"folders":[{"id":"fd_w","name":"Work","depth":0}]}"#
    XCTAssertEqual(FolderSnapshot.parse(Data(noImported.utf8)).map(\.name), ["Imported", "Work"])
  }

  private func residentBytes() -> Int {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Int(info.resident_size) : 0
  }
}
