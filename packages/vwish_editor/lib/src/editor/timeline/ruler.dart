// OWNER: UX-09
//
// The timeline ruler (ux.md §8.5): tick ladder by zoom, timecode labels via core `Timecode`, and
// marker flags. `TimelineRuler` is a leaf render object (its own repaint boundary) that repaints
// from the TimelineViewportController; it never rebuilds per frame.
//
// * Ladder (seconds unless noted): 1f, 2f, 5f, 10f, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600,
//   900, 1800, 3600 (then 2 h, 3 h, 6 h and 12 h so 24 h projects keep their labels apart). The
//   major interval is the smallest step whose pixel spacing is at least the measured label width
//   + 24. Frame steps (and the half second, `fps ~/ 2` frames) restart at every second and drop a
//   major that would sit closer than one step to the next second, so spacing never shrinks.
// * Minor ticks subdivide a major by 5, or by 2 when fifths would be closer than 8 px (frame steps
//   only by whole frames); none when halves would be.
// * Labels: `m:ss` for second steps, `m:ss:ff` for frame steps; once the ruler reaches one hour
//   every label carries the hours (`h:mm:ss`, `h:mm:ss:ff`, so `0:00:00` at the start of a long
//   project) and keeps one width. Laid-out paragraphs are cached in an LRU (256) keyed by (text,
//   scale).
// * Markers: a 10 px flag in the marker colour on a pole; the selected one is outlined.

import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:vwish_editor_core/model.dart' show FrameRate, Marker, MarkerId, TimeUs, Timecode, microsPerSecond;

import 'timeline_metrics.dart';
import 'timeline_style.dart';
import 'timeline_viewport.dart';

// -------------------------------------------------------------------------------------------------
// Ladder
// -------------------------------------------------------------------------------------------------

/// One entry of the ruler ladder: a number of frames (restarting at every second) or of seconds.
@immutable
final class RulerStep {
  /// A step of [frames] frames within each second.
  const RulerStep.frames(this.frames) : seconds = 0;

  /// A step of [seconds] whole seconds.
  const RulerStep.seconds(this.seconds) : frames = 0;

  /// Frames per step (frame steps), else 0.
  final int frames;

  /// Seconds per step (second steps), else 0.
  final int seconds;

  /// Whether this is a frame step (labels carry frames).
  bool get isFrameStep => frames > 0;

  /// The smallest distance between two majors of this step, in seconds, on [rate].
  double minSpacingSec(FrameRate rate) => isFrameStep ? frames / rate.fps : seconds.toDouble();

  @override
  bool operator ==(Object other) => other is RulerStep && other.frames == frames && other.seconds == seconds;

  @override
  int get hashCode => Object.hash(frames, seconds);

  @override
  String toString() => isFrameStep ? '${frames}f' : '${seconds}s';
}

/// The chosen ruler scale: a major [step] and its minor subdivision.
@immutable
final class RulerScale {
  /// A scale of [step] on [rate] with [minorDivisions] (1 = no minor ticks); [hours] makes every
  /// label carry the hours (see [hoursFor]).
  const RulerScale(this.step, this.rate, {this.minorDivisions = 1, this.hours = false});

  /// One hour in µs.
  static const TimeUs hour = 3600 * microsPerSecond;

  /// Whether a ruler whose latest time is [maxTime] labels every tick with hours (it reaches one
  /// hour).
  static bool hoursFor(TimeUs maxTime) => maxTime >= hour;

  /// The major step.
  final RulerStep step;

  /// The frame rate the step is laid out on.
  final FrameRate rate;

  /// Minor intervals per major interval (5, 2 or 1).
  final int minorDivisions;

  /// Whether every label carries the hours, so labels before and after one hour look alike.
  final bool hours;

  int get _perSecond => math.max(1, rate.fps.round());

  /// Upper bound of ticks visited by one [forEachTick] call.
  static const int maxTicks = 20000;

