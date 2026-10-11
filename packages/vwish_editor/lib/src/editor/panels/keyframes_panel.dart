// OWNER: UX-26
//
// The Keyframes panel (ux.md §10.11, §9.4) and the keyframe commands the panel and the keyframe
// actions share.
//
// * The list shows the animated properties of the item, grouped as Transform, Adjust, Mask and Audio.
//   Each property block has its name, the key count, the keyframe toggle (add or remove at the
//   playhead, ‹ › to jump to the previous or next key, `seekExact`), a menu with "Remove all
//   keyframes" and a key strip: the item's duration with one diamond per key. A tap selects a key
//   (`EditorController.selectKeyframe`, the same selection the timeline diamonds make); dragging a
//   diamond moves it, snapped to frames and to the playhead, as one `EditTransaction` (one history
//   entry, label "Move keyframe"). Assistive technology gets each diamond as a node with select and
//   frame-nudge actions.
// * The selected key opens a card under its property: time with -1 / +1 frame nudges (a MoveKeyframe
//   each, joined into one history entry while they come less than 500 ms apart), the value in
//   `InspectorNumberRow`s (SetKeyframeValue), the interpolation ("Linear", read-only in v1), "Jump
//   here" and "Delete keyframe".
// * "Animate a property" lists the properties that can be keyframed and adds the first key at the
//   playhead. The header's keyframe-all toggles a key on every animated property at the playhead;
//   the header's reset removes every key of the item (one entry; each property keeps the value it
//   has at the playhead).
// * Edits go through CORE-13 commands only: AddKeyframe, RemoveKeyframe, MoveKeyframe,
//   SetKeyframeValue, ClearKeyframes. Locked lanes and read-only projects disable every edit.
// * The panel owns its scrolling under the fixed header; nothing rebuilds per playback frame except
//   the strips' playhead marker (a repaint) and the keyframe toggles.

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vwish_editor_core/eval.dart' show evaluate;
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart'
    show AddKeyframe, ClearKeyframes, CompositeCommand, EditCommand, MoveKeyframe, RemoveKeyframe, SetKeyframeValue;
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../../app/strings/edit_strings.dart';
import '../../app/strings/keyframe_strings.dart';
import '../contracts/inspector_routes.dart';
import '../editor_scope.dart';
import '../inspector/inspector_header.dart';
import '../inspector/inspector_rows.dart';
import '../inspector/keyframe_toggle.dart';
import '../state/editor_controller.dart';

/// The groups of the Keyframes list (ux.md §10.11).
enum KeyframeGroup {
  /// Position, scale, rotation, opacity.
  transform,

  /// The light, colour and detail values.
  adjust,

  /// The mask values.
  mask,

  /// Volume.
  audio,
}

/// The pure part of the Keyframes panel: which properties are listed, grouped and addable, and the
/// commands the panel and the keyframe actions run.
abstract final class KeyframeCommands {
  /// The properties the "keyframe at playhead" action keys on an item that has none: the transform.
  static final List<PropertyKey<Object?>> defaultKeys = List.unmodifiable(<PropertyKey<Object?>>[
    PropertyKeys.position,
    PropertyKeys.scale,
    PropertyKeys.rotation,
    PropertyKeys.opacity,
  ]);

  /// The group [key] is listed under.
  static KeyframeGroup groupOf(PropertyKey<Object?> key) {
    final id = key.id;
    if (id.startsWith('mask.')) return KeyframeGroup.mask;
    if (id.startsWith('adjust.') || id.startsWith('detail.')) return KeyframeGroup.adjust;
    if (id.startsWith('audio.')) return KeyframeGroup.audio;
    return KeyframeGroup.transform;
  }

  /// The heading of [group].
  static String groupLabel(KeyframeGroup group) => switch (group) {
        KeyframeGroup.transform => KeyframeStrings.groupTransform,
        KeyframeGroup.adjust => KeyframeStrings.groupAdjust,
        KeyframeGroup.mask => KeyframeStrings.groupMask,
        KeyframeGroup.audio => KeyframeStrings.groupAudio,
      };

  /// The name of [key] in the list.
  static String labelOf(PropertyKey<Object?> key) => InspectorRowStrings.labelOf(key);

  /// The keyframable property named by [id] (a property id or one of its channel ids), or null.
  static PropertyKey<Object?>? resolve(String id) {
    final key = PropertyKeys.lookup(id) ?? PropertyKeys.byChannel[id];
    return key != null && key.keyframable ? key : null;
  }

  /// The item-local times of the keys of [key] that lie inside [item] (sorted).
  static List<TimeUs> timesOf(TimelineItem item, PropertyKey<Object?> key) =>
      [for (final t in KeyframeOps.keyTimes(keyframesOf(item), key)) if (t >= 0 && t < item.duration) t];

  /// The properties of [item] that have at least one key inside the item, in registry order.
  static List<PropertyKey<Object?>> animated(TimelineItem item) => [
        for (final k in PropertyKeys.keyframable)
          if (k.appliesToItem(item) && timesOf(item, k).isNotEmpty) k,
      ];

  /// The properties of [item] that can get a first key: they apply to the item, are not animated
  /// and (volume) the clip has sound.
  static List<PropertyKey<Object?>> addable(TimelineItem item, MediaPool pool) => [
        for (final k in PropertyKeys.keyframable)
          if (k.appliesToItem(item) && timesOf(item, k).isEmpty && _soundOk(item, k, pool)) k,
      ];

