import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show cupertinoTextSelectionHandleControls;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../foundation/danaview_internal.dart';
import '../theme/danaview_theme.dart';
import '../theme/danaview_tokens.dart';
import 'danaview_icon_button.dart';

typedef DanaviewNumberFormatter = String Function(double value);
typedef DanaviewNumberParser = double? Function(String text);

/// Typed numeric entry with an optional unit suffix, -/+ steppers and a drag-to-scrub label.
///
/// The field is controlled: it shows [value] and reports edits through [onChanged], always clamped
/// to [min]..[max] and rounded to [fractionDigits]. Typing is committed on submit and on blur (an
/// unparsable entry reverts, Escape reverts); the steppers, the Up/Down keys (Shift or PageUp/PageDown
/// for x10) and the scrub label commit immediately. Assistive technology gets an adjustable control
/// (increase/decrease actions) in addition to text entry.
///
/// Pass [formatter] and [parser] together for non-decimal notations such as timecode; the default
/// input filter is then disabled so any characters can be typed.
class DanaviewNumberField extends StatefulWidget {
  const DanaviewNumberField({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = double.negativeInfinity,
    this.max = double.infinity,
    this.step = 1,
    this.fractionDigits,
    this.unit,
    this.label,
    this.semanticLabel,
    this.bipolar = false,
    this.showSteppers = true,
    this.enabled = true,
    this.formatter,
    this.parser,
    this.scrubPerPixel,
    this.onChangeStart,
    this.onChangeEnd,
    this.focusNode,
    this.autofocus = false,
  })  : assert(min <= max, 'min must not exceed max'),
        assert(step > 0, 'step must be positive');

  final double value;
  final ValueChanged<double>? onChanged;
  final double min;
  final double max;

  /// Stepper and arrow-key increment.
  final double step;

  /// Decimals kept and shown; defaults to the decimals of [step] (0 for whole steps).
  final int? fractionDigits;

  /// Suffix drawn inside the frame ("%", "px", "s", "x").
  final String? unit;

  /// Visible label to the left; dragging it horizontally scrubs the value.
  final String? label;

  /// Spoken name; falls back to [label].
  final String? semanticLabel;

  /// Show an explicit "+" for positive values (offsets, gains).
  final bool bipolar;
  final bool showSteppers;
  final bool enabled;
  final DanaviewNumberFormatter? formatter;
  final DanaviewNumberParser? parser;

  /// Value change per dragged pixel on the label (default: a quarter of [step]).
  final double? scrubPerPixel;

  /// A stepper press, key press or scrub gesture is about to change the value (for undo coalescing).
  final ValueChanged<double>? onChangeStart;

  /// The gesture or press finished, with the final value.
  final ValueChanged<double>? onChangeEnd;
  final FocusNode? focusNode;
  final bool autofocus;

  /// Below this width the steppers hide; the field stays editable and adjustable by keyboard.
  static const double minWidthForSteppers = 150;

  @override
  State<DanaviewNumberField> createState() => _DanaviewNumberFieldState();
}

class _DanaviewNumberFieldState extends State<DanaviewNumberField> {
  late final TextEditingController _controller = TextEditingController();
  FocusNode? _ownedFocus;
  bool _dirty = false;
  double _scrubOrigin = 0;
  double _scrubTravel = 0;
  bool _scrubbing = false;

  /// The last value a nudge reported, until the parent has had a frame to reflect it: key repeat can
  /// outrun a rebuild, and the next step must build on what was already reported, not on the stale
  /// [DanaviewNumberField.value].
  double? _pending;

  FocusNode get _focus => widget.focusNode ?? (_ownedFocus ??= FocusNode());

  bool get _editable => widget.enabled && widget.onChanged != null;

  int get _digits {
    final explicit = widget.fractionDigits;
    if (explicit != null) return math.max(0, explicit);
    final text = widget.step.toString();
    if (text.contains('e')) return 6;
    final dot = text.indexOf('.');
    if (dot < 0) return 0;
    final decimals = text.substring(dot + 1).replaceFirst(RegExp(r'0+$'), '');
    return decimals.length;
  }

  bool get _customNotation => widget.formatter != null || widget.parser != null;

  double _round(double value) {
    final factor = math.pow(10, _digits).toDouble();
    final rounded = (value * factor).round() / factor;
    return rounded == 0 ? 0 : rounded; // no negative zero
  }

  double _normalize(double value) => _round(value.clamp(widget.min, widget.max));

  String _format(double value) {
    final formatter = widget.formatter;
    if (formatter != null) return formatter(value);
    final text = value.toStringAsFixed(_digits);
    return widget.bipolar && value > 0 ? '+$text' : text;
  }

  double? _parse(String text) {
    final parser = widget.parser;
    final parsed = parser != null ? parser(text) : _defaultParse(text);
    if (parsed == null || parsed.isNaN || parsed.isInfinite) return null;
    return parsed;
  }

