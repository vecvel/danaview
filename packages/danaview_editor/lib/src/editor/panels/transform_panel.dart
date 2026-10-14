// OWNER: UX-23
//
// The Transform panel (ux.md §10.2) for a video, image, overlay or text item.
//
// * Rows from the CORE-05 metadata (`InspectorPropertyRow`): Position X/Y (% of the canvas, 0 =
//   centre, −200…200 %), Scale (1…800 %), Rotation (−360…360°) and Opacity (0…100 %), each with a
//   keyframe toggle and keyframe-aware `SetProperty` writes at the playhead (a drag is one
//   `EditTransaction`, keyboard steps coalesce, typed values and resets are one entry each); Fit
//   (Fit / Fill / Stretch) as a segmented row. Rows that do not apply to the item (flips, fit and
//   crop on text) are left out.
// * Flip: two toggle buttons (the flip icon, and the same icon turned 90° for vertical), one
//   labelled history entry per press.
// * Crop opens crop mode (the Crop panel and the crop preview mode); Reset transform runs core
//   `ResetTransform` (identity placement, transform keyframes cleared) as one entry.
// * The header's reset does the same as Reset transform (asking first when keyframes would go);
//   its keyframe-all keys position, scale, rotation and opacity at the playhead (or removes those
//   keys when all four have one there).
// * Direct manipulation on the preview edits the same properties; the rows read the working project,
//   so they follow a gesture live.

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show AddKeyframe, CompositeCommand, EditCommand, RemoveKeyframe, ResetTransform, SetProperty;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../../app/strings/transform_strings.dart';
import '../contracts/inspector_routes.dart';
import '../editor_scope.dart';
import '../inspector/inspector_header.dart';
import '../inspector/inspector_rows.dart';
import '../inspector/keyframe_toggle.dart';
import '../state/editor_controller.dart';

/// The rows of the Transform panel.
abstract final class TransformRows {
  /// Position, scale and rotation (above the flips).
  static final List<PropertyKey<Object?>> placement =
      List.unmodifiable(<PropertyKey<Object?>>[PropertyKeys.position, PropertyKeys.scale, PropertyKeys.rotation]);

  /// The keyframable rows (the header's keyframe-all).
  static final List<PropertyKey<Object?>> keyframable =
      List.unmodifiable(<PropertyKey<Object?>>[PropertyKeys.position, PropertyKeys.scale, PropertyKeys.rotation, PropertyKeys.opacity]);

  /// The fit options.
  static const List<DanaviewOption<Object?>> fitOptions = [
    DanaviewOption<Object?>(value: FitMode.fit, label: TransformStrings.fitFit),
    DanaviewOption<Object?>(value: FitMode.fill, label: TransformStrings.fitFill),
    DanaviewOption<Object?>(value: FitMode.stretch, label: TransformStrings.fitStretch),
  ];
}

/// Commands shared by the Transform and Mask panels.
abstract final class TransformCommands {
  /// Toggles a flip of [item] (one labelled entry).
  static EditCommand flip(TimelineItem item, {required bool horizontal}) {
    final key = horizontal ? PropertyKeys.flipH : PropertyKeys.flipV;
    return CompositeCommand(TransformStrings.historyFlip(horizontal: horizontal), [
      SetProperty<bool>([item.id], key, !key.read(item)),
    ]);
  }

  /// Keys (or, when every applicable row has one at [at], removes them) for [keys] of [item] at
  /// absolute [at].
  static EditCommand keyframeAll(TimelineItem item, List<PropertyKey<Object?>> keys, TimeUs at) {
    final applicable = [
      for (final k in keys)
        if (k.keyframable && k.appliesToItem(item)) k,
    ];
    final local = localTime(item, at);
    if (aggregateStatus(item, applicable, at).state == KeyframeToggleState.atPlayhead) {
      return CompositeCommand(TransformStrings.historyRemoveKeys, [
        for (final k in applicable)
          if (KeyframeOps.hasKeyAt(keyframesOf(item), k, local)) RemoveKeyframe(KeyframeRef(item.id, k.id, local)),
      ]);
    }
    return CompositeCommand(TransformStrings.historyKeyframeAll, [
      for (final k in applicable)
        if (!KeyframeOps.hasKeyAt(keyframesOf(item), k, local)) AddKeyframe(KeyframeRef(item.id, k.id, local)),
    ]);
  }