  static bool _soundOk(TimelineItem item, PropertyKey<Object?> key, MediaPool pool) {
    if (item is! MediaClip || !key.appliesTo.contains(ItemKindTag.audioClip)) return true;
    final asset = pool[item.media];
    if (asset == null) return true;
    return asset.kind == MediaKind.audio || asset.kind == MediaKind.recording || (asset.kind == MediaKind.video && asset.probe.hasAudio);
  }

  /// Whether the keyframe actions and the panel can edit [item]: a clip or a text.
  static bool animatable(TimelineItem? item) => item is MediaClip || item is TextItem;

  /// Adds a key to each of [keys] at absolute [at] that has none; when every one has a key there,
  /// removes them all. One command, one history entry.
  static EditCommand toggleAt(TimelineItem item, List<PropertyKey<Object?>> keys, TimeUs at, {String? label}) {
    final local = at - item.start;
    final set = keyframesOf(item);
    final remove = keys.isNotEmpty && keys.every((k) => KeyframeOps.hasKeyAt(set, k, local));
    if (remove) {
      return CompositeCommand(label ?? KeyframeStrings.historyRemoveKeys, [
        for (final k in keys) RemoveKeyframe(KeyframeRef(item.id, k.id, local)),
      ]);
    }
    return CompositeCommand(label ?? KeyframeStrings.historyKeyframeAll, [
      for (final k in keys)
        if (!KeyframeOps.hasKeyAt(set, k, local)) AddKeyframe(KeyframeRef(item.id, k.id, local)),
    ]);
  }

  /// What "Keyframe at playhead" keys on [item] at [at]: [selected] (the property of the selected
  /// key) when given, else the animated properties, else the transform (position, scale, rotation,
  /// opacity) or, for a clip with no picture, its volume.
  static List<PropertyKey<Object?>> atPlayheadKeys(TimelineItem item, MediaPool pool, {PropertyKey<Object?>? selected}) {
    if (selected != null && selected.appliesToItem(item)) return [selected];
    final animatedNow = animated(item);
    if (animatedNow.isNotEmpty) return animatedNow;
    final transform = [for (final k in defaultKeys) if (k.appliesToItem(item)) k];
    if (transform.isNotEmpty) return transform;
    return [
      for (final k in addable(item, pool))
        if (k.id == PropertyKeys.volume.id) k,
    ];
  }

  /// The "Keyframe at playhead" command: one history entry.
  static EditCommand atPlayhead(TimelineItem item, MediaPool pool, TimeUs at, {PropertyKey<Object?>? selected}) =>
      toggleAt(item, atPlayheadKeys(item, pool, selected: selected), at, label: KeyframeStrings.historyAtPlayhead);

  /// Removes every key of [item]; each property keeps the value it has at absolute [at].
  static EditCommand removeAll(TimelineItem item, TimeUs at) =>
      CompositeCommand(KeyframeStrings.historyRemoveAll, [ClearKeyframes([item.id], at: at)]);

  /// The state of the header's keyframe-all over [keys] at absolute [playhead]: at the playhead when
  /// every property has a key there, animated when any has keys, else static.
  static KeyframeStatus aggregateStatus(TimelineItem item, List<PropertyKey<Object?>> keys, TimeUs playhead) {
    var at = 0;
    var animatedCount = 0;
    var enabled = true;
    for (final k in keys) {
      final s = KeyframeStatus.of(item, k, playhead);
      enabled = s.enabled;
      if (s.state == KeyframeToggleState.atPlayhead) at++;
      if (s.animated) animatedCount++;
    }
    if (keys.isNotEmpty && at == keys.length) return KeyframeStatus(KeyframeToggleState.atPlayhead, enabled: enabled);
    if (animatedCount > 0) return KeyframeStatus(KeyframeToggleState.animated, enabled: enabled);
    return KeyframeStatus(KeyframeToggleState.none, enabled: enabled);
  }

  /// [local] on the project grid, as an item-local time (the form commands store).
  static TimeUs gridLocal(TimelineItem item, FrameRate rate, TimeUs local) => rate.quantizeNearest(item.start + local) - item.start;

  /// The last item-local time a key can sit at: the item's last frame.
  static TimeUs lastKeyTime(TimelineItem item, FrameRate rate) {
    final last = gridLocal(item, rate, item.duration - 1);
    return last >= item.duration ? last - rate.frameUs : last;
  }

  /// The item-local time [frames] frames from the key at [local] (null when it falls outside the item).
  static TimeUs? nudged(TimelineItem item, FrameRate rate, TimeUs local, int frames) {
    final k = rate.frameIndexNearest(item.start + local);
    final t = rate.timeOfFrame(k + frames) - item.start;
    return t < 0 || t >= item.duration ? null : t;
  }
}

/// The key of [property] at item-local [t] as the commands address it.
KeyframeRef _ref(ItemId item, PropertyKey<Object?> property, TimeUs t) => KeyframeRef(item, property.id, t);

// -------------------------------------------------------------------------------------------------
// Styles
// -------------------------------------------------------------------------------------------------

