// OWNER: CORE-22
//
// Project body codec (ARCH §8.2, domain.md §9.2). Normative schema:
// `schema/project.v1.schema.json`.
//
// Body conventions (deterministic bytes, so equal projects built the same way encode to identical
// bytes and every decode → encode is the identity on bytes):
// - times are integer µs; colours `"#RRGGBBAA"` (the chroma key colour, an RGB value, `"#RRGGBB"`);
// - doubles in shortest round-trip form, integral doubles written as integers;
// - fields equal to their model default are omitted (a nullable field whose default is not null,
//   such as the subtitle box, is written as JSON `null` when cleared);
// - fixed key order per object (the order of the builders below); keyframe channels sorted; the
//   pool keeps its insertion order (it is the media-bin order);
// - items tagged `"t":"clip"|"text"|"cue"`; enums as lower-camel strings; sealed variants as
//   objects discriminated by their first key (`{"c":1.5}` vs `{"ramp":…}`);
// - unknown keys are ignored on decode; unknown enum values decode to the field default with a
//   `ProjectOpenWarning(unknownEnum)`; unknown item tags, track kinds and asset kinds drop the node
//   with a warning (`repair()` then fixes dangling references). Opening never fails for these.
//
// Container paths (ARCH §8.2): no persisted string holds an absolute app-container path. Pool
// locators that point into an app root are written as `AppRelativeLocator`s (through the
// repository's relativizer, falling back to iOS/Android container detection); a container path
// outside the three roots keeps only its file name (it cannot survive an app update anyway, and the
// relink flow takes over). `BookmarkLocator.lastKnownPath` is the only exception: a display hint.
//
// Incremental encoding: `encode` splices fragments from a `FragmentCache`, so after a one-item edit
// only the edited item, its track and the small root objects are re-serialized (≤ 3 ms at 2,000
// items). `encode(p)` always equals `jsonEncode(toJson(p))`.

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../ids/ids.dart';
import '../model/audio_props.dart';
import '../model/items.dart';
import '../model/keyframes/keyframe_data.dart';
import '../model/marker.dart';
import '../model/pool/fingerprint.dart';
import '../model/pool/media_asset.dart';
import '../model/pool/media_locator.dart';
import '../model/pool/media_pool.dart';
import '../model/pool/media_probe.dart';
import '../model/pool/picked_media.dart';
import '../model/project.dart';
import '../model/settings.dart';
import '../model/speed_spec.dart';
import '../model/subtitle.dart';
import '../model/text_style.dart';
import '../model/timeline.dart';
import '../model/track.dart';
import '../model/transition.dart';
import '../model/view_state.dart';
import '../model/visual_props.dart';
import '../time/time.dart';
import '../validate/validate.dart' show ProjectOpenWarning;
import 'fragment_cache.dart';
import 'schema_version.dart';

/// Maps an absolute path to an [AppRelativeLocator] when it lies inside one of the app roots, or
/// returns null. The repository passes `StoreRoots.relativize`.
typedef AppPathRelativizer = AppRelativeLocator? Function(String absolutePath);

/// `ProjectOpenWarning` codes produced by the codec (repair codes are `RepairCodes`).
abstract final class ProjectCodecWarnings {
  /// An enum value this build does not know; the field default was used.
  static const String unknownEnum = 'unknownEnum';

  /// A sealed-variant object (locator, look, speed, origin, …) of an unknown shape; the field
  /// default was used.
  static const String unknownVariant = 'unknownVariant';

  /// An item with an unknown `"t"` tag was left out.
  static const String unknownItemDropped = 'unknownItemDropped';

  /// A track of an unknown kind was left out.
  static const String unknownTrackDropped = 'unknownTrackDropped';

  /// A pool asset of an unknown kind was left out (clips using it get a placeholder from
  /// `repair()`).
  static const String unknownAssetDropped = 'unknownAssetDropped';
}

/// A decoded body: the project plus everything the decoder had to default or leave out.
@immutable
final class ProjectDecodeResult {
  /// Creates a result.
  ProjectDecodeResult(this.project, List<ProjectOpenWarning> warnings) : warnings = List.unmodifiable(warnings);

  /// The decoded project (not yet validated or repaired).
  final EditProject project;

  /// Unknown values met while decoding (never fatal).
  final List<ProjectOpenWarning> warnings;
}

/// Detection of absolute app-container paths (iOS sandbox containers, Android app data dirs).
///
/// iOS changes the container UUID on every app update, so such a path must never be persisted
/// (ARCH §8.2). Used by the codec as a fallback when no relativizer knows the path, and by tests.
abstract final class AppContainerPaths {
  static const String _uuid = '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}';

  // Device data (`/var/mobile/Containers/Data/…`, also under `/private`), device bundles
  // (`/var/containers/Bundle/…`) and simulator containers.
  static final RegExp _iosRoot = RegExp('^(.*?/[Cc]ontainers/(?:Data|Bundle)/Application/$_uuid)(/.*)?\$');
  static final RegExp _iosAnywhere = RegExp('/[Cc]ontainers/(?:Data|Bundle)/Application/$_uuid(?:/|\$)');

  // `/data/user/<n>/<pkg>`, `/data/user_de/<n>/<pkg>`, `/data/data/<pkg>`.
  static const String _pkg = r'[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+';
  static final RegExp _androidRoot = RegExp('^(/data/(?:user(?:_de)?/[0-9]+|data)/$_pkg)(/.*)?\$');
  static final RegExp _androidAnywhere = RegExp('(?:^|[^A-Za-z0-9_])/data/(?:user(?:_de)?/[0-9]+|data)/$_pkg(?:/|\$)');

  /// Whether [s] contains an absolute app-container path anywhere.
  static bool contains(String s) => _iosAnywhere.hasMatch(s) || _androidAnywhere.hasMatch(s);

  /// The container root at the start of the absolute [path] (no trailing `/`), or null.
  static String? containerRootOf(String path) {
    final n = _normalize(path);
    if (n == null) return null;
    return (_iosRoot.firstMatch(n) ?? _androidRoot.firstMatch(n))?.group(1);
  }

  /// [path] relative to the app root it lies in, judged from the container layout alone:
  /// iOS `Documents/`, `Library/Application Support/`, `Library/Caches/`; Android `app_flutter/`,
  /// `files/`, `cache/` (path_provider's documents, support and temporary directories). Null when
  /// [path] is not inside one of them.
  static AppRelativeLocator? relativize(String path) {
    final n = _normalize(path);
    if (n == null) return null;
    final ios = _iosRoot.firstMatch(n);
    if (ios != null) {
      return _under(ios.group(2), const {
        '/Documents/': AppRoot.documents,
        '/Library/Application Support/': AppRoot.support,
        '/Library/Caches/': AppRoot.cache,
      });
    }
    final android = _androidRoot.firstMatch(n);
    if (android != null) {
      return _under(android.group(2), const {
        '/app_flutter/': AppRoot.documents,
        '/files/': AppRoot.support,
        '/cache/': AppRoot.cache,
      });
    }
    return null;
  }

  static AppRelativeLocator? _under(String? rest, Map<String, AppRoot> roots) {
    if (rest == null) return null;
    for (final e in roots.entries) {
      if (rest.startsWith(e.key) && rest.length > e.key.length) {
        return AppRelativeLocator(e.value, rest.substring(e.key.length));
      }
    }
    return null;
  }

  static String? _normalize(String path) {
    if (!path.startsWith('/')) return null;
    return p.posix.normalize(path);
  }
}

/// Encoder/decoder of the project body line (`EditProject` ⇄ canonical JSON).
///
/// One codec per open project keeps the [cache] warm for incremental autosave encodes (ARCH §8.3).
/// Decoding is stateless and may run in the decode isolate.
final class ProjectJsonCodec {
  /// Creates a codec. [relativize] maps absolute paths inside the app roots to app-relative
  /// locators (the repository passes `StoreRoots.relativize`); container detection
  /// ([AppContainerPaths]) is the fallback. [cache] defaults to a new private cache.
  ProjectJsonCodec({AppPathRelativizer? relativize, FragmentCache? cache})
      : _relativizer = relativize,
        cache = cache ?? FragmentCache();

  final AppPathRelativizer? _relativizer;

  /// Fragments of previously encoded nodes (by identity).
  final FragmentCache cache;

  // =============================================================================================
  // Encoding
  // =============================================================================================

