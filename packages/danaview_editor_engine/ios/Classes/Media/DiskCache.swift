// OWNER: IOS-03
//
// Engine disk caches and the launch wipe of work/ (ARCH §15, design/native.md §8.1). Caches live
// under <cache>/danaview/editor/{thumbs,waves,sprites,looks} and are LRU by access time (a hit
// touches the file's modification date, which serves as its access time because APFS does not
// keep atime): thumbs 300 MB, waves 64 MB, sprites 400 MB, looks 64 MB. Files used by an open
// session are pinned (never evicted). `trim(.clearAll)` ("Clear editor cache") is refused while a
// session or job is active.
//
// Launch wipe (`engineDidInitialize`): work/picks and work/drops entries older than 24 h are
// removed; every other entry of work/ is removed except
//   - paths registered as active (`DiskCache.markActive`, running jobs of this process),
//   - directories holding a resumable SegmentCheckpoint (IOS-17),
//   - outputs of unconsumed completedWhileDetached records, registered by IOS-13 with
//     `WorkExemptions.add(_:expires:)` (7-day expiry; expired ones are wiped).
//
// The stores are shared per cache root, so ThumbnailService/WaveformService (other instances)
// and this glue-facing service see the same LRU state (`DiskCache.stores(for:)`).

import Foundation

/// One LRU directory.
final class CacheStore {
    let directory: URL
    let capBytes: Int64
    private let lock = NSLock()
    private var pinned: [String: Int] = [:]

    init(directory: URL, capBytes: Int64) {
        self.directory = directory
        self.capBytes = capBytes
    }

    /// The file for [key] (sanitised file name) with [ext].
    func url(forKey key: String, ext: String) -> URL {
        directory.appendingPathComponent("\(CacheStore.fileName(key)).\(ext)")
    }

    /// The cached file for [key], touched as most recently used; nil on a miss.
    func lookup(key: String, ext: String) -> URL? {
        let url = url(forKey: key, ext: ext)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        touch(url)
        return url
    }

    /// Reads the cached bytes for [key] (touching it), nil on a miss.
    func read(key: String, ext: String) -> Data? {
        guard let url = lookup(key: key, ext: ext) else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// Stores [data] atomically under [key] and evicts down to the cap.
    @discardableResult
    func write(_ data: Data, key: String, ext: String) throws -> URL {
        try ensureDirectory()
        let url = url(forKey: key, ext: ext)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw EngineError.from(error)
        }
        evict(toBytes: capBytes)
        return url
    }

