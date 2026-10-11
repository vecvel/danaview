// OWNER: UX-20
//
// ThumbnailCache (ARCH §17.4, ux.md §17.3): the timeline's thumbnail strips.
//
// * Source: `engine.thumbnails` returns JPEG strips of 8 frames at a fixed height and a fixed
//   interval; this cache decodes them to `ui.Image`s and keeps them in a byte-budgeted LRU
//   (48 MB on `lowMemoryDevice`, 96 MB otherwise; 25% after memory pressure).
// * Keys: `(media fingerprint, interval, height bucket, tile index, proxy)`. The height is the
//   clip's pixel height bucketed to 48/64/96; the interval comes from the zoom through the ladder
//   0.5, 1, 2, 5, 10, 30, 60 s so one cell is about one clip-height wide. A cell shows the frame
//   nearest to the time at its centre, mapped through the clip's speed and reverse
//   (`ClipTimeMap`), so thumbnails follow ramps and reversed clips.
// * Priorities: visible tiles > overscan prefetch. At most [maxInFlight] engine requests run; a
//   waiting visible request pre-empts a running prefetch one. Every paint pass (`beginPaint` ..
//   `endPaint`) marks the tiles it touched; requests it did not touch are cancelled through
//   `ThumbnailHandle.cancel()` (the tile scrolled out of the overscan). While a fling is fast
//   (|velocity| > 2000 px/s) no new request starts; the next paint after the fling slows starts
//   them.
// * Hit = drawn in the same frame. Miss = a flat cell (a cached strip of another interval is used
//   meanwhile, so zooming does not flash). On arrival the canvas repaints through `changes`.
// * Proxy vs original: a ready proxy (same timestamps) is used for video strips when the host
//   resolves one; stills always use the original (decoded once at lane height, repeated).
// * A failed tile is not retried for [retryDelay] (a repaint never loops on a broken file).
// * `onMemoryPressure` trims to 25% and cancels non-visible requests.

import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui' show Canvas, Paint, Rect;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show FilterQuality;
import 'package:flutter/widgets.dart' show WidgetsBinding, WidgetsBindingObserver;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/eval.dart' show ClipTimeMap;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

import '../../app/editor_providers.dart' show editorCapabilitiesProvider, editorEngineProvider, editorSessionProvider;
import '../state/editor_session.dart' show EditorSession;
import '../timeline/render_timeline_canvas.dart' show TimelineClipPaint, TimelineThumbnailHook;
import '../timeline/timeline_snapshot.dart' show ItemModel, ItemVisualKind;

/// Resolves a pool media id to the file the engine reads: the original, or its ready proxy when
/// [proxy] is true. Null when the media is unavailable right now (offline).
typedef ThumbnailMediaResolver = ResolvedMedia? Function(MediaId id, {required bool proxy});

/// Decodes one JPEG strip.
typedef ThumbnailImageDecoder = Future<ui.Image> Function(Uint8List encoded);

/// Identity of one cached strip.
@immutable
final class ThumbnailKey {
  /// Creates a key.
  const ThumbnailKey({
    required this.fingerprint,
    required this.intervalMs,
    required this.heightPx,
    required this.tileIndex,
    required this.proxy,
  });

  /// Quick hash of the original file.
  final String fingerprint;

  /// Source time between two frames.
  final int intervalMs;

  /// Frame height in px (48, 64 or 96).
  final int heightPx;

  /// Tile index (tile `i` starts at `i · framesPerTile · intervalMs`).
  final int tileIndex;

  /// Whether the strip was decoded from the proxy.
  final bool proxy;

  @override
  bool operator ==(Object other) =>
      other is ThumbnailKey &&
      other.fingerprint == fingerprint &&
      other.intervalMs == intervalMs &&
      other.heightPx == heightPx &&
      other.tileIndex == tileIndex &&
      other.proxy == proxy;

  @override
  int get hashCode => Object.hash(fingerprint, intervalMs, heightPx, tileIndex, proxy);

  @override
  String toString() => 'ThumbnailKey(${fingerprint.length > 8 ? fingerprint.substring(0, 8) : fingerprint}, ${intervalMs}ms, ${heightPx}px, #$tileIndex${proxy ? ', proxy' : ''})';
}

/// One decoded strip in the cache.
final class _Strip {
  _Strip(this.image, this.frames) : bytes = image.width * image.height * 4;

