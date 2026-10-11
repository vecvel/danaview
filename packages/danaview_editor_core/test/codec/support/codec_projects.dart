// OWNER: CORE-22
//
// Projects for the codec tests:
// - `decorate` widens a CORE-08 random project (test/support/random_project.dart) to every field
//   the generator leaves at its default (view state, meta origin, revisions, every locator kind,
//   full probes, statuses, derived specs, styles, provenance, …), so the round-trip property covers
//   the whole body schema;
// - `kitchenSinkProject` is a small hand-built project with a non-default value in every field (the
//   golden fixture);
// - `minimalProject` is an empty project (all defaults).

import 'dart:math';

import 'package:danaview_editor_core/model.dart';

import '../../support/random_project.dart';

final DateTime _t0 = DateTime.utc(2026, 10, 9, 12);

/// A random CORE-08 project for [seed], decorated with [decorate].
EditProject decoratedRandomProject(int seed, [RandomProjectSpec spec = const RandomProjectSpec()]) =>
    decorate(randomProject(seed, spec), seed);

/// [project] with random non-default values in the fields the CORE-08 generator leaves at their
/// defaults. Deterministic for a given [seed]. The result is not necessarily *valid* (the codec
/// does not validate), only well-formed.
EditProject decorate(EditProject project, int seed) => _Decorator(Random(seed * 7919 + 17)).run(project);

final class _Decorator {
  _Decorator(this.r);
  final Random r;

  bool chance(double p) => r.nextDouble() < p;
  T pick<T>(List<T> xs) => xs[r.nextInt(xs.length)];
  double unit() => (r.nextDouble() * 1000).roundToDouble() / 1000;
  double any(double a, double b) => a + r.nextDouble() * (b - a);
  int color() => r.nextInt(1 << 32);
  int big(int bits) => bits <= 32 ? r.nextInt(1 << bits) : r.nextInt(1 << (bits - 16)) * 65536 + r.nextInt(65536);
  String word() => pick(const ['alpha', 'Beta 2', 'été', '東京', 'x', '🎬 take', 'q"uote', r'back\slash', 'tab\tline']);
  String qh() => List.generate(40, (_) => '0123456789abcdef'[r.nextInt(16)]).join();

  EditProject run(EditProject p) {
    var stamp = 1 + r.nextInt(1000);
    final tracks = [for (final t in p.tracks) _track(t, stamp += 1 + r.nextInt(5))];
    final markers = [
      for (final m in p.markers) chance(0.4) ? m.copyWith(note: chance(0.5) ? word() : '') : m,
    ];
    final settings = p.settings.copyWith(
      audioSampleRate: chance(0.2) ? 44100 : null,
      background: chance(0.2) ? SolidBackground(color()) : null,
    );
    return p.copyWith(
      meta: p.meta.copyWith(
        name: word(),
        editCount: chance(0.7) ? r.nextInt(5000) : 0,
        origin: chance(0.4)
            ? FromPlayerOrigin(quickHash: qh(), sizeBytes: big(40), displayName: chance(0.7) ? '${word()}.mp4' : '')
            : null,
        updatedAt: _t0.add(Duration(microseconds: big(40))),
      ),
      timeline: p.timeline.copyWith(
        tracks: tracks,
        markers: markers,
        settings: settings,
        revision: stamp + 1,
      ),
      pool: MediaPool({for (final a in p.pool.assets.values) a.id: _asset(a, p.pool)}),
      view: chance(0.8) ? _view(p) : null,
      docRevision: chance(0.8) ? r.nextInt(100000) : 0,
    );
  }

  ViewState _view(EditProject p) => ViewState(
        playhead: p.settings.frameRate.timeOfFrame(r.nextInt(10000)),
        pixelsPerSecond: chance(0.5) ? any(5, 400) : 120,
        scrollTimeUs: r.nextInt(1 << 32),
        scrollLanePx: chance(0.5) ? any(0, 900) : 0,
        rippleEnabled: chance(0.5),
        snappingEnabled: chance(0.5),
        followMode: chance(0.5) ? pick(PlayheadFollowMode.values) : null,
        lastExportPresetId: chance(0.5) ? pick(const ['p1080', 'shorts', 'p4k']) : null,
      );

