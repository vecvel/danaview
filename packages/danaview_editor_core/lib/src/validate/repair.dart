// OWNER: CORE-08
//
// `repair(project)` (ARCH §6.9, domain.md §5): run after decode on a project that fails
// validation. It never refuses to open a project; it returns the closest valid project and one
// `ProjectOpenWarning` per kind of fix, so the user can keep working. The output validates clean
// (tested on every invariant fixture and on randomly corrupted projects).
//
// In order:
//  1. settings: unsupported frame rate → nearest supported; odd/tiny canvas → nearest supported
//     short side;
//  2. tracks: duplicate track ids renamed; `SubtitleTrackData` added on subtitle tracks, removed
//     elsewhere, clamped; canonical band order restored (stable); exactly one main track, the first
//     video track (an empty one is created when there is none);
//  3. items: items that cannot live on their lane move to a lane of the right kind (LUT clips and
//     items beyond 24 h are dropped); visual props added/removed to match the lane; edges snapped
//     to the grid (≥ 1 frame, ≤ 24 h); speeds clamped (invalid ramps become 1×); source ranges
//     clamped (`sourceIn ≥ 0`, duration shortened so `sourceOut ≤ probe.duration`); fades clamped
//     to half the clip and snapped; negative audio streams cleared; dangling LUT looks removed;
//     static values clamped; keyframes: unknown/inapplicable channels and non-finite keys dropped,
//     values clamped, off-grid times snapped (later key wins on collision), empty tracks dropped;
//     text animation lengths snapped; empty cues and empty text items removed;
//  4. overlaps: per lane in start order, an item overlapping the previous one moves to the next
//     lane of its kind above where it fits, else to a new lane at the top of its band;
//  5. duplicate item ids renamed (later occurrences in track order);
//  6. dangling media references get a placeholder asset (status failed `missing`, sized to the
//     clips that use it) so the relink flow can restore them;
//  7. transitions: dropped when not between touching neighbours on a visual lane, on a duplicate
//     cut or shorter than a frame; renamed on duplicate ids; clamped to their limits (dropped when
//     nothing fits); sorted by cut;
//  8. links: groups keep one member per track and need ≥ 2 members, else the link is cleared;
//  9. markers: snapped, clamped to [0, 24 h], duplicate ids renamed, sorted.

import 'dart:math' as math;

import 'package:collection/collection.dart';

import '../eval/clip_time_map.dart';
import '../eval/speed_math.dart';
import '../ids/ids.dart';
import '../model/audio_props.dart';
import '../model/items.dart';
import '../model/keyframes/keyframe_data.dart';
import '../model/keyframes/keyframe_ops.dart';
import '../model/keyframes/property_keys.dart';
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
import '../model/track.dart';
import '../model/transition.dart';
import '../model/visual_props.dart';
import '../time/time.dart';
import 'validate.dart';

/// Stable codes of the warnings [repair] emits.
abstract final class RepairCodes {
  /// The frame rate was not supported.
  static const String frameRateRepaired = 'frameRateRepaired';

  /// The canvas size was invalid.
  static const String canvasRepaired = 'canvasRepaired';

  /// Track order, main track or subtitle track data was fixed.
  static const String tracksRepaired = 'tracksRepaired';

  /// An item moved to a lane of another kind.
  static const String itemRelocated = 'itemRelocated';

  /// A clip's visual props were added or removed to match its lane.
  static const String itemKindRepaired = 'itemKindRepaired';

  /// An item that could not be kept was removed.
  static const String itemDropped = 'itemDropped';

  /// Item edges, keyframes, fades, markers or animation lengths were snapped to the grid.
  static const String offGridSnapped = 'offGridSnapped';

  /// A speed was clamped or an invalid ramp replaced.
  static const String speedRepaired = 'speedRepaired';

  /// A source range was clamped to the media.
  static const String sourceRangeClamped = 'sourceRangeClamped';

  /// A value, keyframe value or fade was clamped, or a malformed value replaced.
  static const String valueClamped = 'valueClamped';

  /// Invalid keyframe channels or keys were dropped.
  static const String keyframesRepaired = 'keyframesRepaired';

  /// An empty cue or text item was removed.
  static const String emptyTextRemoved = 'emptyTextRemoved';

  /// Overlapping items moved to other lanes (`overlapRepaired`).
  static const String overlapRepaired = 'overlapRepaired';

  /// Items (or transitions) of a lane were put back in time order.
  static const String itemsSorted = 'itemsSorted';

  /// A duplicate id was replaced by a fresh one.
  static const String duplicateIdRenamed = 'duplicateIdRenamed';

  /// A placeholder asset was created for a missing media reference.
  static const String mediaPlaceholderCreated = 'mediaPlaceholderCreated';

  /// A transition was dropped.
  static const String transitionDropped = 'transitionDropped';

  /// A transition was shortened to its limit.
  static const String transitionClamped = 'transitionClamped';