TextStyle get _bodyStyle => VwishTextStyles.body.copyWith(fontFamily: VwishFonts.family);
TextStyle get _captionStyle => VwishTextStyles.caption.copyWith(fontFamily: VwishFonts.family, color: VwishColors.textMuted);
TextStyle get _groupStyle => VwishTextStyles.label.copyWith(fontFamily: VwishFonts.family, color: VwishColors.textSecondary);
TextStyle get _timeStyle => VwishTextStyles.body.copyWith(
      fontFamily: VwishFonts.family,
      fontWeight: FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

// -------------------------------------------------------------------------------------------------
// The key strip
// -------------------------------------------------------------------------------------------------

/// The duration of an item with one diamond per key (ux.md §10.11). Presentational: a tap selects a
/// diamond, a horizontal drag moves it (snapped to frames and to the playhead).
class KeyframeStrip extends StatefulWidget {
  /// Creates the strip.
  const KeyframeStrip({
    super.key,
    required this.label,
    required this.times,
    required this.duration,
    required this.itemStart,
    required this.playhead,
    required this.quantize,
    required this.maxTime,
    required this.timeLabel,
    required this.valueLabel,
    this.selected,
    this.enabled = true,
    this.onSelect,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.onNudge,
  });

  /// Space kept at both ends so the first and last diamond are fully visible.
  static const double pad = 16;

  /// Height of the strip (a 44 px touch target).
  static const double height = 44;

  /// Distance within which a pointer picks a diamond.
  static const double hitSlop = 24;

  /// Distance within which a dragged diamond snaps to the playhead.
  static const double snapSlop = 8;

  /// Where a key at item-local [t] sits in a strip [width] wide for an item of [duration].
  static double xOf(double width, TimeUs t, TimeUs duration) =>
      pad + (duration <= 0 ? 0 : t / duration) * math.max(1.0, width - 2 * pad);

  /// Name of the property (semantics).
  final String label;

  /// The keys, item-local, sorted, inside the item.
  final List<TimeUs> times;

  /// The item's duration.
  final TimeUs duration;

  /// The item's start (the playhead is absolute).
  final TimeUs itemStart;

  /// The playhead (absolute).
  final ValueListenable<TimeUs> playhead;

  /// Puts an item-local time on the grid.
  final TimeUs Function(TimeUs local) quantize;

  /// The last item-local time a key can sit at.
  final TimeUs maxTime;

  /// The time of a key as text.
  final String Function(TimeUs local) timeLabel;

  /// The value of a key as text.
  final String Function(TimeUs local) valueLabel;

  /// The selected key.
  final TimeUs? selected;

  /// Whether keys can be moved.
  final bool enabled;

  /// A diamond was tapped.
  final ValueChanged<TimeUs>? onSelect;

  /// A drag starts on the key at the time.
  final ValueChanged<TimeUs>? onDragStart;

  /// The dragged key (from, to) is now at [to].
  final void Function(TimeUs from, TimeUs to)? onDragUpdate;

  /// The drag ended with the key at [to] (equal to [from] when it did not move).
  final void Function(TimeUs from, TimeUs to)? onDragEnd;

  /// The semantics action moved the key at the time by one frame (-1 earlier, 1 later).
  final void Function(TimeUs t, int frames)? onNudge;

  @override
  State<KeyframeStrip> createState() => _KeyframeStripState();
}

class _KeyframeStripState extends State<KeyframeStrip> {
  TimeUs? _from;
  TimeUs? _to;

  List<TimeUs> get _shown => _from == null ? widget.times : [for (final t in widget.times) t == _from ? _to! : t];

  TimeUs? get _selected => _from != null && widget.selected == _from ? _to : widget.selected;

  TimeUs _timeAt(double x, double width) {
    final usable = math.max(1.0, width - 2 * KeyframeStrip.pad);
    final raw = (((x - KeyframeStrip.pad) / usable) * widget.duration).round();
    return raw.clamp(0, math.max(0, widget.duration - 1));
  }

  TimeUs? _nearest(double x, double width) {
    TimeUs? best;
    var bestDistance = double.infinity;
    for (final t in widget.times) {
      final d = (KeyframeStrip.xOf(width, t, widget.duration) - x).abs();
      if (d <= KeyframeStrip.hitSlop && d < bestDistance) {
        best = t;
        bestDistance = d;
      }
    }
    return best;
  }

  void _tap(Offset p, double width) {
    final t = _nearest(p.dx, width);
    if (t != null) widget.onSelect?.call(t);
  }

  void _dragStart(Offset p, double width) {
    if (!widget.enabled) return;
    final t = _nearest(p.dx, width);
    if (t == null) return;
    _from = t;
    _to = t;
    widget.onDragStart?.call(t);
  }

  void _dragUpdate(Offset p, double width) {
    final from = _from;
    if (from == null) return;
    var to = widget.quantize(_timeAt(p.dx, width)).clamp(0, widget.maxTime);
    final head = widget.playhead.value - widget.itemStart;
    if (head >= 0 && head < widget.duration) {
      final headKey = widget.quantize(head);
      if ((KeyframeStrip.xOf(width, headKey, widget.duration) - p.dx).abs() <= KeyframeStrip.snapSlop) to = headKey;
    }
    // Another key of the property is already there: the diamond stays where it was.
    if (to != from && widget.times.contains(to)) return;
    if (to == _to) return;
    setState(() => _to = to);
    widget.onDragUpdate?.call(from, to);
  }

  void _dragEnd() {
    final from = _from;
    final to = _to;
    if (from == null || to == null) return;
    setState(() {
      _from = null;
      _to = null;
    });
    widget.onDragEnd?.call(from, to);
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    final selected = _selected;
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth.isFinite ? constraints.maxWidth : 280.0;
      return Semantics(
        container: true,
        label: KeyframeStrings.stripLabel(widget.label),
        hint: KeyframeStrings.stripHint,
        child: SizedBox(
          height: KeyframeStrip.height,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => _tap(d.localPosition, width),
            onHorizontalDragStart: widget.enabled ? (d) => _dragStart(d.localPosition, width) : null,
            onHorizontalDragUpdate: widget.enabled ? (d) => _dragUpdate(d.localPosition, width) : null,
            onHorizontalDragEnd: widget.enabled ? (_) => _dragEnd() : null,
            onHorizontalDragCancel: widget.enabled ? _dragEnd : null,
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _StripPainter(
                      times: shown,
                      selected: selected,
                      duration: widget.duration,
                      itemStart: widget.itemStart,
                      playhead: widget.playhead,
                      enabled: widget.enabled,
                    ),
                  ),
                ),
                for (final t in shown)
                  Positioned(
                    left: KeyframeStrip.xOf(width, t, widget.duration) - KeyframeStrip.hitSlop / 2,
                    top: 0,
                    width: KeyframeStrip.hitSlop,
                    height: KeyframeStrip.height,
                    child: IgnorePointer(
                      child: Semantics(
                        container: true,
                        button: true,
                        selected: t == selected,
                        label: KeyframeStrings.diamondLabel(widget.label, widget.timeLabel(t)),
                        value: KeyframeStrings.diamondValue(widget.valueLabel(t)),
                        onTap: widget.onSelect == null ? null : () => widget.onSelect!(t),
                        onIncrease: widget.enabled && widget.onNudge != null ? () => widget.onNudge!(t, 1) : null,
                        onDecrease: widget.enabled && widget.onNudge != null ? () => widget.onNudge!(t, -1) : null,
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    });
  }
}

class _StripPainter extends CustomPainter {
  _StripPainter({
    required this.times,
    required this.selected,
    required this.duration,
    required this.itemStart,
    required this.playhead,
    required this.enabled,
  }) : super(repaint: playhead);

  final List<TimeUs> times;
  final TimeUs? selected;
  final TimeUs duration;
  final TimeUs itemStart;
  final ValueListenable<TimeUs> playhead;
  final bool enabled;

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final left = KeyframeStrip.pad;
    final right = size.width - KeyframeStrip.pad;
    canvas.drawRRect(
      RRect.fromLTRBR(left, cy - 1.5, math.max(left, right), cy + 1.5, const Radius.circular(1.5)),
      Paint()..color = VwishColors.trackBackground,
    );
    final head = playhead.value - itemStart;
    final headInside = head >= 0 && head < duration;
    if (headInside) {
      final x = KeyframeStrip.xOf(size.width, head, duration);
      canvas.drawRRect(
        RRect.fromLTRBR(x - 1, 6, x + 1, size.height - 6, const Radius.circular(1)),
        Paint()..color = VwishColors.primaryLight.withValues(alpha: 0.7),
      );
    }
    for (final t in times) {
      final x = KeyframeStrip.xOf(size.width, t, duration);
      final isSelected = t == selected;
      final atHead = headInside && t == head;
      final r = isSelected ? 8.5 : 7.0;
      final path = Path()
        ..moveTo(x, cy - r)
        ..lineTo(x + r, cy)
        ..lineTo(x, cy + r)
        ..lineTo(x - r, cy)
        ..close();
      final color = enabled ? VwishColors.primaryLight : VwishColors.disabled(VwishColors.primaryLight);
      if (isSelected) {
        canvas.drawPath(path, Paint()..color = VwishColors.primary);
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..strokeJoin = StrokeJoin.round
            ..color = color,
        );
      } else if (atHead) {
        canvas.drawPath(path, Paint()..color = color);
      } else {
        canvas.drawPath(path, Paint()..color = VwishColors.surfaceElevated);
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..strokeJoin = StrokeJoin.round
            ..color = color,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_StripPainter old) =>
      old.times != times ||
      old.selected != selected ||
      old.duration != duration ||
      old.itemStart != itemStart ||
      old.enabled != enabled ||
      old.playhead != playhead;
}

// -------------------------------------------------------------------------------------------------
// The panel
// -------------------------------------------------------------------------------------------------

/// The keyframes panel (ux.md §10.11).
class KeyframesPanel extends ConsumerStatefulWidget {
  /// Creates the panel.
  const KeyframesPanel({super.key, required this.route});

  /// What the panel edits.
  final KeyframesInspector route;

  @override
  ConsumerState<KeyframesPanel> createState() => _KeyframesPanelState();
}

class _KeyframesPanelState extends ConsumerState<KeyframesPanel> {
  EditorController get _editor => ref.read(editorControllerProvider(EditorScope.idOf(context)).notifier);

  TimelineItem? _item() {
    final item = ref.read(editorControllerProvider(EditorScope.idOf(context))).project?.index.item(widget.route.item);
    return KeyframeCommands.animatable(item) ? item : null;
  }

  TimeUs _playhead() => ref.read(playheadProvider(EditorScope.idOf(context))).value;

  void _removeAll() {
    final item = _item();
    if (item == null) return;
    final result = _editor.apply(KeyframeCommands.removeAll(item, _playhead()));
    if (result.applied && mounted) VwishToast.show(context, KeyframeStrings.removedAll, icon: Icons.check_circle_outline_rounded);
  }

  void _keyframeAll() {
    final item = _item();
    if (item == null) return;
    final keys = KeyframeCommands.animated(item);
    if (keys.isEmpty) return;
    _editor.apply(KeyframeCommands.toggleAt(item, keys, _playhead()));
  }

  @override
  Widget build(BuildContext context) {
    final id = EditorScope.idOf(context);
    final item = ref.watch(editorControllerProvider(id).select((s) => s.project?.index.item(widget.route.item)));
    if (item == null || !KeyframeCommands.animatable(item)) return const SizedBox.shrink();
    final locked = ref.watch(editorControllerProvider(id).select((s) => s.project?.index.locate(widget.route.item)?.track.locked ?? false));
    final ready = ref.watch(editorControllerProvider(id).select((s) => s.isReady));
    final playhead = ref.watch(playheadProvider(id));
    final animated = KeyframeCommands.animated(item);
    final editable = ready && !locked;
    // The header's keyframe-all follows the playhead; the body (the child) does not rebuild with it.
    return ValueListenableBuilder<TimeUs>(
      valueListenable: playhead,
      child: _KeyframesBody(item: item, editable: editable, locked: locked, onRemoveAll: _removeAll),
      builder: (context, t, body) => InspectorHeaderActions.publish(
        actions: InspectorHeaderActions(
          onReset: animated.isEmpty || !editable ? null : _removeAll,
          resetRemovesKeyframes: animated.isNotEmpty,
          keyframeAll: animated.isEmpty ? null : KeyframeCommands.aggregateStatus(item, animated, t),
          onKeyframeAll: animated.isEmpty || !editable ? null : _keyframeAll,
        ),
        child: body!,
      ),
    );
  }
}

class _KeyframesBody extends ConsumerWidget {
  const _KeyframesBody({required this.item, required this.editable, required this.locked, required this.onRemoveAll});

  final TimelineItem item;
  final bool editable;
  final bool locked;
  final VoidCallback onRemoveAll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = EditorScope.idOf(context);
    final pool = ref.watch(editorControllerProvider(id).select((s) => s.project?.pool)) ?? MediaPool.empty;
    final animated = KeyframeCommands.animated(item);
    final addable = KeyframeCommands.addable(item, pool);
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(VwishSpacing.lg, VwishSpacing.sm, VwishSpacing.lg, VwishSpacing.lg),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (locked)
                  Padding(
                    padding: const EdgeInsets.only(bottom: VwishSpacing.xs),
                    child: Text(KeyframeStrings.trackLocked, style: _captionStyle.copyWith(color: VwishColors.warning)),
                  ),
                if (animated.isEmpty) const _EmptyNote(),
                for (final group in KeyframeGroup.values)
                  ..._group(group, [for (final k in animated) if (KeyframeCommands.groupOf(k) == group) k]),
                if (addable.isNotEmpty) _AddArea(item: item, addable: addable, enabled: editable),
                if (animated.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: VwishSpacing.md),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: VwishButton.ghost(
                        key: const ValueKey<String>('kf.removeAll'),
                        label: KeyframeStrings.removeAll,
                        icon: Icons.delete_outline_rounded,
                        onPressed: editable ? onRemoveAll : null,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _group(KeyframeGroup group, List<PropertyKey<Object?>> keys) {
    if (keys.isEmpty) return const [];
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(VwishSpacing.xs, VwishSpacing.md, VwishSpacing.xs, VwishSpacing.xs),
        child: Semantics(
          header: true,
          child: Text(KeyframeCommands.groupLabel(group), maxLines: 1, overflow: TextOverflow.ellipsis, style: _groupStyle),
        ),
      ),
      for (final k in keys)
        Padding(
          padding: const EdgeInsets.only(bottom: VwishSpacing.sm),
          child: _PropertyBlock(key: ValueKey<String>('kf.block.${k.id}'), itemId: item.id, property: k, editable: editable),
        ),
    ];
  }
}

class _EmptyNote extends StatelessWidget {
  const _EmptyNote();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: VwishSpacing.md, horizontal: VwishSpacing.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(header: true, child: Text(KeyframeStrings.emptyTitle, style: _bodyStyle.copyWith(fontWeight: FontWeight.w600))),
            const SizedBox(height: VwishSpacing.xs),
            Text(KeyframeStrings.emptyBody, style: _captionStyle),
          ],
        ),
      );
}