  Track _track(Track t, int stamp) {
    var out = t.copyWith(
      name: chance(0.3) ? word() : null,
      locked: chance(0.15),
      solo: chance(0.1),
      changedAt: chance(0.9) ? stamp : 0,
      items: [for (final i in t.items) _item(i)],
    );
    if (t.subtitle != null) out = out.copyWith(subtitle: _subtitle(t.subtitle!, t));
    return out;
  }

  TimelineItem _item(TimelineItem item) => switch (item) {
        MediaClip() => chance(0.3)
            ? item.copyWith(
                audioStream: chance(0.5) ? r.nextInt(3) : null,
                label: chance(0.3) ? word() : null,
              )
            : item,
        TextItem() => item.copyWith(style: _textStyle(item.style), label: chance(0.1) ? word() : null),
        SubtitleCue() => chance(0.3) ? item.copyWith(editedAfterGeneration: true) : item,
      };

  TextStyleSpec _textStyle(TextStyleSpec s) => s.copyWith(
        fontFamily: chance(0.3) ? pick(const ['inter', 'lora', 'notoSansJp', 'unknownFont']) : null,
        fontSizePt: chance(0.3) ? any(8, 200) : null,
        color: chance(0.3) ? color() : null,
        letterSpacing: chance(0.2) ? any(-20, 100) : null,
        lineHeight: chance(0.2) ? any(0.6, 3) : null,
        maxWidth: chance(0.2) ? unit() : null,
        background: chance(0.3) ? _box() : null,
        stroke: chance(0.3) ? StrokeStyle(color: color(), widthPt: chance(0.5) ? 2 : any(0, 20)) : null,
        shadow: chance(0.3) ? _shadow() : null,
      );

  BoxStyle _box() => chance(0.3)
      ? const BoxStyle()
      : BoxStyle(color: color(), opacity: unit(), paddingPt: any(0, 40), cornerRadiusPt: chance(0.5) ? 8 : any(0, 30));

  ShadowStyle _shadow() => ShadowStyle(
        color: color(),
        opacity: chance(0.5) ? 0.5 : unit(),
        blurPt: any(0, 40),
        distancePt: chance(0.5) ? 3 : any(0, 40),
        angleDeg: any(-180, 180),
      );

  SubtitleTrackData _subtitle(SubtitleTrackData d, Track t) {
    final cueIds = [for (final i in t.items) i.id];
    return d.copyWith(
      language: chance(0.5) ? pick(const ['en', 'ja', 'pt-BR', 'zh-Hant']) : null,
      style: d.style.copyWith(
        fontFamily: chance(0.3) ? 'inter' : null,
        italic: chance(0.3),
        color: chance(0.3) ? color() : null,
        background: chance(0.3) ? null : (chance(0.5) ? _box() : const BoxStyle()),
        outline: chance(0.3) ? StrokeStyle(color: color(), widthPt: any(0, 20)) : null,
        shadow: chance(0.3) ? _shadow() : null,
        maxWidth: chance(0.3) ? unit() : null,
        align: chance(0.3) ? pick(TextAlignH.values) : null,
      ),
      provenance: chance(0.5)
          ? CaptionProvenance(
              generator: 'whisper.cpp',
              engineVersion: '1.9.4',
              modelId: pick(const ['whisper-base-q5_1', 'whisper-tiny-q5_1']),
              modelSha256: qh() + qh().substring(0, 24),
              language: 'en',
              languageDetected: chance(0.5),
              languageConfidence: chance(0.5) ? unit() : null,
              segmentation: chance(0.5)
                  ? SegmentationSettings(
                      preset: pick(SegmentationPreset.values),
                      maxLines: r.nextInt(4),
                      maxCharsPerLine: chance(0.5) ? 30 + r.nextInt(20) : 0,
                      maxCharsPerSecond: chance(0.5) ? any(10, 25) : 0,
                    )
                  : const SegmentationSettings(),
              scope: CaptionScopeData(
                clips: chance(0.5) ? cueIds.take(3).toList() : const [],
                tracks: chance(0.5) ? [t.id] : const [],
                range: chance(0.5) ? TimeRange(0, 1 + r.nextInt(1 << 30)) : null,
              ),
              transcriptKeys: chance(0.7) ? [qh(), qh()] : const [],
              generatedAt: _t0.add(Duration(seconds: r.nextInt(1 << 20))),
              schema: chance(0.9) ? 1 : 2,
            )
          : null,
    );
  }

