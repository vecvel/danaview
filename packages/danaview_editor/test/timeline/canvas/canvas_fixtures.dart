// OWNER: UX-10
//
// Test projects for the timeline canvas tests: every item kind (video, image, freeze, audio, text,
// cue) and state (offline, pending, speed, ramp, reversed, muted, fx, colour, LUT, chroma, mask,
// keyframes, fades, volume keys, locked and hidden lanes, a transition, a "+" cut, main-lane gaps),
// plus a large generated project for the visible-window tests.

import 'package:danaview_editor_core/model.dart';

const int s = microsPerSecond;

/// Frame-grid times on 30 fps.
TimeUs f(int frames) => FrameRate.fps30.timeOfFrame(frames);

MediaAsset asset(
  String id, {
  MediaKind kind = MediaKind.video,
  String? name,
  bool hasAudio = true,
  AssetStatus status = AssetStatus.ready,
  DerivedSpec? derived,
  int width = 1920,
  int height = 1080,
}) =>
    MediaAsset(
      id: MediaId(id),
      kind: kind,
      displayName: name ?? '$id.mp4',
      locator: AppRelativeLocator(AppRoot.support, 'danaview/editor/media/$id/file'),
      ownership: MediaOwnership.managedCopy,
      fingerprint: MediaFingerprint(sizeBytes: 1000, quickHash: id.padRight(40, '0')),
      probe: MediaProbe(
        kind: kind,
        duration: 60 * s,
        hasVideo: kind != MediaKind.audio,
        hasAudio: hasAudio,
        width: kind == MediaKind.audio ? null : width,
        height: kind == MediaKind.audio ? null : height,
      ),
      origin: MediaOrigin.files,
      derived: derived,
      status: status,
      addedAt: DateTime.utc(2026, 10, 1),
    );

MediaClip clip(String id, String media, TimeUs start, TimeUs duration,
        {String? label,
        SpeedSpec speed = SpeedSpec.normal,
        bool reversed = false,
        VisualProps? visual,
        AudioProps audio = AudioProps.unity,
        KeyframeSet keyframes = KeyframeSet.empty}) =>
    MediaClip(
      id: ItemId(id),
      start: start,
      duration: duration,
      media: MediaId(media),
      label: label,
      speed: speed,
      reversed: reversed,
      visual: visual,
      audio: audio,
      keyframes: keyframes,
    );

KeyframeSet keys(Map<String, List<int>> framesByChannel, {double v = 1}) => KeyframeSet({
      for (final e in framesByChannel.entries) e.key: KeyframeTrack([for (final fr in e.value) Keyframe(f(fr), v)]),
    });

EditProject projectOf(List<Track> tracks, {List<MediaAsset> assets = const [], List<Marker> markers = const [], int revision = 1}) =>
    EditProject(
      id: const ProjectId('pr_canvas'),
      meta: ProjectMeta(name: 'Canvas', createdAt: DateTime.utc(2026, 10, 1), updatedAt: DateTime.utc(2026, 10, 1)),
      timeline: Timeline(tracks: tracks, markers: markers, revision: revision),
      pool: MediaPool({for (final a in assets) a.id: a}),
    );

/// Media of [richProject].
final List<MediaAsset> richAssets = [
  asset('m_beach', name: 'beach.mp4'),
  asset('m_photo', kind: MediaKind.image, name: 'photo.jpg', hasAudio: false),
  asset('m_city', name: 'city at night.mov'),
  asset('m_lost', name: 'lost.mp4'),
  asset('m_still',
      kind: MediaKind.image,
      name: 'still.png',
      hasAudio: false,
      derived: const StillSpec(MediaId('m_city'), 2 * s, sourceQuickHash: 'q'),
      status: const PendingStatus('job1')),
  asset('m_song', kind: MediaKind.audio, name: 'song.m4a'),
  asset('m_logo', kind: MediaKind.image, name: 'logo.png', hasAudio: false, width: 512, height: 512),
];

