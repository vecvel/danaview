// OWNER: INT-02
//
// The app's RenderPlan compiler (ARCH §11.7, §11.8, §9.5, §10.2): UX-08's `PlanCompilerPort` over
// API-02's `PreviewPlanCompiler` (core `PlanMemo`, `compilePlan` in `Isolate.run` above 300 items)
// and core `transientFor`, with an asset resolver over the session pool, proxies and availability.
//
// * The compiler is pure and may run in an isolate, so it needs a synchronous, sendable
//   `PlanAssetResolver`. [SessionAssetResolver] resolves everything the project references
//   **before** each compile (`MediaAccessPort.resolve` for originals, the proxy folder for ready
//   proxies, `.vlut` headers for looks and imported LUTs) and publishes a plain
//   `MapPlanAssetResolver` snapshot that gesture transients and poster requests read synchronously.
// * Resolutions are cached per (media id, locator, status, fingerprint): a relink changes the
//   locator and re-resolves; a derived asset (freeze still, reversed rendition) that turns from
//   pending to ready, or is produced again, re-resolves at once (FIX-INT-02-2: its file did not exist
//   while pending, and the cached miss used to hide the finished still). Any other failed resolve is
//   retried only when the availability report changes (CORE-28 refreshes it on app resume and after
//   relink), so a missing file does not cost a platform call per commit.
// * Availability (CORE-28 `AvailabilityMonitor.last`): missing, access-lost, changed and
//   derived-missing media are offline in the plan (the compiler emits the placeholder and lists the
//   id in `req.offline`).
// * Proxies live in `<cache>/danaview/editor/proxies/<quickHash>-540.mp4` (ARCH §9.5); the resolver
//   offers one only when the pool says it is ready and the file exists. Export plans never use them
//   (the core factory ignores proxies for export targets).
// * Built-in looks are bundled `.vlut` assets extracted on first use to
//   `<cache>/danaview/editor/looks/<presetId>.vlut` (ARCH §10.2); imported LUTs are the `.vlut` written
//   next to the imported `.cube` (CORE-27).

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:path/path.dart' as p;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show EditSession;
import 'package:danaview_editor_core/plan.dart' show MapPlanAssetResolver, ResolvedLut;
import 'package:danaview_editor_core/store.dart'
    show ManagedStore, MediaAvailability, MediaAvailabilityReport, StoreRoots;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show EditorCapabilities, EngineMedia, PlanTransient, RenderPlan;

import 'plan_compiler_port.dart';

/// The latest availability report of a session (CORE-28 `MediaRelinkService.monitorOf(s).last`),
/// or null when none was taken yet (everything is then assumed available).
typedef SessionAvailabilityLookup = MediaAvailabilityReport? Function(EditSession session);

/// Resolves the `.vlut` of a bundled look, or null when the look is unknown.
typedef BuiltinLookSource = Future<ResolvedLut?> Function(String presetId);

/// Reads the table size N of the `.vlut` at an absolute path, or null when it is missing or invalid.
typedef VlutSizeReader = Future<int?> Function(String path);

/// Whether a file exists at an absolute path.
typedef FileExistsProbe = Future<bool> Function(String path);

/// The app's [PlanCompilerPort] (INT-02).
///
/// See ARCH §11.7, §11.8.
final class DefaultPlanCompiler implements PlanCompilerPort {
  /// Creates the port. [access] resolves pool locators for the engine (the engine's
  /// `MediaAccess`); [roots] locate proxies and imported LUTs; [availability] supplies CORE-28's
  /// latest report per session; [looks] resolves bundled looks (default: [BundledLookFiles] over
  /// `rootBundle`); [readVlutSize] and [exists] are for tests.
  DefaultPlanCompiler({
    required this.access,
    required this.roots,
    this.availability,
    BuiltinLookSource? looks,
    this.readVlutSize = readVlutTableSize,
    this.exists = _fileExists,
    this.isolateThreshold = 300,
  }) : looks = looks ?? BundledLookFiles(roots: roots).resolve;

