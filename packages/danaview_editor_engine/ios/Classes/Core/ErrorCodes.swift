// OWNER: ENG-07 (frozen with the glue by ENG-06)
//
// Native side of the engine error contract (ARCH §12.5, §12.6, §19). Every failure that leaves the
// plugin is `FlutterError(code: EngineErrorCode.name, message: debug text without paths,
// details: {itemId?, mediaFingerprint?, retryable})`, or a `FailureMsg` with the same fields on the
// event stream. error_mapper.dart turns both into `EngineFailure`; unknown codes become `internal`.
//
// `EngineError.from(_:)` maps the system errors services meet (Cocoa file errors, POSIX, URL
// loading, AVFoundation) to codes. Messages carry only the error domain and number, never a
// `localizedDescription` (it often names the file), and are scrubbed again by `Log.scrub`.

import Flutter
import Foundation

/// `EngineErrorCode` of danaview_editor_engine_api (ARCH §12.5). Raw values are the Dart enum names.
enum EngineErrorCode: String, CaseIterable {
    case mediaOffline
    case permissionDenied
    case unsupportedMedia
    case decoderInitFailed
    case decodeFailed
    case encoderUnavailable
    case encoderSizeLimit
    case encodingFailed
    case diskFull
    case io
    case planInvalid
    case planOutOfSync
    case gpuUnavailable
    case surfaceLost
    case interrupted
    case cancelled
    case busy
    case notSupportedOnDevice
    case `internal`

    /// The code for a Dart enum name; unknown names map to `internal` (as error_mapper.dart does).
    static func fromName(_ name: String?) -> EngineErrorCode {
        guard let name = name, let code = EngineErrorCode(rawValue: name) else { return .internal }
        return code
    }
}

/// A typed engine failure. Services fail their replies with it (or with any `Error`, which
/// `EngineError.from` maps); the glue turns it into a `FlutterError` or a `FailureMsg`.
struct EngineError: Error, Equatable, CustomStringConvertible {
    let code: EngineErrorCode
    /// Debug text without paths (scrubbed on construction).
    let message: String
    let itemId: String?
    let mediaFingerprint: String?
    let retryable: Bool

    init(
        _ code: EngineErrorCode,
        _ message: String = "",
        itemId: String? = nil,
        mediaFingerprint: String? = nil,
        retryable: Bool = false
    ) {
        self.code = code
        self.message = Log.scrub(message)
        self.itemId = itemId
        self.mediaFingerprint = mediaFingerprint
        self.retryable = retryable
    }

    var description: String { "EngineError(\(code.rawValue): \(message))" }

    // MARK: Common failures

    /// The feature is not built on this device or in this app version (D-33 placeholders).
    static func notSupportedOnDevice(_ what: String) -> EngineError {
        EngineError(.notSupportedOnDevice, "\(what) is not available on this device yet")
    }

    /// A Dart argument broke the host API contract (a caller bug): `internal`, never retryable.
    static func invalidArgument(_ name: String, _ reason: String) -> EngineError {
        EngineError(.internal, "invalid argument \(name): \(reason)")
    }

    /// The engine was called before `EngineHostApi.initialize` supplied its roots.
    static let notInitialized = EngineError(.internal, "engine not initialized: call initialize first")

    /// The operation was cancelled by the caller (not a failure for the UI, ARCH §19).
    static let cancelled = EngineError(.cancelled, "cancelled")

    // MARK: Channel forms

    /// `details` of the `FlutterError`: `{itemId?, mediaFingerprint?, retryable}`.
    var details: [String: any Sendable] {
        var map: [String: any Sendable] = ["retryable": retryable]
        if let itemId = itemId { map["itemId"] = itemId }
        if let fingerprint = mediaFingerprint { map["mediaFingerprint"] = fingerprint }
        return map
    }

    /// The error a host API reply carries (the generated `wrapError` sends code, message, details).
    var pigeonError: EnginePigeonError {
        EnginePigeonError(code: code.rawValue, message: message, details: details)
    }

    /// The same failure as a `FlutterError` (stream errors, tests).
    var flutterError: FlutterError {
        FlutterError(code: code.rawValue, message: message, details: details)
    }

    /// The failure an event carries.
    var failureMsg: FailureMsg {
        FailureMsg(code: code.rawValue, message: message, itemId: itemId, mediaFingerprint: mediaFingerprint, retryable: retryable)
    }

    // MARK: Mapping

