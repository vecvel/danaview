// OWNER: UX-25
//
// The speed panel (ux.md §10.3, D-15) for one video or audio clip: Constant | Curve.
//
// * Constant: nine chips (0.25x-4x, `speedPresets`) and a custom field (0.1-10x, limited to the
//   engine's `minSpeed`/`maxSpeed`). Every choice is one `SetSpeed`: one history entry
//   "Change speed"; steps of the field that come < 500 ms apart share one.
// * Curve: the ramp presets (Montage, Hero, Bullet, Jump cut, Flash in, Flash out, Custom) and the
//   `SpeedCurveEditor`. Dragging a point is one transaction; adding or deleting a point, nudges and
//   typed values are commands. Number fields and buttons for the selected point are the
//   non-gesture alternative to the curve's gestures. Switching to Curve starts from a flat curve at
//   the current speed; switching to Constant goes to 1x.
// * Footer: "Duration 0:12:00 → 0:06:00" (the clip's length at normal speed and now, on the
//   project's frame grid: the clip's real duration), "Keep audio pitch" (hidden for media without
//   audio) and the capability note when audio is muted at the chosen speed
//   (`capabilities.maxAudioSpeed`).
// * Reverse and Freeze frame run the UX-35 actions through the registry (disabled while unbound
//   or not applicable).
// * Reset (header) returns to 1x. The panel owns its scrolling.
//
// A link partner that shares the clip's time map follows (core `SetSpeed`); ripple follows the
// project's ripple mode.

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/eval.dart' show ClipTimeMap;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show EditCommand, SetSpeed, SpeedRampPresets;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../../app/strings/speed_strings.dart';
import '../actions/editor_action_registry.dart';
import '../contracts/contracts.dart';
import '../editor_scope.dart';
import '../inspector/inspector_header.dart';
import '../inspector/inspector_rows.dart' show InspectorEditSession;
import '../state/editor_controller.dart';
import '../state/editor_state.dart';
import '../timeline/timeline_semantics.dart' show editorAnnounce;
import 'speed_curve_editor.dart';

enum _Mode { constant, curve }

/// What the panel reads of the project: the clip and what depends on its media and track.
typedef _View = ({MediaClip? clip, bool hasAudio, bool locked, FrameRate rate});

_View _viewOf(EditorState s, ItemId id) {
  final project = s.project;
  final loc = project?.index.locate(id);
  final item = loc?.item;
  if (project == null || loc == null || item is! MediaClip) {
    return (clip: null, hasAudio: false, locked: false, rate: project?.settings.frameRate ?? FrameRate.fps30);
  }
  final asset = project.pool[item.media];
  return (clip: item, hasAudio: asset == null || asset.probe.hasAudio, locked: loc.track.locked, rate: project.settings.frameRate);
}

/// The speed panel (ux.md §10.3).
class SpeedPanel extends ConsumerStatefulWidget {
  /// Creates the panel for [route].
  const SpeedPanel({super.key, required this.route});

  /// What the panel edits.
  final SpeedInspector route;

  @override
  ConsumerState<SpeedPanel> createState() => _SpeedPanelState();
}

class _SpeedPanelState extends ConsumerState<SpeedPanel> {
  InspectorEditSession? _session;
  int? _selected;

  ItemId get _item => widget.route.item;

  @override
  void dispose() {
    _session?.dispose();
    super.dispose();
  }

  InspectorEditSession _sessionFor(EditorController editor) {
    final key = 'speed:$_item';
    final s = _session ??= InspectorEditSession(editor: editor, label: 'Change speed', coalesceKey: key);
    s
      ..editor = editor
      ..coalesceKey = key;
    return s;
  }

  EditorController get _editor => ref.read(editorControllerProvider(EditorScope.idOf(context)).notifier);

  // ---- Edits ---------------------------------------------------------------------------------

  EditCommand _speed(SpeedSpec spec, {bool? pitch}) => SetSpeed(_item, spec, maintainPitch: pitch);

  void _apply(SpeedSpec spec, {bool? pitch}) => _sessionFor(_editor).apply(_speed(spec, pitch: pitch));

