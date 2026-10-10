import AVFoundation
import XCTest

@testable import VWSpikeHost

/// V-N21 / D-37: an `MTAudioProcessingTap` on a composition audio track sees composition-time
/// ranges after `scaleTimeRange`, and a gain of 2.0 measures +6.02 ± 0.1 dB, both through
/// `AVAssetReaderAudioMixOutput` (export) and in `AVPlayer` (preview).
final class AudioTapTests: XCTestCase {
  static let toneDbfs = -12.0
  /// RMS of a sine at peak −12 dBFS: −12 − 3.0103 dB.
  static let toneRmsDb = toneDbfs - 10 * log10(2)
  static let expectedGainDb = 20 * log10(2.0)  // 6.0206
  /// IOS-01 finding: the only time-pitch algorithm that renders scaled ranges completely and
  /// deterministically in AVAssetReaderAudioMixOutput; used for preview too so both paths match.
  static let pitchAlgorithm = AVAudioTimePitchAlgorithm.timeDomain

  private func tone() throws -> URL {
    try MediaFactory.tone(name: "tone_1k_m12.wav", hz: 1000, dbfs: Self.toneDbfs, seconds: 8)
  }

  /// Checks the ranges handed to the tap: contiguous, starting at 0, covering the 4 s composition
  /// (source times would jump to 3 s and 6 s and cover 4 s of source in other places).
  private func checkCompositionRanges(_ calls: [GainTapProbe.Call], total: Double) -> [String] {
    var problems: [String] = []
    guard let first = calls.first else { return ["tap never called"] }
    if abs(first.start.seconds) > 0.001 { problems.append("first range starts at \(first.start.seconds)") }
    var expectedStart = first.start
    for c in calls {
      guard c.start.isNumeric else {
        problems.append("non-numeric range")
        continue
      }
      if abs(CMTimeSubtract(c.start, expectedStart).seconds) > 0.0005 {
        problems.append(String(format: "gap/jump at %.4f (expected %.4f)", c.start.seconds, expectedStart.seconds))
      }
      // Advance by the frames actually provided: inside scaled segments the range *duration* the
      // tap reports is not composition time (finding; see the report), the start is.
      expectedStart = CMTimeAdd(c.start, CMTime(value: Int64(c.provided), timescale: 48_000))
      if c.start.seconds > total + 0.05 { problems.append("range beyond composition: \(c.start.seconds)") }
    }
    if abs(expectedStart.seconds - total) > 0.05 {
      problems.append(String(format: "ranges end at %.4f, composition is %.1f s", expectedStart.seconds, total))
    }
    return Array(problems.prefix(10))
  }