  double? _defaultParse(String raw) {
    var text = raw.trim().replaceAll('−', '-').replaceAll(',', '.');
    final unit = widget.unit;
    if (unit != null && unit.isNotEmpty && text.endsWith(unit)) {
      text = text.substring(0, text.length - unit.length).trim();
    }
    if (text.startsWith('+')) text = text.substring(1);
    return double.tryParse(text);
  }

  @override
  void initState() {
    super.initState();
    _controller.text = _format(widget.value);
    _focus.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(DanaviewNumberField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      (oldWidget.focusNode ?? _ownedFocus)?.removeListener(_onFocusChanged);
      _focus.addListener(_onFocusChanged);
    }
    _pending = null;
    final reformat = oldWidget.value != widget.value ||
        oldWidget.formatter != widget.formatter ||
        oldWidget.bipolar != widget.bipolar ||
        oldWidget.step != widget.step ||
        oldWidget.fractionDigits != widget.fractionDigits;
    if (reformat && !(_focus.hasFocus && _dirty)) _showValue();
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _ownedFocus?.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _showValue() {
    final text = _format(widget.value);
    if (_controller.text != text) {
      _controller.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    }
    _dirty = false;
  }

  void _onFocusChanged() {
    if (_focus.hasFocus) {
      _controller.selection = TextSelection(baseOffset: 0, extentOffset: _controller.text.length);
    } else {
      _commitText();
    }
    if (mounted) setState(() {});
  }

  /// Applies what was typed (if anything) and refreshes the displayed text.
  void _commitText() {
    if (_dirty) {
      final parsed = _parse(_controller.text);
      if (parsed != null && _editable) {
        final next = _normalize(parsed);
        if (next != widget.value) {
          widget.onChangeStart?.call(widget.value);
          widget.onChanged!(next);
          widget.onChangeEnd?.call(next);
        }
      }
    }
    _dirty = false;
    _showValue();
  }

  void _revert() {
    _dirty = false;
    _showValue();
    _controller.selection = TextSelection(baseOffset: 0, extentOffset: _controller.text.length);
  }

  /// The number a stepper or key press starts from: what is typed, when it parses.
  double get _base {
    if (_dirty) {
      final parsed = _parse(_controller.text);
      if (parsed != null) return _normalize(parsed);
    }
    return _normalize(_pending ?? widget.value);
  }

  void _nudge(double delta) {
    if (!_editable) return;
    final from = _base;
    final reported = _pending ?? widget.value;
    final next = _normalize(from + delta);
    _dirty = false;
    if (next != reported) {
      widget.onChangeStart?.call(reported);
      _pending = next;
      WidgetsBinding.instance
        ..addPostFrameCallback((_) {
          _pending = null;
          // A parent that declined the value gets its own back on screen.
          if (mounted && !_dirty) _showValue();
        })
        ..ensureVisualUpdate();
      widget.onChanged!(next);
      widget.onChangeEnd?.call(next);
    }
    // The parent may not rebuild with the new value (e.g. clamped back); keep the text honest.
    _controller.text = _format(next);
    if (_focus.hasFocus) {
      _controller.selection = TextSelection(baseOffset: 0, extentOffset: _controller.text.length);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || !_editable) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (key == LogicalKeyboardKey.arrowUp) {
      _nudge(widget.step * (shift ? 10 : 1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _nudge(-widget.step * (shift ? 10 : 1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageUp) {
      _nudge(widget.step * 10);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageDown) {
      _nudge(-widget.step * 10);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape && _dirty) {
      _revert();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ---- scrubbing ----------------------------------------------------------

  void _scrubStart(DragStartDetails details) {
    if (!_editable) return;
    _focus.unfocus();
    _scrubbing = true;
    _scrubOrigin = _normalize(widget.value);
    _scrubTravel = 0;
    widget.onChangeStart?.call(widget.value);
  }

  void _scrubUpdate(DragUpdateDetails details) {
    if (!_scrubbing) return;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    _scrubTravel += (rtl ? -1 : 1) * details.delta.dx;
    final perPixel = widget.scrubPerPixel ?? widget.step / 4;
    final next = _normalize(_scrubOrigin + _scrubTravel * perPixel);
    if (next != widget.value) widget.onChanged?.call(next);
  }

  void _scrubEnd([Object? _]) {
    if (!_scrubbing) return;
    _scrubbing = false;
    widget.onChangeEnd?.call(widget.value);
  }

  // ---- build ---------------------------------------------------------------

  TextSelectionControls _selectionControls(BuildContext context) {
    switch (Theme.of(context).platform) {
      case TargetPlatform.iOS:
        return cupertinoTextSelectionHandleControls;
      case TargetPlatform.macOS:
        return desktopTextSelectionHandleControls;
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
        return materialTextSelectionHandleControls;
      case TargetPlatform.linux:
      case TargetPlatform.windows:
        return desktopTextSelectionHandleControls;
    }
  }

  Widget _stepper(IconData icon, String label, double delta, bool canStep) {
    return DanaviewIconButton(
      icon: icon,
      size: 32,
      iconSize: 18,
      variant: DanaviewIconButtonVariant.filled,
      semanticLabel: label,
      onPressed: _editable && canStep ? () => _nudge(delta) : null,
    );
  }

  Widget _frame(BuildContext context) {
    final focused = _focus.hasFocus;
    final theme = Theme.of(context);
    final base = (theme.textTheme.bodyLarge ?? DanaviewTextStyles.body).merge(DanaviewTextStyles.body);
    final style = base.copyWith(fontSize: 15, height: 1.3, color: DanaviewColors.textPrimary);
    final unit = widget.unit;

    final input = Focus(
      onKeyEvent: _onKey,
      skipTraversal: true,
      canRequestFocus: false,
      child: EditableText(
        controller: _controller,
        focusNode: _focus,
        autofocus: widget.autofocus,
        readOnly: !_editable,
        style: style,
        cursorColor: DanaviewColors.primary,
        cursorRadius: const Radius.circular(2),
        backgroundCursorColor: DanaviewColors.textMuted,
        selectionColor: const Color(0x596366F1),
        selectionControls: _selectionControls(context),
        maxLines: 1,
        textAlign: unit == null ? TextAlign.center : TextAlign.end,
        keyboardType: _customNotation
            ? TextInputType.text
            : TextInputType.numberWithOptions(signed: widget.min < 0, decimal: _digits > 0),
        textInputAction: TextInputAction.done,
        inputFormatters: _customNotation
            ? null
            : <TextInputFormatter>[
                FilteringTextInputFormatter.allow(RegExp(r'[0-9+\-−.,]')),
              ],
        onChanged: (_) => _dirty = true,
        onSubmitted: (_) => _commitText(),
        onEditingComplete: _commitText,
      ),
    );

    return AnimatedContainer(
      duration: DanaviewMotion.fast,
      curve: DanaviewMotion.curve,
      constraints: const BoxConstraints(minHeight: 40),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: focused ? DanaviewColors.fieldActive : DanaviewColors.surfaceElevatedHigher,
        borderRadius: DanaviewRadius.mdAll,
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: DanaviewRadius.mdAll,
        border: Border.fromBorderSide(focused ? DanaviewBorders.focus : DanaviewBorders.hairline),
      ),
      child: Row(
        children: [
          Expanded(child: input),
          if (unit != null) ...[
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                unit,
                maxLines: 1,
                overflow: TextOverflow.fade,
                softWrap: false,
                style: style.copyWith(color: DanaviewColors.textSecondary),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final value = _normalize(widget.value);
    final atMin = value <= widget.min;
    final atMax = value >= widget.max;
    final label = widget.label;
    final spokenLabel = widget.semanticLabel ?? label;
    final spokenValue = '${_format(value)}${widget.unit != null ? ' ${widget.unit}' : ''}';

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth ? constraints.maxWidth : double.infinity;
        final labelWidthShare = label == null ? 0.0 : 0.4;
        final controlWidth = width.isFinite ? width * (1 - labelWidthShare) : double.infinity;
        final steppers = widget.showSteppers && controlWidth >= DanaviewNumberField.minWidthForSteppers;

        final control = Row(
          children: [
            if (steppers) ...[
              _stepper(Icons.remove_rounded, 'Decrease', -widget.step, !atMin),
              const SizedBox(width: 4),
            ],
            Expanded(child: ExcludeFocus(excluding: !_editable, child: danaviewTapTarget(context, _frame(context)))),
            if (steppers) ...[
              const SizedBox(width: 4),
              _stepper(Icons.add_rounded, 'Increase', widget.step, !atMax),
            ],
          ],
        );

        final field = Semantics(
          label: spokenLabel,
          value: spokenValue,
          increasedValue: '${_format(_normalize(value + widget.step))}${widget.unit != null ? ' ${widget.unit}' : ''}',
          decreasedValue: '${_format(_normalize(value - widget.step))}${widget.unit != null ? ' ${widget.unit}' : ''}',
          onIncrease: _editable && !atMax ? () => _nudge(widget.step) : null,
          onDecrease: _editable && !atMin ? () => _nudge(-widget.step) : null,
          child: control,
        );

        Widget content = field;
        if (label != null) {
          content = Row(
            children: [
              Flexible(
                flex: 2,
                child: MouseRegion(
                  cursor: _editable ? SystemMouseCursors.resizeLeftRight : MouseCursor.defer,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    dragStartBehavior: DragStartBehavior.down,
                    onHorizontalDragStart: _editable ? _scrubStart : null,
                    onHorizontalDragUpdate: _editable ? _scrubUpdate : null,
                    onHorizontalDragEnd: _editable ? _scrubEnd : null,
                    onHorizontalDragCancel: _editable ? _scrubEnd : null,
                    child: ExcludeSemantics(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Text(
                          label,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: DanaviewTextStyles.label.copyWith(color: DanaviewColors.textSecondary),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(flex: 3, child: field),
            ],
          );
        }
        return danaviewDimmed(_editable, content);
      },
    );
  }
}
