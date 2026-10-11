// OWNER: UX-21
//
// WaveformCache (ARCH §17.4, ux.md §17.4): the timeline's waveforms.
//
// * Native returns `WaveformPeaks` (int8 min/max pairs, 200 pairs per second of source audio,
//   disk-cached natively). Dart builds a mip pyramid from them (each level halves the pairs: the
//   min of the mins, the max of the maxes) in `Isolate.run` and keeps the pyramids in a memory
//   LRU of 24 MB (25% after memory pressure).
// * Painting picks the level whose pairs-per-px is closest to 1 (log scale) for the clip's source
//   zoom (`pxPerSecond / avgSpeed`), then draws one vertical line per pixel column with a single
//   `drawRawPoints(PointMode.lines)` per clip. Columns map through the clip's speed and reverse
//   with `ClipTimeMap`, so ramps and reversed clips draw what they play.
// * The amplitude is scaled by the volume envelope (the clip volume, or its volume keyframes
//   interpolated linearly), clamped to the lane; a muted clip or lane is drawn dimmed. The thin
//   volume line itself belongs to the canvas.
// * Not ready (peaks loading or failed) -> `paintWaveform` returns false and the canvas draws a
//   centre line. A failed media is not retried for [retryDelay].
// * At most [maxConcurrent] peak extractions run; the most recently painted media goes first.

import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Canvas, Color, Paint, PaintingStyle, PointMode, Rect;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding, WidgetsBindingObserver;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vwish_editor_core/eval.dart' show ClipTimeMap;
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_engine_api/vwish_editor_engine_api.dart';

import '../../app/editor_providers.dart' show editorEngineProvider, editorSessionProvider;
import '../state/editor_session.dart' show EditorSession;
import '../timeline/render_timeline_canvas.dart' show TimelineClipPaint, TimelineWaveformHook;
import '../timeline/timeline_snapshot.dart' show ItemBadges, ItemModel;

/// Resolves a pool media id to the original file (waveforms are never read from a proxy). Null
/// when the media is unavailable.
typedef WaveformMediaResolver = ResolvedMedia? Function(MediaId id);

/// Builds the pyramid of [peaks] (default: `Isolate.run`).
typedef WaveformPyramidBuilder = Future<WaveformPyramid> Function(WaveformPeaks peaks);

/// A mip pyramid of min/max peak pairs.
///
/// Level 0 is the engine's peaks ([basePairsPerSecond] pairs per second of source audio); level
/// `L + 1` has half the pairs of level `L` (rounded up).
@immutable
final class WaveformPyramid {
  /// A pyramid over [levels] (interleaved min, max pairs; level 0 first).
  WaveformPyramid(List<Int8List> levels, {required this.basePairsPerSecond, this.duration = 0})
      : assert(levels.isNotEmpty),
        assert(basePairsPerSecond > 0),
        levels = List.unmodifiable(levels),
        byteSize = levels.fold<int>(0, (n, l) => n + l.lengthInBytes);

  /// Builds the pyramid of [peaks] on this isolate.
  factory WaveformPyramid.fromPeaks(WaveformPeaks peaks) => WaveformPyramid(
        buildLevels(peaks.minMax),
        basePairsPerSecond: peaks.pairsPerSecond,
        duration: peaks.duration,
      );

  /// Levels are built until one has at most this many pairs.
  static const int topLevelPairs = 8;

  /// Builds the levels of [base] (interleaved min, max pairs). Pure; runs in an isolate.
  static List<Int8List> buildLevels(Int8List base) {
    final levels = <Int8List>[base];
    var current = base;
    while (current.length ~/ 2 > topLevelPairs) {
      final pairs = current.length ~/ 2;
      final next = Int8List(((pairs + 1) ~/ 2) * 2);
      for (var i = 0; i < next.length ~/ 2; i++) {
        final a = 2 * (2 * i);
        var lo = current[a], hi = current[a + 1];
        if (a + 3 < current.length) {
          if (current[a + 2] < lo) lo = current[a + 2];
          if (current[a + 3] > hi) hi = current[a + 3];
        }
        next[2 * i] = lo;
        next[2 * i + 1] = hi;
      }
      levels.add(next);
      current = next;
    }
    return levels;
  }