  func testTapInAssetReaderAudioMixOutput() async throws {
    let url = try tone()
    func run(gain: Float) async throws -> ([Float], GainTapProbe, AudioCompositionSpec.MixRead) {
      let probe = GainTapProbe(gain: gain)
      let (comp, mix) = try await AudioCompositionSpec.build(
        tone: url, segments: AudioCompositionSpec.standard, tap: probe.makeTap())
      // IOS-01 finding: only .timeDomain renders scaled ranges completely in the reader (see
      // testReaderScaledSegmentsDiagnostics); .spectral/.varispeed go silent after the first rate change.
      (mix.inputParameters.first as! AVMutableAudioMixInputParameters).audioTimePitchAlgorithm = Self.pitchAlgorithm
      let read = try AudioCompositionSpec.readMix(comp, mix: mix, algorithm: Self.pitchAlgorithm)
      return (read.left, probe, read)
    }
    let (unity, _, unityRead) = try await run(gain: 1)
    let (doubled, probe, doubledRead) = try await run(gain: 2)
    XCTAssertEqual(unityRead.status, .completed, "unity read: \(String(describing: unityRead.error))")
    XCTAssertEqual(doubledRead.status, .completed, "doubled read: \(String(describing: doubledRead.error))")
    // .timeDomain output is 3.97–4.10 s long for this 4.0 s composition (stretch latency and
    // overlap-add tail); the export pads/trims audio to the composition duration, so only gross
    // length errors count here.
    for n in [unity.count, doubled.count] {
      XCTAssertGreaterThanOrEqual(Double(n) / 48_000, 3.95)
      XCTAssertLessThanOrEqual(Double(n) / 48_000, 4.1)
    }

    // Level: the 1× segment [0.1, 0.9) s, and the 0.5×/2× segments too (NaN when the read
    // stopped early, which the status assertions above already report).
    func db(_ x: [Float], _ a: Double, _ b: Double) -> Double {
      AudioCompositionSpec.rmsDb(x, a, b) ?? .nan
    }
    var deltas: [String: Double] = [:]
    for (name, a, b) in [("1x", 0.1, 0.9), ("2x", 1.1, 1.9), ("0.5x", 2.1, 3.9)] {
      let d = db(doubled, a, b) - db(unity, a, b)
      deltas[name] = Stats.round2(d * 1000) / 1000
      XCTAssertEqual(d, Self.expectedGainDb, accuracy: 0.1, "\(name) segment gain \(d) dB")
    }
    let segLevels: [String: [Double]] = Dictionary(uniqueKeysWithValues: [("1x", 0.1, 0.9), ("2x", 1.1, 1.9), ("0.5x", 2.1, 3.9)].map {
      ($0.0, [Stats.round2(db(unity, $0.1, $0.2)), Stats.round2(db(doubled, $0.1, $0.2))])
    })
    let detail = probe.calls.filter { (0.95...1.12).contains($0.start.seconds) || (1.95...2.08).contains($0.start.seconds) }
      .map { c in
        "s=\(String(format: "%.5f", c.start.seconds)) d=\(String(format: "%.5f", c.duration.seconds)) req=\(c.requested) got=\(c.provided) f=\(c.flags)"
      }
    let absolute = db(doubled, 0.1, 0.9)
    XCTAssertEqual(absolute, Self.toneRmsDb + Self.expectedGainDb, accuracy: 0.1)
    let peak = doubled.map { abs($0) }.max() ?? 0
    let problems = checkCompositionRanges(probe.calls, total: 4)
    XCTAssertEqual(problems, [])
    let durationFieldOff = probe.calls.filter {
      $0.start.isNumeric && abs($0.duration.seconds - Double($0.provided) / 48_000) > 0.0005
    }.count
    Metrics.record(
      "V-N21.reader",
      [
        "gainDeltaDb": deltas, "absoluteRmsDb1x": Stats.round2(absolute),
        "expectedRmsDb": Stats.round2(Self.toneRmsDb + Self.expectedGainDb),
        "peakLinear": Stats.round2(Double(peak)), "tapCalls": probe.calls.count,
        "tapMaxFrames": probe.maxFrames, "tapSampleRate": probe.format.mSampleRate,
        "tapChannels": probe.format.mChannelsPerFrame,
        "tapFloat": probe.format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
        "tapNonInterleaved": probe.format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0,
        "firstRanges": probe.calls.prefix(3).map { [Stats.round2($0.start.seconds * 1000), Stats.round2($0.duration.seconds * 1000)] },
        "rangeProblems": problems, "segmentRmsDb[unity,doubled]": segLevels,
        "callsNearSeams": Array(detail.prefix(12)), "callsWithDurationNotProvidedFrames": durationFieldOff,
        "frames[unity,doubled]": [unity.count, doubled.count],
        "readerStatus[unity,doubled]": [unityRead.status.rawValue, doubledRead.status.rawValue],
        "readerError": doubledRead.error.map { "\($0)" } ?? unityRead.error.map { "\($0)" } ?? "",
      ])
  }

