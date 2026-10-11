// OWNER: IOS-15
//
// Media access (ARCH §9, §15, D-44) on the io queue:
// - Bookmarks for Files picks: `createBookmark` (inside security-scoped access) and
//   `resolveBookmark` with stale refresh (a stale bookmark is recreated while access is held and
//   returned as `refreshedBookmark`). A bookmark that no longer resolves fails with
//   `mediaOffline` when the file is gone and `permissionDenied` otherwise (access lost).
// - Security-scoped access is refcounted per path (`ScopedAccessRegistry`), so overlapping
//   stat/hash calls and other services never stop each other's access.
// - `stat`: size + modification time, nil when the file is missing, `permissionDenied` when
//   access was lost.
// - `quickHash`: the core algorithm (danaview_editor_core `computeQuickHash`, ARCH §6.8) with a
//   streamed read of at most 2 × 64 KiB: sha1(head + tail + ":<size>"), tail only when
//   size > 64 KiB, empty file -> "".
// - `excludeFromBackup`: sets NSURLIsExcludedFromBackupKey on the directory (created when
//   missing); the glue already refused paths outside the editor and speech roots.
// - `remainingGrantBudget`: unbounded on iOS (Int32.max); URI grants are Android-only no-ops.
// Errors never carry paths (EngineError scrubs; messages name only the operation).

import CryptoKit
import Flutter
import Foundation

/// Refcounted `startAccessingSecurityScopedResource` per standardized path.
final class ScopedAccessRegistry {
    static let shared = ScopedAccessRegistry()

    private let lock = NSLock()
    private var counts: [String: (url: URL, count: Int, started: Bool)] = [:]

    /// Starts (or joins) access to [url].
    func begin(_ url: URL) {
        let key = url.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        if var entry = counts[key] {
            entry.count += 1
            counts[key] = entry
            return
        }
        let started = url.startAccessingSecurityScopedResource()
        counts[key] = (url, 1, started)
    }

    /// Ends one access to [url]; the scope stops when the last user ends.
    func end(_ url: URL) {
        let key = url.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        guard var entry = counts[key] else { return }
        entry.count -= 1
        if entry.count > 0 {
            counts[key] = entry
            return
        }
        counts.removeValue(forKey: key)
        if entry.started { entry.url.stopAccessingSecurityScopedResource() }
    }

    /// Current users of [url] (tests).
    func count(_ url: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[url.standardizedFileURL.path]?.count ?? 0
    }

    /// Runs [work] while access to [url] is held.
    func with<T>(_ url: URL, _ work: () throws -> T) rethrows -> T {
        begin(url)
        defer { end(url) }
        return try work()
    }
}

final class MediaAccess: MediaAccessing {
    /// Bytes read from each end of a file (core `quickHashChunkBytes`).
    static let quickHashChunkBytes = 64 * 1024

    private let context: EngineContext
    private let scopes: ScopedAccessRegistry

    init(context: EngineContext) {
        self.context = context
        self.scopes = .shared
    }

    init(context: EngineContext, scopes: ScopedAccessRegistry) {
        self.context = context
        self.scopes = scopes
    }

    // MARK: Bookmarks

    func createBookmark(fileURL: URL, reply: @escaping EngineReply<Data>) {
        reply(Result { try createBookmark(fileURL) })
    }

    func resolveBookmark(_ bookmark: Data, reply: @escaping EngineReply<ResolvedBookmarkMsg>) {
        reply(Result {
            let resolved = try resolve(bookmark)
            var refreshed: FlutterStandardTypedData?
            if resolved.stale {
                // Recreate while access is held; a failure keeps the stale (still usable) bookmark.
                if let data = try? scopes.with(resolved.url, { try MediaAccess.bookmarkData(resolved.url) }) {
                    refreshed = FlutterStandardTypedData(bytes: data)
                }
            }
            return ResolvedBookmarkMsg(uri: resolved.url.absoluteString, stale: resolved.stale, refreshedBookmark: refreshed)
        })
    }

