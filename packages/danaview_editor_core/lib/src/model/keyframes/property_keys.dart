// OWNER: CORE-05
//
// The property registry (ARCH §6.7, domain.md §4.11): one `PropertyKey<T>` per editable property
// with a stable id, display metadata, range, default, keyframable flag, keyframe channel ids, the
// item kinds it applies to, and static read/write against items. The inspector builds its rows
// from this metadata; commands validate against it; `evaluate` (eval/evaluate.dart) reads it.
//
// Keyframable (exactly ARCH §6.7): position, scale, rotation, opacity, volume, the 8 adjust values,
// sharpness, blur, vignette, and the mask's centre, size, rotation, feather and opacity.
// Not keyframable: chroma, look intensity, crop, flips, fit, text style, fades, mute.

import 'package:meta/meta.dart';

import '../../time/time.dart';
import '../audio_props.dart';
import '../items.dart';
import '../text_style.dart';
import '../visual_props.dart';

/// The kinds of item a property applies to (`PropertyKey.appliesTo`).
enum ItemKindTag {
  /// A media clip with visual properties (video or overlay lane).
  visualClip,

  /// A media clip with audio properties (audio lane clip or a video clip with audio).
  audioClip,

  /// A text item.
  text,
}

/// How the value of a property is edited and shown.
enum PropertyValueKind {
  /// A number on a slider or number field (`double`).
  number,

  /// Two numbers (`Vec2`); keyframable ones have two channels.
  vec2,

  /// An on/off switch (`bool`).
  toggle,

  /// A colour (`int`, ARGB or RGB by property).
  color,

  /// One of a few named values (an enum).
  choice,

  /// A duration in µs (`int`).
  duration,

  /// Free text such as a font id (`String`).
  text,

  /// A rectangle of four numbers (`CropRect`).
  rect,
}

/// A property of an item. All keys are singletons in [PropertyKeys]; two keys are equal when
/// their ids are.
@immutable
final class PropertyKey<T> {
  /// Creates a key. Use [PropertyKeys] instead of constructing keys outside tests.
  const PropertyKey({
    required this.id,
    required this.displayName,
    required this.valueKind,
    required this.defaultValue,
    required this.appliesTo,
    required T Function(TimelineItem item) read,
    required TimelineItem Function(TimelineItem item, T value) write,
    this.unit = '',
    this.min = 0,
    this.max = 0,
    this.step = 0,
    this.displayScale = 1,
    this.channels = const [],
  })  : _read = read,
        _write = write;

  /// Stable id, also the JSON key and the keyframe channel id of scalar properties
  /// (`adjust.exposure`; Vec2 properties have channels `<id>.x` and `<id>.y`).
  final String id;

  /// English display name (the UI localises through its own table keyed by [id]).
  final String displayName;

  /// What the value is.
  final PropertyValueKind valueKind;

  /// The default value.
  final T defaultValue;

  /// The item kinds the property applies to.
  final Set<ItemKindTag> appliesTo;

  /// Display unit: `'%'`, `'°'`, `'pt'`, `'s'`, `'em/100'` or `''`.
  final String unit;

  /// Smallest allowed value (per component for Vec2); 0 for non-numeric kinds.
  final double min;

  /// Largest allowed value (per component for Vec2); 0 for non-numeric kinds.
  final double max;

  /// Increment of the UI stepper/slider in model units; 0 for non-numeric kinds.
  final double step;

  /// The UI shows `value × displayScale` (100 for percentages, 1e-6 for µs shown as seconds).
  final double displayScale;

  /// Keyframe channel ids, empty when the property is not keyframable. Scalars have one channel
  /// (their id); Vec2 properties write both `<id>.x` and `<id>.y` at the same time.
  final List<String> channels;

  final T Function(TimelineItem) _read;
  final TimelineItem Function(TimelineItem, T) _write;

  /// Whether the property can be animated with keyframes.
  bool get keyframable => channels.isNotEmpty;

  /// Whether this property applies to [item]: its kind is in [appliesTo] and, for visual
  /// properties, the clip has visual props.
  bool appliesToItem(TimelineItem item) => switch (item) {
        MediaClip(:final visual) =>
          (appliesTo.contains(ItemKindTag.visualClip) && visual != null) || appliesTo.contains(ItemKindTag.audioClip),
        TextItem() => appliesTo.contains(ItemKindTag.text),
        SubtitleCue() => false,
      };

  /// The static (non-keyframed) value on [item]. Throws [ArgumentError] when [appliesToItem] is
  /// false.
  T read(TimelineItem item) {
    _check(item);
    return _read(item);
  }

  /// [item] with the static value set to [value] (no range check; see [accepts]). Throws
  /// [ArgumentError] when [appliesToItem] is false. Keyframes are not touched.
  TimelineItem write(TimelineItem item, T value) {
    _check(item);
    return _write(item, value);
  }

  void _check(TimelineItem item) {
    if (!appliesToItem(item)) {
      throw ArgumentError.value(item.runtimeType, 'item', 'property "$id" does not apply to this item');
    }
  }

  /// Whether [value] lies in the property's range (the `InvalidValue` test of the commands).
  bool accepts(T value) {
    final v = value as Object?;
    return switch (v) {
      double() => v.isFinite && v >= min && v <= max,
      int() when valueKind == PropertyValueKind.color => true,
      int() => v >= min && v <= max,
      Vec2() => v.x.isFinite && v.y.isFinite && v.x >= min && v.x <= max && v.y >= min && v.y <= max,
      CropRect() => v.left >= 0 && v.top >= 0 && v.right <= 1 && v.bottom <= 1 && v.right > v.left && v.bottom > v.top,
      String() => v.isNotEmpty,
      _ => true,
    };
  }

