// OWNER: IOS-04
//
// `.dvpk` waveform peaks (ARCH §12.3, §15; design/native.md §5.6): one audio stream decoded by
// PcmReader, mixed to mono with the fixed Downmix, binned at 200 pairs per second (bin i covers
// source frames [i·rate/200, (i+1)·rate/200)), each bin's min and max quantised to int8
// (round(x · 127), clamped to ±127). Cached in DiskCache waves/ as `<fingerprint>-<stream>.dvpk`:
//
//   offset  size  field (little endian)
//   0       4     "DVPK"
//   4       2     version (1)
//   6       2     pairs per second (200)
//   8       8     duration µs (int64)
//   16      4     pair count (uint32)
//   20      4     source sample rate (uint32)
//   24      2     source channels (uint16)
//   26      2     audio stream (uint16)
//   28      4     reserved (0)
//   32      2·n   int8 min, int8 max per pair
//
// IOS-05's JobRegistry runs `peaks(...)` as the `waveform` job (cancel, progress) and answers
// with the returned WaveformPeaksMsg.

import Accelerate
import Flutter
import Foundation

final class WaveformService {
    static let pairsPerSecond = 200
    static let fileExtension = "dvpk"
    static let headerSize = 32

    /// The decoded peaks with their source facts.
    struct Peaks: Equatable {
        var minMax: Data
        var durationUs: Int64
        var sampleRate: Int
        var channels: Int
        var audioStream: Int
        var pairCount: Int { minMax.count / 2 }

        var message: WaveformPeaksMsg {
            WaveformPeaksMsg(
                minMax: FlutterStandardTypedData(bytes: minMax), durationUs: durationUs,
                pairsPerSecond: Int64(WaveformService.pairsPerSecond))
        }
    }

    static func cacheKey(fingerprint: String, audioStream: Int) -> String {
        "\(CacheStore.fileName(fingerprint))-\(audioStream)"
    }

    /// Peaks of [audioStream] of [url]: from the waves/ cache when present, else decoded and stored.
    static func peaks(
        url: URL, fingerprint: String, audioStream: Int = 0, store: CacheStore?,
        cancellation: MediaCancellation? = nil, progress: ((Double) -> Void)? = nil
    ) throws -> WaveformPeaksMsg {
        let key = cacheKey(fingerprint: fingerprint, audioStream: audioStream)
        if let store = store, let data = store.read(key: key, ext: fileExtension), let cached = decode(data) {
            progress?(1)
            return cached.message
        }
        let peaks = try compute(url: url, audioStream: audioStream, cancellation: cancellation, progress: progress)
        if let store = store {
            _ = try? store.write(encode(peaks), key: key, ext: fileExtension)
        }
        return peaks.message
    }

    /// Decodes and bins [audioStream] of [url] (no cache).
    static func compute(
        url: URL, audioStream: Int = 0, cancellation: MediaCancellation? = nil, progress: ((Double) -> Void)? = nil
    ) throws -> Peaks {
        let reader = try PcmReader(url: url, audioStream: audioStream, cancellation: cancellation)
        let rate = reader.format.sampleRate
        let channels = reader.format.channels
        let coefficients = Downmix.coefficients(channels: channels, labels: reader.format.labels)
        let binner = PeakBinner(sampleRate: rate)
        var lastReport = 0.0
        while let chunk = try reader.read() {
            binner.add(Downmix.mono(chunk, channels: channels, coefficients: coefficients))
            if let progress = progress, reader.progress - lastReport >= 0.05 {
                lastReport = reader.progress
                progress(lastReport)
            }
        }
        try cancellation?.check()
        progress?(1)
        let frames = binner.frames
        return Peaks(
            minMax: binner.finish(), durationUs: Int64((Double(frames) * 1_000_000 / rate).rounded()),
            sampleRate: Int(rate.rounded()), channels: channels, audioStream: audioStream)
    }

