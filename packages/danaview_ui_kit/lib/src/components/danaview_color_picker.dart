import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../theme/danaview_theme.dart';
import '../theme/danaview_tokens.dart';
import 'danaview_icon_button.dart';
import 'danaview_pressable.dart';
import 'danaview_text_field.dart';

/// Custom HSV color picker: a saturation/brightness square, a hue strip, an optional opacity strip,
/// a hex field, quick swatches and an optional eyedropper.
///
/// The picker is controlled ([color] in, [onChanged] out) and keeps its own hue so dragging through
/// grey or black does not lose it. [onChangeStart]/[onChangeEnd] bracket every edit (drag, key press,
/// swatch, hex entry) so the caller can coalesce undo history. The picker needs a bounded width and
/// scales its height with its content, so place it in a scrolling body on small screens.
///
/// Hex strings follow the CSS order: `RRGGBB`, or `RRGGBBAA` when the color is translucent; `RGB`
/// and `RGBA` shorthands are accepted on input.
class DanaviewColorPicker extends StatefulWidget {
  const DanaviewColorPicker({
    super.key,
    required this.color,
    required this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
    this.showOpacity = true,
    this.swatches = defaultSwatches,
    this.onEyedropper,
    this.areaHeight = 160,
    this.semanticLabel = 'Color picker',
  });

  final Color color;
  final ValueChanged<Color> onChanged;
  final ValueChanged<Color>? onChangeStart;
  final ValueChanged<Color>? onChangeEnd;

  /// Shows the opacity strip and accepts 8-digit hex. When false the color is always opaque.
  final bool showOpacity;
  final List<Color> swatches;

  /// Shows an eyedropper button. The callback lets the user pick a color from the screen and
  /// returns it (or null when cancelled); the picker applies the result.
  final FutureOr<Color?> Function()? onEyedropper;
  final double areaHeight;
  final String semanticLabel;

  static const List<Color> defaultSwatches = <Color>[
    Color(0xFFFFFFFF),
    Color(0xFF000000),
    Color(0xFF8B91A9),
    Color(0xFFEF4444),
    Color(0xFFF97316),
    Color(0xFFF59E0B),
    Color(0xFFFDE047),
    Color(0xFF10B981),
    Color(0xFF06B6D4),
    Color(0xFF3B82F6),
    Color(0xFF5E60EE),
    Color(0xFF8B5CF6),
    Color(0xFFEC4899),
  ];

  /// `RRGGBB`, or `RRGGBBAA` when [includeAlpha] and the color is not opaque.
  static String formatHex(Color color, {bool includeAlpha = true}) {
    String two(double channel) => (channel * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
    final rgb = '${two(color.r)}${two(color.g)}${two(color.b)}';
    final alpha = (color.a * 255).round();
    return (includeAlpha && alpha < 255 ? '$rgb${two(color.a)}' : rgb).toUpperCase();
  }

  /// Parses 3, 4, 6 or 8 hex digits (CSS order), with or without a leading '#'.
  static Color? parseHex(String text, {bool allowAlpha = true}) {
    var hex = text.trim();
    if (hex.startsWith('#')) hex = hex.substring(1);
    if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) return null;
    if (hex.length == 3 || hex.length == 4) {
      hex = hex.split('').map((c) => '$c$c').join();
    }
    if (hex.length != 6 && hex.length != 8) return null;
    final rgb = int.parse(hex.substring(0, 6), radix: 16);
    final alpha = hex.length == 8 && allowAlpha ? int.parse(hex.substring(6), radix: 16) : 255;
    return Color.fromARGB(alpha, (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);
  }

  @override
  State<DanaviewColorPicker> createState() => _DanaviewColorPickerState();
}

class _DanaviewColorPickerState extends State<DanaviewColorPicker> {
  late HSVColor _hsv;
  final TextEditingController _hexController = TextEditingController();
  final FocusNode _hexFocus = FocusNode();
  bool _hexEditing = false;

  Color get _color => _toColor(_hsv);

  Color _toColor(HSVColor hsv) {
    final color = hsv.toColor();
    return widget.showOpacity ? color : color.withValues(alpha: 1);
  }

  HSVColor _fromColor(Color color, {HSVColor? previous}) {
    var hsv = HSVColor.fromColor(widget.showOpacity ? color : color.withValues(alpha: 1));
    // Grey and black have no hue of their own: keep the one the user was on.
    if (previous != null && (hsv.saturation == 0 || hsv.value == 0)) {
      hsv = hsv.withHue(previous.hue);
    }
    return hsv;
  }