  /// [value] limited to the property's range (numbers and Vec2 components; others unchanged).
  T clamp(T value) {
    final v = value as Object?;
    final Object? out = switch (v) {
      double() => v.isNaN ? defaultValue : v.clamp(min, max).toDouble(),
      int() when valueKind == PropertyValueKind.color => v,
      int() => v.clamp(min.toInt(), max.toInt()),
      Vec2() => Vec2(v.x.clamp(min, max).toDouble(), v.y.clamp(min, max).toDouble()),
      _ => v,
    };
    return out as T;
  }

  @override
  bool operator ==(Object other) => other is PropertyKey<Object?> && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'PropertyKey($id)';
}

// ---------------------------------------------------------------------------------------------
// Item access helpers.
// ---------------------------------------------------------------------------------------------

Transform2D _transformOf(TimelineItem i) => switch (i) {
      MediaClip(:final visual) when visual != null => visual.transform,
      TextItem(:final transform) => transform,
      _ => throw ArgumentError.value(i.runtimeType, 'item', 'has no transform'),
    };

TimelineItem _withTransform(TimelineItem i, Transform2D t) => switch (i) {
      MediaClip(:final visual) when visual != null => i.copyWith(visual: visual.copyWith(transform: t)),
      TextItem() => i.copyWith(transform: t),
      _ => throw ArgumentError.value(i.runtimeType, 'item', 'has no transform'),
    };

VisualProps _visualOf(TimelineItem i) => switch (i) {
      MediaClip(:final visual) when visual != null => visual,
      _ => throw ArgumentError.value(i.runtimeType, 'item', 'has no visual props'),
    };

TimelineItem _withVisual(TimelineItem i, VisualProps v) => switch (i) {
      MediaClip() => i.copyWith(visual: v),
      _ => throw ArgumentError.value(i.runtimeType, 'item', 'has no visual props'),
    };

AudioProps _audioOf(TimelineItem i) => switch (i) {
      MediaClip(:final audio) => audio,
      _ => throw ArgumentError.value(i.runtimeType, 'item', 'has no audio props'),
    };

TimelineItem _withAudio(TimelineItem i, AudioProps a) => switch (i) {
      MediaClip() => i.copyWith(audio: a),
      _ => throw ArgumentError.value(i.runtimeType, 'item', 'has no audio props'),
    };

TextStyleSpec _styleOf(TimelineItem i) => switch (i) {
      TextItem(:final style) => style,
      _ => throw ArgumentError.value(i.runtimeType, 'item', 'has no text style'),
    };

TimelineItem _withStyle(TimelineItem i, TextStyleSpec s) => switch (i) {
      TextItem() => i.copyWith(style: s),
      _ => throw ArgumentError.value(i.runtimeType, 'item', 'has no text style'),
    };

const Set<ItemKindTag> _visual = {ItemKindTag.visualClip};
const Set<ItemKindTag> _visualOrText = {ItemKindTag.visualClip, ItemKindTag.text};
const Set<ItemKindTag> _audio = {ItemKindTag.audioClip};
const Set<ItemKindTag> _text = {ItemKindTag.text};

List<String> _scalarChannel(String id, bool keyframable) => keyframable ? [id] : const [];

PropertyKey<double> _transformNumber({
  required String id,
  required String name,
  required double min,
  required double max,
  required double step,
  required double def,
  required double Function(Transform2D) get,
  required Transform2D Function(Transform2D, double) set,
  String unit = '%',
  double displayScale = 100,
}) =>
    PropertyKey<double>(
      id: id,
      displayName: name,
      valueKind: PropertyValueKind.number,
      defaultValue: def,
      appliesTo: _visualOrText,
      unit: unit,
      min: min,
      max: max,
      step: step,
      displayScale: displayScale,
      channels: [id],
      read: (i) => get(_transformOf(i)),
      write: (i, v) => _withTransform(i, set(_transformOf(i), v)),
    );

PropertyKey<bool> _transformFlag({
  required String id,
  required String name,
  required bool Function(Transform2D) get,
  required Transform2D Function(Transform2D, bool) set,
}) =>
    PropertyKey<bool>(
      id: id,
      displayName: name,
      valueKind: PropertyValueKind.toggle,
      defaultValue: false,
      appliesTo: _visual,
      read: (i) => get(_transformOf(i)),
      write: (i, v) => _withTransform(i, set(_transformOf(i), v)),
    );

PropertyKey<double> _visualNumber({
  required String id,
  required String name,
  required double min,
  required double max,
  required double def,
  required double Function(VisualProps) get,
  required VisualProps Function(VisualProps, double) set,
  bool keyframable = true,
  double step = 0.01,
}) =>
    PropertyKey<double>(
      id: id,
      displayName: name,
      valueKind: PropertyValueKind.number,
      defaultValue: def,
      appliesTo: _visual,
      unit: '%',
      min: min,
      max: max,
      step: step,
      displayScale: 100,
      channels: _scalarChannel(id, keyframable),
      read: (i) => get(_visualOf(i)),
      write: (i, v) => _withVisual(i, set(_visualOf(i), v)),
    );

