// OWNER: CORE-08
//
// The project validator (ARCH §6.9 invariants I1–I9, domain.md §5). It runs
//
// * on the changed tracks after every command (`validate(project, only: changed)`, CORE-09: a
//   violation turns the outcome into `InternalInconsistency` and leaves the project unchanged);
// * on the whole project after decode, followed by `repair()` (repair.dart);
// * fully after every step in tests, debug builds and the fuzzer (CORE-34).
//
// **Incremental contract.** Every violation is attributed to one track (`Violation.track`) or to
// the project (null: settings, track structure, markers). `validate(p, only: S)` returns exactly
// the violations of `validate(p)` whose track is null or in S, in the same order (property-tested
// on random projects). Cross-track invariants are attributed per occurrence so this holds:
// a duplicate item id is reported on every occurrence except the one `ProjectIndex` resolves the
// id to; a duplicate transition id on every occurrence after the first in track order; a broken
// link group on each of its members.
//
// **Grid tolerance.** Item edges and markers must be exactly on the grid. Item-local lengths —
// keyframe times, audio fade lengths and text animation lengths — keep their µs value when the
// item moves, and because frame starts are `ceil(k·10⁶/fps)` a length moved between grid positions
// can sit up to a few µs off the grid (CORE-05 time convention, D-35). Those therefore count as
// on the grid when they lie within a quarter frame of a frame start ([lengthGridToleranceUs]):
// drift never reaches that, while a genuinely mid-frame key does.

import '../eval/clip_time_map.dart';
import '../ids/ids.dart';
import '../model/items.dart';
import '../model/keyframes/keyframe_data.dart';
import '../model/keyframes/property_keys.dart';
import '../model/pool/media_pool.dart';
import '../model/pool/media_probe.dart';
import '../model/project.dart';
import '../model/project_index.dart';
import '../model/settings.dart';
import '../model/subtitle.dart';
import '../model/text_style.dart';
import '../model/timeline.dart';
import '../model/track.dart';
import '../model/visual_props.dart';
import '../time/time.dart';
import 'transition_bounds.dart';
import 'violation.dart';

/// Tolerance in µs within which an item-local length (keyframe time, fade, text animation length)
/// counts as on the grid of [rate]: a quarter of a frame (see the file header).
int lengthGridToleranceUs(FrameRate rate) => rate.frameUs ~/ 4;

/// Whole frames (nearest) of an item-local [length] measured from [item]'s start, or back from
/// its end when [fromEnd]. Fades fit (I9) when twice their frame count is at most the item's.
int itemLengthFrames(FrameRate rate, TimelineItem item, TimeUs length, {required bool fromEnd}) => fromEnd
    ? rate.frameIndexOf(item.end) - rate.frameIndexNearest(item.end - length)
    : rate.frameIndexNearest(item.start + length) - rate.frameIndexOf(item.start);

/// Validates [project] against invariants I1–I9 (ARCH §6.9). With [only], checks the tracks in
/// [only] plus the project-level invariants (see the incremental contract in the file header).
/// Returns an empty list for a valid project.
List<Violation> validate(EditProject project, {Set<TrackId>? only}) =>
    _Validator(project.timeline, project.pool, () => project.index).run(only);

/// [validate] over a [timeline] and [pool] that are not wrapped in an [EditProject] (domain.md
/// `Validator.check`).
List<Violation> validateTimeline(Timeline timeline, MediaPool pool, {Set<TrackId>? only}) =>
    _Validator(timeline, pool, () => ProjectIndex.build(timeline)).run(only);

/// The static (non-keyframe) properties checked for range by I6: the numeric, vector and
/// rectangle properties applicable to the item. Fade lengths are checked by I1/I9 instead (the
/// inspector's 10 s fade slider range is a UI limit, not an invariant).
List<PropertyKey<Object?>> rangeCheckedKeysOf(TimelineItem item) => switch (item) {
      MediaClip(:final visual) => visual != null ? _RangeKeys.visualClip : _RangeKeys.audioClip,
      TextItem() => _RangeKeys.text,
      SubtitleCue() => const [],
    };