    func ensureDirectory() throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw EngineError.from(error)
        }
    }

    func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    // MARK: Pinning

    /// Pins [url] (counted): pinned files are never evicted.
    func pin(_ url: URL) {
        lock.lock()
        pinned[url.lastPathComponent, default: 0] += 1
        lock.unlock()
    }

    func unpin(_ url: URL) {
        lock.lock()
        let name = url.lastPathComponent
        if let count = pinned[name] {
            pinned[name] = count > 1 ? count - 1 : nil
        }
        lock.unlock()
    }

    func isPinned(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pinned[url.lastPathComponent] != nil
    }

    // MARK: Size and eviction

    struct Entry {
        var url: URL
        var bytes: Int64
        var accessed: Date
    }

    func entries() -> [Entry] {
        guard let names = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        else { return [] }
        return names.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else { return nil }
            return Entry(url: url, bytes: Int64(values.fileSize ?? 0), accessed: values.contentModificationDate ?? .distantPast)
        }
    }

    var totalBytes: Int64 { entries().reduce(0) { $0 + $1.bytes } }

    /// Deletes least recently used, unpinned files until the store holds at most [limit] bytes.
    /// Returns the bytes freed.
    @discardableResult
    func evict(toBytes limit: Int64) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        var all = entries()
        var total = all.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > limit else { return 0 }
        all.sort { $0.accessed < $1.accessed }
        var freed: Int64 = 0
        for entry in all where total > limit {
            if pinned[entry.url.lastPathComponent] != nil { continue }
            if (try? FileManager.default.removeItem(at: entry.url)) != nil {
                total -= entry.bytes
                freed += entry.bytes
            }
        }
        return freed
    }

    /// Deletes every unpinned file.
    @discardableResult
    func clear() -> Int64 { evict(toBytes: 0) }

    /// A file-system-safe name: [A-Za-z0-9._-] kept up to 120 characters, otherwise a hash.
    static func fileName(_ key: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        if !key.isEmpty, key.count <= 120, !key.hasPrefix("."), key.unicodeScalars.allSatisfy(allowed.contains) {
            return key
        }
        return stableHash(key)
    }

    /// 128-bit FNV-1a style hash as hex (stable across launches; not cryptographic).
    static func stableHash(_ text: String) -> String {
        var h1: UInt64 = 0xcbf2_9ce4_8422_2325
        var h2: UInt64 = 0x8422_2325_cbf2_9ce4
        for byte in text.utf8 {
            h1 = (h1 ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
            h2 = (h2 ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 &+ 0x9E37_79B9_7F4A_7C15
        }
        return String(format: "%016llx%016llx", h1, h2)
    }
}

/// Outputs exempt from the work/ launch wipe until an expiry (completedWhileDetached, D-39).
/// Persisted at <cache>/danaview/editor/work-exemptions.json (outside work/).
enum WorkExemptions {
    static let fileName = "work-exemptions.json"
    /// Default expiry of a completedWhileDetached output.
    static let detachedOutputLifetime: TimeInterval = 7 * 24 * 3600
    private static let lock = NSLock()

    private static func url(_ paths: Paths) -> URL { paths.cacheRoot.appendingPathComponent(fileName) }

    /// Relative path under work/ -> expiry (seconds since 1970).
    static func load(_ paths: Paths) -> [String: Double] {
        guard let data = try? Data(contentsOf: url(paths)),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: Double] else { return [:] }
        return map
    }

    private static func save(_ map: [String: Double], _ paths: Paths) {
        guard let data = try? JSONSerialization.data(withJSONObject: map, options: [.sortedKeys]) else { return }
        try? paths.ensureDirectory(paths.cacheRoot)
        try? data.write(to: url(paths), options: .atomic)
    }

    /// Exempts [file] (inside work/) from the wipe until [expires].
    static func add(_ file: URL, expires: Date = Date().addingTimeInterval(detachedOutputLifetime), paths: Paths) {
        guard let relative = relativePath(file, paths) else { return }
        lock.lock()
        defer { lock.unlock() }
        var map = load(paths)
        map[relative] = expires.timeIntervalSince1970
        save(map, paths)
    }

    /// Ends the exemption of [file] (record consumed).
    static func remove(_ file: URL, paths: Paths) {
        guard let relative = relativePath(file, paths) else { return }
        lock.lock()
        defer { lock.unlock() }
        var map = load(paths)
        map[relative] = nil
        save(map, paths)
    }

    /// Drops expired entries and returns the live ones (relative paths).
    static func live(_ paths: Paths, now: Date = Date()) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        let map = load(paths)
        let alive = map.filter { $0.value > now.timeIntervalSince1970 }
        if alive.count != map.count { save(alive, paths) }
        return Set(alive.keys)
    }

    static func relativePath(_ file: URL, _ paths: Paths) -> String? {
        let work = paths.work.standardizedFileURL.pathComponents
        let parts = file.standardizedFileURL.pathComponents
        guard parts.count > work.count, Array(parts.prefix(work.count)) == work else { return nil }
        return parts.dropFirst(work.count).joined(separator: "/")
    }
}

final class DiskCache: CacheMaintaining {
    private let context: EngineContext

    init(context: EngineContext) {
        self.context = context
    }

    // MARK: Caps (ARCH §15)

    static let thumbsCap: Int64 = 300 * 1024 * 1024
    static let wavesCap: Int64 = 64 * 1024 * 1024
    static let spritesCap: Int64 = 400 * 1024 * 1024
    static let looksCap: Int64 = 64 * 1024 * 1024
    /// work/picks and work/drops lifetime.
    static let pickLifetime: TimeInterval = 24 * 3600

    /// The shared stores of one cache root.
    final class Stores {
        let thumbs: CacheStore
        let waves: CacheStore
        let sprites: CacheStore
        let looks: CacheStore

        init(paths: Paths) {
            thumbs = CacheStore(directory: paths.thumbs, capBytes: DiskCache.thumbsCap)
            waves = CacheStore(directory: paths.waves, capBytes: DiskCache.wavesCap)
            sprites = CacheStore(directory: paths.sprites, capBytes: DiskCache.spritesCap)
            looks = CacheStore(directory: paths.looks, capBytes: DiskCache.looksCap)
        }

        var all: [CacheStore] { [thumbs, waves, sprites, looks] }
    }

    private static let registryLock = NSLock()
    private static var registry: [String: Stores] = [:]
    private static var activeCount = 0
    private static var activePaths: [String: Int] = [:]