PropertyKey<Vec2> _maskVec2({
  required String id,
  required String name,
  required double min,
  required double max,
  required Vec2 def,
  required Vec2 Function(MaskSpec) get,
  required MaskSpec Function(MaskSpec, Vec2) set,
}) =>
    PropertyKey<Vec2>(
      id: id,
      displayName: name,
      valueKind: PropertyValueKind.vec2,
      defaultValue: def,
      appliesTo: _visual,
      unit: '%',
      min: min,
      max: max,
      step: 0.01,
      displayScale: 100,
      channels: ['$id.x', '$id.y'],
      read: (i) => get(_visualOf(i).mask),
      write: (i, v) {
        final vp = _visualOf(i);
        return _withVisual(i, vp.copyWith(mask: set(vp.mask, v)));
      },
    );

PropertyKey<double> _maskNumber({
  required String id,
  required String name,
  required double min,
  required double max,
  required double def,
  required double Function(MaskSpec) get,
  required MaskSpec Function(MaskSpec, double) set,
  required bool keyframable,
  String unit = '%',
  double displayScale = 100,
  double step = 0.01,
}) =>
    PropertyKey<double>(
      id: id,
      displayName: name,
      valueKind: PropertyValueKind.number,
      defaultValue: def,
      appliesTo: _visual,
      unit: unit,
      min: min,
      max: max,
      step: step,
      displayScale: displayScale,
      channels: _scalarChannel(id, keyframable),
      read: (i) => get(_visualOf(i).mask),
      write: (i, v) {
        final vp = _visualOf(i);
        return _withVisual(i, vp.copyWith(mask: set(vp.mask, v)));
      },
    );

PropertyKey<double> _chromaNumber({
  required String id,
  required String name,
  required double def,
  required double Function(ChromaKey) get,
  required ChromaKey Function(ChromaKey, double) set,
}) =>
    PropertyKey<double>(
      id: id,
      displayName: name,
      valueKind: PropertyValueKind.number,
      defaultValue: def,
      appliesTo: _visual,
      unit: '%',
      min: 0,
      max: 1,
      step: 0.01,
      displayScale: 100,
      read: (i) => get(_visualOf(i).chroma),
      write: (i, v) {
        final vp = _visualOf(i);
        return _withVisual(i, vp.copyWith(chroma: set(vp.chroma, v)));
      },
    );

PropertyKey<double> _textNumber({
  required String id,
  required String name,
  required double min,
  required double max,
  required double step,
  required double def,
  required double Function(TextStyleSpec) get,
  required TextStyleSpec Function(TextStyleSpec, double) set,
  String unit = '',
  double displayScale = 1,
}) =>
    PropertyKey<double>(
      id: id,
      displayName: name,
      valueKind: PropertyValueKind.number,
      defaultValue: def,
      appliesTo: _text,
      unit: unit,
      min: min,
      max: max,
      step: step,
      displayScale: displayScale,
      read: (i) => get(_styleOf(i)),
      write: (i, v) => _withStyle(i, set(_styleOf(i), v)),
    );

PropertyKey<bool> _textToggle(String id, String name, bool Function(TextStyleSpec) get, TextStyleSpec Function(TextStyleSpec, bool) set,
        {bool def = false}) =>
    PropertyKey<bool>(
      id: id,
      displayName: name,
      valueKind: PropertyValueKind.toggle,
      defaultValue: def,
      appliesTo: _text,
      read: (i) => get(_styleOf(i)),
      write: (i, v) => _withStyle(i, set(_styleOf(i), v)),
    );

PropertyKey<int> _textColor(String id, String name, int def, int Function(TextStyleSpec) get, TextStyleSpec Function(TextStyleSpec, int) set) =>
    PropertyKey<int>(
      id: id,
      displayName: name,
      valueKind: PropertyValueKind.color,
      defaultValue: def,
      appliesTo: _text,
      read: (i) => get(_styleOf(i)),
      write: (i, v) => _withStyle(i, set(_styleOf(i), v)),
    );

PropertyKey<int> _fade(String id, String name, TimeUs Function(AudioProps) get, AudioProps Function(AudioProps, TimeUs) set) =>
    PropertyKey<int>(
      id: id,
      displayName: name,
      valueKind: PropertyValueKind.duration,
      defaultValue: 0,
      appliesTo: _audio,
      unit: 's',
      min: 0,
      max: 10e6,
      step: 100000,
      displayScale: 1e-6,
      read: (i) => get(_audioOf(i)),
      write: (i, v) => _withAudio(i, set(_audioOf(i), v)),
    );

/// The property registry: every key, by name and by stable id.
abstract final class PropertyKeys {
  // --- Transform (video, image, overlay and text) -------------------------------------------

  /// Centre offset in canvas fractions, both axes in [-2, 2] (UI: −200…200 %). Keyframable.
  static final PropertyKey<Vec2> position = PropertyKey<Vec2>(
    id: 'transform.position',
    displayName: 'Position',
    valueKind: PropertyValueKind.vec2,
    defaultValue: Vec2.zero,
    appliesTo: _visualOrText,
    unit: '%',
    min: -2,
    max: 2,
    step: 0.01,
    displayScale: 100,
    channels: const ['transform.position.x', 'transform.position.y'],
    read: (i) => _transformOf(i).position,
    write: (i, v) => _withTransform(i, _transformOf(i).copyWith(position: v)),
  );

