// OWNER: UX-36
//
// TimelineDropTarget (ux.md §15.3, D-18): the timeline accepts media dragged from the bin and files
// dropped from other apps.
//
// * In-app: a `DragTarget<MediaDragData>` around the timeline. While a card is over it, every
//   pointer move turns the pointer into a start time (snapped to cuts, markers and the playhead
//   within 8 px with a pointer, 12 px on touch; Alt/snapping-off disables it) and a lane (the lane
//   under the pointer when it takes the media, else the default lane), builds the same
//   `InsertMedia` command the drop will apply (`MediaOperations.insertCommand`) and dry-runs it:
//   the drop ghost is the placements of that dry run (a red ghost when the drop would be refused,
//   a "New track" pill when it creates a lane), so the ghost is exactly what the drop commits. A
//   drop applies the command as one history entry; a refused drop applies it once anyway so the
//   editor explains why (toast, haptic) and records nothing.
// * Auto-scroll: within 48 px of an edge of the lanes the timeline scrolls (up to 1.5 viewports per
//   second) and the ghost follows the pointer's new time.
// * External: while the editor is visible (the timeline is mounted and not covered by an opaque
//   route) the target enables `engine.drops`; a drop is
//   imported as managed copies through UX-06's ImportMediaSheet (free-space preflight, progress,
//   cancel) and the imported media is placed at the drop position (time and lane under it; at the
//   playhead when it landed outside the lanes). Drops that arrive while an import is running wait
//   for their turn.
// * Desktop drag (later) reuses this target: it only needs a pointer position.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show EditorEngine, ExternalDrop;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../../app/strings/edit_strings.dart';
import '../../app/strings/media_strings.dart';
import '../actions/bindings/media_bindings.dart';
import '../editor_scope.dart';
import '../flows/import_media_sheet.dart';
import '../layout/editor_layout.dart' show EditorLayoutSpec;
import '../layout/editor_layout_scope.dart';
import '../state/editor_controller.dart' show EditApplied;
import '../state/editor_state.dart' show EditorState;
import 'snapping.dart';
import 'timeline_hit.dart' show TimelineCanvasGeometry;
import 'timeline_metrics.dart';
import 'timeline_semantics.dart' show editorAnnounce;
import 'timeline_style.dart';
import 'timeline_viewport.dart';

/// What a media bin card carries while it is dragged (ux.md §10.1).
@immutable
final class MediaDragData {
  /// Creates the payload: [media] of [project], shown in the drag feedback as [label].
  MediaDragData({required this.project, required List<MediaId> media, this.label = ''}) : media = List.unmodifiable(media);

  /// The project whose pool holds [media] (a drag from another editor is not accepted).
  final ProjectId project;

  /// The dragged assets, in timeline order.
  final List<MediaId> media;

  /// Name shown in the drag feedback.
  final String label;

  @override
  String toString() => 'MediaDragData($project, $media)';
}

/// Where a drag would land: what the ghost draws and what the drop commits.
@immutable
final class DropGhost {
  /// Creates the ghost.
  DropGhost({
    required this.command,
    required this.start,
    required this.pointer,
    Map<ItemId, Placement> placements = const {},
    Map<ItemId, Placement> shifted = const {},
    this.lane,
    this.rejection,
    this.guide,
  })  : placements = Map.unmodifiable(placements),
        shifted = Map.unmodifiable(shifted);

  /// The command the drop applies.
  final EditCommand command;

  /// The snapped start time of the first clip.
  final TimeUs start;

  /// The pointer, relative to the timeline area.
  final Offset pointer;

  /// Where each new clip lands (from `dryRun`).
  final Map<ItemId, Placement> placements;

  /// Existing clips the drop moves (a ripple insert pushes the later clips right), at their new
  /// places.
  final Map<ItemId, Placement> shifted;

  /// The lane the pointer is over and the media was offered, or null for the default lane.
  final TrackId? lane;

  /// Why the drop would be refused, or null.
  final EditRejection? rejection;

  /// The snap target in reach, or null.
  final SnapGuide? guide;

  /// Whether the drop would be accepted.
  bool get valid => rejection == null && placements.isNotEmpty;

