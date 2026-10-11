// OWNER: UX-12
//
// Timeline semantics (ARCH §17.9, ux.md §8.8) and the editor's throttled announcements (V-U4).
//
// * `editorAnnounce(context, text)` sends a live announcement to VoiceOver/TalkBack through
//   `SemanticsService.sendAnnouncement` (the multi-window API of Flutter 3.44; the old `announce` is
//   deprecated). At most one announcement goes out per second: the first one at once, later ones
//   within the window replace each other and the newest is sent when the window ends (a burst of
//   "Moved to 0:03 … 0:04 … 0:05" reads as one "0:05").
// * `TimelineItemSemantics.decorate` is the canvas' `semanticsDecorator`: every clip node gets a
//   tap (select) and custom actions that run core commands through `EditorController.apply` (one
//   history entry each): split at the playhead, delete (ripple when ripple mode is on), move by one
//   frame or one second, and trim either edge by one frame or one second. Results are announced.
// * `TimelineSemanticsLayer` is a leaf render object over the ruler and the lanes that paints
//   nothing and takes no hits; it only contributes semantics nodes: the playhead as an adjustable
//   slider (one frame per increase/decrease), the visible markers, transition chips ("+" included)
//   and the keyframe diamonds of selected items (all items while the Keyframes panel is open).
//   Like the canvas it updates from the viewport without rebuilding widgets.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show FlutterView;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart';

import '../state/editor_controller.dart';
import '../state/editor_state.dart' show EditorSelection, EditorState, SelectMode;
import 'render_timeline_canvas.dart' show TimelineSemanticsTarget;
import 'timeline_hit.dart';
import 'timeline_metrics.dart';
import 'timeline_snapshot.dart';
import 'timeline_viewport.dart';

// -------------------------------------------------------------------------------------------------
// Copy
// -------------------------------------------------------------------------------------------------

/// Plain copy of the timeline's semantics and announcements.
abstract final class TimelineSemanticsStrings {
  /// Split action.
  static const String split = 'Split at playhead';

  /// Delete action.
  static const String delete = 'Delete';

  /// Move one frame earlier.
  static const String moveFrameEarlier = 'Move 1 frame earlier';

  /// Move one frame later.
  static const String moveFrameLater = 'Move 1 frame later';

  /// Move one second earlier.
  static const String moveSecondEarlier = 'Move 1 second earlier';

  /// Move one second later.
  static const String moveSecondLater = 'Move 1 second later';

  /// Trim the start one frame earlier (longer clip).
  static const String trimStartFrameEarlier = 'Trim start 1 frame earlier';

  /// Trim the start one frame later (shorter clip).
  static const String trimStartFrameLater = 'Trim start 1 frame later';

  /// Trim the start one second earlier.
  static const String trimStartSecondEarlier = 'Trim start 1 second earlier';

  /// Trim the start one second later.
  static const String trimStartSecondLater = 'Trim start 1 second later';

  /// Trim the end one frame earlier (shorter clip).
  static const String trimEndFrameEarlier = 'Trim end 1 frame earlier';

  /// Trim the end one frame later (longer clip).
  static const String trimEndFrameLater = 'Trim end 1 frame later';

  /// Trim the end one second earlier.
  static const String trimEndSecondEarlier = 'Trim end 1 second earlier';

  /// Trim the end one second later.
  static const String trimEndSecondLater = 'Trim end 1 second later';

  /// The playhead slider.
  static const String playhead = 'Playhead';

  /// Hint of the playhead slider.
  static const String playheadHint = 'Swipe up or down to move one frame';

  /// A marker node.
  static String marker(Marker marker) =>
      marker.name.isEmpty ? 'Marker at ${Timecode.clock(marker.time)}' : 'Marker ${marker.name} at ${Timecode.clock(marker.time)}';

  /// A transition chip.
  static String transition(Transition transition, TimeUs at) => '${transitionKind(transition.kind)} transition at ${Timecode.clock(at)}';

  /// The "+" add-transition button.
  static String addTransition(TimeUs at) => 'Add transition at ${Timecode.clock(at)}';