  /// The canonical body line of [project] (no trailing newline), built incrementally from
  /// [cache].
  String encode(EditProject project) {
    final c = cache;
    final b = StringBuffer('{"id":')..write(jsonEncode(project.id));
    if (project.docRevision != 0) b.write(',"docRev":${project.docRevision}');
    if (project.timeline.revision != 0) b.write(',"rev":${project.timeline.revision}');
    b
      ..write(',"meta":')
      ..write(c.fragment(project.meta, () => jsonEncode(_meta(project.meta))))
      ..write(',"settings":')
      ..write(c.fragment(project.settings, () => jsonEncode(_settings(project.settings))))
      ..write(',"tracks":[');
    final tracks = project.tracks;
    for (var i = 0; i < tracks.length; i++) {
      if (i > 0) b.write(',');
      final t = tracks[i];
      b.write(c.fragment(t, () => _trackText(t)));
    }
    b.write('],"markers":[');
    final markers = project.markers;
    for (var i = 0; i < markers.length; i++) {
      if (i > 0) b.write(',');
      final m = markers[i];
      b.write(c.fragment(m, () => jsonEncode(_marker(m))));
    }
    b
      ..write('],"pool":')
      ..write(c.fragment(project.pool, () => _poolText(project.pool)))
      ..write(',"view":')
      ..write(c.fragment(project.view, () => jsonEncode(_view(project.view))))
      ..write('}');
    return b.toString();
  }

  /// UTF-8 bytes of [encode].
  Uint8List encodeBytes(EditProject project) => utf8.encode(encode(project));

  /// The body as a JSON object tree (no cache). `jsonEncode(toJson(p)) == encode(p)`.
  Map<String, Object?> toJson(EditProject project) => {
        'id': project.id,
        if (project.docRevision != 0) 'docRev': project.docRevision,
        if (project.timeline.revision != 0) 'rev': project.timeline.revision,
        'meta': _meta(project.meta),
        'settings': _settings(project.settings),
        'tracks': [for (final t in project.tracks) _trackJson(t)],
        'markers': [for (final m in project.markers) _marker(m)],
        'pool': _poolJson(project.pool),
        'view': _view(project.view),
      };

  String _trackText(Track t) {
    final head = jsonEncode(_trackHead(t));
    final b = StringBuffer(head.substring(0, head.length - 1));
    final items = t.items;
    if (items.isNotEmpty) {
      b.write(',"items":[');
      for (var i = 0; i < items.length; i++) {
        if (i > 0) b.write(',');
        final item = items[i];
        b.write(cache.fragment(item, () => jsonEncode(_item(item))));
      }
      b.write(']');
    }
    if (t.transitions.isNotEmpty) {
      b
        ..write(',"tx":')
        ..write(jsonEncode([for (final x in t.transitions) _transition(x)]));
    }
    b.write('}');
    return b.toString();
  }

  String _poolText(MediaPool pool) {
    if (pool.isEmpty) return '{}';
    final b = StringBuffer('{"assets":[');
    var first = true;
    for (final a in pool.assets.values) {
      if (!first) b.write(',');
      first = false;
      b.write(cache.fragment(a, () => jsonEncode(_asset(a))));
    }
    b.write(']}');
    return b.toString();
  }

  Map<String, Object?> _poolJson(MediaPool pool) =>
      pool.isEmpty ? <String, Object?>{} : {'assets': [for (final a in pool.assets.values) _asset(a)]};

  // ---------------------------------------------------------------- meta, settings, view

  Map<String, Object?> _meta(ProjectMeta m) {
    final j = <String, Object?>{
      'name': m.name,
      'created': _time(m.createdAt),
      'updated': _time(m.updatedAt),
    };
    final origin = m.origin;
    if (origin is FromPlayerOrigin) {
      j['origin'] = {
        'player': origin.quickHash,
        'size': origin.sizeBytes,
        if (origin.displayName.isNotEmpty) 'name': _displayName(origin.displayName),
      };
    }
    if (m.editCount != 0) j['edits'] = m.editCount;
    return j;
  }

  static Map<String, Object?> _settings(ProjectSettings s) {
    final j = <String, Object?>{};
    final canvas = <String, Object?>{
      if (s.canvas.aspect.w != 16 || s.canvas.aspect.h != 9) 'aspect': [s.canvas.aspect.w, s.canvas.aspect.h],
      if (s.canvas.baseShortSide != 1080) 'short': s.canvas.baseShortSide,
    };
    if (canvas.isNotEmpty) j['canvas'] = canvas;
    if (s.frameRate.num != 30 || s.frameRate.den != 1) j['fps'] = _rate(s.frameRate);
    final bg = s.background;
    switch (bg) {
      case SolidBackground(:final color):
        if (color != 0xFF000000) j['bg'] = {'solid': _color(color)};
      case BlurOfMainBackground(:final radius):
        j['bg'] = {'blur': _num(radius)};
    }
    if (s.audioSampleRate != 48000) j['sampleRate'] = s.audioSampleRate;
    return j;
  }

  static Map<String, Object?> _view(ViewState v) {
    final j = <String, Object?>{};
    if (v.playhead != 0) j['playhead'] = v.playhead;
    _putNum(j, 'pps', v.pixelsPerSecond, 0);
    if (v.scrollTimeUs != 0) j['scrollT'] = v.scrollTimeUs;
    _putNum(j, 'scrollY', v.scrollLanePx, 0);
    if (!v.rippleEnabled) j['ripple'] = false;
    if (!v.snappingEnabled) j['snap'] = false;
    if (v.followMode != null) j['follow'] = v.followMode!.name;
    if (v.lastExportPresetId != null) j['exportPreset'] = v.lastExportPresetId;
    return j;
  }

  static Map<String, Object?> _marker(Marker m) => {
        'id': m.id,
        'time': m.time,
        if (m.name.isNotEmpty) 'name': m.name,
        if (m.colorIndex != 0) 'color': m.colorIndex,
        if (m.note != null) 'note': m.note,
      };

  // ---------------------------------------------------------------- tracks

  Map<String, Object?> _trackJson(Track t) => {
        ..._trackHead(t),
        if (t.items.isNotEmpty) 'items': [for (final i in t.items) _item(i)],
        if (t.transitions.isNotEmpty) 'tx': [for (final x in t.transitions) _transition(x)],
      };

  static Map<String, Object?> _trackHead(Track t) => {
        'id': t.id,
        'kind': t.kind.name,
        if (t.name.isNotEmpty) 'name': t.name,
        if (t.isMain) 'main': true,
        if (t.locked) 'locked': true,
        if (t.hidden) 'hidden': true,
        if (t.muted) 'muted': true,
        if (t.solo) 'solo': true,
        if (t.audioRole != null) 'role': t.audioRole!.name,
        if (t.subtitle != null) 'sub': _subtitleTrack(t.subtitle!),
        if (t.changedAt != 0) 'chg': t.changedAt,
      };

  static Map<String, Object?> _transition(Transition x) => {
        'id': x.id,
        'left': x.left,
        'right': x.right,
        'kind': x.kind.name,
        'frames': x.durationFrames,
        if (x.direction != null) 'dir': x.direction!.name,
      };

  static Map<String, Object?> _subtitleTrack(SubtitleTrackData d) {
    final j = <String, Object?>{};
    if (d.language != null) j['lang'] = d.language;
    final style = _subtitleStyle(d.style);
    if (style.isNotEmpty) j['style'] = style;
    switch (d.position) {
      case TopSubtitlePosition():
        j['pos'] = 'top';
      case CustomSubtitlePosition(:final yFraction):
        j['pos'] = {'y': _num(yFraction)};
      case BottomSubtitlePosition():
        break;
    }
    if (!d.burnIn) j['burnIn'] = false;
    if (d.provenance != null) j['prov'] = _provenance(d.provenance!);
    return j;
  }

  static Map<String, Object?> _subtitleStyle(SubtitleStyle s) {
    final j = <String, Object?>{};
    if (s.fontFamily != 'figtree') j['font'] = s.fontFamily;
    _putNum(j, 'size', s.fontSizePt, 42);
    if (s.bold) j['bold'] = true;
    if (s.italic) j['italic'] = true;
    if (s.color != 0xFFFFFFFF) j['color'] = _color(s.color);
    if (s.background == null) {
      j['box'] = null;
    } else if (s.background != const BoxStyle()) {
      j['box'] = _box(s.background!);
    }
    if (s.outline != null) j['outline'] = _stroke(s.outline!);
    if (s.shadow != null) j['shadow'] = _shadow(s.shadow!);
    if (s.maxLines != 2) j['maxLines'] = s.maxLines;
    _putNum(j, 'maxWidth', s.maxWidth, 0.9);
    if (s.align != TextAlignH.center) j['align'] = s.align.name;
    return j;
  }

