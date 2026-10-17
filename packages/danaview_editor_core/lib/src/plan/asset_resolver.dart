// OWNER: CORE-30
//
// Asset resolution for the RenderPlan compiler (ARCH §11.2 Asset, §9.5 proxies, domain.md §12.1
// rule 5). The compiler is pure and runs in an isolate above 300 items, so it never touches the
// file system or the platform: the caller resolves what it needs **before** compiling and passes
// a [PlanAssetResolver] — a synchronous lookup from `MediaId` to the file the engine opens
// (`ResolvedMedia`), its ready proxy, and the `.vlut` files of looks. INT-02 implements it over the
// session pool, availability (CORE-28) and the proxy registry; tests use [MapPlanAssetResolver].
//
// [PlanAssetFactory] turns a pool asset plus its resolution into the plan's `assets` entry:
//
// * the asset id is the `MediaId` (bundled looks use `lk_<presetId>`, [PlanAssetIds]);
// * `uri`/`bookmark`/`fp` come from the resolution; a URI that is not `file://` or `content://`
//   is treated as offline (a plan never carries http, ARCH §11.2);
// * `w`/`h`/`rot`/`durUs`/`transfer`/`hasAudio` come from the probe (a derived still or reversed
//   rendition without its own picture size uses its source's);
// * `proxyUri` only in **preview** plans and only when the pool says the proxy is ready and the
//   resolver returns it; **export plans never carry proxies** (ARCH §9.5).

import 'dart:convert';

import 'package:meta/meta.dart';

import '../ids/ids.dart';
import '../model/pool/media_asset.dart';
import '../model/pool/media_pool.dart';
import '../model/pool/media_probe.dart';
import '../model/pool/resolved_media.dart';
import 'render_plan.dart';

/// A `.vlut` colour table the engine can load (ARCH §10.2): its URI and table size N (2–65).
@immutable
final class ResolvedLut {
  /// Creates a resolved LUT.
  const ResolvedLut({required this.uri, required this.size});

  /// `file://` or `content://` URI of the `.vlut` file.
  final String uri;

  /// Table size N (an N³ lattice), 2–65.
  final int size;

  @override
  bool operator ==(Object other) => other is ResolvedLut && other.uri == uri && other.size == size;

  @override
  int get hashCode => Object.hash(uri, size);

  @override
  String toString() => 'ResolvedLut(n: $size)';
}

/// Resolves pool media for the compiler (INT-02 implements it; must be safe to send to an isolate:
/// resolve everything up front, hold plain data).
abstract interface class PlanAssetResolver {
  /// The original file of pool media [id] (never a proxy), or null when it is unavailable right
  /// now (missing, access lost, changed): the compiler then emits an offline placeholder and lists
  /// [id] in `req.offline` (ARCH §11.7 "Missing media").
  ResolvedMedia? original(MediaId id);

  /// The ready proxy rendition of [id] (same timestamps as the original), or null. Consulted for
  /// preview plans only.
  ResolvedMedia? proxy(MediaId id);

  /// The `.vlut` of the bundled look [presetId] (`assets/looks/`), or null when unknown.
  ResolvedLut? builtinLook(String presetId);

  /// The `.vlut` of the imported LUT asset [id] (a pool asset of kind `lut`), or null when it is
  /// unavailable.
  ResolvedLut? importedLut(MediaId id);
}

/// A [PlanAssetResolver] over plain maps, built by the caller before compiling (and by tests).
final class MapPlanAssetResolver implements PlanAssetResolver {
  /// Creates a resolver; the maps are copied.
  MapPlanAssetResolver({
    Map<MediaId, ResolvedMedia> originals = const {},
    Map<MediaId, ResolvedMedia> proxies = const {},
    Map<String, ResolvedLut> looks = const {},
    Map<MediaId, ResolvedLut> luts = const {},
  })  : originals = Map.unmodifiable(originals),
        proxies = Map.unmodifiable(proxies),
        looks = Map.unmodifiable(looks),
        luts = Map.unmodifiable(luts);

  /// A resolver that knows nothing (every media offline, no looks).
  static final MapPlanAssetResolver empty = MapPlanAssetResolver();

  /// Original files by media id.
  final Map<MediaId, ResolvedMedia> originals;

  /// Ready proxies by media id.
  final Map<MediaId, ResolvedMedia> proxies;

  /// Bundled looks by preset id.
  final Map<String, ResolvedLut> looks;

  /// Imported LUTs by media id.
  final Map<MediaId, ResolvedLut> luts;

  @override
  ResolvedMedia? original(MediaId id) => originals[id];

  @override
  ResolvedMedia? proxy(MediaId id) => proxies[id];

  @override
  ResolvedLut? builtinLook(String presetId) => looks[presetId];

  @override
  ResolvedLut? importedLut(MediaId id) => luts[id];
}

/// Ids of entries in `plan.assets`.
abstract final class PlanAssetIds {
  /// Prefix of bundled look assets.
  static const String lookPrefix = 'lk_';