  /// Builds the pyramid of [peaks] in `Isolate.run`.
  static Future<WaveformPyramid> buildInIsolate(WaveformPeaks peaks) async {
    final data = peaks.minMax;
    final levels = await Isolate.run(() => buildLevels(data));
    return WaveformPyramid(levels, basePairsPerSecond: peaks.pairsPerSecond, duration: peaks.duration);
  }

  /// The levels, finest first.
  final List<Int8List> levels;

  /// Pairs per second of source audio at level 0.
  final int basePairsPerSecond;

  /// Source duration covered.
  final TimeUs duration;

  /// Memory used by the levels.
  final int byteSize;

  /// Number of levels.
  int get levelCount => levels.length;

  /// Pairs per second of source audio at [level].
  double pairsPerSecondAt(int level) => basePairsPerSecond / (1 << level);

  /// Pairs in [level].
  int pairsIn(int level) => levels[level].length ~/ 2;

  /// The level whose pairs-per-px is closest to 1 (on a log scale) when one second of source
  /// audio spans [sourcePxPerSecond] px.
  int levelFor(double sourcePxPerSecond) {
    if (!(sourcePxPerSecond > 0)) return levels.length - 1;
    var best = 0;
    var bestDistance = double.infinity;
    for (var l = 0; l < levels.length; l++) {
      final pairsPerPx = pairsPerSecondAt(l) / sourcePxPerSecond;
      final d = (math.log(pairsPerPx)).abs();
      if (d < bestDistance) {
        bestDistance = d;
        best = l;
      }
    }
    return best;
  }

  /// The (min, max) over the source seconds `[fromSec, toSec]` at [level] (at least one pair);
  /// null when the span lies past the end of the audio.
  (int, int)? range(int level, double fromSec, double toSec) {
    final data = levels[level];
    final n = data.length ~/ 2;
    final pps = pairsPerSecondAt(level);
    final lo = math.min(fromSec, toSec), hi = math.max(fromSec, toSec);
    var i0 = (lo * pps).floor();
    if (i0 < 0) i0 = 0;
    if (i0 >= n) return null;
    var i1 = (hi * pps).ceil();
    if (i1 <= i0) i1 = i0 + 1;
    if (i1 > n) i1 = n;
    var mn = 127, mx = -128;
    for (var i = i0; i < i1; i++) {
      final a = data[2 * i], b = data[2 * i + 1];
      if (a < mn) mn = a;
      if (b > mx) mx = b;
    }
    return (mn, mx);
  }

  @override
  String toString() => 'WaveformPyramid(${levels.length} levels, ${basePairsPerSecond}pps, $byteSize bytes)';
}

/// The gain the waveform of a clip is scaled by (ux.md §17.4).
abstract final class WaveformEnvelope {
  /// The clip's volume at item-local time [local]: its volume keyframes interpolated linearly
  /// (held before the first and after the last), or the clip volume without keys. Never
  /// negative.
  static double gainAt(ItemModel item, TimeUs local) {
    final keys = item.volumeKeys;
    if (keys.isEmpty) return math.max(0, item.volume);
    if (local <= keys.first.t) return math.max(0, keys.first.v);
    if (local >= keys.last.t) return math.max(0, keys.last.v);
    var lo = 0, hi = keys.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (keys[mid].t <= local) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final a = keys[lo], b = keys[hi];
    final f = (local - a.t) / (b.t - a.t);
    return math.max(0, a.v + (b.v - a.v) * f);
  }
}

/// Identity of one pyramid.
@immutable
final class WaveformKey {
  /// Creates a key.
  const WaveformKey(this.fingerprint, this.audioStream);

  /// Quick hash of the original file.
  final String fingerprint;

  /// The audio stream.
  final int audioStream;

  @override
  bool operator ==(Object other) => other is WaveformKey && other.fingerprint == fingerprint && other.audioStream == audioStream;

  @override
  int get hashCode => Object.hash(fingerprint, audioStream);

  @override
  String toString() => 'WaveformKey($fingerprint, #$audioStream)';
}

/// A ChangeNotifier the cache can fire.
final class _Notifier extends ChangeNotifier {
  void notify() => notifyListeners();
}

enum _State { waiting, extracting, building }

final class _Job {
  _Job(this.key, this.media, this.stream, this.touched);

