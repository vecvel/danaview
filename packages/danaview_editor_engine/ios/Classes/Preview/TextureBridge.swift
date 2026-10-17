// OWNER: IOS-11
//
// TextureBridge (ARCH §12.7, §13.2 'Session'): the FlutterTexture of one preview session.
//
// - `copyPixelBuffer` returns the latest BGRA IOSurface-backed buffer (+1), zero-copy into Impeller:
//   the very buffer the compositor rendered (AVPlayerItemVideoOutput vends the compositor's buffer
//   unchanged because its attributes match the render context, IOS-01 4/4).
// - Buffers arrive from the display link (playback, `pull`), from exact/scrub seeks (paused) and
//   from paused redraws, source-frame previews and look stills (`push`). Each push marks the
//   texture available on the main thread (`textureFrameAvailable`, ARCH §12.7).
// - The old frame stays on screen until a new one is pushed (structural rebuilds, quality steps,
//   background/foreground): nothing ever clears `latest` except `unregister` (dispose).
// - A trim-edge source frame (`showSourceFrame`) is pushed as an overlay; `restoreComposed` puts
//   the last composed frame back when a seek or play clears it.
// - Every structural rebuild attaches a new `AVPlayerItemVideoOutput` (an output belongs to one
//   item); `output` is swapped atomically.

import AVFoundation
import CoreVideo
import Flutter
import Foundation

/// The texture registry seam: `FlutterTextureRegistry` in the app, a recorder in RunnerTests.
protocol PreviewTextureRegistry: AnyObject {
    func register(_ texture: FlutterTexture) -> Int64
    func textureFrameAvailable(_ textureId: Int64)
    func unregisterTexture(_ textureId: Int64)
}

/// Adapts the engine's `FlutterTextureRegistry` (main thread only).
final class FlutterTextureRegistryAdapter: PreviewTextureRegistry {
    private let registry: FlutterTextureRegistry

    init(_ registry: FlutterTextureRegistry) {
        self.registry = registry
    }

    func register(_ texture: FlutterTexture) -> Int64 { registry.register(texture) }
    func textureFrameAvailable(_ textureId: Int64) { registry.textureFrameAvailable(textureId) }
    func unregisterTexture(_ textureId: Int64) { registry.unregisterTexture(textureId) }
}

final class TextureBridge: NSObject, FlutterTexture {
    /// Same attributes as the compositor's render context, so the video output never converts.
    static var outputAttributes: [String: Any] { DVRenderSession.pixelBufferAttributes as [String: Any] }

    /// One displayed buffer and its `danaview.frame` stamp (nil for source frames).
    struct Frame {
        let buffer: CVPixelBuffer
        let k: Int64?
        /// Increases with every push.
        let serial: UInt64
    }

    private let lock = NSLock()
    private var latest: Frame?
    private var composed: Frame?
    private var serial: UInt64 = 0
    private var _output: AVPlayerItemVideoOutput?
    private var registry: PreviewTextureRegistry?
    private(set) var textureId: Int64 = -1
    private var unregistered = false
    /// Called (on the pushing thread) after the first pushed frame.
    var onFirstFrame: ((Frame) -> Void)?

    // MARK: Registration (main thread)

