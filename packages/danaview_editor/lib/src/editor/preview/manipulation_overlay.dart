// OWNER: UX-22
//
// ManipulationOverlay (ux.md §7.3, §7.4, §19.1): direct manipulation of the selected item on the
// preview: one `ScaleGestureRecognizer` for one-finger moves, two-finger pinch/rotate and trackpad
// pan-zoom (PointerPanZoom), plus taps and long-presses.
//
// Gestures (ux.md §7.3):
// * Tap on a visual item at the playhead selects it; repeated taps at the same point cycle through
//   the overlapping items, top-most first. A second tap on a selected text item within the
//   double-tap window opens the text panel.
// * Tap on empty canvas: while a selected item shows handles it clears the selection; otherwise it
//   is a touch preview control (UX-18): tap toggles play/pause, double-tap seeks ±1 s (left or right
//   half of the view). Single taps on empty canvas wait out the double-tap window.
// * One-finger drag on an item (selecting it first) moves it, snapping to the canvas centre, edges
//   and title-safe margins (§7.4). Corner handles scale uniformly from the centre; the rotate handle
//   rotates with the 45° magnet. Two fingers (or a trackpad pinch) anywhere while an item is selected
//   scale around the box centre, rotate, and move with the focal point.
// * Long-press on an item selects it and opens its context menu (Duplicate, Delete, Bring forward,
//   Send backward, Reset transform, Keyframe at playhead: registry actions).
// * Subtitle cues move their whole track vertically (custom Y position, `SetSubtitlePosition`); they
//   have no corner or rotate handles.
//
// Pipeline per gesture: `beginTransaction(label)` at the start; pointer updates are coalesced to one
// `tx.update` per frame (so at most one transient per frame reaches PlanSync, which also coalesces
// to 60 Hz); `tx.commit()` at the end records one history entry. Writes are keyframe-aware:
// `SetProperty(…, at: playhead)` writes a key at the frame-quantized playhead on keyframed
// properties ("Move (keyframe)"). The label follows what changed ("Move", "Scale", "Rotate",
// "Transform"); a two-finger gesture whose label differs from the predicted one is re-run under the
// right label at commit (still one entry). Cancel (Esc/back's cancel step, the app going inactive,
// another mutation) restores the base.
//
// Handles are painted from the shown (working) project at the playhead, repainting with the
// playhead (no rebuild per frame). Semantics: the selected item exposes custom actions to move,
// scale and rotate it in steps.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' show Theme;
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show CompositeCommand, EditCommand, SetProperty, SetSubtitlePosition;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../actions/editor_action_registry.dart';
import '../contracts/contracts.dart';
import '../editor_lifecycle.dart';
import '../editor_scope.dart';
import '../state/editor_controller.dart';
import '../state/editor_state.dart';
import 'canvas_geometry.dart';
import 'manipulation_painter.dart';
import 'snap_guides.dart';
import 'text_overlay_layer.dart' show previewTextEngineProvider;

/// What a manipulation gesture changes.
enum ManipulationMode {
  /// One-finger move.
  move,

  /// Two-finger (or trackpad) scale, rotate and move.
  transform,

  /// Corner handle: uniform scale from the centre.
  cornerScale,

  /// Rotate handle.
  rotate,
}

/// History labels and semantics of the overlay (ux.md §7.3).
abstract final class ManipulationStrings {
  /// Move.
  static const String move = 'Move';

  /// Scale.
  static const String scale = 'Scale';

  /// Rotate.
  static const String rotate = 'Rotate';

  /// Two or more of move, scale, rotate.
  static const String transform = 'Transform';

  /// A subtitle track moved vertically.
  static const String moveCaptions = 'Move captions';

  /// Suffix of a keyframed write.
  static const String keyframeSuffix = ' (keyframe)';

  /// Semantics: move left.
  static const String moveLeft = 'Move left';

  /// Semantics: move right.
  static const String moveRight = 'Move right';

  /// Semantics: move up.
  static const String moveUp = 'Move up';

  /// Semantics: move down.
  static const String moveDown = 'Move down';

  /// Semantics: scale up.
  static const String scaleUp = 'Scale up';

  /// Semantics: scale down.
  static const String scaleDown = 'Scale down';

  /// Semantics: rotate clockwise.
  static const String rotateClockwise = 'Rotate clockwise';

  /// Semantics: rotate counterclockwise.
  static const String rotateCounterclockwise = 'Rotate counterclockwise';

  /// Semantics label of the overlay with a selected item.
  static String selected(String kind, double scale, double rotation) =>
      'Selected $kind, scale ${(scale * 100).round()} percent, rotation ${rotation.round()} degrees';

  /// Semantics label of a selected subtitle track.
  static const String selectedCaptions = 'Selected captions';
}

