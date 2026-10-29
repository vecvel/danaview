// OWNER: UX-13
//
// TimelineInteractionController (ux.md §8.7, §8.9, ARCH §17.4): the interaction slot of the
// timeline (UX-12's `TimelineInteractionSlot`). It takes every drag except scrubbing:
//
// | Drag      | Hit               | Command per pointer move (EditTransaction.update)       | History entry  |
// |-----------|-------------------|---------------------------------------------------------|----------------|
// | move      | item (selected)   | `MoveItems(ids, Δ, toTrack, ripple, clamp)`             | Move clip(s)   |
// | trim      | trim handle       | `TrimItem(item, edge, t, ripple, clamp)`                | Trim clip      |
// | trim      | cue trim handle   | `SetCueRange(cue, start, end, clamp)`                   | Retime caption |
// | fade      | fade handle       | `SetProperty(fadeIn/fadeOut)`                           | Fade in/out    |
// | keyframe  | diamond           | `MoveKeyframe(ref, t)`                                  | Move keyframe  |
// | marker    | marker flag       | `UpdateMarker(id, time)`                                | Move marker    |
// | marquee   | empty lane (mouse)| (selection only)                                        | none           |
//
// * Every move snaps the proposed time first (snapping.dart over core `SnapIndex`, 8 px pointer /
//   12 px touch, guide line + time pill, `selectionClick` on each new engagement, Alt disables,
//   the project's snapping mode toggles it), then runs the command through the open
//   `EditTransaction`, whose `preview` is core `dryRun`'s placements: the ghosts are drawn from
//   exactly what the drop commits. A refused update draws a red ghost; dropping it cancels the
//   transaction and re-applies the command once so the editor shows why (toast + haptic), with no
//   history entry. A drop commits exactly one history entry.
// * Ripple: items the command shifts on other positions are drawn as offset outlines (the canvas
//   keeps painting the committed project; it repaints only when `liftedItems` changes).
// * Vertical moves: a single-lane selection follows the pointer to a compatible lane (video ↔
//   overlay, otherwise the same kind); a placement on a lane the drop creates (D-11) is drawn at
//   the pointer with a "New track" pill.
// * Auto-scroll: within 48 px of an edge of the lanes area a ticker scrolls (without scrubbing) at
//   a speed proportional to the depth, up to 1.5 viewports per second, and re-runs the drag at the
//   pointer's new time; vertically only for moves.
// * Listeners of this controller (the canvas) are notified only when the lifted items change; the
//   interaction layer repaints from `layerListenable` on every pointer move.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../../app/strings/edit_strings.dart';
import '../state/editor_controller.dart';
import '../state/editor_state.dart' show EditorState, SelectMode;
import 'render_timeline_canvas.dart' show TimelineCanvasInteraction;
import 'snapping.dart';
import 'timeline_gestures.dart';
import 'timeline_hit.dart';
import 'timeline_metrics.dart';
import 'timeline_snapshot.dart';
import 'timeline_viewport.dart';

export 'snapping.dart' show SnapGuide, TimelineSnapping;

// -------------------------------------------------------------------------------------------------
// Ghosts
// -------------------------------------------------------------------------------------------------

/// Where a moved or trimmed group lands (ux.md §8.7 `DragGhost`), from the transaction's dryRun.
@immutable
final class DragGhost {
  /// Creates the ghost.
  DragGhost({
    required Set<ItemId> ids,
    required Map<ItemId, Placement> placements,
    Map<ItemId, Placement> shifted = const {},
    required this.valid,
    this.createsTrack = false,
    this.rejection,
  })  : ids = Set.unmodifiable(ids),
        placements = Map.unmodifiable(placements),
        shifted = Map.unmodifiable(shifted);

  /// The dragged items (link partners included).
  final Set<ItemId> ids;

  /// Where the dragged items land.
  final Map<ItemId, Placement> placements;

  /// Other items the drop moves (ripple), at their new places.
  final Map<ItemId, Placement> shifted;

  /// Whether the drop would be accepted.
  final bool valid;

  /// Whether the drop creates a lane (D-11).
  final bool createsTrack;

  /// Why the drop would be refused.
  final EditRejection? rejection;

  @override
  String toString() => 'DragGhost(${placements.length} placed, ${shifted.length} shifted${valid ? '' : ', invalid'})';
}