  final WaveformKey key;
  final ResolvedMedia media;
  final int stream;
  int touched;
  _State state = _State.waiting;
  MediaJob<WaveformPeaks>? job;
}

/// The waveform pyramids of the timeline canvas (ux.md §17.4). See the file comment.
class WaveformCache with TimelineWaveformHook {
  /// Creates the cache over [source]. [builder] defaults to `Isolate.run`; [now] is for tests.
  WaveformCache({
    required WaveformSource source,
    required WaveformMediaResolver resolve,
    this.budgetBytes = defaultBudgetBytes,
    this.maxConcurrent = 2,
    WaveformPyramidBuilder? builder,
    DateTime Function()? now,
    this.retryDelay = const Duration(seconds: 10),
  })  : assert(maxConcurrent > 0),
        _source = source,
        _resolve = resolve,
        _builder = builder ?? WaveformPyramid.buildInIsolate,
        _now = now ?? DateTime.now;

  /// The memory budget (ux.md §17.4): 24 MB.
  static const int defaultBudgetBytes = 24 * 1024 * 1024;

  /// The share of the budget kept after memory pressure.
  static const double pressureFraction = 0.25;

  final WaveformSource _source;
  final WaveformMediaResolver _resolve;
  final WaveformPyramidBuilder _builder;
  final DateTime Function() _now;
  final _Notifier _changes = _Notifier();
  final LinkedHashMap<WaveformKey, WaveformPyramid> _pyramids = LinkedHashMap();
  final Map<WaveformKey, _Job> _jobs = {};
  final Map<WaveformKey, DateTime> _failed = {};
  final Expando<ClipTimeMap> _maps = Expando<ClipTimeMap>('waveform time maps');
  int _bytes = 0;
  int _touchSeq = 0;
  bool _disposed = false;

  /// Memory budget of the pyramids in bytes.
  final int budgetBytes;

  /// Most peak extractions running at once.
  final int maxConcurrent;

  /// How long a failed media is left alone.
  final Duration retryDelay;

  /// Peak extractions requested from the engine since creation.
  int requestedCount = 0;

  /// Extractions or builds that failed.
  int failedCount = 0;

  @override
  Listenable get changes => _changes;

  /// Bytes of pyramids in memory.
  int get cachedBytes => _bytes;

  /// Pyramids in memory.
  int get cachedCount => _pyramids.length;

  /// Extractions waiting, running or building.
  int get pendingCount => _jobs.length;

  /// Whether the pyramid of [key] is ready (does not touch the LRU order).
  bool contains(WaveformKey key) => _pyramids.containsKey(key);

  /// The pyramid of [key], or null (does not touch the LRU order).
  WaveformPyramid? pyramidOf(WaveformKey key) => _pyramids[key];

  // ---------------------------------------------------------------------------------------------
  // Hook
  // ---------------------------------------------------------------------------------------------

  @override
  bool paintWaveform(Canvas canvas, TimelineClipPaint clip, Rect area, Color color) {
    if (_disposed) return false;
    final item = clip.item;
    final id = item.media;
    if (id == null || !item.hasAudio || item.offline || item.pending) return false;
    final media = _resolve(id);
    if (media == null) return false;
    final source = item.source;
    final stream = source is MediaClip ? (source.audioStream ?? 0) : 0;
    final key = WaveformKey(media.fingerprint, stream);
    final pyramid = _touch(key);
    if (pyramid == null) {
      _want(key, media, stream);
      return false;
    }
    _draw(canvas, clip, pyramid, area, color);
    return true;
  }

