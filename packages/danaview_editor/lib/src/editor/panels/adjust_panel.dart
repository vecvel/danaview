// OWNER: UX-24
//
// The Adjust panel (ux.md §10.6, ARCH §6.5): the Effects tool's panel for one picture clip.
//
// * Three sections in a segmented control: Light (exposure, brightness, contrast, highlights,
//   shadows), Color (saturation, temperature, tint) and Detail (sharpness, blur, vignette and the
//   Opacity mirror of Transform). Every row is an `InspectorPropertyRow` over the CORE-05 metadata
//   (range, default, unit, ×100 display) with a keyframe toggle, writing `SetProperty` at the
//   playhead: a drag is one history entry, keyboard steps coalesce, a double tap on a label resets.
// * Before/after: pressing and holding the compare button opens an `EditTransaction` whose working
//   copy has neutral adjust, detail and look (the keys of those properties cleared), so the preview
//   shows the original through the normal transient path; releasing cancels it, so nothing reaches
//   history. For assistive technology the button toggles.
//   (UX-16's header has no slot for extra buttons, so the button sits in the panel's top row.)
// * Footer: "Apply to all clips" copies the shown values to every other picture clip of the
//   selected clip's lane in one command (one history entry); "Reset all" returns the panel's rows to
//   neutral (and clears their keyframes). The header's reset does the same and asks first only when
//   keyframes would go; the header's keyframe-all toggles keys on every row of the open section at
//   the playhead.
// * The panel owns its scrolling under the pinned section row; it sits in the 240 px dock as well as
//   in the side pane.

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/eval.dart' show evaluate;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show AddKeyframe, ClearKeyframes, CompositeCommand, EditCommand, RemoveKeyframe, SetVisual;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../../app/strings/color_strings.dart';
import '../contracts/inspector_routes.dart';
import '../editor_scope.dart';
import '../inspector/inspector_header.dart';
import '../inspector/inspector_rows.dart';
import '../inspector/keyframe_toggle.dart';
import '../state/editor_controller.dart';

/// The three sections of the Adjust panel (ux.md §10.6).
enum AdjustSection {
  /// Exposure, brightness, contrast, highlights, shadows.
  light,

  /// Saturation, temperature, tint.
  color,

  /// Sharpness, blur, vignette, opacity.
  detail,
}

/// The properties each [AdjustSection] shows.
abstract final class AdjustRows {
  /// Light.
  static final List<PropertyKey<Object?>> light = List.unmodifiable(<PropertyKey<Object?>>[
    PropertyKeys.exposure,
    PropertyKeys.brightness,
    PropertyKeys.contrast,
    PropertyKeys.highlights,
    PropertyKeys.shadows,
  ]);

  /// Color.
  static final List<PropertyKey<Object?>> color = List.unmodifiable(<PropertyKey<Object?>>[
    PropertyKeys.saturation,
    PropertyKeys.temperature,
    PropertyKeys.tint,
  ]);

  /// Detail, with the Opacity mirror last.
  static final List<PropertyKey<Object?>> detail = List.unmodifiable(<PropertyKey<Object?>>[
    PropertyKeys.sharpness,
    PropertyKeys.blur,
    PropertyKeys.vignette,
    PropertyKeys.opacity,
  ]);

  /// The rows of [section].
  static List<PropertyKey<Object?>> of(AdjustSection section) => switch (section) {
        AdjustSection.light => light,
        AdjustSection.color => color,
        AdjustSection.detail => detail,
      };

  /// Every row of the panel.
  static final List<PropertyKey<Object?>> all = List.unmodifiable(<PropertyKey<Object?>>[...light, ...color, ...detail]);

  /// The properties the before/after view neutralizes (opacity is placement, not an adjustment).
  static final List<PropertyKey<Object?>> adjustments = List.unmodifiable(<PropertyKey<Object?>>[...light, ...color, ...detail.take(3)]);
}

/// The commands of the Adjust panel, separated from the widgets so tests and the "apply to all"
/// footer share them.
abstract final class AdjustCommands {
  /// [visual] with neutral adjust and detail and no look: the original picture (ux.md §10.6).
  static VisualProps original(VisualProps visual) => visual.copyWith(adjust: ColorAdjust.neutral, detail: DetailFx.none, look: null);

  /// The command a before/after hold runs on [item]: neutral parameters, keys of the adjustments
  /// cleared so keyed values do not keep animating.
  static EditCommand bypass(MediaClip item) => CompositeCommand('Original', [
        for (final k in AdjustRows.adjustments)
          if (_animated(item, k)) ClearKeyframes([item.id], property: k.id),
        SetVisual([item.id], original(item.visual ?? VisualProps.neutral)),
      ]);