  static Map<String, Object?> _provenance(CaptionProvenance v) {
    final j = <String, Object?>{
      'generator': v.generator,
      'engineVersion': v.engineVersion,
      'modelId': v.modelId,
      'modelSha256': v.modelSha256,
      'language': v.language,
      'languageDetected': v.languageDetected,
    };
    final confidence = v.languageConfidence;
    if (confidence != null && confidence.isFinite) j['languageConfidence'] = _num(confidence);
    final seg = <String, Object?>{
      if (v.segmentation.preset != SegmentationPreset.standard) 'preset': v.segmentation.preset.name,
      if (v.segmentation.maxLines != 0) 'maxLines': v.segmentation.maxLines,
      if (v.segmentation.maxCharsPerLine != 0) 'maxCharsPerLine': v.segmentation.maxCharsPerLine,
    };
    _putNum(seg, 'maxCharsPerSecond', v.segmentation.maxCharsPerSecond, 0);
    if (seg.isNotEmpty) j['segmentation'] = seg;
    final scope = <String, Object?>{
      if (v.scope.clips.isNotEmpty) 'clips': v.scope.clips,
      if (v.scope.tracks.isNotEmpty) 'tracks': v.scope.tracks,
      if (v.scope.range != null) 'range': _range(v.scope.range!),
    };
    if (scope.isNotEmpty) j['scope'] = scope;
    if (v.transcriptKeys.isNotEmpty) j['transcriptKeys'] = v.transcriptKeys;
    j['generatedAt'] = _time(v.generatedAt);
    if (v.schema != 1) j['schema'] = v.schema;
    return j;
  }

  // ---------------------------------------------------------------- items

  static Map<String, Object?> _item(TimelineItem item) => switch (item) {
        MediaClip() => _clip(item),
        TextItem() => _text(item),
        SubtitleCue() => _cue(item),
      };

  static Map<String, Object?> _clip(MediaClip c) {
    final j = <String, Object?>{'t': 'clip', 'id': c.id, 'start': c.start, 'dur': c.duration, 'media': c.media};
    if (c.sourceIn != 0) j['in'] = c.sourceIn;
    final speed = _speed(c.speed);
    if (speed != null) j['speed'] = speed;
    if (!c.maintainPitch) j['pitch'] = false;
    if (c.reversed) j['reversed'] = true;
    if (c.audioStream != null) j['stream'] = c.audioStream;
    if (c.visual != null) j['visual'] = _visual(c.visual!);
    final audio = _audio(c.audio);
    if (audio.isNotEmpty) j['audio'] = audio;
    if (c.detachedAudio) j['detached'] = true;
    if (!c.keyframes.isEmpty) j['kf'] = _keyframes(c.keyframes);
    _linkAndLabel(j, c);
    return j;
  }

  static Map<String, Object?> _text(TextItem t) {
    final j = <String, Object?>{'t': 'text', 'id': t.id, 'start': t.start, 'dur': t.duration, 'text': t.text};
    final style = _textStyle(t.style);
    if (style.isNotEmpty) j['style'] = style;
    final anim = _animation(t.animation);
    if (anim.isNotEmpty) j['anim'] = anim;
    final xf = _transform(t.transform);
    if (xf.isNotEmpty) j['xf'] = xf;
    if (!t.keyframes.isEmpty) j['kf'] = _keyframes(t.keyframes);
    _linkAndLabel(j, t);
    return j;
  }

  static Map<String, Object?> _cue(SubtitleCue c) {
    final j = <String, Object?>{'t': 'cue', 'id': c.id, 'start': c.start, 'dur': c.duration, 'text': c.text};
    if (c.origin != CueOrigin.manual) j['origin'] = c.origin.name;
    if (c.editedAfterGeneration) j['edited'] = true;
    _linkAndLabel(j, c);
    return j;
  }

  static void _linkAndLabel(Map<String, Object?> j, TimelineItem item) {
    if (item.link != null) j['link'] = item.link;
    if (item.label != null) j['label'] = item.label;
  }

  static Map<String, Object?>? _speed(SpeedSpec s) => switch (s) {
        ConstantSpeed(:final rate) => rate == 1 || !rate.isFinite ? null : {'c': _num(rate)},
        SpeedRamp(:final points, :final presetId) => {
            'ramp': [
              for (final pt in points) [_num(pt.x), _num(pt.y)],
            ],
            if (presetId != null) 'preset': presetId,
          },
      };

  static Map<String, Object?> _visual(VisualProps v) {
    final j = <String, Object?>{};
    final xf = _transform(v.transform);
    if (xf.isNotEmpty) j['xf'] = xf;
    if (v.fit != FitMode.fit) j['fit'] = v.fit.name;
    if (v.crop != CropRect.full) j['crop'] = [_num(v.crop.left), _num(v.crop.top), _num(v.crop.right), _num(v.crop.bottom)];
    final a = v.adjust;
    final adj = <String, Object?>{};
    _putNum(adj, 'exposure', a.exposure, 0);
    _putNum(adj, 'brightness', a.brightness, 0);
    _putNum(adj, 'contrast', a.contrast, 0);
    _putNum(adj, 'highlights', a.highlights, 0);
    _putNum(adj, 'shadows', a.shadows, 0);
    _putNum(adj, 'saturation', a.saturation, 0);
    _putNum(adj, 'temperature', a.temperature, 0);
    _putNum(adj, 'tint', a.tint, 0);
    if (adj.isNotEmpty) j['adj'] = adj;
    final detail = <String, Object?>{};
    _putNum(detail, 'sharpness', v.detail.sharpness, 0);
    _putNum(detail, 'blur', v.detail.blur, 0);
    _putNum(detail, 'vignette', v.detail.vignette, 0);
    if (detail.isNotEmpty) j['detail'] = detail;
    final look = v.look;
    if (look != null) {
      final l = switch (look) {
        BuiltinLook(:final presetId) => <String, Object?>{'builtin': presetId},
        ImportedLut(:final lut) => <String, Object?>{'lut': lut},
      };
      _putNum(l, 'i', look.intensity, 1);
      j['look'] = l;
    }
    if (v.chroma != ChromaKey.off) {
      final k = v.chroma;
      final chroma = <String, Object?>{
        if (k.enabled) 'on': true,
        if (k.color != 0x00B140) 'color': _rgb(k.color),
      };
      _putNum(chroma, 'sim', k.similarity, 0.4);
      _putNum(chroma, 'smooth', k.smoothness, 0.1);
      _putNum(chroma, 'spill', k.spill, 0.3);
      j['chroma'] = chroma;
    }
    final m = v.mask;
    final mask = <String, Object?>{
      if (m.shape != MaskShape.none) 'shape': m.shape.name,
      if (m.center != const Vec2(0.5, 0.5)) 'c': _vec(m.center),
      if (m.size != const Vec2(0.6, 0.6)) 'size': _vec(m.size),
    };
    _putNum(mask, 'r', m.rotationDeg, 0);
    _putNum(mask, 'corner', m.cornerRadius, 0);
    _putNum(mask, 'feather', m.feather, 0);
    _putNum(mask, 'op', m.opacity, 1);
    if (m.invert) mask['invert'] = true;
    if (mask.isNotEmpty) j['mask'] = mask;
    return j;
  }

  static Map<String, Object?> _transform(Transform2D x) {
    final j = <String, Object?>{};
    if (x.position != Vec2.zero) j['pos'] = _vec(x.position);
    _putNum(j, 's', x.scale, 1);
    _putNum(j, 'r', x.rotationDeg, 0);
    if (x.flipH) j['flipH'] = true;
    if (x.flipV) j['flipV'] = true;
    _putNum(j, 'op', x.opacity, 1);
    return j;
  }

  static Map<String, Object?> _audio(AudioProps a) {
    final j = <String, Object?>{};
    _putNum(j, 'vol', a.volume, 1);
    if (a.muted) j['muted'] = true;
    if (a.fadeIn != 0) j['fadeIn'] = a.fadeIn;
    if (a.fadeOut != 0) j['fadeOut'] = a.fadeOut;
    return j;
  }

  static Map<String, Object?> _keyframes(KeyframeSet set) {
    final channels = set.byChannel.keys.toList()..sort();
    return {
      for (final ch in channels)
        ch: [
          for (final k in set.byChannel[ch]!.keys) [k.t, _num(k.v)],
        ],
    };
  }

  static Map<String, Object?> _textStyle(TextStyleSpec s) {
    final j = <String, Object?>{};
    if (s.fontFamily != 'figtree') j['font'] = s.fontFamily;
    _putNum(j, 'size', s.fontSizePt, 48);
    if (s.bold) j['bold'] = true;
    if (s.italic) j['italic'] = true;
    if (s.align != TextAlignH.center) j['align'] = s.align.name;
    if (s.color != 0xFFFFFFFF) j['color'] = _color(s.color);
    _putNum(j, 'spacing', s.letterSpacing, 0);
    _putNum(j, 'lineHeight', s.lineHeight, 1.2);
    _putNum(j, 'maxWidth', s.maxWidth, 0.9);
    if (s.background != null) j['box'] = _box(s.background!);
    if (s.stroke != null) j['stroke'] = _stroke(s.stroke!);
    if (s.shadow != null) j['shadow'] = _shadow(s.shadow!);
    return j;
  }

  static Map<String, Object?> _box(BoxStyle b) {
    final j = <String, Object?>{};
    if (b.color != 0xFF000000) j['color'] = _color(b.color);
    _putNum(j, 'op', b.opacity, 0.6);
    _putNum(j, 'pad', b.paddingPt, 12);
    _putNum(j, 'radius', b.cornerRadiusPt, 8);
    return j;
  }

