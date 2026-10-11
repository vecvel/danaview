// OWNER: IOS-18
//
// GainTap in AVPlayer (preview; BUILD_PLAN IOS-18, D-37, V-N21). AVPlayer output cannot be captured
// offline (AVAudioEngine manual rendering cannot host an AVPlayerItem), so the tap's own meter
// measures what it hands to the player's render chain: the tap input arrives at the source level and
// leaves +6.02 ± 0.1 dB louder at 200%, compared with a 100% run. A live envelope swap reaches the
// running tap without rebuilding the item. The player plays at volume 0.05 (applied after the mix).

import AVFoundation
import XCTest

@testable import vwish_editor_engine

final class GainTapPlayerTests: XCTestCase {
    private func toneFixture() throws -> URL {
        try XCTUnwrap(TestFixtures.url(.engine, "media/tone_1khz.wav"), "ENG-05 tone_1khz.wav missing")
    }

    /// Plays [seconds] of tone_1khz (1× then 2× segments) through a GainTap; [during] runs at about
    /// 0.6 s of item time. Returns the meter.
    @MainActor
    private func play(
        envelope: TapEnvelope, seconds: Double, during: ((GainTap, GainTapMeter) -> Void)? = nil
    ) async throws -> (GainTap, GainTapMeter) {
        let tone = try toneFixture()
        let meter = GainTapMeter()
        meter.accumulating = false
        let tap = GainTap(envelope: envelope, meter: meter)
        let (comp, mix, assets) = try await AudioTapSupport.build(
            tracks: [[
                .init(source: tone, t0: 0, t1: 1_000_000, s0: 0, s1: 1_000_000),
                .init(source: tone, t0: 1_000_000, t1: 2_000_000, s0: 3_000_000, s1: 5_000_000),
            ]],
            taps: [tap])
        let item = AVPlayerItem(asset: comp)
        item.audioMix = mix
        item.audioTimePitchAlgorithm = .timeDomain
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        player.volume = 0.05
        let deadline = Date().addingTimeInterval(10)
        while item.status != .readyToPlay, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(item.status, .readyToPlay)
        player.play()
        var ranDuring = false
        var measuring = false
        // Skip the first 150 ms of ramp-up before measuring.
        while item.currentTime().seconds < seconds, Date() < deadline.addingTimeInterval(seconds + 5) {
            let t = item.currentTime().seconds
            if t > 0.15, !measuring {
                measuring = true
                meter.resetLevels()
                meter.accumulating = true
            }
            if t > 0.6, !ranDuring {
                ranDuring = true
                during?(tap, meter)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        player.pause()
        withExtendedLifetime((assets, item, player)) {}
        XCTAssertFalse(meter.calls.isEmpty, "tap not called in AVPlayer")
        return (tap, meter)
    }

    @MainActor
    func testBoost200PctMeasuresPlus6dBInAVPlayer() async throws {
        let (_, unity) = try await play(envelope: TapEnvelope(planGain: [[0, 1]]), seconds: 1.8)
        let (_, boost) = try await play(envelope: TapEnvelope(planGain: [[0, 2]]), seconds: 1.8)
        let u = unity.levels
        let b = boost.levels
        XCTAssertGreaterThan(u.samples, 48_000)
        XCTAssertGreaterThan(b.samples, 48_000)
        // The tap input is the source level (−15.01 dBFS RMS): nothing attenuates before the tap.
        XCTAssertEqual(u.preDb, -15.01, accuracy: 0.5)
        XCTAssertEqual(b.preDb, -15.01, accuracy: 0.5)
        XCTAssertEqual(u.postDb - u.preDb, 0, accuracy: 0.01)
        XCTAssertEqual(b.postDb - b.preDb, 6.0206, accuracy: 0.1)
        XCTAssertEqual(b.postDb - u.postDb, 6.0206, accuracy: 0.1)
        // Composition-time ranges arrive (V-N21); an invalid first range is tolerated.
        XCTAssertTrue(boost.calls.contains { ($0.startUs ?? -1) >= 1_000_000 }, "no call inside the 2× segment")
        XCTAssertTrue(boost.failures.isEmpty, "GetSourceAudio failed: \(boost.failures)")
    }

    /// A gain-only patch while playing: the envelope swaps under the running item (no new item or
    /// tap) and the tap's output follows: +6.02 dB once the 40 ms blend is done. The tap runs
    /// 150–280 ms ahead of the item clock, so the swap is heard with that delay in preview.
    @MainActor
    func testLiveEnvelopeSwapReachesRunningTap() async throws {
        var callsAtSwap = 0
        let (tap, meter) = try await play(envelope: TapEnvelope(planGain: [[0, 1]]), seconds: 1.6) { tap, meter in
            meter.accumulating = false
            callsAtSwap = meter.calls.count
            tap.swapEnvelope(TapEnvelope(planGain: [[0, 2]]))
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                meter.resetLevels()
                meter.accumulating = true
            }
        }
        XCTAssertGreaterThan(callsAtSwap, 0)
        XCTAssertGreaterThan(meter.calls.count - callsAtSwap, 5, "tap stopped after the swap")
        XCTAssertEqual(tap.envelope.gains, [2])
        let l = meter.levels
        XCTAssertGreaterThan(l.samples, 4_800)
        XCTAssertEqual(l.postDb - l.preDb, 6.0206, accuracy: 0.1)
        XCTAssertTrue(meter.failures.isEmpty)
    }
}
