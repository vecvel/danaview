// OWNER: IOS-08
//
// Media URLs of a plan and security-scoped access refcounted per session (ARCH §11.2 Asset
// `bookmark`, §20.1). A preview session (or an export) owns one `SessionMediaAccess`; every built
// composition takes a `MediaLease` on the URLs it reads and releases it when the composition is
// replaced or disposed, so a structural rebuild keeps access to media both compositions use (the
// new lease is taken before the old one is released). The process-wide start/stop calls go through
// `ScopedAccessRegistry` (Platform/MediaAccess.swift), which refcounts across sessions.

import Foundation

/// Per-session refcounts of security-scoped URLs.
final class SessionMediaAccess {
    private let lock = NSLock()
    private var counts: [String: (url: URL, count: Int)] = [:]
    private let begin: (URL) -> Void
    private let end: (URL) -> Void

    /// [begin]/[end] default to the process-wide `ScopedAccessRegistry` (tests inject probes).
    init(begin: @escaping (URL) -> Void = { ScopedAccessRegistry.shared.begin($0) },
         end: @escaping (URL) -> Void = { ScopedAccessRegistry.shared.end($0) }) {
        self.begin = begin
        self.end = end
    }

    deinit {
        releaseAll()
    }

    /// Takes one session reference on [url]; the first one starts process-wide access.
    func acquire(_ url: URL) {
        let key = url.standardizedFileURL.path
        lock.lock()
        let first = counts[key] == nil
        counts[key] = (url, (counts[key]?.count ?? 0) + 1)
        lock.unlock()
        if first { begin(url) }
    }

    /// Drops one session reference on [url]; the last one stops process-wide access.
    func release(_ url: URL) {
        let key = url.standardizedFileURL.path
        lock.lock()
        guard let entry = counts[key] else {
            lock.unlock()
            return
        }
        let last = entry.count <= 1
        if last { counts.removeValue(forKey: key) } else { counts[key] = (entry.url, entry.count - 1) }
        lock.unlock()
        if last { end(entry.url) }
    }

    /// Releases everything (session dispose).
    func releaseAll() {
        lock.lock()
        let all = counts.values.map(\.url)
        counts.removeAll()
        lock.unlock()
        all.forEach(end)
    }

    /// Session references on [url] (tests).
    func count(_ url: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[url.standardizedFileURL.path]?.count ?? 0
    }

    /// A lease on [urls] (one reference each).
    func lease(_ urls: [URL]) -> MediaLease {
        urls.forEach(acquire)
        return MediaLease(access: self, urls: urls)
    }
}

/// The references one composition holds; released once (explicitly or on deinit).
final class MediaLease {
    private weak var access: SessionMediaAccess?
    private var urls: [URL]
    private let lock = NSLock()

    fileprivate init(access: SessionMediaAccess, urls: [URL]) {
        self.access = access
        self.urls = urls
    }

    deinit {
        release()
    }

    /// Releases the references (idempotent).
    func release() {
        lock.lock()
        let held = urls
        urls = []
        lock.unlock()
        held.forEach { access?.release($0) }
    }
}

/// How a plan asset becomes a readable URL.
enum MediaURLResolver {
    /// [asset]'s URL: the proxy when [useProxies] and one exists, else the bookmark's resolved URL
    /// (iOS security-scoped bookmark), else `uri`. `scoped` is true when the URL needs a
    /// security-scoped lease. `content://` never reaches iOS (mediaOffline).
    static func resolve(_ asset: PlanAsset, useProxies: Bool) throws -> (url: URL, scoped: Bool) {
        if useProxies, let proxy = asset.proxyUri, let url = fileURL(proxy) {
            return (url, false)
        }
        if let b64 = asset.bookmark, let data = Data(base64Encoded: b64) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
                return (url, true)
            }
        }
        guard let url = fileURL(asset.uri) else {
            throw EngineError(.mediaOffline, "asset uri is not a file URL", mediaFingerprint: asset.fp.isEmpty ? nil : asset.fp)
        }
        return (url, false)
    }

    private static func fileURL(_ uri: String) -> URL? {
        guard uri.hasPrefix("file://"), let url = URL(string: uri), url.isFileURL else { return nil }
        return url
    }
}
