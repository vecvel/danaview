// OWNER: CORE-13
//
// Property commands (ARCH §6.5–6.7, §7.2, domain.md §4.11 and §6.2): `SetProperty<T>` (keyframe
// aware), the whole-struct setters of the inspector panels (`SetVisual`, `SetAudio`, `SetLook`,
// `SetChroma`, `SetMask`, `SetCrop`) and `ResetTransform`. The keyframe commands (`AddKeyframe`,
// `RemoveKeyframe`, `MoveKeyframe`, `SetKeyframeValue`, `ClearKeyframes`) are in
// keyframe_commands.dart and share the helpers below.
//
// * **Multi-item edits are one outcome**: every item is checked first, the command is refused as a
//   whole when one item cannot take it (a rejection never leaves a partial edit), and the changed
//   items are replaced together ("apply to all" is one history entry).
// * **Ranges come from the registry** (`PropertyKey.min/max`, `accepts`): a value outside its range
//   is `InvalidValue(<property id>)`; whole-struct setters are checked with the same I6 range test
//   the validator uses (`outOfRangeProperties`).
// * **Keyframe-aware writes.** `SetProperty` on a keyframable property whose channels have keys
//   upserts a key at the frame-quantized `at` (nearest frame, absolute timeline time → item-local
//   `at − start`) instead of changing the static value; without keys it sets the static value.
//   Writing a key needs `at` inside the item (`NothingAtTime` otherwise; `InvalidValue('at')` when
//   `at` is missing).
// * **Fades** are kept on the grid and at most half the clip (nearest frame).
// * Volume keyframes and fades apply to audio clips and to video clips that have audio
//   (`UnsupportedForKind('noAudio')` for silent media); the look intensity needs a look
//   (`UnsupportedForKind('noLook')`).

part of '../edit_command.dart';

// -------------------------------------------------------------------------------------------
// Shared helpers (also used by keyframe_commands.dart and text_commands.dart).
// -------------------------------------------------------------------------------------------

/// The distinct items of [ids], located and checked for locked lanes. Empty → `InvalidValue('items')`.
List<_Loc> _editableItems(_Draft d, Iterable<ItemId> ids) {
  final seen = <ItemId>{};
  final out = <_Loc>[];
  for (final id in ids) {
    if (!seen.add(id)) continue;
    final l = d.locate(id);
    if (l.track.locked) d.reject(TrackLocked(l.track.id));
    out.add(l);
  }
  if (out.isEmpty) d.reject(const InvalidValue('items'));
  return out;
}

/// Whether [clip] has sound to edit: audio media, or video with an audio stream (unknown media is
/// given the benefit of the doubt; the validator reports it).
bool _hasAudio(_Draft d, MediaClip clip) {
  final a = d.assetOf(clip);
  if (a == null) return true;
  return a.kind == MediaKind.audio || a.kind == MediaKind.recording || (a.kind == MediaKind.video && a.probe.hasAudio);
}

/// Refuses [item] when [key] does not apply to it (`UnsupportedForKind`).
void _requireApplies(_Draft d, TimelineItem item, PropertyKey<Object?> key) {
  if (item is SubtitleCue) d.reject(const UnsupportedForKind('subtitle'));
  if (!key.appliesToItem(item)) {
    d.reject(UnsupportedForKind(switch (item) {
      TextItem() => 'text',
      MediaClip(:final visual) when visual == null => 'audioClip',
      _ => 'media',
    }));
  }
  if (item is MediaClip && key.appliesTo.contains(ItemKindTag.audioClip) && !_hasAudio(d, item)) {
    d.reject(const UnsupportedForKind('noAudio'));
  }
  // The look intensity belongs to a look: a clip without one has nothing to set it on.
  if (key.id == PropertyKeys.lookIntensity.id && item is MediaClip && item.visual?.look == null) {
    d.reject(const UnsupportedForKind('noLook'));
  }
}