  /// A keyframe diamond.
  static String keyframe(String property, TimeUs at) => '${propertyName(property)} keyframe at ${Timecode.clock(at)}';

  /// The plain name of a transition kind.
  static String transitionKind(TransitionKind kind) {
    final name = kind.name;
    final spaced = name.replaceAllMapped(RegExp('[A-Z]'), (m) => ' ${m[0]!.toLowerCase()}');
    return spaced[0].toUpperCase() + spaced.substring(1);
  }

  /// The plain name of a keyframed property id (`transform.position` → "Position").
  static String propertyName(String property) {
    final last = property.split('.').last;
    final spaced = last.replaceAllMapped(RegExp('[A-Z]'), (m) => ' ${m[0]!.toLowerCase()}');
    return spaced.isEmpty ? property : spaced[0].toUpperCase() + spaced.substring(1);
  }

  /// Announced after a split.
  static const String didSplit = 'Split';

  /// Announced after a delete.
  static const String didDelete = 'Deleted';

  /// Announced after a move.
  static String movedTo(TimeUs start) => 'Moved to ${Timecode.clock(start)}';

  /// Announced after a trim.
  static String trimmedTo(TimeUs duration) => 'Length ${Timecode.clock(duration)}';

  /// Announced when a command is refused (the toast says why).
  static const String notChanged = 'Not changed';

  /// Announced when the playhead moves through the slider.
  static String playheadAt(String timecode) => 'Playhead at $timecode';
}

// -------------------------------------------------------------------------------------------------
// Announcements (V-U4)
// -------------------------------------------------------------------------------------------------

/// Sends one announcement (tests replace it).
typedef EditorAnnouncementSender = void Function(FlutterView view, String message, TextDirection textDirection);

/// Throttles live announcements to one per [interval] (V-U4): the first goes out at once; within
/// the window the newest replaces older pending ones and is sent when the window ends.
class EditorAnnouncer {
  /// Creates an announcer; [send] defaults to `SemanticsService.sendAnnouncement`.
  EditorAnnouncer({this.interval = const Duration(seconds: 1), EditorAnnouncementSender? send}) : _send = send ?? _platformSend;

  /// The announcer `editorAnnounce` uses.
  static EditorAnnouncer instance = EditorAnnouncer();

  /// Minimum time between two announcements.
  final Duration interval;

  final EditorAnnouncementSender _send;
  Timer? _gate;
  (FlutterView, String, TextDirection)? _pending;

  /// Announcements sent so far (diagnostics and tests).
  int sent = 0;

  /// Whether an announcement waits for the window to end.
  bool get hasPending => _pending != null;

  static void _platformSend(FlutterView view, String message, TextDirection textDirection) {
    unawaited(SemanticsService.sendAnnouncement(view, message, textDirection));
  }

  /// Announces [message] in [view] now, or when the current window ends.
  void announce(FlutterView view, String message, {TextDirection textDirection = TextDirection.ltr}) {
    if (message.isEmpty) return;
    if (_gate == null) {
      _deliver(view, message, textDirection);
      return;
    }
    _pending = (view, message, textDirection);
  }

  void _deliver(FlutterView view, String message, TextDirection textDirection) {
    sent++;
    try {
      _send(view, message, textDirection);
    } catch (e, s) {
      FlutterError.reportError(FlutterErrorDetails(exception: e, stack: s, library: 'vwish_editor', context: ErrorDescription('sending an announcement')));
    }
    _gate = Timer(interval, _onWindowEnd);
  }

  void _onWindowEnd() {
    _gate = null;
    final p = _pending;
    _pending = null;
    if (p != null) _deliver(p.$1, p.$2, p.$3);
  }

  /// Drops a pending announcement and closes the window.
  void reset() {
    _gate?.cancel();
    _gate = null;
    _pending = null;
  }
}

/// Announces [message] to VoiceOver/TalkBack through the throttled [EditorAnnouncer.instance]
/// (ARCH §17.9, V-U4). Safe to call often; at most one announcement per second is spoken.
void editorAnnounce(BuildContext context, String message) {
  final view = View.maybeOf(context) ?? WidgetsBinding.instance.platformDispatcher.implicitView;
  if (view == null) return;
  EditorAnnouncer.instance.announce(view, message, textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr);
}

