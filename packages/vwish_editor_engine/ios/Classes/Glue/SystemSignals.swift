// OWNER: ENG-07 (frozen by ENG-06)
//
// Engine-wide signals (ARCH §12.1, §18.3): a memory warning emits `signal(memoryWarning)` and
// trims the caches at `memoryPressure`; thermal state changes emit `signal(thermal, level)`
// (QualityGovernor, IOS-11, reacts to `serious` natively as well).

import Foundation
import UIKit

final class SystemSignals {
    private let context: EngineContext
    private let services: EngineServices
    private var observers: [NSObjectProtocol] = []
    private var lastThermal: ThermalLevelMsg?

    init(context: EngineContext, services: EngineServices) {
        self.context = context
        self.services = services
    }

    /// Starts observing (main thread).
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) {
                [weak self] _ in self?.memoryWarning()
            })
        observers.append(
            center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) {
                [weak self] _ in self?.thermalStateChanged(ProcessInfo.processInfo.thermalState)
            })
    }

    /// Stops observing (main thread).
    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func memoryWarning() {
        Log.info(.engine, "memory warning")
        context.events.emitSignal(SignalMsg(kind: .memoryWarning))
        let caches = services.caches
        context.queues.engine.async { caches.trim(.memoryPressure) }
    }

    func thermalStateChanged(_ state: ProcessInfo.ThermalState) {
        let level = SystemSignals.thermalLevel(state)
        guard level != lastThermal else { return }
        lastThermal = level
        Log.info(.engine, "thermal \(level)")
        context.events.emitSignal(SignalMsg(kind: .thermal, thermalLevel: level))
    }

    static func thermalLevel(_ state: ProcessInfo.ThermalState) -> ThermalLevelMsg {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .critical
        }
    }
}
