// OWNER: API-04
//
// Export sprite pre-pass (ARCH §10.3, §14.1 step 4 "Preparing"): turns CORE-31's
// `collectSpriteRequests` output into `.vsprite` files under `<cache>/vwish/editor/sprites/` and
// returns the `SpriteManifest` that `compileExport` (CORE-33) consumes.
//
// * **Content-addressed reuse.** `<dir>/<key>.vsprite` whose header is valid (and carries a glyph
//   map when the request needs one) is reused without rasterizing (a header-only read). Duplicate
//   keys in one run are rasterized once.
// * **Files** go through core's `StoreFs` (`LocalStoreFs` by default): this package has no
//   `dart:io`. Writes are atomic: `<key>.vsprite.tmp-<n>` written and synced, then renamed.
// * **UI slices.** Layout and picture recording (the only UI-isolate work) run in slices of at
//   most [SpritePrepass.sliceBudget] (4 ms) and at most [SpritePrepass.maxBatch] sprites: a
//   slice stops before the next sprite would exceed the budget (predicted by the costliest of the
//   last 8 sprites), so only a sprite slower than predicted can overrun it; the pre-pass
//   yields to the event loop between slices. Rasterization runs on the raster thread; glyph
//   maps and `.vsprite` encoding (zlib) run in `Isolate.run`, one isolate per batch, pipelined
//   with the next batch's layout; file writes are asynchronous I/O.
// * **Progress** is reported as the fraction of unique keys done (reused or written), from 0 to 1.
// * **Cancel**: `isCancelled` is polled between slices; a cancelled run throws
//   [SpritePrepassCancelled] (files already written stay valid cache entries).

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:vwish_editor_core/plan.dart';
import 'package:vwish_editor_core/store.dart' show LocalStoreFs, StoreFailure, StoreFs;

import 'text_sprite_rasterizer.dart';
import 'vsprite_codec.dart';

/// Thrown by [SpritePrepass.run] when cancelled (ARCH §14.1).
final class SpritePrepassCancelled implements Exception {
  /// Creates the exception.
  const SpritePrepassCancelled();

  @override
  String toString() => 'SpritePrepassCancelled';
}

/// Timing and counts of the last [SpritePrepass.run] (ARCH §14.1, §24.2 V-D7; QA-04, tests).
final class SpritePrepassStats {
  /// Requests passed in.
  int requested = 0;

  /// Distinct keys.
  int unique = 0;

  /// Keys served from the cache.
  int reused = 0;

  /// Keys rasterized and written.
  int rasterized = 0;

  /// Duration of every synchronous UI-isolate slice, in µs.
  final List<int> sliceMicros = [];

  /// Wall time of the run.
  Duration elapsed = Duration.zero;

  /// The longest UI slice in µs (0 without slices).
  int get maxSliceMicros => sliceMicros.isEmpty ? 0 : sliceMicros.reduce((a, b) => a > b ? a : b);
}

/// Rasterizes missing text sprites before an export (file header; ARCH §14.1, API-04).
class SpritePrepass {
  /// Creates the pre-pass. [maxTextureSize] is `EditorCapabilities.maxTextureSize`; [yieldToUi]
  /// is awaited between slices (default: one event-loop turn); [clockMicros] times the UI slices
  /// (default: a monotonic stopwatch; tests inject a fake).
  SpritePrepass({
    TextSpriteRasterizer? rasterizer,
    this.maxTextureSize = defaultMaxTextureSize,
    this.sliceBudget = const Duration(milliseconds: 4),
    this.maxBatch = 8,
    Future<void> Function()? yieldToUi,
    int Function()? clockMicros,
    this.fs = const LocalStoreFs(),
  })  : rasterizer = rasterizer ?? TextSpriteRasterizer(),
        _yield = yieldToUi ?? (() => Future<void>.delayed(Duration.zero)),
        _clock = clockMicros ?? _wallMicros;

  static final Stopwatch _wall = Stopwatch()..start();
  static int _wallMicros() => _wall.elapsedMicroseconds;

  /// The rasterizer (and through it the layout engine).
  final TextSpriteRasterizer rasterizer;

  /// File access (core `StoreFs`).
  final StoreFs fs;

  int _tmpSeq = 0;

  /// `EditorCapabilities.maxTextureSize`.
  final int maxTextureSize;

  /// Budget of one UI slice.
  final Duration sliceBudget;

  /// Most sprites prepared in one slice.
  final int maxBatch;

  final Future<void> Function() _yield;

  /// Monotonic µs used to time UI slices (injectable for tests).
  final int Function() _clock;

  /// Costs of preparing the last sprites on the UI isolate, in µs.
  final List<int> _recentMicros = [];

  int _predictMicros() => _recentMicros.isEmpty ? 1000 : _recentMicros.reduce((a, b) => a > b ? a : b);

  /// Stats of the last run.
  SpritePrepassStats stats = SpritePrepassStats();

  /// The sprite directory under the editor cache root (`EditorEngineConfig.cacheRoot`,
  /// `<cache>/vwish/editor`).
  static String spritesDirOf(String editorCacheRoot) => '$editorCacheRoot/sprites';

  /// The file of [key] in [dir] (POSIX paths: iOS and Android).
  static String pathOf(String dir, String key) => '$dir/$key.vsprite';

  /// The `file://` URI of [path].
  static String uriOf(String path) => Uri.file(path).toString();