// -------------------------------------------------------------------------------------------------
// "Animate a property"
// -------------------------------------------------------------------------------------------------

class _AddArea extends ConsumerWidget {
  const _AddArea({required this.item, required this.addable, required this.enabled});

  final TimelineItem item;
  final List<PropertyKey<Object?>> addable;
  final bool enabled;

  void _add(WidgetRef ref, BuildContext context, PropertyKey<Object?> key) {
    final id = EditorScope.idOf(context);
    final editor = ref.read(editorControllerProvider(id).notifier);
    final playhead = ref.read(playheadProvider(id)).value;
    final local = playhead - item.start;
    final result = editor.apply(AddKeyframe(KeyframeRef(item.id, key.id, local)));
    if (result.applied) {
      final rate = ref.read(editorControllerProvider(id)).project?.settings.frameRate;
      editor.selectKeyframe(_ref(item.id, key, rate == null ? local : KeyframeCommands.gridLocal(item, rate, local)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = EditorScope.idOf(context);
    final playhead = ref.watch(playheadProvider(id));
    return Padding(
      padding: const EdgeInsets.only(top: VwishSpacing.md),
      child: ValueListenableBuilder<TimeUs>(
        valueListenable: playhead,
        builder: (context, t, _) {
          final inside = t >= item.start && t < item.end;
          final canAdd = enabled && inside;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(VwishSpacing.xs, 0, VwishSpacing.xs, VwishSpacing.xs),
                child: Semantics(header: true, child: Text(KeyframeStrings.addTitle, style: _groupStyle)),
              ),
              VwishMenuAnchor(
                width: 240,
                alignment: VwishMenuAlignment.start,
                entries: [
                  for (final group in KeyframeGroup.values) ...[
                    if (addable.any((k) => KeyframeCommands.groupOf(k) == group)) VwishMenuHeader(KeyframeCommands.groupLabel(group)),
                    for (final k in addable)
                      if (KeyframeCommands.groupOf(k) == group) VwishMenuItem(label: KeyframeCommands.labelOf(k), onTap: () => _add(ref, context, k)),
                  ],
                ],
                builder: (context, open, isOpen) => VwishButton.secondary(
                  key: const ValueKey<String>('kf.add'),
                  label: KeyframeStrings.addButton,
                  icon: Icons.add_rounded,
                  onPressed: canAdd ? open : null,
                ),
              ),
              if (!inside)
                Padding(
                  padding: const EdgeInsets.only(top: VwishSpacing.xs, left: VwishSpacing.xs),
                  child: Text(KeyframeStrings.outsideItem, style: _captionStyle),
                ),
            ],
          );
        },
      ),
    );
  }
}

