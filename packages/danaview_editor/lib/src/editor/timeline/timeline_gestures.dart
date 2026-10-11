// OWNER: UX-12
//
// TimelineGestureArbiter (ux.md §8.8, ARCH §17.4): routes timeline input by what is under the
// pointer at pointer-down (`RenderTimelineCanvas.hitTestTimeline`, one call for ruler and lanes).
//
// | Recognizer        | Allowed when the hit is                             | Claims                     |
// |-------------------|-----------------------------------------------------|----------------------------|
// | handle drag       | trim / fade handle, keyframe, marker, playhead knob | at pointer-down (eager)    |
// |                   | ruler in free mode (scrub)                          |                            |
// | item drag         | selected item on an unlocked lane; mouse or stylus  | after slop                 |
// | marquee           | empty lane / gap / below the lanes; mouse only      | after slop                 |
// | lift (long press) | item, empty lane, gap; touch, 350 ms                | on timeout                 |
// | tap               | anything but the header column                      | on up (secondary: menu)    |
// | pan / zoom        | anything not claimed above (headers included)       | after slop                 |
//
// * Eager handle drags win the arena at pointer-down, so a drag that starts on a handle never
//   scrolls. The drag itself begins after a small slop (scrubs begin at once); a release without
//   movement is a tap, and holding still for 350 ms on touch opens the context menu.
// * Pan / zoom: one pointer pans along the dominant axis decided at the first movement (horizontal
//   = time, which scrubs in centre-locked mode; vertical = lanes); two pointers zoom horizontally
//   anchored at the focal point (`ScaleUpdateDetails.horizontalScale`) and follow the focal point;
//   trackpad pan/zoom arrives through the same recognizer. Ending flings along the locked axis.
//   Touch scrolling over clips is this recognizer too: only selected handles are eager on touch.
// * Long press on an item lifts it (haptic, ghost): moving drags it, releasing without moving
//   opens the context menu. On an empty lane it opens the "Paste / Add media / Add text here" menu.
// * Wheel (`handlePointerSignal`): wheel scrolls lanes vertically, Shift+wheel or a horizontal
//   wheel scrolls time, Ctrl/⌘+wheel zooms anchored at the cursor; `PointerScaleEvent`s zoom.
//
// The view (timeline_view.dart) implements `TimelineGestureHost`. Drags of clips, handles,
// keyframes, markers and the marquee go to the interaction slot: UX-13's controller implements
// `TimelineInteractionSlot`; until then (and for kinds it declines) `TimelineBasicInteraction` below
// moves and trims through `EditTransaction`s (ghosts = the transaction's dryRun placements, one
// history entry on drop), moves keyframes and markers, and draws the marquee.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart' show HardwareKeyboard;
import 'package:flutter/widgets.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';

import '../state/editor_controller.dart';
import '../state/editor_state.dart' show EditorState, SelectMode;
import 'render_timeline_canvas.dart' show TimelineCanvasInteraction;
import 'timeline_hit.dart';
import 'timeline_metrics.dart';
import 'timeline_snapshot.dart';
import 'timeline_style.dart';
import 'timeline_viewport.dart';

// -------------------------------------------------------------------------------------------------
// Drag contract (UX-13 implements TimelineInteractionSlot)
// -------------------------------------------------------------------------------------------------

/// What a timeline drag edits.
enum TimelineDragKind {
  /// Move clips (pointer drag of selected items, or a long-press lift on touch).
  move,

  /// Trim an edge (`HitTrimHandle`).
  trim,

  /// Drag an audio fade handle (`HitFadeHandle`).
  fade,

  /// Move a keyframe (`HitKeyframe`).
  keyframe,

  /// Move a marker (`HitMarker`).
  marker,

  /// Scrub the playhead (knob, or the ruler in free mode). Handled by the view.
  scrub,

  /// Rubber-band selection (mouse on an empty lane).
  marquee,
}

/// The start of a drag. Positions are canvas-local (timeline_hit.dart): x is lanes-area x, y = 0 is
/// the top of the lanes, the ruler is y < 0.
@immutable
final class TimelineDragStart {
  /// Creates the start.
  const TimelineDragStart({
    required this.kind,
    required this.hit,
    required this.position,
    required this.time,
    required this.deviceKind,
    this.lifted = false,
    this.additive = false,
  });

  /// What is dragged.
  final TimelineDragKind kind;

  /// The hit at pointer-down.
  final TimelineHit hit;

  /// Where the drag started (canvas-local).
  final Offset position;

  /// Time under [position] (raw µs; callers quantize).
  final TimeUs time;

  /// The pointer.
  final PointerDeviceKind deviceKind;

  /// The clip was lifted by a long press (touch).
  final bool lifted;

  /// Shift was held (the marquee adds to the selection).
  final bool additive;

  @override
  String toString() => 'TimelineDragStart(${kind.name}, $hit${lifted ? ', lifted' : ''})';
}

/// One step of a drag.
@immutable
final class TimelineDragUpdate {
  /// Creates the update.
  const TimelineDragUpdate({required this.position, required this.time, required this.offset, this.snapDisabled = false});

  /// Pointer position (canvas-local).
  final Offset position;

  /// Time under [position] (raw µs).
  final TimeUs time;

  /// Total movement since the start, in px.
  final Offset offset;

  /// Alt/Option is held: snapping is off for this step.
  final bool snapDisabled;

  @override
  String toString() => 'TimelineDragUpdate($position)';
}

/// Receives timeline drags.
abstract interface class TimelineDragDelegate {
  /// Whether drags of [kind] are handled here.
  bool canDrag(TimelineDragKind kind);

