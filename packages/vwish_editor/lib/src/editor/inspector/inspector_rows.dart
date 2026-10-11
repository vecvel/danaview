// OWNER: UX-16
//
// Inspector rows (ux.md §9.3), built on kit components:
// * InspectorSliderRow: label, KeyframeToggle, VwishSlider (bipolar ranges fill from `origin: 0`),
//   the value as text that turns into a VwishNumberField when tapped; a double-tap on the label (or
//   the semantics action) resets to the default (not on the track, where it would delay taps).
// * InspectorNumberRow (VwishNumberField), InspectorToggleRow (VwishSwitchRow), InspectorChoiceRow
//   (VwishSegmentedControl), InspectorColorRow (ColorField over VwishColorPicker).
// * InspectorPropertyRow generates the right row from `PropertyKey` metadata (CORE-05: name, unit,
//   range, default, step, display scale, keyframable) for one item of the open editor and writes
//   through `SetProperty` (keyframe-aware at the playhead):
//     slider drag     onChangeStart → (first move) beginTransaction(label) → tx.update per move
//                     → onChangeEnd tx.commit(): one history entry, one plan patch;
//     discrete steps  (arrow keys, semantics increase/decrease, a tap on the track): one command
//                     each, coalesced into one history entry while they come < 500 ms apart;
//     typed value, reset and switches: one command each.
//   Keyframed properties show their value at the playhead; static ones never listen to it.
// * `InspectorRows.forItem(item, keys)` builds the rows of a list of keys (panels list the keys
//   of a section; keys that do not apply to the item are left out).

import 'dart:math' as math;

import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vwish_editor_core/eval.dart' show evaluate;
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart' show EditCommand, SetProperty;
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../editor_scope.dart';
import '../state/editor_controller.dart';
import '../state/playhead_controller.dart';
import 'color_field.dart';
import 'keyframe_toggle.dart';

/// Copy of the inspector rows.
abstract final class InspectorRowStrings {
  /// Semantics action that resets a row.
  static const String reset = 'Reset to default';

  /// Semantics hint of the value text.
  static const String editValue = 'Double tap to type a value';

  /// The row label of [key] (the UI's table keyed by id; the core display name otherwise).
  static String labelOf(PropertyKey<Object?> key) => _labels[key.id] ?? key.displayName;

  static const Map<String, String> _labels = {
    'transform.opacity': 'Opacity',
    'audio.volume': 'Volume',
  };

  /// "Position X".
  static String axis(String label, int axis) => '$label ${axis == 0 ? 'X' : 'Y'}';
}

/// Formatting and helpers shared by the rows.
abstract final class InspectorRows {
  /// The clock of the 500 ms step coalescing (tests replace it).
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  /// Steps closer than this join one history entry.
  static const Duration stepCoalesceWindow = Duration(milliseconds: 500);

  /// Fraction digits that show [displayStep] exactly (0..3).
  static int digitsFor(double displayStep) {
    if (!(displayStep > 0) || !displayStep.isFinite) return 0;
    for (var d = 0; d <= 3; d++) {
      final scaled = displayStep * math.pow(10, d);
      if ((scaled - scaled.roundToDouble()).abs() < 1e-6) return d;
    }
    return 3;
  }

  /// [value] (model units) as shown: scaled, rounded and with its unit ("45 %", "-12°", "0.5 s").
  static String format(double value, {double displayScale = 1, int fractionDigits = 0, String unit = ''}) {
    var shown = value * displayScale;
    if (shown.abs() < math.pow(10, -fractionDigits) / 2) shown = 0;
    final text = shown.toStringAsFixed(fractionDigits);
    if (unit.isEmpty) return text;
    return unit == '°' || unit == '%' ? '$text$unit' : '$text $unit';
  }

