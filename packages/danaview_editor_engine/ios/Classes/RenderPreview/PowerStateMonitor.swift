// OWNER: IOS-19
//
// D-33 placeholder created by INT-06 (ARCH D-45, §12.4): the power/idle signal. IOS-19 replaces
// the body: it reports charging (`UIDevice.batteryState` .charging/.full, with battery monitoring
// enabled) and Low Power Mode (`ProcessInfo.isLowPowerModeEnabled`) and emits
// `signal(powerStateChanged, powerState)` through `EventHub.emitSignal` when either changes. Keep
// `init(context:)` and the `PowerStateProviding` conformance.

import Foundation

final class PowerStateMonitor: PowerStateProviding {
    private let context: EngineContext

    init(context: EngineContext) {
        self.context = context
    }

    func powerState(reply: @escaping EngineReply<PowerStateMsg>) {
        reply(.failure(EngineError.notSupportedOnDevice("power state")))
    }
}