  /// Starts a drag; false refuses it (the rest of the gesture is ignored).
  bool beginDrag(TimelineDragStart start);

  /// Moves the drag.
  void updateDrag(TimelineDragUpdate update);

  /// Ends the drag: commits, or restores everything when [cancelled].
  void endDrag({bool cancelled = false});
}

/// Inputs of an interaction layer.
@immutable
final class TimelineLayerContext {
  /// Creates the context.
  const TimelineLayerContext({required this.snapshot, required this.viewport, required this.metrics, required this.style});

  /// What the canvas shows.
  final TimelineSnapshot snapshot;

  /// Zoom and scroll.
  final TimelineViewportController viewport;

  /// Sizes.
  final TimelineMetrics metrics;

  /// Colours.
  final TimelineStyle style;
}

/// The interaction layer slot of the timeline (ARCH §17.4): UX-13's `TimelineInteractionController`
/// implements it to take over drags (snapping, auto-scroll, ripple ghosts) and to draw its layer.
/// The layer is placed over the ruler and the lanes (top = ruler top, x origin = the canvas').
abstract interface class TimelineInteractionSlot implements TimelineDragDelegate, TimelineCanvasInteraction {
  /// The layer that draws ghosts, guides, the marquee and trim pills.
  Widget buildLayer(BuildContext context, TimelineLayerContext layer);
}

// -------------------------------------------------------------------------------------------------
// Host
// -------------------------------------------------------------------------------------------------

/// What a tap carried.
@immutable
final class TimelineTapDetails {
  /// Creates the details.
  const TimelineTapDetails({required this.globalPosition, required this.deviceKind, this.toggle = false});

  /// Where (global).
  final Offset globalPosition;

  /// The pointer.
  final PointerDeviceKind deviceKind;

  /// Shift, ⌘ or Ctrl was held (toggle the item in the selection).
  final bool toggle;
}

/// What the arbiter needs from the timeline view.
abstract interface class TimelineGestureHost {
  /// Zoom and scroll.
  TimelineViewportController get viewport;

  /// The hit at [global], or null outside the ruler and lanes (the header column).
  TimelineHit? hitAt(Offset global);

  /// [global] in canvas-local coordinates.
  Offset toCanvas(Offset global);

  /// A tap (primary button or touch) on [hit].
  void onTimelineTap(TimelineHit hit, TimelineTapDetails details);

  /// A secondary click, a long press without movement, or a hold on a handle.
  void onTimelineContextMenu(TimelineHit hit, Offset globalPosition);

  /// Starts a drag; false refuses it.
  bool onTimelineDragStart(TimelineDragStart start);

  /// Moves the drag.
  void onTimelineDragUpdate(TimelineDragUpdate update);

  /// Ends (or cancels) the drag.
  void onTimelineDragEnd({required bool cancelled});
}

// -------------------------------------------------------------------------------------------------
// Arbiter
// -------------------------------------------------------------------------------------------------

/// Routes pointer input by hit type (ux.md §8.8).
class TimelineGestureArbiter {
  /// Creates the arbiter for [host].
  TimelineGestureArbiter(this.host, {this.longPressDuration = const Duration(milliseconds: 350)});

  /// The view.
  final TimelineGestureHost host;

  /// Long press (lift) and handle hold timeout.
  final Duration longPressDuration;

  /// Slop of a handle drag before it starts (px).
  static const double handleSlopTouch = 4;

  /// Slop of a handle drag with a pointer (px).
  static const double handleSlopPointer = 2;

  /// The touch slop the pan/zoom recognizer uses (pan slop = 2×), like scrollables' drag slop.
  static const double panTouchSlop = 9;

  /// Wheel delta that zooms by e (Ctrl/⌘+wheel).
  static const double wheelZoomPixels = 400;

  PointerDownEvent? _down;
  TimelineHit? _downHit;

  // The active drag (any recognizer).
  bool _dragging = false;
  Offset _dragStartLocal = Offset.zero;

  // Pan/zoom state.
  bool _zooming = false;
  Axis? _axis;
  bool _freePan = false;
  bool _trackpad = false;
  double _lastHorizontalScale = 1;
  double _lastScale = 1;
  bool _inPan = false;

  /// Whether a drag (move, trim, scrub, marquee…) is in progress.
  bool get isDragging => _dragging;

  /// Whether a pan or pinch is in progress.
  bool get isPanning => _inPan;

  /// The hit for the pointer of [event] (computed once per pointer-down and shared by every
  /// recognizer).
  TimelineHit? hitFor(PointerDownEvent event) {
    if (!identical(event, _down)) {
      _down = event;
      _downHit = host.hitAt(event.position);
    }
    return _downHit;
  }

  static bool _primary(PointerEvent e) => e.kind == PointerDeviceKind.touch || e.buttons == kPrimaryButton || e.buttons == 0;

  /// The drag kind an eager handle drag starts for [hit], or null.
  TimelineDragKind? handleKindOf(TimelineHit? hit) => switch (hit) {
        HitTrimHandle() => TimelineDragKind.trim,
        HitFadeHandle() => TimelineDragKind.fade,
        HitKeyframe() => TimelineDragKind.keyframe,
        HitMarker() => TimelineDragKind.marker,
        HitPlayheadKnob() => TimelineDragKind.scrub,
        HitRuler() when !host.viewport.centerLocked => TimelineDragKind.scrub,
        _ => null,
      };

  bool _allowsHandle(PointerDownEvent e) => _primary(e) && handleKindOf(hitFor(e)) != null;