  /// Where do source-time markers land in the reader output? 40 ms silent gaps at source 0.5 s,
  /// 4.0 s and 6.5 s must appear at composition 0.5 s (1×), 1.5 s (2×, 20 ms long) and 3.0 s
  /// (0.5×, 80 ms long), within one 30 fps frame (time-stretch grains move them a little), in
  /// every one of 5 reads. Also checks the tap's range starts against the output sample position
  /// (the reported range *duration* is not composition time inside scaled segments).
  func testReaderSeamAlignment() async throws {
    let url = try MediaFactory.tone(
      name: "tone_1k_m12_gaps40.wav", hz: 1000, dbfs: Self.toneDbfs, seconds: 8, gaps: [0.5, 4.0, 6.5])
    var reps: [[String: Any]] = []
    var worstOffset = 0.0
    var worstStartErr = 0.0
    for rep in 0..<5 {
      let probe = GainTapProbe(gain: 1)
      let (comp, mix) = try await AudioCompositionSpec.build(
        tone: url, segments: AudioCompositionSpec.standard, tap: probe.makeTap())
      (mix.inputParameters.first as! AVMutableAudioMixInputParameters).audioTimePitchAlgorithm = Self.pitchAlgorithm
      let r = try AudioCompositionSpec.readMix(comp, mix: mix, algorithm: Self.pitchAlgorithm, timeout: 10)
      XCTAssertFalse(r.hung, "rep \(rep) hung")
      let nans = r.left.filter { $0.isNaN }.count
      XCTAssertEqual(nans, 0, "rep \(rep): NaN samples")
      // Centre of the quiet 1 ms windows within ±150 ms of each expected position.
      func gapCentre(near t: Double) -> (centre: Double, lengthMs: Double)? {
        var quiet: [Double] = []
        var x = t - 0.150
        while x < t + 0.150 {
          if let db = AudioCompositionSpec.rmsDb(r.left, x, x + 0.001), db < -40 { quiet.append(x + 0.0005) }
          x += 0.001
        }
        guard let a = quiet.min(), let b = quiet.max() else { return nil }
        return ((a + b) / 2, Double(quiet.count))
      }
      var markers: [String: Any] = [:]
      for (name, expectedCentre) in [("1x@0.5", 0.520), ("2x@1.5", 1.510), ("0.5x@3.0", 3.040)] {
        if let g = gapCentre(near: expectedCentre) {
          let off = (g.centre - expectedCentre) * 1000
          worstOffset = max(worstOffset, abs(off))
          XCTAssertLessThanOrEqual(abs(off), 1000.0 / 30, "rep \(rep) \(name) offset \(off) ms")
          markers[name] = ["offsetMs": Stats.round2(off), "quietMs": g.lengthMs]
        } else {
          markers[name] = "not found"
          XCTFail("rep \(rep): marker \(name) not found")
        }
      }
      // Tap starts vs. the output position: cumulative provided frames / 48 kHz.
      var position = 0.0
      var startErr = 0.0
      for c in probe.calls where c.start.isNumeric {
        startErr = max(startErr, abs(c.start.seconds - position) * 1000)
        position += Double(c.provided) / 48_000
      }
      worstStartErr = max(worstStartErr, startErr)
      XCTAssertLessThanOrEqual(startErr, 1.0, "rep \(rep): tap range start is not the output position")
      reps.append([
        "markers": markers, "tapStartVsOutputPositionMsMax": Stats.round2(startErr),
        "outputSeconds": Stats.round2(Double(r.left.count) / 48_000 * 1000) / 1000, "nanSamples": nans,
      ])
    }
    Metrics.record(
      "V-N21.readerSeams",
      [
        "algorithm": Self.pitchAlgorithm.rawValue, "reps": reps,
        "worstMarkerOffsetMs": Stats.round2(worstOffset), "worstTapStartErrMs": Stats.round2(worstStartErr),
      ])
  }

  /// AVPlayer preview: what the tap sees while the composition plays in real time (time ranges,
  /// flags) and the level it hands on: the input arrives at the source level (nothing attenuates
  /// before the tap) and leaves +6.02 dB louder. Run for post-effects and pre-effects taps.
  func testTapInAVPlayer() async throws {
    var results: [String: Any] = [:]
    for pre in [false, true] {
      let r = try await playThroughAVPlayer(preEffects: pre)
      results[pre ? "preEffects" : "postEffects"] = r
    }
    Metrics.record("V-N21.avplayer", results)
  }