  /// Uniform scale in [0.01, 8] (UI: 1…800 %, default 100 %). Keyframable.
  static final PropertyKey<double> scale = _transformNumber(
    id: 'transform.scale',
    name: 'Scale',
    min: 0.01,
    max: 8,
    step: 0.01,
    def: 1,
    get: (t) => t.scale,
    set: (t, v) => t.copyWith(scale: v),
  );

  /// Clockwise rotation in plain degrees, [-360, 360]; interpolated linearly without wrapping.
  /// Keyframable.
  static final PropertyKey<double> rotation = _transformNumber(
    id: 'transform.rotation',
    name: 'Rotation',
    min: -360,
    max: 360,
    step: 1,
    def: 0,
    unit: '°',
    displayScale: 1,
    get: (t) => t.rotationDeg,
    set: (t, v) => t.copyWith(rotationDeg: v),
  );

  /// Layer opacity in [0, 1] (UI: 0…100 %). Keyframable.
  static final PropertyKey<double> opacity = _transformNumber(
    id: 'transform.opacity',
    name: 'Opacity',
    min: 0,
    max: 1,
    step: 0.01,
    def: 1,
    get: (t) => t.opacity,
    set: (t, v) => t.copyWith(opacity: v),
  );

  /// Horizontal mirror. Not keyframable.
  static final PropertyKey<bool> flipH = _transformFlag(
    id: 'transform.flipH',
    name: 'Flip horizontally',
    get: (t) => t.flipH,
    set: (t, v) => t.copyWith(flipH: v),
  );

  /// Vertical mirror. Not keyframable.
  static final PropertyKey<bool> flipV = _transformFlag(
    id: 'transform.flipV',
    name: 'Flip vertically',
    get: (t) => t.flipV,
    set: (t, v) => t.copyWith(flipV: v),
  );

  /// Fit / fill / stretch. Not keyframable.
  static final PropertyKey<FitMode> fit = PropertyKey<FitMode>(
    id: 'visual.fit',
    displayName: 'Fit',
    valueKind: PropertyValueKind.choice,
    defaultValue: FitMode.fit,
    appliesTo: _visual,
    read: (i) => _visualOf(i).fit,
    write: (i, v) => _withVisual(i, _visualOf(i).copyWith(fit: v)),
  );

  /// Source crop in normalized display-oriented coordinates. Not keyframable.
  static final PropertyKey<CropRect> crop = PropertyKey<CropRect>(
    id: 'visual.crop',
    displayName: 'Crop',
    valueKind: PropertyValueKind.rect,
    defaultValue: CropRect.full,
    appliesTo: _visual,
    min: 0,
    max: 1,
    step: 0.01,
    displayScale: 100,
    read: (i) => _visualOf(i).crop,
    write: (i, v) => _withVisual(i, _visualOf(i).copyWith(crop: v)),
  );

  // --- Adjust (eight values, each [-1, 1], UI ×100) -----------------------------------------

  /// Exposure (±2 EV at the extremes). Keyframable.
  static final PropertyKey<double> exposure = _visualNumber(
    id: 'adjust.exposure',
    name: 'Exposure',
    min: -1,
    max: 1,
    def: 0,
    get: (v) => v.adjust.exposure,
    set: (v, x) => v.copyWith(adjust: v.adjust.copyWith(exposure: x)),
  );

  /// Brightness. Keyframable.
  static final PropertyKey<double> brightness = _visualNumber(
    id: 'adjust.brightness',
    name: 'Brightness',
    min: -1,
    max: 1,
    def: 0,
    get: (v) => v.adjust.brightness,
    set: (v, x) => v.copyWith(adjust: v.adjust.copyWith(brightness: x)),
  );

  /// Contrast. Keyframable.
  static final PropertyKey<double> contrast = _visualNumber(
    id: 'adjust.contrast',
    name: 'Contrast',
    min: -1,
    max: 1,
    def: 0,
    get: (v) => v.adjust.contrast,
    set: (v, x) => v.copyWith(adjust: v.adjust.copyWith(contrast: x)),
  );

  /// Highlights. Keyframable.
  static final PropertyKey<double> highlights = _visualNumber(
    id: 'adjust.highlights',
    name: 'Highlights',
    min: -1,
    max: 1,
    def: 0,
    get: (v) => v.adjust.highlights,
    set: (v, x) => v.copyWith(adjust: v.adjust.copyWith(highlights: x)),
  );

  /// Shadows. Keyframable.
  static final PropertyKey<double> shadows = _visualNumber(
    id: 'adjust.shadows',
    name: 'Shadows',
    min: -1,
    max: 1,
    def: 0,
    get: (v) => v.adjust.shadows,
    set: (v, x) => v.copyWith(adjust: v.adjust.copyWith(shadows: x)),
  );

  /// Saturation. Keyframable.
  static final PropertyKey<double> saturation = _visualNumber(
    id: 'adjust.saturation',
    name: 'Saturation',
    min: -1,
    max: 1,
    def: 0,
    get: (v) => v.adjust.saturation,
    set: (v, x) => v.copyWith(adjust: v.adjust.copyWith(saturation: x)),
  );

  /// Temperature (warm +, cool −). Keyframable.
  static final PropertyKey<double> temperature = _visualNumber(
    id: 'adjust.temperature',
    name: 'Temperature',
    min: -1,
    max: 1,
    def: 0,
    get: (v) => v.adjust.temperature,
    set: (v, x) => v.copyWith(adjust: v.adjust.copyWith(temperature: x)),
  );

