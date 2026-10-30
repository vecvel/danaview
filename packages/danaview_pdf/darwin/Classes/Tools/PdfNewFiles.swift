// OWNER: S4-W
//
// The PDF tools' shared output helper (page tools, annotate, sign, compress; reported by the
// Windows lane). Each output is created exclusively (`O_CREAT | O_EXCL`) before anything is
// written to it, and the job remembers which files it created: a file that appears at an output
// path after a tool's early "output exists" check is never written over, the job fails with
// `invalidArgument`, and its cleanup on cancel or failure deletes only its own files, never that
// one. Android does the same with `File.createNewFile()` and `Outputs.created`
// (android/.../tools/PdfPageToolsCore.kt). The claim opens no source and writes nothing (the
// descriptor is read-only and closed at once); PDFKit or Data then write the content into the
// claimed file (rule 27: the tools write only new files, from their own directories). Flutter-free:
// the XCTests compile it with the cores (Tests/Viewer/run_xctests.sh, Tests/Compress/
// run_compress_xctests.sh). Nothing is logged (rule 30).

import Foundation

/// The new files one PDF tool job writes.
final class PdfNewFiles {
  /// The paths this job created, in order.
  private(set) var created: [String] = []

  /// Creates [path] as an empty file owned by this job. Fails with `invalidArgument` ("output
  /// exists") when anything is already there, which is then never touched; `notFound` when its
  /// folder is missing.
  func claim(_ path: String) throws {
    guard !path.isEmpty else { throw PdfFailure(.invalidArgument, "empty output path") }
    let fd = open(path, O_CREAT | O_EXCL | O_RDONLY, 0o644)
    guard fd >= 0 else {
      switch errno {
      case EEXIST: throw PdfFailure(.invalidArgument, "output exists")
      case ENOENT, ENOTDIR: throw PdfFailure(.notFound, "output folder missing")
      case ENOSPC, EDQUOT: throw PdfFailure(.noSpace, "out of space")
      default: throw PdfFailure(.ioError, "create failed")
      }
    }
    close(fd)
    created.append(path)
  }

  /// Whether this job created [path].
  func owns(_ path: String) -> Bool { created.contains(path) }

  /// Deletes [path] if this job created it (never anyone else's file).
  func remove(_ path: String) {
    guard let index = created.firstIndex(of: path) else { return }
    created.remove(at: index)
    try? FileManager.default.removeItem(atPath: path)
  }

  /// Deletes every file this job created, and only those.
  func removeAll() {
    for path in created.reversed() { try? FileManager.default.removeItem(atPath: path) }
    created.removeAll()
  }
}
