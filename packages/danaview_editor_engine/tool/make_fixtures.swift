// OWNER: ENG-05
//
// Generates the committed editor test media into test_fixtures/media/ (BUILD_PLAN ENG-05, ARCH
// section 21, V-U6). macOS only: AVAssetWriter + Core Graphics + Core Text, plus the dev-only
// ffmpeg tool for the two containers AVFoundation cannot write (Matroska, WebM).
//
//   swiftc -O -swift-version 5 tool/make_fixtures.swift -o /tmp/make_fixtures
//   /tmp/make_fixtures [--out DIR] [--only name,name] [--skip-containers] [--list]
//
// Regeneration is SEMANTICALLY equivalent, not byte identical: hardware encoders and the speech
// synthesizer change across OS updates. The manifest.json written next to the media records what
// must stay equal (barcodes per frame, durations, stream layout, tone frequency) and
// test/fixtures/fixtures_semantic_test.dart verifies it.
//
// Frame barcode (normative layout, mirrored by lib/src/testing/frame_barcode.dart,
// example/ios/RunnerTests/Support/FrameBarcode.swift and
// android/src/androidTest/.../support/FrameBarcode.kt):
//   band    = top 10 % of the frame height, full width, split into 28 equal cells
//   cell 0  = white, cell 1 = black                        (start / calibration)
//   cells 2...17  = frame index, 16 bits, MSB first        (white = 1)
//   cells 18...25 = CRC-8 (poly 0x07, init 0) of the two index bytes, MSB first
//   cell 26 = white, cell 27 = black                       (end guard)

import AVFoundation
import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

// MARK: - Barcode layout

enum BarcodeSpec {
    static let cellCount = 28
    static let bandFraction = 0.10
    static let maxIndex = 0xFFFF

    static func crc8(_ value: Int) -> Int {
        var crc = 0
        for byte in [(value >> 8) & 0xFF, value & 0xFF] {
            crc ^= byte
            for _ in 0..<8 {
                crc = (crc & 0x80) != 0 ? ((crc << 1) ^ 0x07) & 0xFF : (crc << 1) & 0xFF
            }
        }
        return crc
    }

    static func cells(for index: Int) -> [Bool] {
        precondition(index >= 0 && index <= maxIndex, "barcode index out of range")
        var bits: [Bool] = [true, false]
        for b in stride(from: 15, through: 0, by: -1) { bits.append(((index >> b) & 1) == 1) }
        let crc = crc8(index)
        for b in stride(from: 7, through: 0, by: -1) { bits.append(((crc >> b) & 1) == 1) }
        bits.append(true)
        bits.append(false)
        return bits
    }
}

// MARK: - Canvas (BGRA premultiplied, top row first in memory)

