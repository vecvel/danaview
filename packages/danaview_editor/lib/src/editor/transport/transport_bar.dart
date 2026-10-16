// OWNER: UX-14
//
// The transport bar (ux.md §7.6): play/pause, the time readout, frame step, edit-point jumps and
// the toggles that live next to the preview, planned by the `PriorityRowPlanner`.
//
//   priority  item                                   source
//   M         play / pause                           TransportController.togglePlay
//   M         time readout (tap: time entry)         TimecodeText + Timecode.parse
//   1         frame back / forward (hold repeats)    TransportController.startStepRepeat
//   2         previous / next edit point or marker   TransportController
//   3         add marker (M)                         registry action `addMarker`
//   4         snapping (N)                           registry action `toggleSnapping`
//   5         ripple (R)                             registry action `toggleRipple`
//   6         zoom out / in                          registry actions `zoomOut`, `zoomIn`
//   7         fullscreen preview (F)                 registry action `fullscreenPreview`
//   8         preview quality                        EditorController.setPreviewQuality / setUseProxies
//   M (if anything is hidden) "more" menu with the hidden items
//
// * Actions owned by other features (marker, snapping, ripple) show only while they are bound.
// * At ladder step 4 of the layout (`transportInTopBar`) the bar sits in the top bar's title slot
//   and shows play/pause and the compact time only.
// * Tap targets (ARCH §17.9): every button and the readout answer taps and screen readers over at
//   least 44×44 through `ExpandedHitArea`, also when the bar is 40 px tall (compact landscape,
//   568×320), without growing the bar.
// * Rebuilds (ux.md §16.6): the bar rebuilds when the project's duration or frame rate, the edit
//   modes, the preview quality or the editor phase change, never per playback frame. Per frame only
//   `TimecodeText` rebuilds, and the play button when playback starts or stops.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable, immutable;
import 'package:flutter/material.dart' show Icons, Theme;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart' show FrameRate, TimeUs, Timecode;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show PreviewQuality;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../../debug/rebuild_counters.dart';
import '../a11y/expanded_hit_area.dart';
import '../actions/editor_action_registry.dart';
import '../contracts/contracts.dart';
import '../editor_scope.dart';
import '../layout/editor_layout_scope.dart';
import '../layout/priority_row_planner.dart';
import '../state/editor_state.dart';
import '../state/transport_controller.dart';
import 'timecode_text.dart';
import 'transport_strings.dart';

/// The optional controls of the bar, in ux.md §7.6 priority order.
enum TransportItem {
  /// Frame back and forward.
  frames,

  /// Previous and next edit point.
  edits,

  /// Add marker.
  marker,

  /// Snapping toggle.
  snapping,

  /// Ripple toggle.
  ripple,

  /// Zoom out and in.
  zoom,

  /// Fullscreen preview.
  fullscreen,

  /// Preview quality menu.
  quality,
}

/// Play/pause, frame step, timecode and fullscreen (ux.md §7.6).
class TransportBar extends ConsumerWidget {
  /// Creates the bar for the editor of the nearest `EditorScope`.
  const TransportBar({super.key});

  /// Visual diameter of a transport button.
  static const double buttonSize = 40;

  /// Width one button takes in the row: the tap target on touch devices.
  static double buttonExtent(bool touch) => touch ? math.max(buttonSize, DanaviewSpacing.minTapTarget) : buttonSize;

  /// Horizontal padding of the readout button.
  static const double timecodePadding = 8;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    EditorRebuildCounters.count('TransportBar');
    final id = EditorScope.idOf(context);
    final merged = EditorLayoutScope.maybeOf(context)?.transportInTopBar ?? false;
    final platform = Theme.of(context).platform;
    final registry = ref.watch(editorActionRegistryProvider).forPlatformOf(platform);
    final view = ref.watch(editorControllerProvider(id).select(_BarState.of));
    final transport = ref.watch(transportProvider(id));
    final playhead = ref.watch(playheadProvider(id));
    final ctx = WidgetActionContext(projectId: id, context: context, ref: ref);

