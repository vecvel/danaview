// OWNER: HOM-04
//
// The thumbnail service of the Files & Media Home (ARCH v1.2 V2-28, V2-104; BUILD_PLAN HOM-04):
// one cache for the library, documents and the Home grid with three tiers — the 64 MB memory LRU
// of decoded images, the disk cache keyed by item id + modification time + size class, and the
// native thumbnailers (PhotoKit / Quick Look on Apple, MediaStore / ThumbnailUtils on Android).
//
// * Coalescing: every request for one key shares one job; the job runs once.
// * Cancellation: a [ThumbHandle] is cancelled when its cell leaves the viewport; a job whose
//   handles are all cancelled leaves the queue, or has its native request cancelled when running.
// * Scheduling: at most [maxConcurrent] jobs run; the queue is newest-first, so after a fling the
//   cells now on screen are served before the ones flung past.
// * Failures (corrupt file, unsupported source, iCloud-only asset) are remembered for the session,
//   so a cell scrolling back does not ask again; the cell shows its type icon.
// * Format fallback: a freshly generated non-JPEG thumbnail (HEIC) that the engine cannot decode
//   is regenerated as JPEG, and the session asks JPEG from then on (V2-28).
// * Prefetch: [updatePrefetch] moves the native window (`PHCachingImageManager`) for `ph:` items.
//
// Nothing here logs ids, names or paths (rule 30).

import 'dart:async';
import 'dart:collection';
import 'dart:io' show File;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'package:danaview_library_native/danaview_library_native.dart';

import 'thumb_disk_cache.dart';
import 'thumb_key.dart';
import 'thumb_memory_cache.dart';

/// Decodes an encoded thumbnail file.
abstract interface class ThumbDecoder {
  /// The decoded image of the file at [path]; throws when it does not decode.
  Future<ThumbBitmap> decode(String path);
}

/// The `dart:ui` decoder (the engine sniffs JPEG, PNG, WebP, and HEIC where the platform codec
/// has it).
final class UiThumbDecoder implements ThumbDecoder {
  /// The decoder.
  const UiThumbDecoder();

  @override
  Future<ThumbBitmap> decode(String path) async {
    final bytes = await File(path).readAsBytes();
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final codec = await ui.instantiateImageCodecFromBuffer(buffer);
    try {
      final frame = await codec.getNextFrame();
      return UiThumbBitmap(frame.image);
    } finally {
      codec.dispose();
    }
  }
}

/// The format the disk cache stores on [platform] (V2-28): WebP on Android, HEIC on iOS (the
/// platform writes JPEG before iOS 17), JPEG elsewhere.
///
/// V2-28's [VERIFY: HOM-04] for iOS: `test/v12/thumbs/heic_decode_ios_check.dart` asks the real
/// Apple thumbnailer for a HEIC and decodes it through [UiThumbDecoder] on a hosted iOS Simulator;
/// it passed on iOS 26.5 (iPhone 16, Flutter 3.44, 2026-10-22: HEIC written, decoded 384 x 384).
/// Should an engine still fail to read a HEIC, [ThumbnailService] regenerates it as JPEG and asks
/// JPEG for the rest of the session instead of failing the thumbnail.
NativeThumbnailFormat thumbnailFormatFor(TargetPlatform platform) => switch (platform) {
      TargetPlatform.android => NativeThumbnailFormat.webp,
      TargetPlatform.iOS => NativeThumbnailFormat.heic,
      _ => NativeThumbnailFormat.jpeg,
    };

/// A caller's interest in one thumbnail. Cancel it when the cell goes away.
final class ThumbHandle {
  ThumbHandle._(this._job);

  /// A handle that is already complete with [bitmap] (a memory hit or a known failure).
  ThumbHandle._done(ThumbBitmap? bitmap) : _job = null {
    _completer.complete(bitmap?.clone());
  }

  final _ThumbJob? _job;
  final Completer<ThumbBitmap?> _completer = Completer<ThumbBitmap?>();
  bool _cancelled = false;

  /// A clone of the decoded thumbnail the caller owns (dispose it), or null on failure or cancel.
  Future<ThumbBitmap?> get result => _completer.future;

  /// True after [cancel].
  bool get isCancelled => _cancelled;

  /// Drops the interest; [result] completes with null if it has not completed.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _job?.detach(this);
    if (!_completer.isCompleted) _completer.complete(null);
  }

  void _deliver(ThumbBitmap? b) {
    if (_completer.isCompleted) return;
    _completer.complete(_cancelled ? null : b?.clone());
  }
}

enum _JobState { queued, running, done }

final class _ThumbJob {
  _ThumbJob(this.service, this.request);

  final ThumbnailService service;
  final ThumbRequest request;
  final List<ThumbHandle> handles = [];
  _JobState state = _JobState.queued;
  String? nativeRequestId;
  bool cancelled = false;

  ThumbKey get key => request.key;

  void attach(ThumbHandle h) => handles.add(h);

  void detach(ThumbHandle h) {
    handles.remove(h);
    if (handles.isEmpty && state != _JobState.done) service._abandon(this);
  }
}