  static Map<String, Object?> _stroke(StrokeStyle s) {
    final j = <String, Object?>{};
    if (s.color != 0xFF000000) j['color'] = _color(s.color);
    _putNum(j, 'width', s.widthPt, 2);
    return j;
  }

  static Map<String, Object?> _shadow(ShadowStyle s) {
    final j = <String, Object?>{};
    if (s.color != 0xFF000000) j['color'] = _color(s.color);
    _putNum(j, 'op', s.opacity, 0.5);
    _putNum(j, 'blur', s.blurPt, 6);
    _putNum(j, 'dist', s.distancePt, 3);
    _putNum(j, 'angle', s.angleDeg, 90);
    return j;
  }

  static Map<String, Object?> _animation(TextAnimation a) => {
        if (a.inKind != TextAnimKind.none) 'in': a.inKind.name,
        if (a.inDirection != TextSlideDirection.up) 'inDir': a.inDirection.name,
        if (a.inDuration != 0) 'inDur': a.inDuration,
        if (a.outKind != TextAnimKind.none) 'out': a.outKind.name,
        if (a.outDirection != TextSlideDirection.down) 'outDir': a.outDirection.name,
        if (a.outDuration != 0) 'outDur': a.outDuration,
      };

  // ---------------------------------------------------------------- pool

  Map<String, Object?> _asset(MediaAsset a) {
    final j = <String, Object?>{
      'id': a.id,
      'kind': a.kind.name,
      'name': _displayName(a.displayName),
      'loc': _locator(a.locator),
      'own': a.ownership.name,
      'fp': _fingerprint(a.fingerprint),
      'probe': _probe(a.probe),
      'origin': a.origin.name,
    };
    final derived = a.derived;
    switch (derived) {
      case ReversedSpec(:final media, :final range, :final sourceQuickHash):
        j['derived'] = {'reversed': media, 'range': _range(range), 'qh': sourceQuickHash};
      case StillSpec(:final media, :final sourceTime, :final sourceQuickHash):
        j['derived'] = {'still': media, 'at': sourceTime, 'qh': sourceQuickHash};
      case null:
        break;
    }
    switch (a.status) {
      case PendingStatus(:final jobId):
        j['status'] = {'pending': jobId};
      case FailedStatus(:final reason):
        j['status'] = {'failed': reason};
      case ReadyStatus():
        break;
    }
    if (a.proxy != ProxyState.none) j['proxy'] = a.proxy.name;
    j['added'] = _time(a.addedAt);
    return j;
  }

  Map<String, Object?> _locator(MediaLocator l) => switch (l) {
        AppRelativeLocator(:final root, :final relPath) => {'app': root.name, 'rel': relPath},
        FileLocator(:final path) => _pathLocator(path) ?? {'file': path},
        ContentUriLocator(:final uri) => _uriLocator(uri),
        BookmarkLocator(:final bookmarkB64, :final lastKnownPath) => {
            'bookmark': bookmarkB64,
            if (lastKnownPath.isNotEmpty) 'hint': lastKnownPath,
          },
      };

  /// The persisted form of an absolute path inside an app root or container, or null when the
  /// path is outside every app root and container (then it is kept as is).
  Map<String, Object?>? _pathLocator(String path) {
    final rel = _relativizer?.call(path) ?? AppContainerPaths.relativize(path);
    if (rel != null) return {'app': rel.root.name, 'rel': rel.relPath};
    if (AppContainerPaths.contains(path)) return {'file': _basename(path)};
    return null;
  }

  Map<String, Object?> _uriLocator(String uri) {
    if (uri.startsWith('file:')) {
      final parsed = Uri.tryParse(uri);
      if (parsed != null) {
        final persisted = _pathLocator(Uri.decodeComponent(parsed.path));
        if (persisted != null) return persisted;
      }
    }
    return {'uri': uri};
  }

  static Map<String, Object?> _fingerprint(MediaFingerprint f) => {
        'size': f.sizeBytes,
        'qh': f.quickHash,
        if (f.modifiedMs != null) 'mtime': f.modifiedMs,
        if (f.duration != 0) 'dur': f.duration,
      };

  static Map<String, Object?> _probe(MediaProbe x) {
    final j = <String, Object?>{'kind': x.kind.name};
    if (x.duration != 0) j['dur'] = x.duration;
    if (x.hasVideo) j['video'] = true;
    if (x.hasAudio) j['audio'] = true;
    if (x.width != null) j['w'] = x.width;
    if (x.height != null) j['h'] = x.height;
    if (x.rotation != 0) j['rot'] = x.rotation;
    if (x.nominalFrameRate != null) j['fps'] = _rate(x.nominalFrameRate!);
    final avg = x.nominalFps;
    if (avg != null && avg.isFinite) j['avgFps'] = _num(avg);
    if (x.variableFrameRate) j['vfr'] = true;
    if (x.container != null) j['container'] = x.container;
    if (x.videoCodec != null) j['vcodec'] = x.videoCodec;
    if (x.audioCodec != null) j['acodec'] = x.audioCodec;
    if (x.audioStreams != 0) j['streams'] = x.audioStreams;
    if (x.channels != null) j['ch'] = x.channels;
    if (x.sampleRate != null) j['sr'] = x.sampleRate;
    if (x.bitDepth != null) j['bits'] = x.bitDepth;
    if (x.transfer != ColorTransfer.sdr) j['transfer'] = x.transfer.name;
    if (x.sizeBytes != 0) j['size'] = x.sizeBytes;
    if (!x.editable) j['editable'] = false;
    if (x.issues.isNotEmpty) j['issues'] = x.issues;
    return j;
  }

  /// A display name never persists a container path: such a name keeps only its last segment.
  String _displayName(String name) => AppContainerPaths.contains(name) ? _basename(name) : name;

  static String _basename(String path) {
    final trimmed = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    final i = trimmed.lastIndexOf('/');
    return i < 0 ? trimmed : trimmed.substring(i + 1);
  }

  // ---------------------------------------------------------------- primitives

  /// Canonical number: integral finite doubles become ints (`1.0` and `1` encode alike);
  /// non-finite values (which JSON cannot hold) become 0.
  static Object _num(double d) {
    if (!d.isFinite) return 0;
    if (d == d.truncateToDouble() && d.abs() < 9007199254740992) return d.toInt();
    return d;
  }

  /// Puts [v] under [k] unless it equals [def] or is not finite (both decode to [def]).
  static void _putNum(Map<String, Object?> j, String k, double v, double def) {
    if (v == def || !v.isFinite) return;
    j[k] = _num(v);
  }

  static List<Object> _vec(Vec2 v) => [_num(v.x), _num(v.y)];

  static List<int> _range(TimeRange r) => [r.start, r.end];

  static Object _rate(FrameRate r) => r.den == 1 ? r.num : [r.num, r.den];

  static String _time(DateTime d) => d.toUtc().toIso8601String();

  static String _hex(int v, int digits) => v.toRadixString(16).padLeft(digits, '0').toUpperCase();

  /// `"#RRGGBBAA"` for an ARGB int.
  static String _color(int argb) => '#${_hex(argb & 0xFFFFFF, 6)}${_hex((argb >> 24) & 0xFF, 2)}';

  /// `"#RRGGBB"` for an RGB int (`"#RRGGBBAA"` if bits above 24 are set, so nothing is lost).
  static String _rgb(int rgb) => ((rgb >> 24) & 0xFF) == 0 ? '#${_hex(rgb & 0xFFFFFF, 6)}' : _color(rgb);

  // =============================================================================================
  // Decoding
  // =============================================================================================

  /// Decodes a body line. Throws [ProjectFormatException] when it is not a well-formed body;
  /// unknown values only produce warnings.
  ProjectDecodeResult decode(String body) {
    final Object? raw;
    try {
      raw = jsonDecode(body);
    } on FormatException catch (e) {
      throw ProjectFormatException('body is not JSON: ${e.message}');
    }
    return decodeJson(_Decoder._obj(raw, ''));
  }

  /// Decodes UTF-8 body bytes (see [decode]).
  ProjectDecodeResult decodeBytes(Uint8List body) {
    final String text;
    try {
      text = utf8.decode(body);
    } on FormatException {
      throw const ProjectFormatException('body is not UTF-8');
    }
    return decode(text);
  }

  /// Decodes a body that is already a JSON object tree (for example after `Migrations` ran on the
  /// raw map, ARCH §8.5).
  ProjectDecodeResult decodeJson(Map<String, Object?> body) {
    final d = _Decoder();
    final project = d.project(body);
    return ProjectDecodeResult(project, d.warnings());
  }
}

/// One decode run: field readers plus the warning tally.
final class _Decoder {
  // (code, subject) → count, in first-seen order.
  final Map<(String, String), int> _tally = {};

  void _warn(String code, String subject) => _tally.update((code, subject), (n) => n + 1, ifAbsent: () => 1);