  /// A link group was dissolved or reduced.
  static const String linkRepaired = 'linkRepaired';

  /// Markers were fixed.
  static const String markersRepaired = 'markersRepaired';
}

/// Repairs [project] into a valid project (see the file header) and lists what was fixed, one
/// warning per code with the number of fixes and up to a few ids. A valid project is returned
/// unchanged (identical) with no warnings. [ids] mints ids for new tracks and renamed duplicates
/// (default: `SecureIdGenerator`).
(EditProject, List<ProjectOpenWarning>) repair(EditProject project, {IdGenerator? ids}) {
  if (validate(project).isEmpty) return (project, const []);
  final r = _Repair(project, ids ?? SecureIdGenerator());
  final out = r.run();
  return (out, r.warnings());
}

/// One lane being rebuilt. [items] is the track's own (unmodifiable) list until [mutable] copies
/// it.
final class _Lane {
  _Lane(this.track) : items = track.items;
  _Lane.owned(this.track, this.items) : owned = true;
  Track track;
  List<TimelineItem> items; // sorted by start and non-overlapping once placed
  bool owned = false;

  /// [items], copied first when they are still the track's list.
  List<TimelineItem> get mutable {
    if (!owned) {
      items = List.of(items);
      owned = true;
    }
    return items;
  }