  final ui.Image image;
  final int frames;
  final int bytes;
}

/// A ChangeNotifier the cache can fire.
final class _Notifier extends ChangeNotifier {
  void notify() => notifyListeners();
}

enum _JobState { waiting, requesting, decoding }

final class _Job {
  _Job(this.key, this.request, this.priority, this.pass);

  final ThumbnailKey key;
  final ThumbnailRequest request;
  ThumbPriority priority;
  int pass;
  _JobState state = _JobState.waiting;
  ThumbnailHandle? handle;
  int sequence = 0;
}

/// What a clip needs: the media, the strip parameters and the time map.
final class _Plan {
  const _Plan({
    required this.media,
    required this.proxy,
    required this.still,
    required this.heightPx,
    required this.intervalMs,
    required this.cellWidth,
    required this.map,
    required this.item,
  });

  final ResolvedMedia media;
  final bool proxy;
  final bool still;
  final int heightPx;
  final int intervalMs;
  final double cellWidth;
  final ClipTimeMap? map;
  final ItemModel item;

  int get framesPerTile => still ? 1 : ThumbnailCache.framesPerTile;

  ThumbnailKey key(int tile, {int? interval, bool? useProxy}) => ThumbnailKey(
        fingerprint: media.fingerprint,
        intervalMs: still ? ThumbnailCache.stillIntervalMs : (interval ?? intervalMs),
        heightPx: heightPx,
        tileIndex: tile,
        proxy: useProxy ?? proxy,
      );

  /// The source time (µs) shown at timeline time [t].
  double sourceAt(TimeUs t) {
    final m = map;
    if (m != null) return m.sourceAt(t);
    return item.sourceIn + (t - item.start) * item.avgSpeed;
  }
}

/// The thumbnail strips of the timeline canvas (ux.md §17.3). See the file comment.
class ThumbnailCache with TimelineThumbnailHook {
  /// Creates the cache over [source].
  ///
  /// [resolve] maps pool ids to engine media. [lowMemoryDevice] picks the 48 MB budget (96 MB
  /// otherwise) unless [budgetBytes] is given. [decoder] and [now] are for tests.
  ThumbnailCache({
    required ThumbnailSource source,
    required ThumbnailMediaResolver resolve,
    bool lowMemoryDevice = false,
    int? budgetBytes,
    this.maxInFlight = 4,
    ThumbnailImageDecoder? decoder,
    DateTime Function()? now,
    this.retryDelay = const Duration(seconds: 5),
  })  : assert(maxInFlight > 0),
        _source = source,
        _resolve = resolve,
        budgetBytes = budgetBytes ?? defaultBudgetBytes(lowMemoryDevice: lowMemoryDevice),
        _decoder = decoder ?? decodeJpeg,
        _now = now ?? DateTime.now;

  // ---------------------------------------------------------------------------------------------
  // Constants and pure helpers
  // ---------------------------------------------------------------------------------------------

  /// Frames per strip (engine API default).
  static const int framesPerTile = 8;

  /// The interval ladder in ms (ux.md §17.3).
  static const List<int> intervalLadderMs = [500, 1000, 2000, 5000, 10000, 30000, 60000];

  /// The strip heights in px.
  static const List<int> heightBuckets = [48, 64, 96];

  /// Interval stored in the key of a still image (its strip has one frame).
  static const int stillIntervalMs = 1000;

  /// Fling speed above which new requests are deferred (px/s).
  static const double flingDeferVelocity = 2000;

  /// Memory budget on `lowMemoryDevice`.
  static const int lowMemoryBudgetBytes = 48 * 1024 * 1024;

  /// Memory budget otherwise.
  static const int standardBudgetBytes = 96 * 1024 * 1024;

  /// The share of the budget kept after memory pressure.
  static const double pressureFraction = 0.25;

  /// Tiles requested around the visible ones (each side) for a visible clip.
  static const int prefetchTilesAround = 1;

  /// Most tiles one overscan clip prefetches.
  static const int maxPrefetchTilesPerClip = 8;

  /// The budget for a device class.
  static int defaultBudgetBytes({required bool lowMemoryDevice}) => lowMemoryDevice ? lowMemoryBudgetBytes : standardBudgetBytes;