    /// Registers with [registry] on the main thread; [completion] receives the texture id (−1 when
    /// there is no registry, e.g. a headless engine in tests).
    func register(with registry: PreviewTextureRegistry?, completion: @escaping (Int64) -> Void) {
        let work = {
            guard let registry else {
                completion(-1)
                return
            }
            let id = registry.register(self)
            self.lock.lock()
            self.registry = registry
            self.textureId = id
            self.lock.unlock()
            completion(id)
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// Unregisters the texture and drops every buffer (dispose). Idempotent.
    func unregister(completion: (() -> Void)? = nil) {
        lock.lock()
        let registry = self.registry
        let id = textureId
        self.registry = nil
        unregistered = true
        latest = nil
        composed = nil
        _output = nil
        lock.unlock()
        let work = {
            if let registry, id >= 0 { registry.unregisterTexture(id) }
            completion?()
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    var isRegistered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return registry != nil
    }

    // MARK: Video output

    /// The video output of the current player item.
    var output: AVPlayerItemVideoOutput? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _output
        }
        set {
            lock.lock()
            _output = newValue
            lock.unlock()
        }
    }

    /// A new output for a new player item.
    static func makeOutput() -> AVPlayerItemVideoOutput {
        AVPlayerItemVideoOutput(pixelBufferAttributes: outputAttributes)
    }

    /// Copies the output buffer for [itemTime] when there is a new one, pushes it and returns it.
    @discardableResult
    func pull(itemTime: CMTime, accept: ((Int64?) -> Bool)? = nil) -> Frame? {
        guard itemTime.isNumeric, let output = output, output.hasNewPixelBuffer(forItemTime: itemTime),
              let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
        else { return nil }
        let k = DVRenderSession.frameIndex(of: buffer)
        if let accept, !accept(k) { return nil }
        return push(buffer, k: k)
    }

    // MARK: Frames

    /// Shows [buffer] (a composed frame, [k] = its stamp; read from the buffer when nil).
    @discardableResult
    func push(_ buffer: CVPixelBuffer, k: Int64? = nil) -> Frame? {
        push(buffer, k: k ?? DVRenderSession.frameIndex(of: buffer), composed: true)
    }

    /// Shows a frame that is not a composed output frame (trim-edge source frame).
    @discardableResult
    func pushOverlay(_ buffer: CVPixelBuffer) -> Frame? {
        push(buffer, k: nil, composed: false)
    }

    /// Shows the last composed frame again (clears a source-frame overlay).
    func restoreComposed() {
        lock.lock()
        let c = composed
        lock.unlock()
        guard let c else { return }
        push(c.buffer, k: c.k, composed: true)
    }

    private func push(_ buffer: CVPixelBuffer, k: Int64?, composed isComposed: Bool) -> Frame? {
        lock.lock()
        guard !unregistered else {
            lock.unlock()
            return nil
        }
        serial &+= 1
        let frame = Frame(buffer: buffer, k: k, serial: serial)
        let first = latest == nil
        latest = frame
        if isComposed { composed = frame }
        let registry = self.registry
        let id = textureId
        let callback = onFirstFrame
        lock.unlock()
        if first { callback?(frame) }
        if let registry, id >= 0 {
            if Thread.isMainThread {
                registry.textureFrameAvailable(id)
            } else {
                DispatchQueue.main.async { registry.textureFrameAvailable(id) }
            }
        }
        return frame
    }

    /// The frame on screen.
    var current: Frame? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    /// The last composed frame (ignores a source-frame overlay).
    var lastComposed: Frame? {
        lock.lock()
        defer { lock.unlock() }
        return composed
    }

    /// Serial of the last push (0 before the first).
    var currentSerial: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return serial
    }

    // MARK: FlutterTexture (raster thread)

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        lock.lock()
        defer { lock.unlock() }
        guard let b = latest?.buffer else { return nil }
        return Unmanaged.passRetained(b)
    }

    // MARK: Debug capture

    /// RGBA8 bytes (top row first) of the frame on screen and its size.
    func captureRGBA() -> (width: Int, height: Int, bytes: Data)? {
        guard let pb = current?.buffer else { return nil }
        return TextureBridge.rgba(pb)
    }

    static func rgba(_ pb: CVPixelBuffer) -> (width: Int, height: Int, bytes: Data) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let row = CVPixelBufferGetBytesPerRow(pb)
        var out = Data(count: w * h * 4)
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return (w, h, out) }
        out.withUnsafeMutableBytes { raw in
            let dst = raw.bindMemory(to: UInt8.self)
            for y in 0..<h {
                let src = base + y * row
                for x in 0..<w {
                    let s = x * 4
                    let o = (y * w + x) * 4
                    dst[o] = src[s + 2]
                    dst[o + 1] = src[s + 1]
                    dst[o + 2] = src[s]
                    dst[o + 3] = src[s + 3]
                }
            }
        }
        return (w, h, out)
    }
}