// -------------------------------------------------------------------------------------------------
// One property
// -------------------------------------------------------------------------------------------------

class _PropertyBlock extends ConsumerStatefulWidget {
  const _PropertyBlock({super.key, required this.itemId, required this.property, required this.editable});

  final ItemId itemId;
  final PropertyKey<Object?> property;
  final bool editable;

  @override
  ConsumerState<_PropertyBlock> createState() => _PropertyBlockState();
}

class _PropertyBlockState extends ConsumerState<_PropertyBlock> {
  InspectorEditSession? _nudgeSession;
  InspectorEditSession? _valueSession;
  EditTransaction? _tx;

  @override
  void dispose() {
    _nudgeSession?.dispose();
    _valueSession?.dispose();
    final tx = _tx;
    if (tx != null && tx.isOpen) tx.commit();
    super.dispose();
  }

  EditorController get _editor => ref.read(editorControllerProvider(EditorScope.idOf(context)).notifier);

  TimelineItem? get _item => ref.read(editorControllerProvider(EditorScope.idOf(context))).project?.index.item(widget.itemId);

  FrameRate get _rate => ref.read(editorControllerProvider(EditorScope.idOf(context))).project?.settings.frameRate ?? FrameRate.fps30;

  InspectorEditSession _session(bool nudge) {
    final editor = _editor;
    final key = widget.property;
    if (nudge) {
      return (_nudgeSession ??=
          InspectorEditSession(editor: editor, label: KeyframeStrings.historyNudge, coalesceKey: 'kf.nudge:${widget.itemId}:${key.id}'))
        ..editor = editor;
    }
    return (_valueSession ??=
        InspectorEditSession(editor: editor, label: KeyframeStrings.historyValue, coalesceKey: 'kf.value:${widget.itemId}:${key.id}'))
      ..editor = editor;
  }

