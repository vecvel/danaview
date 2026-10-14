// OWNER: IOS-08
//
// RenderPlan contract corpus on iOS (ARCH §11.9, BUILD_PLAN IOS-08): every valid fixture decodes
// and re-encodes byte for byte (and passes the native validator), every `invalid/` fixture reports
// the expected code and id and nothing else, every `invalid_format/` document fails at the expected
// path, and the `tolerant/` documents decode to their canonical siblings.

import XCTest

@testable import danaview_editor_engine

final class PlanContractTests: XCTestCase {
    private func reencode(_ data: Data) throws -> Data {
        guard case .object(let o) = try PlanJSONReader.parse(data) else { throw PlanFormatError("expected an object") }
        if o["rev"] != nil { return PlanEncoder.encode(try RenderPlanDecoder.decodePlan(data)) }
        if o["from"] != nil { return PlanEncoder.encode(try RenderPlanDecoder.decodePatch(data)) }
        return PlanEncoder.encode(try RenderPlanDecoder.decodeTransient(data))
    }

    func testEveryValidFixtureRoundTripsByteIdentically() throws {
        let files = try CompositionTestSupport.jsonFiles(CompositionTestSupport.contractDir())
        XCTAssertGreaterThanOrEqual(files.count, 25)
        var kinds = Set<String>()
        for url in files {
            let name = url.lastPathComponent
            let data = try CompositionTestSupport.bytes(url)
            let out = try reencode(data)
            XCTAssertEqual(String(decoding: out, as: UTF8.self), String(decoding: data, as: UTF8.self), name)
            guard case .object(let o) = try PlanJSONReader.parse(data) else { continue }
            if o["rev"] != nil {
                kinds.insert("plan")
                let plan = try RenderPlanDecoder.decodePlan(data)
                XCTAssertEqual(PlanValidator.validate(plan), [], name)
                XCTAssertEqual(try RenderPlanDecoder.decodePlan(PlanEncoder.encode(plan)), plan, "\(name): typed equality survives")
            } else if o["from"] != nil {
                kinds.insert("patch")
                let patch = try RenderPlanDecoder.decodePatch(data)
                XCTAssertEqual(try RenderPlanDecoder.decodePatch(PlanEncoder.encode(patch)), patch, name)
            } else {
                kinds.insert("transient")
                let t = try RenderPlanDecoder.decodeTransient(data)
                XCTAssertEqual(try RenderPlanDecoder.decodeTransient(PlanEncoder.encode(t)), t, name)
            }
        }
        XCTAssertEqual(kinds, ["plan", "patch", "transient"])
    }

    func testInvalidFixturesReportTheExpectedCodeAndIdOnly() throws {
        let files = try CompositionTestSupport.jsonFiles(CompositionTestSupport.contractDir().appendingPathComponent("invalid"))
        XCTAssertFalse(files.isEmpty)
        var codes = Set<String>()
        for url in files {
            let name = url.lastPathComponent
            let data = try CompositionTestSupport.bytes(url)
            guard case .object(let o) = try PlanJSONReader.parse(data), case .object(let expect)? = o["_expect"],
                  case .string(let code)? = expect["code"]
            else { return XCTFail("\(name): no _expect") }
            var id: String?
            if case .string(let s)? = expect["id"] { id = s }
            codes.insert(code)
            let violations = PlanValidator.validate(try RenderPlanDecoder.decodePlan(o))
            XCTAssertTrue(
                violations.contains { $0.code.rawValue == code && $0.id == id },
                "\(name): expected \(code) on \(id ?? "nil"), got \(violations)")
            XCTAssertEqual(violations.filter { $0.code.rawValue != code }, [], "\(name) isolates one invariant")
        }
        XCTAssertEqual(codes, Set(PlanViolationCode.allCases.filter { $0 != .version }.map(\.rawValue)))
    }

