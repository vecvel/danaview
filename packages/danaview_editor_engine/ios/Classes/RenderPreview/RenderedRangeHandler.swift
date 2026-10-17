// OWNER: IOS-19
//
// The rendered-range handler of `PreviewHostApi.setRenderedRanges` (ARCH D-45, §12.2; the D-33
// placeholder of INT-06). The glue has validated the ranges (sorted, non-overlapping, non-empty,
// with a hash and a file inside `<cache>/danaview/editor/renders/`) and passes their file URLs.
// The handler hands them to the session's RenderedRangeSwap (IOS-11's rendered-range hook, kept by
// RenderedRangeRegistry per session id), which binds them to the session's current plan, plays
// them from their files during playback only and drops a range when an applied patch touches it
// (every range on `setPlan`) until the next call. Runs on `previewControlQueue`.

import Foundation

final class RenderedRangeHandler: RenderedRangeSetting {
    private let context: EngineContext

    init(context: EngineContext) {
        self.context = context
    }

    /// The ranges of the messages with their validated file URLs.
    static func ranges(_ ranges: [RenderedRangeMsg], fileURLs: [URL]) throws -> [RenderedRange] {
        guard ranges.count == fileURLs.count else {
            throw EngineError.invalidArgument("ranges", "\(ranges.count) ranges for \(fileURLs.count) files")
        }
        return zip(ranges, fileURLs).map { m, url in
            RenderedRange(startUs: m.startUs, endUs: m.endUs, fileURL: url, hash: m.hash)
        }
    }

    func setRenderedRanges(sessionId: String, ranges: [RenderedRangeMsg], fileURLs: [URL], reply: @escaping EngineReply<Void>) {
        do {
            let next = try RenderedRangeHandler.ranges(ranges, fileURLs: fileURLs)
            RenderedRangeRegistry.of(context).swap(for: sessionId).setRanges(next)
            reply(.success(()))
        } catch {
            reply(.failure(EngineError.from(error)))
        }
    }
}