  void _reset() {
    _selected = null;
    _apply(SpeedSpec.normal);
  }

  /// A number field's value: a stepper press or a scrub is one gesture, a typed value one command.
  void _field(EditCommand command) {
    final session = _sessionFor(_editor);
    session.active ? session.change(command) : session.apply(command);
  }

  void _setMode(_Mode mode, MediaClip clip, double lo, double hi) {
    final speed = clip.speed;
    _selected = null;
    switch (mode) {
      case _Mode.constant:
        if (speed is! ConstantSpeed) _apply(ConstantSpeed(SpeedRampEdit.cleanSpeed(1, lo: lo, hi: hi)));
      case _Mode.curve:
        if (speed is ConstantSpeed) _apply(SpeedRampEdit.flat(SpeedRampEdit.cleanSpeed(speed.rate, lo: lo, hi: hi)));
    }
  }

  void _preset(String id, double lo, double hi) {
    final ramp = SpeedRampPresets.byId(id);
    if (ramp == null) return;
    var changed = false;
    final points = [
      for (final p in ramp.points)
        if (p.y < lo || p.y > hi)
          () {
            changed = true;
            return p.copyWith(y: p.y.clamp(lo, hi).toDouble());
          }()
        else
          p,
    ];
    _selected = null;
    _apply(changed ? ramp.copyWith(points: points, presetId: null) : ramp);
  }

  void _structure(SpeedRamp ramp, int? selected, String announcement) {
    _sessionFor(_editor).apply(_speed(ramp));
    setState(() => _selected = selected);
    editorAnnounce(context, announcement);
  }

  void _addPoint(SpeedRamp ramp, double lo, double hi) {
    final added = SpeedRampEdit.addAtWidestGap(ramp, lo: lo, hi: hi);
    if (added == null) return;
    _structure(added.$1, added.$2, SpeedStrings.pointAdded(added.$1.points.length));
  }

  void _deletePoint(SpeedRamp ramp, int i) {
    final next = SpeedRampEdit.removePoint(ramp, i);
    if (next == null) return;
    _structure(next, null, SpeedStrings.pointDeleted(next.points.length));
  }

  // ---- Build ---------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final id = EditorScope.idOf(context);
    final view = ref.watch(editorControllerProvider(id).select((s) => _viewOf(s, _item)));
    final ready = ref.watch(editorControllerProvider(id).select((s) => s.isReady));
    final editor = ref.read(editorControllerProvider(id).notifier);
    _sessionFor(editor);
    final clip = view.clip;
    if (clip == null) {
      return const _Message(SpeedStrings.clipGone);
    }
    final caps = editor.session.capabilities;
    final lo = (caps?.minSpeed ?? minClipSpeed).clamp(minClipSpeed, maxClipSpeed).toDouble();
    final hi = (caps?.maxSpeed ?? maxClipSpeed).clamp(minClipSpeed, maxClipSpeed).toDouble();
    final maxAudio = caps?.maxAudioSpeed ?? 4;
    final enabled = ready && !view.locked;
    final speed = clip.speed;
    final mode = speed is SpeedRamp ? _Mode.curve : _Mode.constant;
    final ramp = speed is SpeedRamp ? speed : null;
    final selected = ramp == null || _selected == null || _selected! >= ramp.points.length ? null : _selected;

    final map = _mapOf(clip, view.rate);
    final normal = map == null ? clip.duration : ClipTimeMap.durationFor(map.sourceRange, SpeedSpec.normal, view.rate);
    final from = Timecode.format(normal, view.rate);
    final to = Timecode.format(clip.duration, view.rate);

    final fastest = ramp == null ? (speed as ConstantSpeed).rate : SpeedRampEdit.fastest(ramp);
    final audioPlays = view.hasAudio && !clip.audio.muted && !clip.detachedAudio;
    final mutedNote = audioPlays && fastest > maxAudio
        ? (ramp == null ? SpeedStrings.audioMutedAbove(maxAudio) : SpeedStrings.audioMutedWhere(maxAudio))
        : null;