  /// "Reset all": neutral rows (adjust, detail, opacity 1) and no keys on them.
  static EditCommand resetAll(MediaClip item) {
    final visual = item.visual ?? VisualProps.neutral;
    return CompositeCommand(ColorStrings.historyResetAll, [
      for (final k in AdjustRows.all)
        if (_animated(item, k)) ClearKeyframes([item.id], property: k.id),
      SetVisual(
          [item.id], visual.copyWith(adjust: ColorAdjust.neutral, detail: DetailFx.none, transform: visual.transform.copyWith(opacity: 1))),
    ]);
  }

  /// "Apply to all clips": the adjust, detail and opacity values of [source] at absolute time [at]
  /// on every [targets] clip, one command. Keys of those rows on the targets are cleared so the
  /// values are the same everywhere.
  static EditCommand applyToAll(MediaClip source, TimeUs at, List<MediaClip> targets) {
    double v(PropertyKey<Object?> key) => (evaluate<Object?>(source, key, _local(source, at)) as num).toDouble();
    final adjust = ColorAdjust(
      exposure: v(PropertyKeys.exposure),
      brightness: v(PropertyKeys.brightness),
      contrast: v(PropertyKeys.contrast),
      highlights: v(PropertyKeys.highlights),
      shadows: v(PropertyKeys.shadows),
      saturation: v(PropertyKeys.saturation),
      temperature: v(PropertyKeys.temperature),
      tint: v(PropertyKeys.tint),
    );
    final detail = DetailFx(sharpness: v(PropertyKeys.sharpness), blur: v(PropertyKeys.blur), vignette: v(PropertyKeys.vignette));
    final opacity = v(PropertyKeys.opacity);
    final ids = [for (final t in targets) t.id];
    return CompositeCommand(ColorStrings.historyApplyToAll, [
      for (final k in AdjustRows.all)
        if (targets.any((t) => _animated(t, k))) ClearKeyframes(ids, property: k.id),
      for (final t in targets)
        SetVisual(
            [t.id],
            (t.visual ?? VisualProps.neutral).copyWith(
                adjust: adjust, detail: detail, transform: (t.visual ?? VisualProps.neutral).transform.copyWith(opacity: opacity))),
    ]);
  }

  /// Keys (or, when every row has one at [at], removes them) for [keys] of [item] at absolute [at].
  static EditCommand keyframeAll(MediaClip item, List<PropertyKey<Object?>> keys, TimeUs at) {
    final local = _local(item, at);
    final status = aggregateStatus(item, keys, at);
    if (status.state == KeyframeToggleState.atPlayhead) {
      return CompositeCommand(ColorStrings.historyRemoveKeys, [
        for (final k in keys)
          if (KeyframeOps.hasKeyAt(keyframesOf(item), k, local)) RemoveKeyframe(KeyframeRef(item.id, k.id, local)),
      ]);
    }
    return CompositeCommand(ColorStrings.historyKeyframeAll, [
      for (final k in keys)
        if (!KeyframeOps.hasKeyAt(keyframesOf(item), k, local)) AddKeyframe(KeyframeRef(item.id, k.id, local)),
    ]);
  }

  /// The keyframe state of a whole section: at the playhead when every row has a key there,
  /// animated when any row has keys, else static.
  static KeyframeStatus aggregateStatus(MediaClip item, List<PropertyKey<Object?>> keys, TimeUs playhead) {
    var at = 0;
    var animated = 0;
    var enabled = true;
    for (final k in keys) {
      final s = KeyframeStatus.of(item, k, playhead);
      enabled = s.enabled;
      if (s.state == KeyframeToggleState.atPlayhead) at++;
      if (s.animated) animated++;
    }
    if (keys.isNotEmpty && at == keys.length) return KeyframeStatus(KeyframeToggleState.atPlayhead, enabled: enabled);
    if (animated > 0) return KeyframeStatus(KeyframeToggleState.animated, enabled: enabled);
    return KeyframeStatus(KeyframeToggleState.none, enabled: enabled);
  }

  static bool _animated(MediaClip item, PropertyKey<Object?> key) => key.keyframable && KeyframeOps.isAnimated(keyframesOf(item), key);

  static TimeUs _local(TimelineItem item, TimeUs at) => (at - item.start).clamp(0, item.duration > 0 ? item.duration - 1 : 0).toInt();
}

/// The Adjust panel (ux.md §10.6).
class AdjustPanel extends ConsumerStatefulWidget {
  /// Creates the panel.
  const AdjustPanel({super.key, required this.route});

  /// What the panel edits.
  final AdjustInspector route;