    /// A bookmark of [url] made while its security scope is held.
    func createBookmark(_ url: URL) throws -> Data {
        try scopes.with(url) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw EngineError(.mediaOffline, "createBookmark: file not found")
            }
            do {
                return try MediaAccess.bookmarkData(url)
            } catch {
                throw MediaAccess.accessError(error, "createBookmark")
            }
        }
    }

    static func bookmarkData(_ url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// No UI, no mounting, and no implicit security-scoped access (balanced by
    /// ScopedAccessRegistry instead).
    static let resolutionOptions: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting, .withoutImplicitStartAccessing]

    /// Resolves [bookmark].
    func resolve(_ bookmark: Data) throws -> (url: URL, stale: Bool) {
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmark, options: MediaAccess.resolutionOptions, relativeTo: nil,
                bookmarkDataIsStale: &stale)
            return (url.standardizedFileURL, stale)
        } catch {
            let mapped = EngineError.from(error)
            if mapped.code == .mediaOffline { throw EngineError(.mediaOffline, "resolveBookmark: file not found") }
            // Anything else means the grant behind the bookmark is gone.
            throw EngineError(.permissionDenied, "resolveBookmark: access lost")
        }
    }

    // MARK: Android-only grants

    func persistUriGrant(uri: String, reply: @escaping EngineReply<Void>) {
        reply(.success(()))
    }

    func releaseUriGrant(uri: String, reply: @escaping EngineReply<Void>) {
        reply(.success(()))
    }

    /// Unbounded on iOS.
    func remainingGrantBudget(reply: @escaping EngineReply<Int64>) {
        reply(.success(Int64(Int32.max)))
    }

    // MARK: Stat and hash

    func stat(_ media: MediaRefMsg, fileURL: URL, reply: @escaping EngineReply<MediaStatMsg?>) {
        reply(Result {
            let url: URL
            do {
                url = try target(media, fileURL)
            } catch let error as EngineError where error.code == .mediaOffline {
                return nil
            }
            return try scopes.with(url) { try MediaAccess.stat(url) }
        })
    }

    func quickHash(_ media: MediaRefMsg, fileURL: URL, reply: @escaping EngineReply<String>) {
        reply(Result {
            let url = try target(media, fileURL)
            return try scopes.with(url) { try MediaAccess.quickHash(of: url) }
        })
    }

    /// The URL to read: the resolved bookmark when there is one, else [fileURL].
    private func target(_ media: MediaRefMsg, _ fileURL: URL) throws -> URL {
        guard let bookmark = media.bookmark else { return fileURL }
        return try resolve(bookmark.data).url
    }

    /// Size and modification time of [url]; nil when it does not exist.
    static func stat(_ url: URL) throws -> MediaStatMsg? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let type = attributes[.type] as? FileAttributeType, type == .typeDirectory { return nil }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date).map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
            return MediaStatMsg(sizeBytes: size, modifiedMs: modified)
        } catch {
            let mapped = EngineError.from(error)
            if mapped.code == .mediaOffline { return nil }
            throw accessError(error, "stat")
        }
    }

    /// The core quickHash of the file at [url] (streamed; reads at most 2 × 64 KiB).
    static func quickHash(of url: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw accessError(error, "quickHash")
        }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            if size == 0 { return "" }
            let chunk = UInt64(quickHashChunkBytes)
            try handle.seek(toOffset: 0)
            let head = try handle.read(upToCount: Int(min(size, chunk))) ?? Data()
            var tail = Data()
            if size > chunk {
                try handle.seek(toOffset: size - chunk)
                tail = try handle.read(upToCount: Int(chunk)) ?? Data()
            }
            guard UInt64(head.count) == min(size, chunk), size <= chunk || UInt64(tail.count) == chunk else {
                throw EngineError(.io, "quickHash: short read", retryable: true)
            }
            return quickHash(head: head, tail: tail, size: size)
        } catch let error as EngineError {
            throw error
        } catch {
            throw accessError(error, "quickHash")
        }
    }

    /// `sha1(head + (size > 64 KiB ? tail : []) + utf8(":<size>"))` as lowercase hex; "" for 0 bytes.
    static func quickHash(head: Data, tail: Data, size: UInt64) -> String {
        if size == 0 { return "" }
        var sha = Insecure.SHA1()
        sha.update(data: head)
        if size > UInt64(quickHashChunkBytes) { sha.update(data: tail) }
        sha.update(data: Data(":\(size)".utf8))
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Maps a file error: missing -> mediaOffline, everything permission-like -> permissionDenied.
    static func accessError(_ error: Error, _ operation: String) -> EngineError {
        let mapped = EngineError.from(error)
        switch mapped.code {
        case .mediaOffline: return EngineError(.mediaOffline, "\(operation): file not found")
        case .permissionDenied: return EngineError(.permissionDenied, "\(operation): access lost")
        default: return mapped
        }
    }

    // MARK: Backup exclusion (D-44)

    func excludeFromBackup(directoryURL: URL, reply: @escaping EngineReply<Void>) {
        reply(Result { try MediaAccess.excludeFromBackup(directoryURL) })
    }

    static func excludeFromBackup(_ directoryURL: URL) throws {
        var url = directoryURL
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            throw EngineError.from(error)
        }
    }

    /// Whether [url] carries NSURLIsExcludedFromBackupKey (fresh read, tests and QA-10).
    static func isExcludedFromBackup(_ url: URL) throws -> Bool {
        var fresh = URL(fileURLWithPath: url.path)
        fresh.removeAllCachedResourceValues()
        return try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false
    }
}