    return LayoutBuilder(
      builder: (context, constraints) {
        final touch = context.isTouchPlatform;
        final extent = buttonExtent(touch);
        final textScaler = MediaQuery.textScalerOf(context);
        final width = constraints.maxWidth.isFinite ? constraints.maxWidth : 400.0;

        double timecodeExtent(bool compact) =>
            measureTextWidth(TimecodeText.widest(view.duration, view.frameRate, compact: compact), TimecodeText.style, textScaler: textScaler) +
            2 * timecodePadding;

        final play = _PlayButton(transport: transport, registry: registry, enabled: view.canPlay, extent: extent);
        Widget readout(bool compact) => _TimecodeButton(
              transport: transport,
              playhead: playhead,
              duration: view.duration,
              frameRate: view.frameRate,
              compact: compact,
              enabled: view.ready,
            );

        if (merged) {
          return Align(
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                play,
                Flexible(child: readout(true)),
              ],
            ),
          );
        }

        final available = _optionalItems(registry, ctx);
        PriorityRowPlan<TransportItem> planFor(bool compact) => PriorityRowPlanner.plan<TransportItem>(
              items: [
                for (final item in available) PriorityRowItem<TransportItem>(item, extent: _extentOf(item, extent), priority: item.index + 1),
              ],
              width: width - extent - timecodeExtent(compact),
              moreExtent: extent,
            );
        var compact = false;
        var plan = planFor(false);
        if (available.contains(TransportItem.frames) && !plan.shown.contains(TransportItem.frames)) {
          compact = true;
          plan = planFor(true);
        }

        return Align(
          alignment: Alignment.centerLeft,
          child: Row(
            children: [
              play,
              Expanded(child: Align(alignment: Alignment.centerLeft, child: readout(compact))),
              for (final item in plan.shown) _buildItem(item, ctx, registry, transport, view, extent),
              if (plan.showMore) _MoreMenu(items: plan.overflow, ctx: ctx, registry: registry, transport: transport, view: view),
            ],
          ),
        );
      },
    );
  }

  /// The optional items that exist right now (actions of other features only while bound).
  static List<TransportItem> _optionalItems(EditorActionRegistry registry, EditorActionContext ctx) {
    bool has(EditorActionId id) => registry.spec(id).isBound && registry.spec(id).isVisible(ctx);
    return [
      TransportItem.frames,
      TransportItem.edits,
      if (has(EditorActionId.addMarker)) TransportItem.marker,
      if (has(EditorActionId.toggleSnapping)) TransportItem.snapping,
      if (has(EditorActionId.toggleRipple)) TransportItem.ripple,
      if (has(EditorActionId.zoomIn) && has(EditorActionId.zoomOut)) TransportItem.zoom,
      if (has(EditorActionId.fullscreenPreview)) TransportItem.fullscreen,
      TransportItem.quality,
    ];
  }

  static double _extentOf(TransportItem item, double button) => switch (item) {
        TransportItem.frames || TransportItem.edits || TransportItem.zoom => 2 * button,
        _ => button,
      };

  Widget _buildItem(
    TransportItem item,
    EditorActionContext ctx,
    EditorActionRegistry registry,
    TransportController transport,
    _BarState view,
    double extent,
  ) {
    Widget action(EditorActionId id, {bool selected = false}) =>
        _ActionButton(spec: registry.spec(id), registry: registry, ctx: ctx, selected: selected, enabled: view.ready);
    return switch (item) {
      TransportItem.frames => Row(mainAxisSize: MainAxisSize.min, children: [
          _StepButton(transport: transport, direction: -1, registry: registry, enabled: view.ready),
          _StepButton(transport: transport, direction: 1, registry: registry, enabled: view.ready),
        ]),
      TransportItem.edits => Row(mainAxisSize: MainAxisSize.min, children: [
          action(EditorActionId.prevEdit),
          action(EditorActionId.nextEdit),
        ]),
      TransportItem.marker => action(EditorActionId.addMarker),
      TransportItem.snapping => action(EditorActionId.toggleSnapping, selected: view.snapping),
      TransportItem.ripple => action(EditorActionId.toggleRipple, selected: view.ripple),
      TransportItem.zoom => Row(mainAxisSize: MainAxisSize.min, children: [
          action(EditorActionId.zoomOut),
          action(EditorActionId.zoomIn),
        ]),
      TransportItem.fullscreen => action(EditorActionId.fullscreenPreview),
      TransportItem.quality => _QualityMenu(ctx: ctx, view: view),
    };
  }
}

