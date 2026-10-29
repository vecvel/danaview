// OWNER: UX-25
//
// The speed curve editor (ux.md §10.3, D-15): edits the points of a SpeedRamp.
//
// * x is the normalized **source** position 0-1, y the speed on a log scale 0.1x-10x; the 1x line is
//   drawn and the curve is drawn as it plays (speed is linear between two points, so it bends on the
//   log axis). The area between the curve and the 1x line is tinted: fast above, slow below.
// * 3-7 points. The first and last point keep their x (0 and 1); a point moves between its
//   neighbours (never closer than `SpeedRampEdit.minGap`) and its speed stays in the device's range.
//   A speed within 5 % of 1x snaps to 1x. Every edit makes the curve custom (`presetId: null`).
// * Touch: pressing a point grabs it at once (so a vertical drag never scrolls the panel), the hit
//   radius is 22 on touch and 14 with a pointer; double-tap anywhere else adds a point on the curve;
//   a long press on a point deletes it (the two end points and the third-last point stay).
// * Non-gesture alternatives (WCAG 2.5.1, 2.5.7): every point is a semantics node with increase and
//   decrease (speed) and move earlier / later and delete actions; arrow keys move the selected
//   point (Up/Down speed, Left/Right position), Delete removes it. The panel adds number fields and
//   buttons for the selected point.
// * The widget is presentational. Gestures report through `onChangeStart` / `onChanged` /
//   `onChangeEnd` (one transaction in the panel); nudges (keys, semantics) through `onStep` and
//   adding or deleting a point through `onStructure`. While dragging, the editor shows its own live ramp, so the curve never waits
//   for the project to catch up.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' show Theme;
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:danaview_editor_core/model.dart' show SpeedPoint, SpeedRamp, maxClipSpeed, minClipSpeed;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/strings/speed_strings.dart';

/// Pure edits of a [SpeedRamp] (every result is a valid ramp and custom: `presetId` null).
abstract final class SpeedRampEdit {
  /// Fewest points the editor leaves a curve with.
  static const int minPoints = 3;

  /// Most points the editor adds (the model allows 16).
  static const int maxPoints = 7;

  /// Closest two points may get in x.
  static const double minGap = 0.02;

  /// A speed this close to 1x (in decades) snaps to 1x.
  static const double snapDecades = 0.02;

  /// Speed change of one step in decades (about +26 %).
  static const double speedStepDecades = 0.1;

  /// Position change of one step.
  static const double positionStep = 0.01;

  /// A flat curve at [rate] (3 points).
  static SpeedRamp flat(double rate) => SpeedRamp([SpeedPoint(0, rate), SpeedPoint(0.5, rate), SpeedPoint(1, rate)]);

  /// The speed of [ramp] at normalized position [x] (linear between points).
  static double speedAt(SpeedRamp ramp, double x) {
    final p = ramp.points;
    if (x <= p.first.x) return p.first.y;
    if (x >= p.last.x) return p.last.y;
    for (var i = 0; i + 1 < p.length; i++) {
      final a = p[i];
      final b = p[i + 1];
      if (x <= b.x) return a.y + (b.y - a.y) * ((x - a.x) / (b.x - a.x));
    }
    return p.last.y;
  }

  /// The largest speed of [ramp].
  static double fastest(SpeedRamp ramp) => ramp.points.map((p) => p.y).reduce(math.max);

  /// [v] clamped to [[lo], [hi]], snapped to 1x when close, rounded to two decimals.
  static double cleanSpeed(double v, {double lo = minClipSpeed, double hi = maxClipSpeed}) {
    var s = v.clamp(lo, hi).toDouble();
    if (lo <= 1 && hi >= 1 && (math.log(s) / math.ln10).abs() < snapDecades) s = 1;
    s = (s * 100).round() / 100;
    return s.clamp(lo, hi).toDouble();
  }

