// OWNER: CORE-03
//
// Every model type is immutable and has value equality, hashCode and copyWith (CORE-03 AC).
// Each case lists an instance, an equal clone, and one variant per field built through copyWith.

import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';

import 'model_fixtures.dart';

/// [a] and [aClone] are equal but not identical; every entry of [variants] differs from [a].
class _Case<T extends Object> {
  _Case(this.name, this.a, this.aClone, this.variants, {this.identityCopy});

  final String name;
  final T a;
  final T aClone;
  final List<T> variants;

  /// `a.copyWith()` must equal `a`.
  final T Function()? identityCopy;

  void register() {
    test(name, () {
      expect(a, aClone, reason: '== on equal values');
      expect(a.hashCode, aClone.hashCode, reason: 'hashCode on equal values');
      for (var i = 0; i < variants.length; i++) {
        expect(a == variants[i], isFalse, reason: 'variant $i must differ');
      }
      if (identityCopy != null) expect(identityCopy!(), a, reason: 'copyWith() with no arguments');
      expect({a, aClone, ...variants}.length, variants.length + 1, reason: 'hash set distinguishes variants');
    });
  }
}

void main() {
  group('value types', () {
    _Case<Vec2>('Vec2', const Vec2(1, 2), Vec2(1.0, 2.0), [const Vec2(1, 3), const Vec2(0, 2), const Vec2(1, 2).copyWith(x: 5), const Vec2(1, 2).copyWith(y: 9)],
        identityCopy: () => const Vec2(1, 2).copyWith()).register();

    final tf = Transform2D(position: const Vec2(0.1, 0.2), scale: 2, rotationDeg: 10, flipH: true, opacity: 0.5);
    _Case<Transform2D>('Transform2D', tf, tf.copyWith(), [
      tf.copyWith(position: Vec2.zero),
      tf.copyWith(scale: 3),
      tf.copyWith(rotationDeg: 11),
      tf.copyWith(flipH: false),
      tf.copyWith(flipV: true),
      tf.copyWith(opacity: 0.4),
    ], identityCopy: tf.copyWith).register();

    const crop = CropRect(left: 0.1, top: 0.1, right: 0.9, bottom: 0.9);
    _Case<CropRect>('CropRect', crop, crop.copyWith(), [
      crop.copyWith(left: 0.2),
      crop.copyWith(top: 0.2),
      crop.copyWith(right: 0.8),
      crop.copyWith(bottom: 0.8),
    ], identityCopy: crop.copyWith).register();

    const adj = ColorAdjust(exposure: 0.1, brightness: 0.2, contrast: 0.3, highlights: 0.4, shadows: 0.5, saturation: 0.6, temperature: 0.7, tint: 0.8);
    _Case<ColorAdjust>('ColorAdjust', adj, adj.copyWith(), [
      adj.copyWith(exposure: 0),
      adj.copyWith(brightness: 0),
      adj.copyWith(contrast: 0),
      adj.copyWith(highlights: 0),
      adj.copyWith(shadows: 0),
      adj.copyWith(saturation: 0),
      adj.copyWith(temperature: 0),
      adj.copyWith(tint: 0),
    ], identityCopy: adj.copyWith).register();

    const detail = DetailFx(sharpness: 0.1, blur: 0.2, vignette: 0.3);
    _Case<DetailFx>('DetailFx', detail, detail.copyWith(), [
      detail.copyWith(sharpness: 0),
      detail.copyWith(blur: 0),
      detail.copyWith(vignette: 0),
    ], identityCopy: detail.copyWith).register();

    const look = BuiltinLook('tealOrange', intensity: 0.5);
    _Case<LookRef>('BuiltinLook', look, const BuiltinLook('tealOrange', intensity: 0.5), [
      look.copyWith(presetId: 'x'),
      look.copyWith(intensity: 1),
      const ImportedLut(MediaId('md_l'), intensity: 0.5),
    ]).register();
    _Case<LookRef>('ImportedLut', const ImportedLut(MediaId('md_l'), intensity: 0.5), const ImportedLut(MediaId('md_l'), intensity: 0.5), [
      const ImportedLut(MediaId('md_l')).copyWith(lut: const MediaId('md_m')),
      const ImportedLut(MediaId('md_l'), intensity: 0.5).copyWith(intensity: 0.4),
    ]).register();

    const chroma = ChromaKey(enabled: true, color: 0x112233, similarity: 0.5, smoothness: 0.2, spill: 0.4);
    _Case<ChromaKey>('ChromaKey', chroma, chroma.copyWith(), [
      chroma.copyWith(enabled: false),
      chroma.copyWith(color: 0x000000),
      chroma.copyWith(similarity: 0.1),
      chroma.copyWith(smoothness: 0.1),
      chroma.copyWith(spill: 0.1),
    ], identityCopy: chroma.copyWith).register();

    const mask = MaskSpec(shape: MaskShape.ellipse, rotationDeg: 5, cornerRadius: 0.1, feather: 0.2, opacity: 0.9, invert: true);
    _Case<MaskSpec>('MaskSpec', mask, mask.copyWith(), [
      mask.copyWith(shape: MaskShape.rectangle),
      mask.copyWith(center: Vec2.zero),
      mask.copyWith(size: Vec2.zero),
      mask.copyWith(rotationDeg: 6),
      mask.copyWith(cornerRadius: 0.2),
      mask.copyWith(feather: 0.3),
      mask.copyWith(opacity: 0.8),
      mask.copyWith(invert: false),
    ], identityCopy: mask.copyWith).register();

    final vp = VisualProps(transform: tf, crop: crop, adjust: adj, detail: detail, look: look, chroma: chroma, mask: mask, fit: FitMode.fill);
    _Case<VisualProps>('VisualProps', vp, vp.copyWith(), [
      vp.copyWith(transform: Transform2D.identity),
      vp.copyWith(fit: FitMode.fit),
      vp.copyWith(crop: CropRect.full),
      vp.copyWith(adjust: ColorAdjust.neutral),
      vp.copyWith(detail: DetailFx.none),
      vp.copyWith(look: null),
      vp.copyWith(chroma: ChromaKey.off),
      vp.copyWith(mask: MaskSpec.none),
    ], identityCopy: vp.copyWith).register();

    const audio = AudioProps(volume: 1.5, muted: true, fadeIn: 100, fadeOut: 200);
    _Case<AudioProps>('AudioProps', audio, audio.copyWith(), [
      audio.copyWith(volume: 1),
      audio.copyWith(muted: false),
      audio.copyWith(fadeIn: 0),
      audio.copyWith(fadeOut: 0),
    ], identityCopy: audio.copyWith).register();

    const box = BoxStyle(color: 0xFF112233, opacity: 0.3, paddingPt: 4, cornerRadiusPt: 2);
    _Case<BoxStyle>('BoxStyle', box, box.copyWith(), [
      box.copyWith(color: 1),
      box.copyWith(opacity: 1),
      box.copyWith(paddingPt: 1),
      box.copyWith(cornerRadiusPt: 1),
    ], identityCopy: box.copyWith).register();
    const stroke = StrokeStyle(color: 5, widthPt: 3);
    _Case<StrokeStyle>('StrokeStyle', stroke, stroke.copyWith(), [stroke.copyWith(color: 6), stroke.copyWith(widthPt: 4)],
        identityCopy: stroke.copyWith).register();
    const shadow = ShadowStyle(color: 1, opacity: 0.2, blurPt: 3, distancePt: 4, angleDeg: 45);
    _Case<ShadowStyle>('ShadowStyle', shadow, shadow.copyWith(), [
      shadow.copyWith(color: 2),
      shadow.copyWith(opacity: 1),
      shadow.copyWith(blurPt: 1),
      shadow.copyWith(distancePt: 1),
      shadow.copyWith(angleDeg: 0),
    ], identityCopy: shadow.copyWith).register();

    const ts = TextStyleSpec(fontFamily: 'abc', fontSizePt: 30, bold: true, italic: true, align: TextAlignH.left, color: 0xFF000000, letterSpacing: 5, lineHeight: 1.5, maxWidth: 0.5, background: box, stroke: stroke, shadow: shadow);
    _Case<TextStyleSpec>('TextStyleSpec', ts, ts.copyWith(), [
      ts.copyWith(fontFamily: 'x'),
      ts.copyWith(fontSizePt: 31),
      ts.copyWith(bold: false),
      ts.copyWith(italic: false),
      ts.copyWith(align: TextAlignH.right),
      ts.copyWith(color: 0),
      ts.copyWith(letterSpacing: 6),
      ts.copyWith(lineHeight: 1.6),
      ts.copyWith(maxWidth: 0.6),
      ts.copyWith(background: null),
      ts.copyWith(stroke: null),
      ts.copyWith(shadow: null),
    ], identityCopy: ts.copyWith).register();

    const anim = TextAnimation(inKind: TextAnimKind.slide, inDirection: TextSlideDirection.left, inDuration: 100, outKind: TextAnimKind.fade, outDirection: TextSlideDirection.up, outDuration: 200);
    _Case<TextAnimation>('TextAnimation', anim, anim.copyWith(), [
      anim.copyWith(inKind: TextAnimKind.fade),
      anim.copyWith(inDirection: TextSlideDirection.right),
      anim.copyWith(inDuration: 1),
      anim.copyWith(outKind: TextAnimKind.scale),
      anim.copyWith(outDirection: TextSlideDirection.down),
      anim.copyWith(outDuration: 1),
    ], identityCopy: anim.copyWith).register();

    const ss = SubtitleStyle(fontFamily: 'abc', fontSizePt: 30, bold: true, italic: true, color: 1, background: box, outline: stroke, shadow: shadow, maxLines: 3, maxWidth: 0.5, align: TextAlignH.right);
    _Case<SubtitleStyle>('SubtitleStyle', ss, ss.copyWith(), [
      ss.copyWith(fontFamily: 'x'),
      ss.copyWith(fontSizePt: 1),
      ss.copyWith(bold: false),
      ss.copyWith(italic: false),
      ss.copyWith(color: 2),
      ss.copyWith(background: null),
      ss.copyWith(outline: null),
      ss.copyWith(shadow: null),
      ss.copyWith(maxLines: 1),
      ss.copyWith(maxWidth: 0.4),
      ss.copyWith(align: TextAlignH.left),
    ], identityCopy: ss.copyWith).register();

    _Case<SubtitlePosition>('SubtitlePosition', SubtitlePosition.bottom, const BottomSubtitlePosition(), [SubtitlePosition.top, const CustomSubtitlePosition(0.5)]).register();
    _Case<SubtitlePosition>('CustomSubtitlePosition', const CustomSubtitlePosition(0.5), const CustomSubtitlePosition(0.5), [const CustomSubtitlePosition(0.5).copyWith(yFraction: 0.6), SubtitlePosition.top]).register();

    const seg = SegmentationSettings(preset: SegmentationPreset.singleLine, maxLines: 1, maxCharsPerLine: 20, maxCharsPerSecond: 17);
    _Case<SegmentationSettings>('SegmentationSettings', seg, seg.copyWith(), [
      seg.copyWith(preset: SegmentationPreset.standard),
      seg.copyWith(maxLines: 2),
      seg.copyWith(maxCharsPerLine: 21),
      seg.copyWith(maxCharsPerSecond: 18),
    ], identityCopy: seg.copyWith).register();

    final scope = CaptionScopeData(clips: [const ItemId('it_a')], tracks: [const TrackId('tr_a')], range: const TimeRange(0, 10));
    _Case<CaptionScopeData>('CaptionScopeData', scope, scope.copyWith(), [
      scope.copyWith(clips: []),
      scope.copyWith(tracks: []),
      scope.copyWith(range: null),
    ], identityCopy: scope.copyWith).register();

    final prov = CaptionProvenance(
      generator: 'whisper.cpp',
      engineVersion: '1.9.4',
      modelId: 'whisper-base-q5_1',
      modelSha256: 'abc',
      language: 'en',
      languageDetected: true,
      languageConfidence: 0.9,
      segmentation: seg,
      scope: scope,
      transcriptKeys: const ['k1'],
      generatedAt: DateTime.utc(2026),
    );
    _Case<CaptionProvenance>('CaptionProvenance', prov, prov.copyWith(), [
      prov.copyWith(generator: 'x'),
      prov.copyWith(engineVersion: 'x'),
      prov.copyWith(modelId: 'x'),
      prov.copyWith(modelSha256: 'x'),
      prov.copyWith(language: 'x'),
      prov.copyWith(languageDetected: false),
      prov.copyWith(languageConfidence: null),
      prov.copyWith(segmentation: const SegmentationSettings()),
      prov.copyWith(scope: CaptionScopeData()),
      prov.copyWith(transcriptKeys: []),
      prov.copyWith(generatedAt: DateTime.utc(2027)),
      prov.copyWith(schema: 2),
    ], identityCopy: prov.copyWith).register();

    final std = SubtitleTrackData(language: 'en', style: ss, position: const CustomSubtitlePosition(0.2), burnIn: false, provenance: prov);
    _Case<SubtitleTrackData>('SubtitleTrackData', std, std.copyWith(), [
      std.copyWith(language: null),
      std.copyWith(style: const SubtitleStyle()),
      std.copyWith(position: SubtitlePosition.top),
      std.copyWith(burnIn: true),
      std.copyWith(provenance: null),
    ], identityCopy: std.copyWith).register();

    final draft = SubtitleCueDraft(const TimeRange(0, 5), 'hi');
    _Case<SubtitleCueDraft>('SubtitleCueDraft', draft, draft.copyWith(), [draft.copyWith(range: const TimeRange(0, 6)), draft.copyWith(text: 'ho')],
        identityCopy: draft.copyWith).register();

    const tr = Transition(id: TransitionId('tx_a'), left: ItemId('it_a'), right: ItemId('it_b'), kind: TransitionKind.slide, durationFrames: 10, direction: TransitionDirection.left);
    _Case<Transition>('Transition', tr, tr.copyWith(), [
      tr.copyWith(kind: TransitionKind.wipe),
      tr.copyWith(durationFrames: 11),
      tr.copyWith(direction: TransitionDirection.right),
      const Transition(id: TransitionId('tx_b'), left: ItemId('it_a'), right: ItemId('it_b'), kind: TransitionKind.slide, durationFrames: 10, direction: TransitionDirection.left),
      const Transition(id: TransitionId('tx_a'), left: ItemId('it_c'), right: ItemId('it_b'), kind: TransitionKind.slide, durationFrames: 10, direction: TransitionDirection.left),
      const Transition(id: TransitionId('tx_a'), left: ItemId('it_a'), right: ItemId('it_c'), kind: TransitionKind.slide, durationFrames: 10, direction: TransitionDirection.left),
    ], identityCopy: tr.copyWith).register();

    const ref = TransitionRef(TrackId('tr_a'), ItemId('it_a'), ItemId('it_b'));
    _Case<TransitionRef>('TransitionRef', ref, ref.copyWith(), [
      ref.copyWith(track: const TrackId('tr_b')),
      ref.copyWith(left: const ItemId('it_c')),
      ref.copyWith(right: const ItemId('it_c')),
    ], identityCopy: ref.copyWith).register();

    const marker = Marker(id: MarkerId('mk_a'), time: 10, name: 'n', colorIndex: 1, note: 'x');
    _Case<Marker>('Marker', marker, marker.copyWith(), [
      marker.copyWith(time: 11),
      marker.copyWith(name: 'm'),
      marker.copyWith(colorIndex: 2),
      marker.copyWith(note: null),
    ], identityCopy: marker.copyWith).register();

    const cs = ConstantSpeed(2);
    _Case<SpeedSpec>('ConstantSpeed', cs, const ConstantSpeed(2), [cs.copyWith(rate: 3), SpeedRamp([const SpeedPoint(0, 1), const SpeedPoint(1, 2)])]).register();
    final ramp = SpeedRamp([const SpeedPoint(0, 1), const SpeedPoint(1, 2)], presetId: 'hero');
    _Case<SpeedSpec>('SpeedRamp', ramp, SpeedRamp([const SpeedPoint(0, 1), const SpeedPoint(1, 2)], presetId: 'hero'), [
      ramp.copyWith(presetId: null),
      ramp.copyWith(points: [const SpeedPoint(0, 1), const SpeedPoint(1, 3)]),
      ramp.copyWith(presetId: 'bullet'),
    ], identityCopy: ramp.copyWith).register();
    const sp = SpeedPoint(0.5, 2);
    _Case<SpeedPoint>('SpeedPoint', sp, const SpeedPoint(0.5, 2), [sp.copyWith(x: 0.6), sp.copyWith(y: 3)], identityCopy: sp.copyWith).register();

    const kf = Keyframe(100, 0.5);
    _Case<Keyframe>('Keyframe', kf, const Keyframe(100, 0.5), [kf.copyWith(t: 200), kf.copyWith(v: 1)], identityCopy: kf.copyWith).register();
    final kt = KeyframeTrack([const Keyframe(0, 0), const Keyframe(10, 1)]);
    _Case<KeyframeTrack>('KeyframeTrack', kt, KeyframeTrack([const Keyframe(0, 0), const Keyframe(10, 1)]), [kt.copyWith(keys: [const Keyframe(0, 0)])],
        identityCopy: kt.copyWith).register();
    final ks = KeyframeSet({'transform.opacity': kt});
    _Case<KeyframeSet>('KeyframeSet', ks, KeyframeSet({'transform.opacity': kt}), [KeyframeSet.empty, ks.copyWith(byChannel: {'transform.scale': kt})],
        identityCopy: ks.copyWith).register();
    const kref = KeyframeRef(ItemId('it_a'), 'transform.position', 5);
    _Case<KeyframeRef>('KeyframeRef', kref, const KeyframeRef(ItemId('it_a'), 'transform.position', 5), [
      kref.copyWith(item: const ItemId('it_b')),
      kref.copyWith(property: 'x'),
      kref.copyWith(t: 6),
    ], identityCopy: kref.copyWith).register();

    const aspect = AspectRatio(16, 9);
    _Case<AspectRatio>('AspectRatio', aspect, const AspectRatio(32, 18), [aspect.copyWith(w: 9), aspect.copyWith(h: 10)], identityCopy: aspect.copyWith).register();
    const canvas = CanvasSpec(aspect: AspectRatio.portrait9x16, baseShortSide: 720);
    _Case<CanvasSpec>('CanvasSpec', canvas, canvas.copyWith(), [canvas.copyWith(aspect: AspectRatio.square), canvas.copyWith(baseShortSide: 1080)],
        identityCopy: canvas.copyWith).register();
    _Case<BackgroundSpec>('SolidBackground', const SolidBackground(1), const SolidBackground(1), [const SolidBackground(1).copyWith(color: 2), const BlurOfMainBackground(0.5)]).register();
    _Case<BackgroundSpec>('BlurOfMainBackground', const BlurOfMainBackground(0.5), const BlurOfMainBackground(0.5), [const BlurOfMainBackground(0.5).copyWith(radius: 0.6)]).register();
    const settings = ProjectSettings(canvas: canvas, frameRate: FrameRate.fps24, background: BlurOfMainBackground(0.3), audioSampleRate: 44100);
    _Case<ProjectSettings>('ProjectSettings', settings, settings.copyWith(), [
      settings.copyWith(canvas: const CanvasSpec()),
      settings.copyWith(frameRate: FrameRate.fps60),
      settings.copyWith(background: BackgroundSpec.black),
      settings.copyWith(audioSampleRate: 48000),
    ], identityCopy: settings.copyWith).register();

    const view = ViewState(playhead: 5, pixelsPerSecond: 100, scrollTimeUs: 6, scrollLanePx: 7, rippleEnabled: false, snappingEnabled: false, followMode: PlayheadFollowMode.free, lastExportPresetId: 'p');
    _Case<ViewState>('ViewState', view, view.copyWith(), [
      view.copyWith(playhead: 6),
      view.copyWith(pixelsPerSecond: 1),
      view.copyWith(scrollTimeUs: 1),
      view.copyWith(scrollLanePx: 1),
      view.copyWith(rippleEnabled: true),
      view.copyWith(snappingEnabled: true),
      view.copyWith(followMode: PlayheadFollowMode.centreLocked),
      view.copyWith(lastExportPresetId: 'q'),
    ], identityCopy: view.copyWith).register();

    final meta = ProjectMeta(name: 'n', createdAt: t0, updatedAt: t0, origin: const FromPlayerOrigin(quickHash: 'h', sizeBytes: 1, displayName: 'd'), editCount: 3);
    _Case<ProjectMeta>('ProjectMeta', meta, meta.copyWith(), [
      meta.copyWith(name: 'm'),
      meta.copyWith(updatedAt: DateTime.utc(2030)),
      meta.copyWith(origin: ProjectOrigin.projects),
      meta.copyWith(editCount: 4),
      ProjectMeta(name: 'n', createdAt: DateTime.utc(2000), updatedAt: t0, origin: meta.origin, editCount: 3),
    ], identityCopy: meta.copyWith).register();
    const fpo = FromPlayerOrigin(quickHash: 'h', sizeBytes: 1, displayName: 'd');
    _Case<ProjectOrigin>('FromPlayerOrigin', fpo, const FromPlayerOrigin(quickHash: 'h', sizeBytes: 1, displayName: 'd'), [
      fpo.copyWith(quickHash: 'x'),
      fpo.copyWith(sizeBytes: 2),
      fpo.copyWith(displayName: 'e'),
      ProjectOrigin.projects,
    ], identityCopy: fpo.copyWith).register();
  });

  group('items', () {
    final mc = MediaClip(
      id: const ItemId('it_a'),
      start: 0,
      duration: 1000,
      link: const LinkId('ln_a'),
      label: 'L',
      media: const MediaId('md_a'),
      sourceIn: 5,
      speed: const ConstantSpeed(2),
      maintainPitch: false,
      reversed: true,
      audioStream: 1,
      visual: const VisualProps(fit: FitMode.fill),
      audio: const AudioProps(volume: 0.5),
      detachedAudio: true,
      keyframes: KeyframeSet({'transform.opacity': KeyframeTrack([const Keyframe(0, 1)])}),
    );
    _Case<TimelineItem>('MediaClip', mc, mc.copyWith(), [
      mc.copyWith(start: 1),
      mc.copyWith(duration: 1),
      mc.copyWith(link: null),
      mc.copyWith(label: null),
      mc.copyWith(media: const MediaId('md_b')),
      mc.copyWith(sourceIn: 6),
      mc.copyWith(speed: SpeedSpec.normal),
      mc.copyWith(maintainPitch: true),
      mc.copyWith(reversed: false),
      mc.copyWith(audioStream: null),
      mc.copyWith(visual: null),
      mc.copyWith(audio: AudioProps.unity),
      mc.copyWith(detachedAudio: false),
      mc.copyWith(keyframes: KeyframeSet.empty),
      mc.withId(const ItemId('it_b')),
    ], identityCopy: mc.copyWith).register();

    test('MediaClip.withId keeps everything but the id', () {
      final b = mc.withId(const ItemId('it_b'));
      expect(b.copyWith(), isNot(mc));
      expect(b.id, 'it_b');
      expect(mc.id, 'it_a');
      expect(MediaClip(id: mc.id, start: b.start, duration: b.duration, link: b.link, label: b.label, media: b.media, sourceIn: b.sourceIn, speed: b.speed, maintainPitch: b.maintainPitch, reversed: b.reversed, audioStream: b.audioStream, visual: b.visual, audio: b.audio, detachedAudio: b.detachedAudio, keyframes: b.keyframes), mc);
    });

    final ti = TextItem(
      id: const ItemId('it_t'),
      start: 0,
      duration: 100,
      link: const LinkId('ln_t'),
      label: 'L',
      text: 'hi',
      style: const TextStyleSpec(bold: true),
      animation: const TextAnimation(inKind: TextAnimKind.fade),
      transform: const Transform2D(scale: 2),
      keyframes: KeyframeSet({'transform.opacity': KeyframeTrack([const Keyframe(0, 1)])}),
    );
    _Case<TimelineItem>('TextItem', ti, ti.copyWith(), [
      ti.copyWith(start: 1),
      ti.copyWith(duration: 1),
      ti.copyWith(link: null),
      ti.copyWith(label: null),
      ti.copyWith(text: 'ho'),
      ti.copyWith(style: const TextStyleSpec()),
      ti.copyWith(animation: TextAnimation.none),
      ti.copyWith(transform: Transform2D.identity),
      ti.copyWith(keyframes: KeyframeSet.empty),
    ], identityCopy: ti.copyWith).register();

    const sc = SubtitleCue(id: ItemId('it_s'), start: 0, duration: 100, text: 'x', origin: CueOrigin.generated, editedAfterGeneration: true, link: LinkId('ln_s'), label: 'l');
    _Case<TimelineItem>('SubtitleCue', sc, sc.copyWith(), [
      sc.copyWith(start: 1),
      sc.copyWith(duration: 1),
      sc.copyWith(text: 'y'),
      sc.copyWith(origin: CueOrigin.manual),
      sc.copyWith(editedAfterGeneration: false),
      const SubtitleCue(id: ItemId('it_s'), start: 0, duration: 100, text: 'x', origin: CueOrigin.generated, editedAfterGeneration: true),
    ], identityCopy: sc.copyWith).register();

    test('sealed TimelineItem switch is exhaustive and `range`/`end` derive from start+duration', () {
      String kind(TimelineItem i) => switch (i) {
            MediaClip() => 'clip',
            TextItem() => 'text',
            SubtitleCue() => 'cue',
          };
      expect([mc, ti, sc].map(kind), ['clip', 'text', 'cue']);
      expect(mc.end, 1000);
      expect(mc.range, const TimeRange(0, 1000));
    });

    test('items of different kinds never compare equal', () {
      expect(mc == ti, isFalse);
      expect(ti == sc, isFalse);
    });
  });

  group('defaults (ARCH §6)', () {
    test('Transform2D', () {
      const t = Transform2D();
      expect([t.position, t.scale, t.rotationDeg, t.flipH, t.flipV, t.opacity], [Vec2.zero, 1, 0, false, false, 1]);
      expect(Transform2D.identity, t);
    });
    test('ChromaKey', () {
      const c = ChromaKey();
      expect([c.enabled, c.color, c.similarity, c.smoothness, c.spill], [false, 0x00B140, 0.4, 0.1, 0.3]);
    });
    test('AudioProps and TextStyleSpec', () {
      const a = AudioProps();
      expect([a.volume, a.muted, a.fadeIn, a.fadeOut], [1.0, false, 0, 0]);
      const s = TextStyleSpec();
      expect([s.fontFamily, s.fontSizePt, s.maxWidth, s.lineHeight, s.letterSpacing], ['figtree', 48.0, 0.9, 1.2, 0.0]);
    });
    test('MediaClip', () {
      final c = clip('it_a', 0, 10);
      expect([c.sourceIn, c.speed, c.maintainPitch, c.reversed, c.audioStream, c.visual, c.audio, c.detachedAudio, c.keyframes],
          [0, SpeedSpec.normal, true, false, null, null, AudioProps.unity, false, KeyframeSet.empty]);
    });
    test('ProjectSettings (16:9 1080p, 30 fps, black, 48 kHz) and ViewState', () {
      const s = ProjectSettings();
      expect(s.canvas, const CanvasSpec());
      expect([s.canvas.widthPx, s.canvas.heightPx], [1920, 1080]);
      expect(s.frameRate, FrameRate.fps30);
      expect(s.background, BackgroundSpec.black);
      expect(s.audioSampleRate, 48000);
      expect(ViewState.initial.rippleEnabled, isTrue);
      expect(ViewState.initial.snappingEnabled, isTrue);
    });
    test('MaskSpec, ColorAdjust, DetailFx neutral', () {
      expect(MaskSpec.none.shape, MaskShape.none);
      expect(ColorAdjust.neutral.isNeutral, isTrue);
      expect(const ColorAdjust(tint: 0.1).isNeutral, isFalse);
      expect(CropRect.full.isFull, isTrue);
      expect(const CropRect(left: 0.1).isFull, isFalse);
    });
    test('SubtitleTrackData defaults to bottom, burn-in on, 2 lines', () {
      const d = SubtitleTrackData();
      expect(d.position, SubtitlePosition.bottom);
      expect(d.burnIn, isTrue);
      expect(d.style.maxLines, 2);
    });
  });

  group('canvas pixels (even, aspect + base short side)', () {
    test('standard ratios', () {
      Map<String, List<int>> sizes(int short) => {
            for (final a in AspectRatio.standard) a.toString(): [CanvasSpec(aspect: a, baseShortSide: short).widthPx, CanvasSpec(aspect: a, baseShortSide: short).heightPx],
          };
      expect(sizes(1080), {
        '16:9': [1920, 1080],
        '9:16': [1080, 1920],
        '1:1': [1080, 1080],
        '4:5': [1080, 1350],
        '4:3': [1440, 1080],
        '21:9': [2520, 1080],
      });
      expect(sizes(720)['16:9'], [1280, 720]);
      expect(sizes(720)['9:16'], [720, 1280]);
      expect(sizes(2160)['16:9'], [3840, 2160]);
    });

    test('every size is even', () {
      for (final short in CanvasSpec.supportedShortSides) {
        for (final a in [...AspectRatio.standard, const AspectRatio(5, 3), const AspectRatio(7, 5), const AspectRatio(3, 7)]) {
          final c = CanvasSpec(aspect: a, baseShortSide: short);
          expect(c.widthPx.isEven, isTrue, reason: '$c');
          expect(c.heightPx.isEven, isTrue, reason: '$c');
        }
      }
    });
  });

  group('immutability', () {
    test('lists handed to constructors are copied and unmodifiable', () {
      final items = <TimelineItem>[clip('it_a', 0, 3)];
      final tracks = <Track>[Track(id: const TrackId('tr_a'), kind: TrackKind.video, isMain: true, items: items)];
      final markers = <Marker>[const Marker(id: MarkerId('mk_a'), time: 0)];
      final tl = Timeline(tracks: tracks, markers: markers);
      items.clear();
      tracks.clear();
      markers.clear();
      expect(tl.tracks, hasLength(1));
      expect(tl.tracks.single.items, hasLength(1));
      expect(tl.markers, hasLength(1));
      expect(() => tl.tracks.add(tl.tracks.first), throwsUnsupportedError);
      expect(() => tl.markers.clear(), throwsUnsupportedError);
      expect(() => tl.tracks.first.items.add(clip('it_b', 3, 1)), throwsUnsupportedError);
      expect(() => tl.tracks.first.transitions.clear(), throwsUnsupportedError);
    });

    test('maps and other lists are unmodifiable too', () {
      expect(() => SpeedRamp([const SpeedPoint(0, 1), const SpeedPoint(1, 1)]).points.add(const SpeedPoint(1, 1)), throwsUnsupportedError);
      expect(() => KeyframeTrack([const Keyframe(0, 0)]).keys.clear(), throwsUnsupportedError);
      expect(() => KeyframeSet({'a': KeyframeTrack([const Keyframe(0, 0)])}).byChannel.clear(), throwsUnsupportedError);
      expect(() => CaptionScopeData(clips: [const ItemId('it_a')]).clips.clear(), throwsUnsupportedError);
    });

    test('with... operations never mutate the original', () {
      final base = clip('it_a', 0, 3);
      final moved = base.copyWith(start: 100);
      expect(base.start, 0);
      expect(moved.start, 100);
      final tl = Timeline(tracks: [track('tr_a', TrackKind.video, main: true, items: [base])]);
      final tl2 = tl.copyWith(markers: [const Marker(id: MarkerId('mk_a'), time: 0)]);
      expect(tl.markers, isEmpty);
      expect(identical(tl.tracks.single, tl2.tracks.single), isTrue, reason: 'unchanged subtrees are shared');
    });
  });
}