  /// The rows of [keys] for [item] (keys that do not apply are skipped at build time).
  static List<Widget> forItem(ItemId item, Iterable<PropertyKey<Object?>> keys,
          {Map<String, List<VwishOption<Object?>>> options = const {}}) =>
      [
        for (final k in keys) InspectorPropertyRow(key: ValueKey<String>('row.${k.id}'), item: item, property: k, options: options[k.id]),
      ];
}

TextStyle get _labelStyle => VwishTextStyles.body.copyWith(fontFamily: VwishFonts.family);
TextStyle get _valueStyle => VwishTextStyles.caption.copyWith(
      fontFamily: VwishFonts.family,
      color: VwishColors.textSecondary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

// -------------------------------------------------------------------------------------------------
// Presentational rows
// -------------------------------------------------------------------------------------------------

/// Slider-like row with keyframe toggle and value entry (ux.md §9.3). Values are in model units;
/// the text shows `value × displayScale` with [unit].
class InspectorSliderRow extends StatefulWidget {
  /// Creates the row.
  const InspectorSliderRow({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    this.defaultValue,
    this.step = 0,
    this.displayScale = 1,
    this.unit = '',
    this.fractionDigits,
    this.origin,
    this.keyframeToggle,
    this.onChangeStart,
    this.onChanged,
    this.onChangeEnd,
    this.onSubmitted,
    this.enabled = true,
  });

  /// Label.
  final String label;

  /// Value (model units).
  final double value;

  /// Smallest value.
  final double min;

  /// Largest value.
  final double max;

  /// Default (double-tap reset); null disables reset.
  final double? defaultValue;

  /// Step (model units); 0 for continuous.
  final double step;

  /// Display factor (100 for percentages).
  final double displayScale;

  /// Display unit.
  final String unit;

  /// Shown fraction digits (default: from [step]).
  final int? fractionDigits;

  /// Where the fill starts; defaults to 0 for ranges that cross 0 (bipolar values).
  final double? origin;

  /// The keyframe toggle, or null.
  final Widget? keyframeToggle;

  /// A drag or step starts.
  final ValueChanged<double>? onChangeStart;

  /// Every change.
  final ValueChanged<double>? onChanged;

  /// A drag or step ends.
  final ValueChanged<double>? onChangeEnd;

  /// A typed value or a reset (one command).
  final ValueChanged<double>? onSubmitted;

  /// Whether the row accepts edits.
  final bool enabled;

  /// Fraction digits used for [step] and [displayScale].
  int get digits => fractionDigits ?? InspectorRows.digitsFor(step * displayScale);

  /// The value text.
  String get valueText => InspectorRows.format(value, displayScale: displayScale, fractionDigits: digits, unit: unit);

  @override
  State<InspectorSliderRow> createState() => _InspectorSliderRowState();
}

class _InspectorSliderRowState extends State<InspectorSliderRow> {
  bool _editing = false;
  final FocusNode _fieldFocus = FocusNode(debugLabel: 'InspectorSliderRow.field');

  @override
  void initState() {
    super.initState();
    _fieldFocus.addListener(_onFieldFocus);
  }

  void _onFieldFocus() {
    if (!_fieldFocus.hasFocus && _editing && mounted) setState(() => _editing = false);
  }

  @override
  void dispose() {
    _fieldFocus.removeListener(_onFieldFocus);
    _fieldFocus.dispose();
    super.dispose();
  }

  void _reset() {
    final d = widget.defaultValue;
    if (d == null || !widget.enabled) return;
    widget.onSubmitted?.call(d);
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final enabled = w.enabled && w.onChanged != null;
    final min = math.min(w.min, w.max);
    final max = math.max(w.min, w.max);
    final value = w.value.clamp(min, max).toDouble();
    final span = max - min;
    final divisions = w.step > 0 && span > 0 && span / w.step <= 2000 ? (span / w.step).round() : null;
    final origin = w.origin ?? (min < 0 && max > 0 ? 0.0 : null);
    final displayStep = w.step > 0 ? w.step * w.displayScale : math.pow(10, -w.digits).toDouble();

    final Widget valueWidget = _editing
        ? SizedBox(
            width: 112,
            child: VwishNumberField(
              value: value * w.displayScale,
              min: min * w.displayScale,
              max: max * w.displayScale,
              step: displayStep,
              fractionDigits: w.digits,
              unit: w.unit.isEmpty ? null : w.unit,
              semanticLabel: w.label,
              showSteppers: false,
              autofocus: true,
              focusNode: _fieldFocus,
              enabled: enabled,
              onChanged: (shown) {
                w.onSubmitted?.call(shown / w.displayScale);
                setState(() => _editing = false);
              },
            ),
          )
        : VwishPressable(
            onTap: enabled && w.onSubmitted != null ? () => setState(() => _editing = true) : null,
            semanticLabel: '${w.label}, ${w.valueText}',
            borderRadius: VwishRadius.smAll,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 44, minHeight: 32),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: VwishSpacing.xs),
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  widthFactor: 1,
                  child: Text(w.valueText, maxLines: 1, softWrap: false, style: _valueStyle),
                ),
              ),
            ),
          );

    return Semantics(
      customSemanticsActions:
          w.defaultValue == null || !enabled ? null : {const CustomSemanticsAction(label: InspectorRowStrings.reset): _reset},
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: VwishSpacing.xxs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onDoubleTap: w.defaultValue == null || !enabled ? null : _reset,
                    child: Text(w.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: _labelStyle),
                  ),
                ),
                if (w.keyframeToggle != null) w.keyframeToggle!,
                Flexible(child: valueWidget),
              ],
            ),
            SizedBox(
              height: 32,
              child: VwishSlider(
                value: value,
                min: min,
                max: span > 0 ? max : min + 1,
                divisions: divisions,
                origin: origin,
                semanticLabel: w.label,
                semanticFormatter: (v) => InspectorRows.format(v, displayScale: w.displayScale, fractionDigits: w.digits, unit: w.unit),
                onChangeStart: enabled ? w.onChangeStart : null,
                onChanged: enabled && span > 0 ? w.onChanged : null,
                onChangeEnd: enabled ? w.onChangeEnd : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Numeric row (ux.md §9.3): label and a VwishNumberField.
class InspectorNumberRow extends StatelessWidget {
  /// Creates the row; values are in display units.
  const InspectorNumberRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.min = double.negativeInfinity,
    this.max = double.infinity,
    this.step = 1,
    this.fractionDigits,
    this.unit,
    this.keyframeToggle,
    this.enabled = true,
  });

  /// Label.
  final String label;

  /// Value.
  final double value;

  /// Committed edits.
  final ValueChanged<double>? onChanged;

  /// Smallest value.
  final double min;

  /// Largest value.
  final double max;

  /// Step.
  final double step;

  /// Fraction digits.
  final int? fractionDigits;

  /// Unit.
  final String? unit;

  /// The keyframe toggle, or null.
  final Widget? keyframeToggle;

  /// Whether the row accepts edits.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: VwishSpacing.xs),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final fieldWidth = math.min(VwishNumberField.minWidthForSteppers, constraints.maxWidth * 0.5);
          return Row(
            children: [
              Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: _labelStyle)),
              if (keyframeToggle != null) keyframeToggle!,
              SizedBox(
                width: fieldWidth,
                child: VwishNumberField(
                  value: value,
                  min: min,
                  max: max,
                  step: step,
                  fractionDigits: fractionDigits,
                  unit: unit,
                  semanticLabel: label,
                  showSteppers: fieldWidth >= VwishNumberField.minWidthForSteppers,
                  enabled: enabled,
                  onChanged: enabled ? onChanged : null,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Switch row (ux.md §9.3).
class InspectorToggleRow extends StatelessWidget {
  /// Creates the row.
  const InspectorToggleRow({super.key, required this.label, required this.value, required this.onChanged, this.subtitle});

  /// Label.
  final String label;

  /// Value.
  final bool value;

  /// Edits (null disables the row).
  final ValueChanged<bool>? onChanged;

  /// Optional second line.
  final String? subtitle;

  @override
  Widget build(BuildContext context) => VwishSwitchRow(title: label, subtitle: subtitle, value: value, onChanged: onChanged, dense: true);
}

/// Segmented or chip choice row (ux.md §9.3).
class InspectorChoiceRow<T> extends StatelessWidget {
  /// Creates the row.
  const InspectorChoiceRow(
      {super.key, required this.label, required this.value, required this.options, required this.onChanged, this.enabled = true});

  /// Label.
  final String label;

  /// Value.
  final T value;

  /// Options.
  final List<VwishOption<T>> options;

  /// Edits.
  final ValueChanged<T> onChanged;

  /// Whether the row accepts edits.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: VwishSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: _labelStyle),
          const SizedBox(height: VwishSpacing.xs),
          VwishSegmentedControl<T>(value: value, options: options, onChanged: onChanged, enabled: enabled),
        ],
      ),
    );
  }
}