  /// Point [i] moved to position [x] (interior points only) and speed [y]; each is left alone when
  /// null. Speeds are limited to [[lo], [hi]].
  static SpeedRamp movePoint(SpeedRamp ramp, int i, {double? x, double? y, double lo = minClipSpeed, double hi = maxClipSpeed}) {
    final p = ramp.points;
    if (i < 0 || i >= p.length) return ramp;
    final interior = i > 0 && i < p.length - 1;
    var nx = p[i].x;
    if (x != null && interior) {
      final lower = p[i - 1].x + minGap;
      final upper = p[i + 1].x - minGap;
      nx = lower > upper ? p[i].x : x.clamp(lower, upper).toDouble();
      nx = (nx * 1000).round() / 1000;
    }
    final ny = y == null ? p[i].y : cleanSpeed(y, lo: lo, hi: hi);
    if (nx == p[i].x && ny == p[i].y) return ramp;
    return ramp.copyWith(points: [...p.take(i), SpeedPoint(nx, ny), ...p.skip(i + 1)], presetId: null);
  }

  /// Point [i] changed by [steps] speed steps (a factor of 10^(0.1 steps)).
  static SpeedRamp stepSpeed(SpeedRamp ramp, int i, int steps, {double lo = minClipSpeed, double hi = maxClipSpeed}) {
    if (i < 0 || i >= ramp.points.length) return ramp;
    final v = ramp.points[i].y * math.pow(10, speedStepDecades * steps);
    return movePoint(ramp, i, y: v, lo: lo, hi: hi);
  }

  /// Point [i] changed by [steps] position steps.
  static SpeedRamp stepPosition(SpeedRamp ramp, int i, int steps) {
    if (i < 0 || i >= ramp.points.length) return ramp;
    return movePoint(ramp, i, x: ramp.points[i].x + positionStep * steps);
  }

  /// Whether a point fits at [x] (room on both sides and fewer than [maxPoints]).
  static bool canAddAt(SpeedRamp ramp, double x) {
    final p = ramp.points;
    if (p.length >= maxPoints) return false;
    for (var i = 0; i + 1 < p.length; i++) {
      if (x > p[i].x && x < p[i + 1].x) return x - p[i].x >= minGap && p[i + 1].x - x >= minGap;
    }
    return false;
  }

  /// [ramp] with a point on the curve at [x], or null when none fits there.
  static SpeedRamp? addPoint(SpeedRamp ramp, double x, {double lo = minClipSpeed, double hi = maxClipSpeed}) {
    final nx = (x * 1000).round() / 1000;
    if (!canAddAt(ramp, nx)) return null;
    final p = ramp.points;
    final at = p.indexWhere((e) => e.x > nx);
    final y = cleanSpeed(speedAt(ramp, nx), lo: lo, hi: hi);
    return ramp.copyWith(points: [...p.take(at), SpeedPoint(nx, y), ...p.skip(at)], presetId: null);
  }

  /// The index [addPoint] gives the new point at the widest gap, with the ramp; null when full.
  static (SpeedRamp, int)? addAtWidestGap(SpeedRamp ramp, {double lo = minClipSpeed, double hi = maxClipSpeed}) {
    final p = ramp.points;
    if (p.length >= maxPoints) return null;
    var best = 0;
    for (var i = 1; i + 1 < p.length; i++) {
      if (p[i + 1].x - p[i].x > p[best + 1].x - p[best].x) best = i;
    }
    final x = (p[best].x + p[best + 1].x) / 2;
    final next = addPoint(ramp, x, lo: lo, hi: hi);
    if (next == null) return null;
    return (next, best + 1);
  }

  /// Whether point [i] can be deleted (interior, and more than [minPoints] points).
  static bool canRemove(SpeedRamp ramp, int i) => ramp.points.length > minPoints && i > 0 && i < ramp.points.length - 1;

  /// [ramp] without point [i], or null when it cannot be deleted.
  static SpeedRamp? removePoint(SpeedRamp ramp, int i) {
    if (!canRemove(ramp, i)) return null;
    return ramp.copyWith(points: [...ramp.points.take(i), ...ramp.points.skip(i + 1)], presetId: null);
  }
}

// -------------------------------------------------------------------------------------------------
// Geometry
// -------------------------------------------------------------------------------------------------

/// Maps ramp coordinates to the plot (x linear, speed logarithmic from 0.1x to 10x).
@immutable
final class SpeedPlot {
  /// Creates the mapping for [rect].
  const SpeedPlot(this.rect);

  /// The plot area in the widget's coordinates.
  final Rect rect;

  static final double _lo = math.log(minClipSpeed) / math.ln10;
  static final double _span = math.log(maxClipSpeed) / math.ln10 - _lo;

  /// Pixel x of normalized position [x].
  double dx(double x) => rect.left + x * rect.width;

