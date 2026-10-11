// OWNER: CORE-08
//
// Seeded random **valid** project generator (BUILD_PLAN CORE-08), shared with the fuzzer (CORE-34)
// and benchmarks. The same seed and spec always produce the same project (ids from
// `SeededIdGenerator(seed)`, values from `Random(seed)`).
//
// Coverage: every track kind (several video/overlay/audio/text/subtitle lanes, the first video
// lane main), video/image/still/audio/recording/LUT media, constant speeds and ramps, reversed
// clips, random visual props within the property ranges (crop, fit, adjust, detail, looks incl.
// imported LUTs, chroma, masks), audio fades, keyframes (including keys outside the item range),
// text items with every animation kind and multi-script text, cues with inline markup, transitions
// of every kind within their limits, links (video clips with extracted-audio partners) and
// markers.

import 'dart:math';

import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';

/// What [randomProject] generates.
final class RandomProjectSpec {
  /// Creates a spec; the default is a small project of about 60 items.
  const RandomProjectSpec({
    this.items = 60,
    this.maxVideoLanes = 3,
    this.maxOverlayLanes = 3,
    this.maxAudioLanes = 3,
    this.maxTextLanes = 2,
    this.maxSubtitleLanes = 2,
    this.frameRate,
    this.transitions = true,
    this.ramps = true,
    this.keyframes = true,
    this.links = true,
    this.markers = true,
  });

  /// Approximate number of timeline items (partners of linked clips included).
  final int items;

  /// Most video lanes (≥ 1; the first is the main lane).
  final int maxVideoLanes;

  /// Most overlay lanes.
  final int maxOverlayLanes;

  /// Most audio lanes besides the extracted-audio lane.
  final int maxAudioLanes;

  /// Most text lanes.
  final int maxTextLanes;

  /// Most subtitle lanes.
  final int maxSubtitleLanes;

  /// Fixed project rate, or null for a random supported rate.
  final FrameRate? frameRate;

  /// Whether to add transitions.
  final bool transitions;

  /// Whether to use speed ramps.
  final bool ramps;

  /// Whether to add keyframes.
  final bool keyframes;

  /// Whether to add linked extracted-audio partners.
  final bool links;

  /// Whether to add markers.
  final bool markers;

  /// A copy with the given fields replaced.
  RandomProjectSpec copyWith({int? items, FrameRate? frameRate}) => RandomProjectSpec(
        items: items ?? this.items,
        maxVideoLanes: maxVideoLanes,
        maxOverlayLanes: maxOverlayLanes,
        maxAudioLanes: maxAudioLanes,
        maxTextLanes: maxTextLanes,
        maxSubtitleLanes: maxSubtitleLanes,
        frameRate: frameRate ?? this.frameRate,
        transitions: transitions,
        ramps: ramps,
        keyframes: keyframes,
        links: links,
        markers: markers,
      );
}

/// A random valid project for [seed] (deterministic).
EditProject randomProject(int seed, [RandomProjectSpec spec = const RandomProjectSpec()]) => _Gen(seed, spec).build();

/// Text samples covering scripts, emoji ZWJ sequences, combining marks and line breaks.
const List<String> randomTextSamples = [
  'Hello',
  'Summer trip 🌴',
  'Crème brûlée',
  '東京タワー',
  'नमस्ते दुनिया',
  'مرحبا بالعالم',
  '👨‍👩‍👧‍👦 family',
  'été',
  'Line one\nLine two',
  '🇯🇵 + 🇫🇷',
];

/// Cue samples with inline markup.
const List<String> randomCueSamples = [
  'Hi there',
  '<i>Whispering</i> now',
  '<b>Loud</b> and clear',
  'Two\nlines',
  'Ça va ?',
  '你好，世界',
];

final class _Gen {
  _Gen(int seed, this.spec)
      : rnd = Random(seed),
        ids = SeededIdGenerator(seed);

  final RandomProjectSpec spec;
  final Random rnd;
  final IdGenerator ids;