  bool _allowsItemDrag(PointerDownEvent e) {
    if (e.kind == PointerDeviceKind.touch || !_primary(e)) return false;
    final hit = hitFor(e);
    return hit is HitItem && hit.selected && !hit.locked;
  }

  bool _allowsMarquee(PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.mouse || e.buttons != kPrimaryButton) return false;
    final hit = hitFor(e);
    if (hit is HitGap) return true;
    return hit is HitEmpty && host.toCanvas(e.position).dy >= 0;
  }

  bool _allowsLift(PointerDownEvent e) {
    final hit = hitFor(e);
    return hit is HitItem || hit is HitGap || (hit is HitEmpty && hit.lane != null);
  }

  bool _allowsTap(PointerDownEvent e) => hitFor(e) != null;

  bool _allowsPan(PointerDownEvent e) {
    if (e.kind == PointerDeviceKind.mouse && !_primary(e)) return false;
    final hit = hitFor(e);
    if (_allowsHandle(e) || _allowsItemDrag(e) || _allowsMarquee(e)) return false;
    // A mouse doesn't pan by dragging items; it drags selected ones, else nothing happens.
    if (e.kind == PointerDeviceKind.mouse && hit is HitItem) return false;
    return true;
  }

  /// The recognizers for a `RawGestureDetector` over the headers, ruler and lanes.
  Map<Type, GestureRecognizerFactory> get gestures => <Type, GestureRecognizerFactory>{
        TimelineHandleDragRecognizer: GestureRecognizerFactoryWithHandlers<TimelineHandleDragRecognizer>(
          () => TimelineHandleDragRecognizer(debugOwner: this, allow: _allowsHandle, holdDuration: longPressDuration),
          (r) => r
            ..onDown = _onHandleDown
            ..onStart = _onHandleStart
            ..onMove = _onHandleMove
            ..onUp = _onHandleUp
            ..onHold = _onHandleHold
            ..onCancel = _onHandleCancel,
        ),
        _ItemDragRecognizer: GestureRecognizerFactoryWithHandlers<_ItemDragRecognizer>(
          () => _ItemDragRecognizer(this),
          (r) => r
            ..dragStartBehavior = DragStartBehavior.down
            ..onStart = _onItemDragStart
            ..onUpdate = _onPointerDragUpdate
            ..onEnd = _onPointerDragEnd
            ..onCancel = _onPointerDragCancel,
        ),
        _MarqueeRecognizer: GestureRecognizerFactoryWithHandlers<_MarqueeRecognizer>(
          () => _MarqueeRecognizer(this),
          (r) => r
            ..dragStartBehavior = DragStartBehavior.down
            ..onStart = _onMarqueeStart
            ..onUpdate = _onPointerDragUpdate
            ..onEnd = _onPointerDragEnd
            ..onCancel = _onPointerDragCancel,
        ),
        _LiftRecognizer: GestureRecognizerFactoryWithHandlers<_LiftRecognizer>(
          () => _LiftRecognizer(this),
          (r) => r
            ..onLongPressStart = _onLiftStart
            ..onLongPressMoveUpdate = _onLiftMove
            ..onLongPressEnd = _onLiftEnd
            ..onLongPressCancel = _onLiftCancel,
        ),
        _TapRecognizer: GestureRecognizerFactoryWithHandlers<_TapRecognizer>(
          () => _TapRecognizer(this),
          (r) => r
            ..onTapUp = _onTapUp
            ..onSecondaryTapUp = _onSecondaryTapUp,
        ),
        _PanZoomRecognizer: GestureRecognizerFactoryWithHandlers<_PanZoomRecognizer>(
          () => _PanZoomRecognizer(this),
          (r) => r
            ..onStart = _onScaleStart
            ..onUpdate = _onScaleUpdate
            ..onEnd = _onScaleEnd,
        ),
      };

  // ---- Drag plumbing ----------------------------------------------------------------------------

  bool _start(TimelineDragKind kind, TimelineHit hit, Offset global, PointerDeviceKind device, {bool lifted = false}) {
    if (_dragging) return false;
    final local = host.toCanvas(global);
    final ok = host.onTimelineDragStart(TimelineDragStart(
      kind: kind,
      hit: hit,
      position: local,
      time: host.viewport.timeAt(local.dx),
      deviceKind: device,
      lifted: lifted,
      additive: HardwareKeyboard.instance.isShiftPressed,
    ));
    if (ok) {
      _dragging = true;
      _dragStartLocal = local;
    }
    return ok;
  }

  void _update(Offset global) {
    if (!_dragging) return;
    final local = host.toCanvas(global);
    host.onTimelineDragUpdate(TimelineDragUpdate(
      position: local,
      time: host.viewport.timeAt(local.dx),
      offset: local - _dragStartLocal,
      snapDisabled: HardwareKeyboard.instance.isAltPressed,
    ));
  }

  void _end({required bool cancelled}) {
    if (!_dragging) return;
    _dragging = false;
    host.onTimelineDragEnd(cancelled: cancelled);
  }

  /// Cancels the drag in progress (back press, app inactive); true when there was one.
  bool cancel() {
    if (!_dragging) return false;
    _end(cancelled: true);
    return true;
  }

  // ---- Handles ----------------------------------------------------------------------------------

  TimelineHit? _handleHit;

  void _onHandleDown(PointerDownEvent e) {
    _handleHit = hitFor(e);
    final kind = handleKindOf(_handleHit);
    // Scrubs start at once (the playhead jumps under the pointer).
    if (kind == TimelineDragKind.scrub) _start(kind!, _handleHit!, e.position, e.kind);
  }

  void _onHandleStart(Offset global, PointerDeviceKind device) {
    final hit = _handleHit;
    final kind = handleKindOf(hit);
    if (hit == null || kind == null || kind == TimelineDragKind.scrub) return;
    _start(kind, hit, global, device);
  }

  void _onHandleMove(Offset global) => _update(global);

  void _onHandleUp(Offset global, PointerDeviceKind device, {required bool moved}) {
    final hit = _handleHit;
    _handleHit = null;
    if (_dragging) {
      _end(cancelled: false);
      if (moved || hit == null) return;
    }
    if (!moved && hit != null && hit is! HitPlayheadKnob && hit is! HitRuler) {
      host.onTimelineTap(_asTapTarget(hit), TimelineTapDetails(globalPosition: global, deviceKind: device, toggle: _toggleHeld));
    }
  }

  void _onHandleHold(Offset global) {
    final hit = _handleHit;
    if (hit == null || hit is HitPlayheadKnob || hit is HitRuler) return;
    _handleHit = null;
    host.onTimelineContextMenu(_asTapTarget(hit), global);
  }

  void _onHandleCancel() {
    _handleHit = null;
    _end(cancelled: true);
  }

  /// A handle tap acts on the item it belongs to.
  TimelineHit _asTapTarget(TimelineHit hit) => switch (hit) {
        HitTrimHandle(:final item, :final lane) => HitItem(item: item, lane: lane, time: 0, selected: true),
        HitFadeHandle(:final item, :final lane) => HitItem(item: item, lane: lane, time: 0, selected: true),
        _ => hit,
      };

  // ---- Pointer item drag and marquee ------------------------------------------------------------

  void _onItemDragStart(DragStartDetails d) {
    final hit = _downHit;
    if (hit == null) return;
    _start(TimelineDragKind.move, hit, d.globalPosition, d.kind ?? PointerDeviceKind.mouse);
  }

  void _onMarqueeStart(DragStartDetails d) {
    final hit = _downHit;
    if (hit == null) return;
    _start(TimelineDragKind.marquee, hit, d.globalPosition, d.kind ?? PointerDeviceKind.mouse);
  }

  void _onPointerDragUpdate(DragUpdateDetails d) => _update(d.globalPosition);

  void _onPointerDragEnd(DragEndDetails d) {
    _end(cancelled: false);
  }

  void _onPointerDragCancel() {
    _end(cancelled: true);
  }

  // ---- Long press (touch) -----------------------------------------------------------------------

  TimelineHit? _liftHit;
  bool _liftMoved = false;
  bool _liftMenuShown = false;

  void _onLiftStart(LongPressStartDetails d) {
    final hit = _liftHit = _downHit;
    _liftMoved = false;
    _liftMenuShown = false;
    if (hit == null) return;
    if (hit is HitItem && !hit.locked) {
      _start(TimelineDragKind.move, hit, d.globalPosition, PointerDeviceKind.touch, lifted: true);
      return;
    }
    // Empty lane, gap, locked item: the menu (or the locked toast) right away.
    _liftMenuShown = true;
    host.onTimelineContextMenu(hit, d.globalPosition);
  }

  void _onLiftMove(LongPressMoveUpdateDetails d) {
    if (!_dragging) return;
    if (!_liftMoved && d.offsetFromOrigin.distance < handleSlopTouch) return;
    _liftMoved = true;
    _update(d.globalPosition);
  }

  void _onLiftEnd(LongPressEndDetails d) {
    final hit = _liftHit;
    _liftHit = null;
    if (_dragging) {
      if (_liftMoved) {
        _end(cancelled: false);
        return;
      }
      _end(cancelled: true);
    }
    if (hit != null && !_liftMenuShown) host.onTimelineContextMenu(hit, d.globalPosition);
  }

  void _onLiftCancel() {
    _liftHit = null;
    _end(cancelled: true);
  }

  // ---- Taps -------------------------------------------------------------------------------------

  static bool get _toggleHeld {
    final k = HardwareKeyboard.instance;
    return k.isShiftPressed || k.isMetaPressed || k.isControlPressed;
  }

  void _onTapUp(TapUpDetails d) {
    final hit = _downHit;
    if (hit == null) return;
    host.onTimelineTap(hit, TimelineTapDetails(globalPosition: d.globalPosition, deviceKind: d.kind, toggle: _toggleHeld));
  }

  void _onSecondaryTapUp(TapUpDetails d) {
    final hit = _downHit;
    if (hit == null) return;
    host.onTimelineContextMenu(hit, d.globalPosition);
  }

  // ---- Pan / zoom -------------------------------------------------------------------------------

  void _onScaleStart(ScaleStartDetails d) {
    _inPan = true;
    _zooming = false;
    _axis = null;
    _freePan = _trackpad || d.kind == PointerDeviceKind.trackpad;
    _lastHorizontalScale = 1;
    _lastScale = 1;
    host.viewport.beginGesture();
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final viewport = host.viewport;
    if (_freePan) {
      // Trackpad: the content follows both axes; a pinch zooms anchored at the cursor.
      final delta = d.focalPointDelta;
      if (delta != Offset.zero) viewport.scrollByPx(-delta.dx, viewport.centerLocked ? 0 : -delta.dy);
      if (d.scale > 0 && _lastScale > 0 && d.scale != _lastScale) {
        _zooming = true;
        viewport.zoomBy(d.scale / _lastScale, anchorX: host.toCanvas(d.focalPoint).dx);
      }
      _lastScale = d.scale;
      return;
    }
    if (d.pointerCount >= 2) {
      if (!_zooming) {
        // The first zoom step only records the scale: its focal delta predates the pinch.
        _zooming = true;
        _lastHorizontalScale = d.horizontalScale;
        return;
      }
      // Horizontal pinch zoom anchored at the focal point, following the focal point (in
      // centre-locked mode the anchor is the playhead and the content never pans: that would scrub).
      final anchorX = host.toCanvas(d.focalPoint).dx;
      if (d.focalPointDelta.dx != 0 && !viewport.centerLocked) viewport.scrollByPx(-d.focalPointDelta.dx, 0);
      final current = d.horizontalScale, last = _lastHorizontalScale;
      if (current > 0 && last > 0 && current != last) viewport.zoomBy(current / last, anchorX: anchorX);
      _lastHorizontalScale = current;
      return;
    }
    if (_zooming) return;
    final delta = d.focalPointDelta;
    if (delta == Offset.zero) return;
    _axis ??= delta.dx.abs() >= delta.dy.abs() ? Axis.horizontal : Axis.vertical;
    if (_axis == Axis.horizontal) {
      viewport.scrollByPx(-delta.dx, 0);
    } else {
      viewport.scrollByPx(0, -delta.dy);
    }
  }

  void _onScaleEnd(ScaleEndDetails d) {
    _inPan = false;
    final v = d.velocity.pixelsPerSecond;
    final Velocity fling;
    if (_zooming) {
      fling = Velocity.zero;
    } else if (_freePan) {
      fling = d.velocity;
    } else {
      fling = switch (_axis) {
        Axis.horizontal => Velocity(pixelsPerSecond: Offset(v.dx, 0)),
        Axis.vertical => Velocity(pixelsPerSecond: Offset(0, v.dy)),
        null => Velocity.zero,
      };
    }
    _zooming = false;
    _axis = null;
    host.viewport.endGesture(velocity: fling);
  }

  /// The axis the current one-pointer pan is locked to (tests).
  @visibleForTesting
  Axis? get debugPanAxis => _axis;

  // ---- Wheel ------------------------------------------------------------------------------------

  /// Mouse wheel and trackpad scroll events (`Listener.onPointerSignal`).
  void handlePointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      GestureBinding.instance.pointerSignalResolver.register(event, (e) => _onWheel(e as PointerScrollEvent));
    } else if (event is PointerScaleEvent) {
      GestureBinding.instance.pointerSignalResolver.register(event, (e) {
        final s = (e as PointerScaleEvent).scale;
        if (s > 0 && s.isFinite) host.viewport.zoomBy(s, anchorX: host.toCanvas(e.position).dx);
      });
    }
  }

  void _onWheel(PointerScrollEvent e) {
    final viewport = host.viewport;
    final k = HardwareKeyboard.instance;
    final dx = e.scrollDelta.dx, dy = e.scrollDelta.dy;
    if (k.isControlPressed || k.isMetaPressed) {
      final d = dy != 0 ? dy : dx;
      if (d != 0) viewport.zoomBy(math.exp(-d / wheelZoomPixels), anchorX: host.toCanvas(e.position).dx);
      return;
    }
    if (k.isShiftPressed) {
      viewport.scrollByPx(dy != 0 ? dy : dx, 0);
      return;
    }
    if (dx.abs() > dy.abs()) {
      viewport.scrollByPx(dx, 0);
    } else if (dy != 0) {
      viewport.scrollByPx(0, dy);
    }
  }

  // ---- Cursors ----------------------------------------------------------------------------------

  /// The mouse cursor over [hit] (ux.md §8.8 hover).
  MouseCursor cursorFor(TimelineHit? hit) {
    if (_dragging) return SystemMouseCursors.grabbing;
    return switch (hit) {
      HitTrimHandle() => SystemMouseCursors.resizeLeftRight,
      HitPlayheadKnob() => SystemMouseCursors.resizeLeftRight,
      HitFadeHandle() || HitKeyframe() => SystemMouseCursors.move,
      HitItem(:final selected, :final locked) when selected && !locked => SystemMouseCursors.grab,
      HitTransition() || HitMarker() => SystemMouseCursors.click,
      HitRuler() when !host.viewport.centerLocked => SystemMouseCursors.click,
      _ => MouseCursor.defer,
    };
  }
}

