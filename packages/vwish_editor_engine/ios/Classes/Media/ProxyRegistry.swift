// OWNER: IOS-05
//
// Proxy status by fingerprint and the proxies/ LRU (ARCH §9.5, §15). Proxies live in
// `<cache>/vwish/editor/proxies/<quickHash>-540.mp4` (the fingerprint is the quickHash). Status:
// `ready` when the file exists, otherwise what the JobRegistry recorded for the fingerprint
// (queued, running, failed), otherwise `noProxy`. The directory is capped at min(4 GB, 10 % of the
// free space) by access time; files in use (pinned by a preview session, or being written) are
// never evicted. Stale proxy work directories (`work/proxy-*`, resumable checkpoints of jobs that
// were never resumed) are removed after 7 days.

import Foundation

final class ProxyRegistry: ProxyStatusProviding {
    private let context: EngineContext

    init(context: EngineContext) {
        self.context = context
    }

    static let absoluteCapBytes: Int64 = 4 * 1024 * 1024 * 1024
    static let freeFraction = 0.10
    static let staleWorkLifetime: TimeInterval = 7 * 24 * 3600
    static let suffix = "-540"
    static let fileExtension = "mp4"

    func status(fingerprint: String, reply: @escaping EngineReply<ProxyStatusMsg>) {
        guard let paths = context.paths else {
            reply(.failure(EngineError.notInitialized))
            return
        }
        reply(.success(ProxyRegistry.status(fingerprint: fingerprint, paths: paths)))
    }

    static func status(fingerprint: String, paths: Paths) -> ProxyStatusMsg {
        if FileManager.default.fileExists(atPath: proxyURL(fingerprint: fingerprint, paths: paths).path) {
            return .ready
        }
        lock.lock()
        defer { lock.unlock() }
        return tracked[fingerprint] ?? .noProxy
    }

    // MARK: Job tracking (JobRegistry)

    private static let lock = NSLock()
    private static var tracked: [String: ProxyStatusMsg] = [:]

    /// Records the job state of [fingerprint] (nil forgets it: done or cancelled).
    static func mark(fingerprint: String, _ status: ProxyStatusMsg?) {
        lock.lock()
        tracked[fingerprint] = status
        lock.unlock()
    }

    // MARK: Files

    /// `proxies/<quickHash>-540.mp4`.
    static func proxyURL(fingerprint: String, paths: Paths) -> URL {
        store(paths).url(forKey: CacheStore.fileName(fingerprint) + suffix, ext: fileExtension)
    }

    /// The proxy of [fingerprint] when it exists (touched as recently used).
    static func readyProxy(fingerprint: String, paths: Paths) -> URL? {
        store(paths).lookup(key: CacheStore.fileName(fingerprint) + suffix, ext: fileExtension)
    }

    private static var stores: [String: CacheStore] = [:]

    /// The shared store of proxies/ (pins are shared by every user of the same root).
    static func store(_ paths: Paths) -> CacheStore {
        lock.lock()
        defer { lock.unlock() }
        let key = paths.proxies.standardizedFileURL.path
        if let store = stores[key] { return store }
        let store = CacheStore(directory: paths.proxies, capBytes: absoluteCapBytes)
        stores[key] = store
        return store
    }

    /// Pins a proxy used by a preview session (IOS-11), balanced by `unpin`.
    static func pin(_ url: URL, paths: Paths) { store(paths).pin(url) }
    static func unpin(_ url: URL, paths: Paths) { store(paths).unpin(url) }

    /// min(4 GB, 10 % of the free space).
    static func capBytes(paths: Paths, freeBytes: Int64? = nil) -> Int64 {
        let free = freeBytes ?? ((try? Paths.freeBytes(at: paths.proxies.path)) ?? 0)
        return min(absoluteCapBytes, Int64(Double(max(0, free)) * freeFraction))
    }

    /// Evicts least recently used proxies above the cap. [keep] (a fresh proxy) is never evicted.
    @discardableResult
    static func enforceCap(paths: Paths, keep: URL? = nil, freeBytes: Int64? = nil) -> Int64 {
        let store = store(paths)
        let cap = capBytes(paths: paths, freeBytes: freeBytes)
        if let keep = keep { store.pin(keep) }
        defer { if let keep = keep { store.unpin(keep) } }
        let freed = store.evict(toBytes: cap)
        if freed > 0 { Log.info(.jobs, "proxies: evicted \(freed / 1024) KB (cap \(cap / 1_048_576) MB)") }
        return freed
    }

    /// Removes `work/proxy-*` directories whose checkpoint is older than 7 days (never resumed).
    static func pruneStaleWork(paths: Paths, now: Date = Date()) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: paths.work.path) else { return }
        for name in names where name.hasPrefix("proxy-") {
            let directory = paths.work.appendingPathComponent(name, isDirectory: true)
            if DiskCache.activeWorkPaths.contains(directory.standardizedFileURL.path) { continue }
            let updated = SegmentCheckpoint.load(from: directory)?.updatedAt ?? .distantPast
            if now.timeIntervalSince(updated) > staleWorkLifetime {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }
}