  /// Pixel y of speed [v].
  double dy(double v) => rect.bottom - ((math.log(v) / math.ln10 - _lo) / _span) * rect.height;

  /// Normalized position of pixel x [px] (0-1).
  double x(double px) => ((px - rect.left) / rect.width).clamp(0.0, 1.0).toDouble();

  /// Speed at pixel y [py] (0.1-10).
  double v(double py) {
    final t = ((rect.bottom - py) / rect.height).clamp(0.0, 1.0).toDouble();
    return math.pow(10, _lo + t * _span).toDouble();
  }

  /// The pixel position of [p].
  Offset of(SpeedPoint p) => Offset(dx(p.x), dy(p.y));
}

/// The curve editor.
class SpeedCurveEditor extends StatefulWidget {
  /// Creates the editor for [ramp].
  const SpeedCurveEditor({
    super.key,
    required this.ramp,
    this.selected,
    this.onSelected,
    this.onChangeStart,
    this.onChanged,
    this.onChangeEnd,
    this.onStep,
    this.onStructure,
    this.minSpeed = minClipSpeed,
    this.maxSpeed = maxClipSpeed,
    this.enabled = true,
    this.height = 176,
  });

  /// The curve.
  final SpeedRamp ramp;

  /// The selected point, or null.
  final int? selected;

  /// A point was selected (or null: none).
  final ValueChanged<int?>? onSelected;

  /// A point drag starts.
  final VoidCallback? onChangeStart;

  /// The dragged curve.
  final ValueChanged<SpeedRamp>? onChanged;

  /// A point drag ends.
  final VoidCallback? onChangeEnd;

  /// A nudge of a point (arrow keys, semantics actions): steps that come close together join one
  /// history entry. [selected] says which point to select afterwards (null keeps the selection).
  final void Function(SpeedRamp ramp, {int? selected})? onStep;

  /// A point was added or deleted: one history entry each. [selected] is the point to select
  /// afterwards.
  final void Function(SpeedRamp ramp, {int? selected})? onStructure;

  /// Lowest speed the device allows.
  final double minSpeed;

  /// Highest speed the device allows.
  final double maxSpeed;

  /// Whether the curve can be edited.
  final bool enabled;

  /// Height of the plot.
  final double height;

  /// Space between the widget's edge and the plot (room for the end points).
  static const EdgeInsets plotInset = EdgeInsets.fromLTRB(12, 16, 12, 16);

  /// Hit radius of a point with a touch.
  static const double touchHitRadius = 22;

  /// Hit radius of a point with a pointer.
  static const double pointerHitRadius = 14;

  @override
  State<SpeedCurveEditor> createState() => _SpeedCurveEditorState();
}

class _SpeedCurveEditorState extends State<SpeedCurveEditor> {
  final FocusNode _focus = FocusNode(debugLabel: 'SpeedCurveEditor');
  SpeedRamp? _live;
  SpeedRamp? _stepped;
  int? _dragging;
  Offset _grab = Offset.zero;
  Offset? _lastTap;
  SpeedPlot? _plot;
  bool _touch = true;
  bool _focused = false;

  SpeedRamp get _ramp => _live ?? widget.ramp;

  /// The curve one-shot edits start from: the latest nudge until the project has caught up.
  SpeedRamp get _base => _stepped ?? widget.ramp;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void dispose() {
    _focus
      ..removeListener(_onFocus)
      ..dispose();
    super.dispose();
  }

  void _onFocus() {
    if (_focus.hasFocus != _focused && mounted) setState(() => _focused = _focus.hasFocus);
  }

  @override
  void didUpdateWidget(SpeedCurveEditor old) {
    super.didUpdateWidget(old);
    if (widget.ramp != old.ramp) _stepped = null;
    if (_dragging == null && _live != null && widget.ramp != old.ramp) _live = null;
  }

  double get _hitRadius => _touch ? SpeedCurveEditor.touchHitRadius : SpeedCurveEditor.pointerHitRadius;

  int? _hit(Offset local) {
    final plot = _plot;
    if (plot == null || !widget.enabled) return null;
    final points = _ramp.points;
    int? best;
    var bestDistance = _hitRadius;
    for (var i = 0; i < points.length; i++) {
      final d = (plot.of(points[i]) - local).distance;
      if (d <= bestDistance) {
        bestDistance = d;
        best = i;
      }
    }
    return best;
  }