  List<ProjectOpenWarning> warnings() => [
        for (final e in _tally.entries)
          ProjectOpenWarning(e.key.$1, e.value == 1 ? e.key.$2 : '${e.key.$2} (${e.value}×)'),
      ];

  static String _clip(String s) => s.length <= 40 ? s : '${s.substring(0, 40)}…';

  // ---------------------------------------------------------------- root

  EditProject project(Map<String, Object?> j) {
    final tracks = <Track>[];
    for (final (i, raw) in _list(j['tracks'], 'tracks').indexed) {
      final t = track(_obj(raw, 'tracks[$i]'), 'tracks[$i]');
      if (t != null) tracks.add(t);
    }
    final markers = [
      for (final (i, raw) in _optList(j, 'markers', '').indexed) marker(_obj(raw, 'markers[$i]'), 'markers[$i]'),
    ];
    return EditProject(
      id: ProjectId(_str(j, 'id', '')),
      meta: meta(_obj(j['meta'], 'meta')),
      timeline: Timeline(
        settings: j['settings'] == null ? const ProjectSettings() : settings(_obj(j['settings'], 'settings')),
        tracks: tracks,
        markers: markers,
        revision: _optInt(j, 'rev', '') ?? 0,
      ),
      pool: j['pool'] == null ? MediaPool.empty : pool(_obj(j['pool'], 'pool')),
      view: j['view'] == null ? ViewState.initial : view(_obj(j['view'], 'view')),
      docRevision: _optInt(j, 'docRev', '') ?? 0,
    );
  }

  ProjectMeta meta(Map<String, Object?> j) {
    ProjectOrigin origin = ProjectOrigin.projects;
    final o = j['origin'];
    if (o != null) {
      final m = _obj(o, 'meta.origin');
      if (m.containsKey('player')) {
        origin = FromPlayerOrigin(
          quickHash: _str(m, 'player', 'meta.origin'),
          sizeBytes: _optInt(m, 'size', 'meta.origin') ?? 0,
          displayName: _optStr(m, 'name', 'meta.origin') ?? '',
        );
      } else {
        _warn(ProjectCodecWarnings.unknownVariant, 'meta.origin');
      }
    }
    return ProjectMeta(
      name: _str(j, 'name', 'meta'),
      createdAt: _date(j, 'created', 'meta'),
      updatedAt: _date(j, 'updated', 'meta'),
      origin: origin,
      editCount: _optInt(j, 'edits', 'meta') ?? 0,
    );
  }

  ProjectSettings settings(Map<String, Object?> j) {
    var canvas = const CanvasSpec();
    if (j['canvas'] != null) {
      final c = _obj(j['canvas'], 'settings.canvas');
      var aspect = AspectRatio.landscape16x9;
      if (c['aspect'] != null) {
        final a = _list(c['aspect'], 'settings.canvas.aspect');
        if (a.length != 2) throw const ProjectFormatException('expected [w, h]', 'settings.canvas.aspect');
        final w = _asInt(a[0], 'settings.canvas.aspect[0]');
        final h = _asInt(a[1], 'settings.canvas.aspect[1]');
        if (w <= 0 || h <= 0) throw const ProjectFormatException('aspect terms must be positive', 'settings.canvas.aspect');
        aspect = AspectRatio(w, h);
      }
      canvas = CanvasSpec(aspect: aspect, baseShortSide: _optInt(c, 'short', 'settings.canvas') ?? 1080);
    }
    var background = BackgroundSpec.black;
    if (j['bg'] != null) {
      final b = _obj(j['bg'], 'settings.bg');
      if (b.containsKey('solid')) {
        background = SolidBackground(_color(_str(b, 'solid', 'settings.bg'), 'settings.bg.solid'));
      } else if (b.containsKey('blur')) {
        background = BlurOfMainBackground(_dbl(b, 'blur', 0, 'settings.bg'));
      } else {
        _warn(ProjectCodecWarnings.unknownVariant, 'settings.bg');
      }
    }
    return ProjectSettings(
      canvas: canvas,
      frameRate: j['fps'] == null ? FrameRate.fps30 : _rate(j['fps'], 'settings.fps'),
      background: background,
      audioSampleRate: _optInt(j, 'sampleRate', 'settings') ?? 48000,
    );
  }

  ViewState view(Map<String, Object?> j) => ViewState(
        playhead: _optInt(j, 'playhead', 'view') ?? 0,
        pixelsPerSecond: _dbl(j, 'pps', 0, 'view'),
        scrollTimeUs: _optInt(j, 'scrollT', 'view') ?? 0,
        scrollLanePx: _dbl(j, 'scrollY', 0, 'view'),
        rippleEnabled: _bool(j, 'ripple', true, 'view'),
        snappingEnabled: _bool(j, 'snap', true, 'view'),
        followMode: _optEnum(PlayheadFollowMode.values, j['follow'], 'view.follow'),
        lastExportPresetId: _optStr(j, 'exportPreset', 'view'),
      );

  Marker marker(Map<String, Object?> j, String p) => Marker(
        id: MarkerId(_str(j, 'id', p)),
        time: _int(j, 'time', p),
        name: _optStr(j, 'name', p) ?? '',
        colorIndex: _optInt(j, 'color', p) ?? 0,
        note: _optStr(j, 'note', p),
      );

  // ---------------------------------------------------------------- tracks

  Track? track(Map<String, Object?> j, String p) {
    final kindName = _str(j, 'kind', p);
    final kind = _byName(TrackKind.values, kindName);
    if (kind == null) {
      _warn(ProjectCodecWarnings.unknownTrackDropped, 'kind "${_clip(kindName)}"');
      return null;
    }
    final items = <TimelineItem>[];
    for (final (i, raw) in _optList(j, 'items', p).indexed) {
      final item = this.item(_obj(raw, '$p.items[$i]'), '$p.items[$i]');
      if (item != null) items.add(item);
    }
    final transitions = <Transition>[
      for (final (i, raw) in _optList(j, 'tx', p).indexed) transition(_obj(raw, '$p.tx[$i]'), '$p.tx[$i]'),
    ];
    return Track(
      id: TrackId(_str(j, 'id', p)),
      kind: kind,
      name: _optStr(j, 'name', p) ?? '',
      isMain: _bool(j, 'main', false, p),
      locked: _bool(j, 'locked', false, p),
      hidden: _bool(j, 'hidden', false, p),
      muted: _bool(j, 'muted', false, p),
      solo: _bool(j, 'solo', false, p),
      audioRole: _optEnum(AudioRole.values, j['role'], 'track.role'),
      subtitle: j['sub'] == null ? null : subtitleTrack(_obj(j['sub'], '$p.sub'), '$p.sub'),
      items: items,
      transitions: transitions,
      changedAt: _optInt(j, 'chg', p) ?? 0,
    );
  }

  Transition transition(Map<String, Object?> j, String p) => Transition(
        id: TransitionId(_str(j, 'id', p)),
        left: ItemId(_str(j, 'left', p)),
        right: ItemId(_str(j, 'right', p)),
        kind: _enum(TransitionKind.values, j['kind'], TransitionKind.fade, 'transition.kind', '$p.kind'),
        durationFrames: _int(j, 'frames', p),
        direction: _optEnum(TransitionDirection.values, j['dir'], 'transition.dir'),
      );

  SubtitleTrackData subtitleTrack(Map<String, Object?> j, String p) {
    var position = SubtitlePosition.bottom;
    final pos = j['pos'];
    if (pos is String) {
      switch (pos) {
        case 'bottom':
          break;
        case 'top':
          position = SubtitlePosition.top;
        default:
          _warn(ProjectCodecWarnings.unknownEnum, 'subtitle.pos: "${_clip(pos)}"');
      }
    } else if (pos != null) {
      final m = _obj(pos, '$p.pos');
      if (m.containsKey('y')) {
        position = CustomSubtitlePosition(_dbl(m, 'y', 0, '$p.pos'));
      } else {
        _warn(ProjectCodecWarnings.unknownVariant, 'subtitle.pos');
      }
    }
    return SubtitleTrackData(
      language: _optStr(j, 'lang', p),
      style: j['style'] == null ? const SubtitleStyle() : subtitleStyle(_obj(j['style'], '$p.style'), '$p.style'),
      position: position,
      burnIn: _bool(j, 'burnIn', true, p),
      provenance: j['prov'] == null ? null : provenance(_obj(j['prov'], '$p.prov'), '$p.prov'),
    );
  }

