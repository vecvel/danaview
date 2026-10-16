// OWNER: QA-04
//
// Support of the editor UI performance suite (BUILD_PLAN QA-04, ARCH §18.2 rows owned by the UI):
// budgets per tier, the `QA04|row|…` report lines (also handed to the integration_test binding's
// `reportData`, which `perf_driver.dart` writes to build/qa04/), percentiles, a frame-timing
// recorder (FrameTiming build and raster times, the numbers TimelineSummary reports), the Dart heap
// reader (VM service, after a GC) and deterministic project builders (200 and 1,000 items, 40
// projects, 3,000 cues).
//
// Budgets are enforced only in a profile build on a real device with
// --dart-define=QA04_ENFORCE=true; elsewhere (flutter-tester, debug builds, simulators) the rows
// are measured and printed, never failed, because those numbers are not device numbers. The tier
// is --dart-define=QA04_TIER=minimal|low|mid|high (default mid; the engine suite reads it from the
// device's capabilities).

import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:danaview_editor/src/debug/debug.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show DeviceTier;
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
// vm_service comes with integration_test (UX-01 owns the pubspec; reading the heap needs no new
// dependency).
// ignore: depend_on_referenced_packages
import 'package:vm_service/vm_service_io.dart' as vm_io;

// =================================================================================================
// Tier, enforcement, report
// =================================================================================================

const bool _enforceDefine = bool.fromEnvironment('QA04_ENFORCE');
const String _tierDefine = String.fromEnvironment('QA04_TIER', defaultValue: 'mid');

/// Whether this is an iOS simulator (performance there is meaningless, ARCH §21).
bool get isIosSimulator =>
    Platform.isIOS && (Platform.environment.containsKey('SIMULATOR_DEVICE_NAME') || Directory.systemTemp.path.contains('/CoreSimulator/'));

/// Whether this is a host run (flutter-tester) rather than a phone.
bool get isHostRun => !(Platform.isIOS || Platform.isAndroid);

/// Whether budgets fail the test: profile build on a real device with QA04_ENFORCE.
bool get enforceBudgets => _enforceDefine && kProfileMode && !isHostRun && !isIosSimulator;

/// The tier budgets are read for.
DeviceTier get perfTier => DeviceTier.values.firstWhere((t) => t.name == _tierDefine, orElse: () => DeviceTier.mid);

/// Where the run happened, for every report line.
String get runKind => isHostRun ? 'host' : (isIosSimulator ? 'simulator' : (kProfileMode ? 'device-profile' : 'device-debug'));

/// Every line printed in this run (also sent to the driver through `reportData`).
final List<String> qa04Lines = [];

/// Prints one `QA04|row|k=v|…` line and keeps it for the driver.
void qa04(String row, Map<String, Object?> values) {
  final line = 'QA04|$row|${values.entries.map((e) => '${e.key}=${e.value}').join('|')}';
  qa04Lines.add(line);
  debugPrint(line);
  final binding = IntegrationTestWidgetsFlutterBinding.instance;
  binding.reportData = {...?binding.reportData, 'qa04': List<String>.of(qa04Lines)};
}

/// A budget row of ARCH §18.2 (`null` = no budget on that tier; the minimal tier has only the
/// D-40 promise).
final class Budget {
  /// Creates a row.
  const Budget(this.row, {this.minimal, this.low, this.mid, this.high, this.higherIsBetter = false, required this.unit});

  /// Row id.
  final String row;

  /// Limits per tier.
  final num? minimal, low, mid, high;

  /// Whether larger values are better (export speed).
  final bool higherIsBetter;

  /// Unit of the value.
  final String unit;

  /// The limit for [tier] (high falls back to mid: §18.2 has low and mid columns).
  num? limitFor(DeviceTier tier) => switch (tier) {
        DeviceTier.minimal => minimal,
        DeviceTier.low => low,
        DeviceTier.mid => mid,
        DeviceTier.high => high ?? mid,
      };

  /// Whether [value] passes on [tier] (true when there is no budget).
  bool passes(DeviceTier tier, num value) {
    final limit = limitFor(tier);
    return limit == null || (higherIsBetter ? value >= limit : value <= limit);
  }

  /// Records [value]; fails the test when [enforceBudgets] and over budget.
  bool check(num value, [Map<String, Object?> extra = const {}, DeviceTier? tier]) {
    final t = tier ?? perfTier;
    final limit = limitFor(t);
    final pass = passes(t, value);
    qa04(row, {
      'tier': t.name,
      'value': value is double ? value.toStringAsFixed(3) : value,
      'unit': unit,
      'budget': limit == null ? 'none' : '${higherIsBetter ? '>=' : '<='}$limit',
      'pass': limit == null ? 'n/a' : pass,
      'enforced': enforceBudgets,
      'run': runKind,
      ...extra,
    });
    if (enforceBudgets && limit != null) {
      expect(pass, isTrue, reason: '$row: $value $unit vs ${higherIsBetter ? '>=' : '<='} $limit on ${t.name}');
    }
    return pass;
  }
}