  /// Tint (magenta +, green −). Keyframable.
  static final PropertyKey<double> tint = _visualNumber(
    id: 'adjust.tint',
    name: 'Tint',
    min: -1,
    max: 1,
    def: 0,
    get: (v) => v.adjust.tint,
    set: (v, x) => v.copyWith(adjust: v.adjust.copyWith(tint: x)),
  );

  // --- Detail ([0, 1], UI ×100) --------------------------------------------------------------

  /// Sharpness. Keyframable.
  static final PropertyKey<double> sharpness = _visualNumber(
    id: 'detail.sharpness',
    name: 'Sharpness',
    min: 0,
    max: 1,
    def: 0,
    get: (v) => v.detail.sharpness,
    set: (v, x) => v.copyWith(detail: v.detail.copyWith(sharpness: x)),
  );

  /// Blur. Keyframable.
  static final PropertyKey<double> blur = _visualNumber(
    id: 'detail.blur',
    name: 'Blur',
    min: 0,
    max: 1,
    def: 0,
    get: (v) => v.detail.blur,
    set: (v, x) => v.copyWith(detail: v.detail.copyWith(blur: x)),
  );

  /// Vignette. Keyframable.
  static final PropertyKey<double> vignette = _visualNumber(
    id: 'detail.vignette',
    name: 'Vignette',
    min: 0,
    max: 1,
    def: 0,
    get: (v) => v.detail.vignette,
    set: (v, x) => v.copyWith(detail: v.detail.copyWith(vignette: x)),
  );

  // --- Look ----------------------------------------------------------------------------------

  /// Look mix amount in [0, 1] (default 1). Applies only while the clip has a look; reading a
  /// clip without a look yields the default and writing to it throws [ArgumentError]. Not
  /// keyframable.
  static final PropertyKey<double> lookIntensity = PropertyKey<double>(
    id: 'look.intensity',
    displayName: 'Look intensity',
    valueKind: PropertyValueKind.number,
    defaultValue: 1,
    appliesTo: _visual,
    unit: '%',
    min: 0,
    max: 1,
    step: 0.01,
    displayScale: 100,
    read: (i) => _visualOf(i).look?.intensity ?? 1,
    write: (i, v) {
      final vp = _visualOf(i);
      final look = vp.look;
      if (look == null) throw ArgumentError.value(i.id, 'item', 'has no look to set the intensity of');
      return _withVisual(i, vp.copyWith(look: look.withIntensity(v)));
    },
  );

  // --- Chroma key (not keyframable) ----------------------------------------------------------

  /// Chroma key on/off.
  static final PropertyKey<bool> chromaEnabled = PropertyKey<bool>(
    id: 'chroma.enabled',
    displayName: 'Chroma key',
    valueKind: PropertyValueKind.toggle,
    defaultValue: false,
    appliesTo: _visual,
    read: (i) => _visualOf(i).chroma.enabled,
    write: (i, v) {
      final vp = _visualOf(i);
      return _withVisual(i, vp.copyWith(chroma: vp.chroma.copyWith(enabled: v)));
    },
  );

  /// Key colour as `0xRRGGBB` (default green `0x00B140`).
  static final PropertyKey<int> chromaColor = PropertyKey<int>(
    id: 'chroma.color',
    displayName: 'Key colour',
    valueKind: PropertyValueKind.color,
    defaultValue: 0x00B140,
    appliesTo: _visual,
    min: 0,
    max: 0xFFFFFF,
    read: (i) => _visualOf(i).chroma.color,
    write: (i, v) {
      final vp = _visualOf(i);
      return _withVisual(i, vp.copyWith(chroma: vp.chroma.copyWith(color: v)));
    },
  );

  /// Similarity threshold in [0, 1] (default 0.4).
  static final PropertyKey<double> chromaSimilarity = _chromaNumber(
    id: 'chroma.similarity',
    name: 'Similarity',
    def: 0.4,
    get: (c) => c.similarity,
    set: (c, v) => c.copyWith(similarity: v),
  );

  /// Edge smoothness in [0, 1] (default 0.1).
  static final PropertyKey<double> chromaSmoothness = _chromaNumber(
    id: 'chroma.smoothness',
    name: 'Smoothness',
    def: 0.1,
    get: (c) => c.smoothness,
    set: (c, v) => c.copyWith(smoothness: v),
  );

  /// Spill reduction in [0, 1] (default 0.3).
  static final PropertyKey<double> chromaSpill = _chromaNumber(
    id: 'chroma.spill',
    name: 'Spill reduction',
    def: 0.3,
    get: (c) => c.spill,
    set: (c, v) => c.copyWith(spill: v),
  );

  // --- Mask ----------------------------------------------------------------------------------

  /// Mask shape (none / rectangle / ellipse). Not keyframable.
  static final PropertyKey<MaskShape> maskShape = PropertyKey<MaskShape>(
    id: 'mask.shape',
    displayName: 'Mask shape',
    valueKind: PropertyValueKind.choice,
    defaultValue: MaskShape.none,
    appliesTo: _visual,
    read: (i) => _visualOf(i).mask.shape,
    write: (i, v) {
      final vp = _visualOf(i);
      return _withVisual(i, vp.copyWith(mask: vp.mask.copyWith(shape: v)));
    },
  );