// -------------------------------------------------------------------------------------------------
// Clip semantics actions
// -------------------------------------------------------------------------------------------------

/// The custom semantics actions of clip nodes and the commands behind them (ARCH §17.9).
class TimelineItemSemantics {
  /// Creates the actions over [controller] and its current [state]; [playhead] is the split time;
  /// [announce] speaks results.
  TimelineItemSemantics({
    required EditorController Function() controller,
    required EditorState Function() state,
    required ValueListenable<TimeUs> playhead,
    required void Function(String message) announce,
  })  : _controller = controller,
        _state = state,
        _playhead = playhead,
        _announce = announce;

  final EditorController Function() _controller;
  final EditorState Function() _state;
  final ValueListenable<TimeUs> _playhead;
  final void Function(String message) _announce;

  /// Split at the playhead.
  static const CustomSemanticsAction splitAction = CustomSemanticsAction(label: TimelineSemanticsStrings.split);

  /// Delete.
  static const CustomSemanticsAction deleteAction = CustomSemanticsAction(label: TimelineSemanticsStrings.delete);

  /// Move by −1, +1 frame and −1, +1 second.
  static const List<CustomSemanticsAction> moveActions = [
    CustomSemanticsAction(label: TimelineSemanticsStrings.moveFrameEarlier),
    CustomSemanticsAction(label: TimelineSemanticsStrings.moveFrameLater),
    CustomSemanticsAction(label: TimelineSemanticsStrings.moveSecondEarlier),
    CustomSemanticsAction(label: TimelineSemanticsStrings.moveSecondLater),
  ];

  /// Trim the start by −1, +1 frame and −1, +1 second.
  static const List<CustomSemanticsAction> trimStartActions = [
    CustomSemanticsAction(label: TimelineSemanticsStrings.trimStartFrameEarlier),
    CustomSemanticsAction(label: TimelineSemanticsStrings.trimStartFrameLater),
    CustomSemanticsAction(label: TimelineSemanticsStrings.trimStartSecondEarlier),
    CustomSemanticsAction(label: TimelineSemanticsStrings.trimStartSecondLater),
  ];

  /// Trim the end by −1, +1 frame and −1, +1 second.
  static const List<CustomSemanticsAction> trimEndActions = [
    CustomSemanticsAction(label: TimelineSemanticsStrings.trimEndFrameEarlier),
    CustomSemanticsAction(label: TimelineSemanticsStrings.trimEndFrameLater),
    CustomSemanticsAction(label: TimelineSemanticsStrings.trimEndSecondEarlier),
    CustomSemanticsAction(label: TimelineSemanticsStrings.trimEndSecondLater),
  ];

  // (frames, seconds) of the four steps, in the order of the action lists.
  static const List<(int, int)> _steps = [(-1, 0), (1, 0), (0, -1), (0, 1)];

  /// The canvas' semantics decorator: tap selects; editable clips get the edit actions.
  void decorate(TimelineSemanticsTarget target, SemanticsConfiguration config) {
    final id = target.item.id;
    config.onTap = () => select(id);
    if (target.lane.locked) return;
    final actions = <CustomSemanticsAction, VoidCallback>{
      splitAction: () => split(id),
      deleteAction: () => delete(id),
    };
    for (var i = 0; i < _steps.length; i++) {
      final (frames, seconds) = _steps[i];
      actions[moveActions[i]] = () => move(id, frames: frames, seconds: seconds);
      actions[trimStartActions[i]] = () => trim(id, TrimEdge.start, frames: frames, seconds: seconds);
      actions[trimEndActions[i]] = () => trim(id, TrimEdge.end, frames: frames, seconds: seconds);
    }
    config.customSemanticsActions = actions;
  }

  EditProject? get _project => _state().project;

  /// Selects [item].
  void select(ItemId item) => _controller().select(item, mode: SelectMode.replace);

  /// Splits [item] at the playhead.
  EditResult split(ItemId item) {
    final project = _project;
    if (project == null) return const EditUnchanged();
    final at = project.settings.frameRate.quantize(_playhead.value);
    return _report(_controller().apply(SplitItems({item}, at)), TimelineSemanticsStrings.didSplit);
  }

