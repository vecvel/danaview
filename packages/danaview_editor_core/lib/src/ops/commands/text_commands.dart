// OWNER: CORE-14
//
// Text commands (ARCH §6.6, §7.2, domain.md §4.8 and §6.2): `AddText`, `SetText`, `SetTextStyle`,
// `SetTextAnimation`. Transform edits of text items (position, scale, rotation, opacity and their
// keyframes) go through `SetProperty` / the keyframe commands (CORE-13); the helpers shared with
// those commands are in property_commands.dart.
//
// * **Lanes.** `AddText` puts the item on the **topmost free unlocked text lane** at its time
//   (text lanes never overlap, I2), or on a new text lane at the top of the text group when every
//   one is occupied (D-11); with `OverlapPolicy.reject` it refuses with `NoRoom` instead. An
//   explicit lane is used when it is free (D-11 fallback otherwise, `TrackLocked` when locked).
// * **Ranges.** Style values are checked against the registry ranges (font size 8–200,
//   letter spacing −20…100, line height 0.6–3, wrap width, box/stroke/shadow values) with the I6
//   range test; a violation is `InvalidValue(<property id>)`.
// * **Animations** keep their lengths on the grid and `in + out ≤ duration` per item (the in
//   animation has priority when both do not fit). Typewriter is an "in" animation only.
// * **Typing coalesces.** `SetText` is a [CoalescingCommand] with key `text:<item id>`: the session
//   (CORE-19) merges consecutive edits of one text into a single history entry.

part of '../edit_command.dart';

/// A command whose repeated application by one gesture merges into one history entry. The
/// session (CORE-19) applies commands with equal non-null [coalesceKey] inside its coalesce window
/// as one entry (`EditSession.apply(command, coalesceKey: command.coalesceKey)`).
abstract interface class CoalescingCommand {
  /// The merge key, or null when the command never coalesces.
  String? get coalesceKey;
}

/// The text items of [ids] on editable lanes.
List<_Loc> _textItems(_Draft d, Iterable<ItemId> ids) {
  final locs = _editableItems(d, ids);
  for (final l in locs) {
    final i = l.item;
    if (i is MediaClip) d.reject(const UnsupportedForKind('media'));
    if (i is SubtitleCue) d.reject(const UnsupportedForKind('subtitle'));
  }
  return locs;
}

bool _validArgb(int c) => c >= 0 && c <= 0xFFFFFFFF;

// -------------------------------------------------------------------------------------------
// AddText
// -------------------------------------------------------------------------------------------

/// Adds a text item at [at] (quantized to the nearest frame, ≥ 0) of [duration]
/// (`EditPolicy.defaultTextUs`, 3 s, by default), in [style] (Figtree 48 pt white, centred by
/// default). See the file header for the lane rules. Selects the new item.
///
/// Rejections: `EmptyText` (blank [text]), `InvalidValue('duration')`, `InvalidValue(<property id>)`
/// (style out of range), `ItemNotFound` / `IncompatibleTrack` / `TrackLocked` (an explicit
/// [track]), `NoRoom` (policy reject), `LimitExceeded`.
final class AddText extends EditCommand {
  /// Creates the command.
  const AddText(this.at, {this.text = placeholder, this.duration, this.style, this.track});

  /// The text a new item starts with when none is given.
  static const String placeholder = 'Text';

  /// Requested start.
  final TimeUs at;

  /// The text.
  final String text;

  /// Length, or null for the policy default.
  final TimeUs? duration;

  /// The style, or null for the default.
  final TextStyleSpec? style;

  /// The lane to prefer, or null for the topmost free text lane.
  final TrackId? track;

  @override
  String get label => 'Add text';

  @override
  void _apply(_Draft d) {
    if (text.trim().isEmpty) d.reject(const EmptyText());
    final length = duration ?? d.policy.defaultTextUs;
    if (length <= 0) d.reject(const InvalidValue('duration'));
    final k0 = d.frameOf(d.rate.quantizeNearest(at < 0 ? 0 : at));
    final frames = d.lengthFrames(length);
    final item = TextItem(
      id: d.ids.itemId(),
      start: d.timeOf(k0),
      duration: d.timeOf(k0 + frames) - d.timeOf(k0),
      text: text.replaceAll('\r\n', '\n'),
      style: style ?? const TextStyleSpec(),
    );
    final bad = outOfRangeProperties(item);
    if (bad.isNotEmpty) d.reject(InvalidValue(bad.first));
    if (!_validArgb(item.style.color)) d.reject(InvalidValue(PropertyKeys.textColor.id));
    if (item.style.fontFamily.isEmpty) d.reject(InvalidValue(PropertyKeys.fontFamily.id));

    final TrackId lane;
    final explicit = track;
    if (explicit != null) {
      final t = d.editableTrack(explicit);
      if (t.kind != TrackKind.text) d.reject(IncompatibleTrack(explicit));
      lane = d.placeGroup([item], kind: TrackKind.text, preferred: explicit);
    } else {
      TrackId? found;
      var anyLane = false;
      for (var i = d.tracks.length - 1; i >= 0; i--) {
        final t = d.tracks[i];
        if (t.kind != TrackKind.text) continue;
        anyLane = true;
        if (!t.locked && LanePlacement.isFree(t, [item.range])) {
          found = t.id;
          break;
        }
      }
      if (found == null) {
        if (anyLane && d.policy.overlap == OverlapPolicy.reject) d.reject(const NoRoom());
        found = d.createTrack(TrackKind.text);
      }
      d.addItems(found, [item]);
      lane = found;
    }
    d.selection = SelectionHint({item.id}, primary: item.id, lane: lane);
  }

