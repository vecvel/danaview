// OWNER: CORE-35
//
// Deterministic builders of the benchmark projects (ARCH §18.2 design target):
//
// * [buildLargeProject] — `test/fixtures/projects/large_2000.json`: 2,000 timeline items besides
//   3,000 subtitle cues, 32 lanes, a 3 h timeline at 30 fps and 300 pool media. Lane layout:
//   1 main video lane (700 contiguous clips, transitions at every fourth cut), 3 overlay lanes
//   (100 clips each, staggered so no two overlay lanes overlap in time and the D-14 caps hold),
//   4 text lanes (100 animated items each), 4 subtitle lanes (750 cues each) and 20 audio lanes
//   (30 clips each: music beds, voice, effects). Some clips carry speed changes, fades, looks and
//   keyframes, so every lowering path is exercised.
// * [buildOneLaneProject] — the `apply` / `dryRun` row: one main lane holding 1,000 clips.
//
// Same arguments, same project (ids from `SeededIdGenerator`, values from `Random(seed)`), so the
// fixture can be regenerated with `dart run benchmark/run.dart --write-fixture`.

import 'dart:math';

import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';

/// Shape of the large fixture (checked by `run.dart --check` and `--write-fixture`).
abstract final class LargeShape {
  /// Non-cue timeline items.
  static const int items = 2000;

  /// Subtitle cues.
  static const int cues = 3000;

  /// Lanes.
  static const int lanes = 32;

  /// Pool media (incl. one imported LUT).
  static const int media = 300;

  /// Timeline length.
  static const TimeUs duration = 3 * 3600 * microsPerSecond;
}

/// Counts of [p] in the terms of [LargeShape].
({int items, int cues, int lanes, int media, TimeUs duration}) shapeOf(EditProject p) {
  var items = 0, cues = 0;
  TimeUs end = 0;
  for (final t in p.tracks) {
    for (final i in t.items) {
      if (i is SubtitleCue) {
        cues++;
      } else {
        items++;
      }
      if (i.end > end) end = i.end;
    }
  }
  return (items: items, cues: cues, lanes: p.tracks.length, media: p.pool.assets.length, duration: end);
}

/// The 2,000-item / 32-lane / 3 h / 300-media / 3,000-cue project.
EditProject buildLargeProject({int seed = 2000}) => _Gen(seed).large();

/// A project whose main lane holds [clips] contiguous clips (the `apply` / `dryRun` row).
EditProject buildOneLaneProject({int clips = 1000, int seed = 1000}) => _Gen(seed).oneLane(clips);

const FrameRate _rate = FrameRate.fps30;

final class _Gen {
  _Gen(int seed)
      : rnd = Random(seed),
        ids = SeededIdGenerator(seed);

  final Random rnd;
  final IdGenerator ids;
  final Map<MediaId, MediaAsset> assets = {};
  final List<MediaId> videos = [];
  final List<MediaId> images = [];
  final List<MediaId> audios = [];
  late MediaId lut;
  final DateTime when = DateTime.utc(2026, 10, 15, 12);

  double uniform(double a, double b) => a + rnd.nextDouble() * (b - a);
  bool chance(double p) => rnd.nextDouble() < p;
  T pick<T>(List<T> xs) => xs[rnd.nextInt(xs.length)];
  TimeUs at(int frame) => _rate.timeOfFrame(frame);
  int frameOf(TimeUs t) => _rate.frameIndexOf(t);
  int sec(double s) => (s * _rate.num).round();

  // -------------------------------------------------------------------------------------------
  // Projects.
  // -------------------------------------------------------------------------------------------

  EditProject large() {
    _media(videoCount: 200, imageCount: 55, audioCount: 44);
    final total = frameOf(LargeShape.duration);
    final tracks = <Track>[
      _mainLane(700, total),
      for (var k = 0; k < 3; k++) _overlayLane(k, 100, total),
      for (var k = 0; k < 4; k++) _textLane(k, 100, total),
      for (var k = 0; k < 4; k++) _subtitleLane(k, 750, total),
      for (var k = 0; k < 20; k++) _audioLane(k, 30, total),
    ];
    final markers = [
      for (var i = 0; i < 48; i++) Marker(id: ids.markerId(), time: at(i * (total ~/ 48) + 15), name: 'M${i + 1}', colorIndex: i % 8),
    ];
    return _project('Large benchmark', tracks, markers);
  }