/// Refuses [value] when it is not a legal value of [key]: wrong type or outside the registry range
/// (`InvalidValue(key.id)`). Integers given for numeric properties are accepted.
void _requireValue(_Draft d, PropertyKey<Object?> key, Object? value) {
  final ok = switch (key.valueKind) {
    PropertyValueKind.number => value is num,
    PropertyValueKind.vec2 => value is Vec2,
    PropertyValueKind.toggle => value is bool,
    PropertyValueKind.color => value is int && value >= 0 && value <= 0xFFFFFFFF,
    PropertyValueKind.duration => value is int,
    PropertyValueKind.text => value is String,
    PropertyValueKind.rect => value is CropRect,
    PropertyValueKind.choice => value != null,
  };
  if (!ok) d.reject(InvalidValue(key.id));
  final checked = value is int && key.valueKind == PropertyValueKind.number ? value.toDouble() : value;
  if (!key.accepts(checked)) d.reject(InvalidValue(key.id));
}

/// The fade-in length [len] fitted to [item]: whole frames from its start, at most half of it.
TimeUs _fitFadeIn(_Draft d, TimelineItem item, TimeUs len) {
  final k0 = d.frameOf(item.start);
  final half = d.framesOf(item) ~/ 2;
  final n = (d.rate.frameIndexNearest(item.start + len) - k0).clamp(0, half);
  return d.timeOf(k0 + n) - item.start;
}

/// The fade-out length [len] fitted to [item]: whole frames back from its end, at most half of it.
TimeUs _fitFadeOut(_Draft d, TimelineItem item, TimeUs len) {
  final k1 = d.frameOf(item.end);
  final half = d.framesOf(item) ~/ 2;
  final n = (k1 - d.rate.frameIndexNearest(item.end - len)).clamp(0, half);
  return item.end - d.timeOf(k1 - n);
}

/// [audio] with both fades fitted to [clip] (grid, ≤ half the clip).
AudioProps _fitAudio(_Draft d, MediaClip clip, AudioProps audio) => audio.copyWith(
      fadeIn: audio.fadeIn == 0 ? 0 : _fitFadeIn(d, clip, audio.fadeIn),
      fadeOut: audio.fadeOut == 0 ? 0 : _fitFadeOut(d, clip, audio.fadeOut),
    );

/// [item] with the static value of [key] set (keyframes untouched). Fade lengths are fitted.
TimelineItem _writeStatic(_Draft d, TimelineItem item, PropertyKey<Object?> key, Object? value) {
  if (key.id == PropertyKeys.fadeIn.id && item is MediaClip) {
    return item.copyWith(audio: item.audio.copyWith(fadeIn: _fitFadeIn(d, item, value as int)));
  }
  if (key.id == PropertyKeys.fadeOut.id && item is MediaClip) {
    return item.copyWith(audio: item.audio.copyWith(fadeOut: _fitFadeOut(d, item, value as int)));
  }
  final v = value is int && key.valueKind == PropertyValueKind.number ? value.toDouble() : value;
  return key.write(item, v);
}

/// The static properties of [after] that are out of range and were not already in [before]
/// (the I6 range test of the validator, by property id).
String? _newRangeViolation(TimelineItem before, TimelineItem after) {
  final now = outOfRangeProperties(after);
  if (now.isEmpty) return null;
  final had = outOfRangeProperties(before).toSet();
  for (final id in now) {
    if (!had.contains(id)) return id;
  }
  return null;
}

/// Replaces [updated] after checking each against its original for new range violations.
void _commitChecked(_Draft d, List<(TimelineItem, TimelineItem)> pairs) {
  for (final (before, after) in pairs) {
    final bad = _newRangeViolation(before, after);
    if (bad != null) d.reject(InvalidValue(bad));
  }
  d.replaceItems([for (final (_, after) in pairs) after]);
}

/// Visual media clips of [items] (video, image and still clips on video and overlay lanes).
List<_Loc> _visualClips(_Draft d, Iterable<ItemId> items) {
  final locs = _editableItems(d, items);
  for (final l in locs) {
    final i = l.item;
    if (i is SubtitleCue) d.reject(const UnsupportedForKind('subtitle'));
    if (i is TextItem) d.reject(const UnsupportedForKind('text'));
    if (i is MediaClip && i.visual == null) d.reject(const UnsupportedForKind('audioClip'));
  }
  return locs;
}