  @override
  ConsumerState<AdjustPanel> createState() => _AdjustPanelState();
}

class _AdjustPanelState extends ConsumerState<AdjustPanel> {
  static const double _topRowHeight = 56;

  AdjustSection _section = AdjustSection.light;
  EditTransaction? _compare;
  bool _comparing = false;

  EditorController get _editor => ref.read(editorControllerProvider(EditorScope.idOf(context)).notifier);

  MediaClip? _item() {
    final id = EditorScope.idOf(context);
    final item = ref.read(editorControllerProvider(id)).project?.index.item(widget.route.item);
    return item is MediaClip && item.visual != null ? item : null;
  }

  @override
  void dispose() {
    _endCompare(notify: false);
    super.dispose();
  }

  // ---- Before / after ----------------------------------------------------------------------------

  void _setCompare(bool on) {
    if (on == _comparing) return;
    if (on) {
      final item = _item();
      if (item == null) return;
      final t = _editor.beginTransaction('Compare original');
      t.update(AdjustCommands.bypass(item));
      _compare = t;
      setState(() => _comparing = true);
    } else {
      _endCompare();
    }
  }

  void _endCompare({bool notify = true}) {
    final t = _compare;
    _compare = null;
    if (t != null && t.isOpen) t.cancel();
    if (_comparing) {
      _comparing = false;
      if (notify && mounted) setState(() {});
    }
  }

  // ---- Footer and header actions -------------------------------------------------------------

  void _run(EditCommand command, {String? toast}) {
    _endCompare();
    final EditResult result = _editor.apply(command);
    if (toast != null && result.applied && mounted) DanaviewToast.show(context, toast, icon: Icons.check_circle_outline_rounded);
  }

  List<MediaClip> _lanePeers(MediaClip item) {
    final id = EditorScope.idOf(context);
    final project = ref.read(editorControllerProvider(id)).project;
    final loc = project?.index.locate(item.id);
    if (loc == null) return const [];
    return [
      for (final i in loc.track.items)
        if (i is MediaClip && i.visual != null && i.id != item.id) i,
    ];
  }

  void _applyToAll() {
    final item = _item();
    if (item == null) return;
    final peers = _lanePeers(item);
    if (peers.isEmpty) return;
    final id = EditorScope.idOf(context);
    final playhead = ref.read(playheadProvider(id)).value;
    _run(AdjustCommands.applyToAll(item, playhead, peers), toast: ColorStrings.appliedToClips(peers.length));
  }

  void _resetAll() {
    final item = _item();
    if (item != null) _run(AdjustCommands.resetAll(item));
  }

  void _keyframeAll() {
    final item = _item();
    if (item == null) return;
    final id = EditorScope.idOf(context);
    _run(AdjustCommands.keyframeAll(item, AdjustRows.of(_section), ref.read(playheadProvider(id)).value));
  }