  EditProject oneLane(int clips) {
    _media(videoCount: 40, imageCount: 10, audioCount: 4);
    final total = clips * sec(10);
    return _project('One lane benchmark', [_mainLane(clips, total)], const []);
  }

  EditProject _project(String name, List<Track> tracks, List<Marker> markers) => EditProject(
        id: ids.projectId(),
        meta: ProjectMeta(name: name, createdAt: when, updatedAt: when),
        timeline: Timeline(
          settings: const ProjectSettings(
            canvas: CanvasSpec(aspect: AspectRatio.landscape16x9, baseShortSide: 1080),
            frameRate: _rate,
          ),
          tracks: tracks,
          markers: markers,
        ),
        pool: MediaPool(assets),
      );

  // -------------------------------------------------------------------------------------------
  // Media.
  // -------------------------------------------------------------------------------------------

  static const List<(int, int)> _sizes = [(1920, 1080), (1920, 1080), (3840, 2160), (1280, 720), (1080, 1920)];

  MediaAsset _asset(MediaKind kind, {TimeUs duration = 0, int? w, int? h, bool hasAudio = false}) {
    final id = ids.mediaId();
    return MediaAsset(
      id: id,
      kind: kind,
      displayName: '${kind.name}_${assets.length}',
      locator: AppRelativeLocator(AppRoot.documents, 'media/$id'),
      ownership: MediaOwnership.managedCopy,
      fingerprint: MediaFingerprint(sizeBytes: 1000000 + rnd.nextInt(1 << 30), quickHash: id.padRight(40, '0'), duration: duration),
      probe: MediaProbe(
        kind: kind,
        duration: duration,
        hasVideo: w != null,
        hasAudio: hasAudio,
        width: w,
        height: h,
        audioStreams: hasAudio ? 1 : 0,
      ),
      origin: MediaOrigin.files,
      addedAt: when,
    );
  }

  void _media({required int videoCount, required int imageCount, required int audioCount}) {
    for (var i = 0; i < videoCount; i++) {
      final (w, h) = pick(_sizes);
      final a = _asset(MediaKind.video, duration: (uniform(600, 1800) * microsPerSecond).round(), w: w, h: h, hasAudio: chance(0.8));
      assets[a.id] = a;
      videos.add(a.id);
    }
    for (var i = 0; i < imageCount; i++) {
      final (w, h) = pick(_sizes);
      final a = _asset(MediaKind.image, w: w, h: h);
      assets[a.id] = a;
      images.add(a.id);
    }
    for (var i = 0; i < audioCount; i++) {
      final a = _asset(chance(0.8) ? MediaKind.audio : MediaKind.recording, duration: (uniform(400, 900) * microsPerSecond).round(), hasAudio: true);
      assets[a.id] = a;
      audios.add(a.id);
    }
    final l = _asset(MediaKind.lut);
    assets[l.id] = l;
    lut = l.id;
  }

  // -------------------------------------------------------------------------------------------
  // Lanes.
  // -------------------------------------------------------------------------------------------

  /// [count] contiguous clips over [totalFrames] frames, with transitions at every fourth cut.
  Track _mainLane(int count, int totalFrames) {
    final step = totalFrames / count;
    final cuts = <int>[0];
    for (var i = 1; i < count; i++) {
      cuts.add((i * step + uniform(-0.3, 0.3) * step).round());
    }
    cuts.add(totalFrames);
    final items = <TimelineItem>[
      for (var i = 0; i < count; i++)
        chance(0.85) ? _videoClip(cuts[i], cuts[i + 1] - cuts[i], overlay: false) : _imageClip(cuts[i], cuts[i + 1] - cuts[i], overlay: false),
    ];
    var track = Track(id: ids.trackId(), kind: TrackKind.video, isMain: true, items: items);
    final pool = MediaPool(assets);
    for (var i = 3; i + 1 < items.length; i += 4) {
      final left = items[i] as MediaClip, right = items[i + 1] as MediaClip;
      final kind = i % 12 == 3 ? pick(TransitionKind.values) : TransitionKind.crossDissolve;
      final maxFrames = TransitionBounds.maxFrames(track: track, left: left, right: right, kind: kind, rate: _rate, pool: pool);
      if (maxFrames < 2) continue;
      track = track.copyWith(transitions: [
        ...track.transitions,
        Transition(
          id: ids.transitionId(),
          left: left.id,
          right: right.id,
          kind: kind,
          durationFrames: min(maxFrames, 10 + rnd.nextInt(11)),
          direction: switch (kind) {
            TransitionKind.slide || TransitionKind.wipe => TransitionDirection.left,
            TransitionKind.zoom => TransitionDirection.zoomIn,
            _ => null,
          },
        ),
      ]);
    }
    return track;
  }

