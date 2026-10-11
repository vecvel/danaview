// OWNER: IOS-04
//
// Speech audio for transcription (ai.md §7, D-28 port implemented natively; ARCH §15): a source
// range of one audio stream -> canonical RIFF/WAVE, PCM s16le, mono, 16,000 Hz, "fmt " then
// "data" only. Sample 0 is source time range.start (PcmReader: edit lists, AAC priming and
// sample-accurate trim); fixed Downmix (mono copy; stereo 0.5/0.5; 5.1 -> 0.5·C + 0.25·(L+R) +
// 0.125·(Ls+Rs), LFE dropped); AVAudioConverter Float32 mono at the source rate -> Int16 16 kHz
// with sampleRateConverterQuality .high. The output always holds round(duration · 16000) frames
// (the converter's tail is padded or cut), so its duration equals the range within 1 ms.
// The WAV is streamed to `<output>.part` (header patched at the end) and renamed onto the
// Dart-supplied path; cancellation and failures delete the partial file. Unsupported containers
// or codecs fail with unsupportedMedia. IOS-05's JobRegistry runs it as the `speechAudio` job.

import AVFoundation
import Flutter
import Foundation

final class SpeechAudioExtractor {
    static let outputRate: Double = 16_000

    struct Result: Equatable {
        var path: String
        var frames: Int
        var durationUs: Int64
        var sourceChannels: Int
        var sourceSampleRate: Int
        var codec: String

        var message: ExtractedSpeechAudioMsg {
            ExtractedSpeechAudioMsg(
                path: path, frames: Int64(frames), durationUs: durationUs, sourceChannels: Int64(sourceChannels),
                sourceSampleRate: Int64(sourceSampleRate), codec: codec)
        }
    }

    /// Extracts [startUs, endUs) of [audioStream] of [url] to [output]. Blocking.
    static func extract(
        url: URL, startUs: Int64, endUs: Int64, audioStream: Int? = nil, output: URL,
        cancellation: MediaCancellation? = nil, progress: ((Double) -> Void)? = nil
    ) throws -> Result {
        let partial = output.appendingPathExtension("part")
        do {
            return try run(url: url, startUs: startUs, endUs: endUs, audioStream: audioStream ?? 0, output: output,
                           partial: partial, cancellation: cancellation, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            if cancellation?.isCancelled == true { throw EngineError.cancelled }
            throw EngineError.from(error)
        }
    }

    private static func run(
        url: URL, startUs: Int64, endUs: Int64, audioStream: Int, output: URL, partial: URL,
        cancellation: MediaCancellation?, progress: ((Double) -> Void)?
    ) throws -> Result {
        let reader = try PcmReader(url: url, audioStream: audioStream, startUs: startUs, endUs: endUs,
                                   cancellation: cancellation)
        let format = reader.format
        let coefficients = Downmix.coefficients(channels: format.channels, labels: format.labels)
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
              let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: outputRate, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { throw EngineError(.internal, "audio converter unavailable") }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try WavWriter(url: partial, sampleRate: Int(outputRate))
        let expected = Int((Double(reader.endUs - reader.startUs) * outputRate / 1_000_000).rounded())

        var pending: [Float]?
        var inputDone = false
        var readError: Error?
        let capacity: AVAudioFrameCount = 8192
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw EngineError(.internal, "audio buffer")
        }
        var written = 0
        var lastReport = 0.0
        loop: while written < expected {
            try cancellation?.check()
            outBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
                if inputDone {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    let chunk = try pending ?? reader.read()
                    pending = nil
                    guard let samples = chunk else {
                        inputDone = true
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    let mono = Downmix.mono(samples, channels: format.channels, coefficients: coefficients)
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(mono.count)) else {
                        inputDone = true
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    buffer.frameLength = AVAudioFrameCount(mono.count)
                    mono.withUnsafeBufferPointer { source in
                        buffer.floatChannelData![0].update(from: source.baseAddress!, count: mono.count)
                    }
                    inputStatus.pointee = .haveData
                    return buffer
                } catch {
                    readError = error
                    inputDone = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
            }
            if let error = readError { throw error }
            if status == .error { throw conversionError.map(EngineError.from) ?? EngineError(.decodeFailed, "conversion failed") }
            let frames = Int(outBuffer.frameLength)
            if frames > 0 {
                let take = min(frames, expected - written)
                try writer.append(outBuffer.int16ChannelData![0], frames: take)
                written += take
            }
            if let progress = progress, reader.progress - lastReport >= 0.05 {
                lastReport = reader.progress
                progress(min(0.99, lastReport))
            }
            if status == .endOfStream || (frames == 0 && inputDone) { break loop }
        }
        // Pad the converter's tail so the duration equals the range (only when the media covered it).
        let target = reader.framesDelivered >= reader.expectedFrames
            ? expected : Int((Double(reader.framesDelivered) * outputRate / format.sampleRate).rounded())
        if written < target {
            let zeros = [Int16](repeating: 0, count: target - written)
            try zeros.withUnsafeBufferPointer { try writer.append($0.baseAddress!, frames: zeros.count) }
            written = target
        }
        try cancellation?.check()
        try writer.finish()
        do {
            if FileManager.default.fileExists(atPath: output.path) {
                _ = try FileManager.default.replaceItemAt(output, withItemAt: partial)
            } else {
                try FileManager.default.moveItem(at: partial, to: output)
            }
        } catch {
            throw EngineError.from(error)
        }
        progress?(1)
        return Result(
            path: output.path, frames: written, durationUs: Int64((Double(written) * 1_000_000 / outputRate).rounded()),
            sourceChannels: format.channels, sourceSampleRate: Int(format.sampleRate.rounded()), codec: format.codec)
    }
}

/// Streams a PCM s16le mono RIFF/WAVE file and patches the sizes on `finish`.
final class WavWriter {
    private let handle: FileHandle
    private let sampleRate: Int
    private(set) var frames = 0
    private var finished = false

    init(url: URL, sampleRate: Int) throws {
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw EngineError(.io, "cannot create output", retryable: true)
        }
        handle = try FileHandle(forWritingTo: url)
        self.sampleRate = sampleRate
        try write(WavWriter.header(sampleRate: sampleRate, dataBytes: 0))
    }

    deinit {
        if !finished { try? handle.close() }
    }

    static func header(sampleRate: Int, dataBytes: Int) -> Data {
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(Data("RIFF".utf8))
        put(UInt32(36 + dataBytes))
        data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8))
        put(UInt32(16))
        put(UInt16(1))  // PCM
        put(UInt16(1))  // mono
        put(UInt32(sampleRate))
        put(UInt32(sampleRate * 2))  // byte rate
        put(UInt16(2))  // block align
        put(UInt16(16))  // bits per sample
        data.append(Data("data".utf8))
        put(UInt32(dataBytes))
        return data
    }

    private func write(_ data: Data) throws {
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw EngineError.from(error)
        }
    }

    func append(_ samples: UnsafePointer<Int16>, frames count: Int) throws {
        guard count > 0 else { return }
        var little = [Int16](repeating: 0, count: count)
        for i in 0..<count { little[i] = samples[i].littleEndian }
        try little.withUnsafeBufferPointer { try write(Data(buffer: $0)) }
        frames += count
    }

    func finish() throws {
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: WavWriter.header(sampleRate: sampleRate, dataBytes: frames * 2))
            try handle.synchronize()
            try handle.close()
            finished = true
        } catch {
            throw EngineError.from(error)
        }
    }
}
