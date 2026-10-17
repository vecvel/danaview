// OWNER: CORE-13
//
// Keyframe commands (ARCH §6.7, domain.md §4.11 and §6.2): `AddKeyframe`, `RemoveKeyframe`,
// `MoveKeyframe`, `SetKeyframeValue` and `ClearKeyframes`. Shared helpers are in
// property_commands.dart.
//
// * A key is addressed by a `KeyframeRef(item, property id, item-local t)`. The property is a
//   registry id (`transform.position`; a channel id such as `transform.position.x` names its
//   property). Vec2 properties act on both channels at once.
// * Times are item-local µs measured from the item start and are put on the grid (nearest frame in
//   absolute time, `quantizeNearest(start + t) − start`). Keys a command writes must lie inside
//   `[0, duration)` (`InvalidValue('t')`); keys outside the range that trims left behind are kept
//   by the model but not editable here.
// * Properties that are not keyframable (chroma, look intensity, crop, flips, text style, fades,
//   mute) reject with `UnsupportedForKind('notKeyframable')`; an unknown id is
//   `InvalidValue('property')`; a key that is not there is `NothingAtTime`; a duplicate is
//   `KeyframeExists(t)`.
// * When the last key of a property is removed the property becomes static again at the value the
//   key held, so the picture does not jump.

part of '../edit_command.dart';

/// The keyframable property named by [id] (a property id or one of its channel ids).
PropertyKey<Object?> _keyframableKey(_Draft d, String id) {
  final k = PropertyKeys.lookup(id) ?? PropertyKeys.byChannel[id];
  if (k == null) d.reject(const InvalidValue('property'));
  if (!k.keyframable) d.reject(const UnsupportedForKind('notKeyframable'));
  return k;
}

/// [local] on the grid, as an item-local time.
TimeUs _gridLocal(_Draft d, TimelineItem item, TimeUs local) => d.rate.quantizeNearest(item.start + local) - item.start;

/// Local grid time of a key command, refusing times outside the item.
TimeUs _keyTime(_Draft d, TimelineItem item, TimeUs local) {
  final t = _gridLocal(d, item, local);
  if (t < 0 || t >= item.duration) d.reject(const InvalidValue('t'));
  return t;
}

/// The key value [v] normalized for [key] (ints become doubles); refuses wrong types and values
/// outside the property's range.
Object _keyValue(_Draft d, PropertyKey<Object?> key, Object? v) {
  final isVec = key.channels.length == 2;
  if (isVec ? v is! Vec2 : v is! num) d.reject(InvalidValue(key.id));
  final out = v is int ? v.toDouble() : v!;
  if (!key.accepts(out)) d.reject(InvalidValue(key.id));
  return out;
}

/// The located item of [ref] on an editable lane, with its property.
(_Loc, PropertyKey<Object?>) _keyTarget(_Draft d, KeyframeRef ref) {
  final loc = d.locate(ref.item);
  if (loc.track.locked) d.reject(TrackLocked(loc.track.id));
  final key = _keyframableKey(d, ref.property);
  _requireApplies(d, loc.item, key);
  return (loc, key);
}

/// Adds a key of [ref].property at [ref].t. [value] null uses the value the property has there
/// (the diamond button: "keyframe the current value"); the first key of a static property starts
/// its animation.
///
/// Rejections: `ItemNotFound`, `TrackLocked`, `UnsupportedForKind`, `InvalidValue('property')`,
/// `InvalidValue('t')` (outside the item), `InvalidValue(<property id>)` (wrong type or range),
/// `KeyframeExists(t)`.
final class AddKeyframe extends EditCommand {
  /// Creates the command.
  const AddKeyframe(this.ref, {this.value});

  /// Item, property and item-local time.
  final KeyframeRef ref;

  /// The key value (double, or `Vec2` for position and mask centre/size), or null for the current
  /// value at [KeyframeRef.t].
  final Object? value;

  @override
  String get label => 'Add keyframe';

  @override
  void _apply(_Draft d) {
    final (loc, key) = _keyTarget(d, ref);
    final item = loc.item;
    final t = _keyTime(d, item, ref.t);
    final keys = keyframesOf(item);
    if (KeyframeOps.hasKeyAt(keys, key, t)) d.reject(KeyframeExists(t));
    final v = _keyValue(d, key, value ?? evaluate<Object?>(item, key, t));
    d.replaceItems([withKeyframes(item, KeyframeOps.setKey(keys, key, t, v))]);
  }

  @override
  String toString() => 'AddKeyframe(${ref.item}, ${ref.property}, ${ref.t}, $value)';
}

/// Removes the key of [ref].property at [ref].t. The last key of a property leaves it static at
/// the value that key held.
///
/// Rejections: `ItemNotFound`, `TrackLocked`, `UnsupportedForKind`, `InvalidValue('property')`,
/// `NothingAtTime` (no key at that time).
final class RemoveKeyframe extends EditCommand {
  /// Creates the command.
  const RemoveKeyframe(this.ref);

  /// Item, property and item-local time of the key.
  final KeyframeRef ref;

  @override
  String get label => 'Remove keyframe';

