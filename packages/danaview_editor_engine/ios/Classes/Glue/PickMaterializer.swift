// OWNER: INT-07
//
// `PlatformHostApi.materializePick` on iOS (INT-07, ARCH §9.1, §12.4): copies a picked file that
// Dart cannot keep by reference into `<intoDir>/<uuid>/<name>` and returns the copy's path.
// - `intoDir` must lie inside `<cache>/danaview/editor/work/` (`permissionDenied` otherwise).
// - A `file://` URI (or absolute path) already under `work/` (the iOS pickers' and the drop
//   target's app-owned temporary copies, ARCH §9.1) is returned as is (`mediaOffline` when gone).
// - Any other `file://` URI (a Files pick in place) is copied while its security scope is held;
//   a missing file is `mediaOffline`, an unreadable one `permissionDenied`, a full disk `diskFull`.
// - Other schemes (Photos `ph://` identifiers, Android `content://`) cannot be copied here:
//   `notSupportedOnDevice` (iOS Photos picks arrive as temporary copies already).
// A failed copy deletes its directory. Runs on the io queue; never logs paths.

import Foundation

enum PickMaterializer {
    /// The copy of [uri] in a new directory under [intoDir] (already validated inside `work/`).
    static func materialize(uri: String, intoDir: URL, paths: Paths, fileManager: FileManager = .default) throws -> String {
        guard uri.hasPrefix("/") || URL(string: uri)?.isFileURL == true else {
            throw EngineError.notSupportedOnDevice("materializing this URI scheme")
        }
        let source = try Paths.fileURL(fromPathOrUri: uri, name: "uri")
        let resolvedSource = Paths.resolvedURL(source)
        let work = Paths.resolvedURL(paths.work)
        if Paths.contains(work, resolvedSource) {
            guard fileManager.fileExists(atPath: source.path) else { throw EngineError(.mediaOffline, "the picked copy is gone") }
            return source.path
        }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw EngineError(.mediaOffline, "the picked file is gone")
        }
        guard !isDirectory.boolValue else { throw EngineError(.unsupportedMedia, "the pick is a directory") }
        guard fileManager.isReadableFile(atPath: source.path) else { throw EngineError(.permissionDenied, "the picked file is not readable") }

        let dir = intoDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = dir.appendingPathComponent(safeName(source.lastPathComponent), isDirectory: false)
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            try? fileManager.removeItem(at: dir)
            throw EngineError.from(error)
        }
        return destination.path
    }

    /// A file name without path separators, NUL or leading dots ("pick" when nothing is left).
    static func safeName(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\u{0}", with: "")
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "pick" : String(s.prefix(200))
    }
}