  @override
  void initState() {
    super.initState();
    _hsv = _fromColor(widget.color);
    _hexController.text = _hexText();
    _hexFocus.addListener(_onHexFocus);
  }

  @override
  void didUpdateWidget(DanaviewColorPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    final external = widget.color.toARGB32() != oldWidget.color.toARGB32() || oldWidget.showOpacity != widget.showOpacity;
    if (external && widget.color.toARGB32() != _color.toARGB32()) {
      _hsv = _fromColor(widget.color, previous: _hsv);
    }
    if (!_hexEditing) _syncHex();
  }

  @override
  void dispose() {
    _hexFocus.removeListener(_onHexFocus);
    _hexFocus.dispose();
    _hexController.dispose();
    super.dispose();
  }

  String _hexText() => DanaviewColorPicker.formatHex(_color, includeAlpha: widget.showOpacity);

  void _syncHex() {
    final text = _hexText();
    if (_hexController.text != text) _hexController.text = text;
  }

  // ---- edits -----------------------------------------------------------------

  void _start() => widget.onChangeStart?.call(_color);

  void _end() => widget.onChangeEnd?.call(_color);

  /// A continuous edit (drag): no start/end here, the surface brackets the gesture.
  void _update(HSVColor next, {bool fromHex = false}) {
    if (next == _hsv) return;
    setState(() => _hsv = next);
    if (!fromHex) _syncHex();
    widget.onChanged(_color);
  }

  /// A single-shot edit: key press, swatch, eyedropper, typed hex.
  void _commit(HSVColor next, {bool fromHex = false}) {
    _start();
    _update(next, fromHex: fromHex);
    _end();
  }

  void _onHexFocus() {
    if (!_hexFocus.hasFocus) _finishHex();
  }

  void _onHexChanged(String text) {
    _hexEditing = true;
    final digits = text.replaceAll('#', '');
    if (digits.length != 6 && !(digits.length == 8 && widget.showOpacity)) return;
    final parsed = DanaviewColorPicker.parseHex(digits, allowAlpha: widget.showOpacity);
    if (parsed == null) return;
    final next = _fromColor(parsed, previous: _hsv);
    if (_toColor(next).toARGB32() != _color.toARGB32()) _commit(next, fromHex: true);
  }

  void _finishHex() {
    final parsed = DanaviewColorPicker.parseHex(_hexController.text, allowAlpha: widget.showOpacity);
    _hexEditing = false;
    if (parsed != null) {
      final next = _fromColor(parsed, previous: _hsv);
      if (_toColor(next).toARGB32() != _color.toARGB32()) _commit(next);
    }
    _syncHex();
  }

  Future<void> _eyedrop() async {
    final picked = await widget.onEyedropper?.call();
    if (picked == null || !mounted) return;
    _commit(_fromColor(picked, previous: _hsv));
  }

  void _pickSwatch(Color swatch) {
    final opaque = swatch.withValues(alpha: _hsv.alpha);
    _commit(_fromColor(widget.showOpacity ? opaque : swatch, previous: _hsv));
  }

  // ---- build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final color = _color;
    final compactSwatch = !context.isTouchPlatform;
    final swatchCell = compactSwatch ? 32.0 : DanaviewSpacing.minTapTarget;

