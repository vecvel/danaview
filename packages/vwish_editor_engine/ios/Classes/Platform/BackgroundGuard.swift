// OWNER: IOS-15
//
// Background leases (ARCH §12.4, §15, D-22): one `UIApplication.beginBackgroundTask` per lease,
// with pause semantics. iOS gives a few seconds to half a minute after backgrounding; when the
// system is about to expire the task, the lease emits `leaseExpiring` (event route = lease id),
// and the task is ended right away so the app is not killed. Dart then pauses its work (export
// segments, speech jobs) and resumes on foreground; native never keeps running past the expiry.
//
// - `acquire` answers nil when the system refuses a task (`.invalid`).
// - `update` records progress (iOS shows no lease UI); unknown or expired leases are ignored.
// - `release` is idempotent: unknown, expired or already released leases succeed.
//
// All calls run on main (the glue's queue); the expiration handler also runs on main.

import Foundation
import UIKit

/// The system calls BackgroundGuard needs (injectable for tests).
protocol BackgroundTaskSystem: AnyObject {
    func begin(name: String, expiration: @escaping () -> Void) -> UIBackgroundTaskIdentifier
    func end(_ identifier: UIBackgroundTaskIdentifier)
}

/// `UIApplication.shared` as a BackgroundTaskSystem.
final class ApplicationBackgroundTasks: BackgroundTaskSystem {
    func begin(name: String, expiration: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: expiration)
    }

    func end(_ identifier: UIBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(identifier)
    }
}

final class BackgroundGuard: BackgroundLeasing {
    private struct Lease {
        let task: UIBackgroundTaskIdentifier
        var progress: Double
    }

    private let context: EngineContext
    private let system: BackgroundTaskSystem
    /// Active leases by id (main thread).
    private var leases: [String: Lease] = [:]

    init(context: EngineContext) {
        self.context = context
        self.system = ApplicationBackgroundTasks()
    }

    /// Tests inject the system.
    init(context: EngineContext, system: BackgroundTaskSystem) {
        self.context = context
        self.system = system
    }

    /// Ids of the active leases (tests).
    var activeLeaseIds: [String] { onMain { Array(leases.keys).sorted() } }

    /// Last progress reported for [leaseId] (tests).
    func progress(of leaseId: String) -> Double? { onMain { leases[leaseId]?.progress } }

    func acquire(title: String, reply: @escaping EngineReply<String?>) {
        onMain {
            let leaseId = "lease-" + UUID().uuidString.lowercased()
            let name = title.isEmpty ? "Vwish editor" : String(title.prefix(64))
            let task = system.begin(name: name) { [weak self] in
                self?.expire(leaseId)
            }
            guard task != .invalid else {
                Log.info(.platform, "background lease refused by the system")
                reply(.success(nil))
                return
            }
            leases[leaseId] = Lease(task: task, progress: 0)
            Log.debug(.platform, "lease \(leaseId) acquired")
            reply(.success(leaseId))
        }
    }

    func update(leaseId: String, progress: Double, reply: @escaping EngineReply<Void>) {
        onMain {
            if var lease = leases[leaseId] {
                lease.progress = min(1, max(0, progress.isFinite ? progress : 0))
                leases[leaseId] = lease
            }
            reply(.success(()))
        }
    }

    func release(leaseId: String, reply: @escaping EngineReply<Void>) {
        onMain {
            if let lease = leases.removeValue(forKey: leaseId) {
                system.end(lease.task)
                Log.debug(.platform, "lease \(leaseId) released")
            }
            reply(.success(()))
        }
    }

    /// The system is about to expire the task: tell Dart (pause) and end it at once.
    private func expire(_ leaseId: String) {
        onMain {
            guard let lease = leases.removeValue(forKey: leaseId) else { return }
            Log.info(.platform, "lease \(leaseId) expiring")
            context.events.emitLeaseExpiring(leaseId: leaseId)
            system.end(lease.task)
        }
    }

    private func onMain<T>(_ work: () -> T) -> T {
        if Thread.isMainThread { return work() }
        return DispatchQueue.main.sync(execute: work)
    }
}
