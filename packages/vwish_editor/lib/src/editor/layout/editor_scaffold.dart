// OWNER: UX-07
//
// EditorScaffold (ux.md §6, §16.6): resolves the EditorLayoutSpec from MediaQuery (size, safe
// area, keyboard, text scale), the platform (touch) and the user's splitter ratio for the layout
// kind, publishes it through EditorLayoutScope and places every region widget at its rect.
//
// * Regions: the top bar (built by the screen, with the TransportBar in its title slot at ladder
//   step 4), PreviewRegion (UX-18), TransportBar (UX-14), the splitter, TimelineView (UX-12), the
//   bottom ToolStrip (compactPortrait), the ToolRail (expanded rail; in compactLandscape and medium
//   the side pane shows it while the inspector is closed), InspectorHost (side pane while the
//   inspector is open; always in the expanded pane) and InspectorDock (compactPortrait, inspector
//   open). UX-16 reads `EditorLayoutScope.of(context).toolPlacement`/`inspectorPlacement`.
// * Every region but the dock gets a MediaQuery without safe-area padding or keyboard inset: the
//   planner already kept it clear of both. The dock slot sits at the bottom of the screen with the
//   full MediaQuery and lays its child out with unbounded height and a minimum of the spec's
//   dock height plus the keyboard, so `VwishDockedPanel(standardHeight: spec.dockHeight)` lifts
//   itself above the keyboard and can still be dragged to its expanded detent over the timeline.
// * Splitter (ux.md §6.5): 12 px row, 24 px touch hit area reaching into the neighbours; drags
//   change a live ratio, the end of a drag (or a semantics/keyboard step) persists it per kind in
//   EditorPrefs (`editor.layout.splitRatio.<kind>`), double-tap resets to the kind's default.
// * Rebuilds (ux.md §16.6): the scaffold rebuilds only for layout inputs (MediaQuery, inspector
//   open, the opening phase, the splitter); region widgets are keyed so they keep their state when
//   the layout kind changes (rotation), and the TransportBar keeps its state when it moves into
//   the top bar.

import 'package:flutter/rendering.dart' show OverflowBoxFit;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import '../../app/editor_prefs.dart';
import '../../app/editor_providers.dart';
import '../../debug/rebuild_counters.dart';
import '../inspector/inspector_dock.dart';
import '../inspector/inspector_host.dart';
import '../preview/preview_region.dart';
import '../timeline/timeline_drop_target.dart';
import '../timeline/timeline_view.dart';
import '../toolbar/tool_rail.dart';
import '../toolbar/tool_strip.dart';
import '../transport/transport_bar.dart';
import 'editor_layout.dart';
import 'editor_layout_scope.dart';
import 'editor_shell_strings.dart';
import 'editor_splitter.dart';

/// Builds the top bar; [transport] is the TransportBar when ladder step 4 merged it into the bar
/// (it then replaces the title), else null.
typedef EditorTopBarBuilder = Widget Function(BuildContext context, Widget? transport);

/// Lays out the editor's regions for the current screen (ux.md §6).
class EditorScaffold extends ConsumerStatefulWidget {
  /// Creates the scaffold.
  const EditorScaffold({super.key, required this.inspectorOpen, required this.topBar, this.loading = false});

  /// Whether an inspector panel is open (docks it in compactPortrait, fills the side pane elsewhere).
  final bool inspectorOpen;

  /// Builds the top bar.
  final EditorTopBarBuilder topBar;

  /// The project is still opening: only the top bar and a progress indicator show.
  final bool loading;

  /// Extra touch area the splitter takes from each neighbour.
  static const double splitterTouchSlop = 6;

  @override
  ConsumerState<EditorScaffold> createState() => _EditorScaffoldState();
}

class _EditorScaffoldState extends ConsumerState<EditorScaffold> {
  /// The splitter ratio while dragging (or after a step), for [_liveKind].
  double? _liveRatio;
  EditorLayoutKind? _liveKind;
  final GlobalKey _transportKey = GlobalKey(debugLabel: 'EditorScaffold.transport');

  EditorPrefs get _prefs => ref.read(editorPrefsProvider);

  void _onSplitChanged(EditorLayoutKind kind, double ratio) {
    setState(() {
      _liveKind = kind;
      _liveRatio = ratio;
    });
  }

  void _onSplitChangeEnd(EditorLayoutKind kind, double ratio) {
    _onSplitChanged(kind, ratio);
    if (ratio.isFinite && ratio > 0 && ratio < 1) _prefs.setSplitRatio(kind.name, ratio);
  }

  void _onSplitReset(EditorLayoutKind kind) {
    setState(() {
      _liveKind = null;
      _liveRatio = null;
    });
    _prefs.setSplitRatio(kind.name, null);
  }