  private func playThroughAVPlayer(preEffects: Bool) async throws -> [String: Any] {
    let url = try tone()
    let probe = GainTapProbe(gain: 2, preEffects: preEffects)
    let (comp, mix) = try await AudioCompositionSpec.build(
      tone: url, segments: AudioCompositionSpec.standard, tap: probe.makeTap())
    (mix.inputParameters.first as! AVMutableAudioMixInputParameters).audioTimePitchAlgorithm = Self.pitchAlgorithm
    let item = AVPlayerItem(asset: comp)
    item.audioMix = mix
    item.audioTimePitchAlgorithm = Self.pitchAlgorithm
    let player = AVPlayer(playerItem: item)
    player.automaticallyWaitsToMinimizeStalling = false
    player.volume = 0.05  // output volume is applied after the mix; keeps the test quiet
    let deadline = Date().addingTimeInterval(10)
    while item.status != .readyToPlay, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertEqual(item.status, .readyToPlay)
    let host0 = mach_absolute_time()
    player.play()
    var clock: [(host: UInt64, item: Double)] = []
    while CMTimeGetSeconds(item.currentTime()) < 3.0, Date() < deadline.addingTimeInterval(6) {
      clock.append((mach_absolute_time(), item.currentTime().seconds))
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    player.pause()
    let calls = probe.calls
    XCTAssertFalse(calls.isEmpty, "tap not called in AVPlayer")
    let valid = calls.filter { $0.start.isNumeric }
    // Level over the steady state (skip the first 5 calls of the ramp-up).
    let steady = calls.dropFirst(5).filter { $0.samples > 0 }
    let preSum = steady.reduce(0) { $0 + $1.preSumSq }
    let postSum = steady.reduce(0) { $0 + $1.postSumSq }
    let n = Double(steady.reduce(0) { $0 + $1.samples })
    let preDb = 10 * log10(preSum / max(n, 1))
    let postDb = 10 * log10(postSum / max(n, 1))
    XCTAssertEqual(postDb - preDb, Self.expectedGainDb, accuracy: 0.1)
    XCTAssertEqual(preDb, Self.toneRmsDb, accuracy: 0.5, "tap input is not at the source level")
    // How far ahead of the player clock the tap runs (frames counted from the first call).
    var info: [String: Any] = [
      "calls": calls.count, "validRanges": valid.count,
      "firstRanges": calls.prefix(4).map { "\($0.start.isNumeric ? String(format: "%.4f", $0.start.seconds) : "invalid")+\($0.duration.isNumeric ? String(format: "%.4f", $0.duration.seconds) : "invalid") req=\($0.requested) got=\($0.provided) f=\($0.flags)" },
      "flagsSeen": Array(Set(calls.map(\.flags))).sorted(),
      "gainDeltaDb": Stats.round2(postDb - preDb), "tapInputRmsDb": Stats.round2(preDb),
      "expectedInputRmsDb": Stats.round2(Self.toneRmsDb),
      "framesPerCall": calls.dropFirst(5).first?.requested ?? 0,
    ]
    if !valid.isEmpty {
      let starts = valid.map(\.start.seconds)
      info["maxStart"] = Stats.round2(starts.max() ?? 0)
      info["monotonic"] = zip(starts, starts.dropFirst()).allSatisfy { $1 >= $0 }
      info["callsIn2xSegment"] = valid.filter { $0.start.seconds >= 1 && $0.start.seconds < 2 }.count
    }
    // Tap lead over the player clock: samples processed by the tap vs item time at that host time.
    var timebase = mach_timebase_info()
    mach_timebase_info(&timebase)
    func secs(_ h: UInt64) -> Double { Double(h - host0) * Double(timebase.numer) / Double(timebase.denom) / 1e9 }
    var processed = 0.0
    var leads: [Double] = []
    for c in calls {
      processed += Double(c.provided) / 48_000
      if let near = clock.min(by: { abs(secs($0.host) - secs(c.hostTime)) < abs(secs($1.host) - secs(c.hostTime)) }),
        near.item > 0.3, near.item < 0.9
      {
        leads.append((processed - near.item) * 1000)
      }
    }
    info["tapLeadMsP50(1x segment)"] = Stats.round2(Stats.percentile(leads, 50))
    return info
  }

  /// Diagnostic (no assertion): is AVAssetReaderAudioMixOutput over scaled segments deterministic
  /// per time-pitch algorithm and source format? A read is "complete" when it has 4 s ± 50 ms of
  /// samples, no silent 100 ms window and did not hang; with a tap, its ranges must also be
  /// contiguous composition time. Counts per variant over `reps` reads.
  func testReaderScaledSegmentsDiagnostics() async throws {
    let wav = try tone()
    let aac = try MediaFactory.toneAAC(name: "tone_1k_m12.m4a", source: wav)
    let reps = 4
    var out: [String: Any] = [:]
    let gaps = try MediaFactory.tone(
      name: "tone_1k_m12_gaps40.wav", hz: 1000, dbfs: Self.toneDbfs, seconds: 8, gaps: [0.5, 4.0, 6.5])
    for (srcName, url) in [("wavFloat", wav), ("aac", aac), ("wavGaps", gaps)] {
      for algo in [AVAudioTimePitchAlgorithm.timeDomain, .spectral, .varispeed] {
        for withTap in [false, true] {
          var complete = 0
          var hung = 0
          var tapRangeProblems = 0
          var nanReads = 0
          var firstSilence: [Double] = []
          var frames: [Int] = []
          for rep in 0..<reps {
            let probe = GainTapProbe(gain: 1)
            let (comp, mix) = try await AudioCompositionSpec.build(
              tone: url, segments: AudioCompositionSpec.standard, tap: withTap ? probe.makeTap() : nil,
              keepPitch: algo != .varispeed)
            (mix.inputParameters.first as! AVMutableAudioMixInputParameters).audioTimePitchAlgorithm = algo
            let r = try AudioCompositionSpec.readMix(comp, mix: mix, algorithm: algo, timeout: 8)
            NSLog("VWSPIKE diag %@ %@ tap=%d rep=%d frames=%d hung=%d", srcName, algo.rawValue, withTap ? 1 : 0, rep, r.left.count, r.hung ? 1 : 0)
            if r.hung { hung += 1 }
            frames.append(r.left.count)
            var silentAt: Double?
            var t = 0.0
            while t + 0.1 <= 3.95 {
              let db = AudioCompositionSpec.rmsDb(r.left, t, t + 0.1) ?? -.infinity
              if db < -40 { silentAt = t; break }
              t += 0.1
            }
            let rangesOK = !withTap || checkCompositionRanges(probe.calls, total: 4).isEmpty
            if !rangesOK { tapRangeProblems += 1 }
            if let s = silentAt { firstSilence.append(Stats.round2(s)) }
            let nans = r.left.filter { $0.isNaN }.count
            if nans > 0 { nanReads += 1 }
            if !r.hung, rangesOK, nans == 0, silentAt == nil, abs(Double(r.left.count) / 48_000 - 4) < 0.05 { complete += 1 }
          }
          out["\(srcName).\(algo.rawValue).tap=\(withTap)"] = [
            "complete": complete, "of": reps, "hung": hung, "tapRangeProblems": tapRangeProblems,
            "readsWithNaN": nanReads,
            "firstSilentWindowAt": firstSilence, "frames": frames,
          ]
        }
      }
    }
    Metrics.record("V-N21.readerDiagnostics", out)
  }

  /// How reliable is the chosen configuration (.timeDomain + tap, AVAssetReaderAudioMixOutput)?
  /// 30 reads of the scaled 3-segment composition; a read is good when it is complete (no hang,
  /// no NaN, no silent 100 ms window, 4.0–4.1 s) with contiguous tap ranges. Failures are
  /// recorded with the tap's call statuses so IOS-12/IOS-18 know what to detect and retry.
  func testReaderTimeDomainTapReliability() async throws {
    let url = try tone()
    var good = 0
    var failures: [[String: Any]] = []
    var lengths: [Double] = []
    let reps = 30
    for rep in 0..<reps {
      let probe = GainTapProbe(gain: 1)
      let (comp, mix) = try await AudioCompositionSpec.build(
        tone: url, segments: AudioCompositionSpec.standard, tap: probe.makeTap())
      (mix.inputParameters.first as! AVMutableAudioMixInputParameters).audioTimePitchAlgorithm = Self.pitchAlgorithm
      let r = try AudioCompositionSpec.readMix(comp, mix: mix, algorithm: Self.pitchAlgorithm, timeout: 10)
      let nans = r.left.filter { $0.isNaN }.count
      var silentAt: Double?
      var t = 0.0
      while t + 0.1 <= 3.95 {
        if (AudioCompositionSpec.rmsDb(r.left, t, t + 0.1) ?? -.infinity) < -40 { silentAt = t; break }
        t += 0.1
      }
      let seconds = Double(r.left.count) / 48_000
      let ranges = checkCompositionRanges(probe.calls, total: 4)
      lengths.append(seconds)
      // Length varies 3.97–4.10 s for the 4.0 s composition (time-stretch latency/tail); the
      // export pads or trims the audio to the composition duration, so only gross errors count.
      if !r.hung, nans == 0, silentAt == nil, seconds >= 3.95, seconds <= 4.1, ranges.isEmpty {
        good += 1
      } else {
        failures.append([
          "rep": rep, "hung": r.hung, "nan": nans, "silentAt": silentAt ?? -1, "seconds": Stats.round2(seconds),
          "tapCalls": probe.calls.count, "tapStatuses": Array(Set(probe.calls.map { Int($0.status) })).sorted(),
          "tapPrepared": probe.maxFrames > 0, "rangeProblems": Array(ranges.prefix(3)),
          "readerStatus": r.status.rawValue, "readerError": r.error.map { "\($0)" } ?? "",
        ])
      }
    }
    Metrics.record(
      "V-N21.readerReliability",
      [
        "good": good, "of": reps, "failures": failures,
        "secondsMin": Stats.round2((lengths.min() ?? 0) * 1000) / 1000,
        "secondsMax": Stats.round2((lengths.max() ?? 0) * 1000) / 1000,
      ])
    // Spike gate: the configuration must be good in at least 90% of reads; IOS-12 must still
    // detect a bad read (silent/NaN output while the plan has audible audio) and redo it.
    XCTAssertGreaterThanOrEqual(good, reps * 9 / 10, "\(failures)")
  }

  /// The pre-D-37 path: does AVAudioMix volume above 1 amplify in AVAssetReaderAudioMixOutput?
  func testMixVolumeAboveOneIsNotApplied() async throws {
    let url = try tone()
    let (comp, mix) = try await AudioCompositionSpec.build(
      tone: url, segments: [AudioCompositionSpec.standard[0]], tap: nil)
    let unity = try AudioCompositionSpec.readMix(comp, mix: mix).left
    let params = mix.inputParameters.first as! AVMutableAudioMixInputParameters
    params.setVolume(2, at: .zero)
    let loud = try AudioCompositionSpec.readMix(comp, mix: mix).left
    let d =
      (AudioCompositionSpec.rmsDb(loud, 0.1, 0.9) ?? .nan) - (AudioCompositionSpec.rmsDb(unity, 0.1, 0.9) ?? .nan)
    // Fact finding (no assertion on the direction): D-37 assumed volume > 1 is not applied.
    Metrics.record("D-37.mixVolume2", ["deltaDb": Stats.round2(d), "amplifies": d > 1])
  }
}
