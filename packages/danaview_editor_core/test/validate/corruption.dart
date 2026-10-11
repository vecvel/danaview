// OWNER: CORE-08
//
// Random corruptions of valid projects for the validator and repair property tests: each mutation
// breaks one invariant the way a buggy command or a damaged file could.

import 'dart:math';

import 'package:danaview_editor_core/model.dart';

/// One named corruption; returns null when it does not apply to the project.
typedef Corruption = EditProject? Function(EditProject p, Random rnd);

EditProject _withTracks(EditProject p, List<Track> tracks) => p.copyWith(timeline: p.timeline.copyWith(tracks: tracks));

EditProject _withTrack(EditProject p, int index, Track track) {
  final tracks = List<Track>.of(p.tracks);
  tracks[index] = track;
  return _withTracks(p, tracks);
}

/// A random (track index, item index) of a track matching [where] that has items, or null.
(int, int)? _randomItem(EditProject p, Random rnd, [bool Function(Track t, TimelineItem i)? where]) {
  final candidates = <(int, int)>[];
  for (var ti = 0; ti < p.tracks.length; ti++) {
    final t = p.tracks[ti];
    for (var ii = 0; ii < t.items.length; ii++) {
      if (where == null || where(t, t.items[ii])) candidates.add((ti, ii));
    }
  }
  return candidates.isEmpty ? null : candidates[rnd.nextInt(candidates.length)];
}

EditProject _replaceItem(EditProject p, int ti, int ii, TimelineItem item) {
  final t = p.tracks[ti];
  final items = List<TimelineItem>.of(t.items);
  items[ii] = item;
  return _withTrack(p, ti, t.copyWith(items: items));
}

TimelineItem _retime(TimelineItem i, {TimeUs? start, TimeUs? duration}) => switch (i) {
      MediaClip() => i.copyWith(start: start, duration: duration),
      TextItem() => i.copyWith(start: start, duration: duration),
      SubtitleCue() => i.copyWith(start: start, duration: duration),
    };