/// Colour swatch row (ux.md §9.3).
class InspectorColorRow extends StatelessWidget {
  /// Creates the row.
  const InspectorColorRow({
    super.key,
    required this.label,
    required this.color,
    required this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
    this.showOpacity = false,
    this.enabled = true,
  });

  /// Label.
  final String label;

  /// Colour.
  final Color color;

  /// Every edit.
  final ValueChanged<Color> onChanged;

  /// A gesture starts.
  final ValueChanged<Color>? onChangeStart;

  /// A gesture ends.
  final ValueChanged<Color>? onChangeEnd;

  /// Shows the opacity strip.
  final bool showOpacity;

  /// Whether the row accepts edits.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: VwishSpacing.xxs),
      child: Row(
        children: [
          Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: _labelStyle)),
          Flexible(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: VwishSpacing.sm),
              child: Text(
                ColorFieldStrings.value(color, alpha: showOpacity),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _valueStyle,
              ),
            ),
          ),
          ColorField(
            color: color,
            label: label,
            showOpacity: showOpacity,
            enabled: enabled,
            onChangeStart: onChangeStart,
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ],
      ),
    );
  }
}

// -------------------------------------------------------------------------------------------------
// Rows generated from PropertyKey metadata
// -------------------------------------------------------------------------------------------------