  /// The platform media access (`EditorEngine.access`).
  final MediaAccessPort access;

  /// App roots.
  final StoreRoots roots;

  /// CORE-28's latest availability report of a session.
  final SessionAvailabilityLookup? availability;

  /// Bundled looks.
  final BuiltinLookSource looks;

  /// `.vlut` header reader.
  final VlutSizeReader readVlutSize;

  /// File existence probe (proxies).
  final FileExistsProbe exists;

  /// Item count above which a cold compile runs in an isolate.
  final int isolateThreshold;

  @override
  SessionPlanCompiler forSession(EditSession session, EditorCapabilities capabilities) => DefaultSessionPlanCompiler(
        SessionAssetResolver(
          access: access,
          roots: roots,
          availability: availability == null ? null : () => availability!(session),
          looks: looks,
          readVlutSize: readVlutSize,
          exists: exists,
        ),
        holdFrame: capabilities.holdFrame,
        maxAudioSpeed: capabilities.maxAudioSpeed,
        isolateThreshold: isolateThreshold,
      );

  static Future<bool> _fileExists(String path) => File(path).exists();
}

/// The compiler of one session: refreshes [assets] before every compile, then compiles through
/// [ResolvingSessionPlanCompiler] (memo, isolate above the threshold, core `transientFor`).
///
/// See ARCH §11.7, §11.8.
final class DefaultSessionPlanCompiler implements SessionPlanCompiler {
  /// Creates the compiler over [assets].
  DefaultSessionPlanCompiler(
    this.assets, {
    bool holdFrame = true,
    double maxAudioSpeed = 4,
    int isolateThreshold = 300,
  }) : _inner = ResolvingSessionPlanCompiler(
          (_) => assets.current,
          holdFrame: holdFrame,
          maxAudioSpeed: maxAudioSpeed,
          isolateThreshold: isolateThreshold,
        );

  /// The session's asset resolver.
  final SessionAssetResolver assets;

  final ResolvingSessionPlanCompiler _inner;

  /// Compiles so far.
  int get compiles => _inner.compiles;

  @override
  Future<RenderPlan> compile(EditProject project) async {
    await assets.refresh(project);
    return _inner.compile(project);
  }

  @override
  PlanTransient? transientFor(EditProject working, ItemId item) => _inner.transientFor(working, item);

  @override
  EngineMedia? resolve(EditProject project, MediaId media) => assets.current.original(media);

  @override
  void trim() => _inner.trim();
}

final class _Resolution {
  _Resolution(this.locator, this.status, this.fingerprint, this.media, this.report);

  final MediaLocator locator;

  /// The asset's status and fingerprint when it was resolved (a change re-resolves).
  final AssetStatus status;
  final MediaFingerprint fingerprint;

  final ResolvedMedia? media;

  /// The availability report in force when a failed resolve happened (retry once it changes).
  final MediaAvailabilityReport? report;
}

/// Resolves the assets of one session's project before each compile and publishes a sendable
/// [MapPlanAssetResolver] snapshot ([current]).
///
/// See ARCH §11.7 ("Missing media"), §9.3, §9.5, §10.2.
final class SessionAssetResolver {
  /// Creates the resolver.
  SessionAssetResolver({
    required this.access,
    required this.roots,
    this.availability,
    BuiltinLookSource? looks,
    this.readVlutSize = readVlutTableSize,
    FileExistsProbe? exists,
  })  : looks = looks ?? BundledLookFiles(roots: roots).resolve,
        exists = exists ?? ((path) => File(path).exists());

  /// The platform media access.
  final MediaAccessPort access;

  /// App roots.
  final StoreRoots roots;

  /// The session's latest availability report.
  final MediaAvailabilityReport? Function()? availability;

  /// Bundled looks.
  final BuiltinLookSource looks;

  /// `.vlut` header reader.
  final VlutSizeReader readVlutSize;

