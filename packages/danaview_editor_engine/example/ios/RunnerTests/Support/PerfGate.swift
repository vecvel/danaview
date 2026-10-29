// OWNER: ENG-09
//
// DV_PERF_STRICT for the iOS RunnerTests (CI round 6, the rule of the Dart and Android suites, see
// docs/v1.2/BUILD_STATE.md "DV_PERF_STRICT"): every absolute timing or throughput budget applies
// only with DV_PERF_STRICT=1 in the test process (a quiet dev Mac or a device; pass it to
// `xcodebuild test` as TEST_RUNNER_DV_PERF_STRICT=1, scripts/ci/editor/ios.sh forwards
// DV_PERF_STRICT). Without it (the hosted macos-26 VM) a budget becomes `looseFactor` times as
// generous, or a same-run baseline when the test has one. The measurement always runs and is
// printed; correctness checks never go through PerfGate; no test is skipped.

import XCTest

enum PerfGate {
    /// Whether absolute budgets apply (DV_PERF_STRICT=1).
    static let strict = ProcessInfo.processInfo.environment["DV_PERF_STRICT"] == "1"

    /// How much slower than the budget a loaded CI simulator may be without DV_PERF_STRICT.
    static let looseFactor = 4.0

    static var mode: String { strict ? "DV_PERF_STRICT=1" : "loose (no DV_PERF_STRICT)" }

    /// An upper limit: [limit] when strict; otherwise `looseFactor` × [limit], or [baseline] (a
    /// same-run measurement scaled by the caller) when that is larger.
    static func upperBound(_ limit: Double, baseline: Double? = nil) -> Double {
        strict ? limit : max(limit * looseFactor, baseline ?? 0)
    }

    /// A lower limit (throughput): [minimum] when strict; otherwise [minimum] / `looseFactor`.
    static func lowerBound(_ minimum: Double) -> Double {
        strict ? minimum : minimum / looseFactor
    }

    static func assertAtMost(_ value: Double, _ limit: Double, baseline: Double? = nil, _ what: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let bound = upperBound(limit, baseline: baseline)
        XCTAssertLessThanOrEqual(value, bound, "\(what): \(value) > \(bound) (\(mode); strict budget \(limit))", file: file, line: line)
    }

    static func assertAtLeast(_ value: Double, _ minimum: Double, _ what: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let bound = lowerBound(minimum)
        XCTAssertGreaterThanOrEqual(value, bound, "\(what): \(value) < \(bound) (\(mode); strict minimum \(minimum))", file: file, line: line)
    }
}