final class Canvas {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let data: UnsafeMutableRawPointer
    let ctx: CGContext

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        bytesPerRow = width * 4
        data = UnsafeMutableRawPointer.allocate(byteCount: bytesPerRow * height, alignment: 16)
        data.initializeMemory(as: UInt8.self, repeating: 0, count: bytesPerRow * height)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        ctx = CGContext(
            data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        // Top-left origin, y down. Text needs a flipped text matrix to stay upright.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    }

    deinit { data.deallocate() }

    func fill(_ r: Double, _ g: Double, _ b: Double, _ rect: CGRect) {
        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
        ctx.fill(rect)
    }

    func text(_ s: String, size: CGFloat, bold: Bool = true, x: CGFloat, baseline: CGFloat,
              centered: Bool, color: CGColor) {
        let font = CTFontCreateWithName((bold ? "Menlo-Bold" : "Menlo") as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        let w = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.textPosition = CGPoint(x: centered ? x - CGFloat(w) / 2 : x, y: baseline)
        CTLineDraw(line, ctx)
    }

    func drawBarcode(index: Int) {
        let bits = BarcodeSpec.cells(for: index)
        let bandH = max(Int((Double(height) * BarcodeSpec.bandFraction).rounded()), 8)
        for i in 0..<BarcodeSpec.cellCount {
            let x0 = i * width / BarcodeSpec.cellCount
            let x1 = (i + 1) * width / BarcodeSpec.cellCount
            let v: Double = bits[i] ? 1 : 0
            fill(v, v, v, CGRect(x: x0, y: 0, width: x1 - x0, height: bandH))
        }
    }

    /// One counter frame: hue-shifting backdrop, big digits, a sweeping bar and the barcode.
    func drawCounter(index: Int, fps: Double, seconds: Double, flash: Bool = false) {
        let w = CGFloat(width), h = CGFloat(height)
        if flash {
            fill(1, 1, 1, CGRect(x: 0, y: 0, width: w, height: h))
        } else {
            let hue = Double(index % 180) / 180.0
            let (r, g, b) = hsv(hue, 0.55, 0.38)
            fill(r, g, b, CGRect(x: 0, y: 0, width: w, height: h))
            // Lower band slightly darker; keeps the bottom (subtitle) area calm.
            fill(r * 0.6, g * 0.6, b * 0.6, CGRect(x: 0, y: h * 0.78, width: w, height: h * 0.22))
        }
        let ink = flash ? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
                        : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let digits = String(format: "%05d", index)
        let digitSize = min(w / 3.6, h * 0.24)
        text(digits, size: digitSize, x: w / 2, baseline: h * 0.50, centered: true, color: ink)
        let label = String(format: "t=%.3fs  %@fps", seconds, fpsLabel(fps))
        text(label, size: max(h * 0.035, 10), bold: false, x: w / 2, baseline: h * 0.58,
             centered: true, color: ink)
        // Sweeping bar (motion evidence for encoders and eyes).
        let barX = w * CGFloat(index % 60) / 60.0
        fill(flash ? 0 : 1, flash ? 0 : 0.85, flash ? 0 : 0.1,
             CGRect(x: barX, y: h * 0.64, width: max(w * 0.02, 4), height: h * 0.05))
        drawBarcode(index: index)
    }
}

func hsv(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
    let i = Int(h * 6) % 6
    let f = h * 6 - Double(Int(h * 6))
    let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
    switch i {
    case 0: return (v, t, p)
    case 1: return (q, v, p)
    case 2: return (p, v, t)
    case 3: return (p, q, v)
    case 4: return (t, p, v)
    default: return (v, p, q)
    }
}

func fpsLabel(_ fps: Double) -> String {
    fps == fps.rounded() ? String(Int(fps)) : String(format: "%.2f", fps)
}

// MARK: - Errors / logging

struct FixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// MARK: - Audio helpers

struct PCMAudio {
    let sampleRate: Int
    let channels: Int
    /// Interleaved float samples in [-1, 1].
    var samples: [Float]
    var frameCount: Int { samples.count / channels }
}

func dbfs(_ db: Double) -> Float { Float(pow(10.0, db / 20.0)) }

func sineAudio(hz: Double, seconds: Double, sampleRate: Int, channels: Int, peakDb: Double,
               onlyChannel: Int? = nil, perChannelHz: [Double]? = nil) -> PCMAudio {
    let frames = Int((seconds * Double(sampleRate)).rounded())
    var out = [Float](repeating: 0, count: frames * channels)
    let amp = dbfs(peakDb)
    for f in 0..<frames {
        for c in 0..<channels {
            if let only = onlyChannel, only != c { continue }
            let freq = perChannelHz?[c] ?? hz
            out[f * channels + c] = amp * Float(sin(2 * Double.pi * freq * Double(f) / Double(sampleRate)))
        }
    }
    return PCMAudio(sampleRate: sampleRate, channels: channels, samples: out)
}

/// Short Hann-windowed 2 kHz burst starting exactly at each time in `times`; digital silence else.
func clickAudio(times: [Double], seconds: Double, sampleRate: Int, peakDb: Double) -> PCMAudio {
    let frames = Int((seconds * Double(sampleRate)).rounded())
    var out = [Float](repeating: 0, count: frames)
    let burst = Int(0.020 * Double(sampleRate))
    let amp = dbfs(peakDb)
    for t in times {
        let start = Int((t * Double(sampleRate)).rounded())
        for i in 0..<burst where start + i < frames {
            let hann = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(burst))
            out[start + i] = amp * Float(hann * sin(2 * Double.pi * 2000 * Double(i) / Double(sampleRate)))
        }
    }
    return PCMAudio(sampleRate: sampleRate, channels: 1, samples: out)
}

func writeWav16(_ audio: PCMAudio, to url: URL) throws {
    var d = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
    func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
    let dataBytes = audio.samples.count * 2
    d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + dataBytes))
    d.append("WAVE".data(using: .ascii)!)
    d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(UInt16(audio.channels))
    u32(UInt32(audio.sampleRate)); u32(UInt32(audio.sampleRate * audio.channels * 2))
    u16(UInt16(audio.channels * 2)); u16(16)
    d.append("data".data(using: .ascii)!); u32(UInt32(dataBytes))
    for s in audio.samples {
        let v = Int16(max(-32767, min(32767, (Double(s) * 32767).rounded())))
        u16(UInt16(bitPattern: v))
    }
    try d.write(to: url)
}

func pcmSampleBuffer(_ audio: PCMAudio, startFrame: Int, count: Int) throws -> CMSampleBuffer {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: Float64(audio.sampleRate), mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: UInt32(4 * audio.channels), mFramesPerPacket: 1,
        mBytesPerFrame: UInt32(4 * audio.channels), mChannelsPerFrame: UInt32(audio.channels),
        mBitsPerChannel: 32, mReserved: 0)
    var layout = AudioChannelLayout()
    var layoutSize = 0
    var layoutPtr: UnsafePointer<AudioChannelLayout>? = nil
    switch audio.channels {
    case 1: layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
    case 2: layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
    case 6: layout.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_D
    default: throw FixtureError("unsupported channel count \(audio.channels)")
    }
    layoutSize = MemoryLayout<AudioChannelLayout>.size
    var fmt: CMAudioFormatDescription?
    let status = withUnsafePointer(to: &layout) { p -> OSStatus in
        layoutPtr = p
        return CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: layoutSize, layout: layoutPtr,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
    }
    guard status == noErr, let format = fmt else { throw FixtureError("audio format desc \(status)") }

    let byteCount = count * audio.channels * 4
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(
        allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil,
        customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0,
        blockBufferOut: &block) == noErr, let blk = block else { throw FixtureError("block alloc") }
    guard CMBlockBufferAssureBlockMemory(blk) == noErr else { throw FixtureError("block memory") }
    audio.samples.withUnsafeBytes { raw in
        let src = raw.baseAddress!.advanced(by: startFrame * audio.channels * 4)
        CMBlockBufferReplaceDataBytes(with: src, blockBuffer: blk, offsetIntoDestination: 0, dataLength: byteCount)
    }
    var sb: CMSampleBuffer?
    let st = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: nil, dataBuffer: blk, formatDescription: format, sampleCount: count,
        presentationTimeStamp: CMTime(value: CMTimeValue(startFrame), timescale: CMTimeScale(audio.sampleRate)),
        packetDescriptions: nil, sampleBufferOut: &sb)
    guard st == noErr, let out = sb else { throw FixtureError("audio sample buffer \(st)") }
    return out
}