/// A trim in progress (ux.md §8.7 `TrimGhost`).
@immutable
final class TrimGhost {
  /// Creates the ghost.
  const TrimGhost({required this.item, required this.edge, required this.edgeTime, required this.delta, required this.duration});

  /// The trimmed item.
  final ItemId item;

  /// The dragged edge.
  final TrimEdge edge;

  /// Where the dragged edge is drawn.
  final TimeUs edgeTime;

  /// How far the edge moved (positive: to the right; for a head trim, content removed).
  final TimeUs delta;

  /// The item's new length.
  final TimeUs duration;

  @override
  String toString() => 'TrimGhost($item, ${edge.name}, Δ$delta, $duration)';
}

class _Signal extends ChangeNotifier {
  void fire() => notifyListeners();
}

// -------------------------------------------------------------------------------------------------
// Controller
// -------------------------------------------------------------------------------------------------

/// Drag ghosts, guides, marquee and trim pills (ux.md §8.7, §8.9). See the file header.
///
/// `interactionProvider` holds a [TimelineInteractionSlotController], the subclass that the
/// timeline view takes as its interaction slot.
class TimelineInteractionController extends ChangeNotifier implements TimelineDragDelegate, TimelineCanvasInteraction {
  /// Creates the interaction over [controller] and its [state]; [snapshot] is what the canvas shows
  /// until the layer reports it; [playhead] is a snap target; [onSnapEngage] plays the haptic.
  TimelineInteractionController({
    required EditorController Function() controller,
    required EditorState Function() state,
    required this.viewport,
    TimelineSnapshot Function()? snapshot,
    ValueListenable<TimeUs>? playhead,
    VoidCallback? onSnapEngage,
  })  : _controller = controller,
        _state = state,
        _snapshotFn = snapshot,
        _playhead = playhead,
        _onSnapEngage = onSnapEngage ?? HapticFeedback.selectionClick;

  /// Maximum auto-scroll speed in viewports per second (ux.md §8.9).
  static const double maxAutoScrollViewportsPerSecond = 1.5;

  final EditorController Function() _controller;
  final EditorState Function() _state;
  final TimelineSnapshot Function()? _snapshotFn;
  final ValueListenable<TimeUs>? _playhead;
  final VoidCallback _onSnapEngage;

  /// Zoom and scroll.
  final TimelineViewportController viewport;

  final _Signal _paint = _Signal();
  TimelineLayerContext? _layer;
  TimelineCanvasGeometry? _geometry;

  // Drag.
  TimelineDragStart? _start;
  TimelineDragUpdate? _last;
  EditTransaction? _tx;
  EditProject? _base;
  TimelineSnapping? _snap;
  Set<ItemId> _ids = const {};
  Set<ItemId> _lifted = const {};
  TimeRange _group = const TimeRange(0, 0);
  TimeUs _grab = 0;
  TimeUs _origStart = 0;
  TimeUs _origEnd = 0;
  TrackId? _sourceLane;
  TrackKind? _sourceKind;
  bool _singleLane = true;
  bool _cue = false;
  EditCommand? _lastCommand;
  EditResult? _lastResult;

  // Output.
  DragGhost? _ghost;
  TrimGhost? _trim;
  TimeUs? _ghostTime;
  String? _pill;
  Rect? _marquee;

  // Auto-scroll.
  Ticker? _ticker;
  Duration _lastTick = Duration.zero;
  Offset _scrollVelocity = Offset.zero;
  bool _disposed = false;

  // ---- Reading ----------------------------------------------------------------------------------

  /// Repaints the interaction layer (every pointer move); the canvas listens to this controller,
  /// which notifies only when [liftedItems] changes.
  Listenable get layerListenable => _paint;

  @override
  Set<ItemId> get liftedItems => _lifted;

  /// The drag in progress, or null.
  TimelineDragStart? get active => _start;

  /// Whether a drag is in progress.
  bool get isDragging => _start != null;

  /// The command of the latest update (its dryRun is what the ghost shows).
  EditCommand? get lastCommand => _lastCommand;

  /// The latest preview of the open transaction.
  EditPreview? get preview => _tx?.preview;

  /// Where a move or trim lands, or null.
  DragGhost? get ghost => _ghost;

  /// Where the dragged items land (the ghosts), keyed by item.
  Map<ItemId, Placement> get ghosts => _ghost?.placements ?? const {};