  /// Mask centre in item-local normalized units ([-0.5, 1.5] per axis, default centre).
  /// Keyframable.
  static final PropertyKey<Vec2> maskCenter = _maskVec2(
    id: 'mask.center',
    name: 'Mask position',
    min: -0.5,
    max: 1.5,
    def: const Vec2(0.5, 0.5),
    get: (m) => m.center,
    set: (m, v) => m.copyWith(center: v),
  );

  /// Mask size in item-local normalized units ([0.01, 2] per axis, default 0.6). Keyframable.
  static final PropertyKey<Vec2> maskSize = _maskVec2(
    id: 'mask.size',
    name: 'Mask size',
    min: 0.01,
    max: 2,
    def: const Vec2(0.6, 0.6),
    get: (m) => m.size,
    set: (m, v) => m.copyWith(size: v),
  );

  /// Mask rotation in degrees, [-360, 360]. Keyframable.
  static final PropertyKey<double> maskRotation = _maskNumber(
    id: 'mask.rotation',
    name: 'Mask rotation',
    min: -360,
    max: 360,
    def: 0,
    unit: '°',
    displayScale: 1,
    step: 1,
    keyframable: true,
    get: (m) => m.rotationDeg,
    set: (m, v) => m.copyWith(rotationDeg: v),
  );

  /// Corner radius as a fraction of min(w, h), [0, 0.5]. Not keyframable.
  static final PropertyKey<double> maskCornerRadius = _maskNumber(
    id: 'mask.cornerRadius',
    name: 'Corner radius',
    min: 0,
    max: 0.5,
    def: 0,
    keyframable: false,
    get: (m) => m.cornerRadius,
    set: (m, v) => m.copyWith(cornerRadius: v),
  );

  /// Edge feather in [0, 1]. Keyframable.
  static final PropertyKey<double> maskFeather = _maskNumber(
    id: 'mask.feather',
    name: 'Feather',
    min: 0,
    max: 1,
    def: 0,
    keyframable: true,
    get: (m) => m.feather,
    set: (m, v) => m.copyWith(feather: v),
  );

  /// Mask strength in [0, 1]. Keyframable.
  static final PropertyKey<double> maskOpacity = _maskNumber(
    id: 'mask.opacity',
    name: 'Mask opacity',
    min: 0,
    max: 1,
    def: 1,
    keyframable: true,
    get: (m) => m.opacity,
    set: (m, v) => m.copyWith(opacity: v),
  );

  /// Keep the outside instead of the inside. Not keyframable.
  static final PropertyKey<bool> maskInvert = PropertyKey<bool>(
    id: 'mask.invert',
    displayName: 'Invert mask',
    valueKind: PropertyValueKind.toggle,
    defaultValue: false,
    appliesTo: _visual,
    read: (i) => _visualOf(i).mask.invert,
    write: (i, v) {
      final vp = _visualOf(i);
      return _withVisual(i, vp.copyWith(mask: vp.mask.copyWith(invert: v)));
    },
  );

  // --- Audio ---------------------------------------------------------------------------------

  /// Linear gain in [0, 2] (1 = 0 dB; UI 0…200 %). Keyframable; applies to audio clips and video
  /// clips with audio.
  static final PropertyKey<double> volume = PropertyKey<double>(
    id: 'audio.volume',
    displayName: 'Volume',
    valueKind: PropertyValueKind.number,
    defaultValue: 1,
    appliesTo: _audio,
    unit: '%',
    min: 0,
    max: 2,
    step: 0.01,
    displayScale: 100,
    channels: const ['audio.volume'],
    read: (i) => _audioOf(i).volume,
    write: (i, v) => _withAudio(i, _audioOf(i).copyWith(volume: v)),
  );

  /// Clip mute. Not keyframable.
  static final PropertyKey<bool> muted = PropertyKey<bool>(
    id: 'audio.muted',
    displayName: 'Mute',
    valueKind: PropertyValueKind.toggle,
    defaultValue: false,
    appliesTo: _audio,
    read: (i) => _audioOf(i).muted,
    write: (i, v) => _withAudio(i, _audioOf(i).copyWith(muted: v)),
  );

  /// Fade-in length in µs ([0, 10 s]; also at most half the clip, checked by the commands).
  /// Not keyframable.
  static final PropertyKey<int> fadeIn = _fade('audio.fadeIn', 'Fade in', (a) => a.fadeIn, (a, v) => a.copyWith(fadeIn: v));

  /// Fade-out length in µs ([0, 10 s]). Not keyframable.
  static final PropertyKey<int> fadeOut = _fade('audio.fadeOut', 'Fade out', (a) => a.fadeOut, (a, v) => a.copyWith(fadeOut: v));

  // --- Text style (text items; not keyframable) ----------------------------------------------

  /// Content-font id (D-30); unknown ids fall back to Figtree.
  static final PropertyKey<String> fontFamily = PropertyKey<String>(
    id: 'text.fontFamily',
    displayName: 'Font',
    valueKind: PropertyValueKind.text,
    defaultValue: 'figtree',
    appliesTo: _text,
    read: (i) => _styleOf(i).fontFamily,
    write: (i, v) => _withStyle(i, _styleOf(i).copyWith(fontFamily: v)),
  );