  /// Overlay lane [k]: clip j sits in slot `3j + k` of `3 × count` equal slots, so overlay lanes
  /// never overlap each other.
  Track _overlayLane(int k, int count, int totalFrames) {
    final slot = totalFrames ~/ (3 * count);
    final items = <TimelineItem>[];
    for (var j = 0; j < count; j++) {
      final k0 = (3 * j + k) * slot + sec(2);
      final n = sec(uniform(5, 10));
      items.add(chance(0.6) ? _videoClip(k0, n, overlay: true) : _imageClip(k0, n, overlay: true));
    }
    return Track(id: ids.trackId(), kind: TrackKind.overlay, items: items);
  }

  Track _textLane(int k, int count, int totalFrames) {
    final slot = totalFrames ~/ count;
    final items = <TimelineItem>[];
    for (var j = 0; j < count; j++) {
      final k0 = j * slot + k * sec(25) + sec(1);
      final n = sec(uniform(4, 10));
      items.add(_text(k0, n));
    }
    return Track(id: ids.trackId(), kind: TrackKind.text, items: items);
  }

  static const List<String> _cueTexts = [
    'Welcome back to the channel',
    'This is where the <i>real</i> trip begins',
    'We left before sunrise',
    '<b>Look</b> at that view!',
    'Two hours later\nwe finally arrived',
    'Ça commence ici',
    '你好，世界',
    'And that is a wrap',
  ];

  Track _subtitleLane(int k, int count, int totalFrames) {
    final slot = totalFrames ~/ count;
    final items = <TimelineItem>[
      for (var j = 0; j < count; j++)
        SubtitleCue(
          id: ids.itemId(),
          start: at(j * slot + k),
          duration: at(j * slot + k + sec(uniform(2, 6))) - at(j * slot + k),
          text: pick(_cueTexts),
          origin: k == 0 ? CueOrigin.generated : CueOrigin.manual,
        ),
    ];
    return Track(
      id: ids.trackId(),
      kind: TrackKind.subtitle,
      subtitle: SubtitleTrackData(language: const ['en', 'fr', 'de', 'ja'][k], burnIn: k == 0),
      items: items,
    );
  }

  Track _audioLane(int k, int count, int totalFrames) {
    final slot = totalFrames ~/ count;
    final role = k < 3 ? AudioRole.music : (k < 10 ? AudioRole.voice : AudioRole.effects);
    final items = <TimelineItem>[];
    for (var j = 0; j < count; j++) {
      final k0 = j * slot + (k < 3 ? k : k * sec(9));
      final n = k < 3 ? slot - sec(1) : sec(uniform(5, 60));
      items.add(_audioClip(k0, n, bed: k < 3));
    }
    return Track(id: ids.trackId(), kind: TrackKind.audio, audioRole: role, muted: k == 19, items: items);
  }

  // -------------------------------------------------------------------------------------------
  // Items.
  // -------------------------------------------------------------------------------------------

  SpeedSpec _speed() {
    final r = rnd.nextDouble();
    if (r < 0.8) return SpeedSpec.normal;
    if (r < 0.93) return ConstantSpeed(pick(const [0.5, 0.75, 1.5, 2.0]));
    return SpeedRamp(const [SpeedPoint(0, 1), SpeedPoint(0.4, 2), SpeedPoint(0.7, 0.5), SpeedPoint(1, 1)]);
  }

  /// A source-in that leaves at least 3 s of handle on both sides.
  TimeUs _sourceIn(MediaId media, TimeUs length) {
    final d = assets[media]!.probe.duration;
    final room = d - length - 6 * microsPerSecond;
    if (room <= 0) return max(0, (d - length) ~/ 2);
    return 3 * microsPerSecond + rnd.nextInt(room);
  }

