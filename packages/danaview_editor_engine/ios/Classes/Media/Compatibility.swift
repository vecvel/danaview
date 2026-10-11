// OWNER: IOS-02
//
// Edit compatibility of a file (ARCH §15, <= 300 ms). Dart's MediaInspector sniffs the container
// first (UX); natively the order is: missing file -> NotEditable('not_found'); MKV/WebM/AVI/Ogg
// (byte sniff) -> NotEditable('container_unsupported_ios') without touching AVFoundation; images
// -> ImageIO header check; audio/video -> AVURLAsset loads of isPlayable / isComposable /
// hasProtectedContent bounded by a 250 ms timeout. Protected -> 'protected_content'; not playable
// -> 'codec_unsupported'; not composable -> 'not_composable'. When the loads time out the file is
// reported editable and the full probe decides later (the budget wins over certainty).

import AVFoundation
import Foundation
import ImageIO

final class Compatibility: CompatibilityChecking {
    private let context: EngineContext

    init(context: EngineContext) {
        self.context = context
    }

    /// Timeout of the AVFoundation loads (the whole answer must fit in 300 ms).
    static let loadTimeout: TimeInterval = 0.25

    func compatibility(of url: URL, reply: @escaping EngineReply<CompatibilityMsg>) {
        Compatibility.check(url, reply: reply)
    }

    static func notEditable(_ code: String, _ message: String) -> CompatibilityMsg {
        CompatibilityMsg(editable: false, code: code, message: message)
    }

    static let editable = CompatibilityMsg(editable: true)

    /// Answers [reply] exactly once within about [loadTimeout] + a few ms.
    static func check(_ url: URL, reply: @escaping EngineReply<CompatibilityMsg>) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            reply(.success(notEditable(ProbeIssue.notFound, "file not found")))
            return
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            reply(.failure(EngineError(.permissionDenied, "file not readable")))
            return
        }
        let container = SniffedContainer.sniff(url)
        if container.unsupportedOnIOS {
            reply(.success(notEditable(ProbeIssue.containerUnsupportedIOS, "\(container.rawValue) is not editable on iOS")))
            return
        }
        if container.isImage {
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
               CGImageSourceGetStatus(source) == .statusComplete || CGImageSourceGetStatus(source) == .statusIncomplete {
                reply(.success(editable))
            } else {
                reply(.success(notEditable(ProbeIssue.codecUnsupported, "image format not supported")))
            }
            return
        }

        let once = ReplyOnce(reply)
        let asset = AVURLAsset(url: url)
        let task = Task.detached(priority: .userInitiated) {
            do {
                let (playable, composable, protected) = try await asset.load(.isPlayable, .isComposable, .hasProtectedContent)
                if protected {
                    once.send(.success(notEditable(ProbeIssue.protectedContent, "protected content")))
                } else if !playable {
                    once.send(.success(notEditable(ProbeIssue.codecUnsupported, "codec not supported")))
                } else if !composable {
                    once.send(.success(notEditable(ProbeIssue.notComposable, "media not composable")))
                } else {
                    once.send(.success(editable))
                }
            } catch {
                let mapped = EngineError.from(error)
                switch mapped.code {
                case .unsupportedMedia, .decoderInitFailed:
                    once.send(.success(notEditable(ProbeIssue.codecUnsupported, "format not supported")))
                case .mediaOffline:
                    once.send(.success(notEditable(ProbeIssue.notFound, "file not found")))
                default:
                    once.send(.failure(mapped))
                }
            }
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + loadTimeout) {
            if once.send(.success(editable)) {
                Log.info(.media, "compatibility loads timed out; deferring to the probe")
                task.cancel()
            }
        }
    }
}

/// Delivers the first of several racing results.
final class ReplyOnce<T> {
    private let lock = NSLock()
    private var reply: EngineReply<T>?

    init(_ reply: @escaping EngineReply<T>) {
        self.reply = reply
    }

    /// Sends [result] if nothing was sent yet; returns whether it was sent.
    @discardableResult
    func send(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        let pending = reply
        reply = nil
        lock.unlock()
        guard let pending = pending else { return false }
        pending(result)
        return true
    }
}