  /// Whether the latest update was refused (red ghost; a drop shows why and changes nothing).
  bool get rejected => _lastResult is EditRejected || (preview?.isRejected ?? false);

  /// The trim in progress, or null.
  TrimGhost? get trimGhost => _trim;

  /// The engaged snap target, or null.
  SnapGuide? get snapGuide => _snap?.guide;

  /// Number of snap engagements in the current drag (haptics).
  int get snapEngagements => _snap?.engagements ?? 0;

  /// The time line of a dragged keyframe, marker or fade, or null.
  TimeUs? get ghostTime => _ghostTime;

  /// The text of the drag pill ("In +00:01:05 · 00:04:12"), or null.
  String? get pill => _pill;

  /// The marquee rect (canvas-local), or null.
  Rect? get marquee => _marquee;

  /// The pointer of the drag (canvas-local), or null.
  Offset? get pointer => _last?.position ?? _start?.position;

  /// The current auto-scroll velocity (px/s; x = time, y = lanes).
  Offset get autoScrollVelocity => _scrollVelocity;

  TimelineSnapshot get _snapshot => _layer?.snapshot ?? _snapshotFn?.call() ?? TimelineSnapshot.empty;

  TimelineMetrics get _metrics => _layer?.metrics ?? const TimelineMetrics();

  TimelineCanvasGeometry get _geo {
    final g = _geometry;
    final s = _snapshot, m = _metrics;
    if (g != null && identical(g.snapshot, s) && g.metrics == m && identical(g.viewport, viewport)) return g;
    return _geometry = TimelineCanvasGeometry(snapshot: s, metrics: m, viewport: viewport);
  }

  FrameRate get _rate => _base?.settings.frameRate ?? _snapshot.frameRate;

  // ---- TimelineDragDelegate ---------------------------------------------------------------------

  @override
  bool canDrag(TimelineDragKind kind) => kind != TimelineDragKind.scrub;

  @override
  bool beginDrag(TimelineDragStart start) {
    if (_start != null) endDrag(cancelled: true);
    if (start.kind == TimelineDragKind.marquee) {
      _start = start;
      _marquee = Rect.fromPoints(start.position, start.position);
      _paint.fire();
      return true;
    }
    final c = _controller();
    final project = _state().project;
    if (!c.canEdit || project == null) return false;
    final snapshot = _snapshot;
    final playhead = _playhead?.value;
    final threshold = TimelineSnapping.thresholdFor(touch: start.deviceKind == PointerDeviceKind.touch || _metrics.touch);
    TimelineSnapping snapping({Set<ItemId> dragged = const {}, bool markers = true}) => TimelineSnapping.forDrag(project,
        dragged: dragged, playhead: playhead, markers: markers, thresholdPx: threshold, onEngage: _onSnapEngage);

    final String label;
    switch ((start.kind, start.hit)) {
      case (TimelineDragKind.move, HitItem(:final item, :final lane, :final locked)):
        if (locked) return false;
        final selected = _state().selection.items;
        final ids = selected.contains(item)
            ? {for (final id in selected) if (!(snapshot.laneOf(id)?.locked ?? true)) id}
            : {item};
        if (!selected.contains(item)) c.select(item);
        if (ids.isEmpty || snapshot.item(item) == null) return false;
        final all = SelectionRules.expand(project, ids);
        TimeUs? s, e;
        for (final id in all) {
          final i = project.index.item(id);
          if (i == null) continue;
          if (s == null || i.start < s) s = i.start;
          if (e == null || i.end > e) e = i.end;
        }
        if (s == null || e == null) return false;
        _group = TimeRange(s, e);
        _ids = ids;
        _lifted = all;
        _sourceLane = lane;
        _sourceKind = snapshot.lane(lane)?.kind;
        _singleLane = SelectionRules.isSingleLane(project, ids);
        _snap = snapping(dragged: ids);
        label = ids.length == 1 ? EditStrings.moveClip : EditStrings.moveClips;
      case (TimelineDragKind.trim, HitTrimHandle(:final item, :final edge)):
        final model = snapshot.item(item);
        if (model == null || (snapshot.laneOf(item)?.locked ?? true)) return false;
        _origStart = model.start;
        _origEnd = model.end;
        _grab = (edge == TrimEdge.start ? model.start : model.end) - start.time;
        _cue = model.source is SubtitleCue;
        _ids = {item};
        _lifted = SelectionRules.expand(project, {item});
        _snap = snapping(dragged: {item});
        label = _cue ? EditStrings.retimeCaption : EditStrings.trimClip;
      case (TimelineDragKind.fade, HitFadeHandle(:final item, :final edge)):
        final model = snapshot.item(item);
        if (model == null || (snapshot.laneOf(item)?.locked ?? true)) return false;
        _origStart = model.start;
        _origEnd = model.end;
        final at = edge == FadeEdge.fadeIn ? model.start + model.fadeIn : model.end - model.fadeOut;
        _grab = at - start.time;
        _ghostTime = at;
        _ids = {item};
        _snap = snapping(dragged: {item});
        label = edge == FadeEdge.fadeIn ? EditStrings.fadeIn : EditStrings.fadeOut;
      case (TimelineDragKind.keyframe, HitKeyframe(:final ref)):
        final model = snapshot.item(ref.item);
        if (model == null || (snapshot.laneOf(ref.item)?.locked ?? true)) return false;
        _origStart = model.start;
        _origEnd = model.end;
        _grab = model.start + ref.t - start.time;
        _ghostTime = model.start + ref.t;
        _snap = snapping();
        label = EditStrings.moveKeyframe;
      case (TimelineDragKind.marker, HitMarker(:final id)):
        final marker = snapshot.markers.where((m) => m.id == id).firstOrNull;
        if (marker == null) return false;
        _grab = marker.time - start.time;
        _ghostTime = marker.time;
        _snap = snapping(markers: false);
        label = EditStrings.moveMarker;
      default:
        return false;
    }
    _base = project;
    _start = start;
    _tx = c.beginTransaction(label);
    if (_lifted.isNotEmpty) _notify();
    _paint.fire();
    return true;
  }