  @override
  String toString() => 'AddText($at, text: $text, duration: $duration, track: $track)';
}

// -------------------------------------------------------------------------------------------
// SetText
// -------------------------------------------------------------------------------------------

/// Sets the content of a text item. Line endings are normalized to `\n`; the text is stored as
/// typed (only a blank text is refused). Coalesces per item (`text:<id>`).
///
/// Rejections: `ItemNotFound`, `TrackLocked`, `UnsupportedForKind` (clips; cues use `SetCueText`),
/// `EmptyText` (whitespace only).
final class SetText extends EditCommand implements CoalescingCommand {
  /// Creates the command.
  const SetText(this.item, this.text);

  /// The text item.
  final ItemId item;

  /// The new text.
  final String text;

  @override
  String get label => 'Edit text';

  @override
  String get coalesceKey => 'text:$item';

  @override
  void _apply(_Draft d) {
    final loc = _textItems(d, [item]).single;
    if (text.trim().isEmpty) d.reject(const EmptyText());
    d.replaceItems([(loc.item as TextItem).copyWith(text: text.replaceAll('\r\n', '\n'))]);
  }

  @override
  String toString() => 'SetText($item)';
}

// -------------------------------------------------------------------------------------------
// SetTextStyle
// -------------------------------------------------------------------------------------------

/// Changes the style of text items: only the given fields change (the box, stroke and shadow are
/// set with a value and removed with the matching `remove…` flag), or the whole style is replaced
/// with [SetTextStyle.replace] (copy a style to several items). All items are one outcome.
///
/// Ranges: font size [8, 200], letter spacing [−20, 100], line height [0.6, 3], wrap width, box
/// opacity/padding/radius, stroke width [0, 20], shadow opacity/blur [0, 40]/distance [0, 40].
///
/// Rejections: `ItemNotFound`, `TrackLocked`, `UnsupportedForKind` (clips, cues),
/// `InvalidValue(<property id>)` (out of range, empty font id, colour outside ARGB),
/// `InvalidValue('items')`.
final class SetTextStyle extends EditCommand {
  /// Creates a command changing the given fields of the style of [items].
  SetTextStyle(
    Iterable<ItemId> items, {
    this.fontFamily,
    this.fontSizePt,
    this.bold,
    this.italic,
    this.align,
    this.color,
    this.letterSpacing,
    this.lineHeight,
    this.maxWidth,
    this.background,
    this.removeBackground = false,
    this.stroke,
    this.removeStroke = false,
    this.shadow,
    this.removeShadow = false,
  })  : items = List.unmodifiable(items.toSet()),
        whole = null;

  /// Creates a command replacing the whole style of [items] with [style].
  SetTextStyle.replace(Iterable<ItemId> items, TextStyleSpec style)
      : items = List.unmodifiable(items.toSet()),
        whole = style,
        fontFamily = null,
        fontSizePt = null,
        bold = null,
        italic = null,
        align = null,
        color = null,
        letterSpacing = null,
        lineHeight = null,
        maxWidth = null,
        background = null,
        removeBackground = false,
        stroke = null,
        removeStroke = false,
        shadow = null,
        removeShadow = false;

  /// The text items.
  final List<ItemId> items;

  /// Content-font id (unknown ids fall back to Figtree when rendering).
  final String? fontFamily;

  /// Size in points at a 1,080 px short side.
  final double? fontSizePt;

  /// Bold.
  final bool? bold;

  /// Italic.
  final bool? italic;

  /// Line alignment.
  final TextAlignH? align;

  /// ARGB text colour.
  final int? color;

  /// Letter spacing in em/100.
  final double? letterSpacing;

  /// Line height multiplier.
  final double? lineHeight;

  /// Wrap width as a canvas-width fraction.
  final double? maxWidth;

  /// The background box to set.
  final BoxStyle? background;