  /// The strip height bucket for a clip body of [logicalHeight] px at [devicePixelRatio]: the
  /// smallest of 48/64/96 that covers the pixel height (96 at most).
  static int heightBucket(double logicalHeight, double devicePixelRatio) {
    final px = logicalHeight * devicePixelRatio;
    for (final b in heightBuckets) {
      if (px <= b) return b;
    }
    return heightBuckets.last;
  }

  /// The ladder interval (ms) nearest, on a log scale, to the source time one cell of
  /// [cellWidthPx] spans: `cellWidthPx · avgSpeed / pxPerSecond` seconds.
  static int intervalFor({required double cellWidthPx, required double pxPerSecond, double avgSpeed = 1}) {
    if (!(pxPerSecond > 0) || !(cellWidthPx > 0)) return intervalLadderMs.first;
    final needed = cellWidthPx * (avgSpeed > 0 ? avgSpeed : 1) / pxPerSecond * 1000;
    var best = intervalLadderMs.first;
    var bestDistance = double.infinity;
    for (final ms in intervalLadderMs) {
      final d = (math.log(ms) - math.log(needed)).abs();
      if (d < bestDistance) {
        bestDistance = d;
        best = ms;
      }
    }
    return best;
  }

  /// Decodes a JPEG strip with the engine's codec.
  static Future<ui.Image> decodeJpeg(Uint8List encoded) async {
    final codec = await ui.instantiateImageCodec(encoded);
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  }

  // ---------------------------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------------------------

  final ThumbnailSource _source;
  final ThumbnailMediaResolver _resolve;
  final ThumbnailImageDecoder _decoder;
  final DateTime Function() _now;
  final _Notifier _changes = _Notifier();
  final LinkedHashMap<ThumbnailKey, _Strip> _strips = LinkedHashMap();
  final Map<ThumbnailKey, _Job> _jobs = {};
  final Map<ThumbnailKey, DateTime> _failed = {};
  final Expando<ClipTimeMap> _maps = Expando<ClipTimeMap>('thumbnail time maps');
  final Paint _paint = Paint()
    ..filterQuality = FilterQuality.low
    ..isAntiAlias = false;

  /// Most engine requests running at once.
  final int maxInFlight;

  /// How long a failed tile is left alone.
  final Duration retryDelay;

  /// Memory budget of the decoded strips in bytes.
  final int budgetBytes;

  TimeRange _window = const TimeRange(0, 0);
  int _pass = 0;
  int _sequence = 0;
  int _bytes = 0;
  bool _disposed = false;

  /// Strips requested from the engine since creation.
  int requestedCount = 0;

  /// Requests cancelled (scrolled away, pre-empted by memory pressure) since creation.
  int cancelledCount = 0;

  /// Requests that were not started because a fling was fast.
  int deferredCount = 0;

  /// Tiles that failed to load or decode.
  int failedCount = 0;

  @override
  Listenable get changes => _changes;

  /// Bytes of decoded strips in memory.
  int get cachedBytes => _bytes;

  /// Decoded strips in memory.
  int get cachedCount => _strips.length;

  /// Requests waiting for a slot.
  int get waitingCount => _jobs.values.where((j) => j.state == _JobState.waiting).length;

  /// Engine requests running.
  int get inFlightCount => _jobs.values.where((j) => j.state == _JobState.requesting).length;

  /// Whether the strip [key] is in memory (does not touch the LRU order).
  bool contains(ThumbnailKey key) => _strips.containsKey(key);

  /// The priority of the waiting or running request for [key], or null.
  ThumbPriority? priorityOf(ThumbnailKey key) => _jobs[key]?.priority;

  /// Keys of the waiting or running requests.
  Iterable<ThumbnailKey> get pendingKeys => _jobs.keys;

  // ---------------------------------------------------------------------------------------------
  // Hook
  // ---------------------------------------------------------------------------------------------

  @override
  void beginPaint(TimeRange window) {
    _window = window;
    _pass++;
  }

  @override
  void endPaint() {
    if (_disposed) return;
    var changed = false;
    for (final job in _jobs.values.toList()) {
      if (job.pass == _pass || job.state == _JobState.decoding) continue;
      _drop(job);
      changed = true;
    }
    if (changed) _pump();
  }