    final body = CustomScrollView(
      key: const ValueKey<String>('speed.scroll'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          sliver: SliverToBoxAdapter(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            DanaviewSegmentedControl<_Mode>(
              key: const ValueKey<String>('speed.mode'),
              value: mode,
              enabled: enabled,
              options: const [
                DanaviewOption<_Mode>(value: _Mode.constant, label: SpeedStrings.modeConstant),
                DanaviewOption<_Mode>(value: _Mode.curve, label: SpeedStrings.modeCurve),
              ],
              onChanged: (m) => _setMode(m, clip, lo, hi),
            ),
            const SizedBox(height: 12),
            if (mode == _Mode.constant)
              ..._constant(clip, (speed as ConstantSpeed).rate, enabled, lo, hi)
            else
              ..._curve(ramp!, selected, enabled, lo, hi),
            const SizedBox(height: 16),
            _DurationRow(from: from, to: to),
            if (mutedNote != null) ...[
              const SizedBox(height: 8),
              _Note(key: const ValueKey<String>('speed.audioNote'), text: mutedNote, icon: Icons.volume_off_rounded),
            ],
            if (view.hasAudio) ...[
              const SizedBox(height: 8),
              DanaviewSwitchRow(
                key: const ValueKey<String>('speed.keepPitch'),
                title: SpeedStrings.keepPitch,
                subtitle: SpeedStrings.keepPitchHint,
                value: clip.maintainPitch,
                onChanged: enabled ? (v) => _apply(clip.speed, pitch: v) : null,
              ),
            ],
            const SizedBox(height: 12),
            _EntryPoints(clip: clip, enabled: enabled, playhead: ref.read(playheadProvider(id))),
            if (view.locked) ...[
              const SizedBox(height: 12),
              const _Note(key: ValueKey<String>('speed.lockedNote'), text: SpeedStrings.trackLocked, icon: Icons.lock_rounded),
            ],
          ])),
        ),
      ],
    );
    return InspectorHeaderActions.publish(
      actions: InspectorHeaderActions(onReset: enabled && (speed != SpeedSpec.normal) ? _reset : null),
      child: body,
    );
  }

  ClipTimeMap? _mapOf(MediaClip clip, FrameRate rate) {
    try {
      return ClipTimeMap.forClip(clip, rate);
    } on ArgumentError {
      return null;
    }
  }

  // ---- Constant ------------------------------------------------------------------------------

  List<Widget> _constant(MediaClip clip, double rate, bool enabled, double lo, double hi) {
    return [
      DanaviewChipGroup(
        key: const ValueKey<String>('speed.chips'),
        children: [
          for (final preset in speedPresets)
            DanaviewChoiceChip(
              key: ValueKey<String>('speed.chip.$preset'),
              label: SpeedStrings.rate(preset),
              selected: rate == preset,
              enabled: enabled && preset >= lo && preset <= hi,
              onTap: () => _apply(ConstantSpeed(preset)),
            ),
        ],
      ),
      const SizedBox(height: 12),
      DanaviewNumberField(
        key: const ValueKey<String>('speed.custom'),
        label: SpeedStrings.customSpeed,
        semanticLabel: SpeedStrings.customSpeedSemantics,
        value: rate.clamp(lo, hi).toDouble(),
        min: lo,
        max: hi,
        step: 0.1,
        fractionDigits: 2,
        unit: '×',
        enabled: enabled,
        onChangeStart: (_) => _sessionFor(_editor).start(),
        onChanged: (v) => _field(_speed(ConstantSpeed(SpeedRampEdit.cleanSpeed(v, lo: lo, hi: hi)))),
        onChangeEnd: (_) => _sessionFor(_editor).end(),
      ),
    ];
  }

  // ---- Curve ---------------------------------------------------------------------------------

  List<Widget> _curve(SpeedRamp ramp, int? selected, bool enabled, double lo, double hi) {
    final session = _sessionFor(_editor);
    final canAdd = ramp.points.length < SpeedRampEdit.maxPoints;
    return [
      _Heading(SpeedStrings.presetsHeading),
      DanaviewChipGroup(
        key: const ValueKey<String>('speed.presets'),
        children: [
          for (final id in SpeedRampPresets.ids)
            DanaviewChoiceChip(
              key: ValueKey<String>('speed.preset.$id'),
              label: SpeedStrings.presetName(id) ?? id,
              selected: ramp.presetId == id,
              enabled: enabled,
              onTap: () => _preset(id, lo, hi),
            ),
          DanaviewChoiceChip(
            key: const ValueKey<String>('speed.preset.custom'),
            label: SpeedStrings.presetCustom,
            selected: ramp.presetId == null,
            enabled: enabled,
            onTap: () {
              if (ramp.presetId != null) _apply(ramp.copyWith(presetId: null));
            },
          ),
        ],
      ),
      const SizedBox(height: 12),
      _Heading(SpeedStrings.curveHeading),
      SpeedCurveEditor(
        key: const ValueKey<String>('speed.curve'),
        ramp: ramp,
        selected: selected,
        enabled: enabled,
        minSpeed: lo,
        maxSpeed: hi,
        onSelected: (i) => setState(() => _selected = i),
        onChangeStart: session.start,
        onChanged: (r) => session.change(_speed(r)),
        onChangeEnd: session.end,
        onStep: (r, {selected}) {
          session.step(_speed(r));
          if (selected != null) setState(() => _selected = selected);
        },
        onStructure: (r, {selected}) => _structure(
          r,
          selected,
          r.points.length > ramp.points.length ? SpeedStrings.pointAdded(r.points.length) : SpeedStrings.pointDeleted(r.points.length),
        ),
      ),
      const SizedBox(height: 8),
      const _Caption(SpeedStrings.curveGestures),
      const SizedBox(height: 12),
      if (selected != null) ..._pointFields(ramp, selected, enabled, lo, hi),
      Wrap(spacing: 8, runSpacing: 8, children: [
        DanaviewButton(
          key: const ValueKey<String>('speed.addPoint'),
          label: SpeedStrings.addPoint,
          icon: Icons.add_rounded,
          size: DanaviewButtonSize.sm,
          onPressed: enabled && canAdd ? () => _addPoint(ramp, lo, hi) : null,
        ),
        DanaviewButton(
          key: const ValueKey<String>('speed.deletePoint'),
          label: SpeedStrings.deletePoint,
          icon: Icons.remove_rounded,
          size: DanaviewButtonSize.sm,
          onPressed: enabled && selected != null && SpeedRampEdit.canRemove(ramp, selected) ? () => _deletePoint(ramp, selected) : null,
        ),
      ]),
      if (!canAdd) ...[
        const SizedBox(height: 8),
        const _Caption(SpeedStrings.curveFull),
      ],
    ];
  }

  List<Widget> _pointFields(SpeedRamp ramp, int i, bool enabled, double lo, double hi) {
    final p = ramp.points[i];
    final interior = i > 0 && i < ramp.points.length - 1;
    final session = _sessionFor(_editor);
    return [
      _Heading(SpeedStrings.selectedPoint(i, ramp.points.length)),
      DanaviewNumberField(
        key: const ValueKey<String>('speed.pointSpeed'),
        label: SpeedStrings.pointSpeed,
        semanticLabel: SpeedStrings.pointSpeed,
        value: p.y.clamp(lo, hi).toDouble(),
        min: lo,
        max: hi,
        step: 0.1,
        fractionDigits: 2,
        unit: '×',
        enabled: enabled,
        onChangeStart: (_) => session.start(),
        onChanged: (v) => _field(_speed(SpeedRampEdit.movePoint(ramp, i, y: v, lo: lo, hi: hi))),
        onChangeEnd: (_) => session.end(),
      ),
      const SizedBox(height: 8),
      DanaviewNumberField(
        key: const ValueKey<String>('speed.pointPosition'),
        label: SpeedStrings.pointPosition,
        semanticLabel: SpeedStrings.pointPosition,
        value: p.x * 100,
        min: 0,
        max: 100,
        step: 1,
        fractionDigits: 0,
        unit: '%',
        enabled: enabled && interior,
        onChangeStart: (_) => session.start(),
        onChanged: (v) => _field(_speed(SpeedRampEdit.movePoint(ramp, i, x: v / 100, lo: lo, hi: hi))),
        onChangeEnd: (_) => session.end(),
      ),
      const SizedBox(height: 12),
    ];
  }
}