abstract final class _RangeKeys {
  static bool _ranged(PropertyKey<Object?> k) =>
      k.valueKind == PropertyValueKind.number ||
      k.valueKind == PropertyValueKind.vec2 ||
      k.valueKind == PropertyValueKind.rect;

  static List<PropertyKey<Object?>> _of(TimelineItem probe) =>
      List.unmodifiable(PropertyKeys.all.where((k) => _ranged(k) && k.appliesToItem(probe)));

  static final List<PropertyKey<Object?>> visualClip = _of(MediaClip(
      id: const ItemId('it_probe'), start: 0, duration: 1, media: const MediaId('md_probe'), visual: VisualProps.neutral));
  static final List<PropertyKey<Object?>> audioClip =
      _of(const MediaClip(id: ItemId('it_probe'), start: 0, duration: 1, media: MediaId('md_probe')));
  static final List<PropertyKey<Object?>> text = _of(const TextItem(id: ItemId('it_probe'), start: 0, duration: 1, text: 'x'));
}

final class _Validator {
  _Validator(this.timeline, this.pool, this._indexOf)
      : settings = timeline.settings,
        rate = timeline.settings.frameRate,
        tolerance = lengthGridToleranceUs(timeline.settings.frameRate);

  final Timeline timeline;
  final MediaPool pool;
  final ProjectIndex Function() _indexOf;
  final ProjectSettings settings;
  final FrameRate rate;
  final int tolerance;
  final List<Violation> out = [];

  ProjectIndex? _index;
  ProjectIndex get index => _index ??= _indexOf();

  /// linkId → track indexes of its members (built on first use, over all tracks).
  Map<LinkId, List<int>>? _links;

  /// transition id → (track index, transition index) of its first occurrence (built on first use).
  Map<String, (int, int)>? _firstTransition;

  void add(ViolationCode code, {TrackId? track, String? subject, String message = ''}) =>
      out.add(Violation(code, track: track, subject: subject, message: message));

  List<Violation> run(Set<TrackId>? only) {
    _project();
    final tracks = timeline.tracks;
    for (var ti = 0; ti < tracks.length; ti++) {
      final track = tracks[ti];
      if (only != null && !only.contains(track.id)) continue;
      _track(ti, track);
    }
    return out;
  }

  // -------------------------------------------------------------------------------------------
  // Project level.
  // -------------------------------------------------------------------------------------------

  void _project() {
    final canvas = settings.canvas;
    final w = canvas.widthPx;
    final h = canvas.heightPx;
    if (w.isOdd || h.isOdd || w < 16 || h < 16) {
      add(ViolationCode.canvasInvalid, message: '${w}x$h');
    }
    if (!rate.isSupportedProjectRate) add(ViolationCode.frameRateUnsupported, message: '$rate');

    final tracks = timeline.tracks;
    if (!TrackOrder.isCanonical(tracks)) add(ViolationCode.bandOrder);
    var mains = 0;
    for (final t in tracks) {
      if (t.isMain) mains++;
    }
    final firstVideo = TrackOrder.mainTrack(tracks);
    if (firstVideo == null) {
      add(ViolationCode.mainTrack, message: 'no video track');
    } else if (mains != 1 || !firstVideo.isMain) {
      add(ViolationCode.mainTrack, subject: firstVideo.id, message: '$mains main tracks');
    }
    final trackIds = <TrackId>{};
    for (final t in tracks) {
      if (!trackIds.add(t.id)) add(ViolationCode.duplicateTrackId, subject: t.id);
    }

    final markers = timeline.markers;
    final markerIds = <MarkerId>{};
    for (var i = 0; i < markers.length; i++) {
      final m = markers[i];
      if (!markerIds.add(m.id)) add(ViolationCode.duplicateMarkerId, subject: m.id);
      if (m.time < 0 || m.time > maxProjectDurationUs || !rate.isOnGrid(m.time)) {
        add(ViolationCode.markerOffGrid, subject: m.id, message: '${m.time}');
      }
      if (i > 0 && markers[i - 1].time > m.time) add(ViolationCode.markersUnsorted, subject: m.id);
    }
  }