  @override
  void updateDrag(TimelineDragUpdate update) {
    final start = _start;
    if (start == null) return;
    _last = update;
    _apply(update.position, update.time, snapDisabled: update.snapDisabled);
    _updateAutoScroll(update.position);
  }

  void _apply(Offset position, TimeUs time, {required bool snapDisabled}) {
    final start = _start;
    if (start == null) return;
    final rate = _rate;
    final pps = viewport.pxPerSecond;
    final snapOn = _state().modes.snapping && !snapDisabled;
    final snap = _snap;
    TimeUs snapped(TimeUs t) => snap == null ? t : snap.snapTime(t, pxPerSecond: pps, enabled: snapOn);
    final ripple = _state().modes.ripple;
    switch ((start.kind, start.hit)) {
      case (TimelineDragKind.move, HitItem()):
        final delta = time - start.time;
        final shift = snap?.snapRange(_group.shift(delta), pxPerSecond: pps, enabled: snapOn) ?? 0;
        final target = math.max(0, rate.quantizeNearest(_group.start + delta + shift)).toInt();
        final toTrack = _targetLane(position.dy);
        _run(MoveItems(_ids, target - _group.start, toTrack: toTrack, ripple: ripple, clamp: true));
        _ghost = _ghostOf(_lifted);
        final landed = _ghost?.placements.values.map((p) => p.range.start).fold<TimeUs?>(null, (a, b) => a == null || b < a ? b : a);
        _pill = EditStrings.movePill(start: landed ?? target, delta: (landed ?? target) - _group.start, rate: rate);
      case (TimelineDragKind.trim, HitTrimHandle(:final item, :final edge)):
        final t = math.max(0, rate.quantizeNearest(snapped(time + _grab))).toInt();
        if (_cue) {
          _run(SetCueRange(item, edge == TrimEdge.start ? t : _origStart, edge == TrimEdge.end ? t : _origEnd, clamp: true));
        } else {
          _run(TrimItem(item, edge, t, ripple: ripple, clamp: true));
        }
        _ghost = _ghostOf(_lifted);
        final p = _ghost?.placements[item];
        final oldDuration = _origEnd - _origStart;
        if (p != null) {
          final head = edge == TrimEdge.start;
          final delta = head ? oldDuration - p.range.duration : p.range.duration - oldDuration;
          _trim = TrimGhost(item: item, edge: edge, edgeTime: head ? p.range.start : p.range.end, delta: delta, duration: p.range.duration);
          _pill = EditStrings.trimPill(head: head, delta: delta, duration: p.range.duration, rate: rate);
        }
      case (TimelineDragKind.fade, HitFadeHandle(:final item, :final edge)):
        final at = rate.quantizeNearest(snapped(time + _grab));
        final half = (_origEnd - _origStart) ~/ 2;
        final fadeIn = edge == FadeEdge.fadeIn;
        final len = (fadeIn ? at - _origStart : _origEnd - at).clamp(0, math.max(0, half)).toInt();
        _ghostTime = fadeIn ? _origStart + len : _origEnd - len;
        _run(SetProperty<int>([item], fadeIn ? PropertyKeys.fadeIn : PropertyKeys.fadeOut, len));
        _pill = EditStrings.fadePill(fadeIn: fadeIn, length: len, rate: rate);
      case (TimelineDragKind.keyframe, HitKeyframe(:final ref)):
        final last = math.max(_origStart, _origEnd - rate.frameUs);
        final abs = rate.quantizeNearest(snapped(time + _grab)).clamp(_origStart, last).toInt();
        _ghostTime = abs;
        _run(MoveKeyframe(ref, abs - _origStart));
        _pill = EditStrings.timePill(abs, rate);
      case (TimelineDragKind.marker, HitMarker(:final id)):
        final t = math.max(0, rate.quantizeNearest(snapped(time + _grab))).toInt();
        _ghostTime = t;
        _run(UpdateMarker(id, time: t));
        _pill = EditStrings.timePill(t, rate);
      case (TimelineDragKind.marquee, _):
        _marquee = Rect.fromPoints(start.position, position);
      default:
    }
    _paint.fire();
  }