/// ARCH §18.2 rows owned by QA-04 on the UI side (V-D7 for the sprite pre-pass).
abstract final class UiBudgets {
  /// Editor open → first preview frame, 200 items (Dart half; the native half is
  /// `preview.firstFrame200` of perf_engine_test.dart).
  static const editorOpen = Budget('ui.editorOpen200', low: 2500, mid: 1500, unit: 'ms');

  /// Projects screen first paint with 40 projects.
  static const projectsFirstPaint = Budget('ui.projectsFirstPaint40', low: 400, mid: 250, unit: 'ms');

  /// Timeline fling/pinch UI thread per frame, p90 and p99.
  static const timelineUiP90 = Budget('ui.timeline.uiP90', low: 8, mid: 5, unit: 'ms');
  static const timelineUiP99 = Budget('ui.timeline.uiP99', low: 14, mid: 10, unit: 'ms');

  /// Timeline raster per frame (p90).
  static const timelineRasterP90 = Budget('ui.timeline.rasterP90', low: 10, mid: 7, unit: 'ms');

  /// Playback with centre-follow: UI per frame (p90).
  static const playbackUi = Budget('ui.playback.uiP90', low: 3, mid: 3, unit: 'ms');

  /// Playback with centre-follow: widget rebuilds outside `TimecodeText`.
  static const playbackRebuilds = Budget('ui.playback.rebuilds', minimal: 0, low: 0, mid: 0, unit: 'rebuilds');

  /// Commit → patch handed to the engine (UI half of "commit → preview", property / structural).
  static const commitProperty = Budget('ui.commit.property', low: 150, mid: 80, unit: 'ms p90');
  static const commitStructural = Budget('ui.commit.structural', low: 400, mid: 250, unit: 'ms p90');

  /// Scrub: drag move → scrub seek issued (UI half of the scrub-lag row).
  static const scrubIssue = Budget('ui.scrub.issue', low: 200, mid: 120, unit: 'ms p90');

  /// Dart heap with 1,000 items open.
  static const heap1000 = Budget('ui.heap1000', low: 180, mid: 150, unit: 'MB');

  /// Autosave block on the main isolate.
  static const autosaveBlock = Budget('ui.autosaveBlock1000', low: 2, mid: 1, unit: 'ms p90');

  /// V-D7: sprite pre-pass with 3,000 cues, first export (mid tier ≤ 15 s; no other tier budget).
  static const spritePrepass = Budget('ui.spritePrepass3000', mid: 15000, high: 15000, unit: 'ms');
}

/// The [p]-th percentile (0–100, nearest rank) of [xs]; NaN when empty.
num percentile(List<num> xs, double p) {
  if (xs.isEmpty) return double.nan;
  final s = [...xs]..sort();
  final rank = ((p / 100) * s.length).ceil().clamp(1, s.length);
  return s[rank - 1];
}

// =================================================================================================
// Frame timing
// =================================================================================================

/// Records engine `FrameTiming`s (UI build+layout+paint and raster per frame, the source of
/// TimelineSummary's build/raster numbers) and, as a host fallback where the engine reports no
/// timings, the wall time of each pump.
final class FrameRecorder {
  final List<FrameTiming> _timings = [];
  final List<num> pumpMs = [];
  bool _on = false;

  void _onTimings(List<FrameTiming> t) {
    if (_on) _timings.addAll(t);
  }

