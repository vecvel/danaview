// OWNER: ENG-07
//
// Error code mapping of the iOS glue (ARCH §12.5, §12.6, §19): service failures reach Dart as
// `EnginePigeonError(code: EngineErrorCode.name, message without paths, details: {itemId?,
// mediaFingerprint?, retryable})`; system errors map to typed codes; unknown codes become
// `internal`; logs never contain paths.

import Flutter
import XCTest

@testable import vwish_editor_engine

final class ErrorMappingTests: XCTestCase {
    /// The Dart `EngineErrorCode` values (vwish_editor_engine_api/lib/src/failures.dart), in order.
    private let dartCodes = [
        "mediaOffline", "permissionDenied", "unsupportedMedia", "decoderInitFailed", "decodeFailed", "encoderUnavailable",
        "encoderSizeLimit", "encodingFailed", "diskFull", "io", "planInvalid", "planOutOfSync", "gpuUnavailable", "surfaceLost",
        "interrupted", "cancelled", "busy", "notSupportedOnDevice", "internal",
    ]

    func testNativeCodesMatchTheDartEnum() {
        XCTAssertEqual(EngineErrorCode.allCases.map(\.rawValue), dartCodes)
        XCTAssertEqual(EngineErrorCode.fromName("diskFull"), .diskFull)
        XCTAssertEqual(EngineErrorCode.fromName("somethingNew"), .internal)
        XCTAssertEqual(EngineErrorCode.fromName(nil), .internal)
    }

    func testEngineErrorBecomesAPigeonErrorWithDetails() {
        let error = EngineError(
            .decodeFailed, "frame 12 of /var/mobile/Containers/a.mp4 failed", itemId: "it1", mediaFingerprint: "fp1",
            retryable: true)
        let pigeon = error.pigeonError
        XCTAssertEqual(pigeon.code, "decodeFailed")
        XCTAssertEqual(pigeon.message, "frame 12 of <path> failed")
        let details = pigeon.details as? [String: Any]
        XCTAssertEqual(details?["itemId"] as? String, "it1")
        XCTAssertEqual(details?["mediaFingerprint"] as? String, "fp1")
        XCTAssertEqual(details?["retryable"] as? Bool, true)
        let failure = error.failureMsg
        XCTAssertEqual(failure.code, "decodeFailed")
        XCTAssertEqual(failure.itemId, "it1")
        XCTAssertTrue(failure.retryable)
        let flutter = error.flutterError
        XCTAssertEqual(flutter.code, "decodeFailed")
        XCTAssertEqual(flutter.message, "frame 12 of <path> failed")
    }

    func testDetailsOmitAbsentIds() {
        let details = EngineError(.busy).details
        XCTAssertEqual(details.count, 1)
        XCTAssertEqual(details["retryable"] as? Bool, false)
    }