  /// Font size in points at a 1,080 px short side, [8, 200].
  static final PropertyKey<double> fontSize = _textNumber(
    id: 'text.fontSize',
    name: 'Size',
    min: 8,
    max: 200,
    step: 1,
    def: 48,
    unit: 'pt',
    get: (s) => s.fontSizePt,
    set: (s, v) => s.copyWith(fontSizePt: v),
  );

  /// Bold.
  static final PropertyKey<bool> bold = _textToggle('text.bold', 'Bold', (s) => s.bold, (s, v) => s.copyWith(bold: v));

  /// Italic.
  static final PropertyKey<bool> italic = _textToggle('text.italic', 'Italic', (s) => s.italic, (s, v) => s.copyWith(italic: v));

  /// Line alignment.
  static final PropertyKey<TextAlignH> textAlign = PropertyKey<TextAlignH>(
    id: 'text.align',
    displayName: 'Alignment',
    valueKind: PropertyValueKind.choice,
    defaultValue: TextAlignH.center,
    appliesTo: _text,
    read: (i) => _styleOf(i).align,
    write: (i, v) => _withStyle(i, _styleOf(i).copyWith(align: v)),
  );

  /// ARGB text colour (alpha is the text opacity).
  static final PropertyKey<int> textColor = _textColor('text.color', 'Colour', 0xFFFFFFFF, (s) => s.color, (s, v) => s.copyWith(color: v));

  /// Letter spacing in em/100, [-20, 100].
  static final PropertyKey<double> letterSpacing = _textNumber(
    id: 'text.letterSpacing',
    name: 'Letter spacing',
    min: -20,
    max: 100,
    step: 1,
    def: 0,
    unit: 'em/100',
    get: (s) => s.letterSpacing,
    set: (s, v) => s.copyWith(letterSpacing: v),
  );

  /// Line height multiplier, [0.6, 3].
  static final PropertyKey<double> lineHeight = _textNumber(
    id: 'text.lineHeight',
    name: 'Line spacing',
    min: 0.6,
    max: 3,
    step: 0.05,
    def: 1.2,
    get: (s) => s.lineHeight,
    set: (s, v) => s.copyWith(lineHeight: v),
  );

  /// Wrap width as a fraction of the canvas width, [0.1, 1] (default 0.9).
  static final PropertyKey<double> maxWidth = _textNumber(
    id: 'text.maxWidth',
    name: 'Width',
    min: 0.1,
    max: 1,
    step: 0.01,
    def: 0.9,
    unit: '%',
    displayScale: 100,
    get: (s) => s.maxWidth,
    set: (s, v) => s.copyWith(maxWidth: v),
  );

  /// Background box on/off (writing `true` creates the default box, `false` removes it).
  static final PropertyKey<bool> backgroundEnabled = _textToggle(
    'text.background.enabled',
    'Background',
    (s) => s.background != null,
    (s, v) => v ? s.copyWith(background: s.background ?? const BoxStyle()) : s.copyWith(background: null),
  );

  /// Background colour (ARGB).
  static final PropertyKey<int> backgroundColor = _textColor(
    'text.background.color',
    'Background colour',
    0xFF000000,
    (s) => (s.background ?? const BoxStyle()).color,
    (s, v) => s.copyWith(background: (s.background ?? const BoxStyle()).copyWith(color: v)),
  );

  /// Background opacity, [0, 1].
  static final PropertyKey<double> backgroundOpacity = _textNumber(
    id: 'text.background.opacity',
    name: 'Background opacity',
    min: 0,
    max: 1,
    step: 0.01,
    def: 0.6,
    unit: '%',
    displayScale: 100,
    get: (s) => (s.background ?? const BoxStyle()).opacity,
    set: (s, v) => s.copyWith(background: (s.background ?? const BoxStyle()).copyWith(opacity: v)),
  );

  /// Background padding in points, [0, 100].
  static final PropertyKey<double> backgroundPadding = _textNumber(
    id: 'text.background.padding',
    name: 'Padding',
    min: 0,
    max: 100,
    step: 1,
    def: 12,
    unit: 'pt',
    get: (s) => (s.background ?? const BoxStyle()).paddingPt,
    set: (s, v) => s.copyWith(background: (s.background ?? const BoxStyle()).copyWith(paddingPt: v)),
  );

  /// Background corner radius in points, [0, 100].
  static final PropertyKey<double> backgroundCornerRadius = _textNumber(
    id: 'text.background.cornerRadius',
    name: 'Corner radius',
    min: 0,
    max: 100,
    step: 1,
    def: 8,
    unit: 'pt',
    get: (s) => (s.background ?? const BoxStyle()).cornerRadiusPt,
    set: (s, v) => s.copyWith(background: (s.background ?? const BoxStyle()).copyWith(cornerRadiusPt: v)),
  );

  /// Outline on/off.
  static final PropertyKey<bool> strokeEnabled = _textToggle(
    'text.stroke.enabled',
    'Outline',
    (s) => s.stroke != null,
    (s, v) => v ? s.copyWith(stroke: s.stroke ?? const StrokeStyle()) : s.copyWith(stroke: null),
  );

  /// Outline colour (ARGB).
  static final PropertyKey<int> strokeColor = _textColor(
    'text.stroke.color',
    'Outline colour',
    0xFF000000,
    (s) => (s.stroke ?? const StrokeStyle()).color,
    (s, v) => s.copyWith(stroke: (s.stroke ?? const StrokeStyle()).copyWith(color: v)),
  );

