// OWNER: UX-12
//
// TimelineView (ARCH §17.4, ux.md §8.1): the timeline region of the editor.
//
//   TimelineView (ConsumerStatefulWidget, project id from EditorScope)
//    ├─ Listener (wheel / trackpad scroll → TimelineGestureArbiter.handlePointerSignal)
//    │   └─ MouseRegion (hover cursors, the 600 ms name/duration pill)
//    │       └─ RawGestureDetector (TimelineGestureArbiter recognizers; headers and lanes)
//    │           └─ Row
//    │               ├─ header column: ruler corner + ProjectTrackHeaders (UX-11)
//    │               └─ Stack: TimelineRuler (UX-09) · TimelineCanvas (UX-10) · interaction layer
//    │                         (UX-13 slot, or TimelineBasicInteraction) · decoration slot under the
//    │                         ruler (UX-44 RenderMarkerStripHost) · PlayheadLayer (UX-10) ·
//    │                         TimelineSemanticsLayer (playhead slider, markers, transitions, keys)
//    ├─ multi-select banner ("3 selected · Select all on track · Done")
//    ├─ hover pill
//    └─ context menu (DanaviewMenuAnchor opened at the pointer)
//
// * The view links the viewport (UX-09) once it is laid out: size, content (duration, frame rate,
//   lane stack height), the project's saved ViewState (restore + sink), the playhead (centre-locked
//   scrolling scrubs through `scrubTo`/`endScrub`) and a vsync for flings. Nothing rebuilds per
//   frame: zoom, scroll and the playhead repaint the layers.
// * Taps select (Shift/⌘/Ctrl or touch multi-select mode toggles), seek on the ruler, select
//   markers, keyframes, gaps and transitions (opening the transition panel); a tap on a locked
//   clip says "This track is locked". Secondary clicks and long presses open context menus built
//   from the action registry.
// * Back (and Esc while the `escape` action is unbound) cancels a drag, then leaves multi-select
//   mode before the selection is cleared.
// * Thumbnails and waveforms come from `timelineContentHooksProvider` (UX-20/UX-21 or the
//   bootstrap override it) or the constructor.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' show Icons, Theme;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' as ops;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_messages.dart';
import '../../app/editor_providers.dart';
import '../actions/editor_action_registry.dart';
import '../caches/paragraph_cache.dart';
import '../contracts/contracts.dart';
import '../editor_lifecycle.dart' show EditorBackDispatcher, EditorBackStep;
import '../editor_scope.dart';
import '../layout/editor_layout.dart' show EditorLayoutSpec;
import '../layout/editor_layout_scope.dart';
import '../state/editor_controller.dart';
import '../state/editor_state.dart';
import '../state/playhead_controller.dart';
import 'playhead_layer.dart';
import 'render_marker_strip.dart' show RenderMarkerStrip, RenderMarkerStripHost;
import 'render_timeline_canvas.dart';
import 'ruler.dart';
import 'timeline_gestures.dart';
import 'timeline_hit.dart';
import 'timeline_metrics.dart';
import 'timeline_semantics.dart';
import 'timeline_snapshot.dart';
import 'timeline_style.dart';
import 'timeline_viewport.dart';
import 'track_headers.dart';

// -------------------------------------------------------------------------------------------------
// Copy
// -------------------------------------------------------------------------------------------------

/// Plain copy of the timeline view.
abstract final class TimelineViewStrings {
  /// Multi-select banner count.
  static String selected(int n) => '$n selected';

  /// Multi-select banner: select all on the lane.
  static const String selectAllOnTrack = 'Select all on track';

  /// Multi-select banner: leave the mode.
  static const String done = 'Done';

  /// Context menu: enter multi-select mode.
  static const String selectMultiple = 'Select multiple';

  /// Context menu on an empty lane.
  static const String pasteHere = 'Paste here';

  /// Context menu on an empty lane.
  static const String addMediaHere = 'Add media here';

  /// Context menu on an empty lane.
  static const String addTextHere = 'Add text here';

  /// Context menu on a keyframe.
  static const String deleteKeyframe = 'Delete keyframe';

  /// Context menu on the ruler.
  static const String addMarkerHere = 'Add marker here';

  /// Announced when multi-select mode starts.
  static const String multiSelectOn = 'Select multiple. Tap clips to add or remove them.';

  /// Announced when multi-select mode ends.
  static const String multiSelectOff = 'Done selecting';