/// Step sizes of the semantics actions.
abstract final class ManipulationSteps {
  /// Move step as a canvas fraction.
  static const double move = 0.01;

  /// Scale factor per step.
  static const double scale = 1.1;

  /// Rotation step in degrees.
  static const double rotate = 15;

  /// Caption Y step as a canvas fraction.
  static const double captions = 0.02;
}

/// Move, scale and rotate on the preview (ux.md §7.3).
class ManipulationOverlay extends ConsumerStatefulWidget {
  /// Creates the overlay over a preview mapped by [geometry].
  const ManipulationOverlay({
    super.key,
    required this.geometry,
    this.onEmptyTap,
    this.onEmptyDoubleTap,
    this.enabled = true,
    this.doubleTapWindow = kDoubleTapTimeout,
    this.haptic,
  });

  /// Letterbox mapping of the preview.
  final CanvasGeometry geometry;

  /// Single tap on empty canvas with nothing shown selected (UX-18: toggle play/pause).
  final VoidCallback? onEmptyTap;

  /// Double tap on empty canvas: -1 on the left half, +1 on the right half (UX-18: seek ±1 s).
  final ValueChanged<int>? onEmptyDoubleTap;

  /// Whether gestures are handled.
  final bool enabled;

  /// Double-tap window.
  final Duration doubleTapWindow;

  /// Snap haptic (tests count it); `HapticFeedback.selectionClick` by default.
  final VoidCallback? haptic;

  @override
  ConsumerState<ManipulationOverlay> createState() => ManipulationOverlayState();
}

/// One running gesture.
final class _Gesture {
  _Gesture({
    required this.item,
    required this.track,
    required this.cue,
    required this.tx,
    required this.mode,
    required this.box0,
    required this.pos0,
    required this.scale0,
    required this.rot0,
    required this.y0,
    required this.animOffset,
    required this.animScale,
    required this.keyed,
  })  : pos = pos0,
        scale = scale0,
        rot = rot0,
        y = y0 {
    rebase();
  }

  final ItemId item;
  final TrackId track;
  final bool cue;
  final EditTransaction tx;
  ManipulationMode mode;
  final ItemBox box0;
  final Vec2 pos0;
  final double scale0;
  final double rot0;
  final double y0;
  final Offset2 animOffset;
  final double animScale;
  final Set<String> keyed;

  Vec2 pos;
  double scale;
  double rot;
  double y;

  // Segment base (reset when fingers are added or lifted).
  Offset segPointer = Offset.zero;
  Vec2 segPos = Vec2.zero;
  double segScale = 1;
  double segRot = 0;
  double segY = 0;
  double segAngle = 0;
  double segDistance = 1;
  bool needsSegment = true;
  bool dirty = false;
  Set<SnapGuide> guides = const {};

  void rebase() {
    segPos = pos;
    segScale = scale;
    segRot = rot;
    segY = y;
    needsSegment = true;
  }

  bool get moved => cue ? y != y0 : pos != pos0;
  bool get scaled => scale != scale0;
  bool get rotated => rot != rot0;
}

/// State of [ManipulationOverlay] (public for tests).
class ManipulationOverlayState extends ConsumerState<ManipulationOverlay> {
  _Gesture? _g;
  bool _frameScheduled = false;
  late final SnapEngagement _engagement = SnapEngagement(haptic: widget.haptic);
  VoidCallback? _unregisterCancel;
  EditorBackDispatcher? _dispatcher;
  Timer? _tapTimer;
  Offset? _pendingTap;
  Offset? _lastTapAt;
  ItemId? _lastTapItem;
  Timer? _itemTapWindow;
  Offset? _menuAt;
  VoidCallback? _openMenu;
  List<ItemId> _lastHits = const [];

  /// Where each pointer went down: gestures target what is under the finger at touch-down (the
  /// scale recognizer only starts after the pan slop) and items follow the finger from there.
  final Map<int, Offset> _downs = {};

  Offset? get _downFocal {
    if (_downs.isEmpty) return null;
    var sum = Offset.zero;
    for (final p in _downs.values) {
      sum += p;
    }
    return sum / _downs.length.toDouble();
  }

  ProjectId get _id => EditorScope.idOf(context);

  EditorController get _controller => ref.read(editorControllerProvider(_id).notifier);

  /// Whether a manipulation gesture is running (tests).
  bool get isManipulating => _g != null;

  /// Snap engagements so far (tests).
  int get snapEngagements => _engagement.engagements;

  /// The guides currently shown (tests).
  Set<SnapGuide> get shownGuides => _g?.guides ?? const {};