  /// Removes the background box.
  final bool removeBackground;

  /// The outline to set.
  final StrokeStyle? stroke;

  /// Removes the outline.
  final bool removeStroke;

  /// The drop shadow to set.
  final ShadowStyle? shadow;

  /// Removes the drop shadow.
  final bool removeShadow;

  /// The replacement style of [SetTextStyle.replace], or null.
  final TextStyleSpec? whole;

  @override
  String get label => 'Change text style';

  TextStyleSpec _styled(TextStyleSpec s) {
    final w = whole;
    if (w != null) return w;
    return s.copyWith(
      fontFamily: fontFamily,
      fontSizePt: fontSizePt,
      bold: bold,
      italic: italic,
      align: align,
      color: color,
      letterSpacing: letterSpacing,
      lineHeight: lineHeight,
      maxWidth: maxWidth,
      background: removeBackground ? null : (background ?? s.background),
      stroke: removeStroke ? null : (stroke ?? s.stroke),
      shadow: removeShadow ? null : (shadow ?? s.shadow),
    );
  }

  @override
  void _apply(_Draft d) {
    final locs = _textItems(d, items);
    final pairs = <(TimelineItem, TimelineItem)>[];
    for (final l in locs) {
      final t = l.item as TextItem;
      final style = _styled(t.style);
      if (style.fontFamily.isEmpty) d.reject(InvalidValue(PropertyKeys.fontFamily.id));
      if (!_validArgb(style.color)) d.reject(InvalidValue(PropertyKeys.textColor.id));
      final bg = style.background;
      if (bg != null && !_validArgb(bg.color)) d.reject(InvalidValue(PropertyKeys.backgroundColor.id));
      final st = style.stroke;
      if (st != null && !_validArgb(st.color)) d.reject(InvalidValue(PropertyKeys.strokeColor.id));
      final sh = style.shadow;
      if (sh != null && !_validArgb(sh.color)) d.reject(InvalidValue(PropertyKeys.shadowColor.id));
      pairs.add((t, t.copyWith(style: style)));
    }
    _commitChecked(d, pairs);
  }

  @override
  String toString() => 'SetTextStyle($items${whole == null ? '' : ', replace'})';
}

// -------------------------------------------------------------------------------------------
// SetTextAnimation
// -------------------------------------------------------------------------------------------

/// Sets the in/out animation of text items. The lengths are put on the grid and limited per item so
/// `in + out ≤ duration` (the in animation keeps its length first); an animation of kind `none` has
/// length 0.
///
/// Rejections: `ItemNotFound`, `TrackLocked`, `UnsupportedForKind` (clips, cues),
/// `InvalidValue('outKind')` (typewriter is an "in" animation only),
/// `InvalidValue('inDuration')` / `('outDuration')` (negative), `InvalidValue('items')`.
final class SetTextAnimation extends EditCommand {
  /// Creates the command.
  SetTextAnimation(Iterable<ItemId> items, this.animation) : items = List.unmodifiable(items.toSet());

  /// The text items.
  final List<ItemId> items;

  /// The requested animation (lengths are fitted per item).
  final TextAnimation animation;

  @override
  String get label => 'Change text animation';

  @override
  void _apply(_Draft d) {
    final a = animation;
    if (a.outKind == TextAnimKind.typewriter) d.reject(const InvalidValue('outKind'));
    if (a.inDuration < 0) d.reject(const InvalidValue('inDuration'));
    if (a.outDuration < 0) d.reject(const InvalidValue('outDuration'));
    final locs = _textItems(d, items);
    d.replaceItems([
      for (final l in locs) (l.item as TextItem).copyWith(animation: _fitted(d, l.item as TextItem)),
    ]);
  }

  /// The requested animation with lengths on the grid and `in + out ≤ duration` for [item].
  TextAnimation _fitted(_Draft d, TextItem item) {
    final a = animation;
    final frames = d.framesOf(item);
    final k0 = d.frameOf(item.start);
    final k1 = d.frameOf(item.end);
    final wantIn = a.inKind == TextAnimKind.none ? 0 : a.inDuration;
    final wantOut = a.outKind == TextAnimKind.none ? 0 : a.outDuration;
    final nIn = wantIn == 0 ? 0 : (d.rate.frameIndexNearest(item.start + wantIn) - k0).clamp(0, frames);
    final nOut = wantOut == 0 ? 0 : (k1 - d.rate.frameIndexNearest(item.end - wantOut)).clamp(0, frames - nIn);
    return a.copyWith(
      inDuration: d.timeOf(k0 + nIn) - item.start,
      outDuration: item.end - d.timeOf(k1 - nOut),
    );
  }

  @override
  String toString() => 'SetTextAnimation($items)';
}
