// OWNER: CORE-05
//
// Table test of the PropertyKey registry (ARCH §6.7): ids, ranges, defaults, keyframable flags,
// channels, applicability and static read/write for every property.

import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';

import '../model/core/model_fixtures.dart';

/// One expected row: independent of the implementation.
class _Row {
  const _Row(this.key, this.id, this.def, this.min, this.max, this.kf, this.applies, {this.scale = 1, this.unit = '', this.vec2 = false});
  final PropertyKey<Object?> key;
  final String id;
  final Object def;
  final double min, max;
  final bool kf;
  final Set<ItemKindTag> applies;
  final double scale;
  final String unit;
  final bool vec2;
}

const _vis = {ItemKindTag.visualClip};
const _visText = {ItemKindTag.visualClip, ItemKindTag.text};
const _aud = {ItemKindTag.audioClip};
const _txt = {ItemKindTag.text};

final List<_Row> _rows = [
  _Row(PropertyKeys.position, 'transform.position', Vec2.zero, -2, 2, true, _visText, scale: 100, unit: '%', vec2: true),
  _Row(PropertyKeys.scale, 'transform.scale', 1.0, 0.01, 8, true, _visText, scale: 100, unit: '%'),
  _Row(PropertyKeys.rotation, 'transform.rotation', 0.0, -360, 360, true, _visText, unit: '°'),
  _Row(PropertyKeys.opacity, 'transform.opacity', 1.0, 0, 1, true, _visText, scale: 100, unit: '%'),
  _Row(PropertyKeys.flipH, 'transform.flipH', false, 0, 0, false, _vis),
  _Row(PropertyKeys.flipV, 'transform.flipV', false, 0, 0, false, _vis),
  _Row(PropertyKeys.fit, 'visual.fit', FitMode.fit, 0, 0, false, _vis),
  _Row(PropertyKeys.crop, 'visual.crop', CropRect.full, 0, 1, false, _vis, scale: 100),
  for (final n in ['exposure', 'brightness', 'contrast', 'highlights', 'shadows', 'saturation', 'temperature', 'tint'])
    _Row(_byName(n), 'adjust.$n', 0.0, -1, 1, true, _vis, scale: 100, unit: '%'),
  for (final n in ['sharpness', 'blur', 'vignette']) _Row(_byName(n), 'detail.$n', 0.0, 0, 1, true, _vis, scale: 100, unit: '%'),
  _Row(PropertyKeys.lookIntensity, 'look.intensity', 1.0, 0, 1, false, _vis, scale: 100, unit: '%'),
  _Row(PropertyKeys.chromaEnabled, 'chroma.enabled', false, 0, 0, false, _vis),
  _Row(PropertyKeys.chromaColor, 'chroma.color', 0x00B140, 0, 0xFFFFFF, false, _vis),
  _Row(PropertyKeys.chromaSimilarity, 'chroma.similarity', 0.4, 0, 1, false, _vis, scale: 100, unit: '%'),
  _Row(PropertyKeys.chromaSmoothness, 'chroma.smoothness', 0.1, 0, 1, false, _vis, scale: 100, unit: '%'),
  _Row(PropertyKeys.chromaSpill, 'chroma.spill', 0.3, 0, 1, false, _vis, scale: 100, unit: '%'),
  _Row(PropertyKeys.maskShape, 'mask.shape', MaskShape.none, 0, 0, false, _vis),
  _Row(PropertyKeys.maskCenter, 'mask.center', const Vec2(0.5, 0.5), -0.5, 1.5, true, _vis, scale: 100, unit: '%', vec2: true),
  _Row(PropertyKeys.maskSize, 'mask.size', const Vec2(0.6, 0.6), 0.01, 2, true, _vis, scale: 100, unit: '%', vec2: true),
  _Row(PropertyKeys.maskRotation, 'mask.rotation', 0.0, -360, 360, true, _vis, unit: '°'),
  _Row(PropertyKeys.maskCornerRadius, 'mask.cornerRadius', 0.0, 0, 0.5, false, _vis, scale: 100, unit: '%'),
  _Row(PropertyKeys.maskFeather, 'mask.feather', 0.0, 0, 1, true, _vis, scale: 100, unit: '%'),
  _Row(PropertyKeys.maskOpacity, 'mask.opacity', 1.0, 0, 1, true, _vis, scale: 100, unit: '%'),
  _Row(PropertyKeys.maskInvert, 'mask.invert', false, 0, 0, false, _vis),
  _Row(PropertyKeys.volume, 'audio.volume', 1.0, 0, 2, true, _aud, scale: 100, unit: '%'),
  _Row(PropertyKeys.muted, 'audio.muted', false, 0, 0, false, _aud),
  _Row(PropertyKeys.fadeIn, 'audio.fadeIn', 0, 0, 10e6, false, _aud, scale: 1e-6, unit: 's'),
  _Row(PropertyKeys.fadeOut, 'audio.fadeOut', 0, 0, 10e6, false, _aud, scale: 1e-6, unit: 's'),
  _Row(PropertyKeys.fontFamily, 'text.fontFamily', 'figtree', 0, 0, false, _txt),
  _Row(PropertyKeys.fontSize, 'text.fontSize', 48.0, 8, 200, false, _txt, unit: 'pt'),
  _Row(PropertyKeys.bold, 'text.bold', false, 0, 0, false, _txt),
  _Row(PropertyKeys.italic, 'text.italic', false, 0, 0, false, _txt),
  _Row(PropertyKeys.textAlign, 'text.align', TextAlignH.center, 0, 0, false, _txt),
  _Row(PropertyKeys.textColor, 'text.color', 0xFFFFFFFF, 0, 0, false, _txt),
  _Row(PropertyKeys.letterSpacing, 'text.letterSpacing', 0.0, -20, 100, false, _txt, unit: 'em/100'),
  _Row(PropertyKeys.lineHeight, 'text.lineHeight', 1.2, 0.6, 3, false, _txt),
  _Row(PropertyKeys.maxWidth, 'text.maxWidth', 0.9, 0.1, 1, false, _txt, scale: 100, unit: '%'),
  _Row(PropertyKeys.backgroundEnabled, 'text.background.enabled', false, 0, 0, false, _txt),
  _Row(PropertyKeys.backgroundColor, 'text.background.color', 0xFF000000, 0, 0, false, _txt),
  _Row(PropertyKeys.backgroundOpacity, 'text.background.opacity', 0.6, 0, 1, false, _txt, scale: 100, unit: '%'),
  _Row(PropertyKeys.backgroundPadding, 'text.background.padding', 12.0, 0, 100, false, _txt, unit: 'pt'),
  _Row(PropertyKeys.backgroundCornerRadius, 'text.background.cornerRadius', 8.0, 0, 100, false, _txt, unit: 'pt'),
  _Row(PropertyKeys.strokeEnabled, 'text.stroke.enabled', false, 0, 0, false, _txt),
  _Row(PropertyKeys.strokeColor, 'text.stroke.color', 0xFF000000, 0, 0, false, _txt),
  _Row(PropertyKeys.strokeWidth, 'text.stroke.width', 2.0, 0, 20, false, _txt, unit: 'pt'),
  _Row(PropertyKeys.shadowEnabled, 'text.shadow.enabled', false, 0, 0, false, _txt),
  _Row(PropertyKeys.shadowColor, 'text.shadow.color', 0xFF000000, 0, 0, false, _txt),
  _Row(PropertyKeys.shadowOpacity, 'text.shadow.opacity', 0.5, 0, 1, false, _txt, scale: 100, unit: '%'),
  _Row(PropertyKeys.shadowBlur, 'text.shadow.blur', 6.0, 0, 40, false, _txt, unit: 'pt'),
  _Row(PropertyKeys.shadowDistance, 'text.shadow.distance', 3.0, 0, 40, false, _txt, unit: 'pt'),
  _Row(PropertyKeys.shadowAngle, 'text.shadow.angle', 90.0, 0, 360, false, _txt, unit: '°'),
];