  /// File existence probe.
  final FileExistsProbe exists;

  final Map<MediaId, _Resolution> _originals = {};
  final Map<String, ResolvedLut?> _looks = {};
  MapPlanAssetResolver _current = MapPlanAssetResolver.empty;
  Future<MapPlanAssetResolver>? _running;
  EditProject? _again;

  /// Platform resolves performed so far (tests).
  int resolveCalls = 0;

  /// The latest snapshot (every media offline before the first [refresh]).
  MapPlanAssetResolver get current => _current;

  /// The absolute path of the proxy of content [quickHash] (ARCH §9.5).
  String proxyPathOf(String quickHash) => p.join(roots.editorCache, 'proxies', '$quickHash-540.mp4');

  /// Resolves what [project] references and publishes the snapshot. Concurrent calls share one
  /// refresh (the latest project wins).
  Future<MapPlanAssetResolver> refresh(EditProject project) {
    final running = _running;
    if (running != null) {
      _again = project;
      return running;
    }
    return _running = _loop(project).whenComplete(() => _running = null);
  }

  Future<MapPlanAssetResolver> _loop(EditProject project) async {
    var next = project;
    while (true) {
      _current = await _build(next);
      final again = _again;
      _again = null;
      if (again == null || identical(again, next)) return _current;
      next = again;
    }
  }

  Future<MapPlanAssetResolver> _build(EditProject project) async {
    final pool = project.pool;
    final report = availability?.call();
    final originals = <MediaId, ResolvedMedia>{};
    final proxies = <MediaId, ResolvedMedia>{};
    final luts = <MediaId, ResolvedLut>{};

    _originals.removeWhere((id, _) => !pool.contains(id));
    for (final asset in pool.assets.values) {
      if (_offline(report?.byMedia[asset.id])) continue;
      if (asset.kind == MediaKind.lut) {
        final lut = await _importedLut(asset);
        if (lut != null) luts[asset.id] = lut;
        continue;
      }
      final media = await _original(asset, report);
      if (media == null) continue;
      originals[asset.id] = media;
      if (asset.proxy == ProxyState.ready && asset.kind == MediaKind.video) {
        final hash = asset.fingerprint.quickHash;
        final path = proxyPathOf(hash);
        if (await _safeExists(path)) {
          proxies[asset.id] = ResolvedMedia(uri: Uri.file(path).toString(), fingerprint: hash, isProxy: true);
        }
      }
    }

    final looks = <String, ResolvedLut>{};
    for (final presetId in builtinLooksOf(project)) {
      final lut = await _builtinLook(presetId);
      if (lut != null) looks[presetId] = lut;
    }
    return MapPlanAssetResolver(originals: originals, proxies: proxies, looks: looks, luts: luts);
  }

  static bool _offline(MediaAvailability? a) =>
      a == MediaAvailability.missing ||
      a == MediaAvailability.accessLost ||
      a == MediaAvailability.changed ||
      a == MediaAvailability.derivedMissing;

  Future<ResolvedMedia?> _original(MediaAsset asset, MediaAvailabilityReport? report) async {
    final cached = _originals[asset.id];
    if (cached != null && cached.locator == asset.locator && cached.status == asset.status && cached.fingerprint == asset.fingerprint) {
      if (cached.media != null) return cached.media;
      if (identical(cached.report, report)) return null;
    }
    ResolvedMedia? media;
    try {
      resolveCalls++;
      media = await access.resolve(asset.locator);
    } on MediaAccessFailure {
      media = null;
    } on Object catch (e) {
      // Any other failure (an engine error, a platform service not available yet) shows the media
      // offline instead of failing the whole compile.
      debugPrint('[PlanCompiler] Resolve failed: ${e.runtimeType}');
      media = null;
    }
    _originals[asset.id] = _Resolution(asset.locator, asset.status, asset.fingerprint, media, report);
    return media;
  }