  /// Announced when a clip is lifted.
  static const String lifted = 'Clip lifted. Drag to move it.';

  /// The hover pill: name and length.
  static String hover(String name, TimeUs duration) => '$name · ${Timecode.clock(duration)}';
}

// -------------------------------------------------------------------------------------------------
// Content hooks
// -------------------------------------------------------------------------------------------------

/// Thumbnail and waveform painters of the canvas (UX-20, UX-21).
@immutable
final class TimelineContentHooks {
  /// Creates the hooks.
  const TimelineContentHooks({this.thumbnails, this.waveforms});

  /// Thumbnail strips, or null for placeholder cells.
  final TimelineThumbnailHook? thumbnails;

  /// Waveforms, or null for centre lines.
  final TimelineWaveformHook? waveforms;
}

/// The canvas hooks of a project's timeline; none until UX-20/UX-21 (or the bootstrap) override it.
final timelineContentHooksProvider = Provider.autoDispose.family<TimelineContentHooks, ProjectId>(
  (ref, id) => const TimelineContentHooks(),
  name: 'timelineContentHooksProvider',
);

// -------------------------------------------------------------------------------------------------
// Widget
// -------------------------------------------------------------------------------------------------

/// Headers, ruler, canvas, interaction and playhead layers (ARCH §17.4).
class TimelineView extends ConsumerStatefulWidget {
  /// Creates the timeline of the project in `EditorScope`.
  const TimelineView({super.key, this.interaction, this.thumbnails, this.waveforms, this.style});

  /// The interaction slot to use instead of `interactionProvider`'s (tests, embedders).
  final TimelineInteractionSlot? interaction;

  /// Thumbnail hook instead of `timelineContentHooksProvider`'s.
  final TimelineThumbnailHook? thumbnails;

  /// Waveform hook instead of `timelineContentHooksProvider`'s.
  final TimelineWaveformHook? waveforms;

  /// Colours (default [TimelineStyle.standard]).
  final TimelineStyle? style;

  @override
  ConsumerState<TimelineView> createState() => TimelineViewState();
}

/// State of [TimelineView]; implements the arbiter's host. Public for tests.
class TimelineViewState extends ConsumerState<TimelineView> with TickerProviderStateMixin implements TimelineGestureHost {
  /// Hover time before the name/duration pill shows.
  static const Duration hoverDelay = Duration(milliseconds: 600);

  /// Routes the timeline's pointer input.
  late final TimelineGestureArbiter arbiter = TimelineGestureArbiter(this);
  late final Map<Type, GestureRecognizerFactory> _gestures = arbiter.gestures;
  final GlobalKey _canvasKey = GlobalKey(debugLabel: 'TimelineCanvas');
  final GlobalKey _rootKey = GlobalKey(debugLabel: 'TimelineView');
  final ParagraphCache _paragraphs = ParagraphCache();
  final ValueNotifier<MouseCursor> _cursor = ValueNotifier<MouseCursor>(MouseCursor.defer);
  final ValueNotifier<_HoverPill?> _hover = ValueNotifier<_HoverPill?>(null);
  Timer? _hoverTimer;

  ProjectId? _id;
  TimelineViewportController? _viewport;
  PlayheadController? _playhead;
  EditorController? _controller;
  TimelineSnapshot _snapshot = TimelineSnapshot.empty;
  TimelineMetrics _metrics = const TimelineMetrics();
  TimelineCanvasGeometry? _geometry;
  TimelineInteractionSlot? _slot;
  TimelineBasicInteraction? _basic;
  TimelineDragDelegate? _dragDelegate;
  bool _scrubbing = false;
  TimelineItemSemantics? _itemSemantics;
  TimelineSemanticsCallbacks? _semanticsCallbacks;

  // Layout link with the viewport.
  (Size, double, double)? _layout;
  (TimelineSnapshot, TimelineMetrics)? _content;
  bool _linkScheduled = false;

  // Back handling.
  final List<VoidCallback> _unregister = [];
  EditorBackDispatcher? _dispatcher;

  // Context menu.
  _MenuRequest? _menu;
  int _menuSerial = 0;
  VoidCallback? _openMenu;
  int _openedSerial = -1;

  /// The interaction that handles drags no slot takes (tests).
  TimelineBasicInteraction get basicInteraction => _basic ??= TimelineBasicInteraction(
        controller: () => _controller!,
        state: _state,
        snapshot: () => _snapshot,
        geometry: () => _geometry,
        viewport: _viewport!,
      );