  /// The lane a single-lane move goes to at lanes-area [y], or null to stay (or follow D-11).
  TrackId? _targetLane(double y) {
    if (!_singleLane) return null;
    final g = _geo;
    final index = g.laneAt(y);
    final lanes = _snapshot.lanes;
    if (index == null || index < 0 || index >= lanes.length) return null;
    final lane = lanes[index];
    final from = _sourceKind;
    if (lane.id == _sourceLane || lane.locked || from == null || !LanePlacement.compatibleKinds(from, lane.kind)) return null;
    return lane.id;
  }

  void _run(EditCommand command) {
    final tx = _tx;
    if (tx == null) return;
    _lastCommand = command;
    _lastResult = tx.update(command);
  }

  DragGhost? _ghostOf(Set<ItemId> dragged) {
    final p = preview;
    final base = _base;
    if (p == null || base == null) return null;
    final placed = <ItemId, Placement>{};
    final shifted = <ItemId, Placement>{};
    final index = base.index;
    p.placements.forEach((id, placement) {
      if (dragged.contains(id)) {
        placed[id] = placement;
        return;
      }
      final loc = index.locate(id);
      if (loc == null || loc.track.id != placement.track || loc.item.range != placement.range) shifted[id] = placement;
    });
    return DragGhost(
      ids: dragged,
      placements: placed,
      shifted: shifted,
      valid: !rejected,
      createsTrack: p.createsTracks.isNotEmpty,
      rejection: p.rejection ?? switch (_lastResult) { EditRejected(:final reason) => reason, _ => null },
    );
  }

  @override
  void endDrag({bool cancelled = false}) {
    final start = _start;
    if (start == null) return;
    _stopAutoScroll();
    final tx = _tx;
    if (start.kind == TimelineDragKind.marquee) {
      if (!cancelled) _selectMarquee(start.additive);
    } else if (tx != null) {
      final command = _lastCommand;
      if (cancelled || command == null) {
        tx.cancel();
      } else if (rejected) {
        tx.cancel();
        // Runs the refused command once on the unchanged project: the editor shows why (toast,
        // haptic, announcement) and records nothing.
        _controller().apply(command);
      } else {
        final result = tx.commit();
        final hit = start.hit;
        if (result is EditApplied && hit is HitKeyframe && _ghostTime != null) {
          _controller().selectKeyframe(KeyframeRef(hit.ref.item, hit.ref.property, _ghostTime! - _origStart));
        }
      }
    }
    _reset();
  }