    // MARK: Binning

    /// Streaming min/max binning at 200 pairs/s.
    final class PeakBinner {
        let sampleRate: Double
        private(set) var frames = 0
        private var bins: [Int8] = []
        private var currentMin: Float = .greatestFiniteMagnitude
        private var currentMax: Float = -.greatestFiniteMagnitude
        private var currentBin = 0
        private var currentHasData = false

        init(sampleRate: Double) {
            self.sampleRate = sampleRate
        }

        /// First frame of bin [i].
        func binStart(_ i: Int) -> Int {
            Int((Double(i) * sampleRate / Double(WaveformService.pairsPerSecond)).rounded(.down))
        }

        func add(_ mono: [Float]) {
            var offset = 0
            mono.withUnsafeBufferPointer { buffer in
                while offset < buffer.count {
                    let absolute = frames + offset
                    let binEnd = binStart(currentBin + 1)
                    if absolute >= binEnd {
                        flush()
                        continue
                    }
                    let take = min(buffer.count - offset, binEnd - absolute)
                    var lo: Float = 0
                    var hi: Float = 0
                    vDSP_minv(buffer.baseAddress! + offset, 1, &lo, vDSP_Length(take))
                    vDSP_maxv(buffer.baseAddress! + offset, 1, &hi, vDSP_Length(take))
                    currentMin = min(currentMin, lo)
                    currentMax = max(currentMax, hi)
                    currentHasData = true
                    offset += take
                }
            }
            frames += mono.count
        }

        private func flush() {
            if currentHasData {
                bins.append(WaveformService.quantize(currentMin))
                bins.append(WaveformService.quantize(currentMax))
            } else {
                bins.append(0)
                bins.append(0)
            }
            currentBin += 1
            currentMin = .greatestFiniteMagnitude
            currentMax = -.greatestFiniteMagnitude
            currentHasData = false
        }

        /// The interleaved min/max pairs (the last partial bin included).
        func finish() -> Data {
            if currentHasData { flush() }
            return bins.withUnsafeBufferPointer { Data(buffer: $0) }
        }
    }

    static func quantize(_ value: Float) -> Int8 {
        guard value.isFinite else { return 0 }
        return Int8(max(-127, min(127, (value * 127).rounded())))
    }

    // MARK: File format

    static func encode(_ peaks: Peaks) -> Data {
        var data = Data(capacity: headerSize + peaks.minMax.count)
        data.append(Data("DVPK".utf8))
        func put<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        put(UInt16(1))
        put(UInt16(pairsPerSecond))
        put(Int64(peaks.durationUs))
        put(UInt32(peaks.pairCount))
        put(UInt32(peaks.sampleRate))
        put(UInt16(peaks.channels))
        put(UInt16(peaks.audioStream))
        put(UInt32(0))
        data.append(peaks.minMax)
        return data
    }

    static func decode(_ data: Data) -> Peaks? {
        guard data.count >= headerSize, data.prefix(4) == Data("DVPK".utf8) else { return nil }
        let bytes = [UInt8](data.prefix(headerSize))
        func read<T: FixedWidthInteger>(_ offset: Int, _: T.Type) -> T {
            var value: T = 0
            for i in 0..<MemoryLayout<T>.size {
                value |= T(truncatingIfNeeded: bytes[offset + i]) << (8 * i)
            }
            return value
        }
        guard read(4, UInt16.self) == 1, read(6, UInt16.self) == UInt16(pairsPerSecond) else { return nil }
        let pairs = Int(read(16, UInt32.self))
        guard data.count == headerSize + pairs * 2 else { return nil }
        return Peaks(
            minMax: data.subdata(in: headerSize..<data.count), durationUs: read(8, Int64.self),
            sampleRate: Int(read(20, UInt32.self)), channels: Int(read(24, UInt16.self)),
            audioStream: Int(read(26, UInt16.self)))
    }
}