  @override
  void _apply(_Draft d) {
    final (loc, key) = _keyTarget(d, ref);
    final item = loc.item;
    final t = _gridLocal(d, item, ref.t);
    final keys = keyframesOf(item);
    if (!KeyframeOps.hasKeyAt(keys, key, t)) d.reject(NothingAtTime(item.start + t));
    final held = evaluate<Object?>(item, key, t);
    final next = KeyframeOps.removeKey(keys, key, t);
    var out = withKeyframes(item, next);
    if (!KeyframeOps.isAnimated(next, key)) out = _writeStatic(d, out, key, held);
    d.replaceItems([out]);
  }

  @override
  String toString() => 'RemoveKeyframe(${ref.item}, ${ref.property}, ${ref.t})';
}

/// Moves the key of [ref].property from [ref].t to [to] (item-local). Other keys stay; keys keep
/// time order.
///
/// Rejections: `ItemNotFound`, `TrackLocked`, `UnsupportedForKind`, `InvalidValue('property')`,
/// `InvalidValue('t')` (target outside the item), `NothingAtTime` (no key at the source time),
/// `KeyframeExists(to)` (a key is already there).
final class MoveKeyframe extends EditCommand {
  /// Creates the command.
  const MoveKeyframe(this.ref, this.to);

  /// Item, property and the item-local time of the key to move.
  final KeyframeRef ref;

  /// The new item-local time.
  final TimeUs to;

  @override
  String get label => 'Move keyframe';

  @override
  void _apply(_Draft d) {
    final (loc, key) = _keyTarget(d, ref);
    final item = loc.item;
    final from = _gridLocal(d, item, ref.t);
    final keys = keyframesOf(item);
    if (!KeyframeOps.hasKeyAt(keys, key, from)) d.reject(NothingAtTime(item.start + from));
    final target = _keyTime(d, item, to);
    if (target == from) return;
    if (KeyframeOps.hasKeyAt(keys, key, target)) d.reject(KeyframeExists(target));
    d.replaceItems([withKeyframes(item, KeyframeOps.moveKey(keys, key, from, target))]);
  }

  @override
  String toString() => 'MoveKeyframe(${ref.item}, ${ref.property}, ${ref.t} -> $to)';
}

/// Sets the value of the existing key of [ref].property at [ref].t.
///
/// Rejections: `ItemNotFound`, `TrackLocked`, `UnsupportedForKind`, `InvalidValue('property')`,
/// `InvalidValue(<property id>)` (wrong type or range), `NothingAtTime` (no key at that time).
final class SetKeyframeValue extends EditCommand {
  /// Creates the command.
  const SetKeyframeValue(this.ref, this.value);

  /// Item, property and item-local time of the key.
  final KeyframeRef ref;

  /// The new value (double, or `Vec2` for position and mask centre/size).
  final Object value;

  @override
  String get label => 'Change keyframe';

  @override
  void _apply(_Draft d) {
    final (loc, key) = _keyTarget(d, ref);
    final item = loc.item;
    final t = _gridLocal(d, item, ref.t);
    final keys = keyframesOf(item);
    if (!KeyframeOps.hasKeyAt(keys, key, t)) d.reject(NothingAtTime(item.start + t));
    final v = _keyValue(d, key, value);
    d.replaceItems([withKeyframes(item, KeyframeOps.setKey(keys, key, t, v))]);
  }

  @override
  String toString() => 'SetKeyframeValue(${ref.item}, ${ref.property}, ${ref.t}, $value)';
}

/// Removes every key of [property] (all keyframable properties when null) from [items]. Items
/// without keys are left alone; nothing to clear is a no-op. With [at] each cleared property
/// becomes static at the value it had at that timeline time (so nothing jumps); without it the
/// static values stay as they were.
///
/// Rejections: `ItemNotFound`, `TrackLocked`, `UnsupportedForKind` (cues; a non-keyframable
/// property), `InvalidValue('property')`, `InvalidValue('items')`.
final class ClearKeyframes extends EditCommand {
  /// Creates the command.
  ClearKeyframes(Iterable<ItemId> items, {this.property, this.at}) : items = List.unmodifiable(items.toSet());

  /// The items.
  final List<ItemId> items;

  /// Property id to clear, or null for all properties.
  final String? property;

  /// Absolute timeline time whose values become the static ones (nearest frame).
  final TimeUs? at;

  @override
  String get label => 'Clear keyframes';

  @override
  void _apply(_Draft d) {
    final locs = _editableItems(d, items);
    final only = property == null ? null : _keyframableKey(d, property!);
    final atQ = at == null ? null : d.rate.quantizeNearest(at!);
    final out = <TimelineItem>[];
    for (final l in locs) {
      final item = l.item;
      if (item is SubtitleCue) d.reject(const UnsupportedForKind('subtitle'));
      if (only != null) _requireApplies(d, item, only);
      var keys = keyframesOf(item);
      if (keys.isEmpty) continue;
      var next = item;
      final targets = only != null
          ? [only]
          : [
              for (final k in PropertyKeys.keyframable)
                if (k.appliesToItem(item) && KeyframeOps.isAnimated(keys, k)) k,
            ];
      for (final k in targets) {
        if (!KeyframeOps.isAnimated(keys, k)) continue;
        if (atQ != null) next = _writeStatic(d, next, k, evaluate<Object?>(item, k, atQ - item.start));
        keys = KeyframeOps.clear(keys, k);
      }
      out.add(withKeyframes(next, keys));
    }
    d.replaceItems(out);
  }

  @override
  String toString() => 'ClearKeyframes($items, property: $property, at: $at)';
}