// MARK: - Movie writer

enum VideoCodec { case h264, hevcMain10HLG }

enum PixelMode {
    case bgra
    /// Rotate a portrait display canvas into a landscape encoded buffer (QuickTime 90 deg transform).
    case bgraRotated90
    /// 10-bit 4:2:0 video range, BT.2020 matrix (HLG), derived from the canvas.
    case x420HLG
}

struct MovieSpec {
    var url: URL
    var fileType: AVFileType
    var codec: VideoCodec = .h264
    var encodedWidth: Int
    var encodedHeight: Int
    var bitrate: Int
    var timescale: CMTimeScale = 2400
    /// Presentation tick of each frame, plus the end tick of the last frame (movie duration).
    var ptsTicks: [Int]
    var endTick: Int
    var pixelMode: PixelMode = .bgra
    var keyFrameIntervalFrames: Int = 30
    var audio: PCMAudio? = nil
    var audioBitrate: Int = 128_000
    /// Draws frame `i` onto the canvas (display orientation for `.bgraRotated90`).
    var canvasSize: (Int, Int)
    var draw: (Int, Canvas) -> Void
}

func writeMovie(_ spec: MovieSpec) throws {
    try? FileManager.default.removeItem(at: spec.url)
    let writer = try AVAssetWriter(outputURL: spec.url, fileType: spec.fileType)

    var vSettings: [String: Any] = [
        AVVideoWidthKey: spec.encodedWidth,
        AVVideoHeightKey: spec.encodedHeight,
    ]
    var props: [String: Any] = [
        AVVideoAverageBitRateKey: spec.bitrate,
        AVVideoMaxKeyFrameIntervalKey: spec.keyFrameIntervalFrames,
    ]
    var pixelFormat: OSType = kCVPixelFormatType_32BGRA
    switch spec.codec {
    case .h264:
        vSettings[AVVideoCodecKey] = AVVideoCodecType.h264
        props[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        vSettings[AVVideoColorPropertiesKey] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
    case .hevcMain10HLG:
        vSettings[AVVideoCodecKey] = AVVideoCodecType.hevc
        props[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
        vSettings[AVVideoColorPropertiesKey] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
        ]
        pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    }
    vSettings[AVVideoCompressionPropertiesKey] = props
    let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
    vInput.expectsMediaDataInRealTime = false
    if case .bgraRotated90 = spec.pixelMode {
        // Encoded landscape, displayed portrait (iPhone style): a=0 b=1 c=-1 d=0 tx=encodedHeight.
        vInput.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(spec.encodedHeight), ty: 0)
    }
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: vInput,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: spec.encodedWidth,
            kCVPixelBufferHeightKey as String: spec.encodedHeight,
        ])
    guard writer.canAdd(vInput) else { throw FixtureError("cannot add video input for \(spec.url.lastPathComponent)") }
    writer.add(vInput)

    var aInput: AVAssetWriterInput?
    if let audio = spec.audio {
        var aSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: audio.sampleRate,
            AVNumberOfChannelsKey: audio.channels,
            AVEncoderBitRateKey: spec.audioBitrate,
        ]
        if audio.channels == 6 {
            var l = AudioChannelLayout(); l.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_D
            aSettings[AVChannelLayoutKey] = Data(bytes: &l, count: MemoryLayout<AudioChannelLayout>.size)
        }
        let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
        ai.expectsMediaDataInRealTime = false
        guard writer.canAdd(ai) else { throw FixtureError("cannot add audio input") }
        writer.add(ai)
        aInput = ai
    }

    guard writer.startWriting() else { throw FixtureError("startWriting: \(String(describing: writer.error))") }
    writer.startSession(atSourceTime: .zero)

    let canvas = Canvas(width: spec.canvasSize.0, height: spec.canvasSize.1)
    var nextFrame = 0
    var nextAudio = 0
    let audioChunk = 4096
    var videoDone = false
    var audioDone = spec.audio == nil

    while !(videoDone && audioDone) {
        var progressed = false
        if !videoDone, vInput.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool {
            if nextFrame >= spec.ptsTicks.count {
                vInput.markAsFinished(); videoDone = true
            } else {
                var pb: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let buf = pb else {
                    throw FixtureError("pixel buffer pool exhausted")
                }
                spec.draw(nextFrame, canvas)
                try fillPixelBuffer(buf, from: canvas, mode: spec.pixelMode)
                let pts = CMTime(value: CMTimeValue(spec.ptsTicks[nextFrame]), timescale: spec.timescale)
                guard adaptor.append(buf, withPresentationTime: pts) else {
                    throw FixtureError("append video failed: \(String(describing: writer.error))")
                }
                nextFrame += 1
            }
            progressed = true
        }
        if !audioDone, let ai = aInput, let audio = spec.audio, ai.isReadyForMoreMediaData {
            if nextAudio >= audio.frameCount {
                ai.markAsFinished(); audioDone = true
            } else {
                let n = min(audioChunk, audio.frameCount - nextAudio)
                let sb = try pcmSampleBuffer(audio, startFrame: nextAudio, count: n)
                guard ai.append(sb) else { throw FixtureError("append audio failed: \(String(describing: writer.error))") }
                nextAudio += n
            }
            progressed = true
        }
        if !progressed { usleep(1000) }
    }

    writer.endSession(atSourceTime: CMTime(value: CMTimeValue(spec.endTick), timescale: spec.timescale))
    let sem = DispatchSemaphore(value: 0)
    writer.finishWriting { sem.signal() }
    sem.wait()
    guard writer.status == .completed else {
        throw FixtureError("finishWriting \(spec.url.lastPathComponent): \(String(describing: writer.error))")
    }
}