  /// Whether the drop creates a lane (D-11).
  bool get createsTrack => placements.values.any((p) => p.onNewTrack);

  @override
  String toString() => 'DropGhost(${placements.length} placed at $start${valid ? '' : ', refused'})';
}

/// Accepts media dragged from the bin and files dropped from other apps (see the file header).
class TimelineDropTarget extends ConsumerStatefulWidget {
  /// Wraps the timeline [child].
  const TimelineDropTarget({super.key, required this.child});

  /// The timeline.
  final Widget child;

  @override
  ConsumerState<TimelineDropTarget> createState() => TimelineDropTargetState();
}

/// State of [TimelineDropTarget]; public so tests can read the ghost.
class TimelineDropTargetState extends ConsumerState<TimelineDropTarget> with SingleTickerProviderStateMixin {
  static const double _maxAutoScrollViewportsPerSecond = 1.5;

  final GlobalKey _area = GlobalKey(debugLabel: 'TimelineDropTarget');
  final ValueNotifier<DropGhost?> _ghost = ValueNotifier<DropGhost?>(null);

  EditorEngine? _engine;
  StreamSubscription<ExternalDrop>? _drops;
  Future<void> _dropQueue = Future<void>.value();
  TimelineSnapping? _snap;
  MediaDragData? _data;
  Offset? _lastGlobal;
  Ticker? _ticker;
  Duration _lastTick = Duration.zero;
  Offset _scrollVelocity = Offset.zero;
  bool _dropsEnabled = false;
  bool _disposed = false;

  /// The drop ghost of the drag in progress, or null.
  DropGhost? get ghost => _ghost.value;

  /// Whether a card is being dragged over the timeline.
  bool get isDragging => _data != null;

