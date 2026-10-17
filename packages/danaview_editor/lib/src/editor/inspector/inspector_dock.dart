// OWNER: UX-16
//
// InspectorDock (ux.md §9.3, §6.3): the inspector of compactPortrait, a non-modal DanaviewDockedPanel
// at the bottom of the screen with the default detent at `EditorLayoutScope.dockHeight` (the
// planner's `max(240, timeline + strip − 76)` within the room left) and the expanded detent at 85 %
// of the screen, moved by dragging or tapping the handle. The scaffold's dock slot gives the dock
// the full MediaQuery, so the panel lifts itself above the keyboard. The content is the same
// InspectorView (header + panel) the side pane shows; the body scrolls inside the panel.
// The detent resets to default when a different panel opens.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../../debug/rebuild_counters.dart';
import '../editor_scope.dart';
import '../layout/editor_layout_scope.dart';
import 'inspector_host.dart';

/// Non-modal DanaviewDockedPanel in compactPortrait (ux.md §9.3).
class InspectorDock extends ConsumerStatefulWidget {
  /// Creates the dock for the editor of the nearest `EditorScope`.
  const InspectorDock({super.key});

  /// Share of the screen at the expanded detent.
  static const double expandedFraction = 0.85;

  @override
  ConsumerState<InspectorDock> createState() => _InspectorDockState();
}

class _InspectorDockState extends ConsumerState<InspectorDock> {
  DanaviewDockDetent _detent = DanaviewDockDetent.standard;
  Type? _routeType;

  @override
  Widget build(BuildContext context) {
    EditorRebuildCounters.count('InspectorDock');
    final id = EditorScope.idOf(context);
    final route = ref.watch(editorControllerProvider(id).select((s) => s.inspector));
    if (route == null) {
      _routeType = null;
      return const SizedBox.shrink();
    }
    if (_routeType != route.runtimeType) {
      _routeType = route.runtimeType;
      _detent = DanaviewDockDetent.standard;
    }
    final spec = EditorLayoutScope.maybeOf(context);
    final standard = spec?.dockHeight ?? 240;
    return DanaviewDockedPanel(
      standardHeight: standard > 0 ? standard : 240,
      expandedFraction: InspectorDock.expandedFraction,
      detent: _detent,
      onDetentChanged: (d) => setState(() => _detent = d),
      scrollable: false,
      padding: EdgeInsets.zero,
      semanticLabel: InspectorRoutes.titleOf(route),
      child: InspectorView(route: route),
    );
  }
}
