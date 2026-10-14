// OWNER: IOS-10
//
// RedrawCache (ARCH §13.2 'Redraw-from-cache', native.md §5.3): keeps the last compositor request's
// source buffers (frame k, composition time, the media layers' tracks, render size) so that, while
// the player is paused, param patches, transients, editing modes (normal, cropSource(item),
// matte(item)) and look stills re-render through the same DVRenderSession.render path as playback
// (≤ 30 ms; IOS-01 measured p50 13–15 ms at 1080p on the simulator).
//
// - `redraw()` renders synchronously into the cache's own BGRA IOSurface pool and returns a buffer
//   stamped `danaview.frame = k` (IOS-11 hands it to TextureBridge).
// - `requestRedraw` coalesces: redraws run one at a time on the redraw queue and a newer request
//   supersedes every queued one (generation counter); superseded requests complete with nil.
// - `still` renders the cached frame with an override snapshot at a given height (look stills).
// - A structural rebuild or seek replaces the entry with the next composed request; `clear()` drops it
//   (dispose, memory warning).

import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

final class RedrawCache {
    /// One cached request.
    struct Entry {
        let k: Int64
        let compositionTime: CMTime
        let sources: DVRenderSession.Sources
        let renderSize: CGSize
    }

    /// A finished redraw.
    struct Result {
        let buffer: CVPixelBuffer
        let output: LayerRenderer.Output
        let renderMs: Double
    }

    enum RedrawError: Error, Equatable {
        /// Nothing composed yet (or cleared).
        case empty
        /// The session is gone.
        case noSession
        /// The pixel buffer pool could not provide a buffer.
        case noBuffer
    }

    /// The owning session (set by DVRenderSession).
    weak var session: DVRenderSession?

    private let lock = NSLock()
    private var entry: Entry?
    private var pool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero
    private var generation: UInt64 = 0
    private let queue = DispatchQueue(label: "danaview.redraw", qos: .userInteractive)

    init() {}

    /// Stores the last composed request.
    func store(_ e: Entry) {
        lock.lock()
        entry = e
        lock.unlock()
    }

    /// The cached request, nil before the first composed frame.
    var last: Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entry
    }

    /// Drops the cached sources and the pool.
    func clear() {
        lock.lock()
        entry = nil
        pool = nil
        poolSize = .zero
        lock.unlock()
    }

    /// Re-renders the cached frame now with [snapshot] (default: the session's current one), [mode]
    /// (default: the session's) at [size] (default: the cached render size).
    func redraw(snapshot: ParamSnapshot? = nil, mode: DVEditingMode? = nil, size: CGSize? = nil) throws -> Result {
        guard let session else { throw RedrawError.noSession }
        guard let e = last else { throw RedrawError.empty }
        let start = CFAbsoluteTimeGetCurrent()
        let target = size ?? e.renderSize
        let buffer = try makeBuffer(size: target)
        let output = try session.render(
            snapshot: snapshot ?? session.snapshots.current, frame: e.k, sources: e.sources, mode: mode ?? session.mode, into: buffer)
        return Result(buffer: buffer, output: output, renderMs: (CFAbsoluteTimeGetCurrent() - start) * 1000)
    }

    /// Asynchronous, coalescing redraw (latest wins). [completion] runs on the redraw queue with the
    /// result, an error, or nil when a newer request superseded this one before it ran.
    func requestRedraw(snapshot: ParamSnapshot? = nil, mode: DVEditingMode? = nil,
                       completion: @escaping (Swift.Result<Result, Error>?) -> Void) {
        lock.lock()
        generation &+= 1
        let gen = generation
        lock.unlock()
        queue.async { [weak self] in
            guard let self else {
                completion(nil)
                return
            }
            guard self.currentGeneration == gen else {
                completion(nil)
                return
            }
            completion(Swift.Result { try self.redraw(snapshot: snapshot, mode: mode) })
        }
    }

    /// Cancels every queued `requestRedraw` (they complete with nil).
    func cancelPending() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }

    private var currentGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    /// The cached frame rendered with [snapshot] at [heightPx] (width from the canvas aspect) as a
    /// CGImage (look stills).
    func still(snapshot: ParamSnapshot, heightPx: Int, mode: DVEditingMode = .normal) throws -> CGImage {
        guard let session else { throw RedrawError.noSession }
        let canvas = snapshot.plan.canvas
        let h = max(1, heightPx)
        let w = max(1, Int((Double(h) * Double(canvas.w) / Double(canvas.h)).rounded()))
        let r = try redraw(snapshot: snapshot, mode: mode, size: CGSize(width: w, height: h))
        let image = CIImage(cvPixelBuffer: r.buffer, options: [.colorSpace: NSNull()])
        guard let cg = session.context.createCGImage(
            image, from: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { throw RedrawError.noBuffer }
        return cg
    }

    // MARK: Pool

    private func makeBuffer(size: CGSize) throws -> CVPixelBuffer {
        let w = max(1, Int(size.width.rounded()))
        let h = max(1, Int(size.height.rounded()))
        lock.lock()
        if pool == nil || poolSize != CGSize(width: w, height: h) {
            var attrs = DVRenderSession.pixelBufferAttributes as [String: Any]
            attrs[kCVPixelBufferWidthKey as String] = w
            attrs[kCVPixelBufferHeightKey as String] = h
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &p)
            pool = p
            poolSize = CGSize(width: w, height: h)
        }
        let p = pool
        lock.unlock()
        var buffer: CVPixelBuffer?
        if let p { CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, p, &buffer) }
        guard let buffer else { throw RedrawError.noBuffer }
        return buffer
    }
}