  EditorState _state() => ref.read(editorControllerProvider(_id!));

  /// The canvas render object, once laid out.
  RenderTimelineCanvas? get canvas {
    final ro = _canvasKey.currentContext?.findRenderObject();
    return ro is RenderTimelineCanvas && ro.attached ? ro : null;
  }

  @override
  TimelineViewportController get viewport => _viewport!;

  // ---- Lifecycle --------------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final dispatcher = EditorBackDispatcher.maybeOf(context);
    if (!identical(dispatcher, _dispatcher)) {
      for (final u in _unregister) {
        u();
      }
      _unregister.clear();
      _dispatcher = dispatcher;
      if (dispatcher != null) {
        _unregister
          ..add(dispatcher.register(EditorBackStep.cancelGesture, arbiter.cancel))
          ..add(dispatcher.register(EditorBackStep.clearSelection, _exitMultiSelect));
      }
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    for (final u in _unregister) {
      u();
    }
    arbiter.cancel();
    _hoverTimer?.cancel();
    _unlinkViewport();
    _basic?.dispose();
    _paragraphs.dispose();
    _cursor.dispose();
    _hover.dispose();
    super.dispose();
  }

  void _linkViewport(TimelineViewportController viewport, PlayheadController playhead, EditorController controller) {
    if (identical(viewport, _viewport) && identical(playhead, _playhead) && identical(controller, _controller)) return;
    _unlinkViewport();
    _viewport = viewport;
    _playhead = playhead;
    _controller = controller;
    _layout = null;
    _content = null;
    _basic?.dispose();
    _basic = null;
    _itemSemantics = TimelineItemSemantics(
      controller: () => _controller!,
      state: _state,
      playhead: playhead,
      announce: _announce,
    );
    _semanticsCallbacks = TimelineSemanticsCallbacks(
      seek: _seek,
      selectMarker: (m) {
        _controller?.selectMarker(m.id);
        _seek(m.time);
      },
      openTransition: _openTransition,
      selectKeyframe: _selectKeyframe,
    );
    // Attaching notifies the viewport's listeners: done after the frame (_applyLink).
    _attached = false;
    _scheduleLink();
  }

  bool _attached = false;

  void _attach() {
    final viewport = _viewport, playhead = _playhead, controller = _controller;
    if (_attached || viewport == null || playhead == null || controller == null) return;
    _attached = true;
    viewport
      ..attachVsync(this)
      ..attachViewSink(controller.updateView)
      ..attachPlayhead(
        playhead,
        playing: playhead.playing,
        onScrub: playhead.scrubTo,
        onScrubEnd: () => unawaited(playhead.endScrub()),
      );
  }

  void _unlinkViewport() {
    final v = _viewport;
    if (v == null || !_attached) return;
    _attached = false;
    v.detachPlayhead();
    v.attachVsync(null);
  }