  SubtitleStyle subtitleStyle(Map<String, Object?> j, String p) => SubtitleStyle(
        fontFamily: _optStr(j, 'font', p) ?? 'figtree',
        fontSizePt: _dbl(j, 'size', 42, p),
        bold: _bool(j, 'bold', false, p),
        italic: _bool(j, 'italic', false, p),
        color: j['color'] == null ? 0xFFFFFFFF : _color(_str(j, 'color', p), '$p.color'),
        background: !j.containsKey('box')
            ? const BoxStyle()
            : (j['box'] == null ? null : box(_obj(j['box'], '$p.box'), '$p.box')),
        outline: j['outline'] == null ? null : stroke(_obj(j['outline'], '$p.outline'), '$p.outline'),
        shadow: j['shadow'] == null ? null : shadow(_obj(j['shadow'], '$p.shadow'), '$p.shadow'),
        maxLines: _optInt(j, 'maxLines', p) ?? 2,
        maxWidth: _dbl(j, 'maxWidth', 0.9, p),
        align: _enum(TextAlignH.values, j['align'], TextAlignH.center, 'subtitle.style.align', '$p.align'),
      );

  CaptionProvenance provenance(Map<String, Object?> j, String p) {
    var segmentation = const SegmentationSettings();
    if (j['segmentation'] != null) {
      final s = _obj(j['segmentation'], '$p.segmentation');
      final sp = '$p.segmentation';
      segmentation = SegmentationSettings(
        preset: _enum(SegmentationPreset.values, s['preset'], SegmentationPreset.standard, 'provenance.segmentation.preset', '$sp.preset'),
        maxLines: _optInt(s, 'maxLines', sp) ?? 0,
        maxCharsPerLine: _optInt(s, 'maxCharsPerLine', sp) ?? 0,
        maxCharsPerSecond: _dbl(s, 'maxCharsPerSecond', 0, sp),
      );
    }
    var scope = CaptionScopeData();
    if (j['scope'] != null) {
      final s = _obj(j['scope'], '$p.scope');
      final sp = '$p.scope';
      scope = CaptionScopeData(
        clips: [for (final id in _strings(s, 'clips', sp)) ItemId(id)],
        tracks: [for (final id in _strings(s, 'tracks', sp)) TrackId(id)],
        range: s['range'] == null ? null : _range(s['range'], '$sp.range'),
      );
    }
    return CaptionProvenance(
      generator: _str(j, 'generator', p),
      engineVersion: _str(j, 'engineVersion', p),
      modelId: _str(j, 'modelId', p),
      modelSha256: _str(j, 'modelSha256', p),
      language: _str(j, 'language', p),
      languageDetected: _bool(j, 'languageDetected', false, p),
      languageConfidence: _optDbl(j, 'languageConfidence', p),
      segmentation: segmentation,
      scope: scope,
      transcriptKeys: _strings(j, 'transcriptKeys', p),
      generatedAt: _date(j, 'generatedAt', p),
      schema: _optInt(j, 'schema', p) ?? 1,
    );
  }

  // ---------------------------------------------------------------- items

  TimelineItem? item(Map<String, Object?> j, String p) {
    final tag = _str(j, 't', p);
    switch (tag) {
      case 'clip':
        return clip(j, p);
      case 'text':
        return text(j, p);
      case 'cue':
        return cue(j, p);
    }
    _warn(ProjectCodecWarnings.unknownItemDropped, 'item tag "${_clip(tag)}"');
    return null;
  }

  MediaClip clip(Map<String, Object?> j, String p) => MediaClip(
        id: ItemId(_str(j, 'id', p)),
        start: _int(j, 'start', p),
        duration: _int(j, 'dur', p),
        link: _optLink(j, p),
        label: _optStr(j, 'label', p),
        media: MediaId(_str(j, 'media', p)),
        sourceIn: _optInt(j, 'in', p) ?? 0,
        speed: j['speed'] == null ? SpeedSpec.normal : speed(_obj(j['speed'], '$p.speed'), '$p.speed'),
        maintainPitch: _bool(j, 'pitch', true, p),
        reversed: _bool(j, 'reversed', false, p),
        audioStream: _optInt(j, 'stream', p),
        visual: j['visual'] == null ? null : visual(_obj(j['visual'], '$p.visual'), '$p.visual'),
        audio: j['audio'] == null ? AudioProps.unity : audio(_obj(j['audio'], '$p.audio'), '$p.audio'),
        detachedAudio: _bool(j, 'detached', false, p),
        keyframes: j['kf'] == null ? KeyframeSet.empty : keyframes(_obj(j['kf'], '$p.kf'), '$p.kf'),
      );

  TextItem text(Map<String, Object?> j, String p) => TextItem(
        id: ItemId(_str(j, 'id', p)),
        start: _int(j, 'start', p),
        duration: _int(j, 'dur', p),
        link: _optLink(j, p),
        label: _optStr(j, 'label', p),
        text: _str(j, 'text', p),
        style: j['style'] == null ? const TextStyleSpec() : textStyle(_obj(j['style'], '$p.style'), '$p.style'),
        animation: j['anim'] == null ? TextAnimation.none : animation(_obj(j['anim'], '$p.anim'), '$p.anim'),
        transform: j['xf'] == null ? Transform2D.identity : transform(_obj(j['xf'], '$p.xf'), '$p.xf'),
        keyframes: j['kf'] == null ? KeyframeSet.empty : keyframes(_obj(j['kf'], '$p.kf'), '$p.kf'),
      );

  SubtitleCue cue(Map<String, Object?> j, String p) => SubtitleCue(
        id: ItemId(_str(j, 'id', p)),
        start: _int(j, 'start', p),
        duration: _int(j, 'dur', p),
        link: _optLink(j, p),
        label: _optStr(j, 'label', p),
        text: _str(j, 'text', p),
        origin: _enum(CueOrigin.values, j['origin'], CueOrigin.manual, 'cue.origin', '$p.origin'),
        editedAfterGeneration: _bool(j, 'edited', false, p),
      );

  LinkId? _optLink(Map<String, Object?> j, String p) {
    final s = _optStr(j, 'link', p);
    return s == null ? null : LinkId(s);
  }

  SpeedSpec speed(Map<String, Object?> j, String p) {
    if (j.containsKey('c')) return ConstantSpeed(_dbl(j, 'c', 1, p));
    if (j.containsKey('ramp')) {
      final points = <SpeedPoint>[];
      for (final (i, raw) in _list(j['ramp'], '$p.ramp').indexed) {
        final pt = _list(raw, '$p.ramp[$i]');
        if (pt.length != 2) throw ProjectFormatException('expected [x, y]', '$p.ramp[$i]');
        points.add(SpeedPoint(_asDouble(pt[0], '$p.ramp[$i][0]'), _asDouble(pt[1], '$p.ramp[$i][1]')));
      }
      return SpeedRamp(points, presetId: _optStr(j, 'preset', p));
    }
    _warn(ProjectCodecWarnings.unknownVariant, 'clip.speed');
    return SpeedSpec.normal;
  }

  VisualProps visual(Map<String, Object?> j, String p) {
    var crop = CropRect.full;
    if (j['crop'] != null) {
      final c = _list(j['crop'], '$p.crop');
      if (c.length != 4) throw ProjectFormatException('expected [l, t, r, b]', '$p.crop');
      crop = CropRect(
        left: _asDouble(c[0], '$p.crop[0]'),
        top: _asDouble(c[1], '$p.crop[1]'),
        right: _asDouble(c[2], '$p.crop[2]'),
        bottom: _asDouble(c[3], '$p.crop[3]'),
      );
    }
    var adjust = ColorAdjust.neutral;
    if (j['adj'] != null) {
      final a = _obj(j['adj'], '$p.adj');
      final ap = '$p.adj';
      adjust = ColorAdjust(
        exposure: _dbl(a, 'exposure', 0, ap),
        brightness: _dbl(a, 'brightness', 0, ap),
        contrast: _dbl(a, 'contrast', 0, ap),
        highlights: _dbl(a, 'highlights', 0, ap),
        shadows: _dbl(a, 'shadows', 0, ap),
        saturation: _dbl(a, 'saturation', 0, ap),
        temperature: _dbl(a, 'temperature', 0, ap),
        tint: _dbl(a, 'tint', 0, ap),
      );
    }
    var detail = DetailFx.none;
    if (j['detail'] != null) {
      final d = _obj(j['detail'], '$p.detail');
      final dp = '$p.detail';
      detail = DetailFx(sharpness: _dbl(d, 'sharpness', 0, dp), blur: _dbl(d, 'blur', 0, dp), vignette: _dbl(d, 'vignette', 0, dp));
    }
    LookRef? look;
    if (j['look'] != null) {
      final l = _obj(j['look'], '$p.look');
      final intensity = _dbl(l, 'i', 1, '$p.look');
      if (l.containsKey('builtin')) {
        look = BuiltinLook(_str(l, 'builtin', '$p.look'), intensity: intensity);
      } else if (l.containsKey('lut')) {
        look = ImportedLut(MediaId(_str(l, 'lut', '$p.look')), intensity: intensity);
      } else {
        _warn(ProjectCodecWarnings.unknownVariant, 'clip.visual.look');
      }
    }
    var chroma = ChromaKey.off;
    if (j['chroma'] != null) {
      final c = _obj(j['chroma'], '$p.chroma');
      final cp = '$p.chroma';
      chroma = ChromaKey(
        enabled: _bool(c, 'on', false, cp),
        color: c['color'] == null ? 0x00B140 : _rgb(_str(c, 'color', cp), '$cp.color'),
        similarity: _dbl(c, 'sim', 0.4, cp),
        smoothness: _dbl(c, 'smooth', 0.1, cp),
        spill: _dbl(c, 'spill', 0.3, cp),
      );
    }
    var mask = MaskSpec.none;
    if (j['mask'] != null) {
      final m = _obj(j['mask'], '$p.mask');
      final mp = '$p.mask';
      mask = MaskSpec(
        shape: _enum(MaskShape.values, m['shape'], MaskShape.none, 'clip.visual.mask.shape', '$mp.shape'),
        center: m['c'] == null ? const Vec2(0.5, 0.5) : _vec(m['c'], '$mp.c'),
        size: m['size'] == null ? const Vec2(0.6, 0.6) : _vec(m['size'], '$mp.size'),
        rotationDeg: _dbl(m, 'r', 0, mp),
        cornerRadius: _dbl(m, 'corner', 0, mp),
        feather: _dbl(m, 'feather', 0, mp),
        opacity: _dbl(m, 'op', 1, mp),
        invert: _bool(m, 'invert', false, mp),
      );
    }
    return VisualProps(
      transform: j['xf'] == null ? Transform2D.identity : transform(_obj(j['xf'], '$p.xf'), '$p.xf'),
      fit: _enum(FitMode.values, j['fit'], FitMode.fit, 'clip.visual.fit', '$p.fit'),
      crop: crop,
      adjust: adjust,
      detail: detail,
      look: look,
      chroma: chroma,
      mask: mask,
    );
  }