    /// Maps any error a service reports to an `EngineError`.
    static func from(_ error: Error) -> EngineError {
        if let engineError = error as? EngineError { return engineError }
        if let flutterError = error as? FlutterError {
            return fromChannelError(code: flutterError.code, message: flutterError.message, details: flutterError.details)
        }
        if let pigeonError = error as? EnginePigeonError {
            return fromChannelError(code: pigeonError.code, message: pigeonError.message, details: pigeonError.details)
        }
        return fromNSError(error as NSError)
    }

    private static func fromChannelError(code raw: String, message: String?, details: Any?) -> EngineError {
        let code = EngineErrorCode.fromName(raw)
        let map = details as? [String: Any] ?? [:]
        var text = message ?? ""
        if code == .internal && raw != EngineErrorCode.internal.rawValue {
            text = text.isEmpty ? raw : "\(raw): \(text)"
        }
        return EngineError(
            code, text,
            itemId: map["itemId"] as? String,
            mediaFingerprint: map["mediaFingerprint"] as? String,
            retryable: map["retryable"] as? Bool ?? false)
    }

    // Error domains matched by name so the core does not link AVFoundation.
    static let avFoundationDomain = "AVFoundationErrorDomain"

    private static func fromNSError(_ error: NSError) -> EngineError {
        let tag = "\(error.domain) \(error.code)"
        switch error.domain {
        case NSCocoaErrorDomain:
            switch error.code {
            case NSFileWriteOutOfSpaceError: return EngineError(.diskFull, tag)
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return EngineError(.mediaOffline, tag)
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError:
                return EngineError(.permissionDenied, tag)
            case NSUserCancelledError: return EngineError(.cancelled, tag)
            case NSFileReadCorruptFileError, NSFileReadUnknownStringEncodingError: return EngineError(.unsupportedMedia, tag)
            case NSFileErrorMinimum...NSFileErrorMaximum:  // every other file read/write error (0...1023)
                return EngineError(.io, tag, retryable: true)
            default: return EngineError(.internal, tag)
            }
        case NSPOSIXErrorDomain:
            switch Int32(truncatingIfNeeded: error.code) {
            case ENOSPC, EDQUOT: return EngineError(.diskFull, tag)
            case ENOENT, ENOTDIR: return EngineError(.mediaOffline, tag)
            case EACCES, EPERM, EROFS: return EngineError(.permissionDenied, tag)
            case ECANCELED: return EngineError(.cancelled, tag)
            case EBUSY, EAGAIN: return EngineError(.busy, tag, retryable: true)
            case EINTR: return EngineError(.interrupted, tag, retryable: true)
            default: return EngineError(.io, tag, retryable: true)
            }
        case NSURLErrorDomain:
            switch error.code {
            case NSURLErrorFileDoesNotExist: return EngineError(.mediaOffline, tag)
            case NSURLErrorNoPermissionsToReadFile: return EngineError(.permissionDenied, tag)
            case NSURLErrorCancelled: return EngineError(.cancelled, tag)
            case NSURLErrorCannotOpenFile, NSURLErrorCannotWriteToFile, NSURLErrorCannotCreateFile:
                return EngineError(.io, tag, retryable: true)
            default: return EngineError(.internal, tag)
            }
        case avFoundationDomain:
            return fromAVError(error.code, tag)
        default:
            return EngineError(.internal, tag)
        }
    }

    // AVError.Code raw values (AVFoundation/AVError.h).
    private static func fromAVError(_ code: Int, _ tag: String) -> EngineError {
        switch code {
        case -11807: return EngineError(.diskFull, tag)  // AVErrorDiskFull
        case -11819, -11847: return EngineError(.interrupted, tag, retryable: true)  // MediaServicesWereReset, OperationInterrupted
        case -11821: return EngineError(.decodeFailed, tag, retryable: true)  // DecodeFailed
        case -11828, -11829, -11831, -11838: return EngineError(.unsupportedMedia, tag)  // FormatNotRecognized, FailedToParse, ContentIsProtected, OperationNotSupportedForAsset
        case -11833: return EngineError(.decoderInitFailed, tag)  // DecoderNotFound
        case -11839: return EngineError(.decoderInitFailed, tag, retryable: true)  // DecoderTemporarilyUnavailable
        case -11834: return EngineError(.encoderUnavailable, tag)  // EncoderNotFound
        case -11840: return EngineError(.encoderUnavailable, tag, retryable: true)  // EncoderTemporarilyUnavailable
        case -11823: return EngineError(.io, tag)  // FileAlreadyExists
        case -11800: return EngineError(.decodeFailed, tag, retryable: true)  // Unknown (most often a decode failure)
        default: return EngineError(.internal, tag)
        }
    }
}