  bool get _touch => context.isTouchPlatform;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final d = EditorBackDispatcher.maybeOf(context);
    if (!identical(d, _dispatcher)) {
      _unregisterCancel?.call();
      _dispatcher = d;
      _unregisterCancel = d?.register(EditorBackStep.cancelGesture, _cancelForBack);
    }
  }

  @override
  void dispose() {
    _unregisterCancel?.call();
    _tapTimer?.cancel();
    _itemTapWindow?.cancel();
    final g = _g;
    _g = null;
    if (g != null && g.tx.isOpen) g.tx.cancel();
    super.dispose();
  }

  bool _cancelForBack() {
    final g = _g;
    if (g == null) return false;
    _g = null;
    _engagement.reset();
    if (g.tx.isOpen) g.tx.cancel();
    if (mounted) setState(() {});
    return true;
  }

  // ---------------------------------------------------------------------------------------------
  // Model helpers
  // ---------------------------------------------------------------------------------------------

  EditProject? get _project => ref.read(editorControllerProvider(_id)).project;

  TimeUs get _t => ref.read(playheadProvider(_id)).value;

  TextMetricsProvider get _metrics => ref.read(previewTextEngineProvider);

  /// The box of [item] at [t] when it is on a visible visual lane and active at [t].
  ItemBox? _boxOf(EditProject project, ItemId? item, TimeUs t) {
    if (item == null) return null;
    final loc = project.index.locate(item);
    if (loc == null) return null;
    final track = loc.track;
    if (track.hidden || !track.kind.isVisual) return null;
    if (!(loc.item.start <= t && t < loc.item.end)) return null;
    return boxAt(project, item, t, text: _metrics);
  }

  List<ItemId> _hitsAt(EditProject project, Offset view, TimeUs t) {
    final g = widget.geometry;
    if (g.isEmpty) return const [];
    return hitTestAll(project, g.toCanvas2(view), t, text: _metrics, slop: g.viewToCanvasLength(_touch ? 4 : 0));
  }

  ItemId? get _primary => ref.read(editorControllerProvider(_id)).selection.primary;

  ManipulationHandles? _handlesOf(EditProject project, ItemId? item, TimeUs t, Size view) {
    final box = _boxOf(project, item, t);
    if (box == null || item == null) return null;
    final cue = project.index.locate(item)?.item is SubtitleCue;
    return ManipulationHandles.layout(
      geometry: widget.geometry,
      box: box,
      view: view,
      touch: _touch,
      scalable: !cue,
      rotatable: !cue,
    );
  }

  // ---------------------------------------------------------------------------------------------
  // Taps
  // ---------------------------------------------------------------------------------------------

  void _onTapUp(TapUpDetails d) {
    if (!widget.enabled) return;
    final project = _project;
    if (project == null) return;
    final p = d.localPosition;
    final t = _t;
    final hits = _hitsAt(project, p, t);
    if (hits.isEmpty) {
      _lastTapItem = null;
      _emptyTap(p);
      return;
    }
    _cancelPendingTap();
    final primary = _primary;
    final sameSpot = _lastTapAt != null && (_lastTapAt! - p).distance <= 12;
    final quick = _itemTapWindow?.isActive ?? false;
    // Double tap on a selected text item opens the text panel.
    if (sameSpot && quick && _lastTapItem != null && _lastTapItem == primary && hits.contains(primary)) {
      final item = project.index.locate(primary!)?.item;
      if (item is TextItem) {
        _controller.openInspector(TextInspector(item.id));
        _lastTapItem = null;
        _itemTapWindow?.cancel();
        _itemTapWindow = null;
        return;
      }
    }
    ItemId next = hits.first;
    if (sameSpot && primary != null && hits.contains(primary) && listEquals(hits, _lastHits)) {
      next = hits[(hits.indexOf(primary) + 1) % hits.length];
    }
    _controller.select(next);
    _lastTapAt = p;
    _lastTapItem = next;
    _itemTapWindow?.cancel();
    _itemTapWindow = Timer(widget.doubleTapWindow, () => _itemTapWindow = null);
    _lastHits = hits;
  }

  void _emptyTap(Offset p) {
    final pending = _pendingTap;
    if (pending != null) {
      _cancelPendingTap();
      widget.onEmptyDoubleTap?.call(p.dx < context.size!.width / 2 ? -1 : 1);
      return;
    }
    _pendingTap = p;
    _tapTimer = Timer(widget.doubleTapWindow, () {
      _pendingTap = null;
      _tapTimer = null;
      if (!mounted) return;
      _singleEmptyTap();
    });
  }

  void _singleEmptyTap() {
    final project = _project;
    final size = context.size;
    if (project != null && size != null && _handlesOf(project, _primary, _t, size) != null) {
      _controller.clearSelection();
      return;
    }
    widget.onEmptyTap?.call();
  }

  void _cancelPendingTap() {
    _tapTimer?.cancel();
    _tapTimer = null;
    _pendingTap = null;
  }

  // ---------------------------------------------------------------------------------------------
  // Long press
  // ---------------------------------------------------------------------------------------------

  void _onLongPressStart(LongPressStartDetails d) {
    if (!widget.enabled || _g != null) return;
    final project = _project;
    if (project == null) return;
    final hits = _hitsAt(project, d.localPosition, _t);
    if (hits.isEmpty) return;
    final primary = _primary;
    final target = primary != null && hits.contains(primary) ? primary : hits.first;
    if (target != primary) _controller.select(target);
    setState(() => _menuAt = d.localPosition);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _openMenu?.call();
    });
  }

  /// The context menu actions (ux.md §7.3).
  static const List<EditorActionId> menuActions = [
    EditorActionId.duplicate,
    EditorActionId.delete,
    EditorActionId.bringForward,
    EditorActionId.sendBackward,
    EditorActionId.resetTransform,
    EditorActionId.keyframeAtPlayhead,
  ];

  // ---------------------------------------------------------------------------------------------
  // Scale gesture (move, pinch, rotate, handles)
  // ---------------------------------------------------------------------------------------------

  void _onScaleStart(ScaleStartDetails d) {
    if (!widget.enabled) return;
    _cancelPendingTap();
    final running = _g;
    if (running != null) {
      // Fingers were added or lifted: continue the same gesture from here.
      if (!running.tx.isOpen) {
        _g = null;
        return;
      }
      if (d.pointerCount >= 2 && !running.cue) running.mode = ManipulationMode.transform;
      if (d.pointerCount == 1 && running.mode == ManipulationMode.transform) running.mode = ManipulationMode.move;
      running.rebase();
      _beginSegment(running, d.localFocalPoint);
      return;
    }
    final project = _project;
    final size = context.size;
    if (project == null || size == null || widget.geometry.isEmpty) return;
    final controller = _controller;
    if (!controller.canEdit) return;
    final t = _t;
    final p = _downFocal ?? d.localFocalPoint;
    var target = _primary;
    ManipulationMode? mode;
    final handles = _handlesOf(project, target, t, size);
    if (d.pointerCount >= 2) {
      if (handles == null) {
        final hits = _hitsAt(project, p, t);
        if (hits.isEmpty) return;
        target = hits.first;
        controller.select(target);
      }
      mode = ManipulationMode.transform;
    } else {
      final hit = handles?.hitTest(p);
      if (hit != null) {
        mode = hit.kind == ManipulationHandleKind.rotate ? ManipulationMode.rotate : ManipulationMode.cornerScale;
      } else {
        final hits = _hitsAt(project, p, t);
        if (hits.isEmpty) return;
        if (target == null || !hits.contains(target)) {
          target = hits.first;
          controller.select(target);
        }
        mode = ManipulationMode.move;
      }
    }
    final g = _start(project, target!, mode, t);
    if (g == null) return;
    _g = g;
    _beginSegment(g, p);
    final playhead = ref.read(playheadProvider(_id));
    if (playhead.playing.value) unawaited(ref.read(transportProvider(_id)).pause());
  }

  _Gesture? _start(EditProject project, ItemId item, ManipulationMode mode, TimeUs t) {
    final loc = project.index.locate(item);
    if (loc == null) return null;
    final box = _boxOf(project, item, t);
    if (box == null) return null;
    final it = loc.item;
    final canvas = project.settings.canvas.sizePx;
    if (it is SubtitleCue) {
      final tx = _controller.beginTransaction(ManipulationStrings.moveCaptions);
      final y = box.center.dy / canvas.height;
      return _Gesture(
        item: item,
        track: loc.track.id,
        cue: true,
        tx: tx,
        mode: ManipulationMode.move,
        box0: box,
        pos0: Vec2.zero,
        scale0: 1,
        rot0: 0,
        y0: y,
        animOffset: Offset2.zero,
        animScale: 1,
        keyed: const {},
      );
    }
    final local = t - it.start;
    final pos = evaluate(it, PropertyKeys.position, local);
    final scale = evaluate(it, PropertyKeys.scale, local);
    final rot = evaluate(it, PropertyKeys.rotation, local);
    var animOffset = Offset2.zero;
    var animScale = 1.0;
    if (it is TextItem) {
      final a = evaluateTextAnimation(it, t, project.settings.canvas);
      animOffset = a.offset;
      animScale = a.scale;
    }
    final keys = keyframesOf(it);
    final keyed = <String>{
      for (final k in [PropertyKeys.position, PropertyKeys.scale, PropertyKeys.rotation])
        if (KeyframeOps.isAnimated(keys, k)) k.id,
    };
    final predicted = switch (mode) {
      ManipulationMode.move => ManipulationStrings.move,
      ManipulationMode.cornerScale => ManipulationStrings.scale,
      ManipulationMode.rotate => ManipulationStrings.rotate,
      ManipulationMode.transform => ManipulationStrings.transform,
    };
    final predictedKey = switch (mode) {
      ManipulationMode.move => keyed.contains(PropertyKeys.position.id),
      ManipulationMode.cornerScale => keyed.contains(PropertyKeys.scale.id),
      ManipulationMode.rotate => keyed.contains(PropertyKeys.rotation.id),
      ManipulationMode.transform => keyed.isNotEmpty,
    };
    final tx = _controller.beginTransaction(predictedKey ? '$predicted${ManipulationStrings.keyframeSuffix}' : predicted);
    return _Gesture(
      item: item,
      track: loc.track.id,
      cue: false,
      tx: tx,
      mode: mode,
      box0: box,
      pos0: pos,
      scale0: scale,
      rot0: rot,
      y0: 0,
      animOffset: animOffset,
      animScale: animScale,
      keyed: keyed,
    );
  }

  Offset _centerView(_Gesture g, Vec2 pos) {
    final project = _project;
    if (project == null) return Offset.zero;
    final canvas = project.settings.canvas.sizePx;
    if (g.cue) return widget.geometry.toView2(Offset2(canvas.width / 2, g.y * canvas.height));
    return widget.geometry.toView2(positionToCanvas(pos, canvas) + g.animOffset);
  }

  void _beginSegment(_Gesture g, Offset p) {
    g.segPointer = p;
    final c = _centerView(g, g.segPos);
    final v = p - c;
    g.segAngle = math.atan2(v.dy, v.dx) * 180 / math.pi;
    g.segDistance = math.max(1, v.distance);
    g.needsSegment = false;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final g = _g;
    if (g == null) return;
    if (!g.tx.isOpen) {
      _g = null;
      setState(() {});
      return;
    }
    final project = _project;
    if (project == null) return;
    if (g.needsSegment) _beginSegment(g, d.localFocalPoint);
    final geo = widget.geometry;
    final canvas = project.settings.canvas.sizePx;
    final snapping = _snappingOn;
    final threshold = geo.viewToCanvasLength(SnapGuides.thresholdFor(touch: _touch));
    final guides = SnapGuides(canvas: canvas, safeMargins: ref.read(editorControllerProvider(_id)).modes.safeGuides);
    var shown = <SnapGuide>{};
    var rotSnapped = false;
    final p = d.localFocalPoint;

    if (g.cue) {
      final dy = geo.viewToCanvasLength(p.dy - g.segPointer.dy);
      var cy = g.segY * canvas.height + dy;
      if (snapping) {
        final box = ItemBox(center: Offset2(canvas.width / 2, cy), base: g.box0.base);
        final s = guides.snapMove(box, threshold, horizontal: false);
        cy += s.delta.dy;
        shown = s.guides;
      }
      g.y = (cy / canvas.height).clamp(0.0, 1.0);
    } else {
      switch (g.mode) {
        case ManipulationMode.move:
        case ManipulationMode.transform:
          final delta = p - g.segPointer;
          var center = positionToCanvas(g.segPos, canvas) + g.animOffset + Offset2(geo.viewToCanvasLength(delta.dx), geo.viewToCanvasLength(delta.dy));
          if (g.mode == ManipulationMode.transform) {
            g.scale = _clampScale(g.segScale * d.scale);
            var rot = g.segRot + normalizeDegrees(d.rotation * 180 / math.pi);
            if (snapping) {
              final r = SnapGuides.snapRotation(rot);
              rot = r.degrees;
              rotSnapped = r.snapped && d.rotation != 0;
            }
            g.rot = _clampRotation(rot);
          }
          if (snapping) {
            final box = _boxWith(g, center);
            final s = guides.snapMove(box, threshold);
            center = center + s.delta;
            shown = s.guides;
          }
          g.pos = _clampPos(canvasToPosition(center - g.animOffset, canvas));
        case ManipulationMode.cornerScale:
          final c = _centerView(g, g.pos);
          final dist = (p - c).distance;
          g.scale = _clampScale(g.segScale * dist / g.segDistance);
        case ManipulationMode.rotate:
          final c = _centerView(g, g.pos);
          final v = p - c;
          final angle = math.atan2(v.dy, v.dx) * 180 / math.pi;
          var rot = g.segRot + normalizeDegrees(angle - g.segAngle);
          if (snapping) {
            final r = SnapGuides.snapRotation(rot);
            rot = r.degrees;
            rotSnapped = r.snapped;
          }
          g.rot = _clampRotation(rot);
      }
    }
    _engagement.guides(shown);
    _engagement.rotation(rotSnapped);
    g.guides = shown;
    g.dirty = true;
    _queueUpdate();
  }

  bool get _snappingOn {
    if (SnapGuides.altHeld) return false;
    return ref.read(editorControllerProvider(_id)).modes.snapping;
  }

  ItemBox _boxWith(_Gesture g, Offset2 center) => ItemBox(
        center: center,
        base: g.box0.base,
        scale: g.scale * g.animScale,
        rotationDeg: g.rot,
        flipH: g.box0.flipH,
        flipV: g.box0.flipV,
      );

  static double _clampScale(double s) => s.isFinite ? s.clamp(0.01, 8.0) : 1;

  static double _clampRotation(double r) => r.isFinite ? r.clamp(-360.0, 360.0) : 0;

  static Vec2 _clampPos(Vec2 v) => Vec2(v.x.clamp(-2.0, 2.0), v.y.clamp(-2.0, 2.0));

  void _queueUpdate() {
    if (_frameScheduled) return;
    _frameScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _frameScheduled = false;
      if (mounted) _flush();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  /// Sends the latest pointer state as one transaction update.
  void _flush() {
    final g = _g;
    if (g == null || !g.dirty) return;
    g.dirty = false;
    if (!g.tx.isOpen) {
      _g = null;
      setState(() {});
      return;
    }
    g.tx.update(_command(g, _labelOf(g)));
    setState(() {});
  }

  String _labelOf(_Gesture g) {
    if (g.cue) return ManipulationStrings.moveCaptions;
    final changes = [g.moved, g.scaled, g.rotated].where((c) => c).length;
    final String base;
    if (changes > 1) {
      base = ManipulationStrings.transform;
    } else if (g.moved) {
      base = ManipulationStrings.move;
    } else if (g.scaled) {
      base = ManipulationStrings.scale;
    } else if (g.rotated) {
      base = ManipulationStrings.rotate;
    } else {
      return g.tx.label;
    }
    final keyed = (g.moved && g.keyed.contains(PropertyKeys.position.id)) ||
        (g.scaled && g.keyed.contains(PropertyKeys.scale.id)) ||
        (g.rotated && g.keyed.contains(PropertyKeys.rotation.id));
    return keyed ? '$base${ManipulationStrings.keyframeSuffix}' : base;
  }

  EditCommand _command(_Gesture g, String label) {
    if (g.cue) return SetSubtitlePosition(g.track, CustomSubtitlePosition(g.y));
    final t = _t;
    final cmds = <EditCommand>[
      if (g.moved) SetProperty<Vec2>([g.item], PropertyKeys.position, g.pos, at: t),
      if (g.scaled) SetProperty<double>([g.item], PropertyKeys.scale, g.scale, at: t),
      if (g.rotated) SetProperty<double>([g.item], PropertyKeys.rotation, g.rot, at: t),
    ];
    return cmds.length == 1 ? cmds.single : CompositeCommand(label, cmds);
  }

  void _onScaleEnd(ScaleEndDetails d) {
    final g = _g;
    if (g == null) return;
    if (d.pointerCount > 0) {
      // Fingers remain: keep the transaction; the next start continues from the current values.
      _flush();
      g.rebase();
      return;
    }
    _finish(g);
  }

  /// A pointer went up (after the recognizers saw it). When it was the last one and the gesture
  /// is still open (the scale recognizer reports no end after fingers were lifted one by one
  /// without moving in between), the gesture ends here; a cancelled pointer cancels it.
  void _pointerGone(int pointer, {bool cancelled = false}) {
    _downs.remove(pointer);
    if (_downs.isNotEmpty) return;
    final g = _g;
    if (g == null) return;
    if (cancelled) {
      _cancelForBack();
    } else {
      _finish(g);
    }
  }

  void _finish(_Gesture g) {
    _g = null;
    _engagement.reset();
    if (!g.tx.isOpen) {
      if (mounted) setState(() {});
      return;
    }
    final label = _labelOf(g);
    final cmd = _command(g, label);
    if (label == g.tx.label) {
      if (g.dirty) g.tx.update(cmd);
      g.tx.commit();
    } else {
      // The gesture turned out to be another kind (e.g. a pinch that only scaled): record it under
      // the right label (one history entry).
      final tx = _controller.beginTransaction(label);
      tx.update(cmd);
      tx.commit();
    }
    if (mounted) setState(() {});
  }

  // ---------------------------------------------------------------------------------------------
  // Semantics actions
  // ---------------------------------------------------------------------------------------------

  void _step({Offset2 move = Offset2.zero, double scale = 1, double rotate = 0, String label = ManipulationStrings.move}) {
    final project = _project;
    final item = _primary;
    if (project == null || item == null) return;
    final t = _t;
    final loc = project.index.locate(item);
    if (loc == null || _boxOf(project, item, t) == null) return;
    final it = loc.item;
    final controller = _controller;
    if (it is SubtitleCue) {
      final box = _boxOf(project, item, t)!;
      final canvas = project.settings.canvas.sizePx;
      final y = (box.center.dy / canvas.height + move.dy).clamp(0.0, 1.0);
      controller.apply(SetSubtitlePosition(loc.track.id, CustomSubtitlePosition(y)));
      return;
    }
    final local = t - it.start;
    final cmds = <EditCommand>[
      if (move != Offset2.zero)
        SetProperty<Vec2>([item], PropertyKeys.position, _clampPos(_add(evaluate(it, PropertyKeys.position, local), move)), at: t),
      if (scale != 1) SetProperty<double>([item], PropertyKeys.scale, _clampScale(evaluate(it, PropertyKeys.scale, local) * scale), at: t),
      if (rotate != 0) SetProperty<double>([item], PropertyKeys.rotation, _clampRotation(evaluate(it, PropertyKeys.rotation, local) + rotate), at: t),
    ];
    if (cmds.isEmpty) return;
    controller.apply(CompositeCommand(label, cmds));
  }

  static Vec2 _add(Vec2 v, Offset2 d) => Vec2(v.x + d.dx, v.y + d.dy);

  Map<CustomSemanticsAction, VoidCallback> _semanticsActions(bool cue) {
    const m = ManipulationSteps.move;
    return {
      if (!cue) ...{
        const CustomSemanticsAction(label: ManipulationStrings.moveLeft): () => _step(move: const Offset2(-m, 0)),
        const CustomSemanticsAction(label: ManipulationStrings.moveRight): () => _step(move: const Offset2(m, 0)),
      },
      const CustomSemanticsAction(label: ManipulationStrings.moveUp): () =>
          _step(move: Offset2(0, cue ? -ManipulationSteps.captions : -m)),
      const CustomSemanticsAction(label: ManipulationStrings.moveDown): () =>
          _step(move: Offset2(0, cue ? ManipulationSteps.captions : m)),
      if (!cue) ...{
        const CustomSemanticsAction(label: ManipulationStrings.scaleUp): () =>
            _step(scale: ManipulationSteps.scale, label: ManipulationStrings.scale),
        const CustomSemanticsAction(label: ManipulationStrings.scaleDown): () =>
            _step(scale: 1 / ManipulationSteps.scale, label: ManipulationStrings.scale),
        const CustomSemanticsAction(label: ManipulationStrings.rotateClockwise): () =>
            _step(rotate: ManipulationSteps.rotate, label: ManipulationStrings.rotate),
        const CustomSemanticsAction(label: ManipulationStrings.rotateCounterclockwise): () =>
            _step(rotate: -ManipulationSteps.rotate, label: ManipulationStrings.rotate),
      },
    };
  }

  // ---------------------------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final id = _id;
    final view = ref.watch(editorControllerProvider(id).select(_OverlayView.of));
    final playhead = ref.watch(playheadProvider(id));
    final engine = ref.watch(previewTextEngineProvider);
    final g = _g;
    final project = view.project;
    final selected = view.primary;
    final selectedItem = project == null || selected == null ? null : project.index.locate(selected)?.item;
    final cue = selectedItem is SubtitleCue;

    final guidesCanvas = g == null || project == null
        ? const <(Offset2, Offset2)>[]
        : SnapGuides(canvas: project.settings.canvas.sizePx, safeMargins: view.safeGuides).segmentsOf(g.guides);
    final readout = g == null || g.cue || g.mode == ManipulationMode.move ? null : manipulationReadout(scale: g.scale, rotationDeg: g.rot);

    Widget overlay = CustomPaint(
      size: Size.infinite,
      painter: _LivePainter(
        playhead: playhead,
        project: project,
        item: selected,
        resolve: (size, t) => project == null ? null : _handlesOfWith(project, selected, t, size, engine),
        guides: ManipulationPainter.viewGuides(widget.geometry, guidesCanvas),
        readout: readout,
        textScale: MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.35),
      ),
    );

    overlay = RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: <Type, GestureRecognizerFactory>{
        TapGestureRecognizer: GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
          () => TapGestureRecognizer(debugOwner: this),
          (r) => r.onTapUp = _onTapUp,
        ),
        LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
          () => LongPressGestureRecognizer(debugOwner: this),
          (r) => r.onLongPressStart = _onLongPressStart,
        ),
        ScaleGestureRecognizer: GestureRecognizerFactoryWithHandlers<ScaleGestureRecognizer>(
          () => ScaleGestureRecognizer(debugOwner: this, dragStartBehavior: DragStartBehavior.down),
          (r) => r
            ..onStart = _onScaleStart
            ..onUpdate = _onScaleUpdate
            ..onEnd = _onScaleEnd,
        ),
      },
      child: overlay,
    );
    overlay = Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) => _downs[e.pointer] = e.localPosition,
      onPointerUp: (e) => _pointerGone(e.pointer),
      onPointerCancel: (e) => _pointerGone(e.pointer, cancelled: true),
      onPointerPanZoomStart: (e) => _downs[e.pointer] = e.localPosition,
      onPointerPanZoomEnd: (e) => _pointerGone(e.pointer),
      child: overlay,
    );

    // The Semantics wrapper is always present so selecting an item mid-gesture never re-parents
    // (and so resets) the gesture recognizers below it.
    final selectedVisible = selectedItem != null && view.ready;
    final transform = selectedVisible && selectedItem is! SubtitleCue ? _transformOf(selectedItem, playhead.value) : null;
    overlay = Semantics(
      container: true,
      label: !selectedVisible
          ? null
          : cue
              ? ManipulationStrings.selectedCaptions
              : ManipulationStrings.selected(_kindOf(selectedItem), transform?.$1 ?? 1, transform?.$2 ?? 0),
      customSemanticsActions: selectedVisible ? _semanticsActions(cue) : null,
      child: overlay,
    );

    final menuAt = _menuAt;
    final platform = Theme.of(context).platform;
    return Stack(
      fit: StackFit.expand,
      children: [
        overlay,
        if (menuAt != null)
          Positioned(
            left: menuAt.dx,
            top: menuAt.dy,
            width: 1,
            height: 1,
            child: DanaviewMenuAnchor(
              entries: ref
                  .read(editorActionRegistryProvider)
                  .forPlatformOf(platform)
                  .menuEntries(WidgetActionContext(projectId: id, context: context, ref: ref), menuActions),
              onClose: () {
                if (mounted) setState(() => _menuAt = null);
              },
              builder: (context, open, _) {
                _openMenu = open;
                return const SizedBox.shrink();
              },
            ),
          ),
      ],
    );
  }

  ManipulationHandles? _handlesOfWith(EditProject project, ItemId? item, TimeUs t, Size size, TextMetricsProvider metrics) {
    if (item == null) return null;
    final loc = project.index.locate(item);
    if (loc == null || loc.track.hidden || !loc.track.kind.isVisual) return null;
    if (!(loc.item.start <= t && t < loc.item.end)) return null;
    final box = boxAt(project, item, t, text: metrics);
    if (box == null) return null;
    final cue = loc.item is SubtitleCue;
    return ManipulationHandles.layout(geometry: widget.geometry, box: box, view: size, touch: _touch, scalable: !cue, rotatable: !cue);
  }

  static (double, double)? _transformOf(TimelineItem item, TimeUs t) {
    // Audio clips have no visual properties; evaluating them throws.
    if (!PropertyKeys.scale.appliesToItem(item) || !PropertyKeys.rotation.appliesToItem(item)) return null;
    final local = (t - item.start).clamp(0, item.duration);
    return (evaluate(item, PropertyKeys.scale, local), evaluate(item, PropertyKeys.rotation, local));
  }

  static String _kindOf(TimelineItem item) => switch (item) {
        TextItem() => 'text',
        SubtitleCue() => 'caption',
        MediaClip() => 'clip',
      };
}