PropertyKey<Object?> _byName(String n) => PropertyKeys.byId.values.firstWhere((k) => k.id.endsWith('.$n') && !k.id.startsWith('text.') && !k.id.startsWith('mask.'));

MediaClip _visualClip() => clip('it_v', 0, 90, visual: VisualProps.neutral);
MediaClip _audioClip() => clip('it_a', 0, 90);
TextItem _textItem() => text('it_t', 0, 90);

/// Keys whose write materializes an optional sub-object, so writing the default back does not
/// restore the exact original item.
bool _materializes(_Row r) =>
    r.id.startsWith('text.background.') && r.id != 'text.background.enabled' ||
    r.id.startsWith('text.stroke.') && r.id != 'text.stroke.enabled' ||
    r.id.startsWith('text.shadow.') && r.id != 'text.shadow.enabled';

TimelineItem _itemFor(_Row r) {
  if (r.id == 'look.intensity') {
    return clip('it_v', 0, 90, visual: VisualProps.neutral.copyWith(look: const BuiltinLook('tealOrange')));
  }
  if (r.applies.contains(ItemKindTag.visualClip)) return _visualClip();
  if (r.applies.contains(ItemKindTag.audioClip)) return _audioClip();
  return _textItem();
}

/// A valid value different from the default, for the write/read round trip.
Object _otherValue(_Row r) {
  final d = r.def;
  return switch (d) {
    bool() => !d,
    Vec2() => Vec2(r.max * 0.5, r.min * 0.5 + 0.1),
    FitMode() => FitMode.fill,
    MaskShape() => MaskShape.ellipse,
    TextAlignH() => TextAlignH.right,
    CropRect() => const CropRect(left: 0.1, top: 0.2, right: 0.8, bottom: 0.9),
    String() => 'other',
    int() when r.key.valueKind == PropertyValueKind.color => 0x12345678 & 0xFFFFFF | 0x11000000,
    int() => (r.max / 2).round(),
    double() => r.min + (r.max - r.min) * 0.37,
    _ => throw StateError('no sample for $d'),
  };
}

