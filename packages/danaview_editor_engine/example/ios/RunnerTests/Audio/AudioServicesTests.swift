// OWNER: IOS-04
//
// PCM reader, waveforms and speech audio extraction (BUILD_PLAN IOS-04):
// - peaks match reference peaks computed independently from the WAV fixtures' raw PCM;
// - waveform throughput (>= 20× realtime asserted on the simulator; the low-tier device figure is
//   deferred: no device available, recorded by QA-04);
// - speech WAV header valid, exactly 16 kHz mono s16, duration = range ± 1 ms;
// - clap_flash_av clicks within ± 20 ms (AAC priming / edit list, V-A6), also from a range that
//   starts mid-file;
// - 5.1: the centre tone is kept (0.5 · C);
// - throughput >= 60× realtime (simulator, as the mid-tier proxy);
// - cancel deletes partial output; unsupported containers and missing audio -> unsupportedMedia.

import XCTest

@testable import danaview_editor_engine

enum AudioTestSupport {
    /// Mono-mixed (0.5/0.5 for stereo) Float samples and rate of a PCM s16le WAV, parsed by hand.
    static func wavMono(_ url: URL) throws -> (samples: [Float], rate: Int, channels: Int) {
        let data = try Data(contentsOf: url)
        let bytes = [UInt8](data)
        func u32(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24 }
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        XCTAssertEqual(String(bytes: bytes[0..<4], encoding: .ascii), "RIFF")
        var offset = 12
        var channels = 1, rate = 0, bits = 16
        var pcm: ArraySlice<UInt8> = []
        while offset + 8 <= bytes.count {
            let id = String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii)
            let size = u32(offset + 4)
            if id == "fmt " {
                channels = u16(offset + 10)
                rate = u32(offset + 12)
                bits = u16(offset + 22)
            } else if id == "data" {
                pcm = bytes[(offset + 8)..<min(bytes.count, offset + 8 + size)]
            }
            offset += 8 + size + (size & 1)
        }
        XCTAssertEqual(bits, 16)
        let values = stride(from: pcm.startIndex, to: pcm.endIndex - 1, by: 2).map {
            Float(Int16(bitPattern: UInt16(pcm[$0]) | UInt16(pcm[$0 + 1]) << 8)) / 32768
        }
        if channels == 1 { return (values, rate, 1) }
        var mono = [Float](repeating: 0, count: values.count / channels)
        for i in 0..<mono.count {
            var sum: Float = 0
            for c in 0..<channels { sum += values[i * channels + c] }
            mono[i] = sum / Float(channels)
        }
        return (mono, rate, channels)
    }

    /// Reference peaks with the documented binning (independent of WaveformService).
    static func referencePeaks(_ mono: [Float], rate: Int) -> [Int8] {
        var out: [Int8] = []
        var bin = 0
        while true {
            let start = bin * rate / 200
            let end = min(mono.count, (bin + 1) * rate / 200)
            guard start < mono.count else { break }
            let slice = mono[start..<end]
            func q(_ v: Float) -> Int8 { Int8(max(-127, min(127, (v * 127).rounded()))) }
            out.append(q(slice.min()!))
            out.append(q(slice.max()!))
            bin += 1
        }
        return out
    }

    struct Wav {
        var format: Int
        var channels: Int
        var rate: Int
        var bits: Int
        var samples: [Int16]
        var riffSizeOK: Bool
    }

    static func parseWav(_ url: URL) throws -> Wav {
        let bytes = [UInt8](try Data(contentsOf: url))
        func u32(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24 }
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        XCTAssertEqual(String(bytes: bytes[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(bytes: bytes[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(bytes: bytes[12..<16], encoding: .ascii), "fmt ")
        XCTAssertEqual(u32(16), 16)
        XCTAssertEqual(String(bytes: bytes[36..<40], encoding: .ascii), "data", "data follows fmt directly")
        let dataSize = u32(40)
        XCTAssertEqual(dataSize, bytes.count - 44)
        let samples = stride(from: 44, to: 44 + dataSize, by: 2).map {
            Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)
        }
        return Wav(format: u16(20), channels: u16(22), rate: u32(24), bits: u16(34), samples: samples,
                   riffSizeOK: u32(4) == bytes.count - 8)
    }

    /// Onset times (s) of bursts above [threshold] separated by at least [gap] seconds.
    static func onsets(_ samples: [Int16], rate: Int, threshold: Int16 = 3000, gap: Double = 0.3) -> [Double] {
        var result: [Double] = []
        var last = -Double.infinity
        for (i, s) in samples.enumerated() where abs(Int(s)) >= Int(threshold) {
            let t = Double(i) / Double(rate)
            if t - last >= gap { result.append(t) }
            last = t
        }
        return result
    }

    static func peakDbfs(_ samples: [Int16]) -> Double {
        let peak = samples.map { abs(Int($0)) }.max() ?? 0
        return 20 * log10(Double(max(1, peak)) / 32768)
    }

    /// Frequency from zero crossings.
    static func zeroCrossingHz(_ samples: [Int16], rate: Int) -> Double {
        var crossings = 0
        for i in 1..<samples.count where (samples[i - 1] < 0) != (samples[i] < 0) { crossings += 1 }
        return Double(crossings) / 2 / (Double(samples.count) / Double(rate))
    }

    static func tempWav(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("danaview-speech-\(name)-\(UUID().uuidString).wav")
    }
}

final class WaveformTests: XCTestCase {
    func testPeaksMatchReferenceMono() throws {
        let url = try ProbeFixtures.url("tone_1khz.wav")
        let reference = try AudioTestSupport.wavMono(url)
        let expected = AudioTestSupport.referencePeaks(reference.samples, rate: reference.rate)
        let peaks = try WaveformService.compute(url: url)
        XCTAssertEqual(peaks.sampleRate, 48_000)
        XCTAssertEqual(peaks.channels, 1)
        XCTAssertEqual(peaks.pairCount, 2000, "10 s at 200 pairs/s")
        XCTAssertEqual(peaks.durationUs, 10_000_000)
        let got = [Int8](peaks.minMax.map { Int8(bitPattern: $0) })
        XCTAssertEqual(got.count, expected.count)
        let worst = zip(got, expected).map { abs(Int($0) - Int($1)) }.max() ?? 99
        XCTAssertLessThanOrEqual(worst, 1, "peaks within 1 LSB of the reference")
        // -12 dBFS tone: about ±32 of ±127.
        XCTAssertEqual(Double(got.max()!), 0.251 * 127, accuracy: 2)
    }

    func testPeaksMatchReferenceStereo() throws {
        let url = try ProbeFixtures.url("stereo_440l_880r.wav")
        let reference = try AudioTestSupport.wavMono(url)
        XCTAssertEqual(reference.channels, 2)
        let expected = AudioTestSupport.referencePeaks(reference.samples, rate: reference.rate)
        let peaks = try WaveformService.compute(url: url)
        let got = [Int8](peaks.minMax.map { Int8(bitPattern: $0) })
        XCTAssertEqual(got.count, expected.count)
        let worst = zip(got, expected).map { abs(Int($0) - Int($1)) }.max() ?? 99
        XCTAssertLessThanOrEqual(worst, 1)
    }

    func testCachedFileFormatAndThroughput() throws {
        let roots = try TempRoots()
        defer { roots.remove() }
        let paths = try Paths(cacheRoot: roots.cache.path, supportRoot: roots.support.path)
        let store = DiskCache.stores(for: paths).waves
        let url = try ProbeFixtures.url("speech_10s.m4a")
        let started = Date()
        let first = try WaveformService.peaks(url: url, fingerprint: "speech10", store: store)
        let elapsed = Date().timeIntervalSince(started)
        let speed = 10 / elapsed
        print("IOS-04 waveform throughput on the simulator: \(Int(speed))x realtime")
        XCTAssertGreaterThanOrEqual(speed, 20)
        XCTAssertEqual(first.pairsPerSecond, 200)
        XCTAssertEqual(Double(first.durationUs) / 1_000_000, 10, accuracy: 0.05)
        let file = try XCTUnwrap(store.lookup(key: WaveformService.cacheKey(fingerprint: "speech10", audioStream: 0), ext: "dvpk"))
        let data = try Data(contentsOf: file)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "DVPK")
        let decoded = try XCTUnwrap(WaveformService.decode(data))
        XCTAssertEqual(decoded.sampleRate, 44_100)
        XCTAssertEqual(decoded.minMax, first.minMax.data)
        let hit = try WaveformService.peaks(url: URL(fileURLWithPath: "/nonexistent"), fingerprint: "speech10", store: store)
        XCTAssertEqual(hit, first, "second call is served from waves/")
    }

    func testCancelAndUnsupported() throws {
        let cancellation = MediaCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(try WaveformService.compute(url: try ProbeFixtures.url("tone_440hz.wav"), cancellation: cancellation)) {
            XCTAssertEqual(EngineError.from($0).code, .cancelled)
        }
        XCTAssertThrowsError(try WaveformService.compute(url: try ProbeFixtures.url("sample_h264_aac.mkv"))) {
            XCTAssertEqual(EngineError.from($0).code, .unsupportedMedia)
        }
        XCTAssertThrowsError(try WaveformService.compute(url: try ProbeFixtures.url("frame_counter_720p25.mp4"))) {
            XCTAssertEqual(EngineError.from($0).code, .unsupportedMedia, "no audio track")
        }
    }
}

final class SpeechAudioTests: XCTestCase {
    func testWavFormatAndExactDuration() throws {
        let output = AudioTestSupport.tempWav("range")
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try SpeechAudioExtractor.extract(
            url: try ProbeFixtures.url("tone_440hz.wav"), startUs: 1_000_000, endUs: 3_500_000, output: output)
        let wav = try AudioTestSupport.parseWav(output)
        XCTAssertEqual(wav.format, 1)
        XCTAssertEqual(wav.channels, 1)
        XCTAssertEqual(wav.rate, 16_000)
        XCTAssertEqual(wav.bits, 16)
        XCTAssertTrue(wav.riffSizeOK)
        XCTAssertEqual(wav.samples.count, 40_000)
        XCTAssertEqual(result.frames, 40_000)
        XCTAssertEqual(Double(result.durationUs), 2_500_000, accuracy: 1000)
        XCTAssertEqual(result.sourceChannels, 1)
        XCTAssertEqual(result.sourceSampleRate, 48_000)
        XCTAssertEqual(result.codec, "pcm_s16le")
        XCTAssertEqual(result.path, output.path)
        XCTAssertEqual(AudioTestSupport.zeroCrossingHz(Array(wav.samples[1000..<39000]), rate: 16_000), 440, accuracy: 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path + ".part"))
    }

    func testClapClicksWithin20ms() throws {
        let url = try ProbeFixtures.url("clap_flash_av.mp4")
        let whole = AudioTestSupport.tempWav("clap")
        defer { try? FileManager.default.removeItem(at: whole) }
        _ = try SpeechAudioExtractor.extract(url: url, startUs: 0, endUs: 6_000_000, output: whole)
        let wav = try AudioTestSupport.parseWav(whole)
        XCTAssertEqual(wav.samples.count, 96_000)
        let clicks = AudioTestSupport.onsets(wav.samples, rate: 16_000)
        XCTAssertEqual(clicks.count, 3, "clicks \(clicks)")
        for (found, expected) in zip(clicks, [1.0, 2.5, 4.0]) {
            XCTAssertEqual(found, expected, accuracy: 0.02, "click at \(found) s, expected \(expected) s")
        }
        print("IOS-04 clap onsets \(clicks.map { String(format: "%.4f", $0) })")

        // Sample 0 is range.start: a range from 2.0 s puts the 2.5 s click at 0.5 s.
        let part = AudioTestSupport.tempWav("clap-part")
        defer { try? FileManager.default.removeItem(at: part) }
        _ = try SpeechAudioExtractor.extract(url: url, startUs: 2_000_000, endUs: 4_500_000, output: part)
        let partClicks = AudioTestSupport.onsets(try AudioTestSupport.parseWav(part).samples, rate: 16_000)
        XCTAssertEqual(partClicks.count, 2)
        XCTAssertEqual(partClicks.first ?? 0, 0.5, accuracy: 0.02)
        XCTAssertEqual(partClicks.last ?? 0, 2.0, accuracy: 0.02)
    }

    func testSurroundKeepsCentre() throws {
        let output = AudioTestSupport.tempWav("surround")
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try SpeechAudioExtractor.extract(
            url: try ProbeFixtures.url("surround_5_1.m4a"), startUs: 0, endUs: 5_000_000, output: output)
        XCTAssertEqual(result.sourceChannels, 6)
        let samples = try AudioTestSupport.parseWav(output).samples
        let middle = Array(samples[8000..<72000])
        // -12 dBFS centre tone × 0.5 = about -18 dBFS.
        XCTAssertEqual(AudioTestSupport.peakDbfs(middle), -18, accuracy: 1.5)
        XCTAssertEqual(AudioTestSupport.zeroCrossingHz(middle, rate: 16_000), 500, accuracy: 3)
    }

    func testThroughputAtLeast60xRealtime() throws {
        let url = try ProbeFixtures.url("speech_10s.m4a")
        var best = TimeInterval.greatestFiniteMagnitude
        for i in 0..<3 {
            let output = AudioTestSupport.tempWav("speed\(i)")
            let started = Date()
            let result = try SpeechAudioExtractor.extract(url: url, startUs: 0, endUs: 10_000_000, output: output)
            best = min(best, Date().timeIntervalSince(started))
            XCTAssertEqual(result.frames, 160_000)
            XCTAssertEqual(result.sourceSampleRate, 44_100)
            XCTAssertEqual(result.codec, "aac")
            try? FileManager.default.removeItem(at: output)
        }
        let speed = 10 / best
        print("IOS-04 speech audio throughput on the simulator: \(Int(speed))x realtime")
        XCTAssertGreaterThanOrEqual(speed, 60)
    }

    func testCancelDeletesPartialOutput() throws {
        let output = AudioTestSupport.tempWav("cancel")
        let cancellation = MediaCancellation()
        XCTAssertThrowsError(try SpeechAudioExtractor.extract(
            url: try ProbeFixtures.url("tone_1khz.wav"), startUs: 0, endUs: 10_000_000, output: output,
            cancellation: cancellation, progress: { if $0 > 0.2 { cancellation.cancel() } })) {
            XCTAssertEqual(EngineError.from($0).code, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path + ".part"))
    }

    func testUnsupportedMedia() throws {
        for name in ["sample_vp9_opus.webm", "sample_h264_aac.mkv", "frame_counter_720p25.mp4"] {
            let output = AudioTestSupport.tempWav("bad")
            XCTAssertThrowsError(try SpeechAudioExtractor.extract(
                url: try ProbeFixtures.url(name), startUs: 0, endUs: 1_000_000, output: output)) {
                XCTAssertEqual(EngineError.from($0).code, .unsupportedMedia, name)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path + ".part"))
        }
    }

    func testDownmixCoefficients() {
        XCTAssertEqual(Downmix.coefficients(channels: 1, labels: []), [1])
        XCTAssertEqual(Downmix.coefficients(channels: 2, labels: []), [0.5, 0.5])
        let layout = PcmReader.layout(channels: 6)
        XCTAssertEqual(Downmix.coefficients(channels: 6, labels: layout.labels), [0.25, 0.25, 0.5, 0, 0.125, 0.125])
        XCTAssertEqual(Downmix.mono([1, 0, 0, 1, 1, 1], channels: 2, coefficients: [0.5, 0.5]), [0.5, 0.5, 1])
    }
}