/// Checks a look: a bundled look needs a preset id, an imported one a LUT asset of the pool, and
/// the intensity must be in [0, 1].
void _requireLook(_Draft d, LookRef? look) {
  if (look == null) return;
  if (!(look.intensity >= 0 && look.intensity <= 1)) d.reject(InvalidValue(PropertyKeys.lookIntensity.id));
  switch (look) {
    case BuiltinLook(:final presetId):
      if (presetId.isEmpty) d.reject(const InvalidValue('look'));
    case ImportedLut(:final lut):
      final a = d.pool[lut];
      if (a == null || a.status is FailedStatus) d.reject(MediaUnavailable(lut));
      if (a.kind != MediaKind.lut) d.reject(const UnsupportedForKind('notLut'));
  }
}

// -------------------------------------------------------------------------------------------
// SetProperty
// -------------------------------------------------------------------------------------------

/// Sets property [key] of [items] to [value] (ARCH §7.2). Keyframe-aware: on an item whose channels
/// have keys it upserts a key at the quantized [at]; otherwise it sets the static value. All items
/// are edited as one outcome.
///
/// Rejections: `ItemNotFound`, `TrackLocked`, `UnsupportedForKind` (the property does not apply to
/// an item, or the media has no audio), `InvalidValue(key.id)` (value out of range),
/// `InvalidValue('items')` (none), `InvalidValue('at')` (a keyframed item and no `at`),
/// `NothingAtTime` (`at` outside a keyframed item).
final class SetProperty<T> extends EditCommand {
  /// Creates the command; [items] are de-duplicated and kept in order.
  SetProperty(Iterable<ItemId> items, this.key, this.value, {this.at}) : items = List.unmodifiable(items.toSet());

  /// The items to edit.
  final List<ItemId> items;

  /// The property.
  final PropertyKey<T> key;

  /// The new value (model units, see `PropertyKey`).
  final T value;

  /// Absolute timeline time of the key to write on keyframed channels (nearest frame).
  final TimeUs? at;

  @override
  String get label => 'Change ${key.displayName.toLowerCase()}';

  @override
  void _apply(_Draft d) {
    final locs = _editableItems(d, items);
    final k = key as PropertyKey<Object?>;
    _requireValue(d, k, value);
    final atQ = at == null ? null : d.rate.quantizeNearest(at!);
    final pairs = <(TimelineItem, TimelineItem)>[];
    for (final l in locs) {
      final item = l.item;
      _requireApplies(d, item, k);
      final keys = keyframesOf(item);
      final TimelineItem next;
      if (k.keyframable && KeyframeOps.isAnimated(keys, k)) {
        if (atQ == null) d.reject(const InvalidValue('at'));
        if (atQ < item.start || atQ >= item.end) d.reject(NothingAtTime(atQ));
        final Object? v = k.valueKind == PropertyValueKind.number && value is int ? (value as int).toDouble() : value;
        next = withKeyframes(item, KeyframeOps.setKey(keys, k, atQ - item.start, v as Object));
      } else {
        next = _writeStatic(d, item, k, value);
      }
      pairs.add((item, next));
    }
    _commitChecked(d, pairs);
  }

  @override
  String toString() => 'SetProperty(${key.id}, $items, $value, at: $at)';
}

// -------------------------------------------------------------------------------------------
// Whole-struct setters
// -------------------------------------------------------------------------------------------

/// Replaces the whole [VisualProps] of visual clips (the panels' "apply" and presets). Keyframes
/// are untouched: keyed channels keep animating.
///
/// Rejections: `ItemNotFound`, `TrackLocked`, `UnsupportedForKind` (audio clips, text, cues),
/// `InvalidValue(<property id>)` (a value out of range), `MediaUnavailable` / `UnsupportedForKind`
/// (an imported LUT that is not a LUT of the pool).
final class SetVisual extends EditCommand {
  /// Creates the command.
  SetVisual(Iterable<ItemId> items, this.visual) : items = List.unmodifiable(items.toSet());

  /// The clips.
  final List<ItemId> items;

  /// The new visual properties.
  final VisualProps visual;

  @override
  String get label => 'Change appearance';