  /// Calls [visit] for every tick in `[startSec, endSec]` (times before 0 have none), in time order.
  void forEachTick(double startSec, double endSec, void Function(TimeUs time, bool major) visit) {
    if (!(endSec >= startSec)) return;
    final from = math.max(0.0, startSec);
    if (endSec < from) return;
    var count = 0;
    if (!step.isFrameStep) {
      final minorUs = step.seconds * microsPerSecond ~/ minorDivisions;
      final first = (from * microsPerSecond / minorUs).ceil();
      final last = (endSec * microsPerSecond / minorUs).floor();
      for (var k = first; k <= last && count < maxTicks; k++, count++) {
        visit(k * minorUs, k % minorDivisions == 0);
      }
      return;
    }
    final perSecond = _perSecond;
    final minorFrames = math.max(1, step.frames ~/ minorDivisions);
    final startUs = (from * microsPerSecond).ceil();
    final endUs = (endSec * microsPerSecond).floor();
    for (var s = from.floor(); s <= endSec.floor() && count < maxTicks; s++) {
      for (var f = 0; f < perSecond && count < maxTicks; f += minorFrames) {
        final t = rate.timeOfFrame(s * perSecond + f);
        if (t < startUs) continue;
        if (t > endUs) return;
        visit(t, isMajorFrame(f));
        count++;
      }
    }
  }

  /// Whether frame [frameInSecond] carries a major tick: a multiple of the step at least one step
  /// before the next second.
  bool isMajorFrame(int frameInSecond) => frameInSecond % step.frames == 0 && _perSecond - frameInSecond >= step.frames;

  /// The label of a major tick at [t]: `m:ss` for second steps, `m:ss:ff` for frame steps; with
  /// the hours (`h:mm:ss`, `h:mm:ss:ff`) from one hour on, or always when [hours] is set.
  String label(TimeUs t) => step.isFrameStep ? frameLabel(t, rate, hours: hours) : secondLabel(t, hours: hours);

  /// `m:ss`, or `h:mm:ss` from one hour or when [hours] is set (from `Timecode.clock`).
  static String secondLabel(TimeUs t, {bool hours = false}) {
    final s = Timecode.clock(t);
    return hours && t < hour ? '0:${s.padLeft(5, '0')}' : s;
  }

  /// `m:ss:ff`, or `h:mm:ss:ff` from one hour or when [hours] is set (from `Timecode.format`,
  /// without the leading zero of the minutes).
  static String frameLabel(TimeUs t, FrameRate rate, {bool hours = false}) {
    final s = Timecode.format(t, rate);
    if (t >= hour || s.length != 8) return s;
    return hours ? '0:$s' : (s.startsWith('0') ? s.substring(1) : s);
  }

  /// The widest label this scale can show up to [maxTime], with every digit as `0` (labels use
  /// tabular figures, so this measures them all).
  String labelTemplate(TimeUs maxTime) => label(math.max(0, maxTime)).replaceAll(RegExp(r'\d'), '0');

  @override
  bool operator ==(Object other) =>
      other is RulerScale && other.step == step && other.rate == rate && other.minorDivisions == minorDivisions && other.hours == hours;

  @override
  int get hashCode => Object.hash(step, rate, minorDivisions, hours);

  @override
  String toString() => 'RulerScale($step / $minorDivisions${hours ? ', hours' : ''})';
}

/// The ruler's tick ladder (ux.md §8.5).
abstract final class RulerLadder {
  /// Required free space between two labels, in px.
  static const double labelGap = 24;

  /// Minor ticks are never closer than this, in px.
  static const double minMinorSpacing = 8;

