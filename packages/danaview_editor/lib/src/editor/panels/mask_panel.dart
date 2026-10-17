// OWNER: UX-23
//
// The Mask panel (ux.md §10.10) for one picture clip.
//
// * Shape: None / Rectangle / Circle (an ellipse on a non-square picture), one labelled entry
//   ("Rectangle mask", "Remove mask").
// * With a shape: Position X/Y (layer-normalized, ×100), Width/Height for a rectangle, or Size with an
//   aspect lock for a circle (unlocked: Width/Height), Rotation, Corner radius (rectangle), Feather,
//   Opacity and Invert. Position, size, rotation, feather and opacity are keyframable (toggles and
//   keyframe-aware `SetProperty` at the playhead); a slider drag is one `EditTransaction`.
// * While the panel is open the preview shows the mask's handles (`MaskOverlay` through
//   `PreviewToolController.enterMask`), which edit the same properties; the aspect lock applies to
//   their corner drags too.
// * The header's reset removes the mask (and its keyframes, asking first); its keyframe-all keys
//   every keyframable mask row at the playhead.

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/eval.dart' show evaluate;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show ClearKeyframes, CompositeCommand, EditCommand, SetMask, SetProperty;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../../app/strings/transform_strings.dart';
import '../contracts/inspector_routes.dart';
import '../editor_scope.dart';
import '../inspector/inspector_header.dart';
import '../inspector/inspector_rows.dart';
import '../inspector/keyframe_toggle.dart';
import '../preview/crop_overlay.dart' show MaskPreviewTool, PreviewToolController, afterFrame, previewToolProvider;
import '../state/editor_controller.dart';
import 'transform_panel.dart' show PanelNotice, TransformCommands;

/// The rows of the Mask panel.
abstract final class MaskRows {
  /// The keyframable mask properties.
  static final List<PropertyKey<Object?>> keyframable = List.unmodifiable(<PropertyKey<Object?>>[
    PropertyKeys.maskCenter,
    PropertyKeys.maskSize,
    PropertyKeys.maskRotation,
    PropertyKeys.maskFeather,
    PropertyKeys.maskOpacity,
  ]);

  /// The shape options.
  static const List<DanaviewOption<MaskShape>> shapes = [
    DanaviewOption(value: MaskShape.none, label: TransformStrings.maskNone),
    DanaviewOption(value: MaskShape.rectangle, label: TransformStrings.maskRectangle),
    DanaviewOption(value: MaskShape.ellipse, label: TransformStrings.maskCircle),
  ];

  /// The label of [shape].
  static String labelOf(MaskShape shape) => switch (shape) {
        MaskShape.none => TransformStrings.maskNone,
        MaskShape.rectangle => TransformStrings.maskRectangle,
        MaskShape.ellipse => TransformStrings.maskCircle,
      };
}

/// Commands of the Mask panel.
abstract final class MaskCommands {
  /// Sets the shape ("Rectangle mask"); a new mask starts from the defaults, "None" also clears
  /// the mask keyframes.
  static EditCommand shape(MediaClip clip, MaskShape shape) {
    final mask = clip.visual!.mask;
    if (shape == MaskShape.none) return reset(clip, label: TransformStrings.historyMaskShape(TransformStrings.maskNone));
    final next = mask.shape == MaskShape.none ? MaskSpec(shape: shape) : mask.copyWith(shape: shape);
    return CompositeCommand(TransformStrings.historyMaskShape(MaskRows.labelOf(shape)), [SetMask([clip.id], next)]);
  }

  /// No mask and no mask keyframes ("Reset mask").
  static EditCommand reset(MediaClip clip, {String label = TransformStrings.historyResetMask}) => CompositeCommand(label, [
        for (final k in MaskRows.keyframable)
          if (KeyframeOps.isAnimated(keyframesOf(clip), k)) ClearKeyframes([clip.id], property: k.id),
        SetMask([clip.id], MaskSpec.none),
      ]);