  Transform2D transform(Map<String, Object?> j, String p) => Transform2D(
        position: j['pos'] == null ? Vec2.zero : _vec(j['pos'], '$p.pos'),
        scale: _dbl(j, 's', 1, p),
        rotationDeg: _dbl(j, 'r', 0, p),
        flipH: _bool(j, 'flipH', false, p),
        flipV: _bool(j, 'flipV', false, p),
        opacity: _dbl(j, 'op', 1, p),
      );

  AudioProps audio(Map<String, Object?> j, String p) => AudioProps(
        volume: _dbl(j, 'vol', 1, p),
        muted: _bool(j, 'muted', false, p),
        fadeIn: _optInt(j, 'fadeIn', p) ?? 0,
        fadeOut: _optInt(j, 'fadeOut', p) ?? 0,
      );

  KeyframeSet keyframes(Map<String, Object?> j, String p) {
    if (j.isEmpty) return KeyframeSet.empty;
    final byChannel = <String, KeyframeTrack>{};
    for (final e in j.entries) {
      final cp = '$p.${e.key}';
      byChannel[e.key] = KeyframeTrack([
        for (final (i, raw) in _list(e.value, cp).indexed)
          () {
            final k = _list(raw, '$cp[$i]');
            if (k.length != 2) throw ProjectFormatException('expected [t, v]', '$cp[$i]');
            return Keyframe(_asInt(k[0], '$cp[$i][0]'), _asDouble(k[1], '$cp[$i][1]'));
          }(),
      ]);
    }
    return KeyframeSet(byChannel);
  }

  TextStyleSpec textStyle(Map<String, Object?> j, String p) => TextStyleSpec(
        fontFamily: _optStr(j, 'font', p) ?? 'figtree',
        fontSizePt: _dbl(j, 'size', 48, p),
        bold: _bool(j, 'bold', false, p),
        italic: _bool(j, 'italic', false, p),
        align: _enum(TextAlignH.values, j['align'], TextAlignH.center, 'text.style.align', '$p.align'),
        color: j['color'] == null ? 0xFFFFFFFF : _color(_str(j, 'color', p), '$p.color'),
        letterSpacing: _dbl(j, 'spacing', 0, p),
        lineHeight: _dbl(j, 'lineHeight', 1.2, p),
        maxWidth: _dbl(j, 'maxWidth', 0.9, p),
        background: j['box'] == null ? null : box(_obj(j['box'], '$p.box'), '$p.box'),
        stroke: j['stroke'] == null ? null : stroke(_obj(j['stroke'], '$p.stroke'), '$p.stroke'),
        shadow: j['shadow'] == null ? null : shadow(_obj(j['shadow'], '$p.shadow'), '$p.shadow'),
      );

  BoxStyle box(Map<String, Object?> j, String p) => BoxStyle(
        color: j['color'] == null ? 0xFF000000 : _color(_str(j, 'color', p), '$p.color'),
        opacity: _dbl(j, 'op', 0.6, p),
        paddingPt: _dbl(j, 'pad', 12, p),
        cornerRadiusPt: _dbl(j, 'radius', 8, p),
      );

  StrokeStyle stroke(Map<String, Object?> j, String p) => StrokeStyle(
        color: j['color'] == null ? 0xFF000000 : _color(_str(j, 'color', p), '$p.color'),
        widthPt: _dbl(j, 'width', 2, p),
      );

  ShadowStyle shadow(Map<String, Object?> j, String p) => ShadowStyle(
        color: j['color'] == null ? 0xFF000000 : _color(_str(j, 'color', p), '$p.color'),
        opacity: _dbl(j, 'op', 0.5, p),
        blurPt: _dbl(j, 'blur', 6, p),
        distancePt: _dbl(j, 'dist', 3, p),
        angleDeg: _dbl(j, 'angle', 90, p),
      );

  TextAnimation animation(Map<String, Object?> j, String p) => TextAnimation(
        inKind: _enum(TextAnimKind.values, j['in'], TextAnimKind.none, 'text.anim.in', '$p.in'),
        inDirection: _enum(TextSlideDirection.values, j['inDir'], TextSlideDirection.up, 'text.anim.inDir', '$p.inDir'),
        inDuration: _optInt(j, 'inDur', p) ?? 0,
        outKind: _enum(TextAnimKind.values, j['out'], TextAnimKind.none, 'text.anim.out', '$p.out'),
        outDirection:
            _enum(TextSlideDirection.values, j['outDir'], TextSlideDirection.down, 'text.anim.outDir', '$p.outDir'),
        outDuration: _optInt(j, 'outDur', p) ?? 0,
      );

  // ---------------------------------------------------------------- pool

  MediaPool pool(Map<String, Object?> j) {
    final assets = <MediaId, MediaAsset>{};
    for (final (i, raw) in _optList(j, 'assets', 'pool').indexed) {
      final a = asset(_obj(raw, 'pool.assets[$i]'), 'pool.assets[$i]');
      if (a != null) assets[a.id] = a;
    }
    return assets.isEmpty ? MediaPool.empty : MediaPool(assets);
  }

  MediaAsset? asset(Map<String, Object?> j, String p) {
    final kindName = _str(j, 'kind', p);
    final kind = _byName(MediaKind.values, kindName);
    if (kind == null) {
      _warn(ProjectCodecWarnings.unknownAssetDropped, 'kind "${_clip(kindName)}"');
      return null;
    }
    DerivedSpec? derived;
    if (j['derived'] != null) {
      final d = _obj(j['derived'], '$p.derived');
      final dp = '$p.derived';
      if (d.containsKey('reversed')) {
        derived = ReversedSpec(MediaId(_str(d, 'reversed', dp)), _range(d['range'], '$dp.range'), sourceQuickHash: _str(d, 'qh', dp));
      } else if (d.containsKey('still')) {
        derived = StillSpec(MediaId(_str(d, 'still', dp)), _int(d, 'at', dp), sourceQuickHash: _str(d, 'qh', dp));
      } else {
        _warn(ProjectCodecWarnings.unknownVariant, 'asset.derived');
      }
    }
    AssetStatus status = AssetStatus.ready;
    if (j['status'] != null) {
      final s = _obj(j['status'], '$p.status');
      if (s.containsKey('pending')) {
        status = PendingStatus(_str(s, 'pending', '$p.status'));
      } else if (s.containsKey('failed')) {
        status = FailedStatus(_str(s, 'failed', '$p.status'));
      } else {
        _warn(ProjectCodecWarnings.unknownVariant, 'asset.status');
      }
    }
    return MediaAsset(
      id: MediaId(_str(j, 'id', p)),
      kind: kind,
      displayName: _str(j, 'name', p),
      locator: locator(_obj(j['loc'], '$p.loc'), '$p.loc'),
      ownership: _enum(MediaOwnership.values, j['own'], MediaOwnership.external, 'asset.own', '$p.own'),
      fingerprint: fingerprint(_obj(j['fp'], '$p.fp'), '$p.fp'),
      probe: probe(_obj(j['probe'], '$p.probe'), '$p.probe', kind),
      origin: _enum(MediaOrigin.values, j['origin'], MediaOrigin.files, 'asset.origin', '$p.origin'),
      derived: derived,
      status: status,
      proxy: _enum(ProxyState.values, j['proxy'], ProxyState.none, 'asset.proxy', '$p.proxy'),
      addedAt: _date(j, 'added', p),
    );
  }