/// Every corruption by name.
final Map<String, Corruption> corruptions = {
  'offGridStart': (p, rnd) {
    final loc = _randomItem(p, rnd);
    if (loc == null) return null;
    final item = p.tracks[loc.$1].items[loc.$2];
    return _replaceItem(p, loc.$1, loc.$2, _retime(item, start: item.start + 1 + rnd.nextInt(5000)));
  },
  'overlap': (p, rnd) {
    final loc = _randomItem(p, rnd, (t, i) => t.items.indexOf(i) > 0);
    if (loc == null) return null;
    final prev = p.tracks[loc.$1].items[loc.$2 - 1];
    final item = p.tracks[loc.$1].items[loc.$2];
    final rate = p.settings.frameRate;
    final k = rate.frameIndexOf(prev.start);
    final start = rate.timeOfFrame(k + 1 > rate.frameIndexOf(prev.end) - 1 ? k : k + 1);
    final frames = rate.frameIndexOf(item.end) - rate.frameIndexOf(item.start);
    final k0 = rate.frameIndexOf(start);
    return _replaceItem(p, loc.$1, loc.$2, _retime(item, start: start, duration: rate.timeOfFrame(k0 + frames) - start));
  },
  'unsorted': (p, rnd) {
    final loc = _randomItem(p, rnd, (t, i) => t.items.indexOf(i) > 0);
    if (loc == null) return null;
    final t = p.tracks[loc.$1];
    final items = List<TimelineItem>.of(t.items);
    final a = items[loc.$2 - 1];
    items[loc.$2 - 1] = items[loc.$2];
    items[loc.$2] = a;
    return _withTrack(p, loc.$1, t.copyWith(items: items));
  },
  'duplicateItemId': (p, rnd) {
    final a = _randomItem(p, rnd, (t, i) => i is MediaClip);
    final b = _randomItem(p, rnd, (t, i) => i is MediaClip);
    if (a == null || b == null || a == b) return null;
    final src = p.tracks[a.$1].items[a.$2] as MediaClip;
    final dst = p.tracks[b.$1].items[b.$2] as MediaClip;
    return _replaceItem(
      p,
      b.$1,
      b.$2,
      MediaClip(
        id: src.id,
        start: dst.start,
        duration: dst.duration,
        media: dst.media,
        sourceIn: dst.sourceIn,
        speed: dst.speed,
        reversed: dst.reversed,
        visual: dst.visual,
        audio: dst.audio,
        keyframes: dst.keyframes,
      ),
    );
  },
  'textOnVideoLane': (p, rnd) {
    final ti = p.tracks.indexWhere((t) => t.kind == TrackKind.video);
    if (ti < 0) return null;
    final t = p.tracks[ti];
    final rate = p.settings.frameRate;
    final start = t.items.isEmpty ? 0 : t.items.last.end;
    final k = rate.frameIndexOf(start);
    return _withTrack(p, ti, t.copyWith(items: [
      ...t.items,
      TextItem(id: ItemId('it_wrongkind${rnd.nextInt(9)}'), start: start, duration: rate.timeOfFrame(k + 10) - start, text: 'x'),
    ]));
  },
  'visualOnAudioLane': (p, rnd) {
    final loc = _randomItem(p, rnd, (t, i) => t.kind == TrackKind.audio);
    if (loc == null) return null;
    final c = p.tracks[loc.$1].items[loc.$2] as MediaClip;
    return _replaceItem(p, loc.$1, loc.$2, c.copyWith(visual: VisualProps.neutral));
  },
  'missingMedia': (p, rnd) {
    final loc = _randomItem(p, rnd, (t, i) => i is MediaClip);
    if (loc == null) return null;
    final c = p.tracks[loc.$1].items[loc.$2] as MediaClip;
    return p.copyWith(pool: p.pool.without({c.media}));
  },
  'badSpeed': (p, rnd) {
    final loc = _randomItem(p, rnd, (t, i) => i is MediaClip);
    if (loc == null) return null;
    final c = p.tracks[loc.$1].items[loc.$2] as MediaClip;
    final speed = rnd.nextBool()
        ? ConstantSpeed(rnd.nextBool() ? 50 : 0.01)
        : SpeedRamp(const [SpeedPoint(0, 1), SpeedPoint(0.5, 30), SpeedPoint(1, 1)]);
    return _replaceItem(p, loc.$1, loc.$2, c.copyWith(speed: speed));
  },
  'sourceBeyondMedia': (p, rnd) {
    final loc = _randomItem(p, rnd, (t, i) => i is MediaClip && p.pool[i.media] != null && p.pool[i.media]!.kind != MediaKind.image && p.pool[i.media]!.kind != MediaKind.still);
    if (loc == null) return null;
    final c = p.tracks[loc.$1].items[loc.$2] as MediaClip;
    final d = p.pool[c.media]!.probe.duration;
    return _replaceItem(p, loc.$1, loc.$2, c.copyWith(sourceIn: rnd.nextBool() ? d - 1000 : -5000));
  },
  'badTransition': (p, rnd) {
    final ti = p.tracks.indexWhere((t) => t.items.length >= 2);
    if (ti < 0) return null;
    final t = p.tracks[ti];
    final i = rnd.nextInt(t.items.length - 1);
    return _withTrack(p, ti, t.copyWith(transitions: [
      ...t.transitions,
      Transition(
        id: TransitionId('tx_bad${rnd.nextInt(99)}'),
        left: t.items[i].id,
        right: t.items[rnd.nextBool() ? i + 1 : i].id,
        kind: TransitionKind.values[rnd.nextInt(TransitionKind.values.length)],
        durationFrames: rnd.nextBool() ? 0 : 5000,
      ),
    ]));
  },
  'badKeyframes': (p, rnd) {
    final loc = _randomItem(p, rnd, (t, i) => i is! SubtitleCue);
    if (loc == null) return null;
    final item = p.tracks[loc.$1].items[loc.$2];
    final rate = p.settings.frameRate;
    final half = rate.frameUs ~/ 2;
    final channel = switch (rnd.nextInt(5)) {
      0 => ('chroma.similarity', [Keyframe(0, 0.5)]),
      1 => ('transform.opacity', [Keyframe(0, 3.0)]),
      2 => ('transform.opacity', [Keyframe(rate.timeOfFrame(2), 0.2), Keyframe(rate.timeOfFrame(1), 0.4)]),
      3 => ('transform.opacity', [Keyframe(rate.timeOfFrame(1) + half, 0.5)]),
      _ => ('transform.opacity', <Keyframe>[]),
    };
    final keys = {...switch (item) { MediaClip(:final keyframes) || TextItem(:final keyframes) => keyframes.byChannel, _ => const <String, KeyframeTrack>{} }};
    keys[channel.$1] = KeyframeTrack(channel.$2);
    return _replaceItem(p, loc.$1, loc.$2, withKeyframes(item, KeyframeSet(keys)));
  },
  'valueOutOfRange': (p, rnd) {
    final loc = _randomItem(p, rnd, (t, i) => i is MediaClip && i.visual != null || i is TextItem);
    if (loc == null) return null;
    final item = p.tracks[loc.$1].items[loc.$2];
    return _replaceItem(
      p,
      loc.$1,
      loc.$2,
      switch (rnd.nextInt(3)) {
        0 => PropertyKeys.scale.write(item, 100),
        1 => PropertyKeys.position.write(item, const Vec2(5, double.nan)),
        _ => PropertyKeys.opacity.write(item, -1),
      },
    );
  },
  'loneLink': (p, rnd) {
    final loc = _randomItem(p, rnd, (t, i) => i is MediaClip);
    if (loc == null) return null;
    final c = p.tracks[loc.$1].items[loc.$2] as MediaClip;
    return _replaceItem(p, loc.$1, loc.$2, c.copyWith(link: const LinkId('ln_lonely000000')));
  },
  'emptyCue': (p, rnd) {
    final loc = _randomItem(p, rnd, (t, i) => i is SubtitleCue || i is TextItem);
    if (loc == null) return null;
    final item = p.tracks[loc.$1].items[loc.$2];
    return _replaceItem(p, loc.$1, loc.$2, item is SubtitleCue ? item.copyWith(text: '  ') : (item as TextItem).copyWith(text: ''));
  },
  'subtitleData': (p, rnd) {
    final ti = rnd.nextInt(p.tracks.length);
    final t = p.tracks[ti];
    return _withTrack(p, ti, t.copyWith(subtitle: t.subtitle == null ? const SubtitleTrackData() : null));
  },
  'canvas': (p, rnd) => p.copyWith(
      timeline: p.timeline.copyWith(settings: p.settings.copyWith(canvas: CanvasSpec(aspect: p.settings.canvas.aspect, baseShortSide: 1081)))),
  'frameRate': (p, rnd) => p.copyWith(timeline: p.timeline.copyWith(settings: p.settings.copyWith(frameRate: const FrameRate(30000, 1001)))),
  'fade': (p, rnd) {
    final loc = _randomItem(p, rnd, (t, i) => i is MediaClip);
    if (loc == null) return null;
    final c = p.tracks[loc.$1].items[loc.$2] as MediaClip;
    return _replaceItem(p, loc.$1, loc.$2, c.copyWith(audio: c.audio.copyWith(fadeIn: rnd.nextBool() ? c.duration : -3)));
  },
  'trackOrder': (p, rnd) {
    final tracks = List<Track>.of(p.tracks.reversed);
    return _withTracks(p, tracks);
  },
  'mainFlag': (p, rnd) {
    final ti = rnd.nextInt(p.tracks.length);
    return _withTrack(p, ti, p.tracks[ti].copyWith(isMain: !p.tracks[ti].isMain));
  },
  'duplicateTrackId': (p, rnd) {
    if (p.tracks.length < 2) return null;
    final t = p.tracks[1];
    return _withTrack(p, 1, Track(id: p.tracks[0].id, kind: t.kind, items: t.items, transitions: t.transitions, subtitle: t.subtitle, audioRole: t.audioRole));
  },
  'markers': (p, rnd) {
    final rate = p.settings.frameRate;
    return p.copyWith(
      timeline: p.timeline.copyWith(markers: [
        ...p.markers,
        Marker(id: const MarkerId('mk_bad'), time: rate.timeOfFrame(40) + 7),
        const Marker(id: MarkerId('mk_bad'), time: 0),
      ]),
    );
  },
  'audioStream': (p, rnd) {
    final loc = _randomItem(p, rnd, (t, i) => i is MediaClip);
    if (loc == null) return null;
    final c = p.tracks[loc.$1].items[loc.$2] as MediaClip;
    return _replaceItem(p, loc.$1, loc.$2, c.copyWith(audioStream: -1));
  },
  'beyond24h': (p, rnd) {
    final ti = p.tracks.indexWhere((t) => t.kind == TrackKind.subtitle || t.kind == TrackKind.text);
    if (ti < 0) return null;
    final t = p.tracks[ti];
    final rate = p.settings.frameRate;
    final k = rate.frameIndexOf(maxProjectDurationUs) - 1;
    final item = t.kind == TrackKind.text
        ? TextItem(id: const ItemId('it_late'), start: rate.timeOfFrame(k), duration: rate.timeOfFrame(k + 3) - rate.timeOfFrame(k), text: 'late')
        : SubtitleCue(id: const ItemId('it_late'), start: rate.timeOfFrame(k), duration: rate.timeOfFrame(k + 3) - rate.timeOfFrame(k), text: 'late');
    return _withTrack(p, ti, t.copyWith(items: [...t.items, item]));
  },
};

/// [p] with 1–[maxCount] random corruptions applied (names in [applied] when given).
EditProject corrupt(EditProject p, Random rnd, {int maxCount = 3, List<String>? applied}) {
  var out = p;
  final names = corruptions.keys.toList();
  final count = 1 + rnd.nextInt(maxCount);
  for (var i = 0; i < count; i++) {
    final name = names[rnd.nextInt(names.length)];
    final next = corruptions[name]!(out, rnd);
    if (next != null) {
      out = next;
      applied?.add(name);
    }
  }
  return out;
}