/// Turns slider and colour gestures into history entries (see the file comment).
class InspectorEditSession {
  /// Creates the session for edits of [editor] labelled [label]; [coalesceKey] names the property
  /// (steps of the same property within 500 ms join one entry).
  InspectorEditSession({required this.editor, required this.label, required this.coalesceKey});

  /// The editor.
  EditorController editor;

  /// History label.
  String label;

  /// Coalescing key base.
  String coalesceKey;

  EditTransaction? _tx;
  EditCommand? _pending;
  int _changes = 0;
  bool _active = false;
  DateTime? _lastStep;
  int _serial = 0;

  /// Whether a gesture is running.
  bool get active => _active;

  /// A gesture starts.
  void start() {
    _active = true;
    _changes = 0;
    _pending = null;
  }

  /// A gesture moves to [command]'s value. The first change is held: a single change followed by
  /// [end] is a discrete step; a second change opens the transaction.
  void change(EditCommand command) {
    if (!_active) start();
    _changes++;
    final tx = _tx;
    if (tx != null) {
      tx.update(command);
      return;
    }
    if (_changes == 1) {
      _pending = command;
      return;
    }
    _pending = null;
    (_tx = editor.beginTransaction(label)).update(command);
  }

  /// The gesture ends: commits the transaction, or applies the single step.
  void end() {
    final tx = _tx;
    final pending = _pending;
    _tx = null;
    _pending = null;
    _active = false;
    _changes = 0;
    if (tx != null) {
      if (tx.isOpen) tx.commit();
    } else if (pending != null) {
      step(pending);
    }
  }