  /// Deletes [item] (ripple delete in ripple mode).
  EditResult delete(ItemId item) {
    final c = _controller();
    return _report(c.apply(DeleteItems({item}, ripple: _state().modes.ripple)), TimelineSemanticsStrings.didDelete);
  }

  /// Moves [item] by [frames] frames plus [seconds] seconds.
  EditResult move(ItemId item, {int frames = 0, int seconds = 0}) {
    final project = _project;
    final loc = project?.index.locate(item);
    if (project == null || loc == null) return const EditUnchanged();
    final rate = project.settings.frameRate;
    final start = loc.item.start;
    final target = _offset(rate, start, frames, seconds);
    final c = _controller();
    final result = c.apply(MoveItems({item}, target - start, ripple: _state().modes.ripple));
    final moved = _state().project?.index.locate(item)?.item.start ?? target;
    return _report(result, TimelineSemanticsStrings.movedTo(moved));
  }

  /// Moves the [edge] of [item] by [frames] frames plus [seconds] seconds.
  EditResult trim(ItemId item, TrimEdge edge, {int frames = 0, int seconds = 0}) {
    final project = _project;
    final loc = project?.index.locate(item);
    if (project == null || loc == null) return const EditUnchanged();
    final rate = project.settings.frameRate;
    final edgeTime = edge == TrimEdge.start ? loc.item.start : loc.item.end;
    final c = _controller();
    final result = c.apply(TrimItem(item, edge, _offset(rate, edgeTime, frames, seconds), ripple: _state().modes.ripple));
    final duration = _state().project?.index.locate(item)?.item.duration ?? loc.item.duration;
    return _report(result, TimelineSemanticsStrings.trimmedTo(duration));
  }

  static TimeUs _offset(FrameRate rate, TimeUs t, int frames, int seconds) {
    final k = rate.frameIndexNearest(t) + frames;
    final shifted = rate.timeOfFrame(k) + seconds * microsPerSecond;
    return rate.quantizeNearest(shifted);
  }

  EditResult _report(EditResult result, String success) {
    _announce(result is EditApplied ? success : TimelineSemanticsStrings.notChanged);
    return result;
  }
}

// -------------------------------------------------------------------------------------------------
// Playhead, markers, transitions and keyframes as nodes
// -------------------------------------------------------------------------------------------------

/// Callbacks of the [TimelineSemanticsLayer] nodes.
@immutable
final class TimelineSemanticsCallbacks {
  /// Creates the callbacks.
  const TimelineSemanticsCallbacks({
    required this.seek,
    required this.selectMarker,
    required this.openTransition,
    required this.selectKeyframe,
  });

  /// Seeks to a time (playhead slider steps).
  final ValueChanged<TimeUs> seek;

  /// Selects a marker and seeks to it.
  final ValueChanged<Marker> selectMarker;

  /// Selects the cut and opens the transition panel.
  final ValueChanged<TransitionRef> openTransition;

  /// Selects a keyframe and seeks to it.
  final ValueChanged<KeyframeRef> selectKeyframe;
}

/// Semantics nodes for the playhead (slider), markers, transitions and keyframes (ARCH §17.9).
///
/// Placed over the ruler and the lanes (top = ruler top), with the canvas' x origin. Paints nothing
/// and takes no hits.
class TimelineSemanticsLayer extends LeafRenderObjectWidget {
  /// Creates the layer.
  const TimelineSemanticsLayer({
    super.key,
    required this.snapshot,
    required this.viewport,
    required this.metrics,
    required this.playhead,
    required this.callbacks,
    this.playing,
    this.selection = EditorSelection.empty,
    this.showAllKeyframes = false,
  });

  /// What is on the timeline.
  final TimelineSnapshot snapshot;

  /// Zoom and scroll.
  final TimelineViewportController viewport;

  /// Sizes (ruler height, hit sizes).
  final TimelineMetrics metrics;

  /// The playhead.
  final ValueListenable<TimeUs> playhead;

  /// Whether playback runs (the slider value then updates once per second).
  final ValueListenable<bool>? playing;