    return Semantics(
      container: true,
      label: widget.semanticLabel,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SvArea(
            hsv: _hsv,
            height: widget.areaHeight,
            onStart: _start,
            onChanged: (s, v) => _update(_hsv.withSaturation(s).withValue(v)),
            onCommit: (s, v) => _commit(_hsv.withSaturation(s).withValue(v)),
            onEnd: _end,
          ),
          const SizedBox(height: DanaviewSpacing.sm),
          _PickerStrip(
            kind: _StripKind.hue,
            hsv: _hsv,
            label: 'Hue',
            value: _hsv.hue / 360,
            valueText: (f) => '${(f * 360).round()} degrees',
            keyStep: 1 / 360,
            semanticStep: 5 / 360,
            onStart: _start,
            onChanged: (f) => _update(_hsv.withHue(f * 360)),
            onCommit: (f) => _commit(_hsv.withHue(f * 360)),
            onEnd: _end,
          ),
          if (widget.showOpacity)
            _PickerStrip(
              kind: _StripKind.opacity,
              hsv: _hsv,
              label: 'Opacity',
              value: _hsv.alpha,
              valueText: (f) => '${(f * 100).round()} percent',
              keyStep: 0.01,
              semanticStep: 0.05,
              onStart: _start,
              onChanged: (f) => _update(_hsv.withAlpha(f)),
              onCommit: (f) => _commit(_hsv.withAlpha(f)),
              onEnd: _end,
            ),
          const SizedBox(height: DanaviewSpacing.sm),
          Row(
            children: [
              _Preview(color: color),
              const SizedBox(width: DanaviewSpacing.sm),
              Text('#', style: DanaviewTextStyles.headline.copyWith(color: DanaviewColors.textSecondary)),
              const SizedBox(width: DanaviewSpacing.xs),
              Expanded(
                child: DanaviewTextField(
                  controller: _hexController,
                  focusNode: _hexFocus,
                  hint: widget.showOpacity ? 'RRGGBBAA' : 'RRGGBB',
                  showClearButton: false,
                  semanticLabel: 'Hex color',
                  keyboardType: TextInputType.visiblePassword,
                  textInputAction: TextInputAction.done,
                  inputFormatters: <TextInputFormatter>[
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F#]')),
                    LengthLimitingTextInputFormatter(widget.showOpacity ? 9 : 7),
                    TextInputFormatter.withFunction(
                      (old, value) => value.copyWith(text: value.text.toUpperCase()),
                    ),
                  ],
                  onChanged: _onHexChanged,
                  onSubmitted: (_) => _finishHex(),
                ),
              ),
              if (widget.onEyedropper != null) ...[
                const SizedBox(width: DanaviewSpacing.xs),
                DanaviewIconButton(
                  icon: Icons.colorize_rounded,
                  variant: DanaviewIconButtonVariant.filled,
                  size: 40,
                  iconSize: 20,
                  tooltip: 'Pick color from screen',
                  onPressed: _eyedrop,
                ),
              ],
            ],
          ),
          if (widget.swatches.isNotEmpty) ...[
            const SizedBox(height: DanaviewSpacing.sm),
            Wrap(
              children: [
                for (final swatch in widget.swatches)
                  _Swatch(
                    color: swatch,
                    cell: swatchCell,
                    selected: (swatch.toARGB32() & 0xFFFFFF) == (color.toARGB32() & 0xFFFFFF),
                    onTap: () => _pickSwatch(swatch),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ---- small parts -------------------------------------------------------------

void _paintChecker(Canvas canvas, Rect rect, {double cell = 6}) {
  canvas.save();
  canvas.clipRect(rect);
  canvas.drawRect(rect, Paint()..color = const Color(0xFFE6E6E6));
  final dark = Paint()..color = const Color(0xFFB9B9B9);
  var row = 0;
  for (var y = rect.top; y < rect.bottom; y += cell, row++) {
    var col = 0;
    for (var x = rect.left; x < rect.right; x += cell, col++) {
      if ((row + col).isOdd) canvas.drawRect(Rect.fromLTWH(x, y, cell, cell), dark);
    }
  }
  canvas.restore();
}

class _CheckerPainter extends CustomPainter {
  const _CheckerPainter();

  @override
  void paint(Canvas canvas, Size size) => _paintChecker(canvas, Offset.zero & size);

  @override
  bool shouldRepaint(_CheckerPainter old) => false;
}

class _Preview extends StatelessWidget {
  const _Preview({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Current color',
      value: '#${DanaviewColorPicker.formatHex(color)}',
      child: ExcludeSemantics(
        child: SizedBox.square(
          dimension: 40,
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: const BoxDecoration(borderRadius: DanaviewRadius.mdAll, border: DanaviewBorders.all),
            child: ClipRRect(
              borderRadius: DanaviewRadius.mdAll,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const CustomPaint(painter: _CheckerPainter()),
                  ColoredBox(color: color),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color, required this.cell, required this.selected, required this.onTap});

  final Color color;
  final double cell;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final check = DanaviewColors.foregroundOn(color);
    return DanaviewPressable.builder(
      onTap: onTap,
      semanticLabel: 'Color #${DanaviewColorPicker.formatHex(color)}',
      selected: selected,
      pressedScale: 0.92,
      builder: (context, state) {
        return SizedBox.square(
          dimension: cell,
          child: Center(
            child: AnimatedContainer(
              duration: DanaviewMotion.fast,
              curve: DanaviewMotion.curve,
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color,
                borderRadius: DanaviewRadius.smAll,
                border: Border.all(
                  color: selected
                      ? DanaviewColors.primaryLight
                      : state.focused
                          ? DanaviewColors.focusRing
                          : DanaviewColors.border,
                  width: selected ? 2 : DanaviewBorders.width,
                ),
              ),
              child: selected ? Icon(Icons.check_rounded, size: 18, color: check) : null,
            ),
          ),
        );
      },
    );
  }
}

// ---- interactive surfaces ------------------------------------------------------

/// Claims the pointer on contact, so dragging a thumb never loses to a scrolling ancestor.
class _EagerDragRecognizer extends OneSequenceGestureRecognizer {
  void Function(Offset local)? onStart;
  void Function(Offset local)? onUpdate;
  VoidCallback? onEnd;
  int? _pointer;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (_pointer != null) return;
    startTrackingPointer(event.pointer, event.transform);
    _pointer = event.pointer;
    resolve(GestureDisposition.accepted);
    onStart?.call(event.localPosition);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _pointer) return;
    if (event is PointerMoveEvent) {
      onUpdate?.call(event.localPosition);
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      if (event is PointerUpEvent) onUpdate?.call(event.localPosition);
      final pointer = _pointer;
      _pointer = null;
      onEnd?.call();
      if (pointer != null) stopTrackingPointer(pointer);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _pointer = null;
  }

  @override
  String get debugDescription => 'eager drag';
}

typedef _KeyHandler = bool Function(LogicalKeyboardKey key, bool shift);

/// Shared behavior of the picker's draggable, focusable, semantic surfaces.
class _PickerSurface extends StatefulWidget {
  const _PickerSurface({
    required this.height,
    required this.painterFor,
    required this.onPointer,
    required this.onKey,
    required this.onStart,
    required this.onEnd,
    required this.semantics,
  });

  final double height;
  final CustomPainter Function(bool focused) painterFor;

  /// Called with the position inside the surface and the surface size, on contact and while dragging.
  final void Function(Offset local, Size size) onPointer;
  final _KeyHandler onKey;
  final VoidCallback onStart;
  final VoidCallback onEnd;
  final Semantics Function(Widget child, bool focused) semantics;

  @override
  State<_PickerSurface> createState() => _PickerSurfaceState();
}

class _PickerSurfaceState extends State<_PickerSurface> {
  bool _focused = false;
  Size _size = Size.zero;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    return widget.onKey(event.logicalKey, HardwareKeyboard.instance.isShiftPressed)
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth ? constraints.maxWidth : 240.0;
        _size = Size(width, widget.height);
        Widget surface = RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          gestures: <Type, GestureRecognizerFactory>{
            _EagerDragRecognizer: GestureRecognizerFactoryWithHandlers<_EagerDragRecognizer>(
              _EagerDragRecognizer.new,
              (recognizer) {
                recognizer
                  ..onStart = (local) {
                    widget.onStart();
                    widget.onPointer(local, _size);
                  }
                  ..onUpdate = (local) {
                    widget.onPointer(local, _size);
                  }
                  ..onEnd = widget.onEnd;
              },
            ),
          },
          child: RepaintBoundary(
            child: CustomPaint(size: _size, painter: widget.painterFor(_focused)),
          ),
        );
        surface = MouseRegion(cursor: SystemMouseCursors.precise, child: surface);
        surface = Focus(
          onKeyEvent: _onKey,
          onFocusChange: (focused) => setState(() => _focused = focused),
          child: surface,
        );
        return SizedBox(
          width: width,
          height: widget.height,
          child: widget.semantics(surface, _focused),
        );
      },
    );
  }
}

void _paintThumb(Canvas canvas, Offset center, Color fill, bool focused, {double radius = 11}) {
  final shadow = DanaviewShadows.subtle.first;
  canvas.drawCircle(center + shadow.offset, radius, shadow.toPaint());
  canvas.drawCircle(center, radius, Paint()..color = fill);
  canvas.drawCircle(
    center,
    radius - 1.25,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = Colors.white,
  );
  if (focused) {
    canvas.drawCircle(
      center,
      radius + 3,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = DanaviewColors.primaryLight,
    );
  }
}

class _SvArea extends StatelessWidget {
  const _SvArea({
    required this.hsv,
    required this.height,
    required this.onStart,
    required this.onChanged,
    required this.onCommit,
    required this.onEnd,
  });

  final HSVColor hsv;
  final double height;
  final VoidCallback onStart;
  final void Function(double saturation, double value) onChanged;
  final void Function(double saturation, double value) onCommit;
  final VoidCallback onEnd;

  static const double inset = 11;

  @override
  Widget build(BuildContext context) {
    final saturation = hsv.saturation;
    final value = hsv.value;

    bool onKey(LogicalKeyboardKey key, bool shift) {
      final step = shift ? 0.1 : 0.01;
      if (key == LogicalKeyboardKey.arrowLeft) {
        onCommit((saturation - step).clamp(0.0, 1.0), value);
      } else if (key == LogicalKeyboardKey.arrowRight) {
        onCommit((saturation + step).clamp(0.0, 1.0), value);
      } else if (key == LogicalKeyboardKey.arrowUp) {
        onCommit(saturation, (value + step).clamp(0.0, 1.0));
      } else if (key == LogicalKeyboardKey.arrowDown) {
        onCommit(saturation, (value - step).clamp(0.0, 1.0));
      } else {
        return false;
      }
      return true;
    }

    String percent(double f) => '${(f * 100).round()} percent';

    return _PickerSurface(
      height: height,
      painterFor: (focused) => _SvPainter(hsv: hsv, focused: focused),
      onPointer: (local, size) {
        final usableW = math.max(1.0, size.width - inset * 2);
        final usableH = math.max(1.0, size.height - inset * 2);
        final s = ((local.dx - inset) / usableW).clamp(0.0, 1.0);
        final v = (1 - (local.dy - inset) / usableH).clamp(0.0, 1.0);
        onChanged(s, v);
      },
      onKey: onKey,
      onStart: onStart,
      onEnd: onEnd,
      semantics: (child, focused) => Semantics(
        label: 'Saturation and brightness',
        value: 'Saturation ${percent(saturation)}, brightness ${percent(value)}',
        focusable: true,
        focused: focused,
        customSemanticsActions: <CustomSemanticsAction, VoidCallback>{
          const CustomSemanticsAction(label: 'Increase saturation'): () =>
              onCommit((saturation + 0.05).clamp(0.0, 1.0), value),
          const CustomSemanticsAction(label: 'Decrease saturation'): () =>
              onCommit((saturation - 0.05).clamp(0.0, 1.0), value),
          const CustomSemanticsAction(label: 'Increase brightness'): () =>
              onCommit(saturation, (value + 0.05).clamp(0.0, 1.0)),
          const CustomSemanticsAction(label: 'Decrease brightness'): () =>
              onCommit(saturation, (value - 0.05).clamp(0.0, 1.0)),
        },
        child: child,
      ),
    );
  }
}

class _SvPainter extends CustomPainter {
  _SvPainter({required this.hsv, required this.focused});

  final HSVColor hsv;
  final bool focused;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    const r = _SvArea.inset;
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(DanaviewRadius.md));
    final hue = HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor();

    canvas.save();
    canvas.clipRRect(rrect);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(r, 0),
          Offset(math.max(r + 1, size.width - r), 0),
          <Color>[Colors.white, hue],
        ),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, r),
          Offset(0, math.max(r + 1, size.height - r)),
          const <Color>[Color(0x00000000), Color(0xFF000000)],
        ),
    );
    canvas.restore();
    canvas.drawRRect(rrect.deflate(DanaviewBorders.width / 2), Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = DanaviewBorders.width
      ..color = DanaviewColors.hairline);

    final usableW = math.max(0.0, size.width - r * 2);
    final usableH = math.max(0.0, size.height - r * 2);
    final center = Offset(r + usableW * hsv.saturation, r + usableH * (1 - hsv.value));
    _paintThumb(canvas, center, HSVColor.fromAHSV(1, hsv.hue, hsv.saturation, hsv.value).toColor(), focused);
  }

  @override
  bool shouldRepaint(_SvPainter old) => old.hsv != hsv || old.focused != focused;
}