void main() {
  group('registry shape', () {
    test('every row of the table is a registered key and vice versa', () {
      expect(_rows.map((r) => r.key).toSet(), PropertyKeys.all.toSet());
      expect(PropertyKeys.all.length, _rows.length);
    });

    test('ids are unique, stable and prefixed by their group', () {
      final ids = PropertyKeys.all.map((k) => k.id).toList();
      expect(ids.toSet().length, ids.length);
      expect(PropertyKeys.byId.length, ids.length);
      for (final id in ids) {
        expect(id, matches(RegExp(r'^[a-z]+(\.[A-Za-z]+)+$')));
      }
      for (final r in _rows) {
        expect(PropertyKeys.byId[r.id], same(r.key), reason: r.id);
        expect(PropertyKeys.lookup(r.id), same(r.key));
      }
      expect(PropertyKeys.lookup('nope'), isNull);
    });

    test('registry lists are unmodifiable', () {
      expect(() => PropertyKeys.all.clear(), throwsUnsupportedError);
      expect(() => PropertyKeys.byId['x'] = PropertyKeys.volume, throwsUnsupportedError);
    });

    test('keyframable set is exactly ARCH §6.7', () {
      final ids = PropertyKeys.keyframable.map((k) => k.id).toSet();
      expect(ids, {
        'transform.position',
        'transform.scale',
        'transform.rotation',
        'transform.opacity',
        'audio.volume',
        'adjust.exposure',
        'adjust.brightness',
        'adjust.contrast',
        'adjust.highlights',
        'adjust.shadows',
        'adjust.saturation',
        'adjust.temperature',
        'adjust.tint',
        'detail.sharpness',
        'detail.blur',
        'detail.vignette',
        'mask.center',
        'mask.size',
        'mask.rotation',
        'mask.feather',
        'mask.opacity',
      });
    });

    test('channel ids are unique and resolve back to their key', () {
      final all = [for (final k in PropertyKeys.keyframable) ...k.channels];
      expect(all.toSet().length, all.length);
      for (final k in PropertyKeys.keyframable) {
        for (final c in k.channels) {
          expect(PropertyKeys.byChannel[c], same(k));
        }
      }
      expect(PropertyKeys.byChannel.length, all.length);
    });
  });

  group('metadata table', () {
    for (final r in _rows) {
      group(r.id, () {
        test('id, default, range, keyframable, scale and unit', () {
          final k = r.key;
          expect(k.id, r.id);
          expect(k.defaultValue, r.def);
          expect(k.min, r.min);
          expect(k.max, r.max);
          expect(k.keyframable, r.kf);
          expect(k.appliesTo, r.applies);
          expect(k.displayScale, r.scale);
          expect(k.unit, r.unit);
          expect(k.displayName, isNotEmpty);
        });

        test('channels', () {
          final k = r.key;
          if (!r.kf) {
            expect(k.channels, isEmpty);
          } else if (r.vec2) {
            expect(k.channels, ['${r.id}.x', '${r.id}.y']);
            expect(k.valueKind, PropertyValueKind.vec2);
          } else {
            expect(k.channels, [r.id]);
          }
        });

        test('default is inside the range and the step is positive for numeric kinds', () {
          final k = r.key;
          if (k.valueKind == PropertyValueKind.number || k.valueKind == PropertyValueKind.vec2 || k.valueKind == PropertyValueKind.duration) {
            expect(k.min < k.max, isTrue);
            expect(k.step, greaterThan(0));
            expect(k.accepts(k.defaultValue), isTrue, reason: 'default ${k.defaultValue}');
          }
        });

        test('read on a fresh item returns the default', () {
          final item = r.id == 'look.intensity' ? _visualClip() : _itemFor(r);
          expect(r.key.read(item), r.def);
        });

        test('write then read round-trips and leaves the rest of the item unchanged', () {
          final item = _itemFor(r);
          final v = _otherValue(r);
          final changed = r.key.write(item, v);
          expect(r.key.read(changed), v);
          expect(changed.id, item.id);
          expect(changed.start, item.start);
          expect(changed.duration, item.duration);
          // Restoring the default restores the original item (writes touch only this property).
          if (!_materializes(r)) expect(r.key.write(changed, r.def), item);
          // Keyframes are never touched by a static write.
          expect(keyframesOf(changed), keyframesOf(item));
        });

        test('applies to its item kinds and throws for the others', () {
          final k = r.key;
          final visual = _visualClip();
          final audioOnly = MediaClip(id: const ItemId('it_x'), start: 0, duration: 10, media: const MediaId('md_a'));
          final t = _textItem();
          final subtitle = cue('it_c', 0, 10);
          expect(k.appliesToItem(visual), r.applies.contains(ItemKindTag.visualClip) || r.applies.contains(ItemKindTag.audioClip));
          expect(k.appliesToItem(audioOnly), r.applies.contains(ItemKindTag.audioClip));
          expect(k.appliesToItem(t), r.applies.contains(ItemKindTag.text));
          expect(k.appliesToItem(subtitle), isFalse);
          expect(() => k.read(subtitle), throwsArgumentError);
          expect(() => k.write(subtitle, k.defaultValue), throwsArgumentError);
          if (!k.appliesToItem(t)) expect(() => k.read(t), throwsArgumentError);
          if (!k.appliesToItem(audioOnly)) expect(() => k.read(audioOnly), throwsArgumentError);
        });
      });
    }
  });

  group('accepts / clamp', () {
    test('numeric bounds are inclusive', () {
      for (final r in _rows) {
        final k = r.key;
        if (k.valueKind != PropertyValueKind.number) continue;
        final kd = k as PropertyKey<double>;
        expect(kd.accepts(kd.min), isTrue, reason: '${k.id} min');
        expect(kd.accepts(kd.max), isTrue, reason: '${k.id} max');
        expect(kd.accepts(kd.min - 0.001), isFalse, reason: '${k.id} below');
        expect(kd.accepts(kd.max + 0.001), isFalse, reason: '${k.id} above');
        expect(kd.accepts(double.nan), isFalse);
        expect(kd.accepts(double.infinity), isFalse);
        expect(kd.clamp(kd.max + 5), kd.max);
        expect(kd.clamp(kd.min - 5), kd.min);
        expect(kd.clamp(double.nan), kd.defaultValue);
      }
    });

    test('Vec2 components are checked individually', () {
      final p = PropertyKeys.position;
      expect(p.accepts(const Vec2(2, -2)), isTrue);
      expect(p.accepts(const Vec2(2.01, 0)), isFalse);
      expect(p.accepts(const Vec2(0, -2.01)), isFalse);
      expect(p.accepts(const Vec2(double.nan, 0)), isFalse);
      expect(p.clamp(const Vec2(5, -5)), const Vec2(2, -2));
    });

    test('ints: fades in [0, 10 s], chroma colour any 24-bit value', () {
      expect(PropertyKeys.fadeIn.accepts(0), isTrue);
      expect(PropertyKeys.fadeIn.accepts(10000000), isTrue);
      expect(PropertyKeys.fadeIn.accepts(10000001), isFalse);
      expect(PropertyKeys.fadeIn.accepts(-1), isFalse);
      expect(PropertyKeys.fadeIn.clamp(20000000), 10000000);
      expect(PropertyKeys.chromaColor.accepts(0x123456), isTrue);
      expect(PropertyKeys.textColor.accepts(0x80FFFFFF), isTrue);
    });

    test('crop must be inside the unit square and non-empty', () {
      final c = PropertyKeys.crop;
      expect(c.accepts(CropRect.full), isTrue);
      expect(c.accepts(const CropRect(left: 0.5, right: 0.5)), isFalse);
      expect(c.accepts(const CropRect(top: 0.9, bottom: 0.1)), isFalse);
      expect(c.accepts(const CropRect(left: -0.1)), isFalse);
      expect(c.accepts(const CropRect(right: 1.1)), isFalse);
    });

    test('font family must be non-empty; enums and toggles always pass', () {
      expect(PropertyKeys.fontFamily.accepts(''), isFalse);
      expect(PropertyKeys.fontFamily.accepts('abc'), isTrue);
      expect(PropertyKeys.fit.accepts(FitMode.stretch), isTrue);
      expect(PropertyKeys.bold.accepts(true), isTrue);
    });
  });

  group('special semantics', () {
    test('look intensity reads 1 without a look, writes only with a look', () {
      final noLook = _visualClip();
      expect(PropertyKeys.lookIntensity.read(noLook), 1);
      expect(() => PropertyKeys.lookIntensity.write(noLook, 0.5), throwsArgumentError);
      final withLook = noLook.copyWith(visual: VisualProps.neutral.copyWith(look: const BuiltinLook('tealOrange')));
      final changed = PropertyKeys.lookIntensity.write(withLook, 0.25) as MediaClip;
      expect(changed.visual!.look, const BuiltinLook('tealOrange', intensity: 0.25));
      final lut = noLook.copyWith(visual: VisualProps.neutral.copyWith(look: const ImportedLut(MediaId('md_l'))));
      expect((PropertyKeys.lookIntensity.write(lut, 0.5) as MediaClip).visual!.look, const ImportedLut(MediaId('md_l'), intensity: 0.5));
    });

    test('text sub-style keys materialize and remove the optional style objects', () {
      final t = _textItem();
      final withStroke = PropertyKeys.strokeWidth.write(t, 5) as TextItem;
      expect(withStroke.style.stroke, const StrokeStyle(widthPt: 5));
      expect(PropertyKeys.strokeEnabled.read(withStroke), isTrue);
      final off = PropertyKeys.strokeEnabled.write(withStroke, false) as TextItem;
      expect(off.style.stroke, isNull);
      expect(PropertyKeys.strokeWidth.read(off), 2, reason: 'reading a missing stroke yields the default');
      final on = PropertyKeys.shadowEnabled.write(t, true) as TextItem;
      expect(on.style.shadow, const ShadowStyle());
      final bg = PropertyKeys.backgroundOpacity.write(t, 0.2) as TextItem;
      expect(bg.style.background, const BoxStyle(opacity: 0.2));
    });

    test('transform keys work on text items and visual clips alike; audio clips reject them', () {
      final t = _textItem();
      final v = _visualClip();
      expect((PropertyKeys.scale.write(t, 2) as TextItem).transform.scale, 2);
      expect((PropertyKeys.scale.write(v, 2) as MediaClip).visual!.transform.scale, 2);
      final audioOnly = _audioClip();
      expect(PropertyKeys.scale.appliesToItem(audioOnly), isFalse);
      expect(() => PropertyKeys.scale.read(audioOnly), throwsArgumentError);
    });

    test('forItem lists the applicable keys', () {
      final tIds = PropertyKeys.forItem(_textItem()).map((k) => k.id).toSet();
      expect(tIds, containsAll(['transform.position', 'transform.opacity', 'text.fontSize']));
      expect(tIds, isNot(contains('adjust.exposure')));
      expect(tIds, isNot(contains('audio.volume')));
      final vIds = PropertyKeys.forItem(_visualClip()).map((k) => k.id).toSet();
      expect(vIds, containsAll(['adjust.exposure', 'mask.feather', 'audio.volume', 'chroma.enabled']));
      expect(vIds, isNot(contains('text.fontSize')));
      expect(PropertyKeys.forItem(cue('it_c', 0, 3)), isEmpty);
    });

    test('model defaults agree with registry defaults', () {
      final v = _visualClip();
      final t = _textItem();
      for (final k in PropertyKeys.all) {
        final item = k.appliesToItem(v) ? v : t;
        if (!k.appliesToItem(item)) continue;
        expect(k.read(item), k.defaultValue, reason: k.id);
      }
    });
  });
}