  /// The uniform circle size: both axes scaled so the width becomes [width] (proportions kept).
  static Vec2 uniformSize(Vec2 current, double width) {
    final ratio = current.x > 0 ? current.y / current.x : 1.0;
    var w = width;
    // Keep both axes inside the range.
    final k = PropertyKeys.maskSize;
    if (ratio > 0) w = w.clamp(math.max(k.min, k.min / ratio), math.min(k.max, k.max / ratio)).toDouble();
    return Vec2(w, w * ratio);
  }
}

/// The mask panel (ux.md §10.10).
class MaskPanel extends ConsumerStatefulWidget {
  /// Creates the panel.
  const MaskPanel({super.key, required this.route});

  /// What the panel edits.
  final MaskInspector route;

  @override
  ConsumerState<MaskPanel> createState() => _MaskPanelState();
}

class _MaskPanelState extends ConsumerState<MaskPanel> {
  PreviewToolController? _tools;
  bool _lock = true;
  InspectorEditSession? _sizeSession;
  double? _liveSize;

  EditorController get _editor => ref.read(editorControllerProvider(EditorScope.idOf(context)).notifier);

  bool _lockFor(MaskShape shape) => shape == MaskShape.ellipse && _lock;

  @override
  void didUpdateWidget(MaskPanel old) {
    super.didUpdateWidget(old);
    if (old.route.item != widget.route.item) {
      final tools = _tools;
      final from = old.route.item;
      afterFrame(() {
        tools?.exit<MaskPreviewTool>(from);
        _sync();
      });
    }
  }

  @override
  void dispose() {
    _sizeSession?.dispose();
    final tools = _tools;
    final item = widget.route.item;
    afterFrame(() => tools?.exit<MaskPreviewTool>(item));
    super.dispose();
  }

  void _bind(PreviewToolController tools) {
    if (identical(tools, _tools)) return;
    final old = _tools;
    _tools = tools;
    final item = widget.route.item;
    afterFrame(() {
      old?.exit<MaskPreviewTool>(item);
      _sync();
    });
  }

  /// Shows the handles of the current item with the current lock.
  void _sync() {
    if (!mounted) return;
    final item = ref.read(editorControllerProvider(EditorScope.idOf(context))).project?.index.item(widget.route.item);
    final shape = item is MediaClip ? item.visual?.mask.shape ?? MaskShape.none : MaskShape.none;
    _tools?.enterMask(widget.route.item, lockAspect: _lockFor(shape));
  }

  void _setLock(bool on) {
    setState(() => _lock = on);
    _sync();
  }

  @override
  Widget build(BuildContext context) {
    final id = EditorScope.idOf(context);
    _bind(ref.watch(previewToolProvider(id)));
    final item = ref.watch(editorControllerProvider(id).select((s) => s.project?.index.item(widget.route.item)));
    if (item is! MediaClip || item.visual == null) return const SizedBox.shrink();
    final locked = ref.watch(editorControllerProvider(id).select((s) => s.project?.index.locate(widget.route.item)?.track.locked ?? false));
    final ready = ref.watch(editorControllerProvider(id).select((s) => s.isReady)) && !locked;
    final playhead = ref.watch(playheadProvider(id));
    final mask = item.visual!.mask;
    final tool = _tools?.value;
    if (tool is MaskPreviewTool && tool.item == item.id && tool.lockAspect != _lockFor(mask.shape)) afterFrame(_sync);
    void reset() => _editor.apply(MaskCommands.reset(item));
    final body = _body(item, mask, ready: ready, locked: locked);
    return ValueListenableBuilder<TimeUs>(
      valueListenable: playhead,
      child: body,
      builder: (context, t, body) => InspectorHeaderActions.publish(
        actions: InspectorHeaderActions(
          onReset: ready && mask.shape != MaskShape.none ? reset : null,
          resetRemovesKeyframes: TransformCommands.anyAnimated(item, MaskRows.keyframable),
          keyframeAll: mask.shape == MaskShape.none ? null : TransformCommands.aggregateStatus(item, MaskRows.keyframable, t),
          onKeyframeAll: ready && mask.shape != MaskShape.none
              ? () => _editor.apply(TransformCommands.keyframeAll(item, MaskRows.keyframable, playhead.value))
              : null,
        ),
        child: body!,
      ),
    );
  }