  void _selectMarquee(bool additive) {
    final rect = _marquee;
    if (rect == null) return;
    final g = _geo;
    final snapshot = _snapshot;
    final ids = <ItemId>[];
    final from = viewport.timeAt(rect.left), to = viewport.timeAt(rect.right);
    for (var li = 0; li < snapshot.lanes.length; li++) {
      final lane = snapshot.lanes[li];
      if (lane.locked) continue;
      final top = g.laneTop(li);
      if (top > rect.bottom || top + g.stack.heights[li] < rect.top) continue;
      for (var i = lane.firstItemEndingAfter(from); i < lane.items.length; i++) {
        final item = lane.items[i];
        if (item.start >= to) break;
        if (g.itemRect(li, item).overlaps(rect)) ids.add(item.id);
      }
    }
    final c = _controller();
    if (!additive) c.clearSelection();
    for (final id in ids) {
      c.select(id, mode: SelectMode.extend);
    }
  }

  void _reset() {
    final hadLifted = _lifted.isNotEmpty;
    _start = null;
    _last = null;
    _tx = null;
    _base = null;
    _snap?.release();
    _snap = null;
    _ids = const {};
    _lifted = const {};
    _lastCommand = null;
    _lastResult = null;
    _ghost = null;
    _trim = null;
    _ghostTime = null;
    _pill = null;
    _marquee = null;
    _sourceLane = null;
    _sourceKind = null;
    _cue = false;
    if (hadLifted) _notify();
    if (!_disposed) _paint.fire();
  }

  // ---- Auto-scroll ------------------------------------------------------------------------------

  void _updateAutoScroll(Offset position) {
    final start = _start;
    if (start == null || start.kind == TimelineDragKind.marquee || !viewport.hasLayout) {
      _stopAutoScroll();
      return;
    }
    final w = viewport.lanesWidth, h = viewport.lanesHeight;
    double speed(double distance, double extent) {
      final edge = math.min(TimelineMetrics.autoScrollEdge, extent / 4);
      if (edge <= 0 || distance >= edge) return 0;
      final depth = ((edge - distance) / edge).clamp(0.0, 1.0);
      return depth * maxAutoScrollViewportsPerSecond * extent;
    }

    var vx = 0.0, vy = 0.0;
    final left = speed(position.dx, w), right = speed(w - position.dx, w);
    if (left > 0) {
      vx = -left;
    } else if (right > 0) {
      vx = right;
    }
    if (start.kind == TimelineDragKind.move) {
      final top = speed(position.dy, h), bottom = speed(h - position.dy, h);
      if (top > 0) {
        vy = -top;
      } else if (bottom > 0) {
        vy = bottom;
      }
    }
    _scrollVelocity = Offset(vx, vy);
    if (_scrollVelocity == Offset.zero) {
      _stopAutoScroll();
    } else {
      final ticker = _ticker ??= Ticker(_onTick, debugLabel: 'timeline auto-scroll');
      if (!ticker.isActive) {
        _lastTick = Duration.zero;
        ticker.start();
      }
    }
  }

  void _onTick(Duration elapsed) {
    final last = _last;
    final dt = (elapsed - _lastTick).inMicroseconds / microsPerSecond;
    _lastTick = elapsed;
    if (last == null || _start == null || dt <= 0) return;
    final step = math.min(dt, 0.1);
    final v = _scrollVelocity;
    final pps = viewport.pxPerSecond;
    if (pps <= 0) return;
    final beforeX = viewport.scrollTimeSec, beforeY = viewport.scrollY;
    viewport.jumpTo(
      scrollTimeSec: v.dx == 0 ? null : beforeX + v.dx * step / pps,
      scrollY: v.dy == 0 ? null : beforeY + v.dy * step,
    );
    if (viewport.scrollTimeSec == beforeX && viewport.scrollY == beforeY) return;
    _apply(last.position, viewport.timeAt(last.position.dx), snapDisabled: last.snapDisabled);
  }

  void _stopAutoScroll() {
    _scrollVelocity = Offset.zero;
    final t = _ticker;
    if (t != null && t.isActive) t.stop();
  }

  // ---- Layer ------------------------------------------------------------------------------------

  /// The layer that draws ghosts, guides, the marquee and pills (see `TimelineInteractionSlot`).
  Widget buildLayer(BuildContext context, TimelineLayerContext layer) {
    _layer = layer;
    return TimelineInteractionLayer(interaction: this, layer: layer);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _tx?.cancel();
    _ticker?.dispose();
    _ticker = null;
    _disposed = true;
    _paint.dispose();
    super.dispose();
  }
}