/// The slice of `EditorState` the bar depends on (value equality, so the bar rebuilds only when
/// one of these changes).
@immutable
class _BarState {
  const _BarState({
    required this.ready,
    required this.canPlay,
    required this.duration,
    required this.frameRate,
    required this.snapping,
    required this.ripple,
    required this.quality,
    required this.useProxies,
  });

  factory _BarState.of(EditorState s) {
    final project = s.project;
    final ready = s.phase == EditorPhase.ready;
    final duration = project?.duration ?? 0;
    return _BarState(
      ready: ready,
      canPlay: ready && s.preview.phase != PreviewPhase.failed && duration > 0,
      duration: duration,
      frameRate: project?.settings.frameRate ?? FrameRate.fps30,
      snapping: s.modes.snapping,
      ripple: s.modes.ripple,
      quality: s.preview.quality,
      useProxies: s.preview.useProxies,
    );
  }

  final bool ready;
  final bool canPlay;
  final TimeUs duration;
  final FrameRate frameRate;
  final bool snapping;
  final bool ripple;
  final PreviewQuality quality;
  final bool useProxies;

  @override
  bool operator ==(Object other) =>
      other is _BarState &&
      other.ready == ready &&
      other.canPlay == canPlay &&
      other.duration == duration &&
      other.frameRate == frameRate &&
      other.snapping == snapping &&
      other.ripple == ripple &&
      other.quality == quality &&
      other.useProxies == useProxies;

  @override
  int get hashCode => Object.hash(ready, canPlay, duration, frameRate, snapping, ripple, quality, useProxies);
}

// -------------------------------------------------------------------------------------------------
// Buttons
// -------------------------------------------------------------------------------------------------

class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.transport, required this.registry, required this.enabled, required this.extent});

  final TransportController transport;
  final EditorActionRegistry registry;
  final bool enabled;
  final double extent;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: transport.playing,
      builder: (context, playing, _) {
        final label = playing ? TransportStrings.pause : TransportStrings.play;
        return ExpandedHitArea(
          child: DanaviewIconButton(
            icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            iconSize: 28,
            size: TransportBar.buttonSize,
            tooltip: registry.tooltip(EditorActionId.playPause, label),
            semanticLabel: label,
            onPressed: enabled ? () => unawaited(transport.togglePlay()) : null,
          ),
        );
      },
    );
  }
}

/// A button that runs a registry action; disabled while the action can't run.
class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.spec, required this.registry, required this.ctx, required this.enabled, this.selected = false});

  final EditorActionSpec spec;
  final EditorActionRegistry registry;
  final EditorActionContext ctx;
  final bool enabled;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final runnable = enabled && spec.isEnabled(ctx);
    return ExpandedHitArea(
      child: DanaviewIconButton(
        icon: spec.icon,
        iconSize: 22,
        size: TransportBar.buttonSize,
        selected: selected,
        tooltip: registry.tooltip(spec.id),
        semanticLabel: spec.label,
        onPressed: runnable ? () => registry.invoke(spec.id, ctx) : null,
      ),
    );
  }
}

/// Frame back/forward: a press steps once at once, and holding repeats at 8 Hz after 400 ms.
class _StepButton extends StatefulWidget {
  const _StepButton({required this.transport, required this.direction, required this.registry, required this.enabled});

  final TransportController transport;
  final int direction;
  final EditorActionRegistry registry;
  final bool enabled;

  @override
  State<_StepButton> createState() => _StepButtonState();
}

class _StepButtonState extends State<_StepButton> {
  bool _viaPointer = false;