// -------------------------------------------------------------------------------------------------
// Small parts
// -------------------------------------------------------------------------------------------------

TextStyle get _captionStyle => DanaviewTextStyles.caption.copyWith(fontFamily: DanaviewFonts.family, color: DanaviewColors.textSecondary);

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Semantics(
          header: true,
          child: Text(
            text,
            style: DanaviewTextStyles.body
                .copyWith(fontFamily: DanaviewFonts.family, fontWeight: FontWeight.w600, color: DanaviewColors.textSecondary, fontSize: 13),
          ),
        ),
      );
}

class _Caption extends StatelessWidget {
  const _Caption(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(text, style: _captionStyle);
}

class _Message extends StatelessWidget {
  const _Message(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Align(alignment: Alignment.topLeft, child: Text(text, style: _captionStyle)),
      );
}

/// A quiet explanation with an icon (capability note, locked track).
class _Note extends StatelessWidget {
  const _Note({super.key, required this.text, required this.icon});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: DanaviewColors.surfaceElevatedHigher,
          borderRadius: DanaviewRadius.smAll,
          border: Border.fromBorderSide(DanaviewBorders.hairline),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 16, color: DanaviewColors.warning)),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: _captionStyle.copyWith(color: DanaviewColors.textPrimary))),
          ]),
        ),
      );
}