  /// Sends size and content to the viewport after the frame (listeners may rebuild widgets).
  void _scheduleLink() {
    if (_linkScheduled) return;
    _linkScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _linkScheduled = false;
      if (!mounted) return;
      _applyLink();
    });
  }

  void _applyLink() {
    final viewport = _viewport;
    if (viewport == null) return;
    _attach();
    final layout = _layout;
    if (layout != null) {
      final (size, header, ruler) = layout;
      if (viewport.lanesWidth != math.max(0.0, size.width - header) ||
          viewport.lanesHeight != math.max(0.0, size.height - ruler) ||
          viewport.headerWidth != header ||
          viewport.rulerHeight != ruler) {
        viewport.setViewport(size, header, rulerHeight: ruler);
      }
    }
    final content = _content;
    if (content != null) {
      final (snapshot, metrics) = content;
      final height = TimelineLaneStack.of(snapshot.laneKinds, metrics, presets: snapshot.laneHeights).contentHeight;
      if (viewport.duration != snapshot.duration || viewport.frameRate != snapshot.frameRate || viewport.contentHeight != height) {
        viewport.setContent(duration: snapshot.duration, frameRate: snapshot.frameRate, contentHeight: height);
      }
    }
    final project = _state().project;
    if (project != null && !viewport.restored) viewport.restore(project.view);
  }

  // ---- Keys and back ----------------------------------------------------------------------------

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.escape || !mounted || _id == null) return false;
    // With the `escape` action bound, Esc runs the back steps (which include ours).
    final registry = ref.read(editorActionRegistryProvider);
    if (registry.spec(EditorActionId.escape).isBound) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    return arbiter.cancel() || _exitMultiSelect();
  }

  bool _exitMultiSelect() {
    final c = _controller;
    if (c == null || !mounted || !_state().modes.multiSelect) return false;
    c.setModes((m) => m.copyWith(multiSelect: false));
    _announce(TimelineViewStrings.multiSelectOff);
    return true;
  }

  void _enterMultiSelect(ItemId? item) {
    final c = _controller;
    if (c == null) return;
    if (item != null && !_state().selection.items.contains(item)) c.select(item);
    c.setModes((m) => m.copyWith(multiSelect: true));
    _announce(TimelineViewStrings.multiSelectOn);
  }

  void _announce(String message) {
    if (mounted) editorAnnounce(context, message);
  }

  // ---- TimelineGestureHost ----------------------------------------------------------------------

  @override
  TimelineHit? hitAt(Offset global) {
    final box = canvas;
    if (box == null || !box.hasSize || _viewport == null || !_viewport!.hasLayout) return null;
    final local = box.globalToLocal(global);
    if (local.dx < 0 || local.dx > box.size.width || local.dy > box.size.height || local.dy < -_metrics.rulerHeight) return null;
    return box.hitTestTimeline(local);
  }

  @override
  Offset toCanvas(Offset global) => canvas?.globalToLocal(global) ?? global;

  @override
  void onTimelineTap(TimelineHit hit, TimelineTapDetails details) {
    final c = _controller;
    if (c == null) return;
    final state = _state();
    switch (hit) {
      case HitItem(:final item, :final lane, :final locked):
        if (locked) {
          _showLocked(lane);
          return;
        }
        final toggle = details.toggle || state.modes.multiSelect;
        c.select(item, mode: toggle ? SelectMode.toggle : SelectMode.replace);
        if (state.modes.multiSelect) _announce(TimelineViewStrings.selected(_state().selection.items.length));
      case HitKeyframe(:final ref):
        _selectKeyframe(ref);
      case HitMarker(:final id):
        c.selectMarker(id);
        final marker = _snapshot.markers.where((m) => m.id == id).firstOrNull;
        if (marker != null) _seek(marker.time);
      case HitRuler(:final time):
        _seek(time);
      case HitTransition(:final ref):
        _openTransition(ref);
      case HitGap(:final lane, :final gap):
        c.selectGap(ops.GapRef(lane, gap));
      case HitEmpty():
        if (!state.modes.multiSelect) c.clearSelection();
      case HitPlayheadKnob() || HitTrimHandle() || HitFadeHandle():
        break;
    }
  }

  void _selectKeyframe(KeyframeRef ref) {
    _controller?.selectKeyframe(ref);
    final item = _snapshot.item(ref.item);
    if (item != null) _seek(item.start + ref.t);
  }

  void _openTransition(TransitionRef ref) {
    final c = _controller;
    if (c == null) return;
    c.selectTransition(ref);
    c.openInspector(TransitionInspector(ref));
  }

  void _seek(TimeUs t) {
    final p = _playhead;
    if (p == null) return;
    final rate = _snapshot.frameRate;
    unawaited(p.seekExact(rate.quantize(t.clamp(0, math.max(0, _snapshot.duration)).toInt())));
  }

  void _showLocked(TrackId lane) {
    final m = EditorMessages.forRejection(ops.TrackLocked(lane));
    final text = m.detail == null ? m.title : '${m.title}. ${m.detail}';
    DanaviewToast.show(context, text, icon: Icons.lock_rounded);
    HapticFeedback.selectionClick();
    _announce(m.title);
  }

  @override
  void onTimelineContextMenu(TimelineHit hit, Offset globalPosition) {
    final c = _controller;
    final id = _id;
    if (c == null || id == null) return;
    final registry = ref.read(editorActionRegistryProvider).forPlatformOf(Theme.of(context).platform);
    final ctx = WidgetActionContext(projectId: id, context: context, ref: ref, source: EditorActionSource.contextMenu);
    final touch = _metrics.touch;
    final entries = <DanaviewMenuEntry>[];

    DanaviewMenuItem atTime(String label, IconData icon, EditorActionId action, TimeUs t) {
      final spec = registry.spec(action);
      final enabled = spec.isEnabled(ctx);
      return DanaviewMenuItem(
        label: label,
        icon: icon,
        enabled: enabled,
        subtitle: enabled ? null : spec.disabledReason(ctx),
        onTap: () {
          _seek(t);
          registry.invoke(action, ctx);
        },
      );
    }

    switch (hit) {
      case HitItem(:final item, :final lane, :final locked):
        if (locked) {
          _showLocked(lane);
          return;
        }
        if (!_state().selection.items.contains(item)) c.select(item);
        if (touch && !_state().modes.multiSelect) {
          // First on touch: the way into multi-select mode (ux.md §8.9).
          entries
            ..add(DanaviewMenuItem(
              label: TimelineViewStrings.selectMultiple,
              icon: Icons.checklist_rounded,
              onTap: () => _enterMultiSelect(item),
            ))
            ..add(const DanaviewMenuDivider());
        }
        entries.addAll(registry.menuEntries(
            ctx,
            const [
              EditorActionId.split,
              EditorActionId.copy,
              EditorActionId.cut,
              EditorActionId.duplicate,
              EditorActionId.moveToTrack,
              EditorActionId.clipInfo,
              EditorActionId.delete,
              EditorActionId.rippleDelete,
            ],
            destructive: (a) => a == EditorActionId.delete || a == EditorActionId.rippleDelete));
      case HitEmpty(:final lane, :final time) when lane != null:
        entries.addAll([
          atTime(TimelineViewStrings.pasteHere, Icons.content_paste_rounded, EditorActionId.paste, time),
          atTime(TimelineViewStrings.addMediaHere, Icons.video_library_rounded, EditorActionId.media, time),
          atTime(TimelineViewStrings.addTextHere, Icons.title_rounded, EditorActionId.addText, time),
        ]);
      case HitGap(:final lane, :final gap):
        c.selectGap(ops.GapRef(lane, gap));
        entries.addAll([
          ...registry.menuEntries(ctx, const [EditorActionId.deleteGap]),
          atTime(TimelineViewStrings.pasteHere, Icons.content_paste_rounded, EditorActionId.paste, gap.start),
          atTime(TimelineViewStrings.addMediaHere, Icons.video_library_rounded, EditorActionId.media, gap.start),
        ]);
      case HitMarker(:final id):
        c.selectMarker(id);
        entries.addAll(registry.menuEntries(ctx, const [EditorActionId.editMarker, EditorActionId.deleteMarker],
            destructive: (a) => a == EditorActionId.deleteMarker));
      case HitKeyframe(:final ref):
        c.selectKeyframe(ref);
        entries.addAll(registry.menuEntries(ctx, const [EditorActionId.keyframes]));
        entries.add(DanaviewMenuItem(
          label: TimelineViewStrings.deleteKeyframe,
          icon: Icons.delete_outline_rounded,
          destructive: true,
          onTap: () => c.apply(ops.RemoveKeyframe(ref)),
        ));
      case HitTransition(:final ref):
        c.selectTransition(ref);
        entries.addAll(registry.menuEntries(ctx, const [EditorActionId.transitions]));
      case HitRuler(:final time):
        entries.add(atTime(TimelineViewStrings.addMarkerHere, Icons.bookmark_add_rounded, EditorActionId.addMarker, time));
      case HitEmpty() || HitPlayheadKnob() || HitTrimHandle() || HitFadeHandle():
        break;
    }
    if (entries.isEmpty) return;
    showContextMenu(globalPosition, entries);
  }

  /// Opens a context menu with [entries] at [globalPosition].
  void showContextMenu(Offset globalPosition, List<DanaviewMenuEntry> entries) {
    final box = _rootKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final local = box.globalToLocal(globalPosition);
    setState(() => _menu = _MenuRequest(++_menuSerial, local, entries));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final m = _menu;
      if (!mounted || m == null || m.serial == _openedSerial) return;
      _openedSerial = m.serial;
      _openMenu?.call();
    });
  }

  /// Whether a context menu is shown (tests).
  bool get menuOpen => _menu != null;

  void _closeMenu(int serial) {
    if (!mounted || _menu?.serial != serial) return;
    setState(() => _menu = null);
  }

  TimelineDragDelegate? _delegateFor(TimelineDragKind kind) {
    final slot = _slot;
    if (slot != null && slot.canDrag(kind)) return slot;
    final basic = basicInteraction;
    return basic.canDrag(kind) ? basic : null;
  }

  @override
  bool onTimelineDragStart(TimelineDragStart start) {
    _hideHover();
    if (_controller == null) return false;
    if (start.kind == TimelineDragKind.scrub) {
      final p = _playhead;
      if (p == null) return false;
      _scrubbing = true;
      p.beginScrub();
      _scrubTo(start.time);
      return true;
    }
    final delegate = _delegateFor(start.kind);
    if (delegate == null || !delegate.beginDrag(start)) return false;
    _dragDelegate = delegate;
    if (start.lifted) {
      HapticFeedback.mediumImpact();
      _announce(TimelineViewStrings.lifted);
    }
    _cursor.value = SystemMouseCursors.grabbing;
    return true;
  }

  void _scrubTo(TimeUs t) {
    final p = _playhead;
    if (p == null) return;
    p.scrubTo(_snapshot.frameRate.quantize(t.clamp(0, math.max(0, _snapshot.duration)).toInt()));
  }

  @override
  void onTimelineDragUpdate(TimelineDragUpdate update) {
    if (_scrubbing) {
      _scrubTo(update.time);
      return;
    }
    _dragDelegate?.updateDrag(update);
  }

  @override
  void onTimelineDragEnd({required bool cancelled}) {
    if (_scrubbing) {
      _scrubbing = false;
      unawaited(_playhead?.endScrub());
      return;
    }
    final d = _dragDelegate;
    _dragDelegate = null;
    d?.endDrag(cancelled: cancelled);
    _cursor.value = MouseCursor.defer;
  }

  /// Semantics scroll actions: 80 % of the lanes area per step.
  void _scrollPage(int x, int y) {
    final v = _viewport;
    if (v == null || !v.hasLayout) return;
    v.scrollByPx(x * v.lanesWidth * 0.8, y * v.lanesHeight * 0.8);
  }

  // ---- Hover ------------------------------------------------------------------------------------

  void _onHover(PointerHoverEvent e) {
    final hit = hitAt(e.position);
    final cursor = arbiter.cursorFor(hit);
    if (_cursor.value != cursor) _cursor.value = cursor;
    if (hit is HitItem) {
      final current = _hover.value;
      if (current != null && current.item == hit.item) return;
      _hideHover();
      final box = _rootKey.currentContext?.findRenderObject();
      final local = box is RenderBox ? box.globalToLocal(e.position) : e.localPosition;
      _hoverTimer = Timer(hoverDelay, () {
        if (!mounted) return;
        final model = _snapshot.item(hit.item);
        if (model == null) return;
        final name = model.label.isEmpty ? TimelineCanvasStrings.kindName(model.kind) : model.label;
        _hover.value = _HoverPill(hit.item, local, TimelineViewStrings.hover(name, model.duration));
      });
    } else {
      _hideHover();
    }
  }

  void _hideHover() {
    _hoverTimer?.cancel();
    _hoverTimer = null;
    if (_hover.value != null) _hover.value = null;
  }

  // ---- Build ------------------------------------------------------------------------------------

  TimelineInteractionSlot? _slotFrom(ProjectId id) {
    try {
      final c = ref.watch(interactionProvider(id));
      return c is TimelineInteractionSlot ? c as TimelineInteractionSlot : null;
    } catch (_) {
      // UX-13 has not landed (its factory throws): drags use TimelineBasicInteraction.
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final id = EditorScope.idOf(context);
    _id = id;
    final controller = ref.watch(editorControllerProvider(id).notifier);
    final viewport = ref.watch(viewportProvider(id));
    final playhead = ref.watch(playheadProvider(id));
    _linkViewport(viewport, playhead, controller);
    final snapshot = ref.watch(timelineSnapshotProvider(id));
    final selection = ref.watch(editorControllerProvider(id).select((s) => s.selection));
    final modes = ref.watch(editorControllerProvider(id).select((s) => s.modes));
    final showAllKeyframes = ref.watch(editorControllerProvider(id).select((s) => s.inspector is KeyframesInspector));
    ref.watch(editorControllerProvider(id).select((s) => s.phase == EditorPhase.ready));
    final hooks = ref.watch(timelineContentHooksProvider(id));
    _slot = widget.interaction ?? _slotFrom(id);

    final spec = EditorLayoutScope.maybeOf(context);
    final touch = spec?.touch ?? context.isTouchPlatform;
    final kind = spec?.kind ?? EditorLayoutSpec.kindFor(MediaQuery.sizeOf(context));
    var metrics =
        TimelineMetrics.resolve(textScaler: MediaQuery.textScalerOf(context), kind: kind, touch: touch, laneHeight: modes.laneHeight);
    if (spec != null) metrics = metrics.copyWith(headerWidth: spec.headerWidth);
    if (_geometry == null || !identical(snapshot, _snapshot) || metrics != _metrics || !identical(_geometry!.viewport, viewport)) {
      _geometry = TimelineCanvasGeometry(snapshot: snapshot, metrics: metrics, viewport: viewport);
    }
    _snapshot = snapshot;
    _metrics = metrics;
    final style = widget.style ?? TimelineStyle.standard;
    final header = metrics.headerWidth;
    final ruler = metrics.rulerHeight;
    final interaction = _slot ?? basicInteraction;

    final content = (snapshot, metrics);
    if (_content == null || !identical(_content!.$1, snapshot) || _content!.$2 != metrics) {
      _content = content;
      _scheduleLink();
    }

    return LayoutBuilder(
      key: _rootKey,
      builder: (context, constraints) {
        final size = constraints.biggest;
        final layout = (size, header, ruler);
        if (size.isFinite && _layout != layout) {
          _layout = layout;
          _scheduleLink();
        }
        final lanes = Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: ruler,
              child: TimelineRuler(
                  viewport: viewport, markers: snapshot.markers, selectedMarker: selection.marker, style: style, metrics: metrics),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: ruler,
              bottom: 0,
              child: TimelineCanvas(
                key: _canvasKey,
                snapshot: snapshot,
                viewport: viewport,
                selection: selection,
                thumbnails: widget.thumbnails ?? hooks.thumbnails,
                waveforms: widget.waveforms ?? hooks.waveforms,
                paragraphs: _paragraphs,
                style: style,
                metrics: metrics,
                interaction: interaction,
                playhead: playhead,
                showAllKeyframes: showAllKeyframes,
                semanticsDecorator: _itemSemantics!.decorate,
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: interaction.buildLayer(
                  context,
                  TimelineLayerContext(snapshot: snapshot, viewport: viewport, metrics: metrics, style: style),
                ),
              ),
            ),
            // Decoration slot under the ruler: UX-44's render marker strip (D-45). It collapses to
            // nothing while the project has no render-preview coverage.
            Positioned(
              key: const ValueKey('timeline-ruler-decoration'),
              left: 0,
              right: 0,
              top: ruler,
              height: RenderMarkerStrip.defaultHeight,
              child: RenderMarkerStripHost(projectId: id),
            ),
            Positioned.fill(
                child: IgnorePointer(child: PlayheadLayer(viewport: viewport, playhead: playhead, style: style, metrics: metrics))),
            Positioned.fill(
              child: TimelineSemanticsLayer(
                snapshot: snapshot,
                viewport: viewport,
                metrics: metrics,
                playhead: playhead,
                playing: playhead.playing,
                selection: selection,
                showAllKeyframes: showAllKeyframes,
                callbacks: _semanticsCallbacks!,
              ),
            ),
          ],
        );
        final surface = Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: header,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(height: ruler, child: ColoredBox(color: style.rulerBackground)),
                  Expanded(child: ClipRect(child: ProjectTrackHeaders(projectId: id))),
                ],
              ),
            ),
            Expanded(
              child: Semantics(
                container: true,
                onScrollLeft: () => _scrollPage(1, 0),
                onScrollRight: () => _scrollPage(-1, 0),
                onScrollUp: () => _scrollPage(0, 1),
                onScrollDown: () => _scrollPage(0, -1),
                child: lanes,
              ),
            ),
          ],
        );
        return ColoredBox(
          color: style.laneBackground,
          child: DefaultTextStyle(
            style: DanaviewTextStyles.body.copyWith(fontFamily: DanaviewFonts.family, color: DanaviewColors.textPrimary),
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned.fill(
                  child: Listener(
                    onPointerSignal: arbiter.handlePointerSignal,
                    child: ValueListenableBuilder<MouseCursor>(
                      valueListenable: _cursor,
                      builder: (context, cursor, child) => MouseRegion(
                        cursor: cursor,
                        onHover: _onHover,
                        onExit: (_) => _hideHover(),
                        child: child,
                      ),
                      child: RawGestureDetector(gestures: _gestures, behavior: HitTestBehavior.opaque, child: surface),
                    ),
                  ),
                ),
                if (modes.multiSelect)
                  Positioned(
                    left: DanaviewSpacing.sm,
                    right: DanaviewSpacing.sm,
                    top: ruler + DanaviewSpacing.xs,
                    child: _MultiSelectBanner(
                      count: selection.items.length,
                      onSelectAll: selection.lane == null ? null : () => _controller?.selectAll(lane: selection.lane),
                      onDone: _exitMultiSelect,
                    ),
                  ),
                ValueListenableBuilder<_HoverPill?>(
                  valueListenable: _hover,
                  builder: (context, pill, _) => pill == null ? const SizedBox.shrink() : _HoverPillView(pill: pill, bounds: size),
                ),
                if (_menu != null) _buildMenu(_menu!),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildMenu(_MenuRequest m) => Positioned(
        left: m.position.dx,
        top: m.position.dy,
        width: 1,
        height: 1,
        child: DanaviewMenuAnchor(
          key: ValueKey<int>(m.serial),
          entries: m.entries,
          onClose: () => _closeMenu(m.serial),
          builder: (context, open, isOpen) {
            _openMenu = open;
            return const SizedBox.expand();
          },
        ),
      );
}

// -------------------------------------------------------------------------------------------------
// Parts
// -------------------------------------------------------------------------------------------------

@immutable
final class _MenuRequest {
  const _MenuRequest(this.serial, this.position, this.entries);

  final int serial;
  final Offset position;
  final List<DanaviewMenuEntry> entries;
}

@immutable
final class _HoverPill {
  const _HoverPill(this.item, this.position, this.text);

  final ItemId item;
  final Offset position;
  final String text;
}

class _HoverPillView extends StatelessWidget {
  const _HoverPillView({required this.pill, required this.bounds});

  static const double maxWidth = 240;

  final _HoverPill pill;
  final Size bounds;

  @override
  Widget build(BuildContext context) {
    final width = math.min(maxWidth, bounds.width);
    final left = (pill.position.dx + 12).clamp(0.0, math.max(0.0, bounds.width - width)).toDouble();
    final top = math.max(0.0, pill.position.dy - 40);
    return Positioned(
      left: left,
      top: top,
      width: width,
      child: IgnorePointer(
        child: Align(
          alignment: Alignment.centerLeft,
          child: DanaviewSurface(
            color: DanaviewColors.surfaceElevatedHigher,
            borderRadius: DanaviewRadius.smAll,
            shadow: DanaviewShadow.soft,
            padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.sm, vertical: DanaviewSpacing.xs),
            child: Text(
              pill.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: DanaviewTextStyles.caption.copyWith(fontFamily: DanaviewFonts.family, color: DanaviewColors.textPrimary),
            ),
          ),
        ),
      ),
    );
  }
}

