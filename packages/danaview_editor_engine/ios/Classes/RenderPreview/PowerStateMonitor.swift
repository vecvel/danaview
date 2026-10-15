// OWNER: IOS-19
//
// The power/idle signal (ARCH D-45, §12.4; created as a D-33 placeholder by INT-06): reports
// charging (`UIDevice.batteryState` `.charging` or `.full`, battery monitoring enabled) and Low
// Power Mode (`ProcessInfo.isLowPowerModeEnabled`), and emits `signal(powerStateChanged,
// powerState)` through `EventHub.emitSignal` whenever either changes. UX-44 combines it with its
// own editor-idle timer for the automatic render-preview default on the minimal and low tiers.
//
// Threading: the glue calls `powerState` on main (ServiceProtocols: queue main). Observation starts
// on main at init (or on the first call) and listens to `UIDevice.batteryStateDidChangeNotification`
// and `NSProcessInfoPowerStateDidChange` (posted on arbitrary threads; handled on main). The
// simulator reports `.unknown` battery state, i.e. not charging.

import Foundation
import UIKit

/// Where the monitor reads the device state (tests inject a scripted source).
protocol PowerStateSource: AnyObject {
    /// Turns battery monitoring on (main thread).
    func enableBatteryMonitoring()
    var batteryState: UIDevice.BatteryState { get }
    var isLowPowerModeEnabled: Bool { get }
}

/// The system source: `UIDevice.current` and `ProcessInfo.processInfo`.
final class SystemPowerStateSource: PowerStateSource {
    func enableBatteryMonitoring() { UIDevice.current.isBatteryMonitoringEnabled = true }
    var batteryState: UIDevice.BatteryState { UIDevice.current.batteryState }
    var isLowPowerModeEnabled: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
}

final class PowerStateMonitor: PowerStateProviding {
    private let context: EngineContext
    private let source: PowerStateSource
    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var started = false
    /// The last state reported (signals fire only on a change).
    private(set) var lastState: PowerStateMsg?

    convenience init(context: EngineContext) {
        self.init(context: context, source: SystemPowerStateSource(), center: .default)
    }

    init(context: EngineContext, source: PowerStateSource, center: NotificationCenter) {
        self.context = context
        self.source = source
        self.center = center
        if Thread.isMainThread {
            start()
        } else {
            DispatchQueue.main.async { [weak self] in self?.start() }
        }
    }

    deinit {
        observers.forEach(center.removeObserver)
    }

    /// Maps the device facts to the message.
    static func state(battery: UIDevice.BatteryState, lowPowerMode: Bool) -> PowerStateMsg {
        PowerStateMsg(charging: battery == .charging || battery == .full, lowPowerMode: lowPowerMode)
    }

    /// The current state (main thread).
    func currentState() -> PowerStateMsg {
        PowerStateMonitor.state(battery: source.batteryState, lowPowerMode: source.isLowPowerModeEnabled)
    }

    func powerState(reply: @escaping EngineReply<PowerStateMsg>) {
        let run = { [self] in
            start()
            let state = currentState()
            lastState = state
            reply(.success(state))
        }
        if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
    }

    /// Starts observing (main thread; idempotent).
    func start() {
        guard !started else { return }
        started = true
        source.enableBatteryMonitoring()
        lastState = currentState()
        let changed: (Notification) -> Void = { [weak self] _ in
            if Thread.isMainThread {
                self?.refresh()
            } else {
                DispatchQueue.main.async { self?.refresh() }
            }
        }
        observers.append(center.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: nil, using: changed))
        observers.append(center.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: nil, using: changed))
    }

    /// Re-reads the state and emits `powerStateChanged` when it changed (main thread).
    func refresh() {
        let state = currentState()
        guard state != lastState else { return }
        lastState = state
        context.events.emitSignal(SignalMsg(kind: .powerStateChanged, powerState: state))
    }
}