/// "Duration 00:12:00 → 00:06:00".
class _DurationRow extends StatelessWidget {
  const _DurationRow({required this.from, required this.to});

  final String from;
  final String to;

  @override
  Widget build(BuildContext context) => Semantics(
        label: SpeedStrings.durationSemantics(from, to),
        excludeSemantics: true,
        child: Text(
          SpeedStrings.durationRow(from, to),
          key: const ValueKey<String>('speed.duration'),
          style: DanaviewTextStyles.body.copyWith(
            fontFamily: DanaviewFonts.family,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      );
}

/// Reverse and Freeze frame: the UX-35 actions, run through the registry.
class _EntryPoints extends ConsumerWidget {
  const _EntryPoints({required this.clip, required this.enabled, required this.playhead});

  final MediaClip clip;
  final bool enabled;
  final ValueListenable<TimeUs> playhead;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = EditorScope.idOf(context);
    final registry = ref.watch(editorActionRegistryProvider);
    // The freeze action depends on the playhead being over the clip.
    return ValueListenableBuilder<TimeUs>(
      valueListenable: playhead,
      builder: (context, _, __) {
        final ctx = WidgetActionContext(projectId: id, context: context, ref: ref);
        Widget button(EditorActionId action, String label, IconData icon, {bool on = false}) {
          final spec = registry.spec(action);
          final can = enabled && spec.isBound && spec.isVisible(ctx) && spec.isEnabled(ctx);
          final reason = can ? null : (spec.isBound ? spec.disabledReason(ctx) : SpeedStrings.actionUnavailable);
          return DanaviewButton(
            key: ValueKey<String>('speed.${action.name}'),
            label: label,
            icon: icon,
            variant: on ? DanaviewButtonVariant.tonal : DanaviewButtonVariant.secondary,
            size: DanaviewButtonSize.sm,
            tooltip: reason,
            onPressed: can ? () => registry.invoke(action, WidgetActionContext(projectId: id, context: context, ref: ref)) : null,
          );
        }

        return Wrap(spacing: 8, runSpacing: 8, children: [
          button(EditorActionId.reverse, clip.reversed ? SpeedStrings.reversed : SpeedStrings.reverse, Icons.fast_rewind_rounded,
              on: clip.reversed),
          button(EditorActionId.freeze, SpeedStrings.freeze, Icons.ac_unit_rounded),
        ]);
      },
    );
  }
}