/// Counters for tests and the performance report (HOM-14).
final class ThumbnailStats {
  /// Memory hits.
  int memoryHits = 0;

  /// Disk hits (decoded without the platform).
  int diskHits = 0;

  /// Thumbnails generated by the platform.
  int generated = 0;

  /// Jobs dropped from the queue before they ran.
  int dequeued = 0;

  /// Native requests cancelled while running.
  int nativeCancels = 0;

  /// Requests that joined a running or queued job.
  int coalesced = 0;

  /// Failures remembered for the session.
  int failures = 0;

  /// Freshly generated thumbnails that did not decode in the requested format and were
  /// regenerated as JPEG.
  int jpegFallbacks = 0;
}

/// The thumbnail cache of the Home.
final class ThumbnailService {
  /// A service over [disk] and [generator]. [format] defaults to the platform's (V2-28).
  ThumbnailService({
    required this.disk,
    required this.generator,
    ThumbDecoder decoder = const UiThumbDecoder(),
    ThumbMemoryCache? memory,
    this.maxConcurrent = 4,
    NativeThumbnailFormat? format,
    this.quality = 0.8,
  })  : _decoder = decoder,
        memory = memory ?? ThumbMemoryCache(),
        format = format ?? thumbnailFormatFor(defaultTargetPlatform),
        assert(maxConcurrent > 0);

  /// The disk tier.
  final ThumbDiskCache disk;

  /// The platform thumbnailers.
  final ThumbnailGenerator generator;

  /// The memory tier (64 MB).
  final ThumbMemoryCache memory;

  /// Jobs running at once.
  final int maxConcurrent;

  /// Format requested from the platform (until a fallback, see [effectiveFormat]).
  final NativeThumbnailFormat format;

  /// The format requested now: [format], or JPEG for the rest of the session once a freshly
  /// generated thumbnail in [format] did not decode here (V2-28: HEIC the engine can't read).
  NativeThumbnailFormat get effectiveFormat => _jpegOnly ? NativeThumbnailFormat.jpeg : format;

  /// Encoder quality.
  final double quality;

  final ThumbDecoder _decoder;
  final Map<ThumbKey, _ThumbJob> _jobs = {};
  final ListQueue<_ThumbJob> _queue = ListQueue<_ThumbJob>();
  final Set<ThumbKey> _failed = {};
  int _running = 0;
  int _ids = 0;
  bool _disposed = false;
  bool _jpegOnly = false;

  /// Counters.
  final ThumbnailStats stats = ThumbnailStats();

  /// Jobs waiting.
  int get queued => _queue.length;

  /// Jobs running.
  int get running => _running;

  /// The cached thumbnail of [request] without loading anything (a clone the caller disposes), or
  /// null. Lets a cell paint in its first frame.
  ThumbBitmap? peek(ThumbRequest request) => memory.get(request.key)?.clone();

  /// True when [request] failed earlier in this session (show the type icon).
  bool hasFailed(ThumbRequest request) => _failed.contains(request.key);

  /// Loads [request] through the tiers.
  ThumbHandle load(ThumbRequest request) {
    final key = request.key;
    final hit = memory.get(key);
    if (hit != null) {
      stats.memoryHits++;
      return ThumbHandle._done(hit);
    }
    if (_disposed || _failed.contains(key)) return ThumbHandle._done(null);
    var job = _jobs[key];
    // A running job whose callers all left is finishing as cancelled; start a fresh one.
    if (job != null && job.cancelled) job = null;
    if (job != null) {
      stats.coalesced++;
      if (job.state == _JobState.queued) {
        // Most recent interest first: move it to the front of the line.
        _queue.remove(job);
        _queue.addLast(job);
      }
    } else {
      job = _ThumbJob(this, request);
      _jobs[key] = job;
      _queue.addLast(job);
    }
    final handle = ThumbHandle._(job);
    job.attach(handle);
    _pump();
    return handle;
  }

  /// Moves the native prefetch window: [entering] items came near the viewport, [leaving] went
  /// away. Only system assets (`ph:`) are prefetched; errors are ignored.
  Future<void> updatePrefetch({
    required Iterable<ThumbRequest> entering,
    required Iterable<ThumbRequest> leaving,
    required ThumbSizeClass sizeClass,
  }) async {
    final start = [for (final r in entering) if (r.source.startsWith('ph:')) r.source];
    final stop = [for (final r in leaving) if (r.source.startsWith('ph:')) r.source];
    if (start.isEmpty && stop.isEmpty) return;
    try {
      await generator.updateCaching(start: start, stop: stop, width: sizeClass.pixels, height: sizeClass.pixels, mode: sizeClass.mode);
    } on LibraryNativeException {
      // Prefetch is an optimisation; desktop and Android have none.
    }
  }

  /// Forgets everything held for [itemId] (it was deleted or replaced).
  void forgetItem(String itemId) {
    memory.removeItem(itemId);
    _failed.removeWhere((k) => k.itemId == itemId);
  }

  /// Drops the memory tier (memory pressure).
  void trimMemory() => memory.clear();