  /// The selection (keyframes of selected items get nodes).
  final EditorSelection selection;

  /// Every item's keyframes get nodes (Keyframes panel open).
  final bool showAllKeyframes;

  /// What the nodes do.
  final TimelineSemanticsCallbacks callbacks;

  @override
  RenderTimelineSemanticsLayer createRenderObject(BuildContext context) => RenderTimelineSemanticsLayer(
        snapshot: snapshot,
        viewport: viewport,
        metrics: metrics,
        playhead: playhead,
        playing: playing,
        selection: selection,
        showAllKeyframes: showAllKeyframes,
        callbacks: callbacks,
      );

  @override
  void updateRenderObject(BuildContext context, RenderTimelineSemanticsLayer renderObject) {
    renderObject
      ..snapshot = snapshot
      ..viewport = viewport
      ..metrics = metrics
      ..playhead = playhead
      ..playing = playing
      ..selection = selection
      ..showAllKeyframes = showAllKeyframes
      ..callbacks = callbacks;
  }
}

/// Render object of [TimelineSemanticsLayer].
class RenderTimelineSemanticsLayer extends RenderBox {
  /// Creates the render object.
  RenderTimelineSemanticsLayer({
    required TimelineSnapshot snapshot,
    required TimelineViewportController viewport,
    required TimelineMetrics metrics,
    required ValueListenable<TimeUs> playhead,
    ValueListenable<bool>? playing,
    EditorSelection selection = EditorSelection.empty,
    bool showAllKeyframes = false,
    required TimelineSemanticsCallbacks callbacks,
  })  : _snapshot = snapshot,
        _viewport = viewport,
        _metrics = metrics,
        _playhead = playhead,
        _playing = playing,
        _selection = selection,
        _showAllKeyframes = showAllKeyframes,
        _callbacks = callbacks;

  TimelineSnapshot _snapshot;
  TimelineViewportController _viewport;
  TimelineMetrics _metrics;
  ValueListenable<TimeUs> _playhead;
  ValueListenable<bool>? _playing;
  EditorSelection _selection;
  bool _showAllKeyframes;
  TimelineSemanticsCallbacks _callbacks;
  TimelineCanvasGeometry? _geometry;
  String? _lastPlayheadValue;
  final Map<Object, SemanticsNode> _nodes = {};

  /// The snapshot.
  TimelineSnapshot get snapshot => _snapshot;
  set snapshot(TimelineSnapshot value) {
    if (identical(value, _snapshot)) return;
    _snapshot = value;
    _geometry = null;
    markNeedsSemanticsUpdate();
  }

  /// The viewport.
  TimelineViewportController get viewport => _viewport;
  set viewport(TimelineViewportController value) {
    if (identical(value, _viewport)) return;
    if (attached) _viewport.removeListener(markNeedsSemanticsUpdate);
    _viewport = value;
    _geometry = null;
    if (attached) _viewport.addListener(markNeedsSemanticsUpdate);
    markNeedsSemanticsUpdate();
  }

  /// The metrics.
  TimelineMetrics get metrics => _metrics;
  set metrics(TimelineMetrics value) {
    if (value == _metrics) return;
    _metrics = value;
    _geometry = null;
    markNeedsSemanticsUpdate();
  }

  /// The playhead.
  ValueListenable<TimeUs> get playhead => _playhead;
  set playhead(ValueListenable<TimeUs> value) {
    if (identical(value, _playhead)) return;
    if (attached) _playhead.removeListener(_onPlayhead);
    _playhead = value;
    if (attached) _playhead.addListener(_onPlayhead);
    markNeedsSemanticsUpdate();
  }

  /// Whether playback runs.
  ValueListenable<bool>? get playing => _playing;
  set playing(ValueListenable<bool>? value) {
    if (identical(value, _playing)) return;
    if (attached) _playing?.removeListener(_onPlayhead);
    _playing = value;
    if (attached) _playing?.addListener(_onPlayhead);
  }

  /// The selection.
  EditorSelection get selection => _selection;
  set selection(EditorSelection value) {
    if (value == _selection) return;
    _selection = value;
    markNeedsSemanticsUpdate();
  }

