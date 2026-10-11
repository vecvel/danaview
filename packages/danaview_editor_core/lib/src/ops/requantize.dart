// OWNER: CORE-17
//
// `requantize(project, newRate)` (ARCH §7.2, domain.md §6.6): moves a whole project to another
// frame grid for `SetFrameRate`. It is a pure function of the project and returns a project that
// satisfies the invariants whenever the input did.
//
// **The map.** Every time goes through one monotone function `T(t) = nearest new-grid time`
// (ties to the later frame; `FrameRate.frameIndexNearest`), so
//
// * the **order** of edges is kept (T never decreases) and items that **touched** still touch
//   (equal times map to equal times);
// * an edge moves by at most half a new frame (< 1 new frame in µs) **unless** the lane needs a
//   cascade: an item whose range collapses below one new frame (it was shorter than a frame of
//   the new grid) is stretched to one frame and the items after it, up to the next gap, move
//   right by the missing frames. A lane never moves an edge by more than 1 frame plus the number
//   of items it had to stretch;
// * every duration is at least one frame.
//
// **What else follows.**
// * Item-local keyframe times keep their content: `T(start + t) − T(start)` (keys that land on
//   one frame keep the later key's value);
// * audio fades and text animation lengths are re-measured from the item's (unstretched) edges
//   on the new grid and clamped to half the clip (fades) or the clip (text in + out);
// * a media clip keeps its source range within the media: when rounding the end up would play
//   past the media's end, `sourceIn` is pulled back by the overrun, and when that is impossible
//   the clip ends a frame earlier (the one case in which touching items can separate; the
//   transition at such a cut is dropped);
// * transitions keep their length in seconds (`n·newRate/oldRate` frames, at least one), are
//   dropped when their clips no longer touch and are re-clamped to `TransitionBounds` (left to
//   right, like the framework's own normalization);
// * markers and the view's playhead move with `T`;
// * pool, canvas, background and everything else stay.
//
// Link partners on different lanes are retimed lane by lane, so a stretched item can separate a
// partner by a frame; sync-locking lanes is deferred (domain.md §6.3).

import 'package:collection/collection.dart';

import '../eval/clip_time_map.dart';
import '../ids/ids.dart';
import '../model/items.dart';
import '../model/keyframes/keyframes.dart';
import '../model/marker.dart';
import '../model/pool/media_pool.dart';
import '../model/pool/media_probe.dart';
import '../model/project.dart';
import '../model/timeline.dart';
import '../model/track.dart';
import '../model/transition.dart';
import '../time/time.dart';
import '../validate/transition_bounds.dart';

/// Returns [project] on the frame grid of [newRate] (see the file header). The same rate returns
/// [project] itself.
EditProject requantize(EditProject project, FrameRate newRate) {
  final oldRate = project.settings.frameRate;
  if (newRate == oldRate) return project;
  final q = _Requantizer(project.pool, oldRate, newRate);
  final tl = project.timeline;
  final tracks = [for (final t in tl.tracks) q.lane(t)];
  final markers = [
    for (final m in tl.markers) q.marker(m),
  ];
  return project.copyWith(
    timeline: Timeline(
      settings: tl.settings.copyWith(frameRate: newRate),
      tracks: tracks,
      markers: markers,
      revision: tl.revision,
    ),
    view: project.view.copyWith(playhead: newRate.timeOfFrame(newRate.frameIndexNearest(project.view.playhead))),
  );
}

final class _Requantizer {
  _Requantizer(this.pool, this.oldRate, this.newRate);

  final MediaPool pool;
  final FrameRate oldRate;
  final FrameRate newRate;

  /// New-grid frame nearest to [t].
  int k(TimeUs t) => newRate.frameIndexNearest(t);

  TimeUs at(int frame) => newRate.timeOfFrame(frame);

  Marker marker(Marker m) => m.copyWith(time: at(k(m.time)));

  Track lane(Track track) {
    var cursor = 0; // first free frame on the new grid
    final items = <TimelineItem>[];
    for (final item in track.items) {
      final ks0 = k(item.start);
      final ke0 = k(item.end);
      final ks = ks0 > cursor ? ks0 : cursor;
      var ke = ke0 > ks + 1 ? ke0 : ks + 1;
      TimelineItem next;
      switch (item) {
        case MediaClip():
          final fitted = _fitSource(item, ks, ke);
          ke = fitted.$2;
          next = _clip(fitted.$1, ks0, ke0, ks, ke);
        case TextItem():
          next = _text(item, ks0, ke0, ks, ke);
        case SubtitleCue():
          next = item.copyWith(start: at(ks), duration: at(ke) - at(ks));
      }
      items.add(next);
      cursor = ke;
    }
    return track.copyWith(items: items, transitions: _transitions(track, items));
  }

  // ----- media clips -----

  /// [clip] with `sourceIn` pulled back, or [ke] reduced, so its source range stays inside the
  /// media for the new duration `[ks, ke)`.
  (MediaClip, int) _fitSource(MediaClip clip, int ks, int ke) {
    final asset = pool[clip.media];
    if (asset == null || !_timeBased(asset.kind) || !TransitionBounds.speedValid(clip.speed)) return (clip, ke);
    final c = clip;
    var end = ke;
    while (true) {
      final over = c.sourceIn + ClipTimeMap.sourceLengthOf(at(end) - at(ks), c.speed) - asset.probe.duration;
      if (over <= 0) return (c, end);
      if (over <= c.sourceIn) return (c.copyWith(sourceIn: c.sourceIn - over), end);
      if (end - ks <= 1) return (c, end);
      end--;
    }
  }

