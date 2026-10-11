import XCTest

/// V-N20 / V-N11 fact finding (no assertion on the outcome, only that a report is produced):
/// start an export in the host app, press Home, stay in the background for 35 s, come back and
/// collect the experiment log. Run on a real iPhone (iOS 18 and iOS 26) for the authoritative
/// numbers; the simulator run only documents simulator behaviour.
///
/// Export length: 120 s of 1080p by default; set `TEST_RUNNER_VW_SECONDS=<n>` on the xcodebuild
/// command line to shorten it (the shared simulator host exported ~5 fps under load, so the
/// simulator documentation run uses 40 s). The wait for completion scales with the length.
final class BackgroundExportUITests: XCTestCase {
  private var seconds: Int {
    ProcessInfo.processInfo.environment["VW_SECONDS"].flatMap(Int.init) ?? 120
  }

  override func setUp() {
    continueAfterFailure = false
  }

  private func runExperiment(_ mode: String, backgroundSeconds: TimeInterval = 35) throws {
    let app = XCUIApplication()
    app.launchArguments = ["-vwExperiment", mode, "-vwSeconds", String(seconds)]
    app.launch()
    let status = app.staticTexts["status"]
    XCTAssertTrue(status.waitForExistence(timeout: 10))
    // Wait until media generation and composition are ready and frames flow.
    let ready = NSPredicate { _, _ in (status.label).contains("progress") || status.label.contains("ready") }
    expectation(for: ready, evaluatedWith: NSObject())
    waitForExpectations(timeout: 120)
    sleep(3)
    XCUIDevice.shared.press(.home)
    sleep(UInt32(backgroundSeconds))
    app.activate()
    let done = NSPredicate { _, _ in status.label.hasPrefix("done") }
    expectation(for: done, evaluatedWith: NSObject())
    waitForExpectations(timeout: max(600, Double(seconds) * 10))
    let log = app.textViews["log"].value as? String ?? ""
    let attachment = XCTAttachment(string: log)
    attachment.name = "background-\(mode).log"
    attachment.lifetime = .keepAlways
    add(attachment)
    for line in log.split(separator: "\n") { print("VWSPIKE-BG \(mode) \(line)") }
    XCTAssertTrue(log.contains("experiment \(mode) start"))
  }

  func testBackgroundPlainExport() throws { try runExperiment("plain") }

  func testBackgroundExportWithBackgroundTask() throws { try runExperiment("bgtask") }

  func testBackgroundSegmentedExportResumes() throws { try runExperiment("segmented") }
}