  // ---- Build ---------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final id = EditorScope.idOf(context);
    final item = ref.watch(editorControllerProvider(id).select((s) => s.project?.index.item(widget.route.item)));
    if (item is! MediaClip || item.visual == null) return const SizedBox.shrink();
    final locked = ref.watch(editorControllerProvider(id).select((s) => s.project?.index.locate(widget.route.item)?.track.locked ?? false));
    final ready = ref.watch(editorControllerProvider(id).select((s) => s.isReady));
    final keys = AdjustRows.of(_section);
    final anyAnimated = AdjustRows.all.any((k) => k.keyframable && KeyframeOps.isAnimated(keyframesOf(item), k));
    final peers = _lanePeers(item).length;
    final playhead = ref.watch(playheadProvider(id));
    // The header's keyframe-all follows the playhead; the body (the child) does not rebuild with it.
    return ValueListenableBuilder<TimeUs>(
      valueListenable: playhead,
      child: _body(item, keys, ready: ready && !locked, locked: locked, peers: peers),
      builder: (context, t, body) => InspectorHeaderActions.publish(
        actions: InspectorHeaderActions(
          onReset: _resetAll,
          resetRemovesKeyframes: anyAnimated,
          keyframeAll: AdjustCommands.aggregateStatus(item, keys, t),
          onKeyframeAll: _keyframeAll,
        ),
        child: body!,
      ),
    );
  }

  Widget _body(MediaClip item, List<PropertyKey<Object?>> keys, {required bool ready, required bool locked, required int peers}) {
    return LayoutBuilder(builder: (context, constraints) => _column(item, keys, constraints, ready: ready, locked: locked, peers: peers));
  }

  Widget _column(MediaClip item, List<PropertyKey<Object?>> keys, BoxConstraints constraints,
      {required bool ready, required bool locked, required int peers}) {
    // The section row stays pinned above the scrolling rows. In a very short pane (the 240 px dock
    // at large text, a phone in landscape) it may take at most half of the height and scrolls itself.
    final topMax = constraints.hasBoundedHeight ? (constraints.maxHeight * 0.5).clamp(_topRowHeight, double.infinity) : double.infinity;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: topMax),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(DanaviewSpacing.lg, DanaviewSpacing.sm, DanaviewSpacing.lg, DanaviewSpacing.xs),
              child: Row(
                children: [
                  Expanded(
                    child: Semantics(
                      container: true,
                      label: ColorStrings.sectionsLabel,
                      child: DanaviewSegmentedControl<AdjustSection>(
                        value: _section,
                        enabled: true,
                        onChanged: (s) => setState(() => _section = s),
                        options: const [
                          DanaviewOption(value: AdjustSection.light, label: ColorStrings.sectionLight),
                          DanaviewOption(value: AdjustSection.color, label: ColorStrings.sectionColor),
                          DanaviewOption(value: AdjustSection.detail, label: ColorStrings.sectionDetail),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: DanaviewSpacing.sm),
                  CompareButton(active: _comparing, enabled: ready, onHold: _setCompare),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.lg),
                sliver: SliverToBoxAdapter(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (locked) _Notice(ColorStrings.trackLocked),
                    ...InspectorRows.forItem(item.id, keys),
                    const SizedBox(height: DanaviewSpacing.md),
                    Wrap(
                      spacing: DanaviewSpacing.sm,
                      runSpacing: DanaviewSpacing.sm,
                      children: [
                        Semantics(
                          hint: peers == 0 ? ColorStrings.applyToAllSingle : ColorStrings.applyToAllHint,
                          child: DanaviewButton.secondary(
                            key: const ValueKey<String>('adjust.applyAll'),
                            label: ColorStrings.applyToAll,
                            icon: Icons.copy_all_rounded,
                            onPressed: ready && peers > 0 ? _applyToAll : null,
                          ),
                        ),
                        DanaviewButton.ghost(
                          key: const ValueKey<String>('adjust.resetAll'),
                          label: ColorStrings.resetAll,
                          icon: Icons.settings_backup_restore_rounded,
                          onPressed: ready ? _resetAll : null,
                        ),
                      ],
                    ),
                    if (peers == 0)
                      Padding(
                        padding: const EdgeInsets.only(top: DanaviewSpacing.xs),
                        child: Text(ColorStrings.applyToAllSingle, style: _hintStyle),
                      ),
                    const SizedBox(height: DanaviewSpacing.lg),
                  ]),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

TextStyle get _hintStyle => DanaviewTextStyles.caption.copyWith(fontFamily: DanaviewFonts.family, color: DanaviewColors.textMuted);

class _Notice extends StatelessWidget {
  const _Notice(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: DanaviewSpacing.xs),
        child: Text(text, style: _hintStyle.copyWith(color: DanaviewColors.warning)),
      );
}

/// The before/after button (ux.md §10.6): shows the original while a pointer is down on it. Assistive
/// technology activates it as a toggle, since it cannot hold a press.
class CompareButton extends StatelessWidget {
  /// Creates the button.
  const CompareButton({super.key, required this.active, required this.onHold, this.enabled = true});

  /// Whether the original is showing.
  final bool active;

  /// Whether pressing does anything.
  final bool enabled;

  /// Called with true when the press starts and false when it ends or is cancelled.
  final ValueChanged<bool> onHold;

  /// Diameter.
  static const double size = 44;

  @override
  Widget build(BuildContext context) {
    final color = active ? DanaviewColors.primaryTonal : DanaviewColors.surfaceElevated;
    return Semantics(
      button: true,
      toggled: active,
      enabled: enabled,
      label: ColorStrings.compare,
      hint: ColorStrings.compareHint,
      excludeSemantics: true,
      onTap: enabled ? () => onHold(!active) : null,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: enabled ? (_) => onHold(true) : null,
        onPointerUp: (_) => onHold(false),
        onPointerCancel: (_) => onHold(false),
        child: Opacity(
          opacity: enabled ? 1 : DanaviewColors.disabledOpacity,
          child: Container(
            key: const ValueKey<String>('adjust.compare'),
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: const Border.fromBorderSide(DanaviewBorders.hairline),
              boxShadow: active ? DanaviewShadows.none : DanaviewShadows.subtle,
            ),
            child: Icon(Icons.compare_rounded, size: 22, color: active ? DanaviewColors.primaryLight : DanaviewColors.textPrimary),
          ),
        ),
      ),
    );
  }
}