  // -------------------------------------------------------------------------------------------
  // Track level.
  // -------------------------------------------------------------------------------------------

  void _track(int ti, Track track) {
    final id = track.id;
    final kind = track.kind;
    if ((kind == TrackKind.subtitle) != (track.subtitle != null)) {
      add(ViolationCode.subtitleData, track: id, subject: id, message: track.subtitle == null ? 'missing' : 'not a subtitle track');
    }
    final sub = track.subtitle;
    if (sub != null) {
      final ml = sub.style.maxLines;
      if (ml < 1 || ml > 3) add(ViolationCode.subtitleData, track: id, subject: id, message: 'maxLines $ml');
      final pos = sub.position;
      if (pos is CustomSubtitlePosition && !(pos.yFraction >= 0 && pos.yFraction <= 1)) {
        add(ViolationCode.subtitleData, track: id, subject: id, message: 'position');
      }
    }

    final items = track.items;
    var prevStart = -1 << 62;
    var maxEnd = -1 << 62;
    for (var ii = 0; ii < items.length; ii++) {
      final item = items[ii];
      if (item.start < prevStart) add(ViolationCode.itemsUnsorted, track: id, subject: item.id);
      if (item.start < maxEnd) add(ViolationCode.itemsOverlap, track: id, subject: item.id);
      prevStart = item.start;
      if (item.end > maxEnd) maxEnd = item.end;

      final loc = index.locate(item.id);
      if (loc == null || loc.trackIndex != ti || loc.itemIndex != ii) {
        add(ViolationCode.duplicateItemId, track: id, subject: item.id);
      }
      _itemTiming(id, item);
      _itemKind(id, kind, item);
      switch (item) {
        case MediaClip():
          _clip(id, kind, item);
          _keyframes(id, item, item.keyframes);
          _ranges(id, item);
        case TextItem():
          if (item.text.trim().isEmpty) add(ViolationCode.emptyText, track: id, subject: item.id);
          _length(id, item, item.animation.inDuration, fromEnd: false, what: 'text in');
          _length(id, item, item.animation.outDuration, fromEnd: true, what: 'text out');
          _keyframes(id, item, item.keyframes);
          _ranges(id, item);
        case SubtitleCue():
          if (item.text.trim().isEmpty) add(ViolationCode.emptyText, track: id, subject: item.id);
      }
      final link = item.link;
      if (link != null) _link(ti, id, item, link);
    }
    if (track.transitions.isNotEmpty) _transitions(ti, track);
  }

  void _itemTiming(TrackId track, TimelineItem item) {
    if (item.start < 0 || item.duration <= 0) {
      add(ViolationCode.itemTooShort, track: track, subject: item.id, message: '${item.start}+${item.duration}');
    }
    if (!rate.isOnGrid(item.start) || !rate.isOnGrid(item.end)) {
      add(ViolationCode.itemOffGrid, track: track, subject: item.id, message: '${item.start}..${item.end}');
    }
    if (item.end > maxProjectDurationUs) add(ViolationCode.beyondMaxDuration, track: track, subject: item.id);
  }

  void _itemKind(TrackId track, TrackKind kind, TimelineItem item) {
    final ok = switch (kind) {
      TrackKind.video || TrackKind.overlay => item is MediaClip && item.visual != null,
      TrackKind.audio => item is MediaClip && item.visual == null,
      TrackKind.text => item is TextItem,
      TrackKind.subtitle => item is SubtitleCue,
    };
    if (!ok) add(ViolationCode.itemKindMismatch, track: track, subject: item.id, message: '${item.runtimeType} on ${kind.name}');
  }

