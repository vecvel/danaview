// OWNER: IOS-19
//
// The power/idle signal (ARCH D-45, §12.4): charging from `UIDevice.batteryState` (.charging or
// .full), Low Power Mode from `ProcessInfo`, battery monitoring switched on, `powerStateChanged`
// signals only when the state changes (battery-state and power-state notifications).

import UIKit
import XCTest

@testable import danaview_editor_engine

private final class ScriptedPowerSource: PowerStateSource {
    var monitoringEnabled = false
    var batteryState: UIDevice.BatteryState = .unplugged
    var isLowPowerModeEnabled = false
    func enableBatteryMonitoring() { monitoringEnabled = true }
}

final class PowerStateMonitorTests: XCTestCase {
    private var roots: TempRoots!

    override func setUpWithError() throws {
        roots = try TempRoots()
    }

    override func tearDown() {
        roots?.remove()
    }

    private func signals(_ recorder: JobEventRecorder) -> [PowerStateMsg] {
        recorder.events.compactMap { $0.signal?.kind == .powerStateChanged ? $0.signal?.powerState : nil }
    }

    func testMapsBatteryAndLowPowerState() {
        XCTAssertEqual(PowerStateMonitor.state(battery: .charging, lowPowerMode: false), PowerStateMsg(charging: true, lowPowerMode: false))
        XCTAssertEqual(PowerStateMonitor.state(battery: .full, lowPowerMode: true), PowerStateMsg(charging: true, lowPowerMode: true))
        XCTAssertEqual(PowerStateMonitor.state(battery: .unplugged, lowPowerMode: false), PowerStateMsg(charging: false, lowPowerMode: false))
        XCTAssertEqual(PowerStateMonitor.state(battery: .unknown, lowPowerMode: true), PowerStateMsg(charging: false, lowPowerMode: true))
    }

    func testAnswersAndSignalsChanges() throws {
        let recorder = JobEventRecorder()
        let context = try MediaJobTestSupport.context(roots, events: recorder.hub)
        let source = ScriptedPowerSource()
        let center = NotificationCenter()
        let monitor = PowerStateMonitor(context: context, source: source, center: center)
        XCTAssertTrue(source.monitoringEnabled, "battery monitoring is switched on")

        var reply: Result<PowerStateMsg, Error>?
        monitor.powerState { reply = $0 }
        XCTAssertEqual(try reply?.get(), PowerStateMsg(charging: false, lowPowerMode: false))

        source.batteryState = .charging
        center.post(name: UIDevice.batteryStateDidChangeNotification, object: nil)
        XCTAssertTrue(JobEventRecorder.spin(timeout: 5) { self.signals(recorder).count == 1 })
        XCTAssertEqual(signals(recorder).last, PowerStateMsg(charging: true, lowPowerMode: false))

        // No change: no signal.
        center.post(name: UIDevice.batteryStateDidChangeNotification, object: nil)
        // Low Power Mode, posted off the main thread like the system does.
        source.isLowPowerModeEnabled = true
        DispatchQueue.global().async { center.post(name: .NSProcessInfoPowerStateDidChange, object: nil) }
        XCTAssertTrue(JobEventRecorder.spin(timeout: 5) { self.signals(recorder).count == 2 })
        XCTAssertEqual(signals(recorder), [
            PowerStateMsg(charging: true, lowPowerMode: false), PowerStateMsg(charging: true, lowPowerMode: true),
        ])

        monitor.powerState { reply = $0 }
        XCTAssertEqual(try reply?.get(), PowerStateMsg(charging: true, lowPowerMode: true))
    }

    func testSystemMonitorAnswersOnTheSimulator() throws {
        let context = try MediaJobTestSupport.context(roots)
        let monitor = PowerStateMonitor(context: context)
        var reply: Result<PowerStateMsg, Error>?
        monitor.powerState { reply = $0 }
        XCTAssertTrue(JobEventRecorder.spin(timeout: 5) { reply != nil })
        XCTAssertNoThrow(try reply?.get())
    }
}