  /// The keyframe state of several rows: at the playhead when every row has a key there,
  /// animated when any row has keys, else static.
  static KeyframeStatus aggregateStatus(TimelineItem item, List<PropertyKey<Object?>> keys, TimeUs playhead) {
    var at = 0;
    var animated = 0;
    var enabled = keys.isNotEmpty;
    var counted = 0;
    for (final k in keys) {
      if (!k.keyframable || !k.appliesToItem(item)) continue;
      counted++;
      final s = KeyframeStatus.of(item, k, playhead);
      enabled = s.enabled;
      if (s.state == KeyframeToggleState.atPlayhead) at++;
      if (s.animated) animated++;
    }
    if (counted > 0 && at == counted) return KeyframeStatus(KeyframeToggleState.atPlayhead, enabled: enabled);
    if (animated > 0) return KeyframeStatus(KeyframeToggleState.animated, enabled: enabled);
    return KeyframeStatus(KeyframeToggleState.none, enabled: enabled && counted > 0);
  }

  /// Whether any of [keys] is animated on [item].
  static bool anyAnimated(TimelineItem item, List<PropertyKey<Object?>> keys) =>
      keys.any((k) => k.keyframable && k.appliesToItem(item) && KeyframeOps.isAnimated(keyframesOf(item), k));

  /// The item-local time of absolute [at], inside the item.
  static TimeUs localTime(TimelineItem item, TimeUs at) => (at - item.start).clamp(0, item.duration > 0 ? item.duration - 1 : 0).toInt();
}

/// The transform panel (ux.md §10.2).
class TransformPanel extends ConsumerWidget {
  /// Creates the panel.
  const TransformPanel({super.key, required this.route});

  /// What the panel edits.
  final TransformInspector route;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = EditorScope.idOf(context);
    final item = ref.watch(editorControllerProvider(id).select((s) => s.project?.index.item(route.item)));
    if (item == null || item is SubtitleCue || (item is MediaClip && item.visual == null)) return const SizedBox.shrink();
    final locked = ref.watch(editorControllerProvider(id).select((s) => s.project?.index.locate(route.item)?.track.locked ?? false));
    final ready = ref.watch(editorControllerProvider(id).select((s) => s.isReady)) && !locked;
    final editor = ref.read(editorControllerProvider(id).notifier);
    final playhead = ref.watch(playheadProvider(id));
    void reset() => editor.apply(ResetTransform([route.item]));
    final body = _TransformBody(item: item, ready: ready, locked: locked, onReset: reset);
    return ValueListenableBuilder<TimeUs>(
      valueListenable: playhead,
      child: body,
      builder: (context, t, body) => InspectorHeaderActions.publish(
        actions: InspectorHeaderActions(
          onReset: ready ? reset : null,
          resetRemovesKeyframes: TransformCommands.anyAnimated(item, TransformRows.keyframable),
          keyframeAll: TransformCommands.aggregateStatus(item, TransformRows.keyframable, t),
          onKeyframeAll: ready ? () => editor.apply(TransformCommands.keyframeAll(item, TransformRows.keyframable, playhead.value)) : null,
        ),
        child: body!,
      ),
    );
  }
}

class _TransformBody extends ConsumerWidget {
  const _TransformBody({required this.item, required this.ready, required this.locked, required this.onReset});