  /// Second steps of the ux.md ladder followed by the long-project extension.
  static const List<int> secondSteps = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 10800, 21600, 43200];

  /// The ladder for [rate], ascending: 1f, 2f, 5f, 10f, the half second (`fps ~/ 2` frames), then
  /// [secondSteps]. Frame steps that would not fit in a second, or not grow, are dropped.
  static List<RulerStep> stepsFor(FrameRate rate) {
    final perSecond = rate.fps.round();
    final out = <RulerStep>[];
    var last = 0;
    for (final f in [1, 2, 5, 10, perSecond ~/ 2]) {
      if (f > last && f < perSecond) {
        out.add(RulerStep.frames(f));
        last = f;
      }
    }
    for (final s in secondSteps) {
      out.add(RulerStep.seconds(s));
    }
    return out;
  }

  /// The scale at [pxPerSecond]: the smallest step whose spacing is at least the label width
  /// ([frameLabelWidth] for frame steps, [secondLabelWidth] for second steps, both measured from
  /// the [RulerScale.labelTemplate] of [maxTime]) + [labelGap]; the largest step when none is.
  /// Minor ticks per [minorDivisionsFor]; labels carry hours when [maxTime] reaches one hour.
  static RulerScale choose({
    required double pxPerSecond,
    required FrameRate rate,
    required double frameLabelWidth,
    required double secondLabelWidth,
    TimeUs maxTime = 0,
  }) {
    final steps = stepsFor(rate);
    var chosen = steps.last;
    for (final s in steps) {
      final need = (s.isFrameStep ? frameLabelWidth : secondLabelWidth) + labelGap;
      if (s.minSpacingSec(rate) * pxPerSecond >= need) {
        chosen = s;
        break;
      }
    }
    return RulerScale(
      chosen,
      rate,
      minorDivisions: minorDivisionsFor(chosen, chosen.minSpacingSec(rate) * pxPerSecond),
      hours: RulerScale.hoursFor(maxTime),
    );
  }

  /// 5 when fifths of [majorSpacing] are at least 8 px apart, else 2 when halves are, else 1; frame
  /// steps subdivide only by whole frames.
  static int minorDivisionsFor(RulerStep step, double majorSpacing) {
    for (final d in const [5, 2]) {
      if (majorSpacing / d < minMinorSpacing) continue;
      if (step.isFrameStep && step.frames % d != 0) continue;
      return d;
    }
    return 1;
  }
}

// -------------------------------------------------------------------------------------------------
// Label paragraphs
// -------------------------------------------------------------------------------------------------

/// Laid-out ruler label paragraphs, LRU of [capacity] keyed by (text, scale). One cache serves one
/// style; a different style or font clears it.
class RulerLabelCache {
  /// Creates an empty cache.
  RulerLabelCache({this.capacity = 256}) : assert(capacity > 0);

  /// Most paragraphs kept.
  final int capacity;

  final LinkedHashMap<(String, double), ui.Paragraph> _entries = LinkedHashMap();
  TimelineStyle? _style;

  /// Number of cached paragraphs.
  int get length => _entries.length;

  /// Whether ([text], [scale]) is cached (does not touch the LRU order).
  bool contains(String text, double scale) => _entries.containsKey((text, scale));

  /// The paragraph of [text] at text [scale] in [style], laid out on one line.
  ui.Paragraph paragraph(String text, double scale, TimelineStyle style) {
    if (!identical(style, _style)) {
      clear();
      _style = style;
    }
    final key = (text, scale);
    final hit = _entries.remove(key);
    if (hit != null) {
      _entries[key] = hit;
      return hit;
    }
    final p = _build(text, scale, style);
    _entries[key] = p;
    while (_entries.length > capacity) {
      final oldest = _entries.keys.first;
      _entries.remove(oldest)!.dispose();
    }
    return p;
  }

  /// Width of [text]'s paragraph.
  double widthOf(String text, double scale, TimelineStyle style) => paragraph(text, scale, style).maxIntrinsicWidth;