  MediaAsset _asset(MediaAsset a, MediaPool pool) {
    final locator = switch (r.nextInt(5)) {
      0 => AppRelativeLocator(pick(AppRoot.values), 'danaview/editor/media/${a.fingerprint.quickHash.substring(0, 2)}/${a.fingerprint.quickHash}/${word()}.mov'),
      1 => FileLocator('/Users/someone/Movies/${word()}.mov'),
      2 => ContentUriLocator('content://com.android.providers.media.documents/document/video%3A${r.nextInt(100000)}'),
      3 => BookmarkLocator(qh(), lastKnownPath: chance(0.5) ? '/private/var/mobile/Library/Mobile Documents/x/${word()}.mov' : ''),
      _ => a.locator,
    };
    final probe = a.probe.copyWith(
      rotation: chance(0.2) ? pick(const [90, 180, 270]) : null,
      nominalFrameRate: a.probe.hasVideo && chance(0.7) ? pick(const [FrameRate.fps30, FrameRate.fps24, FrameRate(30000, 1001)]) : null,
      nominalFps: a.probe.hasVideo && chance(0.5) ? any(23, 61) : null,
      variableFrameRate: chance(0.1),
      container: chance(0.6) ? pick(const ['mp4', 'mov', 'mkv']) : null,
      videoCodec: a.probe.hasVideo && chance(0.6) ? pick(const ['h264', 'hevc']) : null,
      audioCodec: a.probe.hasAudio && chance(0.6) ? 'aac' : null,
      channels: a.probe.hasAudio && chance(0.6) ? pick(const [1, 2, 6]) : null,
      sampleRate: a.probe.hasAudio && chance(0.6) ? pick(const [44100, 48000]) : null,
      bitDepth: a.probe.hasVideo && chance(0.3) ? pick(const [8, 10]) : null,
      transfer: chance(0.2) ? pick(ColorTransfer.values) : null,
      sizeBytes: chance(0.7) ? a.fingerprint.sizeBytes : null,
      editable: chance(0.9),
      issues: chance(0.1) ? const ['container_unsupported_ios', 'protected'] : null,
    );
    final reversible = pool.assets.values.where((x) => x.kind == MediaKind.video).toList();
    return a.copyWith(
      displayName: chance(0.5) ? '${word()}.${pick(const ['mov', 'mp4', 'm4a', 'png'])}' : null,
      locator: locator,
      ownership: pick(MediaOwnership.values),
      origin: pick(MediaOrigin.values),
      fingerprint: a.fingerprint.copyWith(modifiedMs: chance(0.6) ? big(42) : null),
      probe: probe,
      derived: a.derived ??
          (a.kind == MediaKind.video && reversible.isNotEmpty && chance(0.15)
              ? ReversedSpec(pick(reversible).id, TimeRange(1000, 1000 + r.nextInt(1 << 26)), sourceQuickHash: qh())
              : null),
      status: switch (r.nextInt(6)) {
        0 => const PendingStatus('job_reverse_1'),
        1 => const FailedStatus('decoderUnavailable'),
        _ => a.status,
      },
      proxy: pick(ProxyState.values),
      addedAt: _t0.subtract(Duration(milliseconds: r.nextInt(1 << 30))),
    );
  }
}

/// An empty project: every field at its default.
EditProject minimalProject() => EditProject(
      id: const ProjectId('pr_minimal00000'),
      meta: ProjectMeta(name: 'Untitled', createdAt: _t0, updatedAt: _t0),
      timeline: Timeline(),
    );