  // ---- Selection ---------------------------------------------------------------------------------

  void _select(TimeUs t) => _editor.selectKeyframe(_ref(widget.itemId, widget.property, t));

  void _seek(TimeUs local) {
    final item = _item;
    if (item == null) return;
    ref.read(playheadProvider(EditorScope.idOf(context))).seekExact(item.start + local);
  }

  // ---- Drag --------------------------------------------------------------------------------------

  void _dragStart(TimeUs t) {
    _select(t);
  }

  void _dragUpdate(TimeUs from, TimeUs to) {
    if (from == to) {
      _tx?.cancel();
      _tx = null;
      return;
    }
    var tx = _tx;
    if (tx == null || !tx.isOpen) tx = _tx = _editor.beginTransaction(EditStrings.moveKeyframe);
    tx.update(MoveKeyframe(_ref(widget.itemId, widget.property, from), to));
  }

  void _dragEnd(TimeUs from, TimeUs to) {
    final tx = _tx;
    _tx = null;
    if (tx == null) return;
    if (!tx.isOpen) return;
    if (from == to) {
      tx.cancel();
      return;
    }
    final result = tx.commit();
    if (result.applied) _select(to);
  }

  // ---- Selected key ------------------------------------------------------------------------------

  void _nudge(TimeUs t, int frames) {
    final item = _item;
    if (item == null || !widget.editable) return;
    final to = KeyframeCommands.nudged(item, _rate, t, frames);
    if (to == null || KeyframeCommands.timesOf(item, widget.property).contains(to)) return;
    final session = _session(true);
    session.step(MoveKeyframe(_ref(widget.itemId, widget.property, t), to));
    _select(to);
  }