  /// Reads the cached sprite of [key] in [dir], or null when it is missing, invalid or lacks a
  /// glyph map that [needReveal] requires.
  Future<SpriteFile?> cachedFile(String dir, String key, {bool needReveal = false}) async {
    final path = pathOf(dir, key);
    try {
      final h = VspriteCodec.readHeader(await fs.readPrefix(path, VspriteCodec.headerBytes));
      if (needReveal && !h.hasReveal) return null;
      return SpriteFile(uri: uriOf(path), sw: h.width, sh: h.height, sscale: h.scale, reveal: h.hasReveal);
    } on StoreFailure {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<void> _writeAtomic(String path, Uint8List bytes) async {
    final tmp = '$path.tmp-${DateTime.now().microsecondsSinceEpoch}-${_tmpSeq++}';
    try {
      await fs.writeBytesSynced(tmp, bytes);
      await fs.rename(tmp, path);
    } catch (_) {
      await fs.delete(tmp).catchError((Object _) {});
      rethrow;
    }
  }

  /// Rasterizes the missing sprites of [requests] into [cacheDir] (the sprites directory, see
  /// [spritesDirOf]) and returns the manifest of every request's key.
  Future<SpriteManifest> run(
    List<SpriteRequest> requests, {
    required String cacheDir,
    void Function(double fraction)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final watch = Stopwatch()..start();
    final st = stats = SpritePrepassStats()..requested = requests.length;
    final unique = <String, SpriteRequest>{};
    for (final r in requests) {
      final prev = unique[r.key];
      // A reveal request needs the glyph map: prefer it when keys collide (they cannot by
      // construction, the key includes `reveal`, but stay safe).
      if (prev == null || (!prev.reveal && r.reveal)) unique[r.key] = r;
    }
    st.unique = unique.length;
    final files = <String, SpriteFile>{};
    var done = 0;
    void progress() => onProgress?.call(unique.isEmpty ? 1 : done / unique.length);
    void checkCancel() {
      if (isCancelled?.call() ?? false) throw const SpritePrepassCancelled();
    }

    progress();
    await fs.createDirectory(cacheDir);

    // Reuse.
    final missing = <SpriteRequest>[];
    for (final r in unique.values) {
      final f = await cachedFile(cacheDir, r.key, needReveal: r.reveal);
      if (f == null) {
        missing.add(r);
        continue;
      }
      files[r.key] = f;
      st.reused++;
      done++;
    }
    progress();

    // Rasterize: slice → render → encode/write (pipelined, ≤ 2 batches encoding).
    final writes = <Future<void>>[];
    var next = 0;
    while (next < missing.length) {
      if (isCancelled?.call() ?? false) {
        // Let in-flight writes finish so no file is being written after run() returns.
        await Future.wait(writes);
        throw const SpritePrepassCancelled();
      }
      final sliceStart = _clock();
      final batch = <PreparedSprite>[];
      try {
        // Stop before the next sprite would exceed the budget (predicted by the costliest of the
        // last 8 sprites).
        while (next < missing.length &&
            batch.length < maxBatch &&
            (batch.isEmpty || _clock() - sliceStart + _predictMicros() <= sliceBudget.inMicroseconds)) {
          final t0 = _clock();
          batch.add(rasterizer.prepare(missing[next], maxTextureSize: maxTextureSize));
          next++;
          _recentMicros.add(_clock() - t0);
          if (_recentMicros.length > 8) _recentMicros.removeAt(0);
        }
      } catch (_) {
        for (final p in batch) {
          p.dispose();
        }
        rethrow;
      }
      st.sliceMicros.add(_clock() - sliceStart);
      final rgbas = await Future.wait([for (final p in batch) p.renderRgba()]);
      final jobs = [
        for (var i = 0; i < batch.length; i++)
          _WriteJob(
            path: pathOf(cacheDir, batch[i].request.key),
            width: batch[i].width,
            height: batch[i].height,
            scale: batch[i].scale,
            rgba: rgbas[i],
            strips: batch[i].request.reveal ? batch[i].strips : null,
          ),
      ];
      final prepared = List.of(batch);
      writes.add(_encodeInIsolate(jobs).then((encoded) async {
        for (var i = 0; i < jobs.length; i++) {
          await _writeAtomic(jobs[i].path, encoded[i]);
        }
        for (var i = 0; i < prepared.length; i++) {
          final p = prepared[i];
          files[p.request.key] =
              SpriteFile(uri: uriOf(jobs[i].path), sw: p.width, sh: p.height, sscale: p.scale, reveal: p.request.reveal);
          st.rasterized++;
          done++;
        }
        progress();
      }));
      if (writes.length >= 2) await writes.removeAt(0);
      await _yield();
    }
    await Future.wait(writes);
    checkCancel();
    st.elapsed = watch.elapsed;
    return SpriteManifest({for (final r in requests) r.key: files[r.key]!});
  }
}

final class _WriteJob {
  _WriteJob({required this.path, required this.width, required this.height, required this.scale, required this.rgba, this.strips});
  final String path;
  final int width;
  final int height;
  final double scale;
  final Uint8List rgba;
  final Float64List? strips;
}

/// Runs [_encodeAll] in an isolate. A top-level function, so the closure captures only [jobs]
/// (closures created inside `run` share a context holding unsendable `ui.Picture`s).
Future<List<Uint8List>> _encodeInIsolate(List<_WriteJob> jobs) =>
    Isolate.run(() => _encodeAll(jobs), debugName: 'vwish.sprite.encode');

/// Isolate body: glyph maps and `.vsprite` encoding (the result is transferred, not copied).
List<Uint8List> _encodeAll(List<_WriteJob> jobs) => [
      for (final j in jobs)
        VspriteCodec.encodeSync(VspriteImage(
          width: j.width,
          height: j.height,
          scale: j.scale,
          rgba: j.rgba,
          glyphs: j.strips == null ? null : glyphMapOf(j.rgba, j.width, j.height, j.strips!),
        )),
    ];
