// OWNER: CORE-13
//
// Tests of SetProperty, SetVisual, SetAudio, SetLook, SetChroma, SetMask, SetCrop and
// ResetTransform (BUILD_PLAN CORE-13): multi-item edits as one outcome, keyframe-aware writes at
// quantized times, every rejection, reset transform clearing keys, apply-to-all style batches.

import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:vwish_editor_core/eval.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart';

import '../framework/ops_support.dart';
import 'property_fixtures.dart';

void main() {
  group('SetProperty static writes', () {
    test('sets the static value of a property without keys and touches nothing else', () {
      final p = props();
      final out = ok(p, SetProperty([id('it_p')], PropertyKeys.scale, 2.5));
      final c = clip(out.project, 'it_p');
      expect(c.visual!.transform.scale, 2.5);
      expect(c, clip(p, 'it_p').copyWith(visual: clip(p, 'it_p').visual!.copyWith(transform: Transform2D(scale: 2.5))));
      expect(out.affected, {id('it_p')});
      expect(out.changedTracks, {const TrackId('tr_ov')});
      expect(out.noop, isFalse);
    });

    test('every registry property writes its field (round trip through read)', () {
      final p = props();
      final cases = <(PropertyKey<Object?>, Object?, String)>[
        (PropertyKeys.position, const Vec2(0.25, -0.5), 'it_p'),
        (PropertyKeys.rotation, 90.0, 'it_p'),
        (PropertyKeys.opacity, 0.5, 'it_p'),
        (PropertyKeys.flipH, true, 'it_p'),
        (PropertyKeys.flipV, true, 'it_p'),
        (PropertyKeys.fit, FitMode.fill, 'it_p'),
        (PropertyKeys.exposure, -0.5, 'it_p'),
        (PropertyKeys.brightness, 0.1, 'it_p'),
        (PropertyKeys.contrast, 0.2, 'it_p'),
        (PropertyKeys.highlights, -0.3, 'it_p'),
        (PropertyKeys.shadows, 0.3, 'it_p'),
        (PropertyKeys.saturation, -1.0, 'it_p'),
        (PropertyKeys.temperature, 0.4, 'it_p'),
        (PropertyKeys.tint, -0.4, 'it_p'),
        (PropertyKeys.sharpness, 0.6, 'it_p'),
        (PropertyKeys.blur, 0.7, 'it_p'),
        (PropertyKeys.vignette, 0.8, 'it_p'),
        (PropertyKeys.chromaEnabled, true, 'it_p'),
        (PropertyKeys.chromaColor, 0x112233, 'it_p'),
        (PropertyKeys.chromaSimilarity, 0.5, 'it_p'),
        (PropertyKeys.maskShape, MaskShape.ellipse, 'it_p'),
        (PropertyKeys.maskCenter, const Vec2(0.4, 0.6), 'it_p'),
        (PropertyKeys.maskSize, const Vec2(0.5, 0.7), 'it_p'),
        (PropertyKeys.maskFeather, 0.25, 'it_p'),
        (PropertyKeys.maskInvert, true, 'it_p'),
        (PropertyKeys.volume, 1.5, 'it_a2'),
        (PropertyKeys.muted, true, 'it_a2'),
        (PropertyKeys.fontFamily, 'inter', 'it_t2'),
        (PropertyKeys.fontSize, 64.0, 'it_t2'),
        (PropertyKeys.bold, true, 'it_t2'),
        (PropertyKeys.italic, true, 'it_t2'),
        (PropertyKeys.textAlign, TextAlignH.left, 'it_t2'),
        (PropertyKeys.textColor, 0xFF00FF00, 'it_t2'),
        (PropertyKeys.letterSpacing, 10.0, 'it_t2'),
        (PropertyKeys.lineHeight, 1.5, 'it_t2'),
        (PropertyKeys.maxWidth, 0.5, 'it_t2'),
        (PropertyKeys.backgroundEnabled, true, 'it_t2'),
        (PropertyKeys.strokeEnabled, true, 'it_t2'),
        (PropertyKeys.strokeWidth, 4.0, 'it_t2'),
        (PropertyKeys.shadowEnabled, true, 'it_t2'),
        (PropertyKeys.shadowBlur, 12.0, 'it_t2'),
      ];
      for (final (key, value, target) in cases) {
        final out = ok(p, SetProperty<Object?>([id(target)], key, value));
        expect(key.read(item(out.project, target)), value, reason: key.id);
      }
    });

    test('a multi-item edit is one outcome over every lane', () {
      final p = props();
      final cmd = SetProperty([id('it_p'), id('it_t2'), id('it_s')], PropertyKeys.opacity, 0.4);
      final out = ok(p, cmd);
      expect(out.affected, {id('it_p'), id('it_t2'), id('it_s')});
      expect(out.changedTracks, {const TrackId('tr_ov'), const TrackId('tr_txt'), const TrackId('tr_main')});
      expect(clip(out.project, 'it_p').visual!.transform.opacity, 0.4);
      expect(clip(out.project, 'it_s').visual!.transform.opacity, 0.4);
      expect(textOf(out.project, 'it_t2').transform.opacity, 0.4);
      final prev = dryRun(p, cmd, ctx());
      expect(prev.rejection, isNull);
      expect(prev.placements.keys.toSet(), {id('it_p'), id('it_t2'), id('it_s')});
    });

    test('apply-to-all batch: the volume of every audio-capable clip is one outcome', () {
      final p = props();
      final ids = [id('it_a'), id('it_a2'), id('it_v')];
      final out = ok(p, SetProperty(ids, PropertyKeys.volume, 0.5, at: f(10)));
      expect(out.affected, ids.toSet());
      // it_a and it_v are keyed (keys written at 10f), it_a2 is static.
      expect(keysOf(clip(out.project, 'it_a'), 'audio.volume'), [(0, 0.2), (10, 0.5), (30, 1.2)]);
      expect(keysOf(clip(out.project, 'it_v'), 'audio.volume'), [(0, 1.0), (10, 0.5), (60, 0.5)]);
      expect(clip(out.project, 'it_a2').audio.volume, 0.5);
    });

    test('duplicate ids are edited once', () {
      final out = ok(props(), SetProperty([id('it_p'), id('it_p')], PropertyKeys.rotation, 10.0));
      expect(out.affected, {id('it_p')});
    });

    test('writing the current value is a no-op', () {
      final out = applyCommand(props(), SetProperty([id('it_p')], PropertyKeys.scale, 1.0), ctx());
      expect(out.noop, isTrue);
    });

    test('purity: equal inputs, equal outputs', () {
      final a = applyCommand(props(), SetProperty([id('it_p')], PropertyKeys.scale, 2.0), ctx());
      final b = applyCommand(props(), SetProperty([id('it_p')], PropertyKeys.scale, 2.0), ctx());
      expect(a.project.timeline, b.project.timeline);
    });
  });

  group('SetProperty keyframe-aware writes', () {
    test('a keyed channel gets a key at the quantized time; the static value is untouched', () {
      final p = props();
      final out = ok(p, SetProperty([id('it_v')], PropertyKeys.scale, 5.0, at: f(10)));
      final c = clip(out.project, 'it_v');
      expect(keysOf(c, 'transform.scale'), [(0, 1.0), (10, 5.0), (30, 2.0), (60, 3.0)]);
      expect(c.visual!.transform.scale, 1.0, reason: 'the static value stays');
      expect(evaluate(c, PropertyKeys.scale, f(10)), 5.0);
    });

    test('an existing key at that frame is replaced', () {
      final out = ok(props(), SetProperty([id('it_v')], PropertyKeys.scale, 4.0, at: f(30)));
      expect(keysOf(clip(out.project, 'it_v'), 'transform.scale'), [(0, 1.0), (30, 4.0), (60, 3.0)]);
    });

    test('at is put on the grid (nearest frame): platform clock jitter and mid-frame times', () {
      final p = props();
      for (final at in [f(10) - 1, f(10) + 1, f(10) + 5000, f(10) - 5000, f(10) + 16000]) {
        final out = ok(p, SetProperty([id('it_v')], PropertyKeys.scale, 5.0, at: at));
        expect(keysOf(clip(out.project, 'it_v'), 'transform.scale').map((k) => k.$1), [0, 10, 30, 60],
            reason: 'at $at');
      }
      final out = ok(p, SetProperty([id('it_v')], PropertyKeys.scale, 5.0, at: f(10) + 17000));
      expect(keysOf(clip(out.project, 'it_v'), 'transform.scale').map((k) => k.$1), [0, 11, 30, 60],
          reason: 'past the half frame');
    });

    test('a Vec2 property writes both channels at the same time', () {
      final out = ok(props(), SetProperty([id('it_v')], PropertyKeys.position, const Vec2(0.5, -0.25), at: f(20)));
      final c = clip(out.project, 'it_v');
      expect(keysOf(c, 'transform.position.x'), [(0, 0.0), (20, 0.5), (60, 1.0)]);
      expect(keysOf(c, 'transform.position.y'), [(0, 0.0), (20, -0.25), (60, -1.0)]);
      expect(evaluate(c, PropertyKeys.position, f(20)), const Vec2(0.5, -0.25));
    });

    test('a Vec2 property with keys on one channel only gets keys on both', () {
      final base = props();
      final v = clip(base, 'it_v').copyWith(
          keyframes: KeyframeSet({
        'transform.position.x': track(0, [(0, 0), (60, 1)])
      }));
      final p = project([
        lane('tr_main', TrackKind.video, [v], main: true)
      ], pool: base.pool);
      final out = ok(p, SetProperty([id('it_v')], PropertyKeys.position, const Vec2(0.5, 0.5), at: f(30)));
      final c = clip(out.project, 'it_v');
      expect(keysOf(c, 'transform.position.y'), [(30, 0.5)]);
      expect(keysOf(c, 'transform.position.x').map((k) => k.$1), [0, 30, 60]);
    });

    test('items without keys get the static value in the same command', () {
      final p = props();
      final out = ok(p, SetProperty([id('it_v'), id('it_p')], PropertyKeys.scale, 2.0, at: f(10)));
      expect(keysOf(clip(out.project, 'it_v'), 'transform.scale').map((k) => k.$1), [0, 10, 30, 60]);
      expect(clip(out.project, 'it_p').visual!.transform.scale, 2.0);
      expect(clip(out.project, 'it_p').keyframes.isEmpty, isTrue);
    });

    test('text items are keyframe-aware too', () {
      final out = ok(props(), SetProperty([id('it_t')], PropertyKeys.scale, 3.0, at: f(45)));
      expect(keysOf(textOf(out.project, 'it_t'), 'transform.scale'), [(0, 1.0), (30, 2.0), (45, 3.0)]);
    });

    test('a keyed item needs a time inside it', () {
      final p = props();
      final c = SetProperty([id('it_v')], PropertyKeys.scale, 2.0);
      expect(rejection(p, c), const InvalidValue('at'));
      expect(rejection(p, SetProperty([id('it_v')], PropertyKeys.scale, 2.0, at: f(90))), NothingAtTime(f(90)),
          reason: 'the end is outside');
      expect(rejection(p, SetProperty([id('it_v')], PropertyKeys.scale, 2.0, at: f(100))), NothingAtTime(f(100)));
      expect(rejection(p, SetProperty([id('it_t')], PropertyKeys.scale, 2.0, at: f(80))), NothingAtTime(f(80)));
      expect(ok(p, SetProperty([id('it_v')], PropertyKeys.scale, 2.0, at: f(0))).rejection, isNull,
          reason: 'the start is inside');
      expect(ok(p, SetProperty([id('it_v')], PropertyKeys.scale, 2.0, at: f(89))).rejection, isNull);
    });

    test('non-keyframable properties ignore the time and set the static value', () {
      final out = ok(props(), SetProperty([id('it_v')], PropertyKeys.flipH, true, at: f(500)));
      expect(clip(out.project, 'it_v').visual!.transform.flipH, isTrue);
      expect(clip(out.project, 'it_v').keyframes, clip(props(), 'it_v').keyframes);
    });

    test('a keyframable property without keys is a static write even with a time', () {
      final out = ok(props(), SetProperty([id('it_v')], PropertyKeys.rotation, 45.0, at: f(0)));
      expect(keysOf(clip(out.project, 'it_v'), 'transform.rotation'), isEmpty);
      expect(clip(out.project, 'it_v').visual!.transform.rotationDeg, 45.0);
    });
  });

  group('SetProperty fades', () {
    test('fades are whole frames and at most half the clip', () {
      final p = props();
      var out = ok(p, SetProperty([id('it_a2')], PropertyKeys.fadeIn, sec(1)));
      expect(rate.frameIndexNearest(clip(out.project, 'it_a2').audio.fadeIn), 30);
      out = ok(p, SetProperty([id('it_a2')], PropertyKeys.fadeOut, sec(1) + 5000));
      final c = clip(out.project, 'it_a2');
      expect(c.end - c.audio.fadeOut, f(150 - 30), reason: 'nearest frame back from the end');
      out = ok(p, SetProperty([id('it_a2')], PropertyKeys.fadeIn, sec(10)));
      expect(rate.frameIndexNearest(clip(out.project, 'it_a2').audio.fadeIn), 30, reason: 'half of 60 frames');
      out = ok(out.project, SetProperty([id('it_a2')], PropertyKeys.fadeIn, 0));
      expect(clip(out.project, 'it_a2').audio.fadeIn, 0);
    });

    test('fades on video clips with audio work, on silent media and images they do not', () {
      final p = props();
      expect(ok(p, SetProperty([id('it_v')], PropertyKeys.fadeIn, sec(1))).rejection, isNull);
      expect(rejection(p, SetProperty([id('it_s')], PropertyKeys.fadeIn, sec(1))), const UnsupportedForKind('noAudio'));
      expect(
          rejection(p, SetProperty([id('it_p')], PropertyKeys.fadeOut, sec(1))), const UnsupportedForKind('noAudio'));
      expect(rejection(p, SetProperty([id('it_a2')], PropertyKeys.fadeIn, -1)), const InvalidValue('audio.fadeIn'));
    });
  });

  group('SetProperty rejections', () {
    final p = props();
    test('value ranges come from the property metadata', () {
      for (final (key, bad) in <(PropertyKey<Object?>, Object)>[
        (PropertyKeys.scale, 0.0),
        (PropertyKeys.scale, 8.5),
        (PropertyKeys.scale, double.nan),
        (PropertyKeys.scale, double.infinity),
        (PropertyKeys.opacity, 1.2),
        (PropertyKeys.opacity, -0.1),
        (PropertyKeys.rotation, 361.0),
        (PropertyKeys.rotation, -361.0),
        (PropertyKeys.position, const Vec2(2.5, 0)),
        (PropertyKeys.position, const Vec2(0, -2.5)),
        (PropertyKeys.exposure, 1.5),
        (PropertyKeys.blur, -0.2),
        (PropertyKeys.chromaSimilarity, 1.1),
        (PropertyKeys.maskSize, const Vec2(0.0, 0.5)),
        (PropertyKeys.crop, const CropRect(left: 0.6, right: 0.5)),
        (PropertyKeys.crop, const CropRect(bottom: 1.5)),
      ]) {
        expect(rejection(p, SetProperty<Object?>([id('it_p')], key, bad)), InvalidValue(key.id),
            reason: '${key.id} $bad');
      }
      expect(rejection(p, SetProperty([id('it_a2')], PropertyKeys.volume, 2.01)), const InvalidValue('audio.volume'));
      expect(rejection(p, SetProperty([id('it_a2')], PropertyKeys.volume, -0.01)), const InvalidValue('audio.volume'));
      expect(rejection(p, SetProperty([id('it_t2')], PropertyKeys.fontSize, 7.9)), const InvalidValue('text.fontSize'));
      expect(
          rejection(p, SetProperty([id('it_t2')], PropertyKeys.fontSize, 200.1)), const InvalidValue('text.fontSize'));
      expect(rejection(p, SetProperty([id('it_t2')], PropertyKeys.letterSpacing, -20.5)),
          const InvalidValue('text.letterSpacing'));
      expect(rejection(p, SetProperty([id('it_t2')], PropertyKeys.lineHeight, 3.1)),
          const InvalidValue('text.lineHeight'));
      expect(
          rejection(p, SetProperty([id('it_t2')], PropertyKeys.fontFamily, '')), const InvalidValue('text.fontFamily'));
      expect(rejection(p, SetProperty([id('it_t2')], PropertyKeys.textColor, 0x1FFFFFFFF)),
          const InvalidValue('text.color'));
      expect(rejection(p, SetProperty([id('it_p')], PropertyKeys.chromaColor, -1)), const InvalidValue('chroma.color'));
    });

    test('a value outside the range is rejected when keyed too', () {
      expect(rejection(p, SetProperty([id('it_v')], PropertyKeys.scale, 9.0, at: f(10))),
          const InvalidValue('transform.scale'));
    });

    test('properties that do not apply are UnsupportedForKind', () {
      expect(rejection(p, SetProperty([id('it_a2')], PropertyKeys.scale, 2.0)), const UnsupportedForKind('audioClip'));
      expect(rejection(p, SetProperty([id('it_c')], PropertyKeys.scale, 2.0)), const UnsupportedForKind('subtitle'));
      expect(rejection(p, SetProperty([id('it_p')], PropertyKeys.fontSize, 20.0)), const UnsupportedForKind('media'));
      expect(rejection(p, SetProperty([id('it_t2')], PropertyKeys.exposure, 0.5)), const UnsupportedForKind('text'));
      expect(rejection(p, SetProperty([id('it_t2')], PropertyKeys.flipH, true)), const UnsupportedForKind('text'));
      expect(rejection(p, SetProperty([id('it_t2')], PropertyKeys.volume, 1.0)), const UnsupportedForKind('text'));
      expect(rejection(p, SetProperty([id('it_p')], PropertyKeys.volume, 1.0)), const UnsupportedForKind('noAudio'));
      expect(rejection(p, SetProperty([id('it_s')], PropertyKeys.volume, 1.0)), const UnsupportedForKind('noAudio'));
    });

    test('the look intensity needs a look', () {
      expect(
          rejection(p, SetProperty([id('it_p')], PropertyKeys.lookIntensity, 0.5)), const UnsupportedForKind('noLook'));
      final withLook = ok(p, SetLook([id('it_p')], const BuiltinLook('warm'))).project;
      final out = ok(withLook, SetProperty([id('it_p')], PropertyKeys.lookIntensity, 0.5));
      expect(clip(out.project, 'it_p').visual!.look, const BuiltinLook('warm', intensity: 0.5));
    });

    test('a locked lane, unknown items and an empty selection', () {
      expect(rejection(p, SetProperty([id('it_l')], PropertyKeys.scale, 2.0)), const TrackLocked(TrackId('tr_ovl')));
      expect(rejection(p, SetProperty([id('it_nope')], PropertyKeys.scale, 2.0)), const ItemNotFound('it_nope'));
      expect(rejection(p, SetProperty(const <ItemId>[], PropertyKeys.scale, 2.0)), const InvalidValue('items'));
    });

    test('one bad item rejects the whole command, nothing is applied', () {
      final out = applyCommand(p, SetProperty([id('it_p'), id('it_l'), id('it_s')], PropertyKeys.scale, 2.0), ctx());
      expect(out.rejection, const TrackLocked(TrackId('tr_ovl')));
      expect(identical(out.project, p), isTrue);
      expect(rejection(p, SetProperty([id('it_p'), id('it_a2')], PropertyKeys.scale, 2.0)),
          const UnsupportedForKind('audioClip'));
    });

    test('rejections never throw and dry run agrees', () {
      final cmd = SetProperty([id('it_p')], PropertyKeys.scale, double.nan);
      expect(dryRun(p, cmd, ctx()).rejection, const InvalidValue('transform.scale'));
    });
  });

  group('whole-struct setters', () {
    final p = props();

    test('SetVisual replaces the visual props of several clips and keeps the keys', () {
      final visual = VisualProps(
          transform: Transform2D(scale: 2, rotationDeg: 30), adjust: ColorAdjust(contrast: 0.5), fit: FitMode.fill);
      final out = ok(p, SetVisual([id('it_v'), id('it_p')], visual));
      expect(clip(out.project, 'it_v').visual, visual);
      expect(clip(out.project, 'it_p').visual, visual);
      expect(clip(out.project, 'it_v').keyframes, clip(p, 'it_v').keyframes);
      expect(out.affected, {id('it_v'), id('it_p')});
    });

    test('SetVisual validates ranges, kinds, locks and the look', () {
      expect(rejection(p, SetVisual([id('it_p')], VisualProps(transform: Transform2D(scale: 100)))),
          const InvalidValue('transform.scale'));
      expect(rejection(p, SetVisual([id('it_p')], VisualProps(adjust: ColorAdjust(tint: 2)))),
          const InvalidValue('adjust.tint'));
      expect(rejection(p, SetVisual([id('it_p')], VisualProps(crop: CropRect(left: 0.9, right: 0.1)))),
          InvalidValue(PropertyKeys.crop.id));
      expect(rejection(p, SetVisual([id('it_p')], VisualProps(chroma: ChromaKey(color: -1)))),
          const InvalidValue('chroma.color'));
      expect(rejection(p, SetVisual([id('it_a2')], VisualProps.neutral)), const UnsupportedForKind('audioClip'));
      expect(rejection(p, SetVisual([id('it_t2')], VisualProps.neutral)), const UnsupportedForKind('text'));
      expect(rejection(p, SetVisual([id('it_c')], VisualProps.neutral)), const UnsupportedForKind('subtitle'));
      expect(rejection(p, SetVisual([id('it_l')], VisualProps.neutral)), const TrackLocked(TrackId('tr_ovl')));
      expect(rejection(p, SetVisual([id('it_p')], VisualProps(look: ImportedLut(const MediaId('md_missing'))))),
          const MediaUnavailable(MediaId('md_missing')));
      expect(rejection(p, SetVisual(const <ItemId>[], VisualProps.neutral)), const InvalidValue('items'));
    });

    test('SetAudio sets volume, mute and fades; fades are fitted', () {
      final out = ok(
          p,
          SetAudio(
              [id('it_a2'), id('it_v')], AudioProps(volume: 1.5, muted: true, fadeIn: sec(1) + 7, fadeOut: sec(100))));
      for (final i in ['it_a2', 'it_v']) {
        final c = clip(out.project, i);
        expect(c.audio.volume, 1.5);
        expect(c.audio.muted, isTrue);
      }
      final c = clip(out.project, 'it_a2');
      expect(rate.frameIndexNearest(c.audio.fadeIn), 30);
      expect(rate.frameIndexNearest(c.audio.fadeOut), 30, reason: 'half of 60 frames');
      expect(clip(out.project, 'it_v').keyframes, clip(p, 'it_v').keyframes);
    });

    test('SetAudio rejections', () {
      expect(rejection(p, SetAudio([id('it_a2')], AudioProps(volume: 2.5))), const InvalidValue('audio.volume'));
      expect(rejection(p, SetAudio([id('it_a2')], AudioProps(volume: double.nan))), const InvalidValue('audio.volume'));
      expect(rejection(p, SetAudio([id('it_a2')], AudioProps(fadeIn: -1))), const InvalidValue('audio.fadeIn'));
      expect(rejection(p, SetAudio([id('it_a2')], AudioProps(fadeOut: -1))), const InvalidValue('audio.fadeOut'));
      expect(rejection(p, SetAudio([id('it_t2')], AudioProps.unity)), const UnsupportedForKind('text'));
      expect(rejection(p, SetAudio([id('it_p')], AudioProps.unity)), const UnsupportedForKind('noAudio'));
      expect(rejection(p, SetAudio([id('it_s')], AudioProps.unity)), const UnsupportedForKind('noAudio'));
      expect(rejection(p, SetAudio([id('it_c')], AudioProps.unity)), const UnsupportedForKind('subtitle'));
    });

    test('SetLook: bundled, imported (with intensity) and removed', () {
      var out = ok(p, SetLook([id('it_p'), id('it_v')], const BuiltinLook('warm', intensity: 0.6)));
      expect(clip(out.project, 'it_p').visual!.look, const BuiltinLook('warm', intensity: 0.6));
      expect(clip(out.project, 'it_v').visual!.look, const BuiltinLook('warm', intensity: 0.6));
      out = ok(out.project, SetLook([id('it_p')], ImportedLut(const MediaId('md_lut'), intensity: 0.3)));
      expect(clip(out.project, 'it_p').visual!.look, ImportedLut(const MediaId('md_lut'), intensity: 0.3));
      out = ok(out.project, SetLook([id('it_p'), id('it_v')], null));
      expect(clip(out.project, 'it_p').visual!.look, isNull);
      expect(clip(out.project, 'it_v').visual!.look, isNull);
    });

    test('SetLook rejections', () {
      expect(rejection(p, SetLook([id('it_p')], const BuiltinLook('warm', intensity: 1.5))),
          const InvalidValue('look.intensity'));
      expect(rejection(p, SetLook([id('it_p')], const BuiltinLook('warm', intensity: -0.1))),
          const InvalidValue('look.intensity'));
      expect(rejection(p, SetLook([id('it_p')], const BuiltinLook(''))), const InvalidValue('look'));
      expect(rejection(p, SetLook([id('it_p')], ImportedLut(const MediaId('md_gone')))),
          const MediaUnavailable(MediaId('md_gone')));
      expect(rejection(p, SetLook([id('it_p')], ImportedLut(const MediaId('md_video')))),
          const UnsupportedForKind('notLut'));
      expect(rejection(p, SetLook([id('it_a2')], const BuiltinLook('warm'))), const UnsupportedForKind('audioClip'));
      expect(rejection(p, SetLook([id('it_l')], const BuiltinLook('warm'))), const TrackLocked(TrackId('tr_ovl')));
    });

    test('SetChroma', () {
      final chroma = ChromaKey(enabled: true, color: 0x00FF00, similarity: 0.5, smoothness: 0.2, spill: 0.1);
      final out = ok(p, SetChroma([id('it_p'), id('it_v')], chroma));
      expect(clip(out.project, 'it_p').visual!.chroma, chroma);
      expect(clip(out.project, 'it_v').visual!.chroma, chroma);
      expect(
          rejection(p, SetChroma([id('it_p')], ChromaKey(similarity: 1.5))), const InvalidValue('chroma.similarity'));
      expect(
          rejection(p, SetChroma([id('it_p')], ChromaKey(smoothness: -0.1))), const InvalidValue('chroma.smoothness'));
      expect(rejection(p, SetChroma([id('it_p')], ChromaKey(spill: 2))), const InvalidValue('chroma.spill'));
      expect(rejection(p, SetChroma([id('it_p')], ChromaKey(color: 0x1000000))), const InvalidValue('chroma.color'));
      expect(rejection(p, SetChroma([id('it_a2')], ChromaKey())), const UnsupportedForKind('audioClip'));
    });

    test('SetMask', () {
      final mask = MaskSpec(
          shape: MaskShape.ellipse,
          center: Vec2(0.4, 0.6),
          size: Vec2(0.5, 0.5),
          rotationDeg: 10,
          feather: 0.2,
          opacity: 0.8,
          invert: true);
      final out = ok(p, SetMask([id('it_p')], mask));
      expect(clip(out.project, 'it_p').visual!.mask, mask);
      expect(rejection(p, SetMask([id('it_p')], MaskSpec(shape: MaskShape.rectangle, feather: 1.5))),
          const InvalidValue('mask.feather'));
      expect(rejection(p, SetMask([id('it_p')], MaskSpec(shape: MaskShape.rectangle, center: Vec2(2, 0)))),
          const InvalidValue('mask.center'));
      expect(rejection(p, SetMask([id('it_p')], MaskSpec(shape: MaskShape.rectangle, size: Vec2(0, 0.5)))),
          const InvalidValue('mask.size'));
      expect(rejection(p, SetMask([id('it_p')], MaskSpec(shape: MaskShape.rectangle, opacity: -1))),
          const InvalidValue('mask.opacity'));
      expect(rejection(p, SetMask([id('it_t2')], mask)), const UnsupportedForKind('text'));
    });

    test('SetCrop', () {
      const crop = CropRect(left: 0.1, top: 0.2, right: 0.9, bottom: 0.8);
      final out = ok(p, SetCrop([id('it_p'), id('it_v')], crop));
      expect(clip(out.project, 'it_p').visual!.crop, crop);
      expect(clip(out.project, 'it_v').visual!.crop, crop);
      for (final bad in const [
        CropRect(left: 0.5, right: 0.5),
        CropRect(left: 0.6, right: 0.5),
        CropRect(top: 0.9, bottom: 0.1),
        CropRect(left: -0.1),
        CropRect(right: 1.1),
      ]) {
        expect(rejection(p, SetCrop([id('it_p')], bad)), InvalidValue(PropertyKeys.crop.id), reason: '$bad');
      }
      expect(rejection(p, SetCrop([id('it_a2')], crop)), const UnsupportedForKind('audioClip'));
      expect(applyCommand(p, SetCrop([id('it_p')], CropRect.full), ctx()).noop, isTrue);
    });

    test('whole-struct setters are multi-item single outcomes and dry-run clean', () {
      final cmd = SetCrop([id('it_p'), id('it_v'), id('it_s')], const CropRect(left: 0.1));
      final out = ok(p, cmd);
      expect(out.affected, {id('it_p'), id('it_v'), id('it_s')});
      expect(dryRun(p, cmd, ctx()).placements.keys.toSet(), out.affected);
    });
  });

  group('ResetTransform', () {
    test('resets the transform of visual clips and text and clears every transform key', () {
      final base = props();
      final v = clip(base, 'it_v').copyWith(
        visual: VisualProps(
          transform:
              Transform2D(position: Vec2(0.3, 0.3), scale: 2, rotationDeg: 40, flipH: true, flipV: true, opacity: 0.5),
          fit: FitMode.fill,
          crop: CropRect(left: 0.1),
          adjust: ColorAdjust(contrast: 0.3),
        ),
        keyframes: KeyframeSet({
          ...clip(base, 'it_v').keyframes.byChannel,
          'transform.rotation': track(0, [(0, 0), (30, 90)]),
          'transform.opacity': track(0, [(0, 1), (30, 0)]),
          'adjust.exposure': track(0, [(0, 0), (30, 0.5)]),
        }),
      );
      final t = textOf(base, 'it_t').copyWith(transform: Transform2D(position: Vec2(0.2, 0.2), scale: 3));
      final p = project([
        lane('tr_main', TrackKind.video, [v], main: true),
        lane('tr_txt', TrackKind.text, [t]),
      ], pool: base.pool);
      final out = ok(p, ResetTransform([id('it_v'), id('it_t')]));
      final c = clip(out.project, 'it_v');
      expect(c.visual!.transform, Transform2D.identity);
      expect(c.visual!.fit, FitMode.fill, reason: 'fit stays');
      expect(c.visual!.crop, CropRect(left: 0.1), reason: 'crop stays');
      expect(c.visual!.adjust, ColorAdjust(contrast: 0.3));
      expect(c.keyframes.byChannel.keys, unorderedEquals(['audio.volume', 'adjust.exposure']),
          reason: 'only the transform keys go');
      final tt = textOf(out.project, 'it_t');
      expect(tt.transform, Transform2D.identity);
      expect(tt.keyframes.isEmpty, isTrue);
      expect(out.affected, {id('it_v'), id('it_t')});
    });

    test('rejections and no-op', () {
      final p = props();
      expect(rejection(p, ResetTransform([id('it_a2')])), const UnsupportedForKind('audioClip'));
      expect(rejection(p, ResetTransform([id('it_c')])), const UnsupportedForKind('subtitle'));
      expect(rejection(p, ResetTransform([id('it_l')])), const TrackLocked(TrackId('tr_ovl')));
      expect(rejection(p, ResetTransform(const <ItemId>[])), const InvalidValue('items'));
      expect(applyCommand(p, ResetTransform([id('it_p')]), ctx()).noop, isTrue, reason: 'already identity, no keys');
    });
  });

  group('random property edits stay valid', () {
    test('300 seeded SetProperty commands keep every invariant', () {
      final rnd = math.Random(13);
      var p = props();
      final keys = PropertyKeys.all;
      var applied = 0;
      final items = ['it_v', 'it_s', 'it_p', 'it_t', 'it_t2', 'it_a', 'it_a2', 'it_c', 'it_l'];
      for (var n = 0; n < 300; n++) {
        final key = keys[rnd.nextInt(keys.length)];
        final target = items[rnd.nextInt(items.length)];
        final Object? value = switch (key.valueKind) {
          PropertyValueKind.number => key.min + (key.max - key.min) * rnd.nextDouble(),
          PropertyValueKind.vec2 =>
            Vec2(key.min + (key.max - key.min) * rnd.nextDouble(), key.min + (key.max - key.min) * rnd.nextDouble()),
          PropertyValueKind.toggle => rnd.nextBool(),
          PropertyValueKind.color => rnd.nextInt(0xFFFFFF),
          PropertyValueKind.duration => rnd.nextInt(sec(3)),
          PropertyValueKind.text => 'inter',
          PropertyValueKind.rect => const CropRect(left: 0.1, right: 0.9),
          PropertyValueKind.choice => key.defaultValue,
        };
        final c = SetProperty<Object?>([id(target)], key, value, at: f(rnd.nextInt(100)));
        final out = applyCommand(p, c, ctx(seed: 1000 + n));
        if (out.rejection == null) {
          applied++;
          p = out.project;
          expectValid(p, '$c');
        } else {
          expect(out.rejection, isNot(isA<InternalInconsistency>()), reason: '$c -> ${out.rejection}');
        }
      }
      expect(applied, greaterThan(50));
    });
  });
}