  /// One discrete step, joined with the previous one when it came less than 500 ms ago.
  void step(EditCommand command) {
    final now = InspectorRows.clock();
    final last = _lastStep;
    if (last == null || now.difference(last) >= InspectorRows.stepCoalesceWindow) _serial++;
    _lastStep = now;
    editor.apply(command, coalesceKey: '$coalesceKey#$_serial');
  }

  /// One command outside any gesture (typed value, reset, switch).
  void apply(EditCommand command) {
    _lastStep = null;
    editor.apply(command);
  }

  /// Commits an open gesture (the row goes away mid-drag).
  void dispose() {
    final tx = _tx;
    _tx = null;
    if (tx != null && tx.isOpen) tx.commit();
  }
}

/// The row of [property] for [item] in the open editor, generated from the property's metadata.
class InspectorPropertyRow extends ConsumerStatefulWidget {
  /// Creates the row; [options] are required for choice properties (else the row is empty).
  const InspectorPropertyRow({super.key, required this.item, required this.property, this.label, this.options});

  /// The item.
  final ItemId item;

  /// The property.
  final PropertyKey<Object?> property;

  /// Label override.
  final String? label;

  /// Options of a choice property.
  final List<VwishOption<Object?>>? options;

  @override
  ConsumerState<InspectorPropertyRow> createState() => _InspectorPropertyRowState();
}

class _InspectorPropertyRowState extends ConsumerState<InspectorPropertyRow> {
  InspectorEditSession? _session;
  double? _live;
  int? _liveAxis;
  Color? _liveColor;

  @override
  void dispose() {
    _session?.dispose();
    super.dispose();
  }

  InspectorEditSession _sessionFor(EditorController editor) {
    final label = 'Change ${widget.property.displayName.toLowerCase()}';
    final key = '${widget.item}:${widget.property.id}';
    final s = _session ??= InspectorEditSession(editor: editor, label: label, coalesceKey: key);
    s
      ..editor = editor
      ..label = label
      ..coalesceKey = key;
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final id = EditorScope.idOf(context);
    final key = widget.property;
    final item = ref.watch(editorControllerProvider(id).select((s) => s.project?.index.item(widget.item)));
    if (item == null || !key.appliesToItem(item)) return const SizedBox.shrink();
    final ready = ref.watch(editorControllerProvider(id).select((s) => s.isReady));
    final playhead = ref.watch(playheadProvider(id));
    final editor = ref.read(editorControllerProvider(id).notifier);
    final session = _sessionFor(editor);
    final animated = key.keyframable && KeyframeOps.isAnimated(keyframesOf(item), key);
    final label = widget.label ?? InspectorRowStrings.labelOf(key);
    if (!animated) return _row(item, playhead, session, label, ready, playhead.value);
    return ValueListenableBuilder<TimeUs>(
      valueListenable: playhead,
      builder: (context, t, _) => _row(item, playhead, session, label, ready, t),
    );
  }

  Object? _valueAt(TimelineItem item, TimeUs t) {
    final local = (t - item.start).clamp(0, math.max(0, item.duration - 1)).toInt();
    return evaluate<Object?>(item, widget.property, local);
  }

  Widget? _toggle(TimelineItem item, String label) =>
      widget.property.keyframable ? PropertyKeyframeToggle(item: item.id, property: widget.property, label: label) : null;