  @override
  void _apply(_Draft d) {
    final locs = _visualClips(d, items);
    _requireLook(d, visual.look);
    if (visual.chroma.color < 0 || visual.chroma.color > 0xFFFFFF) d.reject(InvalidValue(PropertyKeys.chromaColor.id));
    _commitChecked(d, [for (final l in locs) (l.item, (l.item as MediaClip).copyWith(visual: visual))]);
  }

  @override
  String toString() => 'SetVisual($items)';
}

/// Replaces the [AudioProps] (volume, mute, fades) of clips with sound. Fades are fitted to the
/// grid and to half of each clip; volume keyframes are untouched.
///
/// Rejections: `ItemNotFound`, `TrackLocked`, `UnsupportedForKind` (text, cues, media without
/// audio), `InvalidValue('audio.volume')` (outside [0, 2]) and `InvalidValue('audio.fadeIn')` /
/// `('audio.fadeOut')` (negative).
final class SetAudio extends EditCommand {
  /// Creates the command.
  SetAudio(Iterable<ItemId> items, this.audio) : items = List.unmodifiable(items.toSet());

  /// The clips.
  final List<ItemId> items;

  /// The new audio properties.
  final AudioProps audio;

  @override
  String get label => 'Change audio';

  @override
  void _apply(_Draft d) {
    final locs = _editableItems(d, items);
    if (!PropertyKeys.volume.accepts(audio.volume)) d.reject(InvalidValue(PropertyKeys.volume.id));
    if (audio.fadeIn < 0) d.reject(InvalidValue(PropertyKeys.fadeIn.id));
    if (audio.fadeOut < 0) d.reject(InvalidValue(PropertyKeys.fadeOut.id));
    final pairs = <(TimelineItem, TimelineItem)>[];
    for (final l in locs) {
      final i = l.item;
      _requireApplies(d, i, PropertyKeys.volume);
      final c = i as MediaClip;
      pairs.add((c, c.copyWith(audio: _fitAudio(d, c, audio))));
    }
    _commitChecked(d, pairs);
  }

  @override
  String toString() => 'SetAudio($items, $audio)';
}

/// Sets the look (a bundled preset or an imported LUT, with intensity) of visual clips; null
/// removes it.
///
/// Rejections: `ItemNotFound`, `TrackLocked`, `UnsupportedForKind` (audio clips, text, cues; an
/// imported look whose asset is not a LUT), `InvalidValue('look.intensity')` (outside [0, 1]) or
/// `InvalidValue('look')` (empty preset id), `MediaUnavailable` (the LUT asset is missing).
final class SetLook extends EditCommand {
  /// Creates the command.
  SetLook(Iterable<ItemId> items, this.look) : items = List.unmodifiable(items.toSet());

  /// The clips.
  final List<ItemId> items;

  /// The look, or null for none.
  final LookRef? look;

  @override
  String get label => look == null ? 'Remove look' : 'Apply look';

  @override
  void _apply(_Draft d) {
    final locs = _visualClips(d, items);
    _requireLook(d, look);
    final pairs = <(TimelineItem, TimelineItem)>[];
    for (final l in locs) {
      final c = l.item as MediaClip;
      pairs.add((c, c.copyWith(visual: c.visual!.copyWith(look: look))));
    }
    _commitChecked(d, pairs);
  }

  @override
  String toString() => 'SetLook($items, $look)';
}

/// Sets the chroma key of visual clips.
///
/// Rejections: `ItemNotFound`, `TrackLocked`, `UnsupportedForKind` (audio clips, text, cues),
/// `InvalidValue(<property id>)` (similarity, smoothness or spill outside [0, 1]; colour outside
/// 0xRRGGBB).
final class SetChroma extends EditCommand {
  /// Creates the command.
  SetChroma(Iterable<ItemId> items, this.chroma) : items = List.unmodifiable(items.toSet());

  /// The clips.
  final List<ItemId> items;

  /// The chroma key.
  final ChromaKey chroma;

  @override
  String get label => 'Change chroma key';

  @override
  void _apply(_Draft d) {
    final locs = _visualClips(d, items);
    if (chroma.color < 0 || chroma.color > 0xFFFFFF) d.reject(InvalidValue(PropertyKeys.chromaColor.id));
    final pairs = <(TimelineItem, TimelineItem)>[];
    for (final l in locs) {
      final c = l.item as MediaClip;
      pairs.add((c, c.copyWith(visual: c.visual!.copyWith(chroma: chroma))));
    }
    _commitChecked(d, pairs);
  }