  MediaClip _clip(MediaClip clip, int ks0, int ke0, int ks, int ke) {
    final start = at(ks);
    final end = at(ke);
    final a = clip.audio;
    final half = (ke - ks) ~/ 2;
    var audio = a;
    if (a.fadeIn != 0 || a.fadeOut != 0) {
      final fi = a.fadeIn == 0 ? 0 : _min(_max(k(clip.start + a.fadeIn) - ks0, 0), half);
      final fo = a.fadeOut == 0 ? 0 : _min(_max(ke0 - k(clip.end - a.fadeOut), 0), half);
      audio = a.copyWith(fadeIn: at(ks + fi) - start, fadeOut: end - at(ke - fo));
    }
    return clip.copyWith(
      start: start,
      duration: end - start,
      audio: audio,
      keyframes: _keys(clip.keyframes, clip.start, ks0, ks),
    );
  }

  // ----- text -----

  TextItem _text(TextItem item, int ks0, int ke0, int ks, int ke) {
    final start = at(ks);
    final end = at(ke);
    final an = item.animation;
    var animation = an;
    if (an.inDuration != 0 || an.outDuration != 0) {
      final frames = ke - ks;
      var fi = an.inDuration == 0 ? 0 : _max(k(item.start + an.inDuration) - ks0, 0);
      var fo = an.outDuration == 0 ? 0 : _max(ke0 - k(item.end - an.outDuration), 0);
      if (fi > frames) fi = frames;
      if (fi + fo > frames) fo = frames - fi;
      animation = an.copyWith(inDuration: at(ks + fi) - start, outDuration: end - at(ke - fo));
    }
    return item.copyWith(
      start: start,
      duration: end - start,
      animation: animation,
      keyframes: _keys(item.keyframes, item.start, ks0, ks),
    );
  }

  // ----- keyframes -----

  /// Keys keep their content: the new local time is `T(oldStart + t) − T(oldStart)`; keys that
  /// land on one frame keep the later value.
  KeyframeSet _keys(KeyframeSet set, TimeUs oldStart, int ks0, int ks) {
    if (set.isEmpty) return set;
    final base = at(ks0);
    final out = <String, KeyframeTrack>{};
    for (final e in set.byChannel.entries) {
      final byTime = <TimeUs, double>{};
      for (final key in e.value.keys) {
        byTime[at(k(oldStart + key.t)) - base] = key.v;
      }
      out[e.key] = KeyframeTrack([for (final x in byTime.entries) Keyframe(x.key, x.value)]);
    }
    return KeyframeSet(out);
  }

  // ----- transitions -----

  /// The transitions of [track] on the new grid: lengths converted, dropped when their clips no
  /// longer touch, one per cut, clamped to `TransitionBounds` (the framework's normalization).
  List<Transition> _transitions(Track track, List<TimelineItem> items) {
    final trs = track.transitions;
    if (trs.isEmpty) return trs;
    final position = <ItemId, int>{for (var i = 0; i < items.length; i++) items[i].id: i};
    final kept = <Transition>[];
    final lefts = <ItemId>{};
    final rights = <ItemId>{};
    for (final tr in trs) {
      final li = position[tr.left];
      final ri = position[tr.right];
      final ok = li != null &&
          ri != null &&
          ri == li + 1 &&
          items[li] is MediaClip &&
          items[ri] is MediaClip &&
          items[li].end == items[ri].start &&
          !lefts.contains(tr.left) &&
          !rights.contains(tr.right);
      if (!ok) continue;
      lefts.add(tr.left);
      rights.add(tr.right);
      // The length in seconds stays: n · newRate / oldRate frames, rounded half up.
      final n = (2 * tr.durationFrames * newRate.num * oldRate.den + newRate.den * oldRate.num) ~/ (2 * newRate.den * oldRate.num);
      kept.add(tr.copyWith(durationFrames: n < 1 ? 1 : n));
    }
    kept.sort((a, b) => position[a.left]!.compareTo(position[b.left]!));
    for (var i = 0; i < kept.length; i++) {
      final tr = kept[i];
      final left = items[position[tr.left]!] as MediaClip;
      final right = items[position[tr.right]!] as MediaClip;
      final prev = i > 0 && kept[i - 1].right == tr.left ? kept[i - 1] : null;
      final next = i + 1 < kept.length && kept[i + 1].left == tr.right ? kept[i + 1] : null;
      final max = TransitionBounds.maxFramesBetween(
        left: left,
        right: right,
        kind: tr.kind,
        rate: newRate,
        pool: pool,
        framesBeforeInLeft: prev == null ? 0 : (prev.durationFrames + 1) ~/ 2,
        framesAfterInRight: next == null ? 0 : next.durationFrames ~/ 2,
      );
      if (tr.durationFrames <= max) continue;
      if (max < 1) {
        kept.removeAt(i);
        i--;
      } else {
        kept[i] = tr.copyWith(durationFrames: max);
      }
    }
    return const ListEquality<Transition>().equals(kept, trs) ? trs : kept;
  }
}

bool _timeBased(MediaKind k) => k == MediaKind.video || k == MediaKind.audio || k == MediaKind.recording;

int _min(int a, int b) => a < b ? a : b;

int _max(int a, int b) => a > b ? a : b;