// -------------------------------------------------------------------------------------------------
// Recognizers
// -------------------------------------------------------------------------------------------------

/// A drag on a handle that wins the arena at pointer-down (ux.md §8.8 `_EagerHandleDrag`).
///
/// Reports the down, the start once the pointer moved past [slopOf], each move, the up (with
/// whether it moved) and, on touch, a hold of [holdDuration] without movement.
class TimelineHandleDragRecognizer extends OneSequenceGestureRecognizer {
  /// Creates the recognizer; [allow] gates pointers by what they hit.
  TimelineHandleDragRecognizer({super.debugOwner, required this.allow, this.holdDuration = const Duration(milliseconds: 350)});

  /// Whether the pointer of a down event belongs to this recognizer.
  final bool Function(PointerDownEvent event) allow;

  /// Hold time that opens the context menu on touch.
  final Duration holdDuration;

  /// Pointer-down (accepted).
  ValueChanged<PointerDownEvent>? onDown;

  /// The pointer moved past the slop.
  void Function(Offset global, PointerDeviceKind kind)? onStart;

  /// Each move after the start.
  ValueChanged<Offset>? onMove;

  /// Pointer-up.
  void Function(Offset global, PointerDeviceKind kind, {required bool moved})? onUp;

  /// Held still for [holdDuration] (touch).
  ValueChanged<Offset>? onHold;