  late FrameRate rate;
  late ProjectSettings settings;
  final Map<MediaId, MediaAsset> assets = {};
  final List<MediaId> videos = [];
  final List<MediaId> images = [];
  final List<MediaId> stills = [];
  final List<MediaId> audios = [];
  MediaId? lut;
  final DateTime when = DateTime.utc(2026, 10, 9, 12);

  double uniform(double a, double b) => a + rnd.nextDouble() * (b - a);
  bool chance(double p) => rnd.nextDouble() < p;
  T pick<T>(List<T> xs) => xs[rnd.nextInt(xs.length)];
  TimeUs at(int k) => rate.timeOfFrame(k);

  EditProject build() {
    rate = spec.frameRate ?? FrameRate(pick(FrameRate.supportedProjectRates), 1);
    settings = ProjectSettings(
      canvas: CanvasSpec(aspect: pick(AspectRatio.standard), baseShortSide: pick(CanvasSpec.supportedShortSides)),
      frameRate: rate,
      background: chance(0.3) ? BlurOfMainBackground(uniform(0, 1)) : SolidBackground(0xFF000000 | rnd.nextInt(0xFFFFFF)),
    );
    _media();

    final videoLanes = 1 + rnd.nextInt(max(1, spec.maxVideoLanes));
    final overlayLanes = rnd.nextInt(spec.maxOverlayLanes + 1);
    final audioLanes = rnd.nextInt(spec.maxAudioLanes + 1);
    final textLanes = rnd.nextInt(spec.maxTextLanes + 1);
    final subtitleLanes = rnd.nextInt(spec.maxSubtitleLanes + 1);
    final lanes = videoLanes + overlayLanes + audioLanes + textLanes + subtitleLanes;
    // The main lane gets a double share; partners add roughly a fifth of the main lane.
    final share = max(1, spec.items ~/ (lanes + 1.5));

    final tracks = <Track>[];
    Track? main;
    for (var i = 0; i < videoLanes; i++) {
      final t = _visualLane(TrackKind.video, i == 0 ? share * 2 : share, isMain: i == 0);
      if (i == 0) main = t;
      tracks.add(t);
    }
    for (var i = 0; i < overlayLanes; i++) {
      tracks.add(_visualLane(TrackKind.overlay, share));
    }
    for (var i = 0; i < textLanes; i++) {
      tracks.add(_textLane(share));
    }
    for (var i = 0; i < subtitleLanes; i++) {
      tracks.add(_subtitleLane(share));
    }
    if (spec.links) {
      final linked = _linkPartners(main!);
      if (linked != null) {
        tracks[0] = linked.$1;
        tracks.add(linked.$2);
      }
    }
    for (var i = 0; i < audioLanes; i++) {
      tracks.add(_audioLane(share));
    }

    final timeline = Timeline(settings: settings, tracks: tracks, markers: spec.markers ? _markers(tracks) : const []);
    return EditProject(
      id: ids.projectId(),
      meta: ProjectMeta(name: 'Random', createdAt: when, updatedAt: when),
      timeline: timeline,
      pool: MediaPool(assets),
    );
  }

  // -------------------------------------------------------------------------------------------
  // Media.
  // -------------------------------------------------------------------------------------------

  static const List<(int, int)> _sizes = [(1920, 1080), (1080, 1920), (3840, 2160), (1280, 720), (720, 1280), (1080, 1080)];

  MediaAsset _asset(MediaKind kind, {TimeUs duration = 0, int? w, int? h, bool hasAudio = false, DerivedSpec? derived, AssetStatus status = AssetStatus.ready}) {
    final id = ids.mediaId();
    return MediaAsset(
      id: id,
      kind: kind,
      displayName: '${kind.name} ${assets.length}',
      locator: AppRelativeLocator(AppRoot.documents, 'media/$id'),
      ownership: MediaOwnership.managedCopy,
      fingerprint: MediaFingerprint(sizeBytes: 1000 + rnd.nextInt(1 << 30), quickHash: id.padRight(40, '0'), duration: duration),
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
      derived: derived,
      status: status,
      addedAt: when,
    );
  }