/// The slice of EditorState the overlay depends on.
@immutable
final class _OverlayView {
  const _OverlayView({required this.project, required this.primary, required this.safeGuides, required this.ready});

  static _OverlayView of(EditorState s) =>
      _OverlayView(project: s.project, primary: s.selection.primary, safeGuides: s.modes.safeGuides, ready: s.isReady);

  final EditProject? project;
  final ItemId? primary;
  final bool safeGuides;
  final bool ready;

  @override
  bool operator ==(Object other) =>
      other is _OverlayView &&
      identical(other.project, project) &&
      other.primary == primary &&
      other.safeGuides == safeGuides &&
      other.ready == ready;

  @override
  int get hashCode => Object.hash(identityHashCode(project), primary, safeGuides, ready);
}

/// Paints the handles of the selected item at the playhead (repaints with the playhead).
class _LivePainter extends CustomPainter {
  _LivePainter({
    required this.playhead,
    required this.project,
    required this.item,
    required this.resolve,
    required this.guides,
    required this.readout,
    required this.textScale,
  }) : super(repaint: playhead);

  final ValueListenable<TimeUs> playhead;
  final EditProject? project;
  final ItemId? item;
  final ManipulationHandles? Function(Size size, TimeUs t) resolve;
  final List<(Offset, Offset)> guides;
  final String? readout;
  final double textScale;

  @override
  void paint(Canvas canvas, Size size) {
    final handles = item == null ? null : resolve(size, playhead.value);
    ManipulationPainter(handles: handles, guides: guides, readout: handles == null ? null : readout, textScale: textScale).paint(canvas, size);
  }

  @override
  bool shouldRepaint(_LivePainter old) =>
      !identical(old.project, project) || old.item != item || old.readout != readout || old.guides.length != guides.length || old.guides != guides;
}