  /// Outline width in points, [0, 20].
  static final PropertyKey<double> strokeWidth = _textNumber(
    id: 'text.stroke.width',
    name: 'Outline width',
    min: 0,
    max: 20,
    step: 0.5,
    def: 2,
    unit: 'pt',
    get: (s) => (s.stroke ?? const StrokeStyle()).widthPt,
    set: (s, v) => s.copyWith(stroke: (s.stroke ?? const StrokeStyle()).copyWith(widthPt: v)),
  );

  /// Shadow on/off.
  static final PropertyKey<bool> shadowEnabled = _textToggle(
    'text.shadow.enabled',
    'Shadow',
    (s) => s.shadow != null,
    (s, v) => v ? s.copyWith(shadow: s.shadow ?? const ShadowStyle()) : s.copyWith(shadow: null),
  );

  /// Shadow colour (ARGB).
  static final PropertyKey<int> shadowColor = _textColor(
    'text.shadow.color',
    'Shadow colour',
    0xFF000000,
    (s) => (s.shadow ?? const ShadowStyle()).color,
    (s, v) => s.copyWith(shadow: (s.shadow ?? const ShadowStyle()).copyWith(color: v)),
  );

  /// Shadow opacity, [0, 1].
  static final PropertyKey<double> shadowOpacity = _textNumber(
    id: 'text.shadow.opacity',
    name: 'Shadow opacity',
    min: 0,
    max: 1,
    step: 0.01,
    def: 0.5,
    unit: '%',
    displayScale: 100,
    get: (s) => (s.shadow ?? const ShadowStyle()).opacity,
    set: (s, v) => s.copyWith(shadow: (s.shadow ?? const ShadowStyle()).copyWith(opacity: v)),
  );

  /// Shadow blur radius in points, [0, 40].
  static final PropertyKey<double> shadowBlur = _textNumber(
    id: 'text.shadow.blur',
    name: 'Shadow blur',
    min: 0,
    max: 40,
    step: 1,
    def: 6,
    unit: 'pt',
    get: (s) => (s.shadow ?? const ShadowStyle()).blurPt,
    set: (s, v) => s.copyWith(shadow: (s.shadow ?? const ShadowStyle()).copyWith(blurPt: v)),
  );

  /// Shadow offset distance in points, [0, 40].
  static final PropertyKey<double> shadowDistance = _textNumber(
    id: 'text.shadow.distance',
    name: 'Shadow distance',
    min: 0,
    max: 40,
    step: 1,
    def: 3,
    unit: 'pt',
    get: (s) => (s.shadow ?? const ShadowStyle()).distancePt,
    set: (s, v) => s.copyWith(shadow: (s.shadow ?? const ShadowStyle()).copyWith(distancePt: v)),
  );

  /// Shadow direction in degrees, [0, 360] (90 = straight down).
  static final PropertyKey<double> shadowAngle = _textNumber(
    id: 'text.shadow.angle',
    name: 'Shadow angle',
    min: 0,
    max: 360,
    step: 1,
    def: 90,
    unit: '°',
    get: (s) => (s.shadow ?? const ShadowStyle()).angleDeg,
    set: (s, v) => s.copyWith(shadow: (s.shadow ?? const ShadowStyle()).copyWith(angleDeg: v)),
  );

  // --- Registry ------------------------------------------------------------------------------

  /// Every key, in inspector order.
  static final List<PropertyKey<Object?>> all = List.unmodifiable(<PropertyKey<Object?>>[
    position,
    scale,
    rotation,
    opacity,
    flipH,
    flipV,
    fit,
    crop,
    exposure,
    brightness,
    contrast,
    highlights,
    shadows,
    saturation,
    temperature,
    tint,
    sharpness,
    blur,
    vignette,
    lookIntensity,
    chromaEnabled,
    chromaColor,
    chromaSimilarity,
    chromaSmoothness,
    chromaSpill,
    maskShape,
    maskCenter,
    maskSize,
    maskRotation,
    maskCornerRadius,
    maskFeather,
    maskOpacity,
    maskInvert,
    volume,
    muted,
    fadeIn,
    fadeOut,
    fontFamily,
    fontSize,
    bold,
    italic,
    textAlign,
    textColor,
    letterSpacing,
    lineHeight,
    maxWidth,
    backgroundEnabled,
    backgroundColor,
    backgroundOpacity,
    backgroundPadding,
    backgroundCornerRadius,
    strokeEnabled,
    strokeColor,
    strokeWidth,
    shadowEnabled,
    shadowColor,
    shadowOpacity,
    shadowBlur,
    shadowDistance,
    shadowAngle,
  ]);

  /// Keys by stable id.
  static final Map<String, PropertyKey<Object?>> byId = Map.unmodifiable({for (final k in all) k.id: k});

  /// The keyframable keys, in registry order.
  static final List<PropertyKey<Object?>> keyframable = List.unmodifiable(all.where((k) => k.keyframable));

  /// Owner of each keyframe channel id (`transform.position.x` → [position]).
  static final Map<String, PropertyKey<Object?>> byChannel = Map.unmodifiable({
    for (final k in keyframable)
      for (final c in k.channels) c: k,
  });

  /// The key with stable [id], or null.
  static PropertyKey<Object?>? lookup(String id) => byId[id];

  /// The keys that apply to [item], in registry order.
  static List<PropertyKey<Object?>> forItem(TimelineItem item) => [
        for (final k in all)
          if (k.appliesToItem(item)) k,
      ];
}