  /// Whether every item's keyframes get nodes.
  bool get showAllKeyframes => _showAllKeyframes;
  set showAllKeyframes(bool value) {
    if (value == _showAllKeyframes) return;
    _showAllKeyframes = value;
    markNeedsSemanticsUpdate();
  }

  /// The callbacks.
  TimelineSemanticsCallbacks get callbacks => _callbacks;
  set callbacks(TimelineSemanticsCallbacks value) {
    if (identical(value, _callbacks)) return;
    _callbacks = value;
    markNeedsSemanticsUpdate();
  }

  TimelineCanvasGeometry get _geo => _geometry ??= TimelineCanvasGeometry(snapshot: _snapshot, metrics: _metrics, viewport: _viewport);

  void _onPlayhead() {
    final value = _playheadValue(_playhead.value);
    if (value == _lastPlayheadValue) return;
    _lastPlayheadValue = value;
    markNeedsSemanticsUpdate();
  }

  String _playheadValue(TimeUs t) =>
      (_playing?.value ?? false) ? Timecode.clock(t) : Timecode.format(_snapshot.frameRate.quantize(t), _snapshot.frameRate);

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _viewport.addListener(markNeedsSemanticsUpdate);
    _playhead.addListener(_onPlayhead);
    _playing?.addListener(_onPlayhead);
  }

  @override
  void detach() {
    _viewport.removeListener(markNeedsSemanticsUpdate);
    _playhead.removeListener(_onPlayhead);
    _playing?.removeListener(_onPlayhead);
    super.detach();
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest.isFinite ? constraints.biggest : constraints.smallest;

  @override
  bool hitTestSelf(Offset position) => false;

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config
      ..isSemanticBoundary = true
      ..explicitChildNodes = true
      ..textDirection = TextDirection.ltr;
  }

  /// The nodes this layer would build now: (key, rect, configuration), in reading order.
  @visibleForTesting
  List<(Object, Rect, SemanticsConfiguration)> debugNodes() => _describe();

  List<(Object, Rect, SemanticsConfiguration)> _describe() {
    final out = <(Object, Rect, SemanticsConfiguration)>[];
    if (!hasSize || !_viewport.hasLayout || _viewport.pxPerSecond <= 0) return out;
    final ruler = _metrics.rulerHeight;
    final bounds = Offset.zero & size;
    final half = _metrics.minHitSize / 2;
    final rate = _snapshot.frameRate;

    // Playhead slider.
    final t = rate.quantize(_playhead.value);
    final x = _viewport.centerLocked ? _viewport.lanesWidth / 2 : _viewport.xOf(t);
    final px = x.clamp(half, math.max(half, size.width - half));
    final k = rate.frameIndexOf(t);
    final up = math.min(_snapshot.duration, rate.timeOfFrame(k + 1));
    final down = rate.timeOfFrame(math.max(0, k - 1));
    final value = _playheadValue(t);
    _lastPlayheadValue = value;
    final playheadConfig = SemanticsConfiguration()
      ..isSlider = true
      ..textDirection = TextDirection.ltr
      ..label = TimelineSemanticsStrings.playhead
      ..hint = TimelineSemanticsStrings.playheadHint
      ..value = value
      ..increasedValue = Timecode.format(up, rate)
      ..decreasedValue = Timecode.format(down, rate)
      ..sortKey = const OrdinalSortKey(-1);
    if (up != t) playheadConfig.onIncrease = () => _callbacks.seek(up);
    if (t > 0) playheadConfig.onDecrease = () => _callbacks.seek(down);
    out.add((const _PlayheadKey(), Rect.fromLTWH(px - half, 0, 2 * half, math.min(ruler, size.height)).intersect(bounds), playheadConfig));

    // Markers.
    final start = _viewport.timeAt(0), end = _viewport.timeAt(size.width);
    var order = 0.0;
    for (final m in _snapshot.markers) {
      if (m.time < start || m.time > end) continue;
      final mx = _viewport.xOf(m.time);
      final rect = Rect.fromLTWH(mx - half, 0, 2 * half, ruler).intersect(bounds);
      if (rect.isEmpty) continue;
      out.add((
        ('marker', m.id),
        rect,
        SemanticsConfiguration()
          ..isButton = true
          ..isSelected = _selection.marker == m.id
          ..textDirection = TextDirection.ltr
          ..sortKey = OrdinalSortKey(order++)
          ..label = TimelineSemanticsStrings.marker(m)
          ..onTap = () => _callbacks.selectMarker(m),
      ));
    }

    // Transitions and keyframes of the visible lanes.
    final g = _geo;
    final lanesHeight = math.max(0.0, size.height - ruler);
    final lanesBounds = Rect.fromLTWH(0, 0, size.width, lanesHeight);
    final (first, last) = g.visibleLanes(lanesHeight);
    for (var li = first; li < last; li++) {
      final lane = _snapshot.lanes[li];
      for (var c = lane.firstCutFrom(start); c < lane.cuts.length; c++) {
        final cut = lane.cuts[c];
        if (cut.at > end) break;
        final transition = cut.transition;
        if (transition == null && !g.showsAddButton(lane, cut)) continue;
        final rect = g.cutHitRect(li, cut).intersect(lanesBounds);
        if (rect.isEmpty) continue;
        out.add((
          ('cut', cut.ref),
          rect.shift(Offset(0, ruler)),
          SemanticsConfiguration()
            ..isButton = true
            ..isSelected = _selection.transition == cut.ref
            ..textDirection = TextDirection.ltr
            ..sortKey = OrdinalSortKey(order++)
            ..label = transition == null ? TimelineSemanticsStrings.addTransition(cut.at) : TimelineSemanticsStrings.transition(transition, cut.at)
            ..onTap = () => _callbacks.openTransition(cut.ref),
        ));
      }
      if (lane.locked) continue;
      for (var i = lane.firstItemEndingAfter(start); i < lane.items.length; i++) {
        final item = lane.items[i];
        if (item.start > end) break;
        if (!item.hasKeyframes || !(_showAllKeyframes || _selection.items.contains(item.id))) continue;
        final body = g.itemRect(li, item);
        final y = TimelineCanvasGeometry.keyframeRowY(body);
        for (var k = 0; k < item.keyframeTimes.length; k++) {
          final at = item.keyframeAt(k);
          final kx = _viewport.xOf(at);
          final rect = Rect.fromCenter(center: Offset(kx, y), width: 2 * g.handleReach, height: 2 * g.handleReach).intersect(lanesBounds);
          if (rect.isEmpty) continue;
          final ref = KeyframeRef(item.id, item.keyframeProperties[k], item.keyframeTimes[k]);
          out.add((
            ('key', ref),
            rect.shift(Offset(0, ruler)),
            SemanticsConfiguration()
              ..isButton = true
              ..isSelected = _selection.keyframe == ref
              ..textDirection = TextDirection.ltr
              ..sortKey = OrdinalSortKey(order++)
              ..label = TimelineSemanticsStrings.keyframe(ref.property, at)
              ..onTap = () => _callbacks.selectKeyframe(ref),
          ));
        }
      }
    }
    return out;
  }

  @override
  void assembleSemanticsNode(SemanticsNode node, SemanticsConfiguration config, Iterable<SemanticsNode> children) {
    final described = _describe();
    final keep = <Object>{};
    final nodes = <SemanticsNode>[];
    for (final (key, rect, cfg) in described) {
      if (!keep.add(key)) continue;
      final child = _nodes.putIfAbsent(key, () => SemanticsNode(key: ValueKey<Object>(key)));
      child
        ..rect = rect
        ..updateWith(config: cfg);
      nodes.add(child);
    }
    _nodes.removeWhere((k, _) => !keep.contains(k));
    node.updateWith(config: config, childrenInInversePaintOrder: nodes);
  }

  @override
  void clearSemantics() {
    super.clearSemantics();
    _nodes.clear();
  }

  @override
  void paint(PaintingContext context, Offset offset) {}
}

@immutable
final class _PlayheadKey {
  const _PlayheadKey();

  @override
  bool operator ==(Object other) => other is _PlayheadKey;

  @override
  int get hashCode => (_PlayheadKey).hashCode;
}