func fillPixelBuffer(_ buf: CVPixelBuffer, from c: Canvas, mode: PixelMode) throws {
    CVPixelBufferLockBaseAddress(buf, [])
    defer { CVPixelBufferUnlockBaseAddress(buf, []) }
    let src = c.data.assumingMemoryBound(to: UInt8.self)
    switch mode {
    case .bgra:
        let dst = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let dBpr = CVPixelBufferGetBytesPerRow(buf)
        for y in 0..<c.height {
            memcpy(dst + y * dBpr, src + y * c.bytesPerRow, c.width * 4)
        }
    case .bgraRotated90:
        // Encoded (x, y) holds display pixel (x' = He - 1 - y, y' = x), the inverse of
        // x' = He - y, y' = x applied by the preferred transform.
        let dst = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let dBpr = CVPixelBufferGetBytesPerRow(buf)
        let he = CVPixelBufferGetHeight(buf), we = CVPixelBufferGetWidth(buf)
        guard c.width == he, c.height == we else { throw FixtureError("rotated canvas size mismatch") }
        for y in 0..<he {
            let dRow = dst + y * dBpr
            for x in 0..<we {
                let sx = he - 1 - y, sy = x
                let s = src + sy * c.bytesPerRow + sx * 4
                let d = dRow + x * 4
                d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = s[3]
            }
        }
    case .x420HLG:
        let w = c.width, h = c.height
        let yBase = CVPixelBufferGetBaseAddressOfPlane(buf, 0)!
        let yBpr = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
        let cBase = CVPixelBufferGetBaseAddressOfPlane(buf, 1)!
        let cBpr = CVPixelBufferGetBytesPerRowOfPlane(buf, 1)
        let kr = 0.2627, kb = 0.0593, kg = 1 - kr - kb
        func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let p = src + y * c.bytesPerRow + x * 4   // B G R A
            return (Double(p[2]) / 255, Double(p[1]) / 255, Double(p[0]) / 255)
        }
        for y in 0..<h {
            let row = yBase.advanced(by: y * yBpr).assumingMemoryBound(to: UInt16.self)
            for x in 0..<w {
                let (r, g, b) = rgb(x, y)
                let yy = kr * r + kg * g + kb * b
                row[x] = UInt16(64 + (876 * yy).rounded()) << 6
            }
        }
        for cy in 0..<(h / 2) {
            let row = cBase.advanced(by: cy * cBpr).assumingMemoryBound(to: UInt16.self)
            for cx in 0..<(w / 2) {
                var r = 0.0, g = 0.0, b = 0.0
                for dy in 0..<2 { for dx in 0..<2 {
                    let v = rgb(cx * 2 + dx, cy * 2 + dy); r += v.0; g += v.1; b += v.2
                } }
                r /= 4; g /= 4; b /= 4
                let yy = kr * r + kg * g + kb * b
                let cb = (b - yy) / (2 * (1 - kb)), cr = (r - yy) / (2 * (1 - kr))
                row[cx * 2] = UInt16(512 + (896 * cb).rounded()) << 6
                row[cx * 2 + 1] = UInt16(512 + (896 * cr).rounded()) << 6
            }
        }
    }
}

// MARK: - Images

func writeImage(_ canvas: Canvas, to url: URL, type: UTType, quality: Double? = nil) throws {
    guard let image = canvas.ctx.makeImage() else { throw FixtureError("makeImage") }
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
        throw FixtureError("image destination")
    }
    var opts: [CFString: Any] = [:]
    if let q = quality { opts[kCGImageDestinationLossyCompressionQuality] = q }
    CGImageDestinationAddImage(dest, image, opts as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw FixtureError("image finalize \(url.lastPathComponent)") }
}

// MARK: - Fixture catalogue

struct Fixture {
    let name: String
    let isContainer: Bool
    let make: (URL) throws -> [String: Any]
}

func evenTicks(frames: Int, fps: Int, timescale: Int = 2400) -> ([Int], Int) {
    // 2400 is divisible by 24/25/30/48/60 -> exact integer ticks (600 is not divisible by 48).
    let step = timescale / fps
    return ((0..<frames).map { $0 * step }, frames * step)
}

func counterMovie(url: URL, width: Int, height: Int, fps: Int, seconds: Int, bitrate: Int) throws
    -> [String: Any]
{
    let frames = seconds * fps
    let (ticks, end) = evenTicks(frames: frames, fps: fps)
    try writeMovie(MovieSpec(
        url: url, fileType: .mp4, encodedWidth: width, encodedHeight: height, bitrate: bitrate,
        ptsTicks: ticks, endTick: end, keyFrameIntervalFrames: fps,
        canvasSize: (width, height),
        draw: { i, c in c.drawCounter(index: i, fps: Double(fps), seconds: Double(i) / Double(fps)) }))
    return [
        "container": "mp4", "durationSeconds": Double(seconds),
        "video": ["codec": "h264", "width": width, "height": height, "displayWidth": width,
                  "displayHeight": height, "rotationDegrees": 0, "fps": fps, "frameCount": frames,
                  "variableFrameRate": false],
        "audio": NSNull(),
        "barcode": ["firstIndex": 0, "lastIndex": frames - 1, "step": 1, "indexEqualsFrameNumber": true],
    ]
}

func counterFixture(_ name: String, _ w: Int, _ h: Int, _ fps: Int, _ bitrate: Int) -> Fixture {
    Fixture(name: name, isContainer: false) { dir in
        try counterMovie(url: dir.appendingPathComponent(name), width: w, height: h, fps: fps,
                         seconds: 8, bitrate: bitrate)
    }
}