  /// Cancels everything and releases the memory tier.
  void dispose() {
    _disposed = true;
    for (final job in _jobs.values.toList()) {
      for (final h in job.handles.toList()) {
        h.cancel();
      }
    }
    _queue.clear();
    memory.clear();
  }

  void _abandon(_ThumbJob job) {
    if (job.state == _JobState.queued) {
      _queue.remove(job);
      if (identical(_jobs[job.key], job)) _jobs.remove(job.key);
      job.state = _JobState.done;
      stats.dequeued++;
      return;
    }
    if (job.state == _JobState.running && !job.cancelled) {
      job.cancelled = true;
      final id = job.nativeRequestId;
      if (id != null) {
        stats.nativeCancels++;
        unawaited(generator.cancel(id).catchError((Object _) {}));
      }
    }
  }

  void _pump() {
    while (_running < maxConcurrent && _queue.isNotEmpty && !_disposed) {
      final job = _queue.removeLast();
      job.state = _JobState.running;
      _running++;
      unawaited(_run(job));
    }
  }

  Future<void> _run(_ThumbJob job) async {
    ThumbBitmap? bitmap;
    try {
      bitmap = await _produce(job);
    } on Object {
      bitmap = null;
    } finally {
      _running--;
      job.state = _JobState.done;
      if (identical(_jobs[job.key], job)) _jobs.remove(job.key);
    }
    if (bitmap != null && _disposed) {
      bitmap.dispose();
      bitmap = null;
    }
    // Callers get their clones first; then the cache owns the decoded image (it may dispose it
    // at once when it alone exceeds the budget).
    for (final h in job.handles.toList()) {
      h._deliver(bitmap);
    }
    job.handles.clear();
    if (bitmap != null) memory.put(job.key, bitmap);
    _pump();
  }

  /// Disk hit or platform generation, then decode. Null when cancelled or failed.
  Future<ThumbBitmap?> _produce(_ThumbJob job) async {
    final key = job.key;
    final cached = await disk.lookup(key);
    if (job.cancelled) return null;
    if (cached != null) {
      try {
        final b = await _decoder.decode(cached);
        stats.diskHits++;
        return b;
      } on Object {
        // A damaged cache file: drop it and generate again.
        await disk.evict(key);
      }
    }
    if (job.cancelled) return null;
    final out = await _generate(job, effectiveFormat);
    if (out == null || job.cancelled) return null;
    try {
      return await _decoder.decode(out.path);
    } on Object {
      await disk.evict(key);
      // The engine could not read what the platform wrote (V2-28: HEIC on an engine without a
      // HEIC codec). Ask JPEG from now on and regenerate this one instead of failing it.
      if (out.format == NativeThumbnailFormat.jpeg) {
        _fail(key);
        return null;
      }
      _jpegOnly = true;
      stats.jpegFallbacks++;
      if (job.cancelled) return null;
      final again = await _generate(job, NativeThumbnailFormat.jpeg);
      if (again == null || job.cancelled) return null;
      try {
        return await _decoder.decode(again.path);
      } on Object {
        await disk.evict(key);
        _fail(key);
        return null;
      }
    }
  }

  /// Asks the platform for [job]'s thumbnail in [fmt] and commits it to the disk tier. Null when
  /// cancelled or failed (failures other than cancel / busy are remembered).
  Future<({String path, NativeThumbnailFormat format})?> _generate(_ThumbJob job, NativeThumbnailFormat fmt) async {
    final key = job.key;
    final part = await disk.partPathFor(key);
    final id = 'th-${++_ids}';
    job.nativeRequestId = id;
    final r = job.request;
    try {
      final NativeThumbnail? out;
      if (r.kind == ThumbSourceKind.document) {
        out = await generator.documentThumbnail(
          requestId: id,
          path: r.source,
          width: r.sizeClass.pixels,
          height: r.sizeClass.pixels,
          outputPath: part,
          // Screen pixels per PDF point (the DPR the cell asked at), bounded by the class's box.
          scale: key.scale,
          format: fmt,
          quality: quality,
        );
      } else {
        out = await generator.mediaThumbnail(
          requestId: id,
          source: r.source,
          width: r.sizeClass.pixels,
          height: r.sizeClass.pixels,
          outputPath: part,
          mode: r.sizeClass.mode,
          format: fmt,
          quality: quality,
        );
      }
      if (job.cancelled) {
        await disk.discard(part);
        return null;
      }
      if (out == null) {
        await disk.discard(part);
        _fail(key);
        return null;
      }
      final path = await disk.commit(key, part);
      stats.generated++;
      return (path: path, format: out.format);
    } on LibraryNativeException catch (e) {
      await disk.discard(part);
      if (e.code != LibraryNativeErrorCode.cancelled && e.code != LibraryNativeErrorCode.busy) _fail(key);
      return null;
    } on Object {
      await disk.discard(part);
      await disk.evict(key);
      _fail(key);
      return null;
    }
  }

  void _fail(ThumbKey key) {
    _failed.add(key);
    stats.failures++;
  }
}