  // ---- Gestures ------------------------------------------------------------------------------

  void _down(Offset local) {
    final i = _hit(local);
    final plot = _plot;
    if (i == null || plot == null) return;
    _dragging = i;
    _grab = plot.of(_ramp.points[i]) - local;
    widget.onSelected?.call(i);
    _focus.requestFocus();
    widget.onChangeStart?.call();
  }

  void _move(Offset local) {
    final i = _dragging;
    final plot = _plot;
    if (i == null || plot == null) return;
    final target = local + _grab;
    final next = SpeedRampEdit.movePoint(_ramp, i, x: plot.x(target.dx), y: plot.v(target.dy), lo: widget.minSpeed, hi: widget.maxSpeed);
    if (next == _ramp) return;
    setState(() => _live = next);
    widget.onChanged?.call(next);
  }

  void _end() {
    if (_dragging == null) return;
    _dragging = null;
    widget.onChangeEnd?.call();
    // The project catches up within the frame; keep the live curve until it has.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _dragging == null && _live != null) setState(() => _live = null);
    });
  }

  void _cancel() {
    if (_dragging == null) return;
    _dragging = null;
    widget.onChangeEnd?.call();
    if (_live != null) setState(() => _live = null);
  }

  void _longPress() {
    final i = _dragging;
    if (i == null) return;
    _end();
    _delete(i);
  }

  void _delete(int i) {
    final next = SpeedRampEdit.removePoint(_base, i);
    if (next == null) return;
    HapticFeedback.mediumImpact();
    widget.onStructure?.call(next, selected: math.min(i, next.points.length - 2));
  }

  void _doubleTap() {
    final tap = _lastTap;
    final plot = _plot;
    if (tap == null || plot == null || !widget.enabled) return;
    if (_hit(tap) != null) return;
    final x = plot.x(tap.dx);
    final next = SpeedRampEdit.addPoint(_base, x, lo: widget.minSpeed, hi: widget.maxSpeed);
    if (next == null) {
      HapticFeedback.selectionClick();
      return;
    }
    HapticFeedback.lightImpact();
    widget.onStructure?.call(next, selected: next.points.indexWhere((p) => p.x == (x * 1000).round() / 1000));
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (!widget.enabled || event is KeyUpEvent) return KeyEventResult.ignored;
    final points = _base.points;
    final i = widget.selected;
    final key = event.logicalKey;
    final handled = key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace;
    if (!handled) return KeyEventResult.ignored;
    if (i == null || i >= points.length) {
      widget.onSelected?.call(0);
      return KeyEventResult.handled;
    }
    final big = HardwareKeyboard.instance.isShiftPressed ? 3 : 1;
    if (key == LogicalKeyboardKey.arrowUp) {
      _step(SpeedRampEdit.stepSpeed(_base, i, big, lo: widget.minSpeed, hi: widget.maxSpeed), i);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _step(SpeedRampEdit.stepSpeed(_base, i, -big, lo: widget.minSpeed, hi: widget.maxSpeed), i);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _step(SpeedRampEdit.stepPosition(_base, i, -big), i);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _step(SpeedRampEdit.stepPosition(_base, i, big), i);
    } else {
      _delete(i);
    }
    return KeyEventResult.handled;
  }

  void _nudgeSpeed(int i, int steps) => _step(SpeedRampEdit.stepSpeed(_base, i, steps, lo: widget.minSpeed, hi: widget.maxSpeed), i);

  void _nudgePosition(int i, int steps) => _step(SpeedRampEdit.stepPosition(_base, i, steps), i);

  void _step(SpeedRamp next, int i) {
    if (next == _base) return;
    _stepped = next;
    widget.onStep?.call(next, selected: i);
  }

  // ---- Build ---------------------------------------------------------------------------------

  Widget _pointSemantics(int i, SpeedPlot plot) {
    final ramp = widget.ramp;
    final p = ramp.points[i];
    final lo = widget.minSpeed;
    final hi = widget.maxSpeed;
    final faster = SpeedRampEdit.stepSpeed(ramp, i, 1, lo: lo, hi: hi);
    final slower = SpeedRampEdit.stepSpeed(ramp, i, -1, lo: lo, hi: hi);
    final earlier = SpeedRampEdit.stepPosition(ramp, i, -5);
    final later = SpeedRampEdit.stepPosition(ramp, i, 5);
    final center = plot.of(p);
    const r = SpeedCurveEditor.touchHitRadius;
    final actions = <CustomSemanticsAction, VoidCallback>{
      if (earlier != ramp) const CustomSemanticsAction(label: SpeedStrings.moveEarlier): () => _nudgePosition(i, -5),
      if (later != ramp) const CustomSemanticsAction(label: SpeedStrings.moveLater): () => _nudgePosition(i, 5),
      if (SpeedRampEdit.canRemove(ramp, i)) const CustomSemanticsAction(label: SpeedStrings.deletePoint): () => _delete(i),
    };
    return Positioned.fromRect(
      key: ValueKey<String>('speed.point.$i'),
      rect: Rect.fromCenter(center: center, width: r * 2, height: r * 2),
      child: Semantics(
        container: true,
        label: SpeedStrings.pointLabel(i, ramp.points.length),
        value: SpeedStrings.pointValue(p.y, p.x),
        increasedValue: SpeedStrings.pointValue(faster.points[i].y, p.x),
        decreasedValue: SpeedStrings.pointValue(slower.points[i].y, p.x),
        selected: widget.selected == i,
        onTap: widget.enabled ? () => widget.onSelected?.call(i) : null,
        onIncrease: widget.enabled && faster != ramp ? () => _nudgeSpeed(i, 1) : null,
        onDecrease: widget.enabled && slower != ramp ? () => _nudgeSpeed(i, -1) : null,
        customSemanticsActions: widget.enabled ? actions : const {},
        child: const SizedBox.expand(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    _touch = platform == TargetPlatform.iOS || platform == TargetPlatform.android || platform == TargetPlatform.fuchsia;
    final ramp = _ramp;
    final scaler = MediaQuery.textScalerOf(context);
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: SpeedStrings.curveSemantics(widget.ramp.points.length),
      hint: SpeedStrings.curveHint,
      child: Focus(
        focusNode: _focus,
        canRequestFocus: widget.enabled,
        onKeyEvent: _key,
        child: SizedBox(
          height: widget.height,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: DanaviewColors.surface,
              borderRadius: DanaviewRadius.controlAll,
              border: Border.fromBorderSide(_focused ? DanaviewBorders.focus : DanaviewBorders.hairline),
            ),
            child: ClipRRect(
              borderRadius: DanaviewRadius.controlAll,
              child: LayoutBuilder(builder: (context, c) {
                final plot = _plot = SpeedPlot(SpeedCurveEditor.plotInset.deflateRect(Offset.zero & Size(c.maxWidth, widget.height)));
                return Stack(clipBehavior: Clip.none, children: [
                  Positioned.fill(
                    child: RawGestureDetector(
                      behavior: HitTestBehavior.opaque,
                      gestures: widget.enabled
                          ? <Type, GestureRecognizerFactory>{
                              _PointDragRecognizer: GestureRecognizerFactoryWithHandlers<_PointDragRecognizer>(
                                _PointDragRecognizer.new,
                                (r) => r
                                  ..hitTest = ((p) => _hit(p) != null)
                                  ..onDown = _down
                                  ..onMove = _move
                                  ..onEnd = _end
                                  ..onCancel = _cancel
                                  ..onLongPress = _longPress,
                              ),
                            }
                          : const <Type, GestureRecognizerFactory>{},
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onDoubleTapDown: widget.enabled ? (d) => _lastTap = d.localPosition : null,
                        onTapDown: widget.enabled
                            ? (d) {
                                if (_hit(d.localPosition) == null) {
                                  widget.onSelected?.call(null);
                                  _focus.requestFocus();
                                }
                              }
                            : null,
                        onDoubleTap: widget.enabled ? _doubleTap : null,
                        child: CustomPaint(
                          size: Size(c.maxWidth, widget.height),
                          painter: SpeedCurvePainter(
                            ramp: ramp,
                            plot: plot,
                            selected: widget.selected,
                            enabled: widget.enabled,
                            minSpeed: widget.minSpeed,
                            maxSpeed: widget.maxSpeed,
                            textScaler: scaler,
                          ),
                        ),
                      ),
                    ),
                  ),
                  for (var i = 0; i < widget.ramp.points.length; i++) _pointSemantics(i, SpeedPlot(plot.rect)),
                ]);
              }),
            ),
          ),
        ),
      ),
    );
  }
}