  Future<ResolvedLut?> _importedLut(MediaAsset asset) async {
    final locator = asset.locator;
    if (locator is! AppRelativeLocator) return null;
    final path = roots.resolve(ManagedStore.vlutOf(locator));
    final n = await readVlutSize(path);
    if (n == null) return null;
    return ResolvedLut(uri: Uri.file(path).toString(), size: n);
  }

  Future<ResolvedLut?> _builtinLook(String presetId) async {
    final cached = _looks[presetId];
    if (cached != null && await _safeExists(Uri.parse(cached.uri).toFilePath())) return cached;
    try {
      return _looks[presetId] = await looks(presetId);
    } on Object catch (e) {
      debugPrint('[PlanCompiler] Look $presetId unavailable: ${e.runtimeType}');
      return null;
    }
  }

  Future<bool> _safeExists(String path) async {
    try {
      return await exists(path);
    } on Object {
      return false;
    }
  }

  /// Bundled look ids referenced by [project]'s clips.
  static Set<String> builtinLooksOf(EditProject project) => {
        for (final track in project.tracks)
          for (final item in track.items)
            if (item is MediaClip)
              if (item.visual?.look case BuiltinLook(:final presetId)) presetId,
      };
}

/// Reads the table size N from a `.vlut` header (`'VLUT'`, u16 version 1, u16 N, little-endian;
/// ARCH §10.2), or null when the file is missing, short or invalid.
Future<int?> readVlutTableSize(String path) async {
  RandomAccessFile? f;
  try {
    f = await File(path).open();
    return vlutTableSizeOf(await f.read(8));
  } on FileSystemException {
    return null;
  } finally {
    await f?.close();
  }
}

/// The table size N of a `.vlut` header in [bytes], or null when it is invalid.
int? vlutTableSizeOf(Uint8List bytes) {
  if (bytes.length < 8) return null;
  if (bytes[0] != 0x56 || bytes[1] != 0x4C || bytes[2] != 0x55 || bytes[3] != 0x54) return null; // 'VLUT'
  final data = ByteData.sublistView(bytes);
  if (data.getUint16(4, Endian.little) != 1) return null;
  final n = data.getUint16(6, Endian.little);
  return n >= 2 && n <= 65 ? n : null;
}

/// Extracts bundled looks (`packages/danaview_editor/assets/looks/<presetId>.vlut`) to
/// `<cache>/danaview/editor/looks/` on first use (ARCH §10.2).
final class BundledLookFiles {
  /// Creates the extractor.
  BundledLookFiles({required this.roots, AssetBundle? bundle}) : _bundle = bundle;

  /// App roots.
  final StoreRoots roots;

  final AssetBundle? _bundle;

  static final RegExp _safeId = RegExp(r'^[a-z0-9_-]{1,64}$');

  /// Asset key of [presetId].
  static String assetKeyOf(String presetId) => 'packages/danaview_editor/assets/looks/$presetId.vlut';

  /// Extracted path of [presetId].
  String pathOf(String presetId) => p.join(roots.editorCache, 'looks', '$presetId.vlut');

  /// The extracted `.vlut` of [presetId], or null when the look is not bundled.
  Future<ResolvedLut?> resolve(String presetId) async {
    if (!_safeId.hasMatch(presetId)) return null;
    final path = pathOf(presetId);
    final file = File(path);
    if (await file.exists()) {
      final n = await readVlutTableSize(path);
      if (n != null) return ResolvedLut(uri: Uri.file(path).toString(), size: n);
    }
    final ByteData data;
    try {
      data = await (_bundle ?? rootBundle).load(assetKeyOf(presetId));
    } on Object {
      return null;
    }
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final n = vlutTableSizeOf(bytes);
    if (n == null) return null;
    await file.parent.create(recursive: true);
    final part = File('$path.part');
    await part.writeAsBytes(bytes, flush: true);
    await part.rename(path);
    return ResolvedLut(uri: Uri.file(path).toString(), size: n);
  }
}