  Widget _row(TimelineItem item, PlayheadController playhead, InspectorEditSession session, String label, bool ready, TimeUs t) {
    final key = widget.property;
    final value = _valueAt(item, t);
    final items = [item.id];
    switch (key.valueKind) {
      case PropertyValueKind.number || PropertyValueKind.duration:
        final isInt = key.valueKind == PropertyValueKind.duration || value is int;
        EditCommand command(double v) {
          if (isInt) {
            final k = key as PropertyKey<int>;
            return SetProperty<int>(items, k, k.clamp(v.round()), at: playhead.value);
          }
          final k = key as PropertyKey<double>;
          return SetProperty<double>(items, k, k.clamp(v), at: playhead.value);
        }
        final current = (value as num?)?.toDouble() ?? 0;
        return InspectorSliderRow(
          label: label,
          value: _liveAxis == -1 ? (_live ?? current) : current,
          min: key.min,
          max: key.max,
          step: key.step,
          displayScale: key.displayScale,
          unit: key.unit,
          defaultValue: (key.defaultValue as num?)?.toDouble(),
          enabled: ready,
          keyframeToggle: _toggle(item, label),
          onChangeStart: (_) => session.start(),
          onChanged: (v) {
            setState(() {
              _live = v;
              _liveAxis = -1;
            });
            session.change(command(v));
          },
          onChangeEnd: (_) {
            session.end();
            setState(() => _live = _liveAxis = null);
          },
          onSubmitted: (v) => session.apply(command(v)),
        );
      case PropertyValueKind.vec2:
        final current = value is Vec2 ? value : Vec2.zero;
        final def = key.defaultValue is Vec2 ? key.defaultValue! as Vec2 : Vec2.zero;
        Widget axisRow(int axis) {
          final axisLabel = InspectorRowStrings.axis(label, axis);
          EditCommand command(double v) {
            final base = _valueAt(item, playhead.value);
            final b = base is Vec2 ? base : current;
            final next = axis == 0 ? Vec2(v, b.y) : Vec2(b.x, v);
            final k = key as PropertyKey<Vec2>;
            return SetProperty<Vec2>(items, k, k.clamp(next), at: playhead.value);
          }

          final shown = axis == 0 ? current.x : current.y;
          return InspectorSliderRow(
            key: ValueKey<int>(axis),
            label: axisLabel,
            value: _liveAxis == axis ? (_live ?? shown) : shown,
            min: key.min,
            max: key.max,
            step: key.step,
            displayScale: key.displayScale,
            unit: key.unit,
            defaultValue: axis == 0 ? def.x : def.y,
            enabled: ready,
            keyframeToggle: _toggle(item, label),
            onChangeStart: (_) => session.start(),
            onChanged: (v) {
              setState(() {
                _live = v;
                _liveAxis = axis;
              });
              session.change(command(v));
            },
            onChangeEnd: (_) {
              session.end();
              setState(() => _live = _liveAxis = null);
            },
            onSubmitted: (v) => session.apply(command(v)),
          );
        }

        return Column(mainAxisSize: MainAxisSize.min, children: [axisRow(0), axisRow(1)]);
      case PropertyValueKind.toggle:
        return InspectorToggleRow(
          label: label,
          value: value == true,
          onChanged: ready ? (v) => session.apply(SetProperty<bool>(items, key as PropertyKey<bool>, v, at: playhead.value)) : null,
        );
      case PropertyValueKind.choice:
        final options = widget.options;
        if (options == null || options.isEmpty) return const SizedBox.shrink();
        return InspectorChoiceRow<Object?>(
          label: label,
          value: value,
          options: options,
          enabled: ready,
          onChanged: (v) => session.apply(SetProperty<Object?>(items, key, v, at: playhead.value)),
        );
      case PropertyValueKind.color:
        final color = _liveColor ?? Color(value is int ? value : 0xFFFFFFFF);
        EditCommand command(Color c) => SetProperty<int>(items, key as PropertyKey<int>, c.toARGB32(), at: playhead.value);
        return InspectorColorRow(
          label: label,
          color: color,
          enabled: ready,
          onChangeStart: (_) => session.start(),
          onChanged: (c) {
            if (!session.active) {
              session.apply(command(c));
              return;
            }
            setState(() => _liveColor = c);
            session.change(command(c));
          },
          onChangeEnd: (_) {
            session.end();
            setState(() => _liveColor = null);
          },
        );
      case PropertyValueKind.text || PropertyValueKind.rect:
        // Free text (font ids) and rectangles (crop) have dedicated editors in their panels.
        return const SizedBox.shrink();
    }
  }
}