  /// Pointer cancelled.
  VoidCallback? onCancel;

  int? _pointer;
  Offset _origin = Offset.zero;
  PointerDeviceKind _kind = PointerDeviceKind.touch;
  bool _moved = false;
  bool _held = false;
  Timer? _holdTimer;

  /// Movement before a handle drag starts.
  static double slopOf(PointerDeviceKind kind) =>
      kind == PointerDeviceKind.touch ? TimelineGestureArbiter.handleSlopTouch : TimelineGestureArbiter.handleSlopPointer;

  @override
  bool isPointerAllowed(PointerDownEvent event) => _pointer == null && super.isPointerAllowed(event) && allow(event);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    _pointer = event.pointer;
    _origin = event.position;
    _kind = event.kind;
    _moved = false;
    _held = false;
    resolve(GestureDisposition.accepted);
    invokeCallback<void>('onDown', () => onDown?.call(event));
    if (event.kind == PointerDeviceKind.touch && onHold != null) {
      _holdTimer = Timer(holdDuration, () {
        _holdTimer = null;
        if (_moved || _pointer == null) return;
        _held = true;
        invokeCallback<void>('onHold', () => onHold?.call(_origin));
      });
    }
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _pointer) return;
    if (event is PointerMoveEvent) {
      if (_held) return;
      if (!_moved && (event.position - _origin).distance > slopOf(_kind)) {
        _moved = true;
        _holdTimer?.cancel();
        _holdTimer = null;
        invokeCallback<void>('onStart', () => onStart?.call(_origin, _kind));
      }
      if (_moved) invokeCallback<void>('onMove', () => onMove?.call(event.position));
    } else if (event is PointerUpEvent) {
      final moved = _moved, held = _held;
      _finish(event.pointer);
      if (!held) invokeCallback<void>('onUp', () => onUp?.call(event.position, _kind, moved: moved));
    } else if (event is PointerCancelEvent) {
      _finish(event.pointer);
      invokeCallback<void>('onCancel', () => onCancel?.call());
    }
  }

  void _finish(int pointer) {
    _holdTimer?.cancel();
    _holdTimer = null;
    stopTrackingPointer(pointer);
    _pointer = null;
  }

  @override
  void rejectGesture(int pointer) {
    if (pointer != _pointer) return;
    _finish(pointer);
    invokeCallback<void>('onCancel', () => onCancel?.call());
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  @override
  String get debugDescription => 'timeline handle drag';
}