  static ui.Paragraph _build(String text, double scale, TimelineStyle style) {
    final fontSize = TimelineMetrics.labelFontSize * scale;
    final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
      fontFamily: style.fontFamily,
      fontSize: fontSize,
      maxLines: 1,
      textDirection: TextDirection.ltr,
    ))
      ..pushStyle(ui.TextStyle(
        color: style.rulerLabelForeground,
        fontFamily: style.fontFamily,
        fontSize: fontSize,
        fontWeight: FontWeight.w500,
        fontFeatures: const [ui.FontFeature.tabularFigures()],
      ))
      ..addText(text);
    return builder.build()..layout(const ui.ParagraphConstraints(width: double.infinity));
  }

  /// Drops every paragraph.
  void clear() {
    for (final p in _entries.values) {
      p.dispose();
    }
    _entries.clear();
  }
}

// -------------------------------------------------------------------------------------------------
// Painting
// -------------------------------------------------------------------------------------------------

/// What one ruler paint drew (debug builds only; tests read it).
@immutable
class RulerPaintReport {
  /// Creates a report.
  const RulerPaintReport({
    required this.scale,
    required this.labels,
    required this.majorTicks,
    required this.minorTicks,
    required this.markers,
  });

  /// The scale used.
  final RulerScale? scale;

  /// Each painted label and its rect (ruler-local).
  final List<(String, Rect)> labels;

  /// Number of major ticks painted.
  final int majorTicks;

  /// Number of minor ticks painted.
  final int minorTicks;

  /// Ids of the marker flags painted.
  final List<MarkerId> markers;
}

/// Paints the ruler for a viewport state (used by [RenderTimelineRuler]; pure so tests can call it
/// on a recorder).
class RulerPainter {
  /// Creates a painter drawing with [style] and caching labels in [labels].
  RulerPainter({required this.style, required this.labels});

  /// Colours and font.
  final TimelineStyle style;

  /// Label paragraphs.
  final RulerLabelCache labels;

  /// Major tick length for a ruler of [height].
  static double majorTickLength(double height) => (height * 0.32).roundToDouble();

  /// Minor tick length for a ruler of [height].
  static double minorTickLength(double height) => (height * 0.18).roundToDouble();

  /// Height of a marker flag for a ruler of [height].
  static double flagHeight(double height) => math.min(10, (height * 0.42).roundToDouble());

  /// The scale for [viewport] at text [scale] (labels measured with this painter's font).
  RulerScale? scaleFor(TimelineViewportController viewport, double scale) {
    final pps = viewport.pxPerSecond;
    if (pps <= 0 || !viewport.hasLayout) return null;
    final rate = viewport.frameRate;
    final maxTime = math.max(viewport.duration, viewport.visibleRange.end);
    final frameTemplate = RulerScale(const RulerStep.frames(1), rate).labelTemplate(maxTime);
    final secondTemplate = RulerScale(const RulerStep.seconds(1), rate).labelTemplate(maxTime);
    return RulerLadder.choose(
      pxPerSecond: pps,
      rate: rate,
      frameLabelWidth: labels.widthOf(frameTemplate, scale, style),
      secondLabelWidth: labels.widthOf(secondTemplate, scale, style),
      maxTime: maxTime,
    );
  }