  void _setValue(TimeUs t, Object value) {
    final key = widget.property;
    final session = _session(false);
    final Object clamped = key.clamp(value) as Object;
    session.step(SetKeyframeValue(_ref(widget.itemId, key, t), clamped));
  }

  void _delete(TimeUs t) {
    final result = _editor.apply(RemoveKeyframe(_ref(widget.itemId, widget.property, t)));
    if (result.applied) _editor.select(widget.itemId);
  }

  void _removeAllOfProperty() {
    final item = _item;
    if (item == null) return;
    final playhead = ref.read(playheadProvider(EditorScope.idOf(context))).value;
    _editor.apply(ClearKeyframes([item.id], property: widget.property.id, at: playhead));
  }

  // ---- Build -------------------------------------------------------------------------------------

  String _valueText(Object? value) {
    final key = widget.property;
    final digits = InspectorRows.digitsFor(key.step * key.displayScale);
    String one(double v) => InspectorRows.format(v, displayScale: key.displayScale, fractionDigits: digits, unit: key.unit);
    if (value is Vec2) return '${one(value.x)}, ${one(value.y)}';
    if (value is num) return one(value.toDouble());
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final id = EditorScope.idOf(context);
    final item = ref.watch(editorControllerProvider(id).select((s) => s.project?.index.item(widget.itemId)));
    final selection = ref.watch(editorControllerProvider(id).select((s) => s.selection.keyframe));
    final rate = ref.watch(editorControllerProvider(id).select((s) => s.project?.settings.frameRate)) ?? FrameRate.fps30;
    final playhead = ref.watch(playheadProvider(id));
    final key = widget.property;
    if (item == null || !key.appliesToItem(item)) return const SizedBox.shrink();
    final times = KeyframeCommands.timesOf(item, key);
    if (times.isEmpty) return const SizedBox.shrink();
    final label = KeyframeCommands.labelOf(key);

    // The selected key of this property, matched on the grid (the timeline's refs carry the stored time).
    TimeUs? selectedT;
    if (selection != null && selection.item == item.id && KeyframeCommands.resolve(selection.property)?.id == key.id) {
      final want = KeyframeCommands.gridLocal(item, rate, selection.t);
      for (final t in times) {
        if (KeyframeCommands.gridLocal(item, rate, t) == want) selectedT = t;
      }
    }

    return VwishSurface(
      color: VwishColors.surfaceElevated,
      borderRadius: VwishRadius.mdAll,
      padding: const EdgeInsets.fromLTRB(VwishSpacing.md, VwishSpacing.sm, VwishSpacing.xs, VwishSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: _bodyStyle.copyWith(fontWeight: FontWeight.w600))),
              VwishMenuIconTrigger(
                key: ValueKey<String>('kf.menu.${key.id}'),
                icon: Icons.more_horiz_rounded,
                size: 32,
                iconSize: 20,
                tooltip: KeyframeStrings.rowMenu,
                semanticLabel: '$label, ${KeyframeStrings.rowMenu}',
                color: VwishColors.textSecondary,
                enabled: widget.editable,
                entries: [
                  VwishMenuItem(
                    label: KeyframeStrings.removeAllOfProperty,
                    icon: Icons.delete_outline_rounded,
                    destructive: true,
                    onTap: _removeAllOfProperty,
                  ),
                ],
              ),
            ],
          ),
          Row(
            children: [
              Expanded(child: Text(KeyframeStrings.count(times.length), style: _captionStyle)),
              PropertyKeyframeToggle(key: ValueKey<String>('kf.toggle.${key.id}'), item: item.id, property: key, label: label),
              const SizedBox(width: VwishSpacing.xs),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: VwishSpacing.sm),
            child: KeyframeStrip(
              key: ValueKey<String>('kf.strip.${key.id}'),
              label: label,
              times: times,
              duration: item.duration,
              itemStart: item.start,
              playhead: playhead,
              quantize: (t) => KeyframeCommands.gridLocal(item, rate, t),
              maxTime: KeyframeCommands.lastKeyTime(item, rate),
              timeLabel: (t) => Timecode.format(KeyframeCommands.gridLocal(item, rate, t), rate),
              valueLabel: (t) => _valueText(evaluate<Object?>(item, key, t)),
              selected: selectedT,
              enabled: widget.editable,
              onSelect: _select,
              onDragStart: _dragStart,
              onDragUpdate: _dragUpdate,
              onDragEnd: _dragEnd,
              onNudge: _nudge,
            ),
          ),
          if (selectedT != null)
            Padding(
              padding: const EdgeInsets.only(right: VwishSpacing.sm, top: VwishSpacing.xs),
              child: _SelectedKeyframe(
                key: ValueKey<String>('kf.selected.${key.id}'),
                item: item,
                property: key,
                label: label,
                t: selectedT,
                index: times.indexOf(selectedT) + 1,
                total: times.length,
                rate: rate,
                editable: widget.editable,
                onNudge: (frames) => _nudge(selectedT!, frames),
                onJump: () => _seek(selectedT!),
                onDelete: () => _delete(selectedT!),
                onValue: (v) => _setValue(selectedT!, v),
              ),
            ),
        ],
      ),
    );
  }
}

