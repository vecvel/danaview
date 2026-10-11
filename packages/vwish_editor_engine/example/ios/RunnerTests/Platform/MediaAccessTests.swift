// OWNER: IOS-15
//
// Media access (BUILD_PLAN IOS-15): quickHash equals the core fixtures
// (vwish_editor_core/test/fixtures/quickhash), stat/hash missing-file semantics, bookmarks that
// resolve in a fresh service instance (V-D3 in-process; the real relaunch is re-verified in QA-10),
// stale refresh after a rename, refcounted security scopes, backup exclusion readable back (V-D4)
// and the glue refusing directories outside the editor roots.

import Flutter
import XCTest

@testable import vwish_editor_engine

final class MediaAccessTests: XCTestCase {
    private var fixture: RecordingEngineFixture!
    private var access: MediaAccess!

    override func setUpWithError() throws {
        fixture = try RecordingEngineFixture()
        access = MediaAccess(context: fixture.context)
    }

    override func tearDown() {
        fixture.remove()
    }

    private func media(_ url: URL, bookmark: Data? = nil) -> MediaRefMsg {
        MediaRefMsg(uri: url.absoluteString, bookmark: bookmark.map { FlutterStandardTypedData(bytes: $0) })
    }

    // MARK: quickHash

    func testQuickHashEqualsCoreFixtures() throws {
        let vectorsURL = try XCTUnwrap(TestFixtures.url(.core, "quickhash/quickhash_vectors.json"), "core quickhash vectors missing")
        let doc = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: vectorsURL)) as? [String: Any])
        let cases = try XCTUnwrap(doc["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 7)
        for entry in cases {
            let name = try XCTUnwrap(entry["name"] as? String)
            let size = try XCTUnwrap(entry["size"] as? Int)
            let expected = try XCTUnwrap(entry["quickHash"] as? String)
            let url = fixture.roots.support.appendingPathComponent("media/\(name).bin")
            try writePatternFile(url, size: size)
            let hash = try awaitReply(self) { access.quickHash(media(url), fileURL: url, reply: $0) }
            XCTAssertEqual(hash, expected, name)
        }
    }

    func testQuickHashOfMissingFileIsMediaOffline() {
        let url = fixture.roots.support.appendingPathComponent("media/none.mp4")
        let error = awaitFailure(self) { access.quickHash(media(url), fileURL: url, reply: $0) }
        XCTAssertEqual(error?.code, .mediaOffline)
        XCTAssertFalse(error?.message.contains("/") ?? true, "no paths in messages")
    }

    func testQuickHashReadsOnlyBothEnds() throws {
        // A 32 MiB sparse file hashes quickly and equals the head/tail formula.
        let url = fixture.roots.support.appendingPathComponent("media/big.bin")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data("head".utf8))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 32 << 20)
        try handle.close()
        let started = Date()
        let hash = try MediaAccess.quickHash(of: url)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        var head = Data("head".utf8)
        head.append(Data(count: 64 * 1024 - 4))
        XCTAssertEqual(hash, MediaAccess.quickHash(head: head, tail: Data(count: 64 * 1024), size: UInt64(32 << 20)))
    }

    // MARK: stat

    func testStatReturnsSizeAndModificationTimeAndNilWhenMissing() throws {
        let url = fixture.roots.support.appendingPathComponent("media/a.bin")
        try writePatternFile(url, size: 1234)
        let date = Date(timeIntervalSince1970: 1_700_000_000.25)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        let stat = try XCTUnwrap(try awaitReply(self) { access.stat(media(url), fileURL: url, reply: $0) })
        XCTAssertEqual(stat.sizeBytes, 1234)
        XCTAssertEqual(stat.modifiedMs, 1_700_000_000_250)

        let missing = fixture.roots.support.appendingPathComponent("media/missing.bin")
        XCTAssertNil(try awaitReply(self) { access.stat(media(missing), fileURL: missing, reply: $0) })
    }

    // MARK: Bookmarks

    func testBookmarkResolvesInAFreshInstance() throws {
        // V-D3 (in process): a bookmark made by one engine resolves in another one built from
        // scratch, as after a relaunch. QA-10 repeats this across a real relaunch.
        let url = fixture.roots.base.appendingPathComponent("Files/clip.mov")
        try writePatternFile(url, size: 4096)
        let bookmark = try awaitReply(self) { access.createBookmark(fileURL: url, reply: $0) }
        XCTAssertFalse(bookmark.isEmpty)

        let other = try RecordingEngineFixture()
        defer { other.remove() }
        let fresh = MediaAccess(context: other.context, scopes: ScopedAccessRegistry())
        let resolved = try awaitReply(self) { fresh.resolveBookmark(bookmark, reply: $0) }
        XCTAssertEqual(URL(string: resolved.uri)?.resolvingSymlinksInPath().path, url.resolvingSymlinksInPath().path)
        XCTAssertFalse(resolved.stale)
        XCTAssertNil(resolved.refreshedBookmark)

        // stat and quickHash work through the bookmark (the uri is ignored when a bookmark exists).
        let bogus = fixture.roots.base.appendingPathComponent("elsewhere.mov")
        let stat = try awaitReply(self) { fresh.stat(media(bogus, bookmark: bookmark), fileURL: bogus, reply: $0) }
        XCTAssertEqual(stat?.sizeBytes, 4096)
        let hash = try awaitReply(self) { fresh.quickHash(media(bogus, bookmark: bookmark), fileURL: bogus, reply: $0) }
        XCTAssertEqual(hash, try MediaAccess.quickHash(of: url))
    }

    func testRenamedFileResolvesAndStaleBookmarkIsRefreshed() throws {
        let url = fixture.roots.base.appendingPathComponent("Files/before.mov")
        try writePatternFile(url, size: 2048)
        let bookmark = try access.createBookmark(url)
        let renamed = fixture.roots.base.appendingPathComponent("Files/after.mov")
        try FileManager.default.moveItem(at: url, to: renamed)

        let resolved = try awaitReply(self) { access.resolveBookmark(bookmark, reply: $0) }
        XCTAssertEqual(URL(string: resolved.uri)?.resolvingSymlinksInPath().path, renamed.resolvingSymlinksInPath().path)
        if resolved.stale {
            let refreshed = try XCTUnwrap(resolved.refreshedBookmark, "a stale bookmark must be recreated")
            let again = try access.resolve(refreshed.data)
            XCTAssertEqual(again.url.resolvingSymlinksInPath().path, renamed.resolvingSymlinksInPath().path)
        }
    }

    func testDeletedBookmarkTargetIsOfflineAndGarbageIsAccessLost() throws {
        let url = fixture.roots.base.appendingPathComponent("Files/gone.mov")
        try writePatternFile(url, size: 10)
        let bookmark = try access.createBookmark(url)
        try FileManager.default.removeItem(at: url)
        let error = awaitFailure(self) { access.resolveBookmark(bookmark, reply: $0) }
        XCTAssertEqual(error?.code, .mediaOffline)
        let stat = try awaitReply(self) { access.stat(media(url, bookmark: bookmark), fileURL: url, reply: $0) }
        XCTAssertNil(stat, "stat answers nil for a missing bookmarked file")

        let garbage = awaitFailure(self) { access.resolveBookmark(Data([1, 2, 3, 4, 5, 6, 7, 8]), reply: $0) }
        XCTAssertEqual(garbage?.code, .permissionDenied)
    }

    func testCreateBookmarkOfMissingFileIsMediaOffline() {
        let url = fixture.roots.base.appendingPathComponent("Files/none.mov")
        XCTAssertEqual(awaitFailure(self) { access.createBookmark(fileURL: url, reply: $0) }?.code, .mediaOffline)
    }

    func testSecurityScopesAreRefcounted() {
        let scopes = ScopedAccessRegistry()
        let url = fixture.roots.base.appendingPathComponent("x.mov")
        scopes.begin(url)
        scopes.begin(url)
        XCTAssertEqual(scopes.count(url), 2)
        scopes.end(url)
        XCTAssertEqual(scopes.count(url), 1)
        scopes.with(url) { XCTAssertEqual(scopes.count(url), 2) }
        scopes.end(url)
        XCTAssertEqual(scopes.count(url), 0)
        scopes.end(url)  // unbalanced end is ignored
        XCTAssertEqual(scopes.count(url), 0)
    }

    // MARK: Grants

    func testGrantsAreNoOpsAndTheBudgetIsUnbounded() throws {
        XCTAssertNoThrow(try awaitReply(self) { access.persistUriGrant(uri: "content://x", reply: $0) })
        XCTAssertNoThrow(try awaitReply(self) { access.releaseUriGrant(uri: "content://x", reply: $0) })
        XCTAssertEqual(try awaitReply(self) { access.remainingGrantBudget(reply: $0) }, Int64(Int32.max))
    }

    // MARK: Backup exclusion (V-D4)

    func testExcludeFromBackupSetsTheFlagOnADirectoryAndItReadsBack() throws {
        let dir = fixture.roots.support.appendingPathComponent("projects", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        try awaitReply(self) { access.excludeFromBackup(directoryURL: dir, reply: $0) }
        XCTAssertTrue(try MediaAccess.isExcludedFromBackup(dir))

        let speech = fixture.paths.speechRoot
        try awaitReply(self) { access.excludeFromBackup(directoryURL: speech, reply: $0) }
        XCTAssertTrue(try MediaAccess.isExcludedFromBackup(speech))
    }

    func testGlueRefusesExclusionOutsideTheEditorRoots() throws {
        let services = EngineServices.make(context: fixture.context)
        let api = PlatformHostApiImpl(context: fixture.context, services: services)
        let outside = fixture.roots.base.appendingPathComponent("Documents", isDirectory: true)
        let done = expectation(description: "reply")
        var result: Result<Void, Error>?
        api.excludeFromBackup(path: outside.path) {
            result = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertThrowsError(try XCTUnwrap(result).get()) { error in
            XCTAssertEqual(EngineError.from(error).code, .permissionDenied)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))

        let inside = fixture.roots.cache.appendingPathComponent("thumbs", isDirectory: true)
        let ok = expectation(description: "inside")
        var insideResult: Result<Void, Error>?
        api.excludeFromBackup(path: inside.path) { reply in
            insideResult = reply
            ok.fulfill()
        }
        wait(for: [ok], timeout: 5)
        XCTAssertNoThrow(try XCTUnwrap(insideResult).get())
        XCTAssertTrue(try MediaAccess.isExcludedFromBackup(inside))
    }
}
