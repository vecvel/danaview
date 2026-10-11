// OWNER: IOS-15
//
// Background leases and permissions (BUILD_PLAN IOS-15): lease begin/end/expiry events with an
// injected task system (the expiry handler cannot be triggered on demand by the real system), a
// real UIApplication lease on the simulator, notifications answering true, and the microphone
// status through AVAudioApplication on iOS 17+.

import AVFoundation
import XCTest

@testable import danaview_editor_engine

private final class FakeBackgroundTasks: BackgroundTaskSystem {
    var next = 1
    var refuse = false
    var begun: [(id: UIBackgroundTaskIdentifier, name: String, expire: () -> Void)] = []
    var ended: [UIBackgroundTaskIdentifier] = []

    func begin(name: String, expiration: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
        if refuse { return .invalid }
        let id = UIBackgroundTaskIdentifier(rawValue: next)
        next += 1
        begun.append((id, name, expiration))
        return id
    }

    func end(_ identifier: UIBackgroundTaskIdentifier) {
        ended.append(identifier)
    }
}

final class BackgroundGuardTests: XCTestCase {
    private var fixture: RecordingEngineFixture!
    private var tasks: FakeBackgroundTasks!
    private var guardian: BackgroundGuard!

    override func setUpWithError() throws {
        fixture = try RecordingEngineFixture()
        tasks = FakeBackgroundTasks()
        guardian = BackgroundGuard(context: fixture.context, system: tasks)
    }

    override func tearDown() {
        fixture.remove()
    }

    func testLeaseBeginUpdateAndEnd() throws {
        let id = try XCTUnwrap(try awaitReply(self) { guardian.acquire(title: "Exporting", reply: $0) })
        XCTAssertTrue(id.hasPrefix("lease-"))
        XCTAssertEqual(tasks.begun.map(\.name), ["Exporting"])
        XCTAssertEqual(guardian.activeLeaseIds, [id])

        try awaitReply(self) { guardian.update(leaseId: id, progress: 0.4, reply: $0) }
        XCTAssertEqual(guardian.progress(of: id), 0.4)

        try awaitReply(self) { guardian.release(leaseId: id, reply: $0) }
        XCTAssertEqual(tasks.ended, [tasks.begun[0].id])
        XCTAssertEqual(guardian.activeLeaseIds, [])

        // Idempotent: a second release and updates of unknown leases succeed without ending twice.
        try awaitReply(self) { guardian.release(leaseId: id, reply: $0) }
        try awaitReply(self) { guardian.update(leaseId: id, progress: 1, reply: $0) }
        XCTAssertEqual(tasks.ended.count, 1)
    }

    func testExpiryEmitsLeaseExpiringAndEndsTheTask() throws {
        let id = try XCTUnwrap(try awaitReply(self) { guardian.acquire(title: "Captions", reply: $0) })
        let other = try XCTUnwrap(try awaitReply(self) { guardian.acquire(title: "Export", reply: $0) })
        tasks.begun[0].expire()
        XCTAssertTrue(spin(until: { self.fixture.events.contains { $0.kind == .leaseExpiring } }))
        let expiring = fixture.events.filter { $0.kind == .leaseExpiring }
        XCTAssertEqual(expiring.map(\.jobId), [id], "event route = lease id")
        XCTAssertEqual(tasks.ended, [tasks.begun[0].id], "ended at once so the app is not killed")
        XCTAssertEqual(guardian.activeLeaseIds, [other])

        // Release after expiry is a no-op success; a repeated expiry is ignored.
        try awaitReply(self) { guardian.release(leaseId: id, reply: $0) }
        tasks.begun[0].expire()
        XCTAssertEqual(tasks.ended.count, 1)
    }

    func testRefusedTaskAnswersNil() throws {
        tasks.refuse = true
        XCTAssertNil(try awaitReply(self) { guardian.acquire(title: "x", reply: $0) })
        XCTAssertEqual(guardian.activeLeaseIds, [])
    }

    func testRealApplicationLease() throws {
        let real = BackgroundGuard(context: fixture.context)
        let id = try awaitReply(self) { real.acquire(title: "Danaview test lease", reply: $0) }
        let lease = try XCTUnwrap(id, "the simulator grants background tasks to the foreground app")
        XCTAssertEqual(real.activeLeaseIds, [lease])
        try awaitReply(self) { real.release(leaseId: lease, reply: $0) }
        XCTAssertEqual(real.activeLeaseIds, [])
    }

    // MARK: Permissions

    func testNotificationPermissionIsTrueOnIOS() throws {
        XCTAssertTrue(try awaitReply(self) { Permissions(context: fixture.context).requestNotificationPermission(reply: $0) })
    }

    func testMicrophoneStatusUsesAVAudioApplicationOnIOS17() {
        if #available(iOS 17.0, *) {
            XCTAssertEqual(Permissions.microphoneApi, "AVAudioApplication")
            let expected: Permissions.RecordPermission
            switch AVAudioApplication.shared.recordPermission {
            case .granted: expected = .granted
            case .denied: expected = .denied
            default: expected = .undetermined
            }
            XCTAssertEqual(Permissions.microphoneStatus(), expected)
            print("IOS-15 microphone status on this simulator: \(expected)")
        } else {
            XCTAssertEqual(Permissions.microphoneApi, "AVAudioSession")
        }
        XCTAssertEqual(Permissions.micPermission(.denied), .permanentlyDenied, "iOS denials need Settings")
        XCTAssertEqual(Permissions.micPermission(.granted), .granted)
        XCTAssertEqual(Permissions.micPermission(.undetermined), .undetermined)
    }
}