  /// Paints a ruler of [size] at [offset]: background, ticks, labels and the flags of [markers]
  /// (sorted by time) with [selected] outlined. Returns what was drawn.
  RulerPaintReport paint(
    Canvas canvas,
    Offset offset,
    Size size, {
    required TimelineViewportController viewport,
    required double textScale,
    required double devicePixelRatio,
    List<Marker> markers = const [],
    MarkerId? selected,
  }) {
    final rect = offset & size;
    canvas.drawRect(rect, Paint()..color = style.rulerBackground);
    final dpr = devicePixelRatio > 0 ? devicePixelRatio : 1.0;
    double snap(double x) => (x * dpr).roundToDouble() / dpr;
    const hairline = 1.0;
    canvas.drawRect(
      Rect.fromLTWH(rect.left, rect.bottom - hairline, rect.width, hairline),
      Paint()..color = style.rulerSeparator,
    );

    final scale = scaleFor(viewport, textScale);
    final labelRects = <(String, Rect)>[];
    var majors = 0, minors = 0;
    final painted = <MarkerId>[];
    if (scale == null) {
      return RulerPaintReport(scale: null, labels: labelRects, majorTicks: 0, minorTicks: 0, markers: painted);
    }

    canvas.save();
    canvas.clipRect(rect);
    final h = size.height;
    final majorLen = majorTickLength(h), minorLen = minorTickLength(h);
    final majorPath = Path(), minorPath = Path();
    final pending = <(TimeUs, double)>[];
    // Start one label width early so a label whose tick is just off the left edge still shows.
    final template = scale.labelTemplate(math.max(viewport.duration, viewport.visibleRange.end));
    final lead = (labels.widthOf(template, textScale, style) + 4) / viewport.pxPerSecond;
    scale.forEachTick(viewport.secAt(0) - lead, viewport.secAt(size.width), (t, major) {
      final x = snap(viewport.xOf(t));
      if (major) {
        majorPath.addRect(Rect.fromLTWH(rect.left + x, rect.bottom - hairline - majorLen, hairline, majorLen));
        majors++;
        pending.add((t, x));
      } else {
        minorPath.addRect(Rect.fromLTWH(rect.left + x, rect.bottom - hairline - minorLen, hairline, minorLen));
        minors++;
      }
    });
    canvas.drawPath(minorPath, Paint()..color = style.rulerMinorTick);
    canvas.drawPath(majorPath, Paint()..color = style.rulerMajorTick);

    for (final (t, x) in pending) {
      final text = scale.label(t);
      final p = labels.paragraph(text, textScale, style);
      final top = math.max(0.0, ((h - majorLen - p.height) / 2).floorToDouble());
      final at = Offset(rect.left + x + 4, rect.top + top);
      if (at.dx > rect.right) continue;
      canvas.drawParagraph(p, at);
      labelRects.add((text, Rect.fromLTWH(at.dx - rect.left, top, p.maxIntrinsicWidth, p.height)));
    }

    if (markers.isNotEmpty) {
      final flagW = TimelineMetrics.markerFlagWidth;
      final flagH = flagHeight(h);
      final firstVisible = _firstMarkerFrom(markers, viewport.timeAt(-flagW - 2));
      final pole = Paint();
      for (var i = firstVisible; i < markers.length; i++) {
        final m = markers[i];
        final x = snap(viewport.xOf(m.time));
        if (x > size.width + 1) break;
        final color = style.markerColor(m.colorIndex);
        final isSelected = m.id == selected;
        final left = rect.left + x;
        final poleWidth = isSelected ? 2.0 : 1.0;
        canvas.drawRect(Rect.fromLTWH(left, rect.top, poleWidth, h - hairline), pole..color = color);
        final flag = Path()
          ..moveTo(left, rect.top + 1)
          ..lineTo(left + flagW, rect.top + 1)
          ..lineTo(left + flagW - 3, rect.top + 1 + flagH / 2)
          ..lineTo(left + flagW, rect.top + 1 + flagH)
          ..lineTo(left, rect.top + 1 + flagH)
          ..close();
        canvas.drawPath(flag, Paint()..color = color);
        if (isSelected) {
          canvas.drawPath(
            flag,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5
              ..color = style.selection,
          );
        }
        painted.add(m.id);
      }
    }
    canvas.restore();
    return RulerPaintReport(scale: scale, labels: labelRects, majorTicks: majors, minorTicks: minors, markers: painted);
  }