/// A small hand-built project with a non-default value in every field of the body schema.
EditProject kitchenSinkProject() {
  const v1 = MediaId('md_video000001');
  const v2 = MediaId('md_video000002');
  const img = MediaId('md_image000001');
  const still = MediaId('md_still000001');
  const rev = MediaId('md_revrs000001');
  const aud = MediaId('md_audio000001');
  const rec = MediaId('md_recrd000001');
  const lut = MediaId('md_lut00000001');
  const link = LinkId('ln_link00000001');
  final added = DateTime.utc(2026, 10, 1, 8, 30, 15, 250);
  final rate = FrameRate.fps24;

  MediaProbe videoProbe(int w, int h) => MediaProbe(
        kind: MediaKind.video,
        duration: 61061000,
        hasVideo: true,
        hasAudio: true,
        width: w,
        height: h,
        rotation: 90,
        nominalFrameRate: const FrameRate(30000, 1001),
        nominalFps: 29.97,
        variableFrameRate: true,
        container: 'mov',
        videoCodec: 'hevc',
        audioCodec: 'aac',
        audioStreams: 2,
        channels: 2,
        sampleRate: 48000,
        bitDepth: 10,
        transfer: ColorTransfer.hlg,
        sizeBytes: 104857600,
        editable: false,
        issues: const ['vfr'],
      );

  final assets = <MediaAsset>[
    MediaAsset(
      id: v1,
      kind: MediaKind.video,
      displayName: 'Beach day.mov',
      locator: const AppRelativeLocator(AppRoot.support, 'danaview/editor/media/ab/abcdef/Beach day.mov'),
      ownership: MediaOwnership.managedCopy,
      fingerprint: const MediaFingerprint(sizeBytes: 104857600, quickHash: 'abcdef0123456789abcdef0123456789abcdef01', modifiedMs: 1790000000000, duration: 61061000),
      probe: videoProbe(1080, 1920),
      origin: MediaOrigin.photos,
      proxy: ProxyState.ready,
      addedAt: added,
    ),
    MediaAsset(
      id: v2,
      kind: MediaKind.video,
      displayName: 'Interview.mp4',
      locator: const BookmarkLocator('Ym9va21hcms=', lastKnownPath: '/private/var/mobile/Library/Mobile Documents/Interview.mp4'),
      ownership: MediaOwnership.external,
      fingerprint: const MediaFingerprint(sizeBytes: 2048, quickHash: '1111111111111111111111111111111111111111'),
      probe: videoProbe(1920, 1080),
      origin: MediaOrigin.files,
      addedAt: added,
    ),
    MediaAsset(
      id: img,
      kind: MediaKind.image,
      displayName: 'Logo.png',
      locator: const ContentUriLocator('content://com.android.providers.media.documents/document/image%3A42'),
      ownership: MediaOwnership.external,
      fingerprint: const MediaFingerprint(sizeBytes: 4096, quickHash: '2222222222222222222222222222222222222222'),
      probe: MediaProbe(kind: MediaKind.image, hasVideo: true, width: 512, height: 512),
      origin: MediaOrigin.library,
      addedAt: added,
    ),
    MediaAsset(
      id: still,
      kind: MediaKind.still,
      displayName: 'Freeze frame',
      locator: const AppRelativeLocator(AppRoot.support, 'danaview/editor/projects/pr_kitchen/assets/stills/md_still000001.png'),
      ownership: MediaOwnership.projectOwned,
      fingerprint: const MediaFingerprint(sizeBytes: 0, quickHash: ''),
      probe: MediaProbe(kind: MediaKind.still, hasVideo: true, width: 1080, height: 1920),
      origin: MediaOrigin.derived,
      derived: const StillSpec(v1, 1001000, sourceQuickHash: 'abcdef0123456789abcdef0123456789abcdef01'),
      status: const PendingStatus('job_still_7'),
      addedAt: added,
    ),
    MediaAsset(
      id: rev,
      kind: MediaKind.video,
      displayName: 'Beach day (reversed)',
      locator: const FileLocator('/Volumes/External/derived/rev.mp4'),
      ownership: MediaOwnership.projectOwned,
      fingerprint: const MediaFingerprint(sizeBytes: 1, quickHash: '3333333333333333333333333333333333333333'),
      probe: MediaProbe(kind: MediaKind.video, duration: 5005000, hasVideo: true, width: 1080, height: 1920),
      origin: MediaOrigin.derived,
      derived: const ReversedSpec(v1, TimeRange(1001000, 6006000), sourceQuickHash: 'abcdef0123456789abcdef0123456789abcdef01'),
      status: const FailedStatus('decoderUnavailable'),
      proxy: ProxyState.failed,
      addedAt: added,
    ),
    MediaAsset(
      id: aud,
      kind: MediaKind.audio,
      displayName: 'Song.m4a',
      locator: const AppRelativeLocator(AppRoot.documents, 'Music/Song.m4a'),
      ownership: MediaOwnership.external,
      fingerprint: const MediaFingerprint(sizeBytes: 3000000, quickHash: '4444444444444444444444444444444444444444', duration: 180000000),
      probe: MediaProbe(kind: MediaKind.audio, duration: 180000000, hasAudio: true, audioStreams: 1, channels: 2, sampleRate: 44100, transfer: ColorTransfer.pq),
      origin: MediaOrigin.player,
      proxy: ProxyState.pending,
      addedAt: added,
    ),
    MediaAsset(
      id: rec,
      kind: MediaKind.recording,
      displayName: 'Voice 1',
      locator: const AppRelativeLocator(AppRoot.cache, 'danaview/editor/work/rec.wav'),
      ownership: MediaOwnership.projectOwned,
      fingerprint: const MediaFingerprint(sizeBytes: 96000, quickHash: '5555555555555555555555555555555555555555', duration: 1000000),
      probe: MediaProbe(kind: MediaKind.recording, duration: 1000000, hasAudio: true, audioStreams: 1),
      origin: MediaOrigin.recorded,
      addedAt: added,
    ),
    MediaAsset(
      id: lut,
      kind: MediaKind.lut,
      displayName: 'Film.cube',
      locator: const AppRelativeLocator(AppRoot.support, 'danaview/editor/projects/pr_kitchen/assets/luts/md_lut00000001.cube'),
      ownership: MediaOwnership.projectOwned,
      fingerprint: const MediaFingerprint(sizeBytes: 700000, quickHash: '6666666666666666666666666666666666666666'),
      probe: MediaProbe(kind: MediaKind.lut),
      origin: MediaOrigin.imported,
      addedAt: added,
    ),
  ];

  TimeUs f(int k) => rate.timeOfFrame(k);

  final mainClip = MediaClip(
    id: const ItemId('it_clip00000001'),
    start: 0,
    duration: f(48),
    media: v1,
    sourceIn: 1001000,
    speed: const ConstantSpeed(1.5),
    maintainPitch: false,
    reversed: true,
    audioStream: 1,
    visual: VisualProps(
      transform: const Transform2D(position: Vec2(0.1, -0.25), scale: 1.2, rotationDeg: -12.5, flipH: true, flipV: true, opacity: 0.8),
      fit: FitMode.fill,
      crop: const CropRect(left: 0.1, top: 0.05, right: 0.9, bottom: 0.95),
      adjust: const ColorAdjust(
        exposure: 0.12,
        brightness: -0.1,
        contrast: 0.3,
        highlights: -0.4,
        shadows: 0.25,
        saturation: -1,
        temperature: 0.5,
        tint: -0.05,
      ),
      detail: const DetailFx(sharpness: 0.2, blur: 0.1, vignette: 0.6),
      look: const BuiltinLook('tealOrange', intensity: 0.8),
      chroma: const ChromaKey(enabled: true, color: 0x0047BB, similarity: 0.35, smoothness: 0.2, spill: 0.5),
      mask: const MaskSpec(
        shape: MaskShape.ellipse,
        center: Vec2(0.4, 0.6),
        size: Vec2(0.5, 0.7),
        rotationDeg: 30,
        cornerRadius: 0.1,
        feather: 0.25,
        opacity: 0.9,
        invert: true,
      ),
    ),
    audio: AudioProps(volume: 0.8, muted: true, fadeIn: f(6), fadeOut: f(12)),
    detachedAudio: true,
    keyframes: KeyframeSet({
      'transform.scale': KeyframeTrack([Keyframe(0, 1), Keyframe(f(24), 1.4)]),
      'adjust.exposure': KeyframeTrack([Keyframe(-f(2), -0.5), Keyframe(f(10), 0.25)]),
    }),
    link: link,
    label: 'Hero shot',
  );
  final rampClip = MediaClip(
    id: const ItemId('it_clip00000002'),
    start: f(48),
    duration: f(24),
    media: v2,
    speed: SpeedRamp(const [SpeedPoint(0, 1), SpeedPoint(0.5, 0.25), SpeedPoint(1, 2)], presetId: 'montage'),
    visual: const VisualProps(look: ImportedLut(lut, intensity: 0.5)),
  );
  final imageClip = MediaClip(
    id: const ItemId('it_clip00000003'),
    start: f(72),
    duration: f(24),
    media: img,
    visual: VisualProps.neutral,
  );
  final overlayClip = MediaClip(
    id: const ItemId('it_clip00000004'),
    start: f(12),
    duration: f(24),
    media: still,
    visual: const VisualProps(transform: Transform2D(scale: 0.4)),
  );
  final partner = MediaClip(
    id: const ItemId('it_clip00000005'),
    start: 0,
    duration: f(48),
    media: v1,
    sourceIn: 1001000,
    speed: const ConstantSpeed(1.5),
    link: link,
  );
  final music = MediaClip(id: const ItemId('it_clip00000006'), start: 0, duration: f(96), media: aud, audio: const AudioProps(volume: 1.75));
  final voice = MediaClip(id: const ItemId('it_clip00000007'), start: f(24), duration: f(24), media: rec);
  final title = TextItem(
    id: const ItemId('it_text00000001'),
    start: f(6),
    duration: f(42),
    text: 'Summer trip 🌴\n"quoted" \\ line',
    style: const TextStyleSpec(
      fontFamily: 'lora',
      fontSizePt: 72.5,
      bold: true,
      italic: true,
      align: TextAlignH.left,
      color: 0x80FF8800,
      letterSpacing: -5,
      lineHeight: 1.5,
      maxWidth: 0.75,
      background: BoxStyle(color: 0xFF112233, opacity: 0.4, paddingPt: 6, cornerRadiusPt: 0),
      stroke: StrokeStyle(color: 0xFFFFFFFF, widthPt: 3.5),
      shadow: ShadowStyle(color: 0xFF000080, opacity: 0.7, blurPt: 10, distancePt: 4, angleDeg: 45),
    ),
    animation: TextAnimation(
      inKind: TextAnimKind.slide,
      inDirection: TextSlideDirection.left,
      inDuration: f(6),
      outKind: TextAnimKind.fade,
      outDirection: TextSlideDirection.right,
      outDuration: f(3),
    ),
    transform: const Transform2D(position: Vec2(0, 0.3), rotationDeg: 5),
    keyframes: KeyframeSet({
      'transform.position.x': KeyframeTrack([Keyframe(0, -0.5), Keyframe(f(12), 0)]),
      'transform.position.y': KeyframeTrack([Keyframe(0, 0.3), Keyframe(f(12), 0.3)]),
    }),
    label: 'Title',
  );
  final plainText = TextItem(
    id: const ItemId('it_text00000002'),
    start: f(60),
    duration: f(12),
    text: 'Plain',
    style: const TextStyleSpec(background: BoxStyle()),
    animation: TextAnimation(inKind: TextAnimKind.typewriter, inDuration: f(6)),
  );
  final cues = [
    SubtitleCue(id: const ItemId('it_cue000000001'), start: 0, duration: f(24), text: '<i>Hello</i> there', origin: CueOrigin.generated, editedAfterGeneration: true),
    SubtitleCue(id: const ItemId('it_cue000000002'), start: f(24), duration: f(24), text: 'Two\nlines', origin: CueOrigin.imported),
    SubtitleCue(id: const ItemId('it_cue000000003'), start: f(48), duration: f(12), text: 'Manual'),
  ];

  final tracks = <Track>[
    Track(
      id: const TrackId('tr_main00000001'),
      kind: TrackKind.video,
      name: 'Main',
      isMain: true,
      locked: true,
      hidden: true,
      muted: true,
      solo: true,
      items: [mainClip, rampClip, imageClip],
      transitions: const [
        Transition(id: TransitionId('tx_tran00000001'), left: ItemId('it_clip00000001'), right: ItemId('it_clip00000002'), kind: TransitionKind.slide, durationFrames: 8, direction: TransitionDirection.up),
        Transition(id: TransitionId('tx_tran00000002'), left: ItemId('it_clip00000002'), right: ItemId('it_clip00000003'), kind: TransitionKind.dipToWhite, durationFrames: 5),
      ],
      changedAt: 41,
    ),
    Track(id: const TrackId('tr_over00000001'), kind: TrackKind.overlay, items: [overlayClip], changedAt: 7),
    Track(id: const TrackId('tr_text00000001'), kind: TrackKind.text, items: [title, plainText]),
    Track(
      id: const TrackId('tr_subs00000001'),
      kind: TrackKind.subtitle,
      name: 'Captions (English)',
      subtitle: SubtitleTrackData(
        language: 'en',
        style: const SubtitleStyle(
          fontFamily: 'inter',
          fontSizePt: 36,
          bold: true,
          italic: true,
          color: 0xFFFFEE00,
          background: null,
          outline: StrokeStyle(widthPt: 1.5),
          shadow: ShadowStyle(),
          maxLines: 3,
          maxWidth: 0.8,
          align: TextAlignH.right,
        ),
        position: const CustomSubtitlePosition(0.85),
        burnIn: false,
        provenance: CaptionProvenance(
          generator: 'whisper.cpp',
          engineVersion: '1.9.4',
          modelId: 'whisper-base-q5_1',
          modelSha256: 'b'.padRight(64, '0'),
          language: 'en',
          languageDetected: true,
          languageConfidence: 0.93,
          segmentation: const SegmentationSettings(preset: SegmentationPreset.shortPhrases, maxLines: 1, maxCharsPerLine: 32, maxCharsPerSecond: 17.5),
          scope: CaptionScopeData(clips: const [ItemId('it_clip00000001')], tracks: const [TrackId('tr_main00000001')], range: TimeRange(0, f(48))),
          transcriptKeys: const ['tk_1', 'tk_2'],
          generatedAt: DateTime.utc(2026, 10, 2, 9),
        ),
      ),
      items: cues,
    ),
    Track(id: const TrackId('tr_subs00000002'), kind: TrackKind.subtitle, subtitle: const SubtitleTrackData(position: SubtitlePosition.top)),
    Track(id: const TrackId('tr_orig00000001'), kind: TrackKind.audio, audioRole: AudioRole.original, items: [partner]),
    Track(id: const TrackId('tr_musc00000001'), kind: TrackKind.audio, audioRole: AudioRole.music, items: [music]),
    Track(id: const TrackId('tr_voic00000001'), kind: TrackKind.audio, audioRole: AudioRole.voice, items: [voice]),
  ];

  return EditProject(
    id: const ProjectId('pr_kitchen00001'),
    meta: ProjectMeta(
      name: 'Kitchen sink',
      createdAt: DateTime.utc(2026, 10, 1, 8),
      updatedAt: DateTime.utc(2026, 10, 9, 17, 45, 0, 123, 456),
      origin: const FromPlayerOrigin(quickHash: 'abcdef0123456789abcdef0123456789abcdef01', sizeBytes: 104857600, displayName: 'Beach day.mov'),
      editCount: 57,
    ),
    timeline: Timeline(
      settings: ProjectSettings(
        canvas: const CanvasSpec(aspect: AspectRatio.portrait9x16, baseShortSide: 720),
        frameRate: rate,
        background: const BlurOfMainBackground(0.65),
        audioSampleRate: 44100,
      ),
      tracks: tracks,
      markers: [
        Marker(id: const MarkerId('mk_mark00000001'), time: f(12), name: 'Beat', colorIndex: 3, note: 'Cut here'),
        Marker(id: const MarkerId('mk_mark00000002'), time: f(36)),
      ],
      revision: 812,
    ),
    pool: MediaPool({for (final a in assets) a.id: a}),
    view: ViewState(
      playhead: f(30),
      pixelsPerSecond: 87.5,
      scrollTimeUs: 2000000,
      scrollLanePx: 12.25,
      rippleEnabled: false,
      snappingEnabled: false,
      followMode: PlayheadFollowMode.free,
      lastExportPresetId: 'shorts1080',
    ),
    docRevision: 9001,
  );
}