  Widget _body(MediaClip item, MaskSpec mask, {required bool ready, required bool locked}) {
    final rows = <Widget>[
      if (locked) const PanelNotice(TransformStrings.trackLocked),
      InspectorChoiceRow<MaskShape>(
        key: const ValueKey<String>('mask.shape'),
        label: TransformStrings.maskShape,
        value: mask.shape,
        options: MaskRows.shapes,
        enabled: ready,
        onChanged: (s) {
          if (s != mask.shape) _editor.apply(MaskCommands.shape(item, s));
        },
      ),
    ];
    if (mask.shape == MaskShape.none) {
      rows.add(const Padding(
        padding: EdgeInsets.only(top: DanaviewSpacing.xs),
        child: PanelNotice(TransformStrings.maskNoneHint, color: DanaviewColors.textMuted),
      ));
    } else {
      final ellipse = mask.shape == MaskShape.ellipse;
      rows.addAll([
        InspectorPropertyRow(
          key: ValueKey<String>('row.${PropertyKeys.maskCenter.id}'),
          item: item.id,
          property: PropertyKeys.maskCenter,
          label: TransformStrings.position,
        ),
        if (ellipse)
          InspectorToggleRow(
            key: const ValueKey<String>('mask.lock'),
            label: TransformStrings.maskLockAspect,
            value: _lock,
            onChanged: _setLock,
          ),
        if (ellipse && _lock) _uniformSizeRow(item, ready) else ..._sizeRows(item, ready),
        InspectorPropertyRow(
          key: ValueKey<String>('row.${PropertyKeys.maskRotation.id}'),
          item: item.id,
          property: PropertyKeys.maskRotation,
          label: TransformStrings.maskRotation,
        ),
        if (!ellipse)
          InspectorPropertyRow(
            key: ValueKey<String>('row.${PropertyKeys.maskCornerRadius.id}'),
            item: item.id,
            property: PropertyKeys.maskCornerRadius,
            label: TransformStrings.maskCornerRadius,
          ),
        InspectorPropertyRow(
          key: ValueKey<String>('row.${PropertyKeys.maskFeather.id}'),
          item: item.id,
          property: PropertyKeys.maskFeather,
          label: TransformStrings.maskFeather,
        ),
        InspectorPropertyRow(
          key: ValueKey<String>('row.${PropertyKeys.maskOpacity.id}'),
          item: item.id,
          property: PropertyKeys.maskOpacity,
          label: TransformStrings.maskOpacity,
        ),
        InspectorToggleRow(
          key: const ValueKey<String>('mask.invert'),
          label: TransformStrings.maskInvert,
          subtitle: TransformStrings.maskInvertHint,
          value: mask.invert,
          onChanged: ready ? (v) => _editor.apply(SetProperty<bool>([item.id], PropertyKeys.maskInvert, v)) : null,
        ),
      ]);
    }
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(DanaviewSpacing.lg, DanaviewSpacing.sm, DanaviewSpacing.lg, DanaviewSpacing.lg),
          sliver: SliverToBoxAdapter(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows)),
        ),
      ],
    );
  }

  /// Width and Height rows over the mask size (one property, two axes).
  List<Widget> _sizeRows(MediaClip item, bool ready) => [
        _SizeAxisRow(key: const ValueKey<String>('mask.width'), item: item.id, axis: 0, label: TransformStrings.maskWidth),
        _SizeAxisRow(key: const ValueKey<String>('mask.height'), item: item.id, axis: 1, label: TransformStrings.maskHeight),
      ];

  /// The uniform Size row of a locked circle.
  Widget _uniformSizeRow(MediaClip item, bool ready) {
    final id = EditorScope.idOf(context);
    final playhead = ref.read(playheadProvider(id));
    final key = PropertyKeys.maskSize;
    final session = _sizeSession ??= InspectorEditSession(editor: _editor, label: TransformStrings.historyMaskSize, coalesceKey: '${item.id}:mask.size.uniform');
    session.editor = _editor;
    Vec2 sizeAt() {
      final clip = ref.read(editorControllerProvider(id)).project?.index.item(item.id);
      if (clip is! MediaClip) return key.defaultValue;
      return evaluate(clip, key, TransformCommands.localTime(clip, playhead.value));
    }

    EditCommand command(double w) => SetProperty<Vec2>([item.id], key, MaskCommands.uniformSize(sizeAt(), w), at: playhead.value);
    final animated = KeyframeOps.isAnimated(keyframesOf(item), key);
    Widget row(TimeUs t) => InspectorSliderRow(
          key: const ValueKey<String>('mask.size'),
          label: TransformStrings.maskSize,
          value: _liveSize ?? evaluate(item, key, TransformCommands.localTime(item, t)).x,
          min: key.min,
          max: key.max,
          step: key.step,
          displayScale: key.displayScale,
          unit: key.unit,
          defaultValue: key.defaultValue.x,
          enabled: ready,
          keyframeToggle: PropertyKeyframeToggle(item: item.id, property: key, label: TransformStrings.maskSize),
          onChangeStart: (_) => session.start(),
          onChanged: (v) {
            setState(() => _liveSize = v);
            session.change(command(v));
          },
          onChangeEnd: (_) {
            session.end();
            setState(() => _liveSize = null);
          },
          onSubmitted: (v) => session.apply(command(v)),
        );
    if (!animated) return row(playhead.value);
    return ValueListenableBuilder<TimeUs>(valueListenable: playhead, builder: (context, t, _) => row(t));
  }
}