let flashFrames = [30, 75, 120]   // at 30 fps: 1.0 s, 2.5 s, 4.0 s

func vfrTicks() -> ([Int], Int) {
    // timescale 600. Cycled durations (ticks) plus one 0.5 s hold at frame 60 (screen-recording style).
    let cycle = [20, 20, 40, 25, 10, 30, 20, 20]
    var ticks: [Int] = []
    var t = 0
    var i = 0
    while t < 3600 {
        ticks.append(t)
        t += (i == 60) ? 300 : cycle[i % cycle.count]
        i += 1
    }
    return (ticks, t)
}

func findFFmpeg() -> String? {
    if let e = ProcessInfo.processInfo.environment["FFMPEG"], FileManager.default.isExecutableFile(atPath: e) { return e }
    for p in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
    where FileManager.default.isExecutableFile(atPath: p) { return p }
    return nil
}

func runFFmpeg(_ args: [String]) throws {
    guard let ff = findFFmpeg() else { throw FixtureError("ffmpeg not found (set FFMPEG or use --skip-containers)") }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: ff)
    p.arguments = ["-hide_banner", "-loglevel", "error", "-y"] + args
    try p.run(); p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw FixtureError("ffmpeg failed: \(args.joined(separator: " "))") }
}

func makeFixtures(containerSource: URL) -> [Fixture] {
    var list: [Fixture] = []

    list.append(counterFixture("frame_counter_1080p30.mp4", 1920, 1080, 30, 4_000_000))
    list.append(counterFixture("frame_counter_720p25.mp4", 1280, 720, 25, 2_000_000))
    list.append(counterFixture("frame_counter_720p24.mp4", 1280, 720, 24, 2_000_000))
    list.append(counterFixture("frame_counter_720p48.mp4", 1280, 720, 48, 3_000_000))
    list.append(counterFixture("frame_counter_720p60.mp4", 1280, 720, 60, 3_500_000))

    list.append(Fixture(name: "clap_flash_av.mp4", isContainer: false) { dir in
        let fps = 30, frames = 180
        let (ticks, end) = evenTicks(frames: frames, fps: fps)
        let times = flashFrames.map { Double($0) / Double(fps) }
        let audio = clickAudio(times: times, seconds: 6, sampleRate: 48000, peakDb: -6)
        try writeMovie(MovieSpec(
            url: dir.appendingPathComponent("clap_flash_av.mp4"), fileType: .mp4,
            encodedWidth: 1280, encodedHeight: 720, bitrate: 2_000_000, ptsTicks: ticks, endTick: end,
            keyFrameIntervalFrames: fps, audio: audio, audioBitrate: 96_000, canvasSize: (1280, 720),
            draw: { i, c in
                c.drawCounter(index: i, fps: Double(fps), seconds: Double(i) / Double(fps),
                              flash: flashFrames.contains(i))
            }))
        return [
            "container": "mp4", "durationSeconds": 6.0,
            "video": ["codec": "h264", "width": 1280, "height": 720, "displayWidth": 1280,
                      "displayHeight": 720, "rotationDegrees": 0, "fps": fps, "frameCount": frames,
                      "variableFrameRate": false],
            "audio": ["codec": "aac", "sampleRate": 48000, "channels": 1, "channelLayout": "mono",
                      "clickHz": 2000, "clickDurationMs": 20, "clickPeakDbfs": -6,
                      "aacWithPrimingEditList": true],
            "barcode": ["firstIndex": 0, "lastIndex": frames - 1, "step": 1, "indexEqualsFrameNumber": true],
            "flashFrames": flashFrames, "flashTimesSeconds": times,
            "clickTimesSeconds": times,
            "note": "Flash frames are all-white with black digits; the barcode band stays readable on them. Each click starts exactly at its flash frame's presentation time.",
        ]
    })

    list.append(Fixture(name: "vfr_720p.mp4", isContainer: false) { dir in
        let (ticks, end) = vfrTicks()
        try writeMovie(MovieSpec(
            url: dir.appendingPathComponent("vfr_720p.mp4"), fileType: .mp4,
            encodedWidth: 1280, encodedHeight: 720, bitrate: 1_800_000, timescale: 600,
            ptsTicks: ticks, endTick: end, keyFrameIntervalFrames: 30, canvasSize: (1280, 720),
            draw: { i, c in c.drawCounter(index: i, fps: 0, seconds: Double(ticks[i]) / 600.0) }))
        return [
            "container": "mp4", "durationSeconds": Double(end) / 600.0,
            "video": ["codec": "h264", "width": 1280, "height": 720, "displayWidth": 1280,
                      "displayHeight": 720, "rotationDegrees": 0, "fps": NSNull(),
                      "frameCount": ticks.count, "variableFrameRate": true,
                      "ptsTimescale": 600, "ptsTicks": ticks, "endTick": end],
            "audio": NSNull(),
            "barcode": ["firstIndex": 0, "lastIndex": ticks.count - 1, "step": 1, "indexEqualsFrameNumber": true],
            "note": "Frame i shows barcode i and is presented at ptsTicks[i] / 600 s. Frame 60 is held for 0.5 s.",
        ]
    })

    list.append(Fixture(name: "hlg_10bit_720p.mov", isContainer: false) { dir in
        let fps = 30, frames = 90
        let (ticks, end) = evenTicks(frames: frames, fps: fps)
        try writeMovie(MovieSpec(
            url: dir.appendingPathComponent("hlg_10bit_720p.mov"), fileType: .mov,
            codec: .hevcMain10HLG, encodedWidth: 1280, encodedHeight: 720, bitrate: 3_000_000,
            ptsTicks: ticks, endTick: end, pixelMode: .x420HLG, keyFrameIntervalFrames: fps,
            canvasSize: (1280, 720),
            draw: { i, c in c.drawCounter(index: i, fps: Double(fps), seconds: Double(i) / Double(fps)) }))
        return [
            "container": "mov", "durationSeconds": 3.0,
            "video": ["codec": "hevc", "profile": "Main10", "bitDepth": 10, "width": 1280, "height": 720,
                      "displayWidth": 1280, "displayHeight": 720, "rotationDegrees": 0, "fps": fps,
                      "frameCount": frames, "variableFrameRate": false,
                      "colorPrimaries": "bt2020", "transfer": "arib-std-b67", "matrix": "bt2020nc"],
            "audio": NSNull(),
            "barcode": ["firstIndex": 0, "lastIndex": frames - 1, "step": 1, "indexEqualsFrameNumber": true],
        ]
    })

    list.append(Fixture(name: "rotated_90.mov", isContainer: false) { dir in
        let fps = 30, frames = 90
        let (ticks, end) = evenTicks(frames: frames, fps: fps)
        try writeMovie(MovieSpec(
            url: dir.appendingPathComponent("rotated_90.mov"), fileType: .mov,
            encodedWidth: 1280, encodedHeight: 720, bitrate: 2_000_000, ptsTicks: ticks, endTick: end,
            pixelMode: .bgraRotated90, keyFrameIntervalFrames: fps, canvasSize: (720, 1280),
            draw: { i, c in c.drawCounter(index: i, fps: Double(fps), seconds: Double(i) / Double(fps)) }))
        return [
            "container": "mov", "durationSeconds": 3.0,
            "video": ["codec": "h264", "width": 1280, "height": 720, "displayWidth": 720,
                      "displayHeight": 1280, "rotationDegrees": 90, "fps": fps, "frameCount": frames,
                      "variableFrameRate": false],
            "audio": NSNull(),
            "barcode": ["firstIndex": 0, "lastIndex": frames - 1, "step": 1, "indexEqualsFrameNumber": true],
            "note": "Encoded landscape 1280x720 with a 90 degree preferred transform; the barcode is upright (top band) only after the rotation is applied.",
        ]
    })

    list.append(Fixture(name: "speech_10s.m4a", isContainer: false) { dir in
        let spoken = "Welcome to the video editor test. The quick brown fox jumps over the lazy dog. "
            + "Today we will trim a clip, add a title, and export the final movie. "
            + "Please keep your eyes on the timeline while the captions appear."
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("danaview_speech_\(getpid()).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        var voice = "Samantha"
        let probe = Process(); let pipe = Pipe()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/say"); probe.arguments = ["-v", "?"]
        probe.standardOutput = pipe
        try? probe.run(); probe.waitUntilExit()
        let voices = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if !voices.contains("Samantha") { voice = "" }
        say.arguments = (voice.isEmpty ? [] : ["-v", voice]) + ["-r", "165", "-o", tmp.path,
                                                                  "--data-format=LEI16@44100", spoken]
        try say.run(); say.waitUntilExit()
        guard say.terminationStatus == 0 else { throw FixtureError("say failed") }
        let file = try AVAudioFile(forReading: tmp)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: true)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buf)
        let total = 441_000
        var samples = [Float](repeating: 0, count: total)
        let got = min(Int(buf.frameLength), total)
        for i in 0..<got { samples[i] = buf.floatChannelData![0][i] }
        // Fade the last 50 ms if the speech had to be truncated.
        if Int(buf.frameLength) > total {
            let n = 2205
            for i in 0..<n { samples[total - n + i] *= Float(n - i) / Float(n) }
        }
        let audio = PCMAudio(sampleRate: 44100, channels: 1, samples: samples)
        try writeAudioFile(audio, to: dir.appendingPathComponent("speech_10s.m4a"), bitrate: 64_000)
        return [
            "container": "m4a", "durationSeconds": 10.0, "video": NSNull(),
            "audio": ["codec": "aac", "sampleRate": 44100, "channels": 1, "channelLayout": "mono",
                      "speech": true, "voice": voice.isEmpty ? "system default" : voice,
                      "spokenText": spoken],
        ]
    })

    list.append(Fixture(name: "surround_5_1.m4a", isContainer: false) { dir in
        let audio = sineAudio(hz: 500, seconds: 5, sampleRate: 48000, channels: 6, peakDb: -12, onlyChannel: 0)
        try writeAudioFile(audio, to: dir.appendingPathComponent("surround_5_1.m4a"), bitrate: 192_000)
        return [
            "container": "m4a", "durationSeconds": 5.0, "video": NSNull(),
            "audio": ["codec": "aac", "sampleRate": 48000, "channels": 6, "channelLayout": "5.1",
                      "channelOrder": ["C", "L", "R", "Ls", "Rs", "LFE"], "toneHz": 500,
                      "toneChannel": "C", "peakDbfs": -12, "otherChannelsSilent": true],
        ]
    })

    for (name, hz) in [("tone_440hz.wav", 440.0), ("tone_1khz.wav", 1000.0)] {
        list.append(Fixture(name: name, isContainer: false) { dir in
            let a = sineAudio(hz: hz, seconds: 10, sampleRate: 48000, channels: 1, peakDb: -12)
            try writeWav16(a, to: dir.appendingPathComponent(name))
            return [
                "container": "wav", "durationSeconds": 10.0, "video": NSNull(),
                "audio": ["codec": "pcm_s16le", "sampleRate": 48000, "channels": 1, "channelLayout": "mono",
                          "toneHz": hz, "peakDbfs": -12],
            ]
        })
    }

    list.append(Fixture(name: "stereo_440l_880r.wav", isContainer: false) { dir in
        let a = sineAudio(hz: 0, seconds: 5, sampleRate: 48000, channels: 2, peakDb: -12,
                          perChannelHz: [440, 880])
        try writeWav16(a, to: dir.appendingPathComponent("stereo_440l_880r.wav"))
        return [
            "container": "wav", "durationSeconds": 5.0, "video": NSNull(),
            "audio": ["codec": "pcm_s16le", "sampleRate": 48000, "channels": 2, "channelLayout": "stereo",
                      "toneHzLeft": 440, "toneHzRight": 880, "peakDbfs": -12],
        ]
    })

    list.append(Fixture(name: "tone_under_video.mp4", isContainer: false) { dir in
        let fps = 30, frames = 240
        let (ticks, end) = evenTicks(frames: frames, fps: fps)
        let audio = sineAudio(hz: 1000, seconds: 8, sampleRate: 48000, channels: 1, peakDb: -12)
        try writeMovie(MovieSpec(
            url: dir.appendingPathComponent("tone_under_video.mp4"), fileType: .mp4,
            encodedWidth: 1280, encodedHeight: 720, bitrate: 2_000_000, ptsTicks: ticks, endTick: end,
            keyFrameIntervalFrames: fps, audio: audio, audioBitrate: 96_000, canvasSize: (1280, 720),
            draw: { i, c in c.drawCounter(index: i, fps: Double(fps), seconds: Double(i) / Double(fps)) }))
        return [
            "container": "mp4", "durationSeconds": 8.0,
            "video": ["codec": "h264", "width": 1280, "height": 720, "displayWidth": 1280,
                      "displayHeight": 720, "rotationDegrees": 0, "fps": fps, "frameCount": frames,
                      "variableFrameRate": false],
            "audio": ["codec": "aac", "sampleRate": 48000, "channels": 1, "channelLayout": "mono",
                      "toneHz": 1000, "peakDbfs": -12, "aacWithPrimingEditList": true],
            "barcode": ["firstIndex": 0, "lastIndex": frames - 1, "step": 1, "indexEqualsFrameNumber": true],
        ]
    })

    list.append(Fixture(name: "still_4k.jpg", isContainer: false) { dir in
        let c = Canvas(width: 3840, height: 2160)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let grad = CGGradient(colorsSpace: cs, colors: [
            CGColor(srgbRed: 0.10, green: 0.25, blue: 0.55, alpha: 1),
            CGColor(srgbRed: 0.95, green: 0.55, blue: 0.20, alpha: 1)] as CFArray, locations: [0, 1])!
        c.ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 3840, y: 2160), options: [])
        c.fill(1, 1, 1, CGRect(x: 960, y: 540, width: 1920, height: 1080).insetBy(dx: 40, dy: 40))
        c.fill(0.9, 0.15, 0.2, CGRect(x: 1100, y: 700, width: 800, height: 700))
        c.fill(0.1, 0.7, 0.3, CGRect(x: 2000, y: 700, width: 800, height: 700))
        c.text("STILL 4K 3840x2160", size: 150, x: 1920, baseline: 1750, centered: true,
               color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        c.drawBarcode(index: 0)
        try writeImage(c, to: dir.appendingPathComponent("still_4k.jpg"), type: .jpeg, quality: 0.72)
        return ["container": "jpeg", "image": ["width": 3840, "height": 2160, "alpha": false],
                "barcode": ["firstIndex": 0, "lastIndex": 0, "step": 1, "indexEqualsFrameNumber": true]]
    })

    list.append(Fixture(name: "alpha.png", isContainer: false) { dir in
        let c = Canvas(width: 512, height: 512)
        c.ctx.clear(CGRect(x: 0, y: 0, width: 512, height: 512))
        // Hard-edged opaque square, a soft radial disc, and a fully transparent margin.
        c.fill(0.95, 0.2, 0.2, CGRect(x: 64, y: 64, width: 160, height: 160))
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let radial = CGGradient(colorsSpace: cs, colors: [
            CGColor(srgbRed: 0.1, green: 0.5, blue: 1, alpha: 1),
            CGColor(srgbRed: 0.1, green: 0.5, blue: 1, alpha: 0)] as CFArray, locations: [0, 1])!
        c.ctx.drawRadialGradient(radial, startCenter: CGPoint(x: 340, y: 340), startRadius: 0,
                                 endCenter: CGPoint(x: 340, y: 340), endRadius: 150, options: [])
        c.ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.9, blue: 0.3, alpha: 0.5))
        c.ctx.fill(CGRect(x: 64, y: 300, width: 160, height: 120))
        try writeImage(c, to: dir.appendingPathComponent("alpha.png"), type: .png)
        return ["container": "png", "image": ["width": 512, "height": 512, "alpha": true],
                "note": "Transparent margin; opaque red square at (64,64) 160x160; 50% green rectangle at (64,300) 160x120; radial blue disc centred (340,340), alpha 1 -> 0 over radius 150."]
    })

    // Containers AVFoundation cannot write: derived with the dev-only ffmpeg from the 720p25 counter
    // (first 3 s, scaled to 640x360) so the barcode survives; audio is a 440 Hz sine at -12 dBFS.
    let src = containerSource.path
    list.append(Fixture(name: "sample_h264_aac.mkv", isContainer: true) { dir in
        try runFFmpeg(["-i", src, "-t", "3", "-f", "lavfi", "-t", "3", "-i", "sine=frequency=440:sample_rate=48000",
                       "-vf", "scale=640:360", "-c:v", "libx264", "-preset", "medium", "-crf", "23", "-pix_fmt", "yuv420p",
                       "-r", "25", "-af", "volume=-12dB", "-c:a", "aac", "-b:a", "96k", "-ac", "1", "-shortest",
                       "-map", "0:v:0", "-map", "1:a:0", dir.appendingPathComponent("sample_h264_aac.mkv").path])
        return [
            "container": "matroska", "durationSeconds": 3.0,
            "video": ["codec": "h264", "width": 640, "height": 360, "fps": 25, "frameCount": 75, "rotationDegrees": 0],
            "audio": ["codec": "aac", "sampleRate": 48000, "channels": 1, "toneHz": 440],
            "barcode": ["firstIndex": 0, "lastIndex": 74, "step": 1, "indexEqualsFrameNumber": true],
            "iosRefusal": true,
        ]
    })
    list.append(Fixture(name: "sample_vp9_opus.webm", isContainer: true) { dir in
        try runFFmpeg(["-i", src, "-t", "3", "-f", "lavfi", "-t", "3", "-i", "sine=frequency=440:sample_rate=48000",
                       "-vf", "scale=640:360", "-c:v", "libvpx-vp9", "-b:v", "600k", "-deadline", "good",
                       "-cpu-used", "4", "-pix_fmt", "yuv420p", "-r", "25", "-af", "volume=-12dB", "-c:a", "libopus",
                       "-b:a", "64k", "-ac", "1", "-shortest", "-map", "0:v:0", "-map", "1:a:0",
                       dir.appendingPathComponent("sample_vp9_opus.webm").path])
        return [
            "container": "webm", "durationSeconds": 3.0,
            "video": ["codec": "vp9", "width": 640, "height": 360, "fps": 25, "frameCount": 75, "rotationDegrees": 0],
            "audio": ["codec": "opus", "sampleRate": 48000, "channels": 1, "toneHz": 440],
            "barcode": ["firstIndex": 0, "lastIndex": 74, "step": 1, "indexEqualsFrameNumber": true],
            "iosRefusal": true,
        ]
    })
    return list
}