enum _StripKind { hue, opacity }

class _PickerStrip extends StatelessWidget {
  const _PickerStrip({
    required this.kind,
    required this.hsv,
    required this.label,
    required this.value,
    required this.valueText,
    required this.keyStep,
    required this.semanticStep,
    required this.onStart,
    required this.onChanged,
    required this.onCommit,
    required this.onEnd,
  });

  final _StripKind kind;
  final HSVColor hsv;
  final String label;

  /// 0..1.
  final double value;
  final String Function(double fraction) valueText;
  final double keyStep;
  final double semanticStep;
  final VoidCallback onStart;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onCommit;
  final VoidCallback onEnd;

  static const double thumbRadius = 11;

  @override
  Widget build(BuildContext context) {
    // 28 is the comfortable pointer height; touch grows it to the 44 tap target (track stays 16).
    final height = context.isTouchPlatform ? DanaviewSpacing.minTapTarget : 28.0;

    bool onKey(LogicalKeyboardKey key, bool shift) {
      final step = keyStep * (shift ? 10 : 1);
      if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.arrowUp) {
        onCommit((value + step).clamp(0.0, 1.0));
      } else if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowDown) {
        onCommit((value - step).clamp(0.0, 1.0));
      } else if (key == LogicalKeyboardKey.home) {
        onCommit(0);
      } else if (key == LogicalKeyboardKey.end) {
        onCommit(1);
      } else {
        return false;
      }
      return true;
    }

    return _PickerSurface(
      height: height,
      painterFor: (focused) => _StripPainter(kind: kind, hsv: hsv, focused: focused),
      onPointer: (local, size) {
        final usable = math.max(1.0, size.width - thumbRadius * 2);
        onChanged(((local.dx - thumbRadius) / usable).clamp(0.0, 1.0));
      },
      onKey: onKey,
      onStart: onStart,
      onEnd: onEnd,
      semantics: (child, focused) => Semantics(
        slider: true,
        label: label,
        value: valueText(value),
        increasedValue: valueText((value + semanticStep).clamp(0.0, 1.0)),
        decreasedValue: valueText((value - semanticStep).clamp(0.0, 1.0)),
        onIncrease: () => onCommit((value + semanticStep).clamp(0.0, 1.0)),
        onDecrease: () => onCommit((value - semanticStep).clamp(0.0, 1.0)),
        focusable: true,
        focused: focused,
        child: child,
      ),
    );
  }
}