  @override
  String toString() => 'SetChroma($items, $chroma)';
}

/// Sets the mask of visual clips (shape, geometry, feather, opacity, invert).
///
/// Rejections: `ItemNotFound`, `TrackLocked`, `UnsupportedForKind` (audio clips, text, cues),
/// `InvalidValue(<property id>)` (a value outside its range).
final class SetMask extends EditCommand {
  /// Creates the command.
  SetMask(Iterable<ItemId> items, this.mask) : items = List.unmodifiable(items.toSet());

  /// The clips.
  final List<ItemId> items;

  /// The mask.
  final MaskSpec mask;

  @override
  String get label => 'Change mask';

  @override
  void _apply(_Draft d) {
    final locs = _visualClips(d, items);
    final pairs = <(TimelineItem, TimelineItem)>[];
    for (final l in locs) {
      final c = l.item as MediaClip;
      pairs.add((c, c.copyWith(visual: c.visual!.copyWith(mask: mask))));
    }
    _commitChecked(d, pairs);
  }

  @override
  String toString() => 'SetMask($items, $mask)';
}

/// Sets the crop rectangle of visual clips (not keyframable).
///
/// Rejections: `ItemNotFound`, `TrackLocked`, `UnsupportedForKind` (audio clips, text, cues),
/// `InvalidValue('visual.crop')` (outside [0, 1] or empty).
final class SetCrop extends EditCommand {
  /// Creates the command.
  SetCrop(Iterable<ItemId> items, this.crop) : items = List.unmodifiable(items.toSet());

  /// The clips.
  final List<ItemId> items;

  /// The crop.
  final CropRect crop;

  @override
  String get label => 'Crop';

  @override
  void _apply(_Draft d) {
    final locs = _visualClips(d, items);
    if (!PropertyKeys.crop.accepts(crop)) d.reject(InvalidValue(PropertyKeys.crop.id));
    final pairs = <(TimelineItem, TimelineItem)>[];
    for (final l in locs) {
      final c = l.item as MediaClip;
      pairs.add((c, c.copyWith(visual: c.visual!.copyWith(crop: crop))));
    }
    _commitChecked(d, pairs);
  }

  @override
  String toString() => 'SetCrop($items, $crop)';
}

/// Resets the placement of visual clips and text items to the identity transform (centred, scale 1,
/// no rotation, no flips, opaque) and clears every transform keyframe (position, scale, rotation,
/// opacity). Fit, crop and effects are untouched.
///
/// Rejections: `ItemNotFound`, `TrackLocked`, `UnsupportedForKind` (audio clips, cues).
final class ResetTransform extends EditCommand {
  /// Creates the command.
  ResetTransform(Iterable<ItemId> items) : items = List.unmodifiable(items.toSet());

  /// The items.
  final List<ItemId> items;

  @override
  String get label => 'Reset transform';

  static final List<PropertyKey<Object?>> _transformKeys = [
    PropertyKeys.position,
    PropertyKeys.scale,
    PropertyKeys.rotation,
    PropertyKeys.opacity,
  ];

  @override
  void _apply(_Draft d) {
    final locs = _editableItems(d, items);
    final out = <TimelineItem>[];
    for (final l in locs) {
      final i = l.item;
      if (i is SubtitleCue) d.reject(const UnsupportedForKind('subtitle'));
      if (i is MediaClip && i.visual == null) d.reject(const UnsupportedForKind('audioClip'));
      var keys = keyframesOf(i);
      for (final k in _transformKeys) {
        keys = KeyframeOps.clear(keys, k);
      }
      out.add(switch (i) {
        MediaClip(:final visual) =>
          i.copyWith(visual: visual!.copyWith(transform: Transform2D.identity), keyframes: keys),
        TextItem() => i.copyWith(transform: Transform2D.identity, keyframes: keys),
        SubtitleCue() => i,
      });
    }
    d.replaceItems(out);
  }

  @override
  String toString() => 'ResetTransform($items)';
}