  /// The asset id of pool media [id]: the media id itself.
  static String media(MediaId id) => id;

  /// The asset id of the bundled look [presetId]: `lk_<presetId>`.
  static String builtinLook(String presetId) => '$lookPrefix$presetId';
}

/// Whether [uri] is a scheme a plan may carry (`file://` or `content://`, never http).
bool isPlanUri(String uri) => uri.startsWith('file://') || uri.startsWith('content://');

/// Builds `plan.assets` entries from a pool and a [PlanAssetResolver] for one compile, caching each
/// entry (the same id always yields an equal entry).
final class PlanAssetFactory {
  /// Creates a factory for a plan of [target].
  PlanAssetFactory({required this.pool, required this.resolver, required this.target});

  /// The project's media pool.
  final MediaPool pool;

  /// The caller's resolver.
  final PlanAssetResolver resolver;

  /// Preview plans may carry proxies; export plans never do.
  final PlanTarget target;

  final Map<String, PlanAsset?> _media = {};
  final Map<String, PlanAsset?> _looks = {};
  final Map<MediaId, PlanAsset?> _luts = {};

  /// Whether the original of pool media [id] resolves to a URI a plan may carry.
  bool isAvailable(MediaId id) {
    final r = resolver.original(id);
    return pool.contains(id) && r != null && isPlanUri(r.uri);
  }

  /// The entry of pool media [id] used as [kind] (`video`, `audio` or `image`), or null when [id]
  /// is not in the pool or its original is unavailable (offline).
  PlanAsset? media(MediaId id, PlanAssetKind kind) =>
      _media.putIfAbsent('$id|${kind.index}', () => _buildMedia(id, kind));

  PlanAsset? _buildMedia(MediaId id, PlanAssetKind kind) {
    final asset = pool[id];
    if (asset == null) return null;
    final r = resolver.original(id);
    if (r == null || !isPlanUri(r.uri)) return null;
    final probe = asset.probe;
    final picture = _pictureProbe(asset);
    final timeBased = kind != PlanAssetKind.image;
    String? proxyUri;
    if (target == PlanTarget.preview && kind == PlanAssetKind.video && asset.proxy == ProxyState.ready) {
      final p = resolver.proxy(id);
      if (p != null && isPlanUri(p.uri)) proxyUri = p.uri;
    }
    final rot = _rotation(picture?.rotation ?? 0);
    return PlanAsset(
      kind: kind,
      uri: r.uri,
      bookmark: r.bookmark == null || r.bookmark!.isEmpty ? null : base64Encode(r.bookmark!),
      fp: r.fingerprint,
      proxyUri: proxyUri,
      w: kind == PlanAssetKind.audio ? null : _positive(picture?.width),
      h: kind == PlanAssetKind.audio ? null : _positive(picture?.height),
      rot: kind == PlanAssetKind.audio || rot == 0 ? null : rot,
      durUs: timeBased && probe.duration > 0 ? probe.duration : null,
      transfer: kind == PlanAssetKind.video ? _transfer(probe.transfer) : PlanTransfer.sdr,
      hasAudio: timeBased ? probe.hasAudio : null,
    );
  }

  /// The entry of the bundled look [presetId] (id [PlanAssetIds.builtinLook]), or null when the
  /// resolver does not know it.
  PlanAsset? builtinLook(String presetId) => _looks.putIfAbsent(presetId, () => _lut(resolver.builtinLook(presetId)));

  /// The entry of the imported LUT [id] (a pool asset of kind `lut`), or null when it is not in
  /// the pool or unavailable.
  PlanAsset? importedLut(MediaId id) => _luts.putIfAbsent(id, () {
        final asset = pool[id];
        if (asset == null || asset.kind != MediaKind.lut) return null;
        return _lut(resolver.importedLut(id));
      });

  static PlanAsset? _lut(ResolvedLut? lut) {
    if (lut == null || !isPlanUri(lut.uri) || lut.size < 2 || lut.size > 65) return null;
    return PlanAsset(kind: PlanAssetKind.lut, uri: lut.uri, n: lut.size);
  }

  /// The probe that carries [asset]'s picture size: its own, or for a derived still or rendition
  /// without one, its source's (a pending still has the size of the frame it freezes).
  MediaProbe? _pictureProbe(MediaAsset asset) {
    final own = asset.probe;
    if (_positive(own.width) != null && _positive(own.height) != null) return own;
    final source = switch (asset.derived) {
      StillSpec(:final media) => pool[media],
      ReversedSpec(:final media) => pool[media],
      null => null,
    };
    return source?.probe ?? own;
  }

  static int? _positive(int? v) => v != null && v > 0 ? v : null;

  static int _rotation(int r) {
    final n = ((r % 360) + 360) % 360;
    return n % 90 == 0 ? n : 0;
  }

  static PlanTransfer _transfer(ColorTransfer t) => switch (t) {
        ColorTransfer.sdr => PlanTransfer.sdr,
        ColorTransfer.hlg => PlanTransfer.hlg,
        ColorTransfer.pq => PlanTransfer.pq,
      };
}
