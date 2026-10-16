// OWNER: FIX-IOS-RANGE-VECTORS
//
// FIX-IOS-19-1 (BUILD_STATE.md, filed by the review of FIX-RANGE-RULE): the iOS rendered-range
// drop rule replays the shared vectors `danaview_editor_core/test/fixtures/vectors/range_touch.json`
// (written by core's `test/plan/render_cache/range_rule_test.dart`, the Dart mirror
// `rangeTouched`). For every plan pair and every range of `before`,
// `RenderedRangeRules.changeTouches(before, after, range)` must equal the vector's `touched`, so
// Dart and Swift agree on which renders are dropped (layer `!=` is Swift struct equality here and
// Dart model equality there; the vectors pin both to the same verdicts).
//
// The same verdicts must hold through the swap itself: ranges bound to `before` and reconciled
// against `after` (a plan the swap was not told about) keep exactly the untouched ones.
//
// The vectors are in the test bundle through the `core` fixture tree (ENG-09's TestFixtures).

import XCTest

@testable import danaview_editor_engine

final class RangeTouchVectorTests: XCTestCase {
    private struct VectorRange {
        let startUs: Int64
        let endUs: Int64
        let touched: Bool
        let sameHash: Bool
    }

    private struct VectorCase {
        let name: String
        let before: RenderPlan
        let after: RenderPlan
        let ranges: [VectorRange]
    }

    private func loadCases() throws -> [VectorCase] {
        let url = try XCTUnwrap(TestFixtures.url(.core, "vectors/range_touch.json"),
                                "vectors/range_touch.json missing from the core fixture tree")
        guard case .object(let doc) = try PlanJSONReader.parse(Data(contentsOf: url)),
              case .int(let v)? = doc["v"], case .array(let rawCases)? = doc["cases"]
        else {
            XCTFail("range_touch.json shape")
            return []
        }
        XCTAssertEqual(v, 1, "range_touch.json version")
        var cases: [VectorCase] = []
        for (i, raw) in rawCases.enumerated() {
            guard case .object(let c) = raw, case .string(let name)? = c["name"],
                  case .array(let rawRanges)? = c["ranges"]
            else {
                XCTFail("case \(i) shape")
                continue
            }
            let before = try RenderPlanDecoder.decodePlan(RenderPlanDecoder.object(c["before"], "before"))
            let after = try RenderPlanDecoder.decodePlan(RenderPlanDecoder.object(c["after"], "after"))
            var ranges: [VectorRange] = []
            for (k, r) in rawRanges.enumerated() {
                guard case .object(let o) = r, case .int(let s)? = o["s"], case .int(let e)? = o["e"],
                      case .bool(let touched)? = o["touched"], case .bool(let sameHash)? = o["sameHash"]
                else {
                    XCTFail("\(name): range \(k) shape")
                    continue
                }
                ranges.append(VectorRange(startUs: s, endUs: e, touched: touched, sameHash: sameHash))
            }
            cases.append(VectorCase(name: name, before: before, after: after, ranges: ranges))
        }
        return cases
    }

    private func rendered(_ r: VectorRange, _ i: Int) -> RenderedRange {
        RenderedRange(startUs: r.startUs, endUs: r.endUs, fileURL: URL(fileURLWithPath: "/tmp/range-\(i).mp4"),
                      hash: "h\(i)")
    }

    func testVectorsAreNonTrivial() throws {
        let cases = try loadCases()
        XCTAssertGreaterThanOrEqual(cases.count, 40)
        let all = cases.flatMap(\.ranges)
        XCTAssertGreaterThan(all.filter(\.touched).count, 0, "no touched range in the vectors")
        XCTAssertGreaterThan(all.filter { !$0.touched }.count, 0, "no kept range in the vectors")
        for c in cases {
            XCTAssertFalse(c.ranges.isEmpty, "\(c.name): no ranges")
            // The vector invariant (P1): a range the engine keeps has the same Dart hash.
            for r in c.ranges where !r.touched {
                XCTAssertTrue(r.sameHash, "\(c.name): kept range [\(r.startUs), \(r.endUs)) has a different hash")
            }
        }
    }

    func testChangeTouchesMatchesDartForEveryPlanPair() throws {
        let cases = try loadCases()
        var checked = 0
        for c in cases {
            for (i, r) in c.ranges.enumerated() {
                let got = RenderedRangeRules.changeTouches(before: c.before, after: c.after, range: rendered(r, i))
                XCTAssertEqual(got, r.touched,
                               "\(c.name): range [\(r.startUs), \(r.endUs)) touched=\(got), Dart says \(r.touched)")
                checked += 1
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 200)
    }

    func testSwapReconciliationKeepsExactlyTheUntouchedRanges() throws {
        for c in try loadCases() {
            let swap = RenderedRangeSwap()
            let ranges = c.ranges.enumerated().map { rendered($0.element, $0.offset) }
            swap.setRanges(ranges, plan: c.before)
            var after = c.after
            // The swap only reconciles a plan of another revision; a live session's revisions
            // always advance (the "commands" vectors compile both plans at revision 0).
            if after.rev == c.before.rev { after.rev = c.before.rev + 1 }
            let kept = swap.validRanges(for: after).map { [$0.startUs, $0.endUs] }
            let expected = c.ranges.filter { !$0.touched }.map { [$0.startUs, $0.endUs] }
            XCTAssertEqual(kept.sorted { ($0[0], $0[1]) < ($1[0], $1[1]) },
                           expected.sorted { ($0[0], $0[1]) < ($1[0], $1[1]) }, c.name)
        }
    }
}
