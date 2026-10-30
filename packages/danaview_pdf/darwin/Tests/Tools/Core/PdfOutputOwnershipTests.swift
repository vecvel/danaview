// OWNER: S4-W
//
// XCTests of the PDF tools' output ownership (Tools/PdfNewFiles.swift `PdfNewFiles`, used by
// Tools/PdfPageToolsCore.swift `write` and Annotate/PdfAnnotateCore.swift, so sign too) on macOS
// and the iOS Simulator (Tests/Viewer/run_xctests.sh macos | ios-sim). Reported by the Windows lane:
// when a file appeared at an output path after the early "output exists" check, the late check
// threw and the cleanup deleted that path, which may be someone else's file. Now every output is
// created exclusively and only files the job created are deleted: a file that appears in the race
// keeps its bytes, the job fails with `invalidArgument`, and the job's own earlier outputs (split)
// are removed. Compress has the same test in Tests/Compress/PdfCompressCoreTests.swift.

import CoreGraphics
import Foundation
import PDFKit
import XCTest

/// Runs [onProgress] on every progress report (from the tool's thread, synchronously).
final class RacingControl: PdfToolControl {
  private let onProgress: (Int, Int) -> Void

  init(_ onProgress: @escaping (Int, Int) -> Void) {
    self.onProgress = onProgress
  }

  var isCancelled: Bool { false }

  func progress(done: Int, total: Int) { onProgress(done, total) }
}

final class PdfOutputOwnershipTests: XCTestCase {
  private var dir: URL!
  private let foreignBytes = Data("someone else's file".utf8)

  override func setUp() {
    super.setUp()
    dir = TestPdfs.tempDir(self)
  }

  private func out(_ name: String) -> String { dir.appendingPathComponent(name).path }