  static int _firstMarkerFrom(List<Marker> markers, TimeUs t) {
    var lo = 0, hi = markers.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (markers[mid].time < t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// The marker whose flag is under lanes-area x [x] (nearest flag centre within half of
  /// [hitSize], at least the flag itself), or null. [markers] are sorted by time.
  static Marker? markerAt(List<Marker> markers, double x, TimelineViewportController viewport, {double hitSize = 24}) {
    if (markers.isEmpty || !viewport.hasLayout || viewport.pxPerSecond <= 0) return null;
    final flagW = TimelineMetrics.markerFlagWidth;
    final reach = math.max(hitSize / 2, flagW / 2 + 2);
    final from = _firstMarkerFrom(markers, viewport.timeAt(x - flagW / 2 - reach));
    Marker? best;
    var bestDist = double.infinity;
    for (var i = from; i < markers.length; i++) {
      final centre = viewport.xOf(markers[i].time) + flagW / 2;
      if (centre - x > reach) break;
      final d = (centre - x).abs();
      if (d <= reach && d < bestDist) {
        best = markers[i];
        bestDist = d;
      }
    }
    return best;
  }
}

// -------------------------------------------------------------------------------------------------
// Widget and render object
// -------------------------------------------------------------------------------------------------

/// The ruler above the lanes (ux.md §8.5): ticks, timecode labels and marker flags for [viewport].
/// It sizes to the available width and [metrics]' ruler height, and repaints (never relayouts or
/// rebuilds) when the viewport moves.
class TimelineRuler extends LeafRenderObjectWidget {
  /// Creates the ruler.
  const TimelineRuler({
    super.key,
    required this.viewport,
    this.markers = const [],
    this.selectedMarker,
    this.style,
    this.metrics,
    this.labelCache,
  });

  /// The zoom and scroll to paint.
  final TimelineViewportController viewport;

  /// The project's markers sorted by time (the timeline snapshot's markers).
  final List<Marker> markers;

  /// The selected marker (outlined).
  final MarkerId? selectedMarker;

  /// Colours and font (default [TimelineStyle.standard]).
  final TimelineStyle? style;

  /// Text scale and ruler height (default: from `MediaQuery`'s text scaler).
  final TimelineMetrics? metrics;

  /// Label paragraphs to share (default: one per ruler).
  final RulerLabelCache? labelCache;

  TimelineMetrics _metricsOf(BuildContext context) =>
      metrics ?? TimelineMetrics(textScale: TimelineMetrics.scaleOf(MediaQuery.textScalerOf(context)));

  double _dprOf(BuildContext context) => MediaQuery.maybeDevicePixelRatioOf(context) ?? View.of(context).devicePixelRatio;

  @override
  RenderTimelineRuler createRenderObject(BuildContext context) {
    final m = _metricsOf(context);
    return RenderTimelineRuler(
      viewport: viewport,
      markers: markers,
      selectedMarker: selectedMarker,
      style: style ?? TimelineStyle.standard,
      textScale: m.textScale,
      rulerHeight: m.rulerHeight,
      devicePixelRatio: _dprOf(context),
      labelCache: labelCache,
    );
  }

  @override
  void updateRenderObject(BuildContext context, RenderTimelineRuler renderObject) {
    final m = _metricsOf(context);
    renderObject
      ..viewport = viewport
      ..markers = markers
      ..selectedMarker = selectedMarker
      ..style = style ?? TimelineStyle.standard
      ..textScale = m.textScale
      ..rulerHeight = m.rulerHeight
      ..devicePixelRatio = _dprOf(context)
      ..labelCache = labelCache;
  }
}

/// Render object of [TimelineRuler] (a repaint boundary).
class RenderTimelineRuler extends RenderBox {
  /// Creates the render object.
  RenderTimelineRuler({
    required TimelineViewportController viewport,
    required List<Marker> markers,
    MarkerId? selectedMarker,
    required TimelineStyle style,
    required double textScale,
    required double rulerHeight,
    required double devicePixelRatio,
    RulerLabelCache? labelCache,
  })  : _viewport = viewport,
        _markers = markers,
        _selectedMarker = selectedMarker,
        _style = style,
        _textScale = textScale,
        _rulerHeight = rulerHeight,
        _dpr = devicePixelRatio,
        _sharedCache = labelCache;

  TimelineViewportController _viewport;
  List<Marker> _markers;
  MarkerId? _selectedMarker;
  TimelineStyle _style;
  double _textScale;
  double _rulerHeight;
  double _dpr;
  RulerLabelCache? _sharedCache;
  RulerLabelCache? _ownCache;

  RulerLabelCache get _cache => _sharedCache ?? (_ownCache ??= RulerLabelCache());

  /// What the last paint drew (debug builds; null in release).
  RulerPaintReport? debugLastPaint;

  /// Number of paints (debug builds), for repaint tests.
  int debugPaintCount = 0;

  /// The viewport.
  TimelineViewportController get viewport => _viewport;
  set viewport(TimelineViewportController value) {
    if (identical(value, _viewport)) return;
    if (attached) _viewport.removeListener(markNeedsPaint);
    _viewport = value;
    if (attached) _viewport.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  /// Markers sorted by time.
  List<Marker> get markers => _markers;
  set markers(List<Marker> value) {
    if (identical(value, _markers) || listEquals(value, _markers)) return;
    _markers = value;
    markNeedsPaint();
  }

  /// The selected marker.
  MarkerId? get selectedMarker => _selectedMarker;
  set selectedMarker(MarkerId? value) {
    if (value == _selectedMarker) return;
    _selectedMarker = value;
    markNeedsPaint();
  }

  /// Colours and font.
  TimelineStyle get style => _style;
  set style(TimelineStyle value) {
    if (value == _style) return;
    _style = value;
    markNeedsPaint();
  }

  /// Text scale of the labels.
  double get textScale => _textScale;
  set textScale(double value) {
    if (value == _textScale) return;
    _textScale = value;
    markNeedsPaint();
  }

  /// Preferred height.
  double get rulerHeight => _rulerHeight;
  set rulerHeight(double value) {
    if (value == _rulerHeight) return;
    _rulerHeight = value;
    markNeedsLayout();
  }

  /// Device pixel ratio (ticks snap to physical pixels).
  double get devicePixelRatio => _dpr;
  set devicePixelRatio(double value) {
    if (value == _dpr) return;
    _dpr = value;
    markNeedsPaint();
  }

  /// A shared label cache, or null for the ruler's own.
  RulerLabelCache? get labelCache => _sharedCache;
  set labelCache(RulerLabelCache? value) {
    if (identical(value, _sharedCache)) return;
    _sharedCache = value;
    markNeedsPaint();
  }

  /// The marker whose flag is under [local] (ruler coordinates), with the 44 px touch target when
  /// [touch] is true.
  Marker? markerAt(Offset local, {bool touch = true}) {
    if (local.dy < 0 || local.dy > size.height) return null;
    return RulerPainter.markerAt(_markers, local.dx, _viewport, hitSize: touch ? 44 : 24);
  }

  @override
  bool get isRepaintBoundary => true;

  // Not `sizedByParent`: the height follows [rulerHeight], so a change must reach `performLayout`.
  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(Size(constraints.hasBoundedWidth ? constraints.maxWidth : 0, _rulerHeight));

  @override
  void performLayout() => size = computeDryLayout(constraints);

  @override
  double computeMinIntrinsicHeight(double width) => _rulerHeight;

  @override
  double computeMaxIntrinsicHeight(double width) => _rulerHeight;

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _viewport.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _viewport.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void dispose() {
    _ownCache?.clear();
    super.dispose();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final report = RulerPainter(style: _style, labels: _cache).paint(
      context.canvas,
      offset,
      size,
      viewport: _viewport,
      textScale: _textScale,
      devicePixelRatio: _dpr,
      markers: _markers,
      selected: _selectedMarker,
    );
    assert(() {
      debugLastPaint = report;
      debugPaintCount++;
      return true;
    }());
  }
}