class _ItemDragRecognizer extends PanGestureRecognizer {
  _ItemDragRecognizer(this.arbiter)
      : super(debugOwner: arbiter, supportedDevices: const {
          PointerDeviceKind.mouse,
          PointerDeviceKind.stylus,
          PointerDeviceKind.invertedStylus,
          PointerDeviceKind.unknown,
        });

  final TimelineGestureArbiter arbiter;

  @override
  bool isPointerAllowed(PointerEvent event) =>
      event is PointerDownEvent && super.isPointerAllowed(event) && arbiter._allowsItemDrag(event);

  @override
  String get debugDescription => 'timeline item drag';
}

class _MarqueeRecognizer extends PanGestureRecognizer {
  _MarqueeRecognizer(this.arbiter) : super(debugOwner: arbiter, supportedDevices: const {PointerDeviceKind.mouse});

  final TimelineGestureArbiter arbiter;

  @override
  bool isPointerAllowed(PointerEvent event) => event is PointerDownEvent && super.isPointerAllowed(event) && arbiter._allowsMarquee(event);

  @override
  String get debugDescription => 'timeline marquee';
}

class _LiftRecognizer extends LongPressGestureRecognizer {
  _LiftRecognizer(this.arbiter)
      : super(debugOwner: arbiter, duration: arbiter.longPressDuration, supportedDevices: const {PointerDeviceKind.touch});

  final TimelineGestureArbiter arbiter;

  @override
  bool isPointerAllowed(PointerDownEvent event) => super.isPointerAllowed(event) && arbiter._allowsLift(event);

  @override
  String get debugDescription => 'timeline lift';
}

class _TapRecognizer extends TapGestureRecognizer {
  _TapRecognizer(this.arbiter) : super(debugOwner: arbiter);

  final TimelineGestureArbiter arbiter;

  @override
  bool isPointerAllowed(PointerDownEvent event) => super.isPointerAllowed(event) && arbiter._allowsTap(event);

  @override
  String get debugDescription => 'timeline tap';
}

class _PanZoomRecognizer extends ScaleGestureRecognizer {
  _PanZoomRecognizer(this.arbiter) : super(debugOwner: arbiter);

  final TimelineGestureArbiter arbiter;

  static const DeviceGestureSettings _settings = DeviceGestureSettings(touchSlop: TimelineGestureArbiter.panTouchSlop);

  // Scrollables start dragging after 18 px; the scale recognizer's default pan slop is 36. The
  // RawGestureDetector writes MediaQuery's settings here on every build, so the getter pins ours.
  @override
  DeviceGestureSettings? get gestureSettings => _settings;

  @override
  set gestureSettings(DeviceGestureSettings? value) {}

  @override
  bool isPointerAllowed(PointerDownEvent event) => super.isPointerAllowed(event) && arbiter._allowsPan(event);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    arbiter._trackpad = false;
    super.addAllowedPointer(event);
  }

  @override
  void addAllowedPointerPanZoom(PointerPanZoomStartEvent event) {
    arbiter._trackpad = true;
    super.addAllowedPointerPanZoom(event);
  }

  @override
  String get debugDescription => 'timeline pan/zoom';
}