  void _clip(TrackId track, TrackKind kind, MediaClip clip) {
    final asset = pool[clip.media];
    final speedOk = TransitionBounds.speedValid(clip.speed);
    if (!speedOk) add(ViolationCode.speedOutOfRange, track: track, subject: clip.id);
    if (clip.sourceIn < 0) add(ViolationCode.sourceOutOfRange, track: track, subject: clip.id, message: 'sourceIn');
    final stream = clip.audioStream;
    if (stream != null && stream < 0) add(ViolationCode.audioStreamInvalid, track: track, subject: clip.id);
    if (asset == null) {
      add(ViolationCode.mediaMissing, track: track, subject: clip.id, message: clip.media);
    } else {
      final mk = asset.kind;
      final compatible = switch (kind) {
        TrackKind.video || TrackKind.overlay => mk == MediaKind.video || mk == MediaKind.image || mk == MediaKind.still,
        TrackKind.audio => mk == MediaKind.audio || mk == MediaKind.recording || (mk == MediaKind.video && asset.probe.hasAudio),
        TrackKind.text || TrackKind.subtitle => false,
      };
      if (!compatible) {
        add(ViolationCode.mediaKindMismatch, track: track, subject: clip.id, message: '${mk.name} on ${kind.name}');
      }
      final timeBased = mk == MediaKind.video || mk == MediaKind.audio || mk == MediaKind.recording;
      if (timeBased && speedOk && clip.duration > 0) {
        final out = clip.sourceIn + ClipTimeMap.sourceLengthOf(clip.duration, clip.speed);
        if (out > asset.probe.duration) {
          add(ViolationCode.sourceOutOfRange, track: track, subject: clip.id, message: 'sourceOut $out > ${asset.probe.duration}');
        }
      }
    }
    final look = clip.visual?.look;
    if (look is ImportedLut) {
      final lut = pool[look.lut];
      if (lut == null) {
        add(ViolationCode.mediaMissing, track: track, subject: clip.id, message: 'lut ${look.lut}');
      } else if (lut.kind != MediaKind.lut) {
        add(ViolationCode.mediaKindMismatch, track: track, subject: clip.id, message: 'look is ${lut.kind.name}');
      }
    }
    final a = clip.audio;
    _length(track, clip, a.fadeIn, fromEnd: false, what: 'fadeIn');
    _length(track, clip, a.fadeOut, fromEnd: true, what: 'fadeOut');
    final frames = rate.frameIndexOf(clip.end) - rate.frameIndexOf(clip.start);
    if (2 * itemLengthFrames(rate, clip, a.fadeIn, fromEnd: false) > frames ||
        2 * itemLengthFrames(rate, clip, a.fadeOut, fromEnd: true) > frames) {
      add(ViolationCode.fadeTooLong, track: track, subject: clip.id);
    }
  }

  /// An item-local length measured from the start (or back from the end) must be ≥ 0 and end
  /// within the grid tolerance of a frame start.
  void _length(TrackId track, TimelineItem item, TimeUs length, {required bool fromEnd, required String what}) {
    if (length == 0) return;
    final at = fromEnd ? item.end - length : item.start + length;
    if (length < 0 || !_nearGrid(at)) {
      add(ViolationCode.lengthOffGrid, track: track, subject: item.id, message: '$what $length');
    }
  }

  bool _nearGrid(TimeUs t) => (t - rate.quantizeNearest(t)).abs() <= tolerance;

  void _keyframes(TrackId track, TimelineItem item, KeyframeSet set) {
    if (set.isEmpty) return;
    for (final e in set.byChannel.entries) {
      final key = PropertyKeys.byChannel[e.key];
      if (key == null || !key.appliesToItem(item)) {
        add(ViolationCode.keyChannelInvalid, track: track, subject: item.id, message: e.key);
        continue;
      }
      final keys = e.value.keys;
      if (keys.isEmpty) {
        add(ViolationCode.keyTrackInvalid, track: track, subject: item.id, message: '${e.key} empty');
        continue;
      }
      for (var i = 0; i < keys.length; i++) {
        final k = keys[i];
        if (i > 0 && keys[i - 1].t >= k.t) {
          add(ViolationCode.keyTrackInvalid, track: track, subject: item.id, message: '${e.key} unsorted at $i');
        }
        if (!_nearGrid(item.start + k.t)) {
          add(ViolationCode.keyOffGrid, track: track, subject: item.id, message: '${e.key} t ${k.t}');
        }
        final v = k.v;
        if (!(v.isFinite && v >= key.min && v <= key.max)) {
          add(ViolationCode.keyValueOutOfRange, track: track, subject: item.id, message: '${e.key} at ${k.t}');
        }
      }
    }
  }