    /// The stores of [paths] (one instance per cache root, process-wide).
    static func stores(for paths: Paths) -> Stores {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = registry[paths.cacheRoot.path] { return existing }
        let stores = Stores(paths: paths)
        registry[paths.cacheRoot.path] = stores
        return stores
    }

    // MARK: Activity (sessions and jobs)

    /// Marks a session or job active (clear is refused while any is). Balanced by `endActivity`.
    static func beginActivity() {
        registryLock.lock()
        activeCount += 1
        registryLock.unlock()
    }

    static func endActivity() {
        registryLock.lock()
        activeCount = max(0, activeCount - 1)
        registryLock.unlock()
    }

    static var isActive: Bool {
        registryLock.lock()
        defer { registryLock.unlock() }
        return activeCount > 0
    }

    /// Protects a work/ path of a running job from the wipe (balanced by `unmarkActive`).
    static func markActive(_ url: URL) {
        registryLock.lock()
        activePaths[url.standardizedFileURL.path, default: 0] += 1
        registryLock.unlock()
    }

    static func unmarkActive(_ url: URL) {
        registryLock.lock()
        let key = url.standardizedFileURL.path
        if let count = activePaths[key] { activePaths[key] = count > 1 ? count - 1 : nil }
        registryLock.unlock()
    }

    static var activeWorkPaths: Set<String> {
        registryLock.lock()
        defer { registryLock.unlock() }
        return Set(activePaths.keys)
    }

    // MARK: CacheMaintaining

    func engineDidInitialize(paths: Paths) {
        let started = Date()
        let stores = DiskCache.stores(for: paths)
        let wiped = DiskCache.wipeWork(paths: paths)
        for store in stores.all {
            store.evict(toBytes: store.capBytes)
        }
        Log.info(.engine, "caches ready: work wipe removed \(wiped) item(s) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
    }

    func trim(_ level: CacheTrimLevelMsg) {
        guard let paths = context.paths else { return }
        DiskCache.trim(level, paths: paths)
    }

    /// memoryPressure: in-memory caches only (thumbnail generators); background: evict to half the
    /// caps; clearAll: delete every unpinned file, refused while a session or job is active.
    /// Returns false when a clear was refused.
    @discardableResult
    static func trim(_ level: CacheTrimLevelMsg, paths: Paths) -> Bool {
        let stores = stores(for: paths)
        switch level {
        case .memoryPressure:
            ThumbnailService.dropGenerators()
        case .background:
            ThumbnailService.dropGenerators()
            for store in stores.all {
                store.evict(toBytes: store.capBytes / 2)
            }
        case .clearAll:
            if isActive {
                Log.info(.engine, "clear refused: a session or job is active")
                return false
            }
            ThumbnailService.dropGenerators()
            for store in stores.all {
                store.clear()
            }
        }
        return true
    }

    // MARK: work/ wipe

    /// The launch wipe of work/ (see the file comment). Returns the number of removed entries.
    @discardableResult
    static func wipeWork(paths: Paths, now: Date = Date()) -> Int {
        let fm = FileManager.default
        let work = paths.work
        guard let names = try? fm.contentsOfDirectory(atPath: work.path) else { return 0 }
        let active = activeWorkPaths
        let exempt = WorkExemptions.live(paths, now: now)
        var removed = 0

        func isProtected(_ url: URL) -> Bool {
            let path = url.standardizedFileURL.path
            if active.contains(where: { $0 == path || $0.hasPrefix(path + "/") || path.hasPrefix($0 + "/") }) { return true }
            guard let relative = WorkExemptions.relativePath(url, paths) else { return false }
            return exempt.contains { $0 == relative || $0.hasPrefix(relative + "/") }
        }

        for name in names {
            let url = work.appendingPathComponent(name)
            if name == "picks" || name == "drops" {
                removed += wipeOld(in: url, olderThan: now.addingTimeInterval(-pickLifetime), protected: isProtected)
                continue
            }
            if isProtected(url) { continue }
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
               SegmentCheckpoint.load(from: url) != nil {
                continue  // resumable job (IOS-17)
            }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    private static func wipeOld(in directory: URL, olderThan cutoff: Date, protected: (URL) -> Bool) -> Int {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey]) else { return 0 }
        var removed = 0
        for url in entries {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            let date = values?.contentModificationDate ?? values?.creationDate ?? .distantPast
            guard date < cutoff, !protected(url) else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }
}