class _StripPainter extends CustomPainter {
  _StripPainter({required this.kind, required this.hsv, required this.focused});

  final _StripKind kind;
  final HSVColor hsv;
  final bool focused;

  static const double trackHeight = 16;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    const r = _PickerStrip.thumbRadius;
    final track = Rect.fromLTWH(0, (size.height - trackHeight) / 2, size.width, trackHeight);
    final rrect = RRect.fromRectAndRadius(track, const Radius.circular(trackHeight / 2));
    final from = Offset(r, 0);
    final to = Offset(math.max(r + 1, size.width - r), 0);

    canvas.save();
    canvas.clipRRect(rrect);
    final Color thumbFill;
    final double fraction;
    switch (kind) {
      case _StripKind.hue:
        canvas.drawRect(
          track,
          Paint()
            ..shader = ui.Gradient.linear(from, to, <Color>[
              for (var i = 0; i <= 6; i++) HSVColor.fromAHSV(1, i * 60.0, 1, 1).toColor(),
            ], <double>[
              for (var i = 0; i <= 6; i++) i / 6,
            ]),
        );
        thumbFill = HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor();
        fraction = hsv.hue / 360;
      case _StripKind.opacity:
        _paintChecker(canvas, track, cell: 5);
        final opaque = HSVColor.fromAHSV(1, hsv.hue, hsv.saturation, hsv.value).toColor();
        canvas.drawRect(
          track,
          Paint()..shader = ui.Gradient.linear(from, to, <Color>[opaque.withValues(alpha: 0), opaque]),
        );
        thumbFill = opaque;
        fraction = hsv.alpha;
    }
    canvas.restore();
    canvas.drawRRect(
      rrect.deflate(DanaviewBorders.width / 2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = DanaviewBorders.width
        ..color = DanaviewColors.hairline,
    );

    final usable = math.max(0.0, size.width - r * 2);
    _paintThumb(canvas, Offset(r + usable * fraction, size.height / 2), thumbFill, focused, radius: r);
  }

  @override
  bool shouldRepaint(_StripPainter old) => old.kind != kind || old.hsv != hsv || old.focused != focused;
}
