// OWNER: UX-07
//
// EditorSplitter (ux.md §6.5): the preview/timeline splitter. A 12 px row (the scaffold extends its
// hit area to 24 px on touch, into the neighbours) with a 36×4 grip. Dragging changes the split
// ratio within the range the layout allows; double-tap resets it to the kind's default. Semantics:
// an adjustable "Preview size, 50 percent" with increase/decrease (5% steps); Page Down/Page Up do
// the same when it has keyboard focus. Inside the editor the arrow keys belong to EditorShortcuts
// (ARCH §17.6: ↑/↓ are edit points even over a focused control), so the splitter only falls back to
// Down/Up where no editor scope takes them. The scaffold persists the ratio per layout kind.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import 'editor_shell_strings.dart';

/// The preview/timeline splitter.
class EditorSplitter extends StatefulWidget {
  /// Creates the splitter for [ratio] in [minRatio]..[maxRatio] of [span] pixels.
  const EditorSplitter({
    super.key,
    required this.ratio,
    required this.minRatio,
    required this.maxRatio,
    required this.span,
    required this.onChanged,
    required this.onChangeEnd,
    required this.onReset,
  });

  /// Semantics and keyboard step.
  static const double step = 0.05;

  /// Visual and layout height of the splitter row.
  static const double extent = 12;

  /// The current ratio (preview share of [span]).
  final double ratio;

  /// Smallest ratio allowed now.
  final double minRatio;

  /// Largest ratio allowed now.
  final double maxRatio;

  /// Height shared by the preview and the timeline.
  final double span;

  /// Live changes while dragging (and for each semantics/keyboard step).
  final ValueChanged<double> onChanged;

  /// The final ratio of a drag or step (persist it).
  final ValueChanged<double> onChangeEnd;

  /// Double-tap: back to the default ratio.
  final VoidCallback onReset;

  /// Whether the splitter can move.
  bool get movable => maxRatio - minRatio > 1e-6 && span > 0;

  @override
  State<EditorSplitter> createState() => _EditorSplitterState();
}

class _EditorSplitterState extends State<EditorSplitter> {
  final FocusNode _focus = FocusNode(debugLabel: 'EditorSplitter');
  bool _focused = false;
  bool _dragging = false;
  double _dragStartRatio = 0;
  double _dragDy = 0;
  double _lastRatio = 0;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (_focused != _focus.hasFocus) setState(() => _focused = _focus.hasFocus);
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  double _clamp(double r) => r.clamp(widget.minRatio, widget.maxRatio).toDouble();

  void _step(double delta) {
    if (!widget.movable) return;
    final next = _clamp(widget.ratio + delta);
    if ((next - widget.ratio).abs() < 1e-9) return;
    widget.onChanged(next);
    widget.onChangeEnd(next);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.pageDown || key == LogicalKeyboardKey.arrowDown) {
      _step(EditorSplitter.step);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageUp || key == LogicalKeyboardKey.arrowUp) {
      _step(-EditorSplitter.step);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final movable = widget.movable;
    final up = movable && widget.ratio < widget.maxRatio - 1e-6;
    final down = movable && widget.ratio > widget.minRatio + 1e-6;
    final active = _focused || _dragging;
    final grip = AnimatedContainer(
      duration: DanaviewMotion.fast,
      width: 36,
      height: 4,
      decoration: BoxDecoration(
        color: active ? DanaviewColors.primaryLight : const Color(0x33FFFFFF),
        borderRadius: DanaviewRadius.capsuleAll,
      ),
    );
    return Semantics(
      container: true,
      slider: true,
      focusable: movable,
      focused: _focused,
      label: EditorShellStrings.splitter,
      value: EditorShellStrings.splitterValue(widget.ratio),
      increasedValue: up ? EditorShellStrings.splitterValue(_clamp(widget.ratio + EditorSplitter.step)) : null,
      decreasedValue: down ? EditorShellStrings.splitterValue(_clamp(widget.ratio - EditorSplitter.step)) : null,
      onIncrease: up ? () => _step(EditorSplitter.step) : null,
      onDecrease: down ? () => _step(-EditorSplitter.step) : null,
      child: ExcludeSemantics(
        child: Focus(
          focusNode: _focus,
          canRequestFocus: movable,
          onKeyEvent: _onKey,
          child: MouseRegion(
            cursor: movable ? SystemMouseCursors.resizeUpDown : MouseCursor.defer,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTap: movable ? widget.onReset : null,
              onVerticalDragStart: movable
                  ? (_) => setState(() {
                        _dragging = true;
                        _dragStartRatio = widget.ratio;
                        _lastRatio = widget.ratio;
                        _dragDy = 0;
                      })
                  : null,
              onVerticalDragUpdate: movable
                  ? (d) {
                      _dragDy += d.primaryDelta ?? 0;
                      final next = _clamp((_dragStartRatio * widget.span + _dragDy) / widget.span);
                      if ((next - _lastRatio).abs() < 1e-9) return;
                      _lastRatio = next;
                      widget.onChanged(next);
                    }
                  : null,
              onVerticalDragEnd: movable
                  ? (_) {
                      setState(() => _dragging = false);
                      widget.onChangeEnd(_lastRatio);
                    }
                  : null,
              onVerticalDragCancel: movable ? () => setState(() => _dragging = false) : null,
              child: CustomPaint(
                painter: _SplitterLinePainter(),
                child: Center(child: grip),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A hairline across the splitter's centre.
class _SplitterLinePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final y = (size.height / 2).floorToDouble() + 0.5;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), Paint()..color = DanaviewColors.hairline);
  }

  @override
  bool shouldRepaint(_SplitterLinePainter oldDelegate) => false;
}