  MediaLocator locator(Map<String, Object?> j, String p) {
    if (j.containsKey('app')) {
      return AppRelativeLocator(
        _enum(AppRoot.values, j['app'], AppRoot.support, 'asset.loc.app', '$p.app'),
        _str(j, 'rel', p),
      );
    }
    if (j.containsKey('file')) return FileLocator(_str(j, 'file', p));
    if (j.containsKey('uri')) return ContentUriLocator(_str(j, 'uri', p));
    if (j.containsKey('bookmark')) return BookmarkLocator(_str(j, 'bookmark', p), lastKnownPath: _optStr(j, 'hint', p) ?? '');
    // An unknown locator kind cannot be resolved: the asset reads as missing and relink takes over.
    _warn(ProjectCodecWarnings.unknownVariant, 'asset.loc');
    return const FileLocator('');
  }

  MediaFingerprint fingerprint(Map<String, Object?> j, String p) => MediaFingerprint(
        sizeBytes: _int(j, 'size', p),
        quickHash: _str(j, 'qh', p),
        modifiedMs: _optInt(j, 'mtime', p),
        duration: _optInt(j, 'dur', p) ?? 0,
      );

  MediaProbe probe(Map<String, Object?> j, String p, MediaKind assetKind) => MediaProbe(
        kind: _enum(MediaKind.values, j['kind'], assetKind, 'asset.probe.kind', '$p.kind'),
        duration: _optInt(j, 'dur', p) ?? 0,
        hasVideo: _bool(j, 'video', false, p),
        hasAudio: _bool(j, 'audio', false, p),
        width: _optInt(j, 'w', p),
        height: _optInt(j, 'h', p),
        rotation: _optInt(j, 'rot', p) ?? 0,
        nominalFrameRate: j['fps'] == null ? null : _rate(j['fps'], '$p.fps'),
        nominalFps: _optDbl(j, 'avgFps', p),
        variableFrameRate: _bool(j, 'vfr', false, p),
        container: _optStr(j, 'container', p),
        videoCodec: _optStr(j, 'vcodec', p),
        audioCodec: _optStr(j, 'acodec', p),
        audioStreams: _optInt(j, 'streams', p) ?? 0,
        channels: _optInt(j, 'ch', p),
        sampleRate: _optInt(j, 'sr', p),
        bitDepth: _optInt(j, 'bits', p),
        transfer: _enum(ColorTransfer.values, j['transfer'], ColorTransfer.sdr, 'asset.probe.transfer', '$p.transfer'),
        sizeBytes: _optInt(j, 'size', p) ?? 0,
        editable: _bool(j, 'editable', true, p),
        issues: _strings(j, 'issues', p),
      );

  // ---------------------------------------------------------------- enums

  static T? _byName<T extends Enum>(List<T> values, String name) {
    for (final v in values) {
      if (v.name == name) return v;
    }
    return null;
  }

  /// [raw] as a value of [values]; absent → [def]; unknown → [def] plus an `unknownEnum` warning
  /// naming [field] (a path pattern without indices) and the value.
  T _enum<T extends Enum>(List<T> values, Object? raw, T def, String field, String p) {
    if (raw == null) return def;
    if (raw is! String) throw ProjectFormatException('expected a string', p);
    final v = _byName(values, raw);
    if (v != null) return v;
    _warn(ProjectCodecWarnings.unknownEnum, '$field: "${_clip(raw)}"');
    return def;
  }

  /// Like [_enum] for nullable fields whose default is null.
  T? _optEnum<T extends Enum>(List<T> values, Object? raw, String field) {
    if (raw == null) return null;
    if (raw is! String) throw ProjectFormatException('expected a string', field);
    final v = _byName(values, raw);
    if (v == null) _warn(ProjectCodecWarnings.unknownEnum, '$field: "${_clip(raw)}"');
    return v;
  }

  // ---------------------------------------------------------------- primitives

  static String _at(String p, String k) => p.isEmpty ? k : '$p.$k';

  static Map<String, Object?> _obj(Object? raw, String p) {
    if (raw is Map<String, Object?>) return raw;
    if (raw is Map) return raw.cast<String, Object?>();
    throw ProjectFormatException('expected an object', p);
  }

  static List<Object?> _list(Object? raw, String p) {
    if (raw is List<Object?>) return raw;
    if (raw is List) return raw.cast<Object?>();
    throw ProjectFormatException('expected an array', p);
  }

  static List<Object?> _optList(Map<String, Object?> j, String k, String p) =>
      j[k] == null ? const [] : _list(j[k], _at(p, k));

  static List<String> _strings(Map<String, Object?> j, String k, String p) {
    if (j[k] == null) return const [];
    final path = _at(p, k);
    return [
      for (final (i, e) in _list(j[k], path).indexed) e is String ? e : throw ProjectFormatException('expected a string', '$path[$i]'),
    ];
  }

  static int _asInt(Object? v, String p) {
    if (v is int) return v;
    if (v is double && v.isFinite && v == v.truncateToDouble()) return v.toInt();
    throw ProjectFormatException('expected an integer', p);
  }

  static double _asDouble(Object? v, String p) {
    if (v is num) return v.toDouble();
    throw ProjectFormatException('expected a number', p);
  }

  static int _int(Map<String, Object?> j, String k, String p) => _asInt(j[k], _at(p, k));

  static int? _optInt(Map<String, Object?> j, String k, String p) => j[k] == null ? null : _asInt(j[k], _at(p, k));

  static double _dbl(Map<String, Object?> j, String k, double def, String p) =>
      j[k] == null ? def : _asDouble(j[k], _at(p, k));

  static double? _optDbl(Map<String, Object?> j, String k, String p) => j[k] == null ? null : _asDouble(j[k], _at(p, k));

  static bool _bool(Map<String, Object?> j, String k, bool def, String p) {
    final v = j[k];
    if (v == null) return def;
    if (v is bool) return v;
    throw ProjectFormatException('expected a boolean', _at(p, k));
  }

  static String _str(Map<String, Object?> j, String k, String p) {
    final v = j[k];
    if (v is String) return v;
    throw ProjectFormatException('expected a string', _at(p, k));
  }

  static String? _optStr(Map<String, Object?> j, String k, String p) => j[k] == null ? null : _str(j, k, p);

  static DateTime _date(Map<String, Object?> j, String k, String p) {
    final d = DateTime.tryParse(_str(j, k, p));
    if (d == null) throw ProjectFormatException('expected an ISO-8601 time', _at(p, k));
    return d.toUtc();
  }

  static Vec2 _vec(Object? raw, String p) {
    final v = _list(raw, p);
    if (v.length != 2) throw ProjectFormatException('expected [x, y]', p);
    return Vec2(_asDouble(v[0], '$p[0]'), _asDouble(v[1], '$p[1]'));
  }

  static TimeRange _range(Object? raw, String p) {
    final v = _list(raw, p);
    if (v.length != 2) throw ProjectFormatException('expected [start, end]', p);
    final s = _asInt(v[0], '$p[0]');
    final e = _asInt(v[1], '$p[1]');
    if (e < s) throw ProjectFormatException('range ends before it starts', p);
    return TimeRange(s, e);
  }

  static FrameRate _rate(Object? raw, String p) {
    if (raw is List) {
      if (raw.length != 2) throw ProjectFormatException('expected [num, den]', p);
      final n = _asInt(raw[0], '$p[0]');
      final d = _asInt(raw[1], '$p[1]');
      if (n <= 0 || d <= 0) throw ProjectFormatException('frame rate terms must be positive', p);
      return FrameRate(n, d);
    }
    final n = _asInt(raw, p);
    if (n <= 0) throw ProjectFormatException('frame rate must be positive', p);
    return FrameRate(n, 1);
  }

  static final RegExp _hexColor = RegExp(r'^#([0-9A-Fa-f]{6})([0-9A-Fa-f]{2})?$');

  /// ARGB int for `"#RRGGBBAA"` (`"#RRGGBB"` reads as opaque).
  static int _color(String s, String p) {
    final m = _hexColor.firstMatch(s);
    if (m == null) throw ProjectFormatException('expected "#RRGGBBAA"', p);
    final a = m[2] == null ? 0xFF : int.parse(m[2]!, radix: 16);
    return (a << 24) | int.parse(m[1]!, radix: 16);
  }

  /// RGB int for `"#RRGGBB"` (`"#RRGGBBAA"` keeps the high byte).
  static int _rgb(String s, String p) {
    final m = _hexColor.firstMatch(s);
    if (m == null) throw ProjectFormatException('expected "#RRGGBB"', p);
    final a = m[2] == null ? 0 : int.parse(m[2]!, radix: 16);
    return (a << 24) | int.parse(m[1]!, radix: 16);
  }
}
