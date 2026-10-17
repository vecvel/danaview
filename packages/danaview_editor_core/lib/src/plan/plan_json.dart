// OWNER: CORE-29
//
// Deterministic JSON codec for RenderPlan v1, patches and transients (ARCH §11.1 rule 4, §11.2).
//
// Canonical form (so fixtures round-trip byte for byte in Dart, Swift and Kotlin):
// - fixed key order per object (the order of the ARCH §11.2 tables); `assets` ids and `anim`
//   channel names sorted;
// - default-valued optional keys omitted;
// - integral doubles written as integers, other doubles in shortest round-trip form;
// - colours `"#RRGGBBAA"` (chroma key `"#RRGGBB"`);
// - unknown keys ignored on decode.

import 'dart:convert';
import 'dart:typed_data';

import '../time/time.dart';
import 'render_plan.dart';

/// A malformed plan, patch or transient.
final class PlanFormatException implements Exception {
  /// Creates the exception; [path] is a JSON-pointer-like location.
  const PlanFormatException(this.message, [this.path = '']);

  /// What is wrong.
  final String message;

  /// Where (e.g. `layers[3].map[0]`).
  final String path;

  @override
  String toString() => 'PlanFormatException(${path.isEmpty ? '' : '$path: '}$message)';
}

/// Encoder/decoder for the RenderPlan wire format.
abstract final class PlanJson {
  // ---------------------------------------------------------------- bytes

  /// UTF-8 JSON bytes of [plan] (what crosses the Pigeon control API).
  static Uint8List encodePlanBytes(RenderPlan plan) => _utf8(encodePlan(plan));

  /// Decodes [bytes] produced by [encodePlanBytes] (or any conforming encoder).
  static RenderPlan decodePlanBytes(Uint8List bytes) => decodePlan(_obj(_parse(bytes), ''));

  /// UTF-8 JSON bytes of [patch].
  static Uint8List encodePatchBytes(RenderPlanPatch patch) => _utf8(encodePatch(patch));

  /// Decodes a patch.
  static RenderPlanPatch decodePatchBytes(Uint8List bytes) => decodePatch(_obj(_parse(bytes), ''));

  /// UTF-8 JSON bytes of [transient].
  static Uint8List encodeTransientBytes(PlanTransient transient) => _utf8(encodeTransient(transient));

  /// Decodes a transient.
  static PlanTransient decodeTransientBytes(Uint8List bytes) => decodeTransient(_obj(_parse(bytes), ''));

  /// Canonical JSON text of an encoded object (as produced by the `encode*` methods).
  static String canonicalString(Map<String, Object?> json) => jsonEncode(json);

  // ---------------------------------------------------------------- colours