/// Claims the pointer at once when it goes down on a point, so the point is dragged and the
/// panel does not scroll; reports a long press when the pointer stays put.
class _PointDragRecognizer extends OneSequenceGestureRecognizer {
  _PointDragRecognizer();

  bool Function(Offset local)? hitTest;
  void Function(Offset local)? onDown;
  void Function(Offset local)? onMove;
  VoidCallback? onEnd;
  VoidCallback? onCancel;
  VoidCallback? onLongPress;

  Offset _origin = Offset.zero;
  int _pointer = 0;
  bool _moved = false;
  Timer? _timer;

  @override
  bool isPointerAllowed(PointerDownEvent event) => (hitTest?.call(event.localPosition) ?? false) && super.isPointerAllowed(event);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _pointer = event.pointer;
    startTrackingPointer(event.pointer, event.transform);
    resolve(GestureDisposition.accepted);
    _origin = event.localPosition;
    _moved = false;
    onDown?.call(event.localPosition);
    _timer?.cancel();
    _timer = Timer(kLongPressTimeout, () {
      _timer = null;
      if (!_moved) {
        stopTrackingPointer(_pointer);
        onLongPress?.call();
      }
    });
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      if (!_moved && (event.localPosition - _origin).distance < kPrecisePointerHitSlop) return;
      _moved = true;
      _timer?.cancel();
      _timer = null;
      onMove?.call(event.localPosition);
    } else if (event is PointerUpEvent) {
      _timer?.cancel();
      _timer = null;
      stopTrackingPointer(event.pointer);
      onEnd?.call();
    } else if (event is PointerCancelEvent) {
      _timer?.cancel();
      _timer = null;
      stopTrackingPointer(event.pointer);
      onCancel?.call();
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  String get debugDescription => 'speed point drag';
}