// -------------------------------------------------------------------------------------------------
// Basic interaction (used until UX-13's slot takes a drag kind)
// -------------------------------------------------------------------------------------------------

/// Moves, trims, keyframe and marker drags and the marquee through `EditTransaction`s, with
/// ghosts at the transaction's dryRun placements and one history entry on drop. No snapping or
/// auto-scroll: UX-13's `TimelineInteractionSlot` adds those.
class TimelineBasicInteraction extends ChangeNotifier implements TimelineInteractionSlot {
  /// Creates the interaction over [controller] and its [state]; [snapshot] and [geometry] describe
  /// what the canvas shows.
  TimelineBasicInteraction({
    required EditorController Function() controller,
    required EditorState Function() state,
    required TimelineSnapshot Function() snapshot,
    required TimelineCanvasGeometry? Function() geometry,
    required this.viewport,
  })  : _controller = controller,
        _state = state,
        _snapshot = snapshot,
        _geometry = geometry;

  final EditorController Function() _controller;
  final EditorState Function() _state;
  final TimelineSnapshot Function() _snapshot;
  final TimelineCanvasGeometry? Function() _geometry;

  /// Zoom and scroll.
  final TimelineViewportController viewport;

  TimelineDragStart? _start;
  EditTransaction? _tx;
  Set<ItemId> _lifted = const {};
  EditCommand? _lastCommand;
  EditResult? _lastResult;
  Rect? _marquee;
  TimeUs? _ghostTime;
  TimeUs _grab = 0;
  TimeUs _anchor = 0;
  Set<ItemId> _ids = const {};
  TrackId? _sourceLane;
  bool _singleLane = true;
  bool _disposed = false;

  @override
  Set<ItemId> get liftedItems => _lifted;

  /// The drag in progress, or null.
  TimelineDragStart? get active => _start;

  /// The command of the latest update (its dryRun is what the ghost shows).
  EditCommand? get lastCommand => _lastCommand;

  /// The latest preview of the open transaction.
  EditPreview? get preview => _tx?.preview;

  /// Where the dragged items land (the ghosts).
  Map<ItemId, Placement> get ghosts => preview?.placements ?? const {};

  /// Whether the latest update was refused (red ghost; a drop cancels).
  bool get rejected => _lastResult is EditRejected || (preview?.isRejected ?? false);

  /// The marquee rect (canvas-local), or null.
  Rect? get marquee => _marquee;

  /// The ghost time of a dragged keyframe or marker, or null.
  TimeUs? get ghostTime => _ghostTime;

  @override
  bool canDrag(TimelineDragKind kind) => switch (kind) {
        TimelineDragKind.move || TimelineDragKind.trim || TimelineDragKind.keyframe || TimelineDragKind.marker || TimelineDragKind.marquee => true,
        TimelineDragKind.fade || TimelineDragKind.scrub => false,
      };

  FrameRate get _rate => _snapshot().frameRate;

  @override
  bool beginDrag(TimelineDragStart start) {
    if (_start != null) endDrag(cancelled: true);
    final snapshot = _snapshot();
    switch ((start.kind, start.hit)) {
      case (TimelineDragKind.move, HitItem(:final item, :final lane, :final locked)):
        if (locked) return false;
        final selected = _state().selection.items;
        final ids = selected.contains(item)
            ? {for (final id in selected) if (!(snapshot.laneOf(id)?.locked ?? true)) id}
            : {item};
        if (!selected.contains(item)) _controller().select(item);
        final model = snapshot.item(item);
        if (model == null) return false;
        _ids = ids;
        _anchor = model.start;
        _sourceLane = lane;
        _singleLane = ids.every((id) => snapshot.laneOf(id)?.id == lane);
        _tx = _controller().beginTransaction(ids.length == 1 ? 'Move clip' : 'Move clips');
        _lifted = ids;
      case (TimelineDragKind.trim, HitTrimHandle(:final item, :final edge)):
        final model = snapshot.item(item);
        if (model == null) return false;
        _grab = (edge == TrimEdge.start ? model.start : model.end) - start.time;
        _ids = {item};
        _tx = _controller().beginTransaction('Trim clip');
        _lifted = {item};
      case (TimelineDragKind.keyframe, HitKeyframe(:final ref)):
        final model = snapshot.item(ref.item);
        if (model == null) return false;
        _anchor = model.start;
        _grab = model.start + ref.t - start.time;
        _ghostTime = model.start + ref.t;
        _tx = _controller().beginTransaction('Move keyframe');
      case (TimelineDragKind.marker, HitMarker(:final id)):
        final marker = snapshot.markers.where((m) => m.id == id).firstOrNull;
        if (marker == null) return false;
        _grab = marker.time - start.time;
        _ghostTime = marker.time;
        _tx = _controller().beginTransaction('Move marker');
      case (TimelineDragKind.marquee, _):
        _marquee = Rect.fromPoints(start.position, start.position);
      default:
        return false;
    }
    _start = start;
    _notify();
    return true;
  }