/// The [TimelineInteractionController] as the timeline's interaction slot (UX-12's
/// `TimelineInteractionSlot`): what `interactionProvider` holds and what tests pass to
/// `TimelineView(interaction:)`.
class TimelineInteractionSlotController extends TimelineInteractionController implements TimelineInteractionSlot {
  /// Creates the slot; see [TimelineInteractionController.new].
  TimelineInteractionSlotController({
    required super.controller,
    required super.state,
    required super.viewport,
    super.snapshot,
    super.playhead,
    super.onSnapEngage,
  });
}

/// Builds the value of `interactionProvider` for [id]: the controller over the project's editor
/// controller, viewport and playhead, disposed with the provider (the timeline unmounted).
TimelineInteractionController createInteractionController(Ref<Object?> ref, ProjectId id) {
  final controller = ref.watch(editorControllerProvider(id).notifier);
  final viewport = ref.watch(viewportProvider(id));
  final playhead = ref.watch(playheadProvider(id));
  final interaction = TimelineInteractionSlotController(
    controller: () => controller,
    state: () => ref.read(editorControllerProvider(id)),
    viewport: viewport,
    snapshot: () => ref.read(timelineSnapshotProvider(id)),
    playhead: playhead,
  );
  ref.onDispose(interaction.dispose);
  return interaction;
}

// -------------------------------------------------------------------------------------------------
// Layer
// -------------------------------------------------------------------------------------------------

/// Draws the ghosts, ripple offsets, snap guide, marquee and pills of a
/// [TimelineInteractionController] over the ruler and lanes (top = ruler top).
class TimelineInteractionLayer extends StatelessWidget {
  /// Creates the layer.
  const TimelineInteractionLayer({super.key, required this.interaction, required this.layer});

  /// Widest drag pill.
  static const double pillMaxWidth = 240;

  /// What to draw.
  final TimelineInteractionController interaction;

  /// Snapshot, viewport, metrics and style.
  final TimelineLayerContext layer;