  EditorActionId get _id => widget.direction < 0 ? EditorActionId.prevFrame : EditorActionId.nextFrame;

  void _pointerDown(PointerDownEvent event) {
    if (!widget.enabled) return;
    _viaPointer = true;
    widget.transport.startStepRepeat(widget.direction);
  }

  void _pointerEnd(PointerEvent event) {
    widget.transport.stopStepRepeat();
    // The tap that follows the pointer-up must not step a second time.
    scheduleMicrotask(() => _viaPointer = false);
  }

  void _activate() {
    if (_viaPointer) return;
    unawaited(widget.transport.stepFrames(widget.direction));
  }

  @override
  void dispose() {
    widget.transport.stopStepRepeat();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final back = widget.direction < 0;
    final label = back ? TransportStrings.previousFrame : TransportStrings.nextFrame;
    return ExpandedHitArea(
      child: Listener(
        onPointerDown: _pointerDown,
        onPointerUp: _pointerEnd,
        onPointerCancel: _pointerEnd,
        child: DanaviewIconButton(
          icon: back ? Icons.keyboard_arrow_left_rounded : Icons.keyboard_arrow_right_rounded,
          iconSize: 26,
          size: TransportBar.buttonSize,
          tooltip: widget.registry.tooltip(_id, label),
          semanticLabel: label,
          onPressed: widget.enabled ? _activate : null,
        ),
      ),
    );
  }
}

// -------------------------------------------------------------------------------------------------
// Time readout and time entry
// -------------------------------------------------------------------------------------------------

class _TimecodeButton extends StatelessWidget {
  const _TimecodeButton({
    required this.transport,
    required this.playhead,
    required this.duration,
    required this.frameRate,
    required this.compact,
    required this.enabled,
  });

  final TransportController transport;
  final ValueListenable<TimeUs> playhead;
  final TimeUs duration;
  final FrameRate frameRate;
  final bool compact;
  final bool enabled;

  Future<void> _enterTime(BuildContext context) async {
    final from = playhead.value;
    final text = await showDanaviewPrompt(
      context,
      title: TransportStrings.entryTitle,
      hint: TransportStrings.entryHint,
      initialValue: Timecode.format(from, frameRate),
      confirmLabel: TransportStrings.entryConfirm,
      validator: (value) => Timecode.parse(value, frameRate, base: playhead.value) == null ? TransportStrings.entryInvalid : null,
      prefixIcon: Icons.schedule_rounded,
    );
    if (text == null) return;
    final t = Timecode.parse(text, frameRate, base: playhead.value);
    if (t == null) return;
    await transport.seekTo(math.min(math.max(t, 0), duration));
  }

  @override
  Widget build(BuildContext context) {
    // The pressable names the readout; the text adds only its value, so the label is read once.
    return ExpandedHitArea(
      child: DanaviewPressable(
        enabled: enabled,
        onTap: enabled ? () => unawaited(_enterTime(context)) : null,
        semanticLabel: TransportStrings.time,
        tooltip: TransportStrings.timeHint,
        borderRadius: DanaviewRadius.smAll,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: TransportBar.timecodePadding, vertical: DanaviewSpacing.sm),
          child: TimecodeText(playhead: playhead, duration: duration, frameRate: frameRate, compact: compact, semanticsLabel: false),
        ),
      ),
    );
  }
}

// -------------------------------------------------------------------------------------------------
// Quality and more
// -------------------------------------------------------------------------------------------------