  void _media() {
    final nVideo = 3 + rnd.nextInt(5);
    for (var i = 0; i < nVideo; i++) {
      final (w, h) = pick(_sizes);
      final a = _asset(MediaKind.video,
          duration: (uniform(3, 600) * microsPerSecond).round(), w: w, h: h, hasAudio: chance(0.75));
      assets[a.id] = a;
      videos.add(a.id);
    }
    for (var i = 0; i < 2 + rnd.nextInt(3); i++) {
      final (w, h) = pick(_sizes);
      final a = _asset(MediaKind.image, w: w, h: h);
      assets[a.id] = a;
      images.add(a.id);
    }
    for (var i = 0; i < rnd.nextInt(3); i++) {
      final src = assets[pick(videos)]!;
      final (w, h) = (src.probe.width, src.probe.height);
      final a = _asset(
        MediaKind.still,
        w: w,
        h: h,
        derived: StillSpec(src.id, rnd.nextInt(src.probe.duration), sourceQuickHash: src.fingerprint.quickHash),
        status: chance(0.5) ? AssetStatus.ready : const PendingStatus('job_still'),
      );
      assets[a.id] = a;
      stills.add(a.id);
    }
    for (var i = 0; i < 2 + rnd.nextInt(3); i++) {
      final a = _asset(chance(0.7) ? MediaKind.audio : MediaKind.recording,
          duration: (uniform(10, 600) * microsPerSecond).round(), hasAudio: true);
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

  /// Frame lengths: mostly 15–150 frames, sometimes very short or long.
  int _frames() {
    final r = rnd.nextDouble();
    if (r < 0.15) return 1 + rnd.nextInt(15);
    if (r < 0.9) return 15 + rnd.nextInt(136);
    return 150 + rnd.nextInt(750);
  }

  /// Lays out [count] items with [make] (which may shorten the requested frame count).
  List<TimelineItem> _sequence(int count, {required double touchChance, required TimelineItem? Function(int k0, int frames) make}) {
    final out = <TimelineItem>[];
    var k = rnd.nextInt(30);
    final limit = rate.frameIndexOf(maxProjectDurationUs);
    for (var i = 0; i < count; i++) {
      if (!chance(touchChance) || i == 0) k += rnd.nextInt(60);
      final frames = _frames();
      if (k + frames > limit) break;
      final item = make(k, frames);
      if (item == null) continue;
      out.add(item);
      k = rate.frameIndexOf(item.end);
    }
    return out;
  }

  Track _visualLane(TrackKind kind, int count, {bool isMain = false}) {
    final items = _sequence(count, touchChance: isMain ? 0.7 : 0.35, make: (k0, n) => _visualClip(k0, n));
    var track = Track(id: ids.trackId(), kind: kind, isMain: isMain, items: items, hidden: !isMain && chance(0.1));
    if (spec.transitions) track = _addTransitions(track);
    return track;
  }

  Track _audioLane(int count) => Track(
        id: ids.trackId(),
        kind: TrackKind.audio,
        audioRole: pick(AudioRole.values),
        muted: chance(0.1),
        items: _sequence(count, touchChance: 0.3, make: (k0, n) => _audioClip(k0, n)),
      );

  Track _textLane(int count) => Track(
        id: ids.trackId(),
        kind: TrackKind.text,
        items: _sequence(count, touchChance: 0.2, make: (k0, n) => _textItem(k0, n)),
      );

  Track _subtitleLane(int count) => Track(
        id: ids.trackId(),
        kind: TrackKind.subtitle,
        subtitle: SubtitleTrackData(
          language: chance(0.5) ? 'en' : null,
          style: SubtitleStyle(maxLines: 1 + rnd.nextInt(3), fontSizePt: uniform(20, 80), bold: chance(0.3)),
          position: switch (rnd.nextInt(3)) {
            0 => SubtitlePosition.bottom,
            1 => SubtitlePosition.top,
            _ => CustomSubtitlePosition(uniform(0.1, 0.9)),
          },
          burnIn: chance(0.5),
        ),
        items: _sequence(count, touchChance: 0.6, make: (k0, n) {
          return SubtitleCue(
            id: ids.itemId(),
            start: at(k0),
            duration: at(k0 + n) - at(k0),
            text: pick(randomCueSamples),
            origin: pick(CueOrigin.values),
          );
        }),
      );

  // -------------------------------------------------------------------------------------------
  // Items.
  // -------------------------------------------------------------------------------------------

  SpeedSpec _speed({required bool allowRamp}) {
    if (allowRamp && spec.ramps && chance(0.15)) {
      final n = 2 + rnd.nextInt(4);
      final xs = <double>{0, 1};
      while (xs.length < n) {
        xs.add((uniform(0.05, 0.95) * 100).roundToDouble() / 100);
      }
      final sorted = xs.toList()..sort();
      return SpeedRamp([for (final x in sorted) SpeedPoint(x, (uniform(0.25, 4) * 100).roundToDouble() / 100)],
          presetId: chance(0.3) ? 'montage' : null);
    }
    if (chance(0.6)) return SpeedSpec.normal;
    return ConstantSpeed(pick(speedPresets));
  }

  /// The largest frame count ≤ [frames] from [k0] whose source length at [speed] fits [available].
  int _fit(int k0, int frames, SpeedSpec speed, TimeUs available) {
    final k = speedTimeFactor(speed);
    var n = min(frames, rate.frameIndexOf(at(k0) + (available * k).floor()) - k0);
    while (n >= 1 && ClipTimeMap.sourceLengthOf(at(k0 + n) - at(k0), speed) > available) {
      n--;
    }
    return n;
  }

  MediaClip? _mediaClip(int k0, int frames, MediaId media, {required bool visual}) {
    final asset = assets[media]!;
    final timeBased = asset.kind != MediaKind.image && asset.kind != MediaKind.still;
    var speed = timeBased ? _speed(allowRamp: true) : SpeedSpec.normal;
    var n = frames;
    TimeUs sourceIn = 0;
    if (timeBased) {
      final d = asset.probe.duration;
      n = _fit(k0, frames, speed, d);
      if (n < 1) {
        speed = SpeedSpec.normal;
        n = _fit(k0, frames, speed, d);
        if (n < 1) return null;
      }
      final length = ClipTimeMap.sourceLengthOf(at(k0 + n) - at(k0), speed);
      sourceIn = d - length <= 0 ? 0 : rnd.nextInt(d - length + 1);
    }
    final start = at(k0);
    final duration = at(k0 + n) - start;
    final half = n ~/ 2;
    final hasAudio = asset.kind == MediaKind.audio || asset.kind == MediaKind.recording || asset.probe.hasAudio;
    final fadeIn = hasAudio && chance(0.3) ? at(k0 + rnd.nextInt(half + 1)) - start : 0;
    final fadeOut = hasAudio && chance(0.3) ? start + duration - at(k0 + n - rnd.nextInt(half + 1)) : 0;
    MediaClip clip = MediaClip(
      id: ids.itemId(),
      start: start,
      duration: duration,
      media: media,
      sourceIn: sourceIn,
      speed: speed,
      maintainPitch: chance(0.8),
      reversed: timeBased && asset.kind == MediaKind.video && chance(0.1),
      visual: visual ? _visualProps() : null,
      audio: AudioProps(volume: (uniform(0, 2) * 100).roundToDouble() / 100, muted: chance(0.05), fadeIn: fadeIn, fadeOut: fadeOut),
      label: chance(0.05) ? 'Label' : null,
    );
    clip = _randomStatics(clip) as MediaClip;
    if (spec.keyframes && chance(0.35)) clip = _randomKeys(clip, k0, n) as MediaClip;
    return clip;
  }

  MediaClip? _visualClip(int k0, int frames) {
    final r = rnd.nextDouble();
    final media = r < 0.7 || images.isEmpty
        ? pick(videos)
        : (r < 0.9 || stills.isEmpty ? pick(images) : pick(stills));
    return _mediaClip(k0, frames, media, visual: true);
  }

  MediaClip? _audioClip(int k0, int frames) {
    final withAudio = videos.where((v) => assets[v]!.probe.hasAudio).toList();
    final media = chance(0.65) || withAudio.isEmpty ? pick(audios) : pick(withAudio);
    return _mediaClip(k0, frames, media, visual: false);
  }

  VisualProps _visualProps() {
    LookRef? look;
    final lr = rnd.nextDouble();
    if (lr < 0.15) {
      look = BuiltinLook(pick(const ['tealOrange', 'warm', 'mono']), intensity: uniform(0, 1));
    } else if (lr < 0.22) {
      look = ImportedLut(lut!, intensity: uniform(0, 1));
    }
    return VisualProps(
      transform: Transform2D(flipH: chance(0.1), flipV: chance(0.05)),
      fit: pick(FitMode.values),
      look: look,
      chroma: chance(0.1) ? const ChromaKey(enabled: true) : ChromaKey.off,
      mask: chance(0.1) ? MaskSpec(shape: chance(0.5) ? MaskShape.rectangle : MaskShape.ellipse, invert: chance(0.3)) : MaskSpec.none,
    );
  }

  /// A random in-range value for [key].
  Object _value(PropertyKey<Object?> key) => switch (key.valueKind) {
        PropertyValueKind.vec2 => Vec2(uniform(key.min, key.max), uniform(key.min, key.max)),
        PropertyValueKind.rect => () {
            final l = uniform(0, 0.3), t = uniform(0, 0.3);
            return CropRect(left: l, top: t, right: uniform(l + 0.2, 1), bottom: uniform(t + 0.2, 1));
          }(),
        _ => uniform(key.min, key.max),
      };

  /// Writes random in-range static values to a few of [item]'s ranged properties.
  TimelineItem _randomStatics(TimelineItem item) {
    var out = item;
    final keys = rangeCheckedKeysOf(item);
    final n = rnd.nextInt(6);
    for (var i = 0; i < n && keys.isNotEmpty; i++) {
      final key = pick(keys);
      if (key == PropertyKeys.lookIntensity && (out as MediaClip).visual?.look == null) continue;
      out = key.write(out, _value(key));
    }
    return out;
  }

  /// Adds 1–3 keyframed properties with 1–4 keys at frames around the item (some outside it).
  TimelineItem _randomKeys(TimelineItem item, int k0, int n) {
    final keys = PropertyKeys.keyframable.where((k) => k.appliesToItem(item)).toList();
    var set = keyframesOf(item);
    final count = 1 + rnd.nextInt(3);
    for (var i = 0; i < count; i++) {
      final key = pick(keys);
      final m = 1 + rnd.nextInt(4);
      for (var j = 0; j < m; j++) {
        final f = max(0, k0 - 5 + rnd.nextInt(n + 10));
        set = KeyframeOps.setKey(set, key, at(f) - item.start, _value(key));
      }
    }
    return withKeyframes(item, set);
  }

  TextItem _textItem(int k0, int n) {
    final start = at(k0);
    final duration = at(k0 + n) - start;
    final inKind = pick(TextAnimKind.values);
    final outKind = pick(const [TextAnimKind.none, TextAnimKind.fade, TextAnimKind.slide, TextAnimKind.scale]);
    final a = inKind == TextAnimKind.none ? 0 : rnd.nextInt(n ~/ 2 + 1);
    final b = outKind == TextAnimKind.none ? 0 : rnd.nextInt(n - a + 1);
    TimelineItem item = TextItem(
      id: ids.itemId(),
      start: start,
      duration: duration,
      text: pick(randomTextSamples),
      style: TextStyleSpec(align: pick(TextAlignH.values), bold: chance(0.3), italic: chance(0.2)),
      animation: TextAnimation(
        inKind: inKind,
        inDirection: pick(TextSlideDirection.values),
        inDuration: at(k0 + a) - start,
        outKind: outKind,
        outDirection: pick(TextSlideDirection.values),
        outDuration: start + duration - at(k0 + n - b),
      ),
    );
    item = _randomStatics(item);
    if (spec.keyframes && chance(0.3)) item = _randomKeys(item, k0, n);
    return item as TextItem;
  }

  // -------------------------------------------------------------------------------------------
  // Transitions, links, markers.
  // -------------------------------------------------------------------------------------------

  Track _addTransitions(Track track) {
    var t = track;
    final items = track.items;
    for (var i = 0; i + 1 < items.length; i++) {
      final left = items[i];
      final right = items[i + 1];
      if (left is! MediaClip || right is! MediaClip || left.end != right.start || !chance(0.5)) continue;
      final kind = pick(TransitionKind.values);
      final maxFrames = TransitionBounds.maxFrames(
        track: t,
        left: left,
        right: right,
        kind: kind,
        rate: rate,
        pool: MediaPool(assets),
      );
      if (maxFrames < 1) continue;
      final n = 1 + rnd.nextInt(min(maxFrames, 45));
      final direction = switch (kind) {
        TransitionKind.slide || TransitionKind.wipe => pick(const [
            TransitionDirection.left,
            TransitionDirection.right,
            TransitionDirection.up,
            TransitionDirection.down,
          ]),
        TransitionKind.zoom => pick(const [TransitionDirection.zoomIn, TransitionDirection.zoomOut]),
        _ => null,
      };
      t = t.copyWith(transitions: [
        ...t.transitions,
        Transition(id: ids.transitionId(), left: left.id, right: right.id, kind: kind, durationFrames: n, direction: direction),
      ]);
    }
    return t;
  }

  /// Extracted-audio partners for some main-lane clips whose media has audio: the main clip and
  /// a copy on a new audio lane share a link id. Returns (updated main track, partner lane).
  (Track, Track)? _linkPartners(Track main) {
    final mainItems = List<TimelineItem>.of(main.items);
    final partners = <TimelineItem>[];
    for (var i = 0; i < mainItems.length; i++) {
      final c = mainItems[i];
      if (c is! MediaClip) continue;
      final asset = assets[c.media]!;
      if (asset.kind != MediaKind.video || !asset.probe.hasAudio || !chance(0.4)) continue;
      final link = ids.linkId();
      mainItems[i] = c.copyWith(link: link, detachedAudio: true);
      partners.add(MediaClip(
        id: ids.itemId(),
        start: c.start,
        duration: c.duration,
        media: c.media,
        sourceIn: c.sourceIn,
        speed: c.speed,
        reversed: c.reversed,
        maintainPitch: c.maintainPitch,
        audio: c.audio,
        link: link,
      ));
    }
    if (partners.isEmpty) return null;
    return (
      main.copyWith(items: mainItems),
      Track(id: ids.trackId(), kind: TrackKind.audio, audioRole: AudioRole.original, items: partners),
    );
  }

  List<Marker> _markers(List<Track> tracks) {
    var end = 0;
    for (final t in tracks) {
      if (t.items.isNotEmpty && t.items.last.end > end) end = t.items.last.end;
    }
    final frames = max(1, rate.frameIndexOf(end));
    final markers = [
      for (var i = 0; i < rnd.nextInt(8); i++)
        Marker(id: ids.markerId(), time: at(rnd.nextInt(frames)), name: chance(0.5) ? 'M$i' : '', colorIndex: rnd.nextInt(8)),
    ];
    markers.sort((a, b) => a.time != b.time ? a.time.compareTo(b.time) : a.id.compareTo(b.id));
    return markers;
  }
}