  @override
  Widget build(BuildContext context) {
    final repaint = Listenable.merge([interaction.layerListenable, layer.viewport]);
    return IgnorePointer(
      child: RepaintBoundary(
        child: LayoutBuilder(
          builder: (context, constraints) => Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned.fill(child: CustomPaint(painter: _InteractionPainter(interaction, layer, repaint))),
              Positioned.fill(
                child: ListenableBuilder(
                  listenable: repaint,
                  builder: (context, _) => Stack(
                    clipBehavior: Clip.hardEdge,
                    children: _pills(constraints.biggest),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _pills(Size size) {
    if (!size.isFinite || interaction.active == null) return const [];
    final ruler = layer.metrics.rulerHeight;
    final viewport = layer.viewport;
    final rate = layer.snapshot.frameRate;
    final out = <Widget>[];
    final guide = interaction.snapGuide;
    if (guide != null) {
      out.add(_pill(size, viewport.xOf(guide.time), 2, EditStrings.timePill(guide.time, rate),
          key: const ValueKey('snap-pill')));
    }
    final text = interaction.pill;
    final last = interaction.active;
    if (text != null && last != null) {
      final anchor = interaction.trimGhost?.edgeTime ?? interaction.ghostTime;
      final x = anchor != null ? viewport.xOf(anchor) : _ghostLeft() ?? last.position.dx;
      final top = guide != null ? ruler + 4 : 2.0;
      out.add(_pill(size, x, top, text, key: const ValueKey('drag-pill')));
    }
    final ghost = interaction.ghost;
    if (ghost != null && ghost.placements.values.any((p) => p.onNewTrack)) {
      final first = ghost.placements.values.firstWhere((p) => p.onNewTrack);
      out.add(_pill(size, viewport.xOf(first.range.start), _newLaneTop() + ruler - 28, EditStrings.newTrack,
          key: const ValueKey('new-track-pill')));
    }
    return out;
  }

  double? _ghostLeft() {
    final ghost = interaction.ghost;
    if (ghost == null || ghost.placements.isEmpty) return null;
    var start = ghost.placements.values.first.range.start;
    for (final p in ghost.placements.values) {
      if (p.range.start < start) start = p.range.start;
    }
    return layer.viewport.xOf(start);
  }

  double _newLaneTop() => math.max(0, interaction.pointer?.dy ?? 0);

  Widget _pill(Size size, double x, double top, String text, {Key? key}) {
    final width = math.min(pillMaxWidth, size.width);
    final left = (x - width / 2).clamp(0.0, math.max(0.0, size.width - width)).toDouble();
    final y = top.clamp(0.0, math.max(0.0, size.height - 24)).toDouble();
    return Positioned(
      key: key,
      left: left,
      top: y,
      width: width,
      child: Align(
        alignment: Alignment.topCenter,
        child: DanaviewSurface(
          color: DanaviewColors.surfaceElevatedHigher,
          borderRadius: DanaviewRadius.controlAll,
          shadow: DanaviewShadow.soft,
          padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.sm, vertical: 2),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: DanaviewTextStyles.caption.copyWith(fontFamily: DanaviewFonts.family, color: DanaviewColors.textPrimary),
          ),
        ),
      ),
    );
  }
}

class _InteractionPainter extends CustomPainter {
  _InteractionPainter(this.interaction, this.layer, Listenable repaint) : super(repaint: repaint);

  static const Color _invalid = DanaviewColors.error;

  final TimelineInteractionController interaction;
  final TimelineLayerContext layer;

  @override
  void paint(Canvas canvas, Size size) {
    final start = interaction.active;
    if (start == null) return;
    final ruler = layer.metrics.rulerHeight;
    final style = layer.style;
    final viewport = layer.viewport;
    canvas.save();
    canvas.clipRect(Offset.zero & size);

    final marquee = interaction.marquee;
    if (marquee != null) {
      final r = marquee.shift(Offset(0, ruler));
      canvas.drawRect(r, Paint()..color = style.selection.withValues(alpha: 0.12));
      canvas.drawRect(r, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = style.selection.withValues(alpha: 0.8));
    }

    final ghost = interaction.ghost;
    if (ghost != null) {
      final g = TimelineCanvasGeometry(snapshot: layer.snapshot, metrics: layer.metrics, viewport: viewport);
      // Ripple offsets: outlines where the other items go.
      ghost.shifted.forEach((id, p) {
        final rect = _rect(g, p, interaction.pointer?.dy ?? start.position.dy);
        if (rect == null) return;
        canvas.drawRRect(rect, Paint()..color = style.selection.withValues(alpha: 0.10));
        canvas.drawRRect(rect, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = style.selection.withValues(alpha: 0.55));
      });
      final color = ghost.valid ? style.selection : _invalid;
      ghost.placements.forEach((id, p) {
        final rect = _rect(g, p, interaction.pointer?.dy ?? start.position.dy);
        if (rect == null) return;
        canvas.drawRRect(rect, Paint()..color = color.withValues(alpha: 0.28));
        canvas.drawRRect(rect, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = p.onNewTrack ? 1.5 : 2
          ..color = color);
      });
    }

    final ghostTime = interaction.ghostTime;
    if (ghostTime != null) {
      final x = viewport.xOf(ghostTime);
      final top = start.kind == TimelineDragKind.marker ? 0.0 : ruler;
      canvas.drawLine(Offset(x, top), Offset(x, size.height), Paint()
        ..strokeWidth = 1.5
        ..color = style.selection.withValues(alpha: 0.8));
    }

    final guide = interaction.snapGuide;
    if (guide != null) {
      final x = viewport.xOf(guide.time);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), Paint()
        ..strokeWidth = 1.5
        ..color = style.snapGuide);
    }
    canvas.restore();
  }

  RRect? _rect(TimelineCanvasGeometry g, Placement p, double pointerY) {
    final ruler = layer.metrics.rulerHeight;
    final li = layer.snapshot.laneIndexOf(p.track);
    final double top, height;
    if (li != null) {
      top = g.laneTop(li) + TimelineMetrics.clipInset;
      height = g.stack.heights[li] - 2 * TimelineMetrics.clipInset;
    } else {
      // A lane the drop creates: drawn where the pointer is.
      final kind = p.newTrack?.kind ?? TrackKind.video;
      height = layer.metrics.laneHeightOf(kind) - 2 * TimelineMetrics.clipInset;
      top = pointerY - height / 2;
    }
    final left = layer.viewport.xOf(p.range.start);
    final right = layer.viewport.xOf(p.range.end);
    return RRect.fromRectAndRadius(
      Rect.fromLTWH(left, top + ruler, math.max(1, right - left), height),
      const Radius.circular(TimelineMetrics.clipRadius),
    );
  }

  @override
  bool shouldRepaint(_InteractionPainter oldDelegate) => !identical(oldDelegate.interaction, interaction) || oldDelegate.layer != layer;
}