List<DanaviewMenuEntry> _qualityEntries(EditorActionContext ctx, _BarState view) {
  final editor = ctx.read(editorControllerProvider(ctx.projectId).notifier);
  DanaviewMenuItem quality(String label, PreviewQuality q) => DanaviewMenuItem(
        label: label,
        selected: view.quality == q,
        enabled: view.ready,
        onTap: () => unawaited(editor.setPreviewQuality(q)),
      );
  return [
    DanaviewMenuHeader(TransportStrings.quality),
    quality(TransportStrings.qualityAuto, PreviewQuality.auto),
    quality(TransportStrings.qualityFull, PreviewQuality.full),
    quality(TransportStrings.qualityHalf, PreviewQuality.half),
    quality(TransportStrings.qualityQuarter, PreviewQuality.quarter),
    const DanaviewMenuDivider(),
    DanaviewMenuItem(
      label: TransportStrings.useProxies,
      selected: view.useProxies,
      enabled: view.ready,
      onTap: () => unawaited(editor.setUseProxies(!view.useProxies)),
    ),
    const DanaviewMenuDivider(),
    const DanaviewMenuHeader(TransportStrings.qualityNote),
  ];
}

class _QualityMenu extends StatelessWidget {
  const _QualityMenu({required this.ctx, required this.view});

  final EditorActionContext ctx;
  final _BarState view;

  @override
  Widget build(BuildContext context) {
    return ExpandedHitArea(
        child: DanaviewMenuIconTrigger(
      icon: Icons.hd_rounded,
      iconSize: 22,
      size: TransportBar.buttonSize,
      tooltip: TransportStrings.quality,
      semanticLabel: TransportStrings.quality,
      selected: view.quality != PreviewQuality.auto,
      enabled: view.ready,
      menuWidth: 280,
      entries: _qualityEntries(ctx, view),
    ));
  }
}

class _MoreMenu extends StatelessWidget {
  const _MoreMenu({required this.items, required this.ctx, required this.registry, required this.transport, required this.view});

  final List<TransportItem> items;
  final EditorActionContext ctx;
  final EditorActionRegistry registry;
  final TransportController transport;
  final _BarState view;

  List<DanaviewMenuEntry> _entries() {
    final out = <DanaviewMenuEntry>[];
    for (final item in items) {
      switch (item) {
        case TransportItem.frames:
          out
            ..add(_step(-1, TransportStrings.previousFrame, Icons.keyboard_arrow_left_rounded, EditorActionId.prevFrame))
            ..add(_step(1, TransportStrings.nextFrame, Icons.keyboard_arrow_right_rounded, EditorActionId.nextFrame));
        case TransportItem.edits:
          out.addAll(registry.menuEntries(ctx, const [EditorActionId.prevEdit, EditorActionId.nextEdit]));
        case TransportItem.marker:
          out.addAll(registry.menuEntries(ctx, const [EditorActionId.addMarker]));
        case TransportItem.snapping:
          out.addAll(registry.menuEntries(ctx, const [EditorActionId.toggleSnapping], selected: (_) => view.snapping));
        case TransportItem.ripple:
          out.addAll(registry.menuEntries(ctx, const [EditorActionId.toggleRipple], selected: (_) => view.ripple));
        case TransportItem.zoom:
          out.addAll(registry.menuEntries(ctx, const [EditorActionId.zoomOut, EditorActionId.zoomIn]));
        case TransportItem.fullscreen:
          out.addAll(registry.menuEntries(ctx, const [EditorActionId.fullscreenPreview]));
        case TransportItem.quality:
          if (out.isNotEmpty) out.add(const DanaviewMenuDivider());
          out.addAll(_qualityEntries(ctx, view));
      }
    }
    return out;
  }

  DanaviewMenuItem _step(int direction, String label, IconData icon, EditorActionId id) => DanaviewMenuItem(
        label: label,
        icon: icon,
        enabled: view.ready,
        trailing: registry.spec(id).primaryShortcut == null
            ? null
            : Text(registry.spec(id).primaryShortcut!, style: DanaviewTextStyles.caption.copyWith(fontFamily: DanaviewFonts.family)),
        onTap: () => unawaited(transport.stepFrames(direction)),
      );

  @override
  Widget build(BuildContext context) {
    return ExpandedHitArea(
        child: DanaviewMenuIconTrigger(
      icon: Icons.more_horiz_rounded,
      iconSize: 22,
      size: TransportBar.buttonSize,
      tooltip: TransportStrings.more,
      semanticLabel: TransportStrings.more,
      menuWidth: 280,
      entries: _entries(),
    ));
  }
}