  /// Puts another writer's file at [path] (what the race looks like from the job's side).
  private func appear(_ path: String) {
    XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: foreignBytes))
  }

  private func assertForeignKept(_ path: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(FileManager.default.contents(atPath: path), foreignBytes, "the other file is kept as it was", file: file, line: line)
  }

  private func assertOutputExists(_ body: () throws -> Any, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try body(), file: file, line: line) { error in
      XCTAssertEqual(error as? PdfFailure, PdfFailure(.invalidArgument, "output exists"), file: file, line: line)
    }
  }

  // ---------------------------------------------------------------------------------------------
  // PdfNewFiles

  func testClaimCreatesExclusivelyAndRemovesOnlyItsOwnFiles() throws {
    let files = PdfNewFiles()
    let mine = out("mine.pdf")
    try files.claim(mine)
    XCTAssertTrue(files.owns(mine))
    XCTAssertEqual(FileManager.default.contents(atPath: mine), Data(), "claimed as an empty file")

    let theirs = out("theirs.pdf")
    appear(theirs)
    XCTAssertThrowsError(try files.claim(theirs)) { XCTAssertEqual(($0 as? PdfFailure)?.code, .invalidArgument) }
    XCTAssertThrowsError(try files.claim(mine)) { XCTAssertEqual(($0 as? PdfFailure)?.code, .invalidArgument, "not twice") }
    XCTAssertThrowsError(try files.claim(out("no/such/dir.pdf"))) { XCTAssertEqual(($0 as? PdfFailure)?.code, .notFound) }
    XCTAssertThrowsError(try files.claim("")) { XCTAssertEqual(($0 as? PdfFailure)?.code, .invalidArgument) }
    XCTAssertFalse(files.owns(theirs))
    XCTAssertEqual(files.created, [mine])

    files.remove(theirs)
    assertForeignKept(theirs)
    files.removeAll()
    XCTAssertFalse(FileManager.default.fileExists(atPath: mine))
    assertForeignKept(theirs)
    XCTAssertEqual(files.created, [])
  }

  // ---------------------------------------------------------------------------------------------
  // The late check of every tool

  func testMergeNeverDeletesAFileThatAppearedAtItsOutput() throws {
    let a = TestPdfs.writeTextPdf(to: dir.appendingPathComponent("a.pdf"), pages: 2, prefix: "AAA")
    let b = TestPdfs.writeTextPdf(to: dir.appendingPathComponent("b.pdf"), pages: 2, prefix: "BBB")
    let path = out("merged.pdf")
    // The last page report comes right before the write: the other file appears then.
    let control = RacingControl { done, total in if done == total, total > 0 { self.appear(path) } }
    assertOutputExists { try PdfPageToolsCore.merge([PdfToolSource(path: a.path), PdfToolSource(path: b.path)], outPath: path, control: control) }
    assertForeignKept(path)
  }

  func testOrganiseNeverDeletesAFileThatAppearedAtItsOutput() throws {
    let a = TestPdfs.writeTextPdf(to: dir.appendingPathComponent("a.pdf"), pages: 3, prefix: "AAA")
    let path = out("organised.pdf")
    let control = RacingControl { done, total in if done == total, total > 0 { self.appear(path) } }
    assertOutputExists {
      try PdfPageToolsCore.organise(PdfToolSource(path: a.path), plan: [PdfPagePlanItem(2), PdfPagePlanItem(0)], outPath: path, control: control)
    }
    assertForeignKept(path)
  }

  func testSplitRemovesItsOwnPartsButNotTheFileThatAppeared() throws {
    let a = TestPdfs.writeTextPdf(to: dir.appendingPathComponent("a.pdf"), pages: 4, prefix: "AAA")
    let first = out("part1.pdf")
    let second = out("part2.pdf")
    // Part 1 (pages 0–1) is written after report 2; the other file takes part 2's path at report 3.
    let control = RacingControl { done, _ in if done == 3 { self.appear(second) } }
    assertOutputExists {
      try PdfPageToolsCore.split(PdfToolSource(path: a.path), ranges: [0..<2, 2..<4], outPaths: [first, second], control: control)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: first), "the job's own part is removed")
    assertForeignKept(second)
  }

  func testAnnotateAndSignNeverDeleteAFileThatAppearedAtTheirOutput() throws {
    let source = TestPdfs.writeTextPdf(to: dir.appendingPathComponent("s.pdf"), pages: 2, prefix: "TXT")
    let ink = PdfAnnotationSpec(kind: .ink, pageIndex: 0, strokes: [[CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 40)]])
    let annotated = out("annotated.pdf")
    // Reports: 0 of 2, the page (1 of 2), then the write; the other file appears at the page report.
    let control = RacingControl { done, total in if done == total - 1 { self.appear(annotated) } }
    assertOutputExists { try PdfAnnotateCore.annotate(PdfToolSource(path: source.path), annotations: [ink], outPath: annotated, control: control) }
    assertForeignKept(annotated)

    // Sign is the same write with burnIn (Sign/PdfSigner.swift routes to it).
    let signed = out("signed.pdf")
    let burnControl = RacingControl { done, total in if done == total - 1 { self.appear(signed) } }
    assertOutputExists {
      try PdfAnnotateCore.annotate(PdfToolSource(path: source.path), annotations: [ink], burnIn: true, outPath: signed, control: burnControl)
    }
    assertForeignKept(signed)
  }

  func testAWriteWithoutARaceStillProducesTheFile() throws {
    let a = TestPdfs.writeTextPdf(to: dir.appendingPathComponent("a.pdf"), pages: 2, prefix: "AAA")
    let path = out("ok.pdf")
    let written = try PdfPageToolsCore.organise(PdfToolSource(path: a.path), plan: [PdfPagePlanItem(1)], outPath: path, control: RacingControl { _, _ in })
    XCTAssertEqual(written.pageCount, 1)
    XCTAssertGreaterThan(written.sizeBytes, 0, "PDFKit wrote over the job's own empty claim")
    XCTAssertEqual(PDFDocument(url: URL(fileURLWithPath: path))?.pageCount, 1)
  }
}