  @override
  void initState() {
    super.initState();
    final EditorEngine engine = ref.read(editorEngineProvider);
    _engine = engine;
    _drops = engine.drops.drops.listen(_onExternalDrop, onError: (Object _) {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // External drops are accepted while the editor is visible: the timeline is mounted and no
    // opaque route (Settings, a full-screen player) covers it (`TickerMode` follows that).
    final visible = TickerMode.valuesOf(context).enabled;
    final engine = _engine;
    if (engine != null && visible != _dropsEnabled) {
      _dropsEnabled = visible;
      unawaited(_enableDrops(engine, visible));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _stopAutoScroll();
    _ticker?.dispose();
    _ticker = null;
    unawaited(_drops?.cancel());
    final engine = _engine;
    if (engine != null && _dropsEnabled) unawaited(_enableDrops(engine, false));
    _snap?.release();
    _ghost.dispose();
    super.dispose();
  }

  Future<void> _enableDrops(EditorEngine engine, bool on) async {
    try {
      await engine.drops.setEnabled(on);
    } on Object catch (e) {
      debugPrint('[Drop] Could not ${on ? 'enable' : 'disable'} external drops: ${e.runtimeType}');
    }
  }

  // ---- Geometry ---------------------------------------------------------------------------------

  ProjectId get _id => EditorScope.idOf(context);

  MediaOperations get _ops => MediaOperations.forProject(_id, ref.read);

  RenderBox? get _box {
    final ro = _area.currentContext?.findRenderObject();
    return ro is RenderBox && ro.hasSize ? ro : null;
  }

  /// The timeline's metrics, resolved like `TimelineView` does.
  TimelineMetrics _metrics(EditorState state) {
    final spec = EditorLayoutScope.maybeOf(context);
    final touch = spec?.touch ?? context.isTouchPlatform;
    final kind = spec?.kind ?? EditorLayoutSpec.kindFor(MediaQuery.sizeOf(context));
    var metrics =
        TimelineMetrics.resolve(textScaler: MediaQuery.textScalerOf(context), kind: kind, touch: touch, laneHeight: state.modes.laneHeight);
    if (spec != null) metrics = metrics.copyWith(headerWidth: spec.headerWidth);
    return metrics;
  }

  /// The pointer at [global] as a position in the lanes: null when the timeline is not laid out.
  ({Offset local, double x, double y})? _lanesPosition(Offset global, TimelineMetrics metrics, TimelineViewportController viewport) {
    final box = _box;
    if (box == null || !viewport.hasLayout) return null;
    final local = box.globalToLocal(global);
    final header = viewport.headerWidth > 0 ? viewport.headerWidth : metrics.headerWidth;
    final ruler = viewport.rulerHeight > 0 ? viewport.rulerHeight : metrics.rulerHeight;
    return (local: local, x: local.dx - header, y: local.dy - ruler);
  }

  /// What a drop of [data] at [global] would do (null when it cannot be computed).
  DropGhost? _plan(Offset global, MediaDragData data) {
    final state = ref.read(editorControllerProvider(_id));
    final project = state.project;
    if (project == null) return null;
    final viewport = ref.read(viewportProvider(_id));
    final metrics = _metrics(state);
    final pos = _lanesPosition(global, metrics, viewport);
    if (pos == null) return null;
    final ops = _ops;
    final assets = ops.placeable(data.media);
    if (assets.isEmpty) return null;

    final rate = project.settings.frameRate;
    var start = math.max(0, rate.quantizeNearest(viewport.timeAt(math.max(0, pos.x)))).toInt();
    final snap = _snap;
    if (snap != null) {
      final length = _lengthOf(assets, ops);
      final shift = snap.snapRange(TimeRange(start, start + length), pxPerSecond: viewport.pxPerSecond, enabled: state.modes.snapping);
      start = math.max(0, rate.quantizeNearest(start + shift)).toInt();
    }

    // The lane under the pointer, when it takes the media (a refused lane still shows why).
    TrackId? lane;
    if (pos.y >= 0) {
      final snapshot = ref.read(timelineSnapshotProvider(_id));
      final geometry = TimelineCanvasGeometry(snapshot: snapshot, metrics: metrics, viewport: viewport);
      final index = geometry.laneAt(pos.y);
      if (index != null && index >= 0 && index < snapshot.lanes.length) {
        final candidate = snapshot.lanes[index];
        if (assets.any((a) => laneAcceptsMedia(candidate.kind, a.kind))) lane = candidate.id;
      }
    }

    final command = ops.insertCommand(data.media, at: start, lane: lane);
    if (command == null) return null;
    final preview = ops.preview(command);
    // The dry run lists every affected item: the new clips are the ones the project does not have
    // yet, the others are existing clips the insert moves.
    final index = project.index;
    final created = <ItemId, Placement>{};
    final moved = <ItemId, Placement>{};
    preview.placements.forEach((id, placement) {
      final loc = index.locate(id);
      if (loc == null) {
        created[id] = placement;
      } else if (loc.track.id != placement.track || loc.item.range != placement.range) {
        moved[id] = placement;
      }
    });
    return DropGhost(
      command: command,
      start: start,
      pointer: pos.local,
      placements: created,
      shifted: moved,
      lane: lane,
      rejection: preview.rejection,
      guide: snap?.guide,
    );
  }

  TimeUs _lengthOf(List<MediaAsset> assets, MediaOperations ops) {
    final defaultImage = ops.session.editOrNull?.editPolicy.defaultImageUs ?? 3 * microsPerSecond;
    TimeUs of(Iterable<MediaAsset> group) => group.fold<TimeUs>(
        0,
        (sum, a) =>
            sum + (a.probe.duration > 0 && a.kind != MediaKind.image && a.kind != MediaKind.still ? a.probe.duration : defaultImage));
    final visual = assets.where((a) => isVisualMediaKind(a.kind));
    return visual.isNotEmpty ? of(visual) : of(assets);
  }

  // ---- In-app drag ------------------------------------------------------------------------------

  bool _willAccept(MediaDragData? data) {
    if (data == null || data.project != _id) return false;
    final ops = _ops;
    return ops.canEdit && ops.placeable(data.media).isNotEmpty;
  }

  void _onEnter(MediaDragData data) {
    final state = ref.read(editorControllerProvider(_id));
    final project = state.project;
    if (project == null) return;
    _data = data;
    _snap?.release();
    final touch = _metrics(state).touch;
    _snap = TimelineSnapping.forDrag(
      project,
      playhead: ref.read(playheadProvider(_id)).value,
      thresholdPx: TimelineSnapping.thresholdFor(touch: touch),
      onEngage: HapticFeedback.selectionClick,
    );
  }

  void _onMove(DragTargetDetails<MediaDragData> details) {
    // `onMove` also fires for a drag the target refused (another project, nothing to place).
    if (!_willAccept(details.data)) return;
    if (_data == null) _onEnter(details.data);
    _lastGlobal = details.offset;
    _ghost.value = _plan(details.offset, details.data);
    _updateAutoScroll(details.offset);
  }

  void _onLeave() => _endDrag();

  void _onAccept(DragTargetDetails<MediaDragData> details) {
    if (_data == null) _onEnter(details.data);
    final ghost = _plan(details.offset, details.data);
    _endDrag();
    if (ghost == null) return;
    // A refused drop runs the command anyway: the controller shows why and records nothing.
    final result = _ops.controller.apply(ghost.command);
    if (result is EditApplied) {
      HapticFeedback.lightImpact();
      if (mounted) editorAnnounce(context, MediaStrings.dropped);
    }
  }

  void _endDrag() {
    _stopAutoScroll();
    _snap?.release();
    _snap = null;
    _data = null;
    _lastGlobal = null;
    if (!_disposed) _ghost.value = null;
  }

  // ---- Auto-scroll ------------------------------------------------------------------------------

  void _updateAutoScroll(Offset global) {
    final viewport = ref.read(viewportProvider(_id));
    final box = _box;
    if (box == null || !viewport.hasLayout) {
      _stopAutoScroll();
      return;
    }
    final local = box.globalToLocal(global);
    final x = local.dx - viewport.headerWidth;
    final y = local.dy - viewport.rulerHeight;
    final w = viewport.lanesWidth, h = viewport.lanesHeight;
    double speed(double distance, double extent) {
      final edge = math.min(TimelineMetrics.autoScrollEdge, extent / 4);
      if (edge <= 0 || distance >= edge) return 0;
      final depth = ((edge - distance) / edge).clamp(0.0, 1.0);
      return depth * _maxAutoScrollViewportsPerSecond * extent;
    }

    var vx = 0.0, vy = 0.0;
    if (x >= -viewport.headerWidth && x <= w) {
      final left = speed(x, w), right = speed(w - x, w);
      if (left > 0) {
        vx = -left;
      } else if (right > 0) {
        vx = right;
      }
    }
    if (y >= 0 && y <= h) {
      final top = speed(y, h), bottom = speed(h - y, h);
      if (top > 0) {
        vy = -top;
      } else if (bottom > 0) {
        vy = bottom;
      }
    }
    _scrollVelocity = Offset(vx, vy);
    if (_scrollVelocity == Offset.zero) {
      _stopAutoScroll();
      return;
    }
    final ticker = _ticker ??= createTicker(_onTick);
    if (!ticker.isActive) {
      _lastTick = Duration.zero;
      ticker.start();
    }
  }

  void _onTick(Duration elapsed) {
    final data = _data, last = _lastGlobal;
    final dt = (elapsed - _lastTick).inMicroseconds / microsPerSecond;
    _lastTick = elapsed;
    if (data == null || last == null || dt <= 0 || !mounted) return;
    final viewport = ref.read(viewportProvider(_id));
    final pps = viewport.pxPerSecond;
    if (pps <= 0) return;
    final v = _scrollVelocity;
    final step = math.min(dt, 0.1);
    final beforeX = viewport.scrollTimeSec, beforeY = viewport.scrollY;
    viewport.jumpTo(
      scrollTimeSec: v.dx == 0 ? null : beforeX + v.dx * step / pps,
      scrollY: v.dy == 0 ? null : beforeY + v.dy * step,
    );
    if (viewport.scrollTimeSec == beforeX && viewport.scrollY == beforeY) return;
    _ghost.value = _plan(last, data);
  }

  void _stopAutoScroll() {
    _scrollVelocity = Offset.zero;
    final t = _ticker;
    if (t != null && t.isActive) t.stop();
  }

  // ---- External drops ---------------------------------------------------------------------------

  void _onExternalDrop(ExternalDrop drop) {
    _dropQueue = _dropQueue.then((_) => _handleDrop(drop)).catchError((Object e) {
      debugPrint('[Drop] External drop failed: ${e.runtimeType}');
    });
  }

  Future<void> _handleDrop(ExternalDrop drop) async {
    if (!mounted || drop.items.isEmpty) return;
    final ops = _ops;
    if (!ops.canEdit || ops.readOnly) {
      DanaviewToast.show(context, MediaStrings.dropNotEditable, icon: Icons.lock_rounded);
      return;
    }
    final target = _externalTarget(drop.position);
    final job = ops.importJob(
      pool: ref.read(mediaPoolServiceProvider),
      edit: ops.session.edit,
      at: target?.time,
      lane: target?.lane,
    );
    await showImportMediaSheet(context, picks: drop.items, job: job, title: MediaStrings.dropTitle);
  }

  /// The time and lane under an external drop at [global], or null when it landed outside the
  /// lanes (the media then goes to the playhead).
  ({TimeUs time, TrackId? lane})? _externalTarget(Offset global) {
    final state = ref.read(editorControllerProvider(_id));
    final project = state.project;
    final box = _box;
    if (project == null || box == null) return null;
    final viewport = ref.read(viewportProvider(_id));
    final metrics = _metrics(state);
    final pos = _lanesPosition(global, metrics, viewport);
    if (pos == null) return null;
    final inside = pos.local.dx >= 0 && pos.local.dy >= 0 && pos.local.dx <= box.size.width && pos.local.dy <= box.size.height;
    if (!inside || pos.x < 0 || pos.y < 0) return null;
    final rate = project.settings.frameRate;
    final time = math.max(0, rate.quantizeNearest(viewport.timeAt(pos.x))).toInt();
    final snapshot = ref.read(timelineSnapshotProvider(_id));
    final geometry = TimelineCanvasGeometry(snapshot: snapshot, metrics: metrics, viewport: viewport);
    final index = geometry.laneAt(pos.y);
    final lane = index != null && index >= 0 && index < snapshot.lanes.length ? snapshot.lanes[index].id : null;
    return (time: time, lane: lane);
  }

  // ---- Build ------------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return DragTarget<MediaDragData>(
      onWillAcceptWithDetails: (details) {
        final ok = _willAccept(details.data);
        if (ok && _data == null) _onEnter(details.data);
        return ok;
      },
      onMove: _onMove,
      onLeave: (_) => _onLeave(),
      onAcceptWithDetails: _onAccept,
      builder: (context, candidates, rejected) => Stack(
        key: _area,
        fit: StackFit.expand,
        children: [
          widget.child,
          Positioned.fill(
            child: IgnorePointer(
              child: ValueListenableBuilder<DropGhost?>(
                valueListenable: _ghost,
                builder: (context, ghost, _) => ghost == null ? const SizedBox.shrink() : _DropGhostLayer(ghost: ghost, owner: this),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// -------------------------------------------------------------------------------------------------
// Ghost layer
// -------------------------------------------------------------------------------------------------

class _DropGhostLayer extends ConsumerWidget {
  const _DropGhostLayer({required this.ghost, required this.owner});

  static const Color _invalid = Color(0xFFEF4444);
  static const double _pillMaxWidth = 220;

  final DropGhost ghost;
  final TimelineDropTargetState owner;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = EditorScope.idOf(context);
    final state = ref.read(editorControllerProvider(id));
    final snapshot = ref.read(timelineSnapshotProvider(id));
    final viewport = ref.read(viewportProvider(id));
    final metrics = owner._metrics(state);
    final header = viewport.headerWidth > 0 ? viewport.headerWidth : metrics.headerWidth;
    final ruler = viewport.rulerHeight > 0 ? viewport.rulerHeight : metrics.rulerHeight;
    final rate = snapshot.frameRate;
    final style = TimelineStyle.standard;
    final geometry = TimelineCanvasGeometry(snapshot: snapshot, metrics: metrics, viewport: viewport);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final pills = <Widget>[];
        if (size.isFinite) {
          final x = header + viewport.xOf(ghost.start);
          final text = ghost.valid ? MediaStrings.dropStart(EditStrings.timePill(ghost.start, rate)) : MediaStrings.dropRefused;
          pills.add(_pill(size, x, 2, text, key: const ValueKey('drop-pill')));
          final guide = ghost.guide;
          if (guide != null) {
            pills.add(_pill(size, header + viewport.xOf(guide.time), ruler + 4, EditStrings.timePill(guide.time, rate),
                key: const ValueKey('drop-snap-pill')));
          }
          if (ghost.createsTrack) {
            pills.add(_pill(size, x, math.max(0, ghost.pointer.dy - 28), EditStrings.newTrack,
                key: const ValueKey('drop-new-track-pill')));
          }
        }
        return Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _GhostPainter(ghost: ghost, geometry: geometry, header: header, ruler: ruler, style: style, invalid: _invalid),
              ),
            ),
            ...pills,
          ],
        );
      },
    );
  }

  static Widget _pill(Size size, double x, double top, String text, {Key? key}) {
    final width = math.min(_pillMaxWidth, size.width);
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
          borderRadius: DanaviewRadius.smAll,
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

class _GhostPainter extends CustomPainter {
  _GhostPainter(
      {required this.ghost, required this.geometry, required this.header, required this.ruler, required this.style, required this.invalid});

  final DropGhost ghost;
  final TimelineCanvasGeometry geometry;
  final double header;
  final double ruler;
  final TimelineStyle style;
  final Color invalid;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    // Everything below is in lanes coordinates (the ruler on top, the lanes under it).
    canvas.translate(header, 0);
    final viewport = geometry.viewport;
    final color = ghost.valid ? style.selection : invalid;
    final pointerY = ghost.pointer.dy - ruler;
    ghost.shifted.forEach((id, p) {
      final rect = _rect(p, pointerY);
      if (rect == null) return;
      canvas.drawRRect(rect, Paint()..color = style.selection.withValues(alpha: 0.10));
      canvas.drawRRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = style.selection.withValues(alpha: 0.55),
      );
    });
    ghost.placements.forEach((id, p) {
      final rect = _rect(p, pointerY);
      if (rect == null) return;
      canvas.drawRRect(rect, Paint()..color = color.withValues(alpha: 0.28));
      canvas.drawRRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = p.onNewTrack ? 1.5 : 2
          ..color = color,
      );
    });
    if (ghost.placements.isEmpty) {
      // A refused drop has no placements: show where the pointer is.
      final x = viewport.xOf(ghost.start);
      canvas.drawLine(
        Offset(x, ruler),
        Offset(x, size.height),
        Paint()
          ..strokeWidth = 1.5
          ..color = invalid.withValues(alpha: 0.8),
      );
    }
    final guide = ghost.guide;
    if (guide != null) {
      final x = viewport.xOf(guide.time);
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..strokeWidth = 1.5
          ..color = style.snapGuide,
      );
    }
    canvas.restore();
  }

  RRect? _rect(Placement p, double pointerY) {
    final snapshot = geometry.snapshot;
    final li = snapshot.laneIndexOf(p.track);
    final double top, height;
    if (li != null) {
      top = geometry.laneTop(li) + TimelineMetrics.clipInset;
      height = geometry.stack.heights[li] - 2 * TimelineMetrics.clipInset;
    } else {
      // A lane the drop creates: drawn where the pointer is.
      final kind = p.newTrack?.kind ?? TrackKind.video;
      height = geometry.metrics.laneHeightOf(kind) - 2 * TimelineMetrics.clipInset;
      top = pointerY - height / 2;
    }
    final left = geometry.viewport.xOf(p.range.start);
    final right = geometry.viewport.xOf(p.range.end);
    return RRect.fromRectAndRadius(
      Rect.fromLTWH(left, top + ruler, math.max(1, right - left), height),
      const Radius.circular(TimelineMetrics.clipRadius),
    );
  }

  @override
  bool shouldRepaint(_GhostPainter oldDelegate) => oldDelegate.ghost != ghost || oldDelegate.geometry != geometry;
}