  @override
  bool paintThumbnails(Canvas canvas, TimelineClipPaint clip) {
    if (_disposed) return false;
    final plan = _planOf(clip);
    if (plan == null) return false;
    final body = clip.body;
    final visible = clip.visible;
    if (visible.isEmpty || body.height <= 0 || plan.cellWidth <= 0) return false;
    final cell = plan.cellWidth;
    final first = math.max(0, ((visible.left - body.left) / cell).floor());
    final last = ((visible.right - body.left) / cell).ceil();
    final intervalUs = plan.intervalMs * 1000;
    final item = clip.item;
    final deferred = clip.flingVelocityX.abs() > flingDeferVelocity;
    var painted = 0;
    final missing = <Rect>[];
    final wanted = <ThumbnailKey, ThumbnailRequest>{};
    int? lowTile, highTile;

    for (var k = first; k < last; k++) {
      final rect = Rect.fromLTWH(body.left + k * cell, body.top, cell, body.height);
      final t = _clampTime(clip.timeAt(rect.center.dx), item);
      final frame = plan.still ? 0 : _frameOf(plan.sourceAt(t), intervalUs);
      final tile = plan.still ? 0 : frame ~/ framesPerTile;
      lowTile = lowTile == null ? tile : math.min(lowTile, tile);
      highTile = highTile == null ? tile : math.max(highTile, tile);
      final exact = plan.key(tile);
      var strip = _touch(exact);
      var inFrame = frame % plan.framesPerTile;
      if (strip == null) {
        wanted[exact] = _requestOf(plan, tile);
        if (!plan.still) {
          final fallback = _fallback(plan, plan.sourceAt(t));
          if (fallback != null) (strip, inFrame) = fallback;
        }
      }
      if (strip == null) {
        missing.add(rect);
        continue;
      }
      _drawFrame(canvas, strip, math.min(inFrame, strip.frames - 1), rect);
      painted++;
    }

    for (final e in wanted.entries) {
      _want(e.key, e.value, ThumbPriority.visible, deferred: deferred);
    }
    if (!plan.still && lowTile != null && highTile != null) {
      _prefetchAround(plan, lowTile, highTile, deferred: deferred);
    }
    if (painted == 0) return false;
    if (missing.isNotEmpty) _paintMissing(canvas, missing, clip);
    return true;
  }

  @override
  void prefetchThumbnails(TimelineClipPaint clip) {
    if (_disposed) return;
    final plan = _planOf(clip);
    if (plan == null) return;
    final deferred = clip.flingVelocityX.abs() > flingDeferVelocity;
    if (plan.still) {
      _want(plan.key(0), _requestOf(plan, 0), ThumbPriority.prefetch, deferred: deferred);
      return;
    }
    final item = clip.item;
    final from = math.max(item.start, _window.start);
    final to = math.min(item.end - 1, _window.end);
    if (to < from) return;
    final intervalUs = plan.intervalMs * 1000;
    final a = _frameOf(plan.sourceAt(_clampTime(from, item)), intervalUs);
    final b = _frameOf(plan.sourceAt(_clampTime(to, item)), intervalUs);
    final lo = math.min(a, b) ~/ framesPerTile;
    final hi = math.max(a, b) ~/ framesPerTile;
    final tiles = math.min(hi - lo + 1, maxPrefetchTilesPerClip);
    for (var i = 0; i < tiles; i++) {
      final tile = lo + i;
      if (_strips.containsKey(plan.key(tile))) continue;
      _want(plan.key(tile), _requestOf(plan, tile), ThumbPriority.prefetch, deferred: deferred);
    }
  }

  // ---------------------------------------------------------------------------------------------
  // Maintenance
  // ---------------------------------------------------------------------------------------------

  /// Memory pressure: keeps 25% of the budget (least recently used strips go first) and cancels
  /// every request that is not for a visible tile.
  void onMemoryPressure() {
    if (_disposed) return;
    for (final job in _jobs.values.toList()) {
      if (job.priority != ThumbPriority.visible && job.state != _JobState.decoding) _drop(job);
    }
    _failed.clear();
    _trimTo((budgetBytes * pressureFraction).floor());
    _pump();
  }

  /// Drops every strip and request (the project was replaced).
  void clear() {
    for (final job in _jobs.values.toList()) {
      if (job.state != _JobState.decoding) _drop(job);
    }
    _failed.clear();
    _trimTo(0);
    _changes.notify();
  }