// -------------------------------------------------------------------------------------------------
// The selected key
// -------------------------------------------------------------------------------------------------

class _SelectedKeyframe extends StatelessWidget {
  const _SelectedKeyframe({
    super.key,
    required this.item,
    required this.property,
    required this.label,
    required this.t,
    required this.index,
    required this.total,
    required this.rate,
    required this.editable,
    required this.onNudge,
    required this.onJump,
    required this.onDelete,
    required this.onValue,
  });

  final TimelineItem item;
  final PropertyKey<Object?> property;
  final String label;
  final TimeUs t;
  final int index;
  final int total;
  final FrameRate rate;
  final bool editable;
  final ValueChanged<int> onNudge;
  final VoidCallback onJump;
  final VoidCallback onDelete;
  final ValueChanged<Object> onValue;

  @override
  Widget build(BuildContext context) {
    final key = property;
    final value = evaluate<Object?>(item, key, t);
    final scale = key.displayScale;
    final digits = InspectorRows.digitsFor(key.step * scale);
    final step = key.step > 0 ? key.step * scale : math.pow(10, -digits).toDouble();
    final unit = key.unit.isEmpty ? null : key.unit;
    final local = KeyframeCommands.gridLocal(item, rate, t);
    final canBack = editable && _free(-1);
    final canForward = editable && _free(1);

    Widget numberRow(String rowLabel, double v, ValueChanged<double> onChanged) => InspectorNumberRow(
          label: rowLabel,
          value: v * scale,
          min: key.min * scale,
          max: key.max * scale,
          step: step,
          fractionDigits: digits,
          unit: unit,
          enabled: editable,
          onChanged: (shown) => onChanged(shown / scale),
        );

    final isSize = key.id == PropertyKeys.maskSize.id;
    final Widget valueRows = value is Vec2
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              numberRow(isSize ? 'Width' : 'X', value.x, (x) => onValue(Vec2(x, value.y))),
              numberRow(isSize ? 'Height' : 'Y', value.y, (y) => onValue(Vec2(value.x, y))),
            ],
          )
        : numberRow(KeyframeStrings.value, (value is num ? value.toDouble() : 0), (v) => onValue(v));

    return VwishSurface(
      color: VwishColors.surfaceElevatedHigher,
      borderRadius: VwishRadius.smAll,
      padding: const EdgeInsets.symmetric(horizontal: VwishSpacing.md, vertical: VwishSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(KeyframeStrings.selectedTitle(label, index, total), style: _bodyStyle.copyWith(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: VwishSpacing.xs),
          Row(
            children: [
              Expanded(child: Text(KeyframeStrings.time, maxLines: 1, overflow: TextOverflow.ellipsis, style: _bodyStyle)),
              VwishIconButton(
                key: const ValueKey<String>('kf.frameBack'),
                icon: Icons.chevron_left_rounded,
                size: 32,
                iconSize: 20,
                color: VwishColors.textSecondary,
                tooltip: KeyframeStrings.frameBack,
                onPressed: canBack ? () => onNudge(-1) : null,
              ),
              Semantics(
                label: KeyframeStrings.time,
                value: Timecode.format(local, rate),
                excludeSemantics: true,
                child: Text(Timecode.format(local, rate), key: const ValueKey<String>('kf.time'), maxLines: 1, style: _timeStyle),
              ),
              VwishIconButton(
                key: const ValueKey<String>('kf.frameForward'),
                icon: Icons.chevron_right_rounded,
                size: 32,
                iconSize: 20,
                color: VwishColors.textSecondary,
                tooltip: KeyframeStrings.frameForward,
                onPressed: canForward ? () => onNudge(1) : null,
              ),
            ],
          ),
          valueRows,
          Padding(
            padding: const EdgeInsets.symmetric(vertical: VwishSpacing.xs),
            child: Row(
              children: [
                Expanded(child: Text(KeyframeStrings.interpolation, maxLines: 1, overflow: TextOverflow.ellipsis, style: _bodyStyle)),
                Semantics(
                  label: KeyframeStrings.interpolation,
                  value: KeyframeStrings.linear,
                  excludeSemantics: true,
                  child: DecoratedBox(
                    key: const ValueKey<String>('kf.interpolation'),
                    decoration: BoxDecoration(
                      color: VwishColors.surfaceElevated,
                      borderRadius: VwishRadius.smAll,
                      border: Border.all(color: VwishColors.border, width: VwishBorders.width),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: VwishSpacing.md, vertical: VwishSpacing.xs),
                      child: Text(KeyframeStrings.linear, style: _captionStyle.copyWith(color: VwishColors.textSecondary)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: VwishSpacing.xs),
          Wrap(
            spacing: VwishSpacing.sm,
            runSpacing: VwishSpacing.sm,
            children: [
              VwishButton.secondary(
                key: const ValueKey<String>('kf.jumpHere'),
                label: KeyframeStrings.jumpHere,
                icon: Icons.my_location_rounded,
                onPressed: onJump,
              ),
              VwishButton.ghost(
                key: const ValueKey<String>('kf.delete'),
                label: KeyframeStrings.delete,
                icon: Icons.delete_outline_rounded,
                onPressed: editable ? onDelete : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  bool _free(int frames) {
    final to = KeyframeCommands.nudged(item, rate, t, frames);
    return to != null && !KeyframeCommands.timesOf(item, property).contains(to);
  }
}