  /// Index of the first item whose start is ≥ [t].
  int lowerBound(TimeUs t) {
    var lo = 0;
    var hi = items.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (items[mid].start < t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  bool fits(TimelineItem item) {
    final i = lowerBound(item.end);
    // Candidates: the last item starting before item.end.
    if (i > 0 && items[i - 1].end > item.start) return false;
    return true;
  }

  void insert(TimelineItem item) => mutable.insert(lowerBound(item.start), item);
}

final class _Repair {
  _Repair(this.p, this.ids);

  final EditProject p;
  final IdGenerator ids;
  final Map<String, List<String>> _fixes = {};

  late FrameRate rate;
  late ProjectSettings settings;
  late MediaPool pool;
  late int tolerance;

  void fix(String code, [String subject = '']) => (_fixes[code] ??= []).add(subject);

  List<ProjectOpenWarning> warnings() => [
        for (final e in _fixes.entries)
          ProjectOpenWarning(
            e.key,
            '${e.value.length} fix${e.value.length == 1 ? '' : 'es'}'
            '${_subjects(e.value)}',
          ),
      ];

  static String _subjects(List<String> s) {
    final named = s.where((x) => x.isNotEmpty).take(5).toList();
    return named.isEmpty ? '' : ': ${named.join(', ')}${s.length > named.length ? ', …' : ''}';
  }

  EditProject run() {
    _settings();
    pool = p.pool;
    final lanes = _tracks();
    _items(lanes);
    _overlaps(lanes);
    _duplicateItems(lanes);
    _placeholders(lanes);
    _transitions(lanes);
    _links(lanes);
    final markers = _markers();
    final tracks = [
      for (final l in lanes) l.owned ? l.track.copyWith(items: l.items) : l.track,
    ];
    return p.copyWith(
      timeline: p.timeline.copyWith(settings: settings, tracks: tracks, markers: markers),
      pool: pool,
    );
  }

  // -------------------------------------------------------------------------------------------
  // 1. Settings.
  // -------------------------------------------------------------------------------------------

  void _settings() {
    settings = p.settings;
    var fr = settings.frameRate;
    if (!fr.isSupportedProjectRate) {
      final fps = fr.fps;
      var best = FrameRate.supportedProjectRates.first;
      for (final r in FrameRate.supportedProjectRates) {
        if (!fps.isFinite) break;
        if ((r - fps).abs() < (best - fps).abs()) best = r;
      }
      fr = FrameRate(best, 1);
      fix(RepairCodes.frameRateRepaired, '$best fps');
    }
    var canvas = settings.canvas;
    bool ok(CanvasSpec c) => c.widthPx.isEven && c.heightPx.isEven && c.widthPx >= 16 && c.heightPx >= 16;
    if (!ok(canvas)) {
      var best = CanvasSpec.supportedShortSides.first;
      for (final s in CanvasSpec.supportedShortSides) {
        if ((s - canvas.baseShortSide).abs() < (best - canvas.baseShortSide).abs()) best = s;
      }
      canvas = CanvasSpec(aspect: canvas.aspect, baseShortSide: best);
      if (!ok(canvas)) canvas = const CanvasSpec();
      fix(RepairCodes.canvasRepaired);
    }
    settings = settings.copyWith(frameRate: fr, canvas: canvas);
    rate = fr;
    tolerance = lengthGridToleranceUs(rate);
  }

  // -------------------------------------------------------------------------------------------
  // 2. Tracks.
  // -------------------------------------------------------------------------------------------

  List<_Lane> _tracks() {
    final seen = <TrackId>{};
    final tracks = <Track>[];
    for (var t in p.tracks) {
      if (!seen.add(t.id)) {
        final fresh = ids.trackId();
        fix(RepairCodes.duplicateIdRenamed, t.id);
        t = Track(
          id: fresh,
          kind: t.kind,
          name: t.name,
          isMain: t.isMain,
          locked: t.locked,
          hidden: t.hidden,
          muted: t.muted,
          solo: t.solo,
          audioRole: t.audioRole,
          subtitle: t.subtitle,
          items: t.items,
          transitions: t.transitions,
          changedAt: t.changedAt,
        );
        seen.add(fresh);
      }
      tracks.add(_fixSubtitleData(t));
    }
    // Canonical band order (stable).
    final ordered = List.of(tracks);
    mergeSort(ordered, compare: (a, b) => a.kind.canonicalOrder - b.kind.canonicalOrder);
    for (var i = 0; i < ordered.length; i++) {
      if (!identical(ordered[i], tracks[i])) {
        fix(RepairCodes.tracksRepaired, 'order');
        break;
      }
    }
    // Exactly one main track: the first video track.
    var firstVideo = ordered.indexWhere((t) => t.kind == TrackKind.video);
    if (firstVideo < 0) {
      ordered.insert(0, Track(id: ids.trackId(), kind: TrackKind.video, isMain: true));
      firstVideo = 0;
      fix(RepairCodes.tracksRepaired, 'main track created');
    }
    for (var i = 0; i < ordered.length; i++) {
      final want = i == firstVideo;
      if (ordered[i].isMain != want) {
        ordered[i] = ordered[i].copyWith(isMain: want);
        fix(RepairCodes.tracksRepaired, ordered[i].id);
      }
    }
    return [for (final t in ordered) _Lane(t)];
  }

  Track _fixSubtitleData(Track t) {
    if (t.kind != TrackKind.subtitle) {
      if (t.subtitle == null) return t;
      fix(RepairCodes.tracksRepaired, t.id);
      return t.copyWith(subtitle: null);
    }
    var data = t.subtitle ?? const SubtitleTrackData();
    final ml = data.style.maxLines;
    if (ml < 1 || ml > 3) data = data.copyWith(style: data.style.copyWith(maxLines: ml < 1 ? 1 : 3));
    final pos = data.position;
    if (pos is CustomSubtitlePosition && !(pos.yFraction >= 0 && pos.yFraction <= 1)) {
      data = data.copyWith(position: pos.yFraction.isNaN ? SubtitlePosition.bottom : CustomSubtitlePosition(pos.yFraction.clamp(0, 1).toDouble()));
    }
    if (identical(data, t.subtitle)) return t;
    fix(RepairCodes.tracksRepaired, t.id);
    return t.copyWith(subtitle: data);
  }

  // -------------------------------------------------------------------------------------------
  // 3. Items.
  // -------------------------------------------------------------------------------------------

  /// Items to place on a lane of another kind (after every lane is fixed).
  final List<(TimelineItem, TrackKind, TrackId)> _relocate = [];

  void _items(List<_Lane> lanes) {
    for (var li = 0; li < lanes.length; li++) {
      final lane = lanes[li];
      final kind = lane.track.kind;
      final kept = <TimelineItem>[];
      var changed = false;
      for (final original in lane.items) {
        var item = _fixItem(original, kind);
        if (item == null) {
          changed = true;
          continue;
        }
        final target = _laneKindFor(item, kind);
        if (target == null) {
          fix(RepairCodes.itemDropped, original.id);
          changed = true;
          continue;
        }
        item = _fitToLane(item, target);
        if (target != kind) {
          fix(RepairCodes.itemRelocated, item.id);
          _relocate.add((item, target, lane.track.id));
          changed = true;
          continue;
        }
        if (!identical(item, original)) changed = true;
        kept.add(item);
      }
      if (changed) lanes[li] = _Lane.owned(lane.track, kept);
    }
  }

  /// The kind of lane [item] can live on, preferring [current]; null when it cannot be kept.
  TrackKind? _laneKindFor(TimelineItem item, TrackKind current) {
    switch (item) {
      case TextItem():
        return TrackKind.text;
      case SubtitleCue():
        return TrackKind.subtitle;
      case MediaClip():
        final asset = pool[item.media];
        if (asset == null) {
          // Missing media: keep it where it is when that is a media lane (a placeholder follows).
          return current == TrackKind.text || current == TrackKind.subtitle ? TrackKind.overlay : current;
        }
        final mk = asset.kind;
        final visual = mk == MediaKind.video || mk == MediaKind.image || mk == MediaKind.still;
        final audible = mk == MediaKind.audio || mk == MediaKind.recording || (mk == MediaKind.video && asset.probe.hasAudio);
        if (current == TrackKind.video || current == TrackKind.overlay) {
          if (visual) return current;
          return audible ? TrackKind.audio : null;
        }
        if (current == TrackKind.audio) {
          if (audible) return current;
          return visual ? TrackKind.overlay : null;
        }
        if (visual) return TrackKind.overlay;
        return audible ? TrackKind.audio : null;
    }
  }

  /// [item] with visual props matching a lane of [kind].
  TimelineItem _fitToLane(TimelineItem item, TrackKind kind) {
    if (item is! MediaClip) return item;
    final visualLane = kind == TrackKind.video || kind == TrackKind.overlay;
    if (visualLane == (item.visual != null)) return item;
    fix(RepairCodes.itemKindRepaired, item.id);
    if (visualLane) return _ranges(item.copyWith(visual: VisualProps.neutral));
    return _ranges(_withoutVisualKeys(item.copyWith(visual: null)));
  }

  MediaClip _withoutVisualKeys(MediaClip c) {
    final kept = <String, KeyframeTrack>{};
    for (final e in c.keyframes.byChannel.entries) {
      final key = PropertyKeys.byChannel[e.key];
      if (key != null && key.appliesToItem(c)) kept[e.key] = e.value;
    }
    if (kept.length == c.keyframes.byChannel.length) return c;
    return c.copyWith(keyframes: kept.isEmpty ? KeyframeSet.empty : KeyframeSet(kept));
  }

  /// The fixed item, or null when it is dropped.
  TimelineItem? _fixItem(TimelineItem item, TrackKind laneKind) {
    if (item is SubtitleCue && item.text.trim().isEmpty) {
      fix(RepairCodes.emptyTextRemoved, item.id);
      return null;
    }
    if (item is TextItem && item.text.trim().isEmpty) {
      fix(RepairCodes.emptyTextRemoved, item.id);
      return null;
    }
    if (item is MediaClip) {
      final asset = pool[item.media];
      if (asset != null && asset.kind == MediaKind.lut) {
        fix(RepairCodes.itemDropped, item.id);
        return null;
      }
    }
    final timed = _fixTiming(item);
    if (timed == null) return null;
    TimelineItem out = timed;
    if (out is MediaClip) {
      final fixed = _fixClip(out);
      if (fixed == null) return null;
      out = fixed;
    }
    if (out is TextItem) out = _fixTextLengths(out);
    out = _fixKeyframes(out);
    out = _ranges(out);
    if (out is MediaClip) out = _fixFades(out);
    return out;
  }

  /// Snaps edges to the grid (≥ 1 frame, start ≥ 0, end ≤ 24 h); null when nothing remains.
  TimelineItem? _fixTiming(TimelineItem item) {
    var start = item.start;
    var end = item.end;
    if (rate.isOnGrid(start) && rate.isOnGrid(end) && start >= 0 && end > start && end <= maxProjectDurationUs) {
      return item;
    }
    start = start < 0 ? 0 : rate.quantizeNearest(start);
    end = rate.quantizeNearest(end);
    if (end > maxProjectDurationUs) end = rate.quantize(maxProjectDurationUs);
    if (start >= maxProjectDurationUs) {
      fix(RepairCodes.itemDropped, item.id);
      return null;
    }
    if (end <= start) end = rate.timeOfFrame(rate.frameIndexOf(start) + 1);
    fix(RepairCodes.offGridSnapped, item.id);
    return _retime(item, start, end - start);
  }

  TimelineItem _retime(TimelineItem item, TimeUs start, TimeUs duration) => switch (item) {
        MediaClip() => item.copyWith(start: start, duration: duration),
        TextItem() => item.copyWith(start: start, duration: duration),
        SubtitleCue() => item.copyWith(start: start, duration: duration),
      };

  MediaClip? _fixClip(MediaClip c) {
    var clip = c;
    // Speed.
    final speed = clip.speed;
    if (!TransitionBounds.speedValid(speed)) {
      fix(RepairCodes.speedRepaired, clip.id);
      clip = clip.copyWith(speed: _fixSpeed(speed));
    }
    // Audio stream.
    final stream = clip.audioStream;
    if (stream != null && stream < 0) {
      fix(RepairCodes.valueClamped, clip.id);
      clip = clip.copyWith(audioStream: null);
    }
    // LUT look.
    final look = clip.visual?.look;
    if (look is ImportedLut) {
      final lut = pool[look.lut];
      if (lut == null || lut.kind != MediaKind.lut) {
        fix(RepairCodes.valueClamped, clip.id);
        clip = clip.copyWith(visual: clip.visual!.copyWith(look: null));
      }
    }
    // Source range.
    if (clip.sourceIn < 0) {
      fix(RepairCodes.sourceRangeClamped, clip.id);
      clip = clip.copyWith(sourceIn: 0);
    }
    final asset = pool[clip.media];
    if (asset == null) return clip;
    final mk = asset.kind;
    if (mk != MediaKind.video && mk != MediaKind.audio && mk != MediaKind.recording) return clip;
    final mediaEnd = asset.probe.duration;
    if (clip.sourceIn + ClipTimeMap.sourceLengthOf(clip.duration, clip.speed) <= mediaEnd) return clip;
    fix(RepairCodes.sourceRangeClamped, clip.id);
    final k0 = rate.frameIndexOf(clip.start);
    int sourceOutFor(int frames) =>
        clip.sourceIn + ClipTimeMap.sourceLengthOf(rate.timeOfFrame(k0 + frames) - clip.start, clip.speed);
    // Estimate the frame count that fits, then step down until it does.
    final k = speedTimeFactor(clip.speed);
    final avail = mediaEnd - clip.sourceIn;
    var frames = avail <= 0 ? 0 : rate.frameIndexOf(clip.start + (avail * k).floor()) - k0 + 1;
    final current = rate.frameIndexOf(clip.end) - k0;
    if (frames > current) frames = current;
    while (frames >= 1 && sourceOutFor(frames) > mediaEnd) {
      frames--;
    }
    if (frames >= 1) {
      return clip.copyWith(duration: rate.timeOfFrame(k0 + frames) - clip.start);
    }
    // Not even one frame fits after sourceIn: move sourceIn back.
    final oneFrame = rate.timeOfFrame(k0 + 1) - clip.start;
    final need = ClipTimeMap.sourceLengthOf(oneFrame, clip.speed);
    if (need > mediaEnd) {
      fix(RepairCodes.itemDropped, clip.id);
      return null;
    }
    return clip.copyWith(sourceIn: mediaEnd - need, duration: oneFrame);
  }

  SpeedSpec _fixSpeed(SpeedSpec speed) {
    switch (speed) {
      case ConstantSpeed(:final rate):
        if (rate.isNaN) return SpeedSpec.normal;
        return ConstantSpeed(rate.clamp(minClipSpeed, maxClipSpeed).toDouble());
      case SpeedRamp(:final points):
        final clamped = SpeedRamp([
          for (final pt in points) SpeedPoint(pt.x, pt.y.isNaN ? 1.0 : pt.y.clamp(minClipSpeed, maxClipSpeed).toDouble()),
        ], presetId: speed.presetId);
        return speedRampIssues(clamped).isEmpty ? clamped : SpeedSpec.normal;
    }
  }

  TextItem _fixTextLengths(TextItem t) {
    final a = t.animation;
    final inD = _snapLength(t, a.inDuration, fromEnd: false);
    final outD = _snapLength(t, a.outDuration, fromEnd: true);
    if (inD == a.inDuration && outD == a.outDuration) return t;
    fix(RepairCodes.offGridSnapped, t.id);
    return t.copyWith(animation: a.copyWith(inDuration: inD, outDuration: outD));
  }

  /// [length] measured from the item start (or back from its end) snapped to the nearest frame
  /// when it is off the grid tolerance; negative lengths become 0; at most the item duration.
  TimeUs _snapLength(TimelineItem item, TimeUs length, {required bool fromEnd}) {
    if (length <= 0) return 0;
    var l = length > item.duration ? item.duration : length;
    final at = fromEnd ? item.end - l : item.start + l;
    if ((at - rate.quantizeNearest(at)).abs() > tolerance) {
      final snapped = rate.quantizeNearest(at);
      l = fromEnd ? item.end - snapped : snapped - item.start;
    }
    return l < 0 ? 0 : l;
  }

  MediaClip _fixFades(MediaClip c) {
    final a = c.audio;
    final frames = rate.frameIndexOf(c.end) - rate.frameIndexOf(c.start);
    final half = frames ~/ 2;
    final maxIn = rate.timeOfFrame(rate.frameIndexOf(c.start) + half) - c.start;
    final maxOut = c.end - rate.timeOfFrame(rate.frameIndexOf(c.end) - half);
    var fadeIn = _snapLength(c, a.fadeIn, fromEnd: false);
    var fadeOut = _snapLength(c, a.fadeOut, fromEnd: true);
    if (2 * itemLengthFrames(rate, c, fadeIn, fromEnd: false) > frames) fadeIn = maxIn;
    if (2 * itemLengthFrames(rate, c, fadeOut, fromEnd: true) > frames) fadeOut = maxOut;
    if (fadeIn == a.fadeIn && fadeOut == a.fadeOut) return c;
    fix(RepairCodes.valueClamped, c.id);
    return c.copyWith(audio: AudioProps(volume: a.volume, muted: a.muted, fadeIn: fadeIn, fadeOut: fadeOut));
  }

  TimelineItem _fixKeyframes(TimelineItem item) {
    final set = keyframesOf(item);
    if (set.isEmpty) return item;
    final out = <String, KeyframeTrack>{};
    var changed = false;
    for (final e in set.byChannel.entries) {
      final key = PropertyKeys.byChannel[e.key];
      if (key == null || !key.appliesToItem(item)) {
        changed = true;
        continue;
      }
      final byTime = <TimeUs, double>{};
      var trackChanged = false;
      TimeUs? prev;
      for (final k in e.value.keys) {
        var v = k.v;
        if (!v.isFinite) {
          trackChanged = true;
          continue;
        }
        if (v < key.min || v > key.max) {
          v = v.clamp(key.min, key.max).toDouble();
          trackChanged = true;
        }
        var t = k.t;
        final abs = item.start + t;
        if ((abs - rate.quantizeNearest(abs)).abs() > tolerance) {
          t = rate.quantizeNearest(abs) - item.start;
          trackChanged = true;
        }
        if (prev != null && t <= prev) trackChanged = true;
        prev = t;
        byTime[t] = v; // a later key wins on collision
      }
      if (byTime.isEmpty) {
        changed = true;
        continue;
      }
      if (!trackChanged) {
        out[e.key] = e.value;
        continue;
      }
      changed = true;
      final times = byTime.keys.toList()..sort();
      out[e.key] = KeyframeTrack([for (final t in times) Keyframe(t, byTime[t]!)]);
    }
    if (!changed) return item;
    fix(RepairCodes.keyframesRepaired, item.id);
    return withKeyframes(item, out.isEmpty ? KeyframeSet.empty : KeyframeSet(out));
  }

  TimelineItem _ranges(TimelineItem item) {
    var out = item;
    for (final key in rangeCheckedKeysOf(item)) {
      final v = key.read(out);
      if (key.accepts(v)) continue;
      final Object? fixed = switch (v) {
        Vec2() => Vec2(
            v.x.isNaN ? (key.defaultValue! as Vec2).x : v.x.clamp(key.min, key.max).toDouble(),
            v.y.isNaN ? (key.defaultValue! as Vec2).y : v.y.clamp(key.min, key.max).toDouble(),
          ),
        CropRect() => _fixCrop(v),
        _ => key.clamp(v),
      };
      out = key.write(out, fixed);
      fix(RepairCodes.valueClamped, item.id);
    }
    return out;
  }

  static CropRect _fixCrop(CropRect c) {
    double n(double v, double d) => v.isNaN ? d : v.clamp(0, 1).toDouble();
    final l = n(c.left, 0), t = n(c.top, 0), r = n(c.right, 1), b = n(c.bottom, 1);
    if (r > l && b > t) return CropRect(left: l, top: t, right: r, bottom: b);
    return CropRect.full;
  }

  // -------------------------------------------------------------------------------------------
  // 4. Overlaps and relocation.
  // -------------------------------------------------------------------------------------------

  void _overlaps(List<_Lane> lanes) {
    final pending = <(TimelineItem, TrackKind, TrackId)>[..._relocate];
    for (var li = 0; li < lanes.length; li++) {
      final lane = lanes[li];
      final sorted = List.of(lane.items);
      mergeSort(sorted, compare: (a, b) => a.start != b.start ? a.start.compareTo(b.start) : a.id.compareTo(b.id));
      final kept = <TimelineItem>[];
      var end = -1;
      for (final item in sorted) {
        if (kept.isNotEmpty && item.start < end) {
          fix(RepairCodes.overlapRepaired, item.id);
          pending.add((item, lane.track.kind, lane.track.id));
          continue;
        }
        kept.add(item);
        end = item.end;
      }
      var same = kept.length == lane.items.length;
      for (var i = 0; same && i < kept.length; i++) {
        same = identical(kept[i], lane.items[i]);
      }
      if (!same) {
        for (var i = 1; i < lane.items.length; i++) {
          if (lane.items[i].start < lane.items[i - 1].start) {
            fix(RepairCodes.itemsSorted, lane.track.id);
            break;
          }
        }
        lanes[li] = _Lane.owned(lane.track, kept);
      }
    }
    for (final (item, kind, from) in pending) {
      _place(lanes, item, kind, from);
    }
  }

  /// Places [item] on the first lane of [kind] above its lane [fromId] (or anywhere of that kind
  /// when it comes from another kind) where it fits; else on a new lane at the top of the band.
  void _place(List<_Lane> lanes, TimelineItem item, TrackKind kind, TrackId fromId) {
    final from = lanes.indexWhere((l) => l.track.id == fromId);
    final sameKind = from >= 0 && lanes[from].track.kind == kind;
    for (var i = 0; i < lanes.length; i++) {
      final lane = lanes[i];
      if (lane.track.kind != kind) continue;
      if (sameKind && i <= from) continue;
      if (lane.fits(item)) {
        lane.insert(item);
        return;
      }
    }
    final source = from >= 0 ? lanes[from].track : null;
    final track = Track(
      id: ids.trackId(),
      kind: kind,
      audioRole: kind == TrackKind.audio ? (source?.kind == TrackKind.audio ? source!.audioRole : AudioRole.original) : null,
      subtitle: kind == TrackKind.subtitle
          ? (source?.kind == TrackKind.subtitle ? source!.subtitle : null) ?? const SubtitleTrackData()
          : null,
    );
    var at = 0;
    for (var i = 0; i < lanes.length; i++) {
      if (lanes[i].track.kind.canonicalOrder <= kind.canonicalOrder) at = i + 1;
    }
    lanes.insert(at, _Lane.owned(track, [item]));
    fix(RepairCodes.tracksRepaired, 'lane added');
  }

  // -------------------------------------------------------------------------------------------
  // 5. Duplicate item ids.
  // -------------------------------------------------------------------------------------------

  void _duplicateItems(List<_Lane> lanes) {
    final seen = <ItemId>{};
    for (var li = 0; li < lanes.length; li++) {
      final lane = lanes[li];
      for (var i = 0; i < lane.items.length; i++) {
        final item = lane.items[i];
        if (seen.add(item.id)) continue;
        final fresh = ids.itemId();
        seen.add(fresh);
        fix(RepairCodes.duplicateIdRenamed, item.id);
        lane.mutable[i] = _withId(item, fresh);
      }
    }
  }

  static TimelineItem _withId(TimelineItem item, ItemId id) => switch (item) {
        MediaClip() => item.withId(id),
        TextItem() => TextItem(
            id: id,
            start: item.start,
            duration: item.duration,
            link: item.link,
            label: item.label,
            text: item.text,
            style: item.style,
            animation: item.animation,
            transform: item.transform,
            keyframes: item.keyframes,
          ),
        SubtitleCue() => SubtitleCue(
            id: id,
            start: item.start,
            duration: item.duration,
            link: item.link,
            label: item.label,
            text: item.text,
            origin: item.origin,
            editedAfterGeneration: item.editedAfterGeneration,
          ),
      };

  // -------------------------------------------------------------------------------------------
  // 6. Placeholders for missing media.
  // -------------------------------------------------------------------------------------------

  void _placeholders(List<_Lane> lanes) {
    final need = <MediaId, ({bool visual, TimeUs end})>{};
    for (final lane in lanes) {
      final visualLane = lane.track.kind == TrackKind.video || lane.track.kind == TrackKind.overlay;
      for (final item in lane.items) {
        if (item is! MediaClip || pool[item.media] != null) continue;
        final end = item.sourceIn + ClipTimeMap.sourceLengthOf(item.duration, item.speed);
        final prev = need[item.media];
        need[item.media] = (
          visual: (prev?.visual ?? false) || visualLane,
          end: prev == null || end > prev.end ? end : prev.end,
        );
      }
    }
    if (need.isEmpty) return;
    final assets = Map.of(pool.assets);
    final canvas = settings.canvas;
    for (final e in need.entries) {
      final kind = e.value.visual ? MediaKind.video : MediaKind.audio;
      final duration = math.max(e.value.end, 1);
      assets[e.key] = MediaAsset(
        id: e.key,
        kind: kind,
        displayName: 'Missing media',
        locator: const FileLocator(''),
        ownership: MediaOwnership.external,
        fingerprint: MediaFingerprint(sizeBytes: 0, quickHash: '', duration: duration),
        probe: MediaProbe(
          kind: kind,
          duration: duration,
          hasVideo: e.value.visual,
          hasAudio: true,
          width: e.value.visual ? canvas.widthPx : null,
          height: e.value.visual ? canvas.heightPx : null,
          audioStreams: 1,
        ),
        origin: MediaOrigin.files,
        status: const FailedStatus('missing'),
        addedAt: p.meta.updatedAt,
      );
      fix(RepairCodes.mediaPlaceholderCreated, e.key);
    }
    pool = MediaPool(assets);
  }

  // -------------------------------------------------------------------------------------------
  // 7. Transitions.
  // -------------------------------------------------------------------------------------------

  void _transitions(List<_Lane> lanes) {
    final usedIds = <TransitionId>{};
    for (var li = 0; li < lanes.length; li++) {
      final lane = lanes[li];
      final original = lane.track.transitions;
      if (original.isEmpty) continue;
      final kind = lane.track.kind;
      final visual = kind == TrackKind.video || kind == TrackKind.overlay;
      final position = <ItemId, int>{};
      for (var i = 0; i < lane.items.length; i++) {
        position.putIfAbsent(lane.items[i].id, () => i);
      }
      final lefts = <ItemId>{};
      final rights = <ItemId>{};
      var kept = <Transition>[];
      for (var tr in original) {
        final li2 = position[tr.left];
        final ri = position[tr.right];
        final left = li2 == null ? null : lane.items[li2];
        final right = ri == null ? null : lane.items[ri];
        final ok = visual &&
            left is MediaClip &&
            right is MediaClip &&
            ri == li2! + 1 &&
            left.end == right.start &&
            tr.durationFrames >= 1 &&
            !lefts.contains(tr.left) &&
            !rights.contains(tr.right);
        if (!ok) {
          fix(RepairCodes.transitionDropped, tr.id);
          continue;
        }
        lefts.add(tr.left);
        rights.add(tr.right);
        if (!usedIds.add(tr.id)) {
          final fresh = ids.transitionId();
          usedIds.add(fresh);
          fix(RepairCodes.duplicateIdRenamed, tr.id);
          tr = Transition(
            id: fresh,
            left: tr.left,
            right: tr.right,
            kind: tr.kind,
            durationFrames: tr.durationFrames,
            direction: tr.direction,
          );
        }
        kept.add(tr);
      }
      final unsorted = List.of(kept);
      kept.sort((a, b) => lane.items[position[a.left]!].end.compareTo(lane.items[position[b.left]!].end));
      for (var i = 0; i < kept.length; i++) {
        if (!identical(kept[i], unsorted[i])) {
          fix(RepairCodes.itemsSorted, lane.track.id);
          break;
        }
      }
      // Clamp to the limits until stable (clamping only relaxes the neighbours' limits).
      var changed = true;
      for (var round = 0; changed && round <= kept.length + 1; round++) {
        changed = false;
        final probe = lane.track.copyWith(transitions: kept);
        final next = <Transition>[];
        for (final tr in kept) {
          final max = TransitionBounds.maxFrames(
            track: probe,
            left: lane.items[position[tr.left]!] as MediaClip,
            right: lane.items[position[tr.right]!] as MediaClip,
            kind: tr.kind,
            rate: rate,
            pool: pool,
          );
          if (tr.durationFrames <= max) {
            next.add(tr);
          } else if (max >= 1) {
            fix(RepairCodes.transitionClamped, tr.id);
            next.add(tr.copyWith(durationFrames: max));
            changed = true;
          } else {
            fix(RepairCodes.transitionDropped, tr.id);
            changed = true;
          }
        }
        kept = next;
      }
      var same = kept.length == original.length;
      for (var i = 0; same && i < kept.length; i++) {
        same = identical(kept[i], original[i]);
      }
      if (!same) lane.track = lane.track.copyWith(transitions: kept);
    }
  }

  // -------------------------------------------------------------------------------------------
  // 8. Links.
  // -------------------------------------------------------------------------------------------

  void _links(List<_Lane> lanes) {
    // linkId → members (lane, index), in lane order then time order.
    final groups = <LinkId, List<(int, int)>>{};
    for (var li = 0; li < lanes.length; li++) {
      final items = lanes[li].items;
      for (var i = 0; i < items.length; i++) {
        final l = items[i].link;
        if (l != null) (groups[l] ??= []).add((li, i));
      }
    }
    for (final e in groups.entries) {
      final perLane = <int>{};
      final keep = <(int, int)>[];
      final drop = <(int, int)>[];
      for (final m in e.value) {
        (perLane.add(m.$1) ? keep : drop).add(m);
      }
      if (keep.length < 2) drop.addAll(keep);
      if (drop.isEmpty) continue;
      fix(RepairCodes.linkRepaired, e.key);
      for (final (li, i) in drop) {
        final items = lanes[li].mutable;
        items[i] = _withoutLink(items[i]);
      }
    }
  }

  static TimelineItem _withoutLink(TimelineItem item) => switch (item) {
        MediaClip() => item.copyWith(link: null),
        TextItem() => item.copyWith(link: null),
        SubtitleCue() => SubtitleCue(
            id: item.id,
            start: item.start,
            duration: item.duration,
            label: item.label,
            text: item.text,
            origin: item.origin,
            editedAfterGeneration: item.editedAfterGeneration,
          ),
      };

  // -------------------------------------------------------------------------------------------
  // 9. Markers.
  // -------------------------------------------------------------------------------------------

  List<Marker> _markers() {
    final markers = p.markers;
    var changed = false;
    final seen = <MarkerId>{};
    final out = <Marker>[];
    for (var m in markers) {
      var t = m.time;
      if (t < 0) t = 0;
      if (t > maxProjectDurationUs) t = maxProjectDurationUs;
      t = rate.quantizeNearest(t);
      if (t > maxProjectDurationUs) t = rate.quantize(maxProjectDurationUs);
      if (t != m.time) {
        m = m.copyWith(time: t);
        changed = true;
      }
      if (!seen.add(m.id)) {
        final fresh = ids.markerId();
        seen.add(fresh);
        m = Marker(id: fresh, time: m.time, name: m.name, colorIndex: m.colorIndex, note: m.note);
        changed = true;
      }
      out.add(m);
    }
    final sorted = List.of(out);
    mergeSort(sorted, compare: (a, b) => a.time.compareTo(b.time));
    for (var i = 0; i < sorted.length; i++) {
      if (!identical(sorted[i], out[i])) changed = true;
    }
    if (!changed) return markers;
    fix(RepairCodes.markersRepaired);
    return sorted;
  }
}