func writeAudioFile(_ audio: PCMAudio, to url: URL, bitrate: Int) throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
    var settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: audio.sampleRate,
        AVNumberOfChannelsKey: audio.channels, AVEncoderBitRateKey: bitrate,
    ]
    if audio.channels == 6 {
        var l = AudioChannelLayout(); l.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_D
        settings[AVChannelLayoutKey] = Data(bytes: &l, count: MemoryLayout<AudioChannelLayout>.size)
    }
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    writer.add(input)
    guard writer.startWriting() else { throw FixtureError("audio startWriting: \(String(describing: writer.error))") }
    writer.startSession(atSourceTime: .zero)
    var next = 0
    while next < audio.frameCount {
        if !input.isReadyForMoreMediaData { usleep(1000); continue }
        let n = min(4096, audio.frameCount - next)
        guard input.append(try pcmSampleBuffer(audio, startFrame: next, count: n)) else {
            throw FixtureError("audio append: \(String(describing: writer.error))")
        }
        next += n
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: CMTimeValue(audio.frameCount), timescale: CMTimeScale(audio.sampleRate)))
    let sem = DispatchSemaphore(value: 0)
    writer.finishWriting { sem.signal() }
    sem.wait()
    guard writer.status == .completed else { throw FixtureError("audio finish: \(String(describing: writer.error))") }
}