  MediaClip _videoClip(int k0, int n, {required bool overlay}) {
    final media = pick(videos);
    final speed = _speed();
    final start = at(k0), duration = at(k0 + n) - at(k0);
    final length = ClipTimeMap.sourceLengthOf(duration, speed);
    final hasAudio = assets[media]!.probe.hasAudio;
    MediaClip clip = MediaClip(
      id: ids.itemId(),
      start: start,
      duration: duration,
      media: media,
      sourceIn: _sourceIn(media, length),
      speed: speed,
      maintainPitch: chance(0.9),
      reversed: !overlay && chance(0.03),
      visual: _visual(overlay),
      audio: hasAudio
          ? AudioProps(
              volume: overlay ? 0.3 : 1,
              fadeIn: chance(0.2) ? at(min(15, n ~/ 2)) : 0,
              fadeOut: chance(0.2) ? duration - (at(k0 + n - min(15, n ~/ 2)) - start) : 0,
            )
          : AudioProps.unity,
    );
    if (chance(overlay ? 0.5 : 0.15)) clip = _keyed(clip, n) as MediaClip;
    return clip;
  }

  MediaClip _imageClip(int k0, int n, {required bool overlay}) {
    MediaClip clip = MediaClip(
      id: ids.itemId(),
      start: at(k0),
      duration: at(k0 + n) - at(k0),
      media: pick(images),
      visual: _visual(overlay),
    );
    if (chance(0.3)) clip = _keyed(clip, n) as MediaClip;
    return clip;
  }

  MediaClip _audioClip(int k0, int n, {required bool bed}) {
    final media = pick(audios);
    final start = at(k0), duration = at(k0 + n) - at(k0);
    final speed = !bed && chance(0.1) ? const ConstantSpeed(1.25) : SpeedSpec.normal;
    final length = ClipTimeMap.sourceLengthOf(duration, speed);
    return MediaClip(
      id: ids.itemId(),
      start: start,
      duration: duration,
      media: media,
      sourceIn: _sourceIn(media, length),
      speed: speed,
      audio: AudioProps(
        volume: (uniform(0.3, 1.2) * 100).roundToDouble() / 100,
        fadeIn: at(min(sec(1), n ~/ 2)),
        fadeOut: duration - (at(k0 + n - min(sec(1), n ~/ 2)) - start),
      ),
    );
  }

  VisualProps _visual(bool overlay) {
    final r = rnd.nextDouble();
    final LookRef? look = r < 0.15
        ? BuiltinLook(pick(const ['tealOrange', 'warm', 'mono']), intensity: 0.8)
        : (r < 0.2 ? ImportedLut(lut, intensity: 0.6) : null);
    return VisualProps(
      transform: overlay
          ? Transform2D(position: Vec2(uniform(-0.3, 0.3), uniform(-0.3, 0.3)), scale: uniform(0.3, 0.6), opacity: 0.9)
          : Transform2D.identity,
      look: look,
      chroma: overlay && chance(0.15) ? const ChromaKey(enabled: true) : ChromaKey.off,
      mask: overlay && chance(0.15) ? const MaskSpec(shape: MaskShape.ellipse) : MaskSpec.none,
    );
  }

  /// Opacity and scale keys at the item's start, middle and end.
  TimelineItem _keyed(TimelineItem item, int n) {
    var set = keyframesOf(item);
    set = KeyframeOps.setKey(set, PropertyKeys.opacity, 0, 0.0);
    set = KeyframeOps.setKey(set, PropertyKeys.opacity, at(min(15, n ~/ 2)), 1.0);
    if (chance(0.5)) {
      set = KeyframeOps.setKey(set, PropertyKeys.scale, 0, 1.0);
      set = KeyframeOps.setKey(set, PropertyKeys.scale, at(n - 1), 1.2);
    }
    return withKeyframes(item, set);
  }

  static const List<String> _texts = ['Day one', 'Summer trip 🌴', 'Crème brûlée', '東京タワー', 'The end', 'Chapter two\nThe coast'];

  TextItem _text(int k0, int n) {
    final start = at(k0), duration = at(k0 + n) - at(k0);
    final inKind = pick(TextAnimKind.values);
    final outKind = pick(const [TextAnimKind.none, TextAnimKind.fade, TextAnimKind.slide, TextAnimKind.scale]);
    TimelineItem item = TextItem(
      id: ids.itemId(),
      start: start,
      duration: duration,
      text: pick(_texts),
      style: TextStyleSpec(bold: chance(0.4), fontSizePt: uniform(36, 72).roundToDouble()),
      transform: Transform2D(position: Vec2(0, uniform(-0.4, 0.4))),
      animation: TextAnimation(
        inKind: inKind,
        inDuration: inKind == TextAnimKind.none ? 0 : at(sec(1)),
        outKind: outKind,
        outDuration: outKind == TextAnimKind.none ? 0 : at(sec(0.5)),
      ),
    );
    if (chance(0.2)) item = _keyed(item, n);
    return item as TextItem;
  }
}