  @override
  void updateDrag(TimelineDragUpdate update) {
    final start = _start;
    if (start == null) return;
    final rate = _rate;
    switch ((start.kind, start.hit)) {
      case (TimelineDragKind.move, HitItem()):
        final target = math.max(0, rate.quantizeNearest(_anchor + update.time - start.time)).toInt();
        final laneIndex = _geometry()?.laneAt(update.position.dy);
        final lanes = _snapshot().lanes;
        final lane = laneIndex == null ? null : lanes[laneIndex].id;
        final toTrack = _singleLane && lane != null && lane != _sourceLane ? lane : null;
        _run(MoveItems(_ids, target - _anchor, toTrack: toTrack, ripple: _state().modes.ripple, clamp: true));
      case (TimelineDragKind.trim, HitTrimHandle(:final item, :final edge)):
        final t = math.max(0, rate.quantizeNearest(update.time + _grab)).toInt();
        _run(TrimItem(item, edge, t, ripple: _state().modes.ripple, clamp: true));
      case (TimelineDragKind.keyframe, HitKeyframe(:final ref)):
        final model = _snapshot().item(ref.item);
        if (model == null) return;
        final abs = rate.quantizeNearest(update.time + _grab).clamp(model.start, math.max(model.start, model.end - rate.frameUs)).toInt();
        _ghostTime = abs;
        _run(MoveKeyframe(ref, abs - _anchor));
      case (TimelineDragKind.marker, HitMarker(:final id)):
        final t = math.max(0, rate.quantizeNearest(update.time + _grab)).toInt();
        _ghostTime = t;
        _run(UpdateMarker(id, time: t));
      case (TimelineDragKind.marquee, _):
        _marquee = Rect.fromPoints(start.position, update.position);
        _notify();
      default:
    }
  }

  void _run(EditCommand command) {
    final tx = _tx;
    if (tx == null) return;
    _lastCommand = command;
    _lastResult = tx.update(command);
    _notify();
  }

  @override
  void endDrag({bool cancelled = false}) {
    final start = _start;
    if (start == null) return;
    final tx = _tx;
    if (start.kind == TimelineDragKind.marquee) {
      if (!cancelled) _selectMarquee(start.additive);
    } else if (tx != null) {
      if (cancelled || _lastCommand == null || rejected) {
        tx.cancel();
      } else {
        final result = tx.commit();
        final hit = start.hit;
        if (result is EditApplied && hit is HitKeyframe && _ghostTime != null) {
          _controller().selectKeyframe(KeyframeRef(hit.ref.item, hit.ref.property, _ghostTime! - _anchor));
        }
      }
    }
    _reset();
  }

  void _selectMarquee(bool additive) {
    final rect = _marquee;
    final g = _geometry();
    if (rect == null || g == null) return;
    final snapshot = _snapshot();
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
    _start = null;
    _tx = null;
    _lifted = const {};
    _lastCommand = null;
    _lastResult = null;
    _marquee = null;
    _ghostTime = null;
    _ids = const {};
    _sourceLane = null;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  Widget buildLayer(BuildContext context, TimelineLayerContext layer) => TimelineBasicInteractionLayer(interaction: this, layer: layer);

  @override
  void dispose() {
    _tx?.cancel();
    _disposed = true;
    super.dispose();
  }
}

/// Draws the [TimelineBasicInteraction] ghosts and marquee over the ruler and lanes.
class TimelineBasicInteractionLayer extends StatelessWidget {
  /// Creates the layer.
  const TimelineBasicInteractionLayer({super.key, required this.interaction, required this.layer});

  /// What to draw.
  final TimelineBasicInteraction interaction;

  /// Snapshot, viewport, metrics and style.
  final TimelineLayerContext layer;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: RepaintBoundary(
          child: CustomPaint(painter: _BasicInteractionPainter(interaction, layer), size: Size.infinite),
        ),
      );
}

class _BasicInteractionPainter extends CustomPainter {
  _BasicInteractionPainter(this.interaction, this.layer) : super(repaint: Listenable.merge([interaction, layer.viewport]));

  final TimelineBasicInteraction interaction;
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
    final ghostTime = interaction.ghostTime;
    if (ghostTime != null) {
      final x = viewport.xOf(ghostTime);
      final top = start.kind == TimelineDragKind.marker ? 0.0 : ruler;
      canvas.drawLine(Offset(x, top), Offset(x, size.height), Paint()
        ..strokeWidth = 1.5
        ..color = style.snapGuide);
    }
    final ghosts = interaction.ghosts;
    if (ghosts.isNotEmpty) {
      final g = TimelineCanvasGeometry(snapshot: layer.snapshot, metrics: layer.metrics, viewport: viewport);
      final bad = interaction.rejected;
      final color = bad ? const Color(0xFFEF4444) : style.selection;
      final pointerY = start.position.dy;
      ghosts.forEach((id, p) {
        final li = layer.snapshot.laneIndexOf(p.track);
        final double top, height;
        if (li != null) {
          top = g.laneTop(li) + TimelineMetrics.clipInset;
          height = g.stack.heights[li] - 2 * TimelineMetrics.clipInset;
        } else {
          // A lane the drop creates: drawn where the pointer started, outlined.
          top = pointerY;
          height = layer.metrics.laneHeightOf(TrackKind.video) - 2 * TimelineMetrics.clipInset;
        }
        final rect = RRect.fromRectAndRadius(
          Rect.fromLTWH(viewport.xOf(p.range.start), top + ruler, viewport.xOf(p.range.end) - viewport.xOf(p.range.start), height),
          const Radius.circular(TimelineMetrics.clipRadius),
        );
        canvas.drawRRect(rect, Paint()..color = color.withValues(alpha: 0.28));
        canvas.drawRRect(rect, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = li == null ? 1 : 2
          ..color = color);
      });
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BasicInteractionPainter oldDelegate) => !identical(oldDelegate.interaction, interaction) || oldDelegate.layer != layer;
}
