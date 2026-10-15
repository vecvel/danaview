// OWNER: IOS-19
//
// D-33 placeholder created by INT-06 (ARCH D-45, §12.2): the rendered-range handler of
// `PreviewHostApi.setRenderedRanges`. IOS-19 replaces the body: it hands the ranges to the
// session's RenderedRangeSwap (IOS-11's rendered-range hook), which plays them from their files
// during playback only and drops a range when an applied patch touches it (and every range on
// `setPlan`) until the next call. Keep `init(context:)` and the `RenderedRangeSetting`
// conformance.

import Foundation

final class RenderedRangeHandler: RenderedRangeSetting {
    private let context: EngineContext

    init(context: EngineContext) {
        self.context = context
    }

    func setRenderedRanges(sessionId: String, ranges: [RenderedRangeMsg], fileURLs: [URL], reply: @escaping EngineReply<Void>) {
        reply(.failure(EngineError.notSupportedOnDevice("rendered ranges")))
    }
}