/// One axis of the mask size ("Width" / "Height").
class _SizeAxisRow extends ConsumerStatefulWidget {
  const _SizeAxisRow({super.key, required this.item, required this.axis, required this.label});

  final ItemId item;
  final int axis;
  final String label;

  @override
  ConsumerState<_SizeAxisRow> createState() => _SizeAxisRowState();
}

class _SizeAxisRowState extends ConsumerState<_SizeAxisRow> {
  InspectorEditSession? _session;
  double? _live;

  @override
  void dispose() {
    _session?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final id = EditorScope.idOf(context);
    final key = PropertyKeys.maskSize;
    final item = ref.watch(editorControllerProvider(id).select((s) => s.project?.index.item(widget.item)));
    if (item is! MediaClip || item.visual == null) return const SizedBox.shrink();
    final ready = ref.watch(editorControllerProvider(id).select((s) => s.isReady));
    final playhead = ref.watch(playheadProvider(id));
    final editor = ref.read(editorControllerProvider(id).notifier);
    final session = _session ??= InspectorEditSession(editor: editor, label: TransformStrings.historyMaskSize, coalesceKey: '${widget.item}:mask.size.${widget.axis}');
    session.editor = editor;
    Vec2 at(TimeUs t) => evaluate(item, key, TransformCommands.localTime(item, t));
    EditCommand command(double v) {
      final b = at(playhead.value);
      return SetProperty<Vec2>([item.id], key, key.clamp(widget.axis == 0 ? Vec2(v, b.y) : Vec2(b.x, v)), at: playhead.value);
    }

    Widget row(TimeUs t) {
      final shown = widget.axis == 0 ? at(t).x : at(t).y;
      return InspectorSliderRow(
        label: widget.label,
        value: _live ?? shown,
        min: key.min,
        max: key.max,
        step: key.step,
        displayScale: key.displayScale,
        unit: key.unit,
        defaultValue: widget.axis == 0 ? key.defaultValue.x : key.defaultValue.y,
        enabled: ready,
        keyframeToggle: PropertyKeyframeToggle(item: item.id, property: key, label: TransformStrings.maskSize),
        onChangeStart: (_) => session.start(),
        onChanged: (v) {
          setState(() => _live = v);
          session.change(command(v));
        },
        onChangeEnd: (_) {
          session.end();
          setState(() => _live = null);
        },
        onSubmitted: (v) => session.apply(command(v)),
      );
    }

    if (!KeyframeOps.isAnimated(keyframesOf(item), key)) return row(playhead.value);
    return ValueListenableBuilder<TimeUs>(valueListenable: playhead, builder: (context, t, _) => row(t));
  }
}