  /// `"#RRGGBBAA"` for an ARGB int.
  static String encodeColor(int argb) {
    final a = (argb >> 24) & 0xFF;
    final rgb = argb & 0xFFFFFF;
    return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}${a.toRadixString(16).padLeft(2, '0').toUpperCase()}';
  }

  /// ARGB int for `"#RRGGBBAA"` (or `"#RRGGBB"`, alpha FF).
  static int decodeColor(String s, [String path = '']) {
    final m = RegExp(r'^#([0-9a-fA-F]{6})([0-9a-fA-F]{2})?$').firstMatch(s);
    if (m == null) throw PlanFormatException('expected "#RRGGBBAA"', path);
    final rgb = int.parse(m[1]!, radix: 16);
    final a = m[2] == null ? 0xFF : int.parse(m[2]!, radix: 16);
    return (a << 24) | rgb;
  }

  // ---------------------------------------------------------------- plan

  /// JSON object of [plan] in canonical form.
  static Map<String, Object?> encodePlan(RenderPlan plan) => {
        'v': plan.v,
        'rev': plan.rev,
        'target': plan.target.name,
        'canvas': _encodeCanvas(plan.canvas),
        'durUs': plan.durUs,
        'assets': _encodeAssets(plan.assets),
        'layers': [for (final l in plan.layers) _encodeLayer(l)],
        'audio': [for (final a in plan.audio) _encodeAudio(a)],
        if (plan.req != null) 'req': _encodeReq(plan.req!),
      };

  /// Decodes a plan object.
  static RenderPlan decodePlan(Map<String, Object?> j) {
    final v = _int(j, 'v', '');
    if (v != renderPlanVersion) throw PlanFormatException('unsupported plan version $v', 'v');
    return RenderPlan(
      v: v,
      rev: _int(j, 'rev', ''),
      target: _enum(PlanTarget.values, _str(j, 'target', ''), 'target'),
      canvas: _decodeCanvas(_obj(j['canvas'], 'canvas')),
      durUs: _int(j, 'durUs', ''),
      assets: _decodeAssets(_obj(j['assets'], 'assets'), 'assets'),
      layers: [for (final (i, e) in _list(j['layers'], 'layers').indexed) _decodeLayer(_obj(e, 'layers[$i]'), 'layers[$i]')],
      audio: [for (final (i, e) in _list(j['audio'], 'audio').indexed) _decodeAudio(_obj(e, 'audio[$i]'), 'audio[$i]')],
      req: j['req'] == null ? null : _decodeReq(_obj(j['req'], 'req')),
    );
  }

  // ---------------------------------------------------------------- patch

  /// JSON object of [p] in canonical form.
  static Map<String, Object?> encodePatch(RenderPlanPatch p) => {
        'v': p.v,
        'from': p.from,
        'to': p.to,
        if (p.canvas != null) 'canvas': _encodeCanvas(p.canvas!),
        if (p.durUs != null) 'durUs': p.durUs,
        if (p.assetUpserts.isNotEmpty || p.assetRemovals.isNotEmpty)
          'assets': {
            if (p.assetUpserts.isNotEmpty) 'upsert': _encodeAssets(p.assetUpserts),
            if (p.assetRemovals.isNotEmpty) 'remove': p.assetRemovals,
          },
        if (!p.layers.isEmpty)
          'layers': {
            if (p.layers.upsert.isNotEmpty) 'upsert': [for (final l in p.layers.upsert) _encodeLayer(l)],
            if (p.layers.remove.isNotEmpty) 'remove': p.layers.remove,
          },
        if (!p.audio.isEmpty)
          'audio': {
            if (p.audio.upsert.isNotEmpty) 'upsert': [for (final a in p.audio.upsert) _encodeAudio(a)],
            if (p.audio.remove.isNotEmpty) 'remove': p.audio.remove,
          },
      };

  /// Decodes a patch object.
  static RenderPlanPatch decodePatch(Map<String, Object?> j) {
    final v = _int(j, 'v', '');
    if (v != renderPlanVersion) throw PlanFormatException('unsupported patch version $v', 'v');
    final assets = j['assets'] == null ? const <String, Object?>{} : _obj(j['assets'], 'assets');
    final layers = j['layers'] == null ? const <String, Object?>{} : _obj(j['layers'], 'layers');
    final audio = j['audio'] == null ? const <String, Object?>{} : _obj(j['audio'], 'audio');
    return RenderPlanPatch(
      v: v,
      from: _int(j, 'from', ''),
      to: _int(j, 'to', ''),
      canvas: j['canvas'] == null ? null : _decodeCanvas(_obj(j['canvas'], 'canvas')),
      durUs: j['durUs'] == null ? null : _int(j, 'durUs', ''),
      assetUpserts: assets['upsert'] == null ? const {} : _decodeAssets(_obj(assets['upsert'], 'assets.upsert'), 'assets.upsert'),
      assetRemovals: _strings(assets['remove'], 'assets.remove'),
      layers: PatchSet<PlanLayer>(
        upsert: [
          for (final (i, e) in _list(layers['upsert'] ?? const <Object?>[], 'layers.upsert').indexed)
            _decodeLayer(_obj(e, 'layers.upsert[$i]'), 'layers.upsert[$i]'),
        ],
        remove: _strings(layers['remove'], 'layers.remove'),
      ),
      audio: PatchSet<AudioSeg>(
        upsert: [
          for (final (i, e) in _list(audio['upsert'] ?? const <Object?>[], 'audio.upsert').indexed)
            _decodeAudio(_obj(e, 'audio.upsert[$i]'), 'audio.upsert[$i]'),
        ],
        remove: _strings(audio['remove'], 'audio.remove'),
      ),
    );
  }

  // ---------------------------------------------------------------- transient

  /// JSON object of [t] in canonical form.
  static Map<String, Object?> encodeTransient(PlanTransient t) => {
        'v': t.v,
        'item': t.item,
        'layers': [
          for (final l in t.layers)
            {
              'id': l.id,
              if (l.xf != null) 'xf': _encodeXf(l.xf!),
              if (l.crop != null) 'crop': _encodeCrop(l.crop!),
              if (l.base != null) 'base': [_num(l.base!.w), _num(l.base!.h)],
              if (l.fx != null) 'fx': _encodeFx(l.fx!),
              if (l.anim != null) 'anim': _encodeAnim(l.anim!),
              if (l.cmasks != null) 'cmasks': [for (final m in l.cmasks!) _encodeCmask(m)],
            },
        ],
      };

  /// Decodes a transient object. Timing keys are ignored (ARCH §11.2).
  static PlanTransient decodeTransient(Map<String, Object?> j) {
    final v = _int(j, 'v', '');
    if (v != renderPlanVersion) throw PlanFormatException('unsupported transient version $v', 'v');
    return PlanTransient(
      v: v,
      item: _str(j, 'item', ''),
      layers: [
        for (final (i, e) in _list(j['layers'], 'layers').indexed)
          () {
            final o = _obj(e, 'layers[$i]');
            final p = 'layers[$i]';
            return TransientLayer(
              id: _str(o, 'id', p),
              xf: o['xf'] == null ? null : _decodeXf(_obj(o['xf'], '$p.xf'), '$p.xf'),
              crop: o['crop'] == null ? null : _decodeCrop(o['crop'], '$p.crop'),
              base: o['base'] == null ? null : _decodeSize(o['base'], '$p.base'),
              fx: o['fx'] == null ? null : _decodeFx(_obj(o['fx'], '$p.fx'), '$p.fx'),
              anim: o['anim'] == null ? null : _decodeAnim(_obj(o['anim'], '$p.anim'), '$p.anim'),
              cmasks: o['cmasks'] == null
                  ? null
                  : [
                      for (final (k, m) in _list(o['cmasks'], '$p.cmasks').indexed)
                        _decodeCmask(_obj(m, '$p.cmasks[$k]'), '$p.cmasks[$k]'),
                    ],
            );
          }(),
      ],
    );
  }

  // ---------------------------------------------------------------- pieces

  static Map<String, Object?> _encodeCanvas(PlanCanvas c) => {
        'w': c.w,
        'h': c.h,
        'fps': c.fps,
        if (c.gridFps != c.fps) 'gridFps': c.gridFps,
        'bg': encodeColor(c.bg),
      };

  static PlanCanvas _decodeCanvas(Map<String, Object?> j) => PlanCanvas(
        w: _int(j, 'w', 'canvas'),
        h: _int(j, 'h', 'canvas'),
        fps: _int(j, 'fps', 'canvas'),
        gridFps: j['gridFps'] == null ? null : _int(j, 'gridFps', 'canvas'),
        bg: j['bg'] == null ? 0xFF000000 : decodeColor(_str(j, 'bg', 'canvas'), 'canvas.bg'),
      );

  static Map<String, Object?> _encodeAssets(Map<String, PlanAsset> assets) {
    final ids = assets.keys.toList()..sort();
    return {for (final id in ids) id: _encodeAsset(assets[id]!)};
  }

  static Map<String, PlanAsset> _decodeAssets(Map<String, Object?> j, String path) =>
      {for (final e in j.entries) e.key: _decodeAsset(_obj(e.value, '$path.${e.key}'), '$path.${e.key}')};

  static Map<String, Object?> _encodeAsset(PlanAsset a) => {
        'kind': a.kind.name,
        'uri': a.uri,
        if (a.bookmark != null) 'bookmark': a.bookmark,
        if (a.fp.isNotEmpty) 'fp': a.fp,
        if (a.proxyUri != null) 'proxyUri': a.proxyUri,
        if (a.w != null) 'w': a.w,
        if (a.h != null) 'h': a.h,
        if (a.rot != null) 'rot': a.rot,
        if (a.durUs != null) 'durUs': a.durUs,
        if (a.transfer != PlanTransfer.sdr) 'transfer': a.transfer.name,
        if (a.hasAudio != null) 'hasAudio': a.hasAudio,
        if (a.n != null) 'n': a.n,
        if (a.sw != null) 'sw': a.sw,
        if (a.sh != null) 'sh': a.sh,
        if (a.sscale != null) 'sscale': _num(a.sscale!),
        if (a.reveal != null) 'reveal': a.reveal,
      };

  static PlanAsset _decodeAsset(Map<String, Object?> j, String p) => PlanAsset(
        kind: _enum(PlanAssetKind.values, _str(j, 'kind', p), '$p.kind'),
        uri: _str(j, 'uri', p),
        bookmark: _optStr(j, 'bookmark', p),
        fp: _optStr(j, 'fp', p) ?? '',
        proxyUri: _optStr(j, 'proxyUri', p),
        w: _optInt(j, 'w', p),
        h: _optInt(j, 'h', p),
        rot: _optInt(j, 'rot', p),
        durUs: _optInt(j, 'durUs', p),
        transfer: j['transfer'] == null ? PlanTransfer.sdr : _enum(PlanTransfer.values, _str(j, 'transfer', p), '$p.transfer'),
        hasAudio: _optBool(j, 'hasAudio', p),
        n: _optInt(j, 'n', p),
        sw: _optInt(j, 'sw', p),
        sh: _optInt(j, 'sh', p),
        sscale: _optDouble(j, 'sscale', p),
        reveal: _optBool(j, 'reveal', p),
      );

  static Map<String, Object?> _encodeLayer(PlanLayer l) => {
        'id': l.id,
        'z': l.z,
        if (l.seq != null) 'seq': l.seq,
        't': [l.t0, l.t1],
        'kind': l.kind.name,
        if (l.asset != null) 'asset': l.asset,
        if (l.map.isNotEmpty) 'map': _encodeMap(l.map),
        if (l.hold) 'hold': true,
        if (l.color != null) 'color': encodeColor(l.color!),
        if (l.base != null) 'base': [_num(l.base!.w), _num(l.base!.h)],
        if (!l.crop.isFull) 'crop': _encodeCrop(l.crop),
        if (!l.xf.isIdentity) 'xf': _encodeXf(l.xf),
        if (!l.fx.isEmpty) 'fx': _encodeFx(l.fx),
        if (l.anim.isNotEmpty) 'anim': _encodeAnim(l.anim),
        if (l.cmasks.isNotEmpty) 'cmasks': [for (final m in l.cmasks) _encodeCmask(m)],
      };

  static PlanLayer _decodeLayer(Map<String, Object?> j, String p) {
    final t = _list(j['t'], '$p.t');
    if (t.length != 2) throw PlanFormatException('expected [t0, t1]', '$p.t');
    return PlanLayer(
      id: _str(j, 'id', p),
      z: _int(j, 'z', p),
      seq: _optInt(j, 'seq', p),
      t0: _asInt(t[0], '$p.t[0]'),
      t1: _asInt(t[1], '$p.t[1]'),
      kind: _enum(PlanLayerKind.values, _str(j, 'kind', p), '$p.kind'),
      asset: _optStr(j, 'asset', p),
      map: j['map'] == null ? const [] : _decodeMap(j['map'], '$p.map'),
      hold: _optBool(j, 'hold', p) ?? false,
      color: j['color'] == null ? null : decodeColor(_str(j, 'color', p), '$p.color'),
      base: j['base'] == null ? null : _decodeSize(j['base'], '$p.base'),
      crop: j['crop'] == null ? PlanCrop.full : _decodeCrop(j['crop'], '$p.crop'),
      xf: j['xf'] == null ? PlanTransform.identity : _decodeXf(_obj(j['xf'], '$p.xf'), '$p.xf'),
      fx: j['fx'] == null ? PlanEffects.none : _decodeFx(_obj(j['fx'], '$p.fx'), '$p.fx'),
      anim: j['anim'] == null ? const {} : _decodeAnim(_obj(j['anim'], '$p.anim'), '$p.anim'),
      cmasks: j['cmasks'] == null
          ? const []
          : [for (final (i, m) in _list(j['cmasks'], '$p.cmasks').indexed) _decodeCmask(_obj(m, '$p.cmasks[$i]'), '$p.cmasks[$i]')],
    );
  }

  static Map<String, Object?> _encodeAudio(AudioSeg a) => {
        'id': a.id,
        'asset': a.asset,
        if (a.stream != 0) 'stream': a.stream,
        't': [a.t0, a.t1],
        'map': _encodeMap(a.map),
        'gain': _encodeKeys(a.gain),
        if (!a.pitch) 'pitch': false,
      };

  static AudioSeg _decodeAudio(Map<String, Object?> j, String p) {
    final t = _list(j['t'], '$p.t');
    if (t.length != 2) throw PlanFormatException('expected [t0, t1]', '$p.t');
    return AudioSeg(
      id: _str(j, 'id', p),
      asset: _str(j, 'asset', p),
      stream: _optInt(j, 'stream', p) ?? 0,
      t0: _asInt(t[0], '$p.t[0]'),
      t1: _asInt(t[1], '$p.t[1]'),
      map: _decodeMap(j['map'], '$p.map'),
      gain: _decodeKeys(j['gain'], '$p.gain'),
      pitch: _optBool(j, 'pitch', p) ?? true,
    );
  }

  static Map<String, Object?> _encodeReq(PlanRequirements r) => {
        if (r.offline.isNotEmpty) 'offline': r.offline,
        if (r.pendingReverse.isNotEmpty) 'pendingReverse': r.pendingReverse,
        if (r.pendingStill.isNotEmpty) 'pendingStill': r.pendingStill,
      };

  static PlanRequirements _decodeReq(Map<String, Object?> j) => PlanRequirements(
        offline: _strings(j['offline'], 'req.offline'),
        pendingReverse: _strings(j['pendingReverse'], 'req.pendingReverse'),
        pendingStill: _strings(j['pendingStill'], 'req.pendingStill'),
      );

  static List<Object?> _encodeMap(List<MapSegment> map) => [
        for (final s in map) [s.t0, s.t1, s.s0, s.s1],
      ];

  static List<MapSegment> _decodeMap(Object? raw, String p) => [
        for (final (i, e) in _list(raw, p).indexed)
          () {
            final s = _list(e, '$p[$i]');
            if (s.length != 4) throw PlanFormatException('expected [t0, t1, s0, s1]', '$p[$i]');
            final t0 = _asInt(s[0], '$p[$i][0]');
            final t1 = _asInt(s[1], '$p[$i][1]');
            final s0 = _asInt(s[2], '$p[$i][2]');
            final s1 = _asInt(s[3], '$p[$i][3]');
            if (t1 <= t0 || s1 < s0) throw PlanFormatException('segment needs t1 > t0 and s1 ≥ s0', '$p[$i]');
            return MapSegment(t0, t1, s0, s1);
          }(),
      ];

  static List<Object?> _encodeCrop(PlanCrop c) => [_num(c.l), _num(c.t), _num(c.r), _num(c.b)];

  static PlanCrop _decodeCrop(Object? raw, String p) {
    final c = _list(raw, p);
    if (c.length != 4) throw PlanFormatException('expected [l, t, r, b]', p);
    return PlanCrop(_asDouble(c[0], p), _asDouble(c[1], p), _asDouble(c[2], p), _asDouble(c[3], p));
  }

  static PlanSize _decodeSize(Object? raw, String p) {
    final c = _list(raw, p);
    if (c.length != 2) throw PlanFormatException('expected [w, h]', p);
    return PlanSize(_asDouble(c[0], p), _asDouble(c[1], p));
  }

  static Map<String, Object?> _encodeXf(PlanTransform x) => {
        if (x.cx != null) 'cx': _num(x.cx!),
        if (x.cy != null) 'cy': _num(x.cy!),
        if (x.s != 1) 's': _num(x.s),
        if (x.r != 0) 'r': _num(x.r),
        if (x.fx) 'fx': true,
        if (x.fy) 'fy': true,
        if (x.op != 1) 'op': _num(x.op),
      };

  static PlanTransform _decodeXf(Map<String, Object?> j, String p) => PlanTransform(
        cx: _optDouble(j, 'cx', p),
        cy: _optDouble(j, 'cy', p),
        s: _optDouble(j, 's', p) ?? 1,
        r: _optDouble(j, 'r', p) ?? 0,
        fx: _optBool(j, 'fx', p) ?? false,
        fy: _optBool(j, 'fy', p) ?? false,
        op: _optDouble(j, 'op', p) ?? 1,
      );

  static const List<String> _adjNames = [
    'exposure',
    'brightness',
    'contrast',
    'highlights',
    'shadows',
    'saturation',
    'temperature',
    'tint',
  ];

  static Map<String, Object?> _encodeFx(PlanEffects f) => {
        if (f.adj != null)
          'adj': {
            for (final (i, n) in _adjNames.indexed)
              if (f.adj!.values[i] != 0) n: _num(f.adj!.values[i]),
          },
        if (f.detail != null)
          'detail': {
            if (f.detail!.sharpen != 0) 'sharpen': _num(f.detail!.sharpen),
            if (f.detail!.blur != 0) 'blur': _num(f.detail!.blur),
            if (f.detail!.vignette != 0) 'vignette': _num(f.detail!.vignette),
          },
        if (f.lut != null) 'lut': {'asset': f.lut!.asset, 'i': _num(f.lut!.i)},
        if (f.chroma != null)
          'chroma': {
            'key': '#${f.chroma!.key.toRadixString(16).padLeft(6, '0').toUpperCase()}',
            'sim': _num(f.chroma!.sim),
            'smooth': _num(f.chroma!.smooth),
            'spill': _num(f.chroma!.spill),
          },
        if (f.mask != null)
          'mask': {
            'shape': f.mask!.shape.name,
            'cx': _num(f.mask!.cx),
            'cy': _num(f.mask!.cy),
            'w': _num(f.mask!.w),
            'h': _num(f.mask!.h),
            if (f.mask!.r != 0) 'r': _num(f.mask!.r),
            if (f.mask!.corner != 0) 'corner': _num(f.mask!.corner),
            if (f.mask!.feather != 0) 'feather': _num(f.mask!.feather),
            if (f.mask!.op != 1) 'op': _num(f.mask!.op),
            if (f.mask!.inv) 'inv': true,
          },
      };

  static PlanEffects _decodeFx(Map<String, Object?> j, String p) {
    PlanAdjust? adj;
    if (j['adj'] != null) {
      final a = _obj(j['adj'], '$p.adj');
      double g(String n) => _optDouble(a, n, '$p.adj') ?? 0;
      adj = PlanAdjust(
        exposure: g('exposure'),
        brightness: g('brightness'),
        contrast: g('contrast'),
        highlights: g('highlights'),
        shadows: g('shadows'),
        saturation: g('saturation'),
        temperature: g('temperature'),
        tint: g('tint'),
      );
    }
    PlanDetail? detail;
    if (j['detail'] != null) {
      final d = _obj(j['detail'], '$p.detail');
      detail = PlanDetail(
        sharpen: _optDouble(d, 'sharpen', '$p.detail') ?? 0,
        blur: _optDouble(d, 'blur', '$p.detail') ?? 0,
        vignette: _optDouble(d, 'vignette', '$p.detail') ?? 0,
      );
    }
    PlanLut? lut;
    if (j['lut'] != null) {
      final l = _obj(j['lut'], '$p.lut');
      lut = PlanLut(_str(l, 'asset', '$p.lut'), _optDouble(l, 'i', '$p.lut') ?? 1);
    }
    PlanChroma? chroma;
    if (j['chroma'] != null) {
      final c = _obj(j['chroma'], '$p.chroma');
      chroma = PlanChroma(
        key: decodeColor(_str(c, 'key', '$p.chroma'), '$p.chroma.key') & 0xFFFFFF,
        sim: _optDouble(c, 'sim', '$p.chroma') ?? 0.4,
        smooth: _optDouble(c, 'smooth', '$p.chroma') ?? 0.1,
        spill: _optDouble(c, 'spill', '$p.chroma') ?? 0.3,
      );
    }
    PlanMask? mask;
    if (j['mask'] != null) {
      final m = _obj(j['mask'], '$p.mask');
      final mp = '$p.mask';
      mask = PlanMask(
        shape: _enum(PlanMaskShape.values, _str(m, 'shape', mp), '$mp.shape'),
        cx: _optDouble(m, 'cx', mp) ?? 0.5,
        cy: _optDouble(m, 'cy', mp) ?? 0.5,
        w: _optDouble(m, 'w', mp) ?? 1,
        h: _optDouble(m, 'h', mp) ?? 1,
        r: _optDouble(m, 'r', mp) ?? 0,
        corner: _optDouble(m, 'corner', mp) ?? 0,
        feather: _optDouble(m, 'feather', mp) ?? 0,
        op: _optDouble(m, 'op', mp) ?? 1,
        inv: _optBool(m, 'inv', mp) ?? false,
      );
    }
    return PlanEffects(adj: adj, detail: detail, lut: lut, chroma: chroma, mask: mask);
  }

  static Map<String, Object?> _encodeAnim(Map<String, List<AnimKey>> anim) {
    final names = anim.keys.toList()..sort();
    return {for (final n in names) n: _encodeKeys(anim[n]!)};
  }

  static Map<String, List<AnimKey>> _decodeAnim(Map<String, Object?> j, String p) =>
      {for (final e in j.entries) e.key: _decodeKeys(e.value, '$p.${e.key}')};

  static List<Object?> _encodeKeys(List<AnimKey> keys) => [
        for (final k in keys) [k.tUs, _num(k.v)],
      ];

  static List<AnimKey> _decodeKeys(Object? raw, String p) => [
        for (final (i, e) in _list(raw, p).indexed)
          () {
            final k = _list(e, '$p[$i]');
            if (k.length != 2) throw PlanFormatException('expected [tUs, v]', '$p[$i]');
            return AnimKey(_asInt(k[0], '$p[$i][0]'), _asDouble(k[1], '$p[$i][1]'));
          }(),
      ];

  static Map<String, Object?> _encodeCmask(CanvasMask m) => {
        'cx': _num(m.cx),
        'cy': _num(m.cy),
        'w': _num(m.w),
        'h': _num(m.h),
        if (m.r != 0) 'r': _num(m.r),
        if (m.feather != 0) 'feather': _num(m.feather),
        if (m.inv) 'inv': true,
        if (m.anim.isNotEmpty) 'anim': _encodeAnim(m.anim),
      };

  static CanvasMask _decodeCmask(Map<String, Object?> j, String p) => CanvasMask(
        cx: _asDouble(j['cx'], '$p.cx'),
        cy: _asDouble(j['cy'], '$p.cy'),
        w: _asDouble(j['w'], '$p.w'),
        h: _asDouble(j['h'], '$p.h'),
        r: _optDouble(j, 'r', p) ?? 0,
        feather: _optDouble(j, 'feather', p) ?? 0,
        inv: _optBool(j, 'inv', p) ?? false,
        anim: j['anim'] == null ? const {} : _decodeAnim(_obj(j['anim'], '$p.anim'), '$p.anim'),
      );

  // ---------------------------------------------------------------- primitives

  /// Canonical number: integral finite doubles become ints (so `1.0` and `1` encode alike).
  static Object _num(double d) {
    if (d.isFinite && d == d.truncateToDouble() && d.abs() < 9007199254740992) return d.toInt();
    return d;
  }

  static Uint8List _utf8(Map<String, Object?> json) {
    // Straight to UTF-8 (no intermediate String); identical bytes to utf8.encode(jsonEncode(json)).
    final out = JsonUtf8Encoder().convert(json);
    return out is Uint8List ? out : Uint8List.fromList(out);
  }

  static Object? _parse(Uint8List bytes) {
    try {
      return jsonDecode(utf8.decode(bytes));
    } on FormatException catch (e) {
      throw PlanFormatException('invalid JSON: ${e.message}');
    }
  }

  static Map<String, Object?> _obj(Object? raw, String p) {
    if (raw is Map<String, Object?>) return raw;
    if (raw is Map) return raw.cast<String, Object?>();
    throw PlanFormatException('expected an object', p);
  }

  static List<Object?> _list(Object? raw, String p) {
    if (raw is List<Object?>) return raw;
    if (raw is List) return raw.cast<Object?>();
    throw PlanFormatException('expected an array', p);
  }

  static List<String> _strings(Object? raw, String p) =>
      raw == null ? const [] : [for (final (i, e) in _list(raw, p).indexed) e is String ? e : throw PlanFormatException('expected a string', '$p[$i]')];

  static int _asInt(Object? v, String p) {
    if (v is int) return v;
    if (v is double && v == v.truncateToDouble()) return v.toInt();
    throw PlanFormatException('expected an integer', p);
  }

  static double _asDouble(Object? v, String p) {
    if (v is num) return v.toDouble();
    throw PlanFormatException('expected a number', p);
  }

  static int _int(Map<String, Object?> j, String k, String p) => _asInt(j[k], p.isEmpty ? k : '$p.$k');

  static int? _optInt(Map<String, Object?> j, String k, String p) => j[k] == null ? null : _asInt(j[k], '$p.$k');

  static double? _optDouble(Map<String, Object?> j, String k, String p) => j[k] == null ? null : _asDouble(j[k], '$p.$k');

  static bool? _optBool(Map<String, Object?> j, String k, String p) {
    final v = j[k];
    if (v == null) return null;
    if (v is bool) return v;
    throw PlanFormatException('expected a boolean', '$p.$k');
  }

  static String _str(Map<String, Object?> j, String k, String p) {
    final v = j[k];
    if (v is String) return v;
    throw PlanFormatException('expected a string', p.isEmpty ? k : '$p.$k');
  }

  static String? _optStr(Map<String, Object?> j, String k, String p) => j[k] == null ? null : _str(j, k, p);

  static T _enum<T extends Enum>(List<T> values, String name, String p) {
    for (final v in values) {
      if (v.name == name) return v;
    }
    throw PlanFormatException('unknown value "$name"', p);
  }
}