    func testSystemErrorsMapToTypedCodes() {
        func code(_ error: Error) -> EngineErrorCode { EngineError.from(error).code }
        XCTAssertEqual(code(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))), .diskFull)
        XCTAssertEqual(code(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))), .mediaOffline)
        XCTAssertEqual(code(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))), .permissionDenied)
        XCTAssertEqual(code(NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))), .io)
        XCTAssertEqual(code(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)), .diskFull)
        XCTAssertEqual(code(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)), .mediaOffline)
        XCTAssertEqual(code(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)), .permissionDenied)
        XCTAssertEqual(code(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)), .cancelled)
        XCTAssertEqual(code(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist)), .mediaOffline)
        XCTAssertEqual(code(NSError(domain: "AVFoundationErrorDomain", code: -11807)), .diskFull)
        XCTAssertEqual(code(NSError(domain: "AVFoundationErrorDomain", code: -11834)), .encoderUnavailable)
        XCTAssertEqual(code(NSError(domain: "AVFoundationErrorDomain", code: -11833)), .decoderInitFailed)
        XCTAssertEqual(code(NSError(domain: "AVFoundationErrorDomain", code: -11828)), .unsupportedMedia)
        XCTAssertEqual(code(NSError(domain: "AVFoundationErrorDomain", code: -11847)), .interrupted)
        XCTAssertEqual(code(NSError(domain: "SomeDomain", code: 1)), .internal)
        struct Custom: Error {}
        XCTAssertEqual(code(Custom()), .internal)
    }

    func testSystemErrorMessagesNeverCarryTheLocalizedDescription() {
        let error = NSError(
            domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError,
            userInfo: [NSLocalizedDescriptionKey: "The file “secret.mp4” couldn’t be opened.", NSFilePathErrorKey: "/var/secret.mp4"])
        let mapped = EngineError.from(error)
        XCTAssertFalse(mapped.message.contains("secret"))
        XCTAssertEqual(mapped.message, "\(NSCocoaErrorDomain) \(NSFileReadNoSuchFileError)")
    }

    func testChannelErrorsKeepKnownCodesAndWrapUnknownOnes() {
        let known = EngineError.from(EnginePigeonError(code: "busy", message: "m", details: ["retryable": true, "itemId": "i"]))
        XCTAssertEqual(known.code, .busy)
        XCTAssertTrue(known.retryable)
        XCTAssertEqual(known.itemId, "i")
        let unknown = EngineError.from(EnginePigeonError(code: "weird", message: "x", details: nil))
        XCTAssertEqual(unknown.code, .internal)
        XCTAssertEqual(unknown.message, "weird: x")
    }

    func testGlueRepliesCarryMappedServiceFailures() throws {
        let fake = FakeServices()
        let fixture = try GlueFixture(services: fake.services)
        try fixture.initialize(self)
        let media = media("file://" + fixture.roots.support.appendingPathComponent("media/a.mp4").path)

        func probeError() -> EnginePigeonError? {
            let done = expectation(description: "probe")
            var result: Result<ProbeMsg, Error>?
            fixture.glue.engineApi.probe(media: media) {
                result = $0
                done.fulfill()
            }
            wait(for: [done], timeout: 5)
            return pigeonError(result)
        }

        fake.failure = EngineError(.unsupportedMedia, "codec of /var/mobile/x.mkv", mediaFingerprint: "fp1")
        var error = probeError()
        XCTAssertEqual(error?.code, "unsupportedMedia")
        XCTAssertEqual(error?.message, "codec of <path>")
        XCTAssertEqual((error?.details as? [String: Any])?["mediaFingerprint"] as? String, "fp1")
        XCTAssertEqual(retryable(error), false)

        fake.failure = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        error = probeError()
        XCTAssertEqual(error?.code, "diskFull")

        struct Unexpected: Error {}
        fake.failure = Unexpected()
        error = probeError()
        XCTAssertEqual(error?.code, "internal")
    }

    func testLogsAreScrubbedOfPaths() {
        var lines: [String] = []
        Log.testSink = { _, _, text in lines.append(text) }
        defer { Log.testSink = nil }
        Log.info(.glue, "opened /var/mobile/Containers/Data/a.mp4 and file:///private/var/b.mov ok")
        Log.error(.media, "content://media/external/video/1 failed")
        XCTAssertEqual(lines, ["opened <path> and <path> ok", "<path> failed"])
        XCTAssertEqual(Log.scrub("ratio 1/2 and v1.2/x"), "ratio 1/2 and v1.2/x")
    }

    func testGlueFailureLogsDoNotLeakPaths() throws {
        let fake = FakeServices()
        let fixture = try GlueFixture(services: fake.services)
        try fixture.initialize(self)
        var lines: [String] = []
        Log.testSink = { _, _, text in lines.append(text) }
        defer { Log.testSink = nil }
        fake.failure = NSError(domain: "Custom", code: 7, userInfo: [NSFilePathErrorKey: fixture.roots.base.path])
        let done = expectation(description: "capabilities")
        fixture.glue.engineApi.capabilities { _ in done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertFalse(lines.isEmpty)
        XCTAssertFalse(lines.contains { $0.contains(fixture.roots.base.path) })
    }
}