  /// Drops the strips of the media with [fingerprint] (relinked, replaced or its proxy changed).
  void evictMedia(String fingerprint) {
    for (final job in _jobs.values.toList()) {
      if (job.key.fingerprint == fingerprint && job.state != _JobState.decoding) _drop(job);
    }
    _failed.removeWhere((k, _) => k.fingerprint == fingerprint);
    for (final k in _strips.keys.where((k) => k.fingerprint == fingerprint).toList()) {
      _evict(k);
    }
    _changes.notify();
  }

  /// Cancels every request and releases the images. The cache is unusable afterwards.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final job in _jobs.values.toList()) {
      if (job.state == _JobState.requesting) job.handle?.cancel();
    }
    _jobs.clear();
    for (final s in _strips.values) {
      s.image.dispose();
    }
    _strips.clear();
    _bytes = 0;
    _changes.dispose();
  }

  // ---------------------------------------------------------------------------------------------
  // Planning
  // ---------------------------------------------------------------------------------------------

  _Plan? _planOf(TimelineClipPaint clip) {
    final item = clip.item;
    final id = item.media;
    if (id == null || item.offline || item.pending || !item.showsThumbnails) return null;
    final visual = item.visual;
    final aspect = visual != null && visual.aspect > 0 ? visual.aspect : 16 / 9;
    final bodyHeight = clip.body.height;
    if (!(bodyHeight > 0)) return null;
    final cell = math.max(8.0, bodyHeight * aspect);
    final height = heightBucket(bodyHeight, clip.devicePixelRatio);
    final still = item.kind == ItemVisualKind.image || item.kind == ItemVisualKind.freeze;
    ResolvedMedia? media;
    var proxy = false;
    if (!still && (visual?.proxyReady ?? false)) {
      media = _resolve(id, proxy: true);
      proxy = media != null;
    }
    media ??= _resolve(id, proxy: false);
    if (media == null) return null;
    return _Plan(
      media: media,
      proxy: proxy,
      still: still,
      heightPx: height,
      intervalMs: still ? stillIntervalMs : intervalFor(cellWidthPx: cell, pxPerSecond: clip.pxPerSecond, avgSpeed: item.avgSpeed),
      cellWidth: cell,
      map: still ? null : _mapOf(item),
      item: item,
    );
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

  ThumbnailRequest _requestOf(_Plan plan, int tile) => ThumbnailRequest(
        media: plan.media,
        intervalMs: plan.still ? stillIntervalMs : plan.intervalMs,
        tileIndex: tile,
        heightPx: plan.heightPx,
        framesPerTile: plan.framesPerTile,
        proxy: plan.proxy,
      );

  static TimeUs _clampTime(TimeUs t, ItemModel item) => t < item.start ? item.start : (t >= item.end ? item.end - 1 : t);

  static int _frameOf(double sourceUs, int intervalUs) => math.max(0, (sourceUs / intervalUs).round());

  /// A cached strip of a neighbouring interval (or the other proxy flag) that has the frame for
  /// [sourceUs], nearest interval first.
  (_Strip, int)? _fallback(_Plan plan, double sourceUs) {
    final candidates = [...intervalLadderMs]..sort((a, b) => (math.log(a) - math.log(plan.intervalMs)).abs().compareTo((math.log(b) - math.log(plan.intervalMs)).abs()));
    for (final ms in candidates) {
      for (final proxy in [plan.proxy, !plan.proxy]) {
        if (ms == plan.intervalMs && proxy == plan.proxy) continue;
        final frame = _frameOf(sourceUs, ms * 1000);
        final strip = _touch(plan.key(frame ~/ framesPerTile, interval: ms, useProxy: proxy));
        if (strip != null) return (strip, frame % framesPerTile);
      }
    }
    return null;
  }

  _Strip? _touch(ThumbnailKey key) {
    final strip = _strips.remove(key);
    if (strip != null) _strips[key] = strip;
    return strip;
  }

  void _drawFrame(Canvas canvas, _Strip strip, int frame, Rect dst) {
    final image = strip.image;
    final frameWidth = image.width / strip.frames;
    final height = image.height.toDouble();
    var src = Rect.fromLTWH(frame * frameWidth, 0, frameWidth, height);
    final srcAspect = frameWidth / height;
    final dstAspect = dst.width / dst.height;
    if ((srcAspect / dstAspect - 1).abs() > 0.02) {
      // Centre-crop to the cell so a differently shaped frame is never stretched.
      if (srcAspect > dstAspect) {
        final w = height * dstAspect;
        src = Rect.fromLTWH(src.left + (frameWidth - w) / 2, 0, w, height);
      } else {
        final h = frameWidth / dstAspect;
        src = Rect.fromLTWH(src.left, (height - h) / 2, frameWidth, h);
      }
    }
    canvas.drawImageRect(image, src, dst, _paint);
  }

  void _paintMissing(Canvas canvas, List<Rect> cells, TimelineClipPaint clip) {
    final fill = Paint()..color = clip.style.videoFill;
    final line = Paint()..color = clip.style.laneBackground.withAlpha(0x59);
    for (final c in cells) {
      canvas.drawRect(c, fill);
      canvas.drawRect(Rect.fromLTWH(c.left, c.top, 1, c.height), line);
    }
  }

  // ---------------------------------------------------------------------------------------------
  // Requests
  // ---------------------------------------------------------------------------------------------

  void _prefetchAround(_Plan plan, int lowTile, int highTile, {required bool deferred}) {
    final maxTile = _lastTile(plan);
    final lo = math.max(0, lowTile - prefetchTilesAround);
    final hi = math.min(maxTile, highTile + prefetchTilesAround);
    for (var tile = lo; tile <= hi; tile++) {
      final key = plan.key(tile);
      if (_strips.containsKey(key)) continue;
      _want(key, _requestOf(plan, tile), ThumbPriority.prefetch, deferred: deferred);
    }
  }

  int _lastTile(_Plan plan) {
    final item = plan.item;
    final intervalUs = plan.intervalMs * 1000;
    final a = _frameOf(plan.sourceAt(item.start), intervalUs);
    final b = _frameOf(plan.sourceAt(item.end - 1), intervalUs);
    return math.max(a, b) ~/ framesPerTile;
  }

  /// Registers interest in [key] in the current pass; starts a request unless one exists, the
  /// tile failed recently or a fling is fast.
  void _want(ThumbnailKey key, ThumbnailRequest request, ThumbPriority priority, {required bool deferred}) {
    if (_strips.containsKey(key)) return;
    final existing = _jobs[key];
    if (existing != null) {
      existing.pass = _pass;
      if (priority.index < existing.priority.index) existing.priority = priority;
      if (existing.state == _JobState.waiting) _pump();
      return;
    }
    final failedAt = _failed[key];
    if (failedAt != null) {
      if (_now().difference(failedAt) < retryDelay) return;
      _failed.remove(key);
    }
    if (deferred) {
      deferredCount++;
      return;
    }
    final job = _Job(key, request, priority, _pass)..sequence = _sequence++;
    _jobs[key] = job;
    _pump();
  }

  /// Starts waiting jobs by priority (FIFO inside a priority), pre-empting a running lower
  /// priority request when every slot is taken.
  void _pump() {
    if (_disposed) return;
    while (true) {
      _Job? best;
      var running = 0;
      _Job? worst;
      for (final j in _jobs.values) {
        if (j.state == _JobState.requesting) {
          running++;
          if (worst == null || j.priority.index > worst.priority.index || (j.priority == worst.priority && j.sequence > worst.sequence)) worst = j;
        } else if (j.state == _JobState.waiting) {
          if (best == null || j.priority.index < best.priority.index || (j.priority == best.priority && j.sequence < best.sequence)) best = j;
        }
      }
      if (best == null) return;
      if (running < maxInFlight) {
        _start(best);
        continue;
      }
      if (worst != null && worst.priority.index > best.priority.index) {
        // Pre-empt: the running prefetch request goes back to waiting.
        worst.handle?.cancel();
        worst.handle = null;
        worst.state = _JobState.waiting;
        cancelledCount++;
        _start(best);
        continue;
      }
      return;
    }
  }

  void _start(_Job job) {
    job.state = _JobState.requesting;
    requestedCount++;
    final ThumbnailHandle handle;
    try {
      handle = _source.request(job.request, priority: job.priority);
    } catch (_) {
      _jobs.remove(job.key);
      _fail(job.key);
      return;
    }
    job.handle = handle;
    handle.result.then<void>((tile) => _arrived(job, handle, tile), onError: (Object e) => _onRequestError(job, handle, e));
  }

  Future<void> _arrived(_Job job, ThumbnailHandle handle, ThumbnailTile tile) async {
    if (_disposed || !identical(job.handle, handle) || _jobs[job.key] != job) return;
    job.state = _JobState.decoding;
    job.handle = null;
    _pump();
    ui.Image image;
    try {
      image = await _decoder(tile.encoded);
    } catch (_) {
      _jobs.remove(job.key);
      _fail(job.key);
      _pump();
      return;
    }
    if (_disposed) {
      image.dispose();
      return;
    }
    _jobs.remove(job.key);
    _insert(job.key, _Strip(image, math.max(1, tile.frames)));
    _changes.notify();
    _pump();
  }

  void _onRequestError(_Job job, ThumbnailHandle handle, Object error) {
    if (_disposed || !identical(job.handle, handle) || _jobs[job.key] != job) return;
    _jobs.remove(job.key);
    if (error is! EngineCancelled) _fail(job.key);
    _pump();
  }

  void _fail(ThumbnailKey key) {
    failedCount++;
    _failed[key] = _now();
  }

  /// Cancels and forgets [job] (it was not touched in the last paint pass, or memory pressure).
  void _drop(_Job job) {
    if (job.state == _JobState.requesting) job.handle?.cancel();
    if (job.state != _JobState.decoding) cancelledCount++;
    job.handle = null;
    _jobs.remove(job.key);
  }

  // ---------------------------------------------------------------------------------------------
  // LRU
  // ---------------------------------------------------------------------------------------------

  void _insert(ThumbnailKey key, _Strip strip) {
    final old = _strips.remove(key);
    if (old != null) {
      _bytes -= old.bytes;
      old.image.dispose();
    }
    _strips[key] = strip;
    _bytes += strip.bytes;
    _trimTo(budgetBytes, keep: key);
  }

  void _trimTo(int limit, {ThumbnailKey? keep}) {
    if (_bytes <= limit) return;
    for (final key in _strips.keys.toList()) {
      if (_bytes <= limit) return;
      if (key != keep) _evict(key);
    }
  }

  void _evict(ThumbnailKey key) {
    final strip = _strips.remove(key);
    if (strip == null) return;
    _bytes -= strip.bytes;
    strip.image.dispose();
  }

  @override
  String toString() => 'ThumbnailCache(${_strips.length} strips, ${_bytes ~/ 1024} KB of ${budgetBytes ~/ 1024} KB, '
      '$inFlightCount running, $waitingCount waiting)';
}