  void _ranges(TrackId track, TimelineItem item) {
    final bad = outOfRangeProperties(item);
    for (final id in bad) {
      add(ViolationCode.valueOutOfRange, track: track, subject: item.id, message: id);
    }
  }

  void _link(int ti, TrackId track, TimelineItem item, LinkId link) {
    final links = _links ??= _buildLinks();
    final members = links[link] ?? const <int>[];
    var sameTrack = 0;
    for (final m in members) {
      if (m == ti) sameTrack++;
    }
    if (members.length < 2 || sameTrack > 1) {
      add(ViolationCode.linkInvalid, track: track, subject: item.id, message: '$link: ${members.length} members');
    }
  }

  Map<LinkId, List<int>> _buildLinks() {
    final map = <LinkId, List<int>>{};
    final tracks = timeline.tracks;
    for (var ti = 0; ti < tracks.length; ti++) {
      for (final item in tracks[ti].items) {
        final l = item.link;
        if (l != null) (map[l] ??= <int>[]).add(ti);
      }
    }
    return map;
  }

  Map<String, (int, int)> _buildFirstTransitions() {
    final map = <String, (int, int)>{};
    final tracks = timeline.tracks;
    for (var ti = 0; ti < tracks.length; ti++) {
      final trs = tracks[ti].transitions;
      for (var i = 0; i < trs.length; i++) {
        map.putIfAbsent(trs[i].id, () => (ti, i));
      }
    }
    return map;
  }

  void _transitions(int ti, Track track) {
    final id = track.id;
    final visual = track.kind == TrackKind.video || track.kind == TrackKind.overlay;
    final firsts = _firstTransition ??= _buildFirstTransitions();
    final position = <ItemId, int>{};
    final items = track.items;
    for (var i = 0; i < items.length; i++) {
      position.putIfAbsent(items[i].id, () => i);
    }
    final lefts = <ItemId>{};
    final rights = <ItemId>{};
    TimeUs? lastCut;
    final trs = track.transitions;
    // Frames of the transition at an item's start (⌈m/2⌉) and end (⌊p/2⌋) lying inside it, last
    // one in list order winning, as TransitionBounds.maxFrames resolves them per call.
    final inAtStart = <ItemId, int>{};
    final inAtEnd = <ItemId, int>{};
    for (final t in trs) {
      if (t.left != t.right) {
        inAtStart[t.right] = (t.durationFrames + 1) ~/ 2;
        inAtEnd[t.left] = t.durationFrames ~/ 2;
      }
    }
    for (var i = 0; i < trs.length; i++) {
      final tr = trs[i];
      if (firsts[tr.id] != (ti, i)) add(ViolationCode.duplicateTransitionId, track: id, subject: tr.id);
      final li = position[tr.left];
      final ri = position[tr.right];
      final left = li == null ? null : items[li];
      final right = ri == null ? null : items[ri];
      if (!visual ||
          left is! MediaClip ||
          right is! MediaClip ||
          ri != li! + 1 ||
          left.end != right.start) {
        add(ViolationCode.transitionNotAdjacent, track: id, subject: tr.id);
        continue;
      }
      if (!lefts.add(tr.left) | !rights.add(tr.right)) {
        add(ViolationCode.transitionDuplicateCut, track: id, subject: tr.id);
      }
      final cut = left.end;
      if (lastCut != null && cut <= lastCut) add(ViolationCode.transitionsUnsorted, track: id, subject: tr.id);
      lastCut = cut;
      if (tr.durationFrames < 1) {
        add(ViolationCode.transitionTooLong, track: id, subject: tr.id, message: '${tr.durationFrames} frames');
        continue;
      }
      final max = TransitionBounds.maxFramesBetween(
        left: left,
        right: right,
        kind: tr.kind,
        rate: rate,
        pool: pool,
        framesBeforeInLeft: inAtStart[left.id] ?? 0,
        framesAfterInRight: inAtEnd[right.id] ?? 0,
      );
      if (tr.durationFrames > max) {
        add(ViolationCode.transitionTooLong, track: id, subject: tr.id, message: '${tr.durationFrames} > $max frames');
      }
    }
  }
}