  void _draw(Canvas canvas, TimelineClipPaint clip, WaveformPyramid pyramid, Rect area, Color color) {
    final visible = clip.visible;
    if (visible.isEmpty || area.height < 2) return;
    final item = clip.item;
    final map = _mapOf(item);
    final srcPxPerSecond = clip.pxPerSecond / (item.avgSpeed > 0 ? item.avgSpeed : 1);
    final level = pyramid.levelFor(srcPxPerSecond);
    final x0 = visible.left.floorToDouble();
    final columns = math.max(0, (visible.right - x0).ceil());
    if (columns == 0) return;
    final half = (area.height - 2) / 2;
    final cy = area.center.dy;
    final points = Float32List(columns * 4);
    var n = 0;
    for (var c = 0; c < columns; c++) {
      final x = x0 + c;
      final t0 = _clampTime(clip.timeAt(x), item);
      final t1 = _clampTime(clip.timeAt(x + 1), item);
      final s0 = _sourceSec(map, item, t0);
      final s1 = _sourceSec(map, item, t1);
      final r = pyramid.range(level, s0, s1);
      double top, bottom;
      if (r == null) {
        top = bottom = cy;
      } else {
        final gain = WaveformEnvelope.gainAt(item, t0 - item.start);
        final hi = (r.$2 / 127 * gain).clamp(-1.0, 1.0);
        final lo = (r.$1 / 128 * gain).clamp(-1.0, 1.0);
        top = cy - hi * half;
        bottom = cy - lo * half;
      }
      if (bottom - top < 1) {
        final mid = (top + bottom) / 2;
        top = mid - 0.5;
        bottom = mid + 0.5;
      }
      final px = x + 0.5;
      points[n++] = px;
      points[n++] = top;
      points[n++] = px;
      points[n++] = bottom;
    }
    final dimmed = item.badges & ItemBadges.muted != 0 || clip.lane.muted;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..isAntiAlias = false
      ..color = dimmed ? color.withValues(alpha: color.a * 0.4) : color;
    canvas.drawRawPoints(PointMode.lines, Float32List.sublistView(points, 0, n), paint);
  }

  ClipTimeMap? _mapOf(ItemModel item) {
    final source = item.source;
    if (source is! MediaClip) return null;
    final cached = _maps[source];
    if (cached != null) return cached;
    try {
      return _maps[source] = ClipTimeMap.forClip(source, FrameRate.fps30);
    } on ArgumentError {
      return null;
    }
  }

  static TimeUs _clampTime(TimeUs t, ItemModel item) => t < item.start ? item.start : (t > item.end ? item.end : t);

  static double _sourceSec(ClipTimeMap? map, ItemModel item, TimeUs t) {
    final us = map != null ? map.sourceAt(t) : item.sourceIn + (t - item.start) * item.avgSpeed;
    return us / microsPerSecond;
  }

  // ---------------------------------------------------------------------------------------------
  // Loading
  // ---------------------------------------------------------------------------------------------

  void _want(WaveformKey key, ResolvedMedia media, int stream) {
    final existing = _jobs[key];
    if (existing != null) {
      existing.touched = _touchSeq++;
      return;
    }
    final failedAt = _failed[key];
    if (failedAt != null) {
      if (_now().difference(failedAt) < retryDelay) return;
      _failed.remove(key);
    }
    _jobs[key] = _Job(key, media, stream, _touchSeq++);
    _pump();
  }

  void _pump() {
    if (_disposed) return;
    while (true) {
      var running = 0;
      _Job? next;
      for (final j in _jobs.values) {
        if (j.state == _State.extracting) running++;
        if (j.state == _State.waiting && (next == null || j.touched > next.touched)) next = j;
      }
      if (next == null || running >= maxConcurrent) return;
      _start(next);
    }
  }

  void _start(_Job job) {
    job.state = _State.extracting;
    requestedCount++;
    final MediaJob<WaveformPeaks> started;
    try {
      started = _source.peaks(job.media, audioStream: job.stream);
    } catch (_) {
      _jobs.remove(job.key);
      _fail(job.key);
      return;
    }
    job.job = started;
    started.result.then<void>((peaks) => _extracted(job, peaks), onError: (Object _) => _onError(job));
  }

  Future<void> _extracted(_Job job, WaveformPeaks peaks) async {
    if (_disposed || _jobs[job.key] != job) return;
    job.state = _State.building;
    _pump();
    WaveformPyramid pyramid;
    try {
      pyramid = await _builder(peaks);
    } catch (_) {
      if (_jobs[job.key] == job) {
        _jobs.remove(job.key);
        _fail(job.key);
      }
      _pump();
      return;
    }
    if (_disposed || _jobs[job.key] != job) return;
    _jobs.remove(job.key);
    _insert(job.key, pyramid);
    _changes.notify();
    _pump();
  }

  void _onError(_Job job) {
    if (_disposed || _jobs[job.key] != job) return;
    _jobs.remove(job.key);
    _fail(job.key);
    _pump();
  }

  void _fail(WaveformKey key) {
    failedCount++;
    _failed[key] = _now();
  }