/// "3 selected · Select all on track · Done" over the timeline (multi-select mode on touch).
class _MultiSelectBanner extends StatelessWidget {
  const _MultiSelectBanner({required this.count, required this.onSelectAll, required this.onDone});

  /// Below this width "Select all on track" becomes an icon button.
  static const double compactBelow = 380;

  final int count;
  final VoidCallback? onSelectAll;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final label = Text(
      TimelineViewStrings.selected(count),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: DanaviewTextStyles.label.copyWith(fontFamily: DanaviewFonts.family, color: DanaviewColors.textPrimary),
    );
    return Align(
      alignment: Alignment.topCenter,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < compactBelow;
          return Semantics(
            container: true,
            liveRegion: true,
            child: DanaviewSurface(
              color: DanaviewColors.surfaceElevatedHigher,
              borderRadius: DanaviewRadius.mdAll,
              shadow: DanaviewShadow.soft,
              padding:
                  const EdgeInsets.only(left: DanaviewSpacing.md, right: DanaviewSpacing.xs, top: DanaviewSpacing.xxs, bottom: DanaviewSpacing.xxs),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(child: label),
                  const SizedBox(width: DanaviewSpacing.xs),
                  if (compact)
                    DanaviewIconButton(
                      icon: Icons.select_all_rounded,
                      onPressed: onSelectAll,
                      size: 36,
                      tooltip: TimelineViewStrings.selectAllOnTrack,
                      semanticLabel: TimelineViewStrings.selectAllOnTrack,
                    )
                  else
                    DanaviewButton.ghost(label: TimelineViewStrings.selectAllOnTrack, onPressed: onSelectAll, size: DanaviewButtonSize.sm),
                  const SizedBox(width: DanaviewSpacing.xxs),
                  DanaviewButton.tonal(label: TimelineViewStrings.done, onPressed: onDone, size: DanaviewButtonSize.sm),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