  @override
  Widget build(BuildContext context) {
    EditorRebuildCounters.count('EditorScaffold');
    final padding = MediaQuery.paddingOf(context);
    final insets = MediaQuery.viewInsetsOf(context);
    final textScaler = MediaQuery.textScalerOf(context);
    final touch = context.isTouchPlatform;
    final prefs = ref.watch(editorPrefsProvider);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final kind = EditorLayoutSpec.kindOf(size: size, padding: padding);
        final ratio = (_liveKind == kind ? _liveRatio : null) ?? prefs.splitRatio(kind.name);
        final spec = EditorLayoutSpec.resolve(
          size: size,
          padding: padding,
          viewInsets: insets,
          textScaler: textScaler,
          touch: touch,
          splitRatio: ratio,
          inspectorOpen: widget.inspectorOpen && !widget.loading,
        );
        return EditorLayoutScope(spec: spec, child: _regions(context, spec));
      },
    );
  }

  Widget _regions(BuildContext context, EditorLayoutSpec spec) {
    final transport = KeyedSubtree(key: _transportKey, child: const TransportBar());
    final children = <Widget>[];

    void region(EditorRegion r, Widget child) {
      final rect = spec.rectOf(r);
      if (rect == null) return;
      children.add(Positioned.fromRect(
        key: ValueKey<EditorRegion>(r),
        rect: rect,
        child: _plain(context, RepaintBoundary(child: child)),
      ));
    }

    final topBar = spec.rectOf(EditorRegion.topBar);
    if (topBar != null) {
      children.add(Positioned.fromRect(
        key: const ValueKey<EditorRegion>(EditorRegion.topBar),
        rect: topBar,
        child: _plain(
            context, Builder(builder: (context) => widget.topBar(context, spec.transportInTopBar && !widget.loading ? transport : null))),
      ));
    }

    if (widget.loading) {
      final top = topBar?.bottom ?? spec.padding.top;
      final bottom = spec.size.height - spec.padding.bottom.clamp(spec.viewInsets.bottom, double.infinity);
      children.add(Positioned(
        key: const ValueKey<String>('loading'),
        left: spec.padding.left,
        right: spec.padding.right,
        top: top,
        height: (bottom - top).clamp(0.0, double.infinity),
        child: const Center(child: VwishSpinner(semanticLabel: EditorShellStrings.opening)),
      ));
      return Stack(children: children);
    }

    region(EditorRegion.preview, const PreviewRegion());
    region(EditorRegion.transport, transport);
    region(EditorRegion.timeline, const TimelineDropTarget(child: TimelineView()));
    region(EditorRegion.toolStrip, const ToolStrip());
    region(EditorRegion.rail, const ToolRail());
    region(
      EditorRegion.pane,
      switch (spec.kind) {
        EditorLayoutKind.expanded => const InspectorHost(),
        _ => spec.inspectorOpen ? const InspectorHost() : const ToolRail(),
      },
    );

    final splitter = spec.rectOf(EditorRegion.splitter);
    if (splitter != null) {
      final slop = spec.touch ? EditorScaffold.splitterTouchSlop : 0.0;
      final kind = spec.kind;
      children.add(Positioned(
        key: const ValueKey<EditorRegion>(EditorRegion.splitter),
        left: splitter.left,
        width: splitter.width,
        top: splitter.top - slop,
        height: splitter.height + 2 * slop,
        child: _plain(
          context,
          EditorSplitter(
            ratio: spec.splitRatio,
            minRatio: spec.minSplitRatio,
            maxRatio: spec.maxSplitRatio,
            span: spec.splitSpan,
            onChanged: (r) => _onSplitChanged(kind, r),
            onChangeEnd: (r) => _onSplitChangeEnd(kind, r),
            onReset: () => _onSplitReset(kind),
          ),
        ),
      ));
    }

    final dock = spec.rectOf(EditorRegion.dock);
    if (dock != null) {
      children.add(Positioned(
        key: const ValueKey<EditorRegion>(EditorRegion.dock),
        left: dock.left,
        width: dock.width,
        bottom: 0,
        child: OverflowBox(
          alignment: Alignment.bottomCenter,
          fit: OverflowBoxFit.deferToChild,
          minHeight: dock.height + spec.viewInsets.bottom,
          maxHeight: double.infinity,
          child: const InspectorDock(),
        ),
      ));
    }
    return Stack(children: children);
  }

  /// [child] without the safe-area padding and the keyboard inset (the planner kept the region
  /// clear of both).
  static Widget _plain(BuildContext context, Widget child) {
    final data = MediaQuery.of(context)
        .removePadding(removeLeft: true, removeTop: true, removeRight: true, removeBottom: true)
        .removeViewPadding(removeLeft: true, removeTop: true, removeRight: true, removeBottom: true)
        .removeViewInsets(removeLeft: true, removeTop: true, removeRight: true, removeBottom: true);
    return MediaQuery(data: data, child: child);
  }
}