  // ---------------------------------------------------------------------------------------------
  // LRU and maintenance
  // ---------------------------------------------------------------------------------------------

  WaveformPyramid? _touch(WaveformKey key) {
    final p = _pyramids.remove(key);
    if (p != null) _pyramids[key] = p;
    return p;
  }

  void _insert(WaveformKey key, WaveformPyramid pyramid) {
    final old = _pyramids.remove(key);
    if (old != null) _bytes -= old.byteSize;
    _pyramids[key] = pyramid;
    _bytes += pyramid.byteSize;
    _trimTo(budgetBytes, keep: key);
  }

  void _trimTo(int limit, {WaveformKey? keep}) {
    if (_bytes <= limit) return;
    for (final key in _pyramids.keys.toList()) {
      if (_bytes <= limit) return;
      if (key == keep) continue;
      _bytes -= _pyramids.remove(key)!.byteSize;
    }
  }

  /// Memory pressure: keeps 25% of the budget (least recently used pyramids go first).
  void onMemoryPressure() {
    if (_disposed) return;
    _failed.clear();
    _trimTo((budgetBytes * pressureFraction).floor());
  }

  /// Drops the pyramids and pending work of the media with [fingerprint] (replaced or relinked).
  void evictMedia(String fingerprint) {
    for (final j in _jobs.values.where((j) => j.key.fingerprint == fingerprint).toList()) {
      j.job?.cancel();
      _jobs.remove(j.key);
    }
    _failed.removeWhere((k, _) => k.fingerprint == fingerprint);
    for (final k in _pyramids.keys.where((k) => k.fingerprint == fingerprint).toList()) {
      _bytes -= _pyramids.remove(k)!.byteSize;
    }
    _changes.notify();
  }

  /// Drops every pyramid and cancels every extraction.
  void clear() {
    for (final j in _jobs.values) {
      j.job?.cancel();
    }
    _jobs.clear();
    _failed.clear();
    _pyramids.clear();
    _bytes = 0;
    _changes.notify();
  }

  /// Cancels the extractions and releases the pyramids. The cache is unusable afterwards.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final j in _jobs.values) {
      j.job?.cancel();
    }
    _jobs.clear();
    _pyramids.clear();
    _bytes = 0;
    _changes.dispose();
  }

  @override
  String toString() => 'WaveformCache(${_pyramids.length} pyramids, ${_bytes ~/ 1024} KB of ${budgetBytes ~/ 1024} KB, ${_jobs.length} pending)';
}

// -------------------------------------------------------------------------------------------------
// Provider
// -------------------------------------------------------------------------------------------------

/// The resolver over an editing session: the original file of a pool media.
WaveformMediaResolver sessionWaveformResolver(EditorSession session) => (id) {
      final project = session.project;
      final compiler = session.compiler;
      if (project == null || compiler == null) return null;
      return compiler.resolve(project, id);
    };

/// The waveform cache of an open project (ux.md §17.4): over `engine.waveforms`, 24 MB, trimmed
/// on the engine's memory warning and on the system's, disposed with the project.
///
/// Wire it into the timeline with `timelineContentHooksProvider` (UX-12):
/// `TimelineContentHooks(waveforms: ref.watch(waveformCacheProvider(id)), ...)`.
final waveformCacheProvider = Provider.autoDispose.family<WaveformCache, ProjectId>(
  (ref, id) {
    final engine = ref.watch(editorEngineProvider);
    final session = ref.watch(editorSessionProvider(id));
    final cache = WaveformCache(source: engine.waveforms, resolve: sessionWaveformResolver(session));
    final signals = engine.signals.listen((signal) {
      if (signal is MemoryWarningSignal) cache.onMemoryPressure();
    });
    final observer = _MemoryPressureObserver(cache.onMemoryPressure);
    WidgetsBinding.instance.addObserver(observer);
    ref.onDispose(() {
      WidgetsBinding.instance.removeObserver(observer);
      unawaited(signals.cancel());
      cache.dispose();
    });
    return cache;
  },
  name: 'waveformCacheProvider',
);

final class _MemoryPressureObserver with WidgetsBindingObserver {
  _MemoryPressureObserver(this.onPressure);

  final void Function() onPressure;

  @override
  void didHaveMemoryPressure() => onPressure();
}