    func testMalformedDocumentsFailAtTheExpectedPath() throws {
        let files = try CompositionTestSupport.jsonFiles(CompositionTestSupport.contractDir().appendingPathComponent("invalid_format"))
        XCTAssertFalse(files.isEmpty)
        for url in files {
            let name = url.lastPathComponent
            let data = try CompositionTestSupport.bytes(url)
            guard case .object(let o) = try PlanJSONReader.parse(data), case .object(let expect)? = o["_expect"],
                  case .string(let path)? = expect["path"]
            else { return XCTFail("\(name): no _expect.path") }
            XCTAssertThrowsError(try RenderPlanDecoder.decodePlan(o), name) { error in
                XCTAssertEqual((error as? PlanFormatError)?.path, path, "\(name): \(error)")
            }
        }
        XCTAssertThrowsError(try RenderPlanDecoder.decodePlan(Data("{\"v\":".utf8)))
        XCTAssertThrowsError(try RenderPlanDecoder.decodePlan(Data("[]".utf8)))
        XCTAssertThrowsError(try RenderPlanDecoder.decodePatch(Data(#"{"v":2,"from":1,"to":2}"#.utf8)))
        XCTAssertThrowsError(try RenderPlanDecoder.decodeTransient(Data(#"{"v":0,"item":"x","layers":[]}"#.utf8)))
    }

    func testTolerantDocumentsDecodeToTheirCanonicalSiblings() throws {
        let dir = try CompositionTestSupport.contractDir()
        let loose = try RenderPlanDecoder.decodePlan(CompositionTestSupport.bytes(dir.appendingPathComponent("tolerant/plan_unknown_keys.json")))
        let canonicalBytes = try CompositionTestSupport.bytes(dir.appendingPathComponent("minimal_preview.json"))
        XCTAssertEqual(loose, try RenderPlanDecoder.decodePlan(canonicalBytes))
        XCTAssertEqual(PlanEncoder.encode(loose), canonicalBytes)

        let patch = try RenderPlanDecoder.decodePatch(CompositionTestSupport.bytes(dir.appendingPathComponent("tolerant/patch_unknown_keys.json")))
        XCTAssertEqual(patch.from, 7)
        XCTAssertEqual(patch.to, 8)
        XCTAssertEqual(patch.layers.remove, ["it_x#v"])
        XCTAssertEqual(patch.layers.upsert, [])

        let t = try RenderPlanDecoder.decodeTransient(
            CompositionTestSupport.bytes(dir.appendingPathComponent("tolerant/transient_timing_fields_ignored.json")))
        XCTAssertEqual(t, try RenderPlanDecoder.decodeTransient(CompositionTestSupport.bytes(dir.appendingPathComponent("transient_move.json"))))
    }

    /// Dart's `double.toString` layout (the canonical writer must match it byte for byte).
    func testDoublesAreWrittenLikeDart() {
        let cases: [(Double, String)] = [
            (0.1, "0.1"), (1.5, "1.5"), (-0.5, "-0.5"), (0.30000000000000004, "0.30000000000000004"),
            (1e-7, "1e-7"), (1.5e-7, "1.5e-7"), (0.000001, "0.000001"), (0.0001234, "0.0001234"),
            (123.456, "123.456"), (1e21, "1e+21"), (1.25e22, "1.25e+22"), (1e20, "100000000000000000000.0"),
            (12345.678901234567, "12345.678901234567"), (2.5e-10, "2.5e-10"),
        ]
        for (d, expected) in cases {
            XCTAssertEqual(PlanJSONWriter.formatDouble(d), expected, "\(d)")
        }
        XCTAssertEqual(PlanJSONWriter.string(.num(1.0)), "1")
        XCTAssertEqual(PlanJSONWriter.string(.num(-0.0)), "0")
        XCTAssertEqual(PlanJSONWriter.string(.string("a\"b\\c\n\u{1}é")), "\"a\\\"b\\\\c\\n\\u0001é\"")
    }

    func testReaderKeepsIntegersAndDoublesApart() throws {
        let v = try PlanJSONReader.parse(Data(#"{"a":1,"b":1.0,"c":-2e3,"d":"é😀","e":[true,false,null]}"#.utf8))
        guard case .object(let o) = v else { return XCTFail() }
        XCTAssertEqual(o["a"], .int(1))
        XCTAssertEqual(o["b"], .double(1))
        XCTAssertEqual(o["c"], .double(-2000))
        XCTAssertEqual(o["d"], .string("é😀"))
        XCTAssertEqual(o["e"], .array([.bool(true), .bool(false), .null]))
        XCTAssertEqual(try RenderPlanDecoder.asInt(o["b"], "b"), 1)
        XCTAssertThrowsError(try RenderPlanDecoder.asInt(.double(1.5), "x"))
        XCTAssertThrowsError(try PlanJSONReader.parse(Data("{} x".utf8)))
    }
}