// -------------------------------------------------------------------------------------------------
// Provider
// -------------------------------------------------------------------------------------------------

/// The resolver over an editing session: the file the session's plan compiler resolves for a pool
/// media (the original). The proxy is not offered by the session yet, so strips come from the
/// original until it is (the cache already takes the proxy path when [ThumbnailMediaResolver]
/// returns one for `proxy: true`).
ThumbnailMediaResolver sessionThumbnailResolver(EditorSession session) => (id, {required proxy}) {
      if (proxy) return null;
      final project = session.project;
      final compiler = session.compiler;
      if (project == null || compiler == null) return null;
      return compiler.resolve(project, id);
    };

/// The thumbnail cache of an open project (ux.md §17.3): over `engine.thumbnails`, 48 MB on
/// `lowMemoryDevice` and 96 MB otherwise, trimmed on the engine's memory warning and on the
/// system's. Disposed with the project (pending requests are cancelled).
///
/// Wire it into the timeline with `timelineContentHooksProvider` (UX-12):
/// `TimelineContentHooks(thumbnails: ref.watch(thumbnailCacheProvider(id)), ...)`.
final thumbnailCacheProvider = Provider.autoDispose.family<ThumbnailCache, ProjectId>(
  (ref, id) {
    final engine = ref.watch(editorEngineProvider);
    final session = ref.watch(editorSessionProvider(id));
    final low = ref.read(editorCapabilitiesProvider).valueOrNull?.lowMemoryDevice ?? false;
    final cache = ThumbnailCache(source: engine.thumbnails, resolve: sessionThumbnailResolver(session), lowMemoryDevice: low);
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
  name: 'thumbnailCacheProvider',
);

final class _MemoryPressureObserver with WidgetsBindingObserver {
  _MemoryPressureObserver(this.onPressure);

  final void Function() onPressure;

  @override
  void didHaveMemoryPressure() => onPressure();
}
