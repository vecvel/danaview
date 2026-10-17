// OWNER: ENG-07 (frozen with the glue by ENG-06)
//
// Engine directories (ARCH §8.1, §15, §20.1). The engine never invents roots: Dart hands it
// `<cache>/danaview/editor` and `<support>/danaview/editor` through `EngineHostApi.initialize`, and every
// directory the engine writes is derived from them. The AI root `<support>/danaview/speech` is the
// sibling of the editor support root (speech audio jobs and backup exclusion, D-20, D-44).
//
// Dart-supplied output paths are checked with `requireWritable`: absolute, no `..` components,
// and inside the editor or speech roots after resolving symlinks of the deepest existing ancestor
// (so a symlink inside a root cannot point the engine outside it). Native code deletes only its own
// partial outputs inside such paths (ARCH §9.6, §20.1).

import Foundation

/// The engine's directories. Immutable; created by `EngineContext.configure`.
final class Paths: Equatable {
    /// `<cache>/danaview/editor`.
    let cacheRoot: URL
    /// `<support>/danaview/editor`.
    let supportRoot: URL
    /// `<support>/danaview/speech` (sibling of [supportRoot]).
    let speechRoot: URL

    /// Validates the Dart-supplied roots.
    init(cacheRoot: String, supportRoot: String) throws {
        let cache = try Paths.absoluteURL(cacheRoot, name: "cacheRoot")
        let support = try Paths.absoluteURL(supportRoot, name: "supportRoot")
        if cache.path == support.path {
            throw EngineError.invalidArgument("supportRoot", "must differ from cacheRoot")
        }
        if Paths.contains(cache, support) || Paths.contains(support, cache) {
            throw EngineError.invalidArgument("supportRoot", "roots must not contain each other")
        }
        self.cacheRoot = cache
        self.supportRoot = support
        self.speechRoot = support.deletingLastPathComponent().appendingPathComponent("speech", isDirectory: true)
    }

    static func == (lhs: Paths, rhs: Paths) -> Bool {
        lhs.cacheRoot == rhs.cacheRoot && lhs.supportRoot == rhs.supportRoot
    }

    // MARK: Engine-owned directories (ARCH §8.1, §15)

    /// Thumbnail strips (300 MB LRU).
    var thumbs: URL { cacheRoot.appendingPathComponent("thumbs", isDirectory: true) }
    /// Waveform peaks (64 MB LRU).
    var waves: URL { cacheRoot.appendingPathComponent("waves", isDirectory: true) }
    /// Proxies (`<quickHash>-540.mp4`).
    var proxies: URL { cacheRoot.appendingPathComponent("proxies", isDirectory: true) }
    /// Decoded text sprites (400 MB LRU).
    var sprites: URL { cacheRoot.appendingPathComponent("sprites", isDirectory: true) }
    /// Look stills.
    var looks: URL { cacheRoot.appendingPathComponent("looks", isDirectory: true) }
    /// Engine assets generated at runtime (the composition spacer, IOS-08).
    var engineAssets: URL { cacheRoot.appendingPathComponent("engine", isDirectory: true) }
    /// Scratch space wiped at launch except active/resumable job files (IOS-03).
    var work: URL { cacheRoot.appendingPathComponent("work", isDirectory: true) }
    /// Picker copies (24 h).
    var workPicks: URL { work.appendingPathComponent("picks", isDirectory: true) }
    /// Drop copies (24 h).
    var workDrops: URL { work.appendingPathComponent("drops", isDirectory: true) }
    /// Reversed renditions (`derived/<specHash>.mp4`).
    var derived: URL { supportRoot.appendingPathComponent("derived", isDirectory: true) }

    /// Roots the engine may write below.
    var writableRoots: [URL] { [cacheRoot, supportRoot, speechRoot] }

    /// Roots `excludeFromBackup` accepts (D-44).
    var backupExclusionRoots: [URL] { [cacheRoot, supportRoot, speechRoot] }

    /// Creates [url] and its parents when missing.
    func ensureDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw EngineError.from(error)
        }
    }

    // MARK: Validation of Dart-supplied paths

    /// The URL of a Dart-supplied output path, which must lie inside one of [writableRoots].
    func requireWritable(_ path: String, name: String) throws -> URL {
        try requireInside(path, roots: writableRoots, name: name)
    }

    /// The URL of [path] if it lies inside one of [roots]; `permissionDenied` otherwise.
    func requireInside(_ path: String, roots: [URL], name: String) throws -> URL {
        let url = try Paths.absoluteURL(path, name: name)
        let resolved = Paths.resolvedURL(url)
        for root in roots {
            let resolvedRoot = Paths.resolvedURL(root)
            if resolved.path == resolvedRoot.path || Paths.contains(resolvedRoot, resolved) {
                return url
            }
        }
        throw EngineError(.permissionDenied, "\(name) is outside the editor roots")
    }

    /// A `file://` URI or an absolute path as a standardized file URL (no `..`, no NUL).
    static func fileURL(fromPathOrUri value: String, name: String) throws -> URL {
        if value.hasPrefix("file:") {
            guard let url = URL(string: value), url.isFileURL, !url.path.isEmpty else {
                throw EngineError.invalidArgument(name, "not a file URI")
            }
            return try absoluteURL(url.path, name: name)
        }
        if value.contains("://") {
            throw EngineError.invalidArgument(name, "only file URIs and absolute paths are supported on iOS")
        }
        return try absoluteURL(value, name: name)
    }

    /// An absolute path as a standardized file URL. Refuses empty, relative, `..` and NUL paths.
    static func absoluteURL(_ path: String, name: String) throws -> URL {
        guard !path.isEmpty else { throw EngineError.invalidArgument(name, "empty path") }
        guard path.hasPrefix("/") else { throw EngineError.invalidArgument(name, "not an absolute path") }
        guard !path.contains("\u{0}") else { throw EngineError.invalidArgument(name, "contains NUL") }
        guard path.utf8.count <= 4096 else { throw EngineError.invalidArgument(name, "path too long") }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        if components.contains(where: { $0 == ".." }) {
            throw EngineError.invalidArgument(name, "contains '..'")
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    /// Whether [child] lies strictly below [parent] (component-wise, no string-prefix tricks).
    static func contains(_ parent: URL, _ child: URL) -> Bool {
        let p = parent.standardizedFileURL.pathComponents
        let c = child.standardizedFileURL.pathComponents
        return c.count > p.count && Array(c.prefix(p.count)) == p
    }

    /// [url] with the symlinks of its deepest existing ancestor resolved by `realpath`, and the
    /// missing tail appended (outputs usually do not exist yet).
    static func resolvedURL(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var tail: [String] = []
        while existing.path != "/" && !FileManager.default.fileExists(atPath: existing.path) {
            tail.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var resolved = existing
        if let real = realpath(existing.path, nil) {
            resolved = URL(fileURLWithPath: String(cString: real))
            free(real)
        }
        for component in tail {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL
    }

    // MARK: Disk space (privacy manifest DiskSpace E174.1)

    /// Free bytes for important usage on the volume of [path] (the deepest existing ancestor).
    static func freeBytes(at path: String) throws -> Int64 {
        var url = try absoluteURL(path, name: "path")
        while url.path != "/" && !FileManager.default.fileExists(atPath: url.path) {
            url = url.deletingLastPathComponent()
        }
        do {
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
                return important
            }
            return Int64(values.volumeAvailableCapacity ?? 0)
        } catch {
            throw EngineError.from(error)
        }
    }
}