  /// Starts recording.
  void start() {
    _on = true;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  /// Stops recording after the engine flushed its pending timings (reported in batches).
  Future<void> stop(WidgetTester tester) async {
    if (!isHostRun) {
      // Timings arrive at most every 100 ms (profile) / 1 s (debug); give the batch time to land.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1200)));
    }
    _on = false;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
  }

  /// Pumps one frame of [step] and records its wall time.
  Future<void> pump(WidgetTester tester, [Duration step = const Duration(milliseconds: 16)]) async {
    final sw = Stopwatch()..start();
    await tester.pump(step);
    pumpMs.add(sw.elapsedMicroseconds / 1000);
  }

  /// UI-thread times (ms): FrameTiming build durations, else pump wall times.
  List<num> get uiMs => _timings.isNotEmpty ? [for (final t in _timings) t.buildDuration.inMicroseconds / 1000] : pumpMs;

  /// Raster times (ms), empty without engine timings.
  List<num> get rasterMs => [for (final t in _timings) t.rasterDuration.inMicroseconds / 1000];

  /// Whether the numbers are engine FrameTimings.
  bool get fromEngine => _timings.isNotEmpty;

  /// Report fields.
  Map<String, Object?> summary() => {
        'frames': fromEngine ? _timings.length : pumpMs.length,
        'source': fromEngine ? 'FrameTiming' : 'pumpWall',
        'uiP50': percentile(uiMs, 50).toStringAsFixed(2),
        'uiMax': percentile(uiMs, 100).toStringAsFixed(2),
        if (fromEngine) 'rasterP50': percentile(rasterMs, 50).toStringAsFixed(2),
      };
}

// =================================================================================================
// Dart heap
// =================================================================================================

/// The isolate's Dart heap (used + external, MB) after a full GC, from the VM service; null when
/// the service is not reachable (release builds).
Future<({double heapMb, double externalMb})?> dartHeapAfterGc() async {
  try {
    final info = await developer.Service.getInfo();
    final uri = info.serverWebSocketUri;
    final id = developer.Service.getIsolateId(Isolate.current);
    if (uri == null || id == null) return null;
    final service = await vm_io.vmServiceConnectUri(uri.toString());
    try {
      await service.getAllocationProfile(id, gc: true);
      final m = await service.getMemoryUsage(id);
      return (heapMb: (m.heapUsage ?? 0) / (1024 * 1024), externalMb: (m.externalUsage ?? 0) / (1024 * 1024));
    } finally {
      await service.dispose();
    }
  } on Object {
    return null;
  }
}

/// Process RSS in MB (fallback figure when the VM service is unavailable).
double rssMb() => ProcessInfo.currentRss / (1024 * 1024);

// =================================================================================================
// Projects
// =================================================================================================

const FrameRate _rate = FrameRate.fps30;
final DateTime _when = DateTime.utc(2026, 10, 16, 12);

TimeUs _at(int frame) => _rate.timeOfFrame(frame);

MediaAsset _asset(String id, MediaKind kind, {TimeUs duration = 0, int? w, int? h, bool hasAudio = false}) => MediaAsset(
      id: MediaId(id),
      kind: kind,
      displayName: '${kind.name} $id',
      locator: AppRelativeLocator(AppRoot.support, 'danaview/editor/media/$id/file'),
      ownership: MediaOwnership.managedCopy,
      fingerprint: MediaFingerprint(sizeBytes: 1000000, quickHash: id.padRight(40, '0'), duration: duration),
      probe: MediaProbe(kind: kind, duration: duration, hasVideo: w != null, hasAudio: hasAudio, width: w, height: h, audioStreams: hasAudio ? 1 : 0),
      origin: MediaOrigin.files,
      addedAt: _when,
    );

/// A deterministic project of about [items] timeline items: 60 % clips on the main lane (2 s each,
/// video and photos), 15 % PiP clips on 3 overlay lanes, 15 % animated texts on 2 text lanes and
/// 10 % audio clips on 2 audio lanes, plus [cues] subtitle cues on one burned-in lane.
EditProject perfProject({required int items, int cues = 0, String id = 'pr_qa04', String name = 'QA-04 perf', int seed = 4}) {
  final rnd = math.Random(seed);
  final assets = <MediaId, MediaAsset>{};
  final videos = <MediaId>[], images = <MediaId>[], audios = <MediaId>[];
  for (var i = 0; i < 24; i++) {
    final a = _asset('md_v$i', MediaKind.video, duration: 600 * 1000000, w: 1920, h: 1080, hasAudio: true);
    assets[a.id] = a;
    videos.add(a.id);
  }
  for (var i = 0; i < 6; i++) {
    final a = _asset('md_i$i', MediaKind.image, w: 1920, h: 1080);
    assets[a.id] = a;
    images.add(a.id);
  }
  for (var i = 0; i < 4; i++) {
    final a = _asset('md_a$i', MediaKind.audio, duration: 900 * 1000000, hasAudio: true);
    assets[a.id] = a;
    audios.add(a.id);
  }
  var n = 0;
  String next() => 'it_${n++}';
  final mainCount = (items * 0.6).round();
  final overlayCount = (items * 0.15).round();
  final textCount = (items * 0.15).round();
  final audioCount = items - mainCount - overlayCount - textCount;
  const clipFrames = 60;

  MediaClip video(int k0, int frames, {required bool overlay}) {
    final photo = rnd.nextDouble() < 0.15;
    final media = photo ? images[rnd.nextInt(images.length)] : videos[rnd.nextInt(videos.length)];
    final duration = _at(k0 + frames) - _at(k0);
    return MediaClip(
      id: ItemId(next()),
      start: _at(k0),
      duration: duration,
      media: media,
      sourceIn: photo ? 0 : _at(30 * rnd.nextInt(300)),
      visual: overlay
          ? VisualProps(transform: Transform2D(position: Vec2(rnd.nextDouble() * 0.6 - 0.3, -0.2), scale: 0.4, opacity: 0.9))
          : VisualProps.neutral,
      audio: photo ? AudioProps.unity : AudioProps(volume: overlay ? 0.3 : 1),
    );
  }

  final tracks = <Track>[
    Track(id: const TrackId('tr_main'), kind: TrackKind.video, isMain: true, items: [
      for (var i = 0; i < mainCount; i++) video(i * clipFrames, clipFrames, overlay: false),
    ]),
  ];
  final total = mainCount * clipFrames;
  for (var lane = 0; lane < 3; lane++) {
    final per = (overlayCount / 3).ceil();
    final slot = math.max(1, total ~/ math.max(1, per));
    tracks.add(Track(id: TrackId('tr_ov$lane'), kind: TrackKind.overlay, items: [
      for (var j = 0; j < per && lane * per + j < overlayCount; j++) video(j * slot + lane * 10, math.min(90, slot - 20), overlay: true),
    ]));
  }
  for (var lane = 0; lane < 2; lane++) {
    final per = (textCount / 2).ceil();
    final slot = math.max(1, total ~/ math.max(1, per));
    tracks.add(Track(id: TrackId('tr_tx$lane'), kind: TrackKind.text, items: [
      for (var j = 0; j < per && lane * per + j < textCount; j++)
        TextItem(
          id: ItemId(next()),
          start: _at(j * slot + 5),
          duration: _at(j * slot + 5 + math.min(90, slot - 10)) - _at(j * slot + 5),
          text: const ['Day one', 'Summer trip', 'Crème brûlée', 'The end'][j % 4],
          style: const TextStyleSpec(fontSizePt: 48),
          transform: Transform2D(position: Vec2(0, lane == 0 ? -0.3 : 0.3)),
          animation: TextAnimation(inKind: TextAnimKind.fade, inDuration: _at(15)),
        ),
    ]));
  }
  for (var lane = 0; lane < 2; lane++) {
    final per = (audioCount / 2).ceil();
    final slot = math.max(1, total ~/ math.max(1, per));
    tracks.add(Track(id: TrackId('tr_au$lane'), kind: TrackKind.audio, audioRole: lane == 0 ? AudioRole.music : AudioRole.voice, items: [
      for (var j = 0; j < per && lane * per + j < audioCount; j++)
        MediaClip(
          id: ItemId(next()),
          start: _at(j * slot),
          duration: _at(j * slot + math.max(30, slot - 30)) - _at(j * slot),
          media: audios[rnd.nextInt(audios.length)],
          audio: const AudioProps(volume: 0.8),
        ),
    ]));
  }
  if (cues > 0) {
    final cueFrames = math.max(30, (math.max(total, cues * 90)) ~/ cues);
    tracks.add(Track(
      id: const TrackId('tr_sub'),
      kind: TrackKind.subtitle,
      subtitle: const SubtitleTrackData(language: 'en', burnIn: true),
      items: [
        for (var j = 0; j < cues; j++)
          SubtitleCue(
            id: ItemId(next()),
            start: _at(j * cueFrames),
            duration: _at(j * cueFrames + cueFrames - 6) - _at(j * cueFrames),
            text: 'Cue ${j + 1}: ${const ['We left before sunrise', 'Look at that view!', 'Two hours later\nwe arrived', 'And that is a wrap'][j % 4]}',
            origin: CueOrigin.manual,
          ),
      ],
    ));
  }
  return EditProject(
    id: ProjectId(id),
    meta: ProjectMeta(name: name, createdAt: _when, updatedAt: _when),
    timeline: Timeline(
      settings: const ProjectSettings(canvas: CanvasSpec(aspect: AspectRatio.landscape16x9, baseShortSide: 1080), frameRate: _rate),
      tracks: tracks,
    ),
    pool: MediaPool(assets),
  );
}

/// Non-cue timeline items of [p].
int itemCountOf(EditProject p) => p.tracks.expand((t) => t.items).where((i) => i is! SubtitleCue).length;

/// Enables the UX-01 perf hooks for one test (restored on tear-down).
void enablePerfHooks() {
  final was = EditorPerfHooks.enabled;
  EditorPerfHooks.enabled = true;
  EditorPerfHooks.clear();
  addTearDown(() {
    EditorPerfHooks.enabled = was;
    EditorPerfHooks.clear();
  });
}

/// Waits (pumping) until [done] holds or [timeout] passes; returns whether it held.
Future<bool> pumpUntil(WidgetTester tester, bool Function() done, {Duration timeout = const Duration(seconds: 20)}) async {
  final sw = Stopwatch()..start();
  while (!done()) {
    if (sw.elapsed > timeout) return false;
    await tester.pump(const Duration(milliseconds: 16));
  }
  return true;
}