  final TimelineItem item;
  final bool ready;
  final bool locked;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = EditorScope.idOf(context);
    final EditorController editor = ref.read(editorControllerProvider(id).notifier);
    final visual = item is MediaClip;
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(DanaviewSpacing.lg, DanaviewSpacing.sm, DanaviewSpacing.lg, DanaviewSpacing.lg),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (locked) const PanelNotice(TransformStrings.trackLocked),
                InspectorPropertyRow(
                  key: ValueKey<String>('row.${PropertyKeys.position.id}'),
                  item: item.id,
                  property: PropertyKeys.position,
                  label: TransformStrings.position,
                ),
                ...InspectorRows.forItem(item.id, TransformRows.placement.skip(1)),
                if (visual) FlipRow(item: item, enabled: ready, onFlip: (h) => editor.apply(TransformCommands.flip(item, horizontal: h))),
                ...InspectorRows.forItem(
                  item.id,
                  [PropertyKeys.opacity, PropertyKeys.fit],
                  options: {PropertyKeys.fit.id: TransformRows.fitOptions},
                ),
                const SizedBox(height: DanaviewSpacing.md),
                Wrap(
                  spacing: DanaviewSpacing.sm,
                  runSpacing: DanaviewSpacing.sm,
                  children: [
                    if (visual)
                      DanaviewButton.secondary(
                        key: const ValueKey<String>('transform.crop'),
                        label: TransformStrings.cropButton,
                        icon: Icons.crop_rounded,
                        onPressed: ready ? () => editor.openInspector(CropInspector(item.id)) : null,
                      ),
                    Semantics(
                      hint: TransformStrings.resetTransformHint,
                      child: DanaviewButton.ghost(
                        key: const ValueKey<String>('transform.reset'),
                        label: TransformStrings.resetTransform,
                        icon: Icons.restart_alt_rounded,
                        onPressed: ready ? onReset : null,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The flip row (ux.md §10.2): two toggle buttons.
class FlipRow extends StatelessWidget {
  /// Creates the row.
  const FlipRow({super.key, required this.item, required this.onFlip, this.enabled = true});

  /// The item.
  final TimelineItem item;

  /// Called with true for horizontal, false for vertical.
  final ValueChanged<bool> onFlip;

  /// Whether the buttons work.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final h = PropertyKeys.flipH.appliesToItem(item) && PropertyKeys.flipH.read(item);
    final v = PropertyKeys.flipV.appliesToItem(item) && PropertyKeys.flipV.read(item);
    Widget button(bool horizontal, bool on) {
      final label = horizontal ? TransformStrings.flipHorizontal : TransformStrings.flipVertical;
      final b = DanaviewIconButton(
        key: ValueKey<String>(horizontal ? 'transform.flipH' : 'transform.flipV'),
        icon: Icons.flip_rounded,
        variant: DanaviewIconButtonVariant.filled,
        selected: on,
        size: 40,
        color: on ? DanaviewColors.primaryLight : null,
        tooltip: label,
        semanticLabel: label,
        onPressed: enabled ? () => onFlip(horizontal) : null,
      );
      return Semantics(toggled: on, child: horizontal ? b : RotatedBox(quarterTurns: 1, child: b));
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: DanaviewSpacing.xxs),
      child: Row(
        children: [
          Expanded(
            child: Text(TransformStrings.flip,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: DanaviewTextStyles.body.copyWith(fontFamily: DanaviewFonts.family)),
          ),
          button(true, h),
          const SizedBox(width: DanaviewSpacing.sm),
          button(false, v),
        ],
      ),
    );
  }
}

/// A one-line warning above a panel's rows (a locked track).
class PanelNotice extends StatelessWidget {
  /// Creates the notice.
  const PanelNotice(this.text, {super.key, this.color = DanaviewColors.warning});

  /// The text.
  final String text;

  /// Its colour.
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: DanaviewSpacing.xs),
        child: Text(text, style: DanaviewTextStyles.caption.copyWith(fontFamily: DanaviewFonts.family, color: color)),
      );
}