// -------------------------------------------------------------------------------------------------
// Painter
// -------------------------------------------------------------------------------------------------

/// Paints the curve, the 1x line, the grid and the points (also used by the golden test).
class SpeedCurvePainter extends CustomPainter {
  /// Creates the painter.
  SpeedCurvePainter({
    required this.ramp,
    required this.plot,
    this.selected,
    this.enabled = true,
    this.minSpeed = minClipSpeed,
    this.maxSpeed = maxClipSpeed,
    this.textScaler = TextScaler.noScaling,
  });

  /// The curve.
  final SpeedRamp ramp;

  /// The plot mapping.
  final SpeedPlot plot;

  /// The selected point.
  final int? selected;

  /// Whether the curve can be edited (dimmed otherwise).
  final bool enabled;

  /// The device's lowest speed (slower is shaded).
  final double minSpeed;

  /// The device's highest speed (faster is shaded).
  final double maxSpeed;

  /// The user's text scale for the labels.
  final TextScaler textScaler;

  static const double _pointRadius = 6.5;

  TextPainter _label(String text, Color color) => TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(fontFamily: DanaviewFonts.family, fontSize: 10, fontWeight: FontWeight.w600, color: color, height: 1),
        ),
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
        maxLines: 1,
      )..layout();

  @override
  void paint(Canvas canvas, Size size) {
    final dim = enabled ? 1.0 : DanaviewColors.disabledOpacity;
    final rect = plot.rect;

    // Speeds the device cannot play.
    final shade = Paint()..color = DanaviewColors.trackBackground.withValues(alpha: 0.35 * dim);
    if (maxSpeed < maxClipSpeed) canvas.drawRect(Rect.fromLTRB(rect.left, rect.top, rect.right, plot.dy(maxSpeed)), shade);
    if (minSpeed > minClipSpeed) canvas.drawRect(Rect.fromLTRB(rect.left, plot.dy(minSpeed), rect.right, rect.bottom), shade);

    // Grid: quarters of the clip and the decades.
    final grid = Paint()
      ..color = DanaviewColors.hairline.withValues(alpha: 0.08 * dim + 0.04)
      ..strokeWidth = 1;
    for (final fraction in const [0.25, 0.5, 0.75]) {
      final x = plot.dx(fraction);
      canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), grid);
    }
    for (final v in const [0.3, 3.0]) {
      final y = plot.dy(v);
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), grid);
    }
    for (final v in const [minClipSpeed, maxClipSpeed]) {
      final y = plot.dy(v);
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), grid);
    }

    // The 1x line.
    final y1 = plot.dy(1);
    canvas.drawLine(
      Offset(rect.left, y1),
      Offset(rect.right, y1),
      Paint()
        ..color = DanaviewColors.textMuted.withValues(alpha: 0.7 * dim)
        ..strokeWidth = 1.2,
    );

    // The curve as it plays: speed is linear in x between points.
    final curve = Path();
    final points = ramp.points;
    const samples = 24;
    for (var i = 0; i + 1 < points.length; i++) {
      final a = points[i];
      final b = points[i + 1];
      for (var s = (i == 0 ? 0 : 1); s <= samples; s++) {
        final t = s / samples;
        final off = Offset(plot.dx(a.x + (b.x - a.x) * t), plot.dy(a.y + (b.y - a.y) * t));
        if (i == 0 && s == 0) {
          curve.moveTo(off.dx, off.dy);
        } else {
          curve.lineTo(off.dx, off.dy);
        }
      }
    }
    final fill = Path.from(curve)
      ..lineTo(plot.dx(points.last.x), y1)
      ..lineTo(plot.dx(points.first.x), y1)
      ..close();
    canvas.drawPath(fill, Paint()..color = DanaviewColors.primary.withValues(alpha: 0.22 * dim));
    canvas.drawPath(
      curve,
      Paint()
        ..color = DanaviewColors.primaryLight.withValues(alpha: dim)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );

    // Axis labels.
    final label = DanaviewColors.textSecondary.withValues(alpha: dim);
    for (final (v, text) in const [(maxClipSpeed, '10×'), (1.0, '1×'), (minClipSpeed, '0.1×')]) {
      final tp = _label(text, label);
      final y = plot.dy(v);
      final top = v == maxClipSpeed ? y + 2 : (v == minClipSpeed ? y - tp.height - 2 : y - tp.height - 2);
      tp.paint(canvas, Offset(rect.left + 4, top));
      tp.dispose();
    }

    // Points.
    for (var i = 0; i < points.length; i++) {
      final c = plot.of(points[i]);
      final isSelected = i == selected;
      if (isSelected) {
        canvas.drawCircle(c, _pointRadius + 6, Paint()..color = DanaviewColors.primary.withValues(alpha: 0.28 * dim));
      }
      canvas.drawCircle(c, _pointRadius + 1.5, Paint()..color = DanaviewColors.surface.withValues(alpha: dim));
      canvas.drawCircle(
          c, _pointRadius, Paint()..color = (isSelected ? DanaviewColors.primary : DanaviewColors.primaryLight).withValues(alpha: dim));
      canvas.drawCircle(
        c,
        _pointRadius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = DanaviewColors.textPrimary.withValues(alpha: (isSelected ? 0.95 : 0.55) * dim),
      );
    }

    // The selected point's speed.
    final sel = selected;
    if (sel != null && sel >= 0 && sel < points.length) {
      final p = points[sel];
      final tp = _label(SpeedStrings.rate(p.y), DanaviewColors.textPrimary.withValues(alpha: dim));
      final c = plot.of(p);
      const padX = 6.0;
      const padY = 3.0;
      final w = tp.width + padX * 2;
      final h = tp.height + padY * 2;
      var left = c.dx - w / 2;
      left = left.clamp(rect.left, math.max(rect.left, rect.right - w)).toDouble();
      var top = c.dy - _pointRadius - 10 - h;
      if (top < 0) top = c.dy + _pointRadius + 10;
      final bubble = RRect.fromRectAndRadius(Rect.fromLTWH(left, top, w, h), const Radius.circular(DanaviewRadius.xs));
      canvas.drawRRect(bubble, Paint()..color = DanaviewColors.surfaceElevatedHigher.withValues(alpha: dim));
      canvas.drawRRect(
        bubble,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8
          ..color = DanaviewColors.border,
      );
      tp.paint(canvas, Offset(left + padX, top + padY));
      tp.dispose();
    }
  }

  @override
  bool shouldRepaint(SpeedCurvePainter old) =>
      old.ramp != ramp ||
      old.plot.rect != plot.rect ||
      old.selected != selected ||
      old.enabled != enabled ||
      old.minSpeed != minSpeed ||
      old.maxSpeed != maxSpeed ||
      old.textScaler != textScaler;
}
