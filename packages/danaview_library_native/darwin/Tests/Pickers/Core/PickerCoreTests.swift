// OWNER: HOM-20
//
// XCTests of the picker core (BUILD_PLAN HOM-20, ARCH v1.2 §5.6, rule 27): picker result mapping
// (representation choice, names, staging, reported facts) and the streamed, resumable copy. The
// sources are generated here (local test media only) and must come out byte- and
// timestamp-identical.

import Foundation
import XCTest

@testable import DanaviewPickersCore

final class PickerCoreTests: XCTestCase {
  private var dir: URL!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent("hom20-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  private func bytes(_ n: Int, seed: UInt8 = 7) -> Data {
    var d = Data(count: n)
    var x = UInt32(seed)
    for i in 0..<n {
      x = x &* 1_103_515_245 &+ 12345
      d[i] = UInt8(truncatingIfNeeded: x >> 16)
    }
    return d
  }

  private func source(_ name: String, _ data: Data) throws -> URL {
    let url = dir.appendingPathComponent(name)
    try data.write(to: url)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_577_934_245)], ofItemAtPath: url.path)
    return url
  }

  private func stamp(_ url: URL) throws -> (Date, Int) {
    let a = try FileManager.default.attributesOfItem(atPath: url.path)
    return (a[.modificationDate] as! Date, (a[.size] as! NSNumber).intValue)
  }

  // MARK: Representation choice

  func testBestTypeIdentifierPrefersAStillOverTheLivePhotoBundle() {
    let live = ["com.apple.live-photo-bundle", "public.heic", "public.jpeg"]
    XCTAssertEqual(PickerCore.bestTypeIdentifier(registered: live, filter: .all), "public.heic")
    XCTAssertEqual(PickerCore.bestTypeIdentifier(registered: live, filter: .photos), "public.heic")
    XCTAssertNil(PickerCore.bestTypeIdentifier(registered: live, filter: .videos))
  }

  func testBestTypeIdentifierPicksTheMovieOfAVideo() {
    let video = ["com.apple.quicktime-movie", "public.jpeg"]
    XCTAssertEqual(PickerCore.bestTypeIdentifier(registered: video, filter: .all), "com.apple.quicktime-movie")
    XCTAssertEqual(PickerCore.bestTypeIdentifier(registered: video, filter: .videos), "com.apple.quicktime-movie")
    XCTAssertEqual(PickerCore.bestTypeIdentifier(registered: ["com.example.unknown"], filter: .all), "com.example.unknown")
    XCTAssertNil(PickerCore.bestTypeIdentifier(registered: [], filter: .all))
  }

  // MARK: Names

  func testDisplayNameAddsTheExtensionOfTheRepresentation() {
    XCTAssertEqual(PickerCore.displayName(suggested: "IMG_0001", typeIdentifier: "public.heic", fallback: nil), "IMG_0001.heic")
    XCTAssertEqual(PickerCore.displayName(suggested: "clip", typeIdentifier: "com.apple.quicktime-movie", fallback: nil), "clip.mov")
    XCTAssertEqual(PickerCore.displayName(suggested: "Report.pdf", typeIdentifier: "com.adobe.pdf", fallback: nil), "Report.pdf")
  }

  func testDisplayNameFallsBackAndSanitizes() {
    let tmp = URL(fileURLWithPath: "/private/var/tmp/A1B2.jpeg")
    XCTAssertEqual(PickerCore.displayName(suggested: nil, typeIdentifier: nil, fallback: tmp), "A1B2.jpeg")
    XCTAssertEqual(PickerCore.displayName(suggested: "  ", typeIdentifier: "public.png", fallback: nil), "Imported file.png")
    XCTAssertEqual(PickerCore.displayName(suggested: "a/b:c", typeIdentifier: "public.png", fallback: nil), "a_b_c.png")
    XCTAssertEqual(PickerCore.displayName(suggested: "..", typeIdentifier: nil, fallback: nil), "Imported file")
    XCTAssertEqual(PickerCore.displayName(suggested: "tab\tname", typeIdentifier: nil, fallback: nil), "tab_name")
  }

  func testUniqueURLSuffixesTakenNames() throws {
    _ = try source("Photo.jpg", Data([1]))
    _ = try source("Photo (2).jpg", Data([1]))
    XCTAssertEqual(PickerCore.uniqueURL(in: dir, name: "Photo.jpg").lastPathComponent, "Photo (3).jpg")
    XCTAssertEqual(PickerCore.uniqueURL(in: dir, name: "New.jpg").lastPathComponent, "New.jpg")
    _ = try source("README", Data([1]))
    XCTAssertEqual(PickerCore.uniqueURL(in: dir, name: "README").lastPathComponent, "README (2)")
  }

  // MARK: Staging

  func testStagingCopiesThePickersTemporaryAndLeavesItUnchanged() throws {
    let data = bytes(300_000)
    let temp = try source("picker-temp.heic", data)
    let before = try stamp(temp)
    let staging = dir.appendingPathComponent("staging", isDirectory: true)
    let first = try PickerCore.stage(copyOf: temp, into: staging, name: "IMG_0001.heic")
    let second = try PickerCore.stage(copyOf: temp, into: staging, name: "IMG_0001.heic")
    XCTAssertEqual(first.lastPathComponent, "IMG_0001.heic")
    XCTAssertEqual(second.lastPathComponent, "IMG_0001 (2).heic", "create-new, never overwrite")
    XCTAssertEqual(try Data(contentsOf: first), data)
    XCTAssertEqual(try Data(contentsOf: temp), data)
    let after = try stamp(temp)
    XCTAssertEqual(after.0, before.0)
    XCTAssertEqual(after.1, before.1)
  }

  func testStagingMovesAnAppOwnedImportCopy() throws {
    let own = try source("Inbox copy.pdf", bytes(1000))
    let staging = dir.appendingPathComponent("staging", isDirectory: true)
    let moved = try PickerCore.stage(moving: own, into: staging)
    XCTAssertEqual(moved.lastPathComponent, "Inbox copy.pdf")
    XCTAssertFalse(FileManager.default.fileExists(atPath: own.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
  }

  // MARK: Facts

  func testPickedFileReportsSizeTimeAndTypes() throws {
    let url = try source("Quarterly Report.pdf", bytes(4321))
    let f = PickerCore.pickedFile(at: url, fromPhotoLibrary: false, needsCopy: false)
    XCTAssertEqual(f.displayName, "Quarterly Report.pdf")
    XCTAssertEqual(f.path, url.path)
    XCTAssertEqual(f.uri, url.absoluteString)
    XCTAssertEqual(f.sizeBytes, 4321)
    XCTAssertEqual(f.modifiedTimeMs, 1_577_934_245_000)
    XCTAssertEqual(f.uti, "com.adobe.pdf")
    XCTAssertEqual(f.mimeType, "application/pdf")
    XCTAssertFalse(f.fromPhotoLibrary)
    XCTAssertFalse(f.needsCopy)

    let photo = PickerCore.pickedFile(at: url, displayName: "IMG.heic", typeIdentifier: "public.heic", fromPhotoLibrary: true, needsCopy: true, assetIdentifier: "A/L0/001")
    XCTAssertNil(photo.path, "a URI that still needs a copy has no readable path")
    XCTAssertEqual(photo.uti, "public.heic")
    XCTAssertEqual(photo.mimeType, "image/heic")
    XCTAssertEqual(photo.assetIdentifier, "A/L0/001")
    XCTAssertTrue(photo.fromPhotoLibrary)
  }

  // MARK: Streamed copy

  func testStreamCopyCopiesExactlyAndNeverTouchesTheSource() throws {
    let data = bytes(5 * 1024 * 1024 + 3)
    let src = try source("video.mov", data)
    let before = try stamp(src)
    let dest = dir.appendingPathComponent("job.part").path
    var reports: [Int64] = []
    let r = try PickerCore.streamCopy(from: src, to: dest, resumeFrom: 0, progressEvery: 1 << 20) { done, total in
      reports.append(done)
      XCTAssertEqual(total, Int64(data.count))
    }
    XCTAssertEqual(r.copied, Int64(data.count))
    XCTAssertEqual(r.total, Int64(data.count))
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: dest)), data)
    XCTAssertEqual(reports.last, Int64(data.count))
    XCTAssertEqual(reports, reports.sorted())
    XCTAssertGreaterThanOrEqual(reports.count, 5)
    let after = try stamp(src)
    XCTAssertEqual(after.0, before.0)
    XCTAssertEqual(after.1, before.1)
    XCTAssertEqual(try Data(contentsOf: src), data)
  }

  func testStreamCopyResumesFromTheOffsetAndCutsAnUnsyncedTail() throws {
    let data = bytes(3 * 1024 * 1024)
    let src = try source("doc.bin", data)
    let dest = dir.appendingPathComponent("job.part")
    var partial = data.prefix(1_000_000)
    partial.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF])
    try partial.write(to: dest)
    let r = try PickerCore.streamCopy(from: src, to: dest.path, resumeFrom: 1_000_000)
    XCTAssertEqual(r.copied, Int64(data.count))
    XCTAssertEqual(try Data(contentsOf: dest), data)
  }

  func testStreamCopyClampsAnOffsetBeyondTheDestination() throws {
    let data = bytes(100_000)
    let src = try source("a.bin", data)
    let dest = dir.appendingPathComponent("job.part")
    try data.prefix(10).write(to: dest)
    let r = try PickerCore.streamCopy(from: src, to: dest.path, resumeFrom: 50_000)
    XCTAssertEqual(r.copied, Int64(data.count))
    XCTAssertEqual(try Data(contentsOf: dest), data)
  }

  func testStreamCopyStopsWhenCancelled() throws {
    let src = try source("big.bin", bytes(4 * 1024 * 1024))
    let dest = dir.appendingPathComponent("job.part").path
    var calls = 0
    XCTAssertThrowsError(try PickerCore.streamCopy(from: src, to: dest, resumeFrom: 0, chunkBytes: 1 << 20, isCancelled: { calls += 1; return calls > 2 })) { error in
      XCTAssertEqual((error as? PickerFailure)?.code, "cancelled")
    }
  }

  func testStreamCopyOfAMissingSourceIsNotFound() {
    let missing = dir.appendingPathComponent("missing.bin")
    XCTAssertThrowsError(try PickerCore.streamCopy(from: missing, to: dir.appendingPathComponent("p").path, resumeFrom: 0)) { error in
      XCTAssertEqual((error as? PickerFailure)?.code, "notFound")
    }
    XCTAssertThrowsError(try PickerCore.streamCopy(from: missing, to: dir.appendingPathComponent("p").path, resumeFrom: -1)) { error in
      XCTAssertEqual((error as? PickerFailure)?.code, "invalidArgument")
    }
  }

  // MARK: Registries

  func testCopyRegistryRefusesADuplicateIdAndTracksCancel() {
    let r = CopyRegistry()
    XCTAssertTrue(r.start("a"))
    XCTAssertFalse(r.start("a"))
    XCTAssertFalse(r.isCancelled("a"))
    XCTAssertTrue(r.cancel("a"))
    XCTAssertTrue(r.isCancelled("a"))
    r.finish("a")
    XCTAssertFalse(r.cancel("a"))
    XCTAssertTrue(r.start("a"))
  }

  func testScopedAccessIsHeldUntilReleased() throws {
    let registry = ScopedAccessRegistry()
    XCTAssertFalse(registry.release("file:///never-held"), "releasing nothing held is a no-op")
    let plain = try source("plain.txt", Data([1]))
    // Outside a sandbox every file URL reports access; inside one only scoped URLs do.
    if registry.begin(plain) {
      XCTAssertEqual(registry.heldURIs, [plain.absoluteString])
      XCTAssertTrue(registry.release(plain.absoluteString))
    }
    XCTAssertEqual(registry.heldURIs, [])
  }
}