/// Every item kind and state on seven lanes.
EditProject richProject() {
  final main = Track(
    id: const TrackId('tr_main'),
    kind: TrackKind.video,
    isMain: true,
    items: [
      // Gap 0..1 s.
      clip('it_v1', 'm_beach', 1 * s, 4 * s, audio: const AudioProps(fadeIn: 1 * s, fadeOut: s ~/ 2)),
      clip('it_v2', 'm_photo', 5 * s, 3 * s),
      clip('it_v3', 'm_city', 8 * s, 3 * s, speed: const ConstantSpeed(2)),
      // Gap 11..12 s.
      clip('it_v4', 'm_lost', 12 * s, 3 * s),
      clip('it_v5', 'm_still', 15 * s, 2 * s),
    ],
    transitions: const [
      Transition(
        id: TransitionId('tx_1'),
        left: ItemId('it_v1'),
        right: ItemId('it_v2'),
        kind: TransitionKind.crossDissolve,
        durationFrames: 15,
      ),
    ],
  );
  final video2 = Track(
    id: const TrackId('tr_video2'),
    kind: TrackKind.video,
    items: [
      clip(
        'it_v6',
        'm_city',
        2 * s,
        6 * s,
        label: 'Graded',
        reversed: true,
        speed: SpeedRamp(const [SpeedPoint(0, 1), SpeedPoint(1, 2)]),
        audio: const AudioProps(muted: true),
        visual: const VisualProps(
          adjust: ColorAdjust(exposure: 0.2),
          detail: DetailFx(blur: 0.3),
          look: BuiltinLook('tealOrange'),
          chroma: ChromaKey(enabled: true),
          mask: MaskSpec(shape: MaskShape.ellipse),
        ),
        keyframes: keys({'transform.opacity': [0, 30]}),
      ),
    ],
  );
  final overlay = Track(
    id: const TrackId('tr_overlay'),
    kind: TrackKind.overlay,
    items: [
      clip('it_o1', 'm_logo', 1 * s, 5 * s,
          visual: const VisualProps(),
          keyframes: keys({'transform.position.x': [0, 60], 'transform.position.y': [0, 60], 'transform.scale': [30]})),
    ],
  );
  final hiddenOverlay = Track(
    id: const TrackId('tr_overlay2'),
    kind: TrackKind.overlay,
    hidden: true,
    items: [clip('it_o2', 'm_logo', 6 * s, 4 * s)],
  );
  final text = Track(
    id: const TrackId('tr_text'),
    kind: TrackKind.text,
    items: [
      TextItem(id: const ItemId('it_t1'), start: 1 * s, duration: 3 * s, text: 'Hello world\nsecond line', keyframes: keys({'transform.rotation': [15]})),
    ],
  );
  final subs = Track(
    id: const TrackId('tr_subs'),
    kind: TrackKind.subtitle,
    subtitle: const SubtitleTrackData(),
    items: [
      SubtitleCue(id: const ItemId('it_c1'), start: 0, duration: 2 * s, text: 'First caption'),
      SubtitleCue(id: const ItemId('it_c2'), start: 2 * s, duration: 2 * s, text: 'Second caption'),
    ],
  );
  final music = Track(
    id: const TrackId('tr_music'),
    kind: TrackKind.audio,
    audioRole: AudioRole.music,
    items: [
      clip('it_a1', 'm_song', 0, 10 * s,
          audio: const AudioProps(volume: 0.8, fadeIn: 2 * s, fadeOut: 2 * s),
          keyframes: keys({'audio.volume': [60, 180]}, v: 0.5)),
    ],
  );
  final locked = Track(
    id: const TrackId('tr_voice'),
    kind: TrackKind.audio,
    audioRole: AudioRole.voice,
    locked: true,
    items: [clip('it_a2', 'm_song', 3 * s, 5 * s, audio: const AudioProps(muted: true))],
  );
  return projectOf(
    [main, video2, overlay, hiddenOverlay, text, subs, music, locked],
    assets: richAssets,
    markers: const [Marker(id: MarkerId('mk_1'), time: 3 * s)],
  );
}

/// One main lane with [count] back-to-back one-second clips plus [lanes] - 1 audio lanes with the
/// same layout (the "large project" of ux.md §17.6).
EditProject largeProject({int count = 2000, int lanes = 4}) {
  final assets = [asset('m_a'), asset('m_s', kind: MediaKind.audio, name: 'a.m4a')];
  final tracks = <Track>[
    Track(
      id: const TrackId('tr_main'),
      kind: TrackKind.video,
      isMain: true,
      items: [for (var i = 0; i < count; i++) clip('it_m$i', 'm_a', i * s, s)],
    ),
    for (var l = 1; l < lanes; l++)
      Track(
        id: TrackId('tr_a$l'),
        kind: TrackKind.audio,
        items: [for (var i = 0; i < count; i++) clip('it_a${l}_$i', 'm_s', i * s, s)],
      ),
  ];
  return projectOf(tracks, assets: assets);
}

/// [project] with [track]'s items replaced by [items] (the other tracks keep their instances).
EditProject withTrackItems(EditProject project, TrackId track, List<TimelineItem> items, {int? revision}) {
  final tracks = [
    for (final t in project.timeline.tracks) t.id == track ? t.copyWith(items: items, changedAt: t.changedAt + 1) : t,
  ];
  return EditProject(
    id: project.id,
    meta: project.meta,
    timeline: project.timeline.copyWith(tracks: tracks, revision: revision ?? project.timeline.revision + 1),
    pool: project.pool,
    view: project.view,
  );
}