/// The ids of [item]'s static properties whose value lies outside its `PropertyKey` range (the
/// I6 static check), in registry order. Equivalent to testing `key.accepts(key.read(item))` for
/// every key of [rangeCheckedKeysOf] (property-tested), but reads the fields directly: this is
/// most of the validator's per-item work.
List<String> outOfRangeProperties(TimelineItem item) {
  final out = <String>[];
  void n(PropertyKey<double> k, double v) {
    if (!(v >= k.min && v <= k.max)) out.add(k.id);
  }

  void v2(PropertyKey<Vec2> k, Vec2 v) {
    if (!(v.x >= k.min && v.x <= k.max && v.y >= k.min && v.y <= k.max)) out.add(k.id);
  }

  void transform(Transform2D t) {
    v2(PropertyKeys.position, t.position);
    n(PropertyKeys.scale, t.scale);
    n(PropertyKeys.rotation, t.rotationDeg);
    n(PropertyKeys.opacity, t.opacity);
  }

  switch (item) {
    case MediaClip(:final visual, :final audio):
      if (visual != null) {
        transform(visual.transform);
        final c = visual.crop;
        if (!(c.left >= 0 && c.top >= 0 && c.right <= 1 && c.bottom <= 1 && c.right > c.left && c.bottom > c.top)) {
          out.add(PropertyKeys.crop.id);
        }
        final a = visual.adjust;
        if (!identical(a, ColorAdjust.neutral)) {
          n(PropertyKeys.exposure, a.exposure);
          n(PropertyKeys.brightness, a.brightness);
          n(PropertyKeys.contrast, a.contrast);
          n(PropertyKeys.highlights, a.highlights);
          n(PropertyKeys.shadows, a.shadows);
          n(PropertyKeys.saturation, a.saturation);
          n(PropertyKeys.temperature, a.temperature);
          n(PropertyKeys.tint, a.tint);
        }
        final d = visual.detail;
        n(PropertyKeys.sharpness, d.sharpness);
        n(PropertyKeys.blur, d.blur);
        n(PropertyKeys.vignette, d.vignette);
        n(PropertyKeys.lookIntensity, visual.look?.intensity ?? 1);
        final ch = visual.chroma;
        n(PropertyKeys.chromaSimilarity, ch.similarity);
        n(PropertyKeys.chromaSmoothness, ch.smoothness);
        n(PropertyKeys.chromaSpill, ch.spill);
        final m = visual.mask;
        if (!identical(m, MaskSpec.none)) {
          v2(PropertyKeys.maskCenter, m.center);
          v2(PropertyKeys.maskSize, m.size);
          n(PropertyKeys.maskRotation, m.rotationDeg);
          n(PropertyKeys.maskCornerRadius, m.cornerRadius);
          n(PropertyKeys.maskFeather, m.feather);
          n(PropertyKeys.maskOpacity, m.opacity);
        }
      }
      n(PropertyKeys.volume, audio.volume);
    case TextItem(:final style):
      transform(item.transform);
      n(PropertyKeys.fontSize, style.fontSizePt);
      n(PropertyKeys.letterSpacing, style.letterSpacing);
      n(PropertyKeys.lineHeight, style.lineHeight);
      n(PropertyKeys.maxWidth, style.maxWidth);
      final b = style.background ?? const BoxStyle();
      n(PropertyKeys.backgroundOpacity, b.opacity);
      n(PropertyKeys.backgroundPadding, b.paddingPt);
      n(PropertyKeys.backgroundCornerRadius, b.cornerRadiusPt);
      n(PropertyKeys.strokeWidth, (style.stroke ?? const StrokeStyle()).widthPt);
      final sh = style.shadow ?? const ShadowStyle();
      n(PropertyKeys.shadowOpacity, sh.opacity);
      n(PropertyKeys.shadowBlur, sh.blurPt);
      n(PropertyKeys.shadowDistance, sh.distancePt);
      n(PropertyKeys.shadowAngle, sh.angleDeg);
    case SubtitleCue():
      break;
  }
  return out;
}