// MARK: - Main

let toolDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
var outDir = toolDir.deletingLastPathComponent().appendingPathComponent("test_fixtures/media")
var only: Set<String>? = nil
var skipContainers = false
var listOnly = false
var argv = Array(CommandLine.arguments.dropFirst())
while !argv.isEmpty {
    let a = argv.removeFirst()
    switch a {
    case "--out": outDir = URL(fileURLWithPath: argv.removeFirst())
    case "--only": only = Set(argv.removeFirst().split(separator: ",").map(String.init))
    case "--skip-containers": skipContainers = true
    case "--list": listOnly = true
    default:
        log("unknown argument \(a)"); exit(64)
    }
}

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let all = makeFixtures(containerSource: outDir.appendingPathComponent("frame_counter_720p25.mp4"))
if listOnly { all.forEach { print($0.name) }; exit(0) }

var manifest: [String: Any] = [:]
// Merge an existing manifest so partial runs (--only) keep the other entries.
let manifestURL = outDir.appendingPathComponent("manifest.json")
if let data = try? Data(contentsOf: manifestURL),
   let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let files = old["files"] as? [String: Any] { manifest = files }

for fx in all {
    if let only = only, !only.contains(fx.name) { continue }
    if fx.isContainer && skipContainers { log("skip \(fx.name)"); continue }
    let t0 = Date()
    do {
        var entry = try fx.make(outDir)
        let size = (try FileManager.default.attributesOfItem(atPath: outDir.appendingPathComponent(fx.name).path)[.size] as? Int) ?? 0
        entry["bytes"] = size
        manifest[fx.name] = entry
        log(String(format: "ok   %-28@ %8d bytes  %.1fs", fx.name as NSString, size, Date().timeIntervalSince(t0)))
    } catch {
        log("FAIL \(fx.name): \(error)"); exit(1)
    }
}

let root: [String: Any] = [
    "schema": 1,
    "generator": "tool/make_fixtures.swift",
    "barcode": ["cellCount": BarcodeSpec.cellCount, "bandPercentOfHeight": 10,
                "layout": "cell0 white, cell1 black, 16 index bits MSB first, 8 CRC-8 bits (poly 0x07), cell26 white, cell27 black"],
    "files": manifest,
]
let json = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
try json.write(to: manifestURL)
log("manifest: \(manifestURL.path)")
