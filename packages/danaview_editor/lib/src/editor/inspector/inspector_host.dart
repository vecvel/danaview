// OWNER: UX-16
//
// InspectorHost (ux.md §9.3): maps the open InspectorRoute to its panel widget (the panel files of
// UX-01's placeholders; each panel ticket replaces its file and keeps the constructor
// `XPanel({Key? key, required XInspector route})`) under an InspectorHeader.
//
// * Placement: the side pane in compactLandscape and medium while the inspector is open, and the
//   expanded pane always (the scaffold places it). In compactPortrait the panel docks at the bottom
//   in `InspectorDock` (a DanaviewDockedPanel) around the same `InspectorView`.
// * The expanded pane with no panel open shows the context tools of the selection (or the open tool
//   tab) as a ToolGrid, else the media bin (MediaPanel), as in the expanded wireframe of ux.md §6.3.
// * Re-targeting (ux.md §9.3): EditorController re-points item panels at the new primary item when
//   the selection changes; the view closes the panel (and the context tools of the new selection
//   show) when the new item does not support it (ToolSets.supports).
// * The panel is keyed by its route type, so a re-targeted panel keeps its widget state (tab,
//   scroll) and gets the new route through didUpdateWidget.

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart' show EditProject;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../../debug/rebuild_counters.dart';
import '../contracts/contracts.dart';
import '../editor_scope.dart';
import '../layout/editor_layout.dart';
import '../layout/editor_layout_scope.dart';
import '../panels/adjust_panel.dart';
import '../panels/audio_panel.dart';
import '../panels/canvas_panel.dart';
import '../panels/chroma_panel.dart';
import '../panels/clip_info_panel.dart';
import '../panels/crop_panel.dart';
import '../panels/filters_panel.dart';
import '../panels/keyframes_panel.dart';
import '../panels/mask_panel.dart';
import '../panels/media_panel.dart';
import '../panels/overlay_panel.dart';
import '../panels/speed_panel.dart';
import '../panels/subtitles_panel.dart';
import '../panels/text_panel.dart';
import '../panels/transform_panel.dart';
import '../panels/transitions_panel.dart';
import '../panels/voiceover_panel.dart';
import '../toolbar/tool_grid.dart';
import '../toolbar/tool_sets.dart';
import '../toolbar/toolbar_model.dart';
import 'inspector_header.dart';

/// The panel and title of each route.
abstract final class InspectorRoutes {
  /// The panel widget of [route].
  static Widget panelFor(InspectorRoute route) => switch (route) {
        MediaInspector() => MediaPanel(route: route),
        VoiceoverInspector() => VoiceoverPanel(route: route),
        OverlayInspector() => OverlayPanel(route: route),
        CanvasInspector() => CanvasPanel(route: route),
        TransformInspector() => TransformPanel(route: route),
        CropInspector() => CropPanel(route: route),
        MaskInspector() => MaskPanel(route: route),
        SpeedInspector() => SpeedPanel(route: route),
        AudioInspector() => AudioPanel(route: route),
        AdjustInspector() => AdjustPanel(route: route),
        FiltersInspector() => FiltersPanel(route: route),
        ChromaInspector() => ChromaPanel(route: route),
        KeyframesInspector() => KeyframesPanel(route: route),
        TextInspector() => TextPanel(route: route),
        ClipInfoInspector() => ClipInfoPanel(route: route),
        SubtitlesInspector() => SubtitlesPanel(route: route),
        TransitionInspector() => TransitionsPanel(route: route),
      };

  /// The header title of [route].
  static String titleOf(InspectorRoute route) => switch (route) {
        MediaInspector() => InspectorStrings.media,
        VoiceoverInspector() => InspectorStrings.voiceover,
        OverlayInspector() => InspectorStrings.overlay,
        CanvasInspector() => InspectorStrings.format,
        TransformInspector() => InspectorStrings.transform,
        CropInspector() => InspectorStrings.crop,
        MaskInspector() => InspectorStrings.mask,
        SpeedInspector() => InspectorStrings.speed,
        AudioInspector(:final focus) => focus == AudioPanelFocus.fades ? InspectorStrings.fades : InspectorStrings.volume,
        AdjustInspector() => InspectorStrings.adjust,
        FiltersInspector() => InspectorStrings.filters,
        ChromaInspector() => InspectorStrings.chroma,
        KeyframesInspector() => InspectorStrings.keyframes,
        TextInspector() => InspectorStrings.text,
        ClipInfoInspector() => InspectorStrings.clipInfo,
        SubtitlesInspector() => InspectorStrings.captions,
        TransitionInspector() => InspectorStrings.transition,
      };

  /// Whether [route] can stay open on [project] (its target exists and supports the panel).
  static bool isSupported(InspectorRoute route, EditProject? project) {
    final target = route.target;
    if (target == null || project == null || route is! ItemInspectorRoute) return true;
    return ToolSets.supportsItem(route, target, project);
  }
}

/// Hosts the panel of the current InspectorRoute in the side pane (ux.md §9.3).
class InspectorHost extends ConsumerWidget {
  /// Creates the host for the editor of the nearest `EditorScope`.
  const InspectorHost({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    EditorRebuildCounters.count('InspectorHost');
    final id = EditorScope.idOf(context);
    final route = ref.watch(editorControllerProvider(id).select((s) => s.inspector));
    final spec = EditorLayoutScope.maybeOf(context);
    final Widget body;
    if (route != null) {
      body = InspectorView(route: route);
    } else if (spec == null || spec.kind == EditorLayoutKind.expanded) {
      final contents = ToolbarModel.watch(context, ref, id);
      body = contents.topLevel
          ? const MediaPanel(key: ValueKey<String>('idle.media'), route: MediaInspector())
          : ToolGrid(contents: contents, tileHeight: spec?.toolTileHeight ?? 64, iconOnly: spec?.iconOnlyTools ?? false);
    } else {
      body = const SizedBox.shrink();
    }
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: DanaviewColors.surface,
        border: BorderDirectional(start: DanaviewBorders.hairline, end: DanaviewBorders.hairline),
      ),
      child: body,
    );
  }
}

/// The open panel under its header; shared by [InspectorHost] and `InspectorDock`.
class InspectorView extends ConsumerStatefulWidget {
  /// Creates the view of [route].
  const InspectorView({super.key, required this.route});

  /// The open panel.
  final InspectorRoute route;

  @override
  ConsumerState<InspectorView> createState() => _InspectorViewState();
}

class _InspectorViewState extends ConsumerState<InspectorView> {
  final ValueNotifier<InspectorHeaderActions> _actions = ValueNotifier(InspectorHeaderActions.none);
  bool _closeScheduled = false;

  @override
  void didUpdateWidget(InspectorView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.route.runtimeType != widget.route.runtimeType) _actions.value = InspectorHeaderActions.none;
  }

  @override
  void dispose() {
    _actions.dispose();
    super.dispose();
  }

  void _closeUnsupported() {
    if (_closeScheduled) return;
    _closeScheduled = true;
    final id = EditorScope.idOf(context);
    final route = widget.route;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _closeScheduled = false;
      if (!mounted) return;
      final state = ref.read(editorControllerProvider(id));
      // Close only if the unsupported route is still the open one.
      if (state.inspector == route && !InspectorRoutes.isSupported(route, state.project)) {
        ref.read(editorControllerProvider(id).notifier).closeInspector();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final id = EditorScope.idOf(context);
    final route = widget.route;
    final project = ref.watch(editorControllerProvider(id).select((s) => s.project));
    if (!InspectorRoutes.isSupported(route, project)) {
      _closeUnsupported();
      return const SizedBox.shrink();
    }
    final editor = ref.read(editorControllerProvider(id).notifier);
    final title = InspectorRoutes.titleOf(route);
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: '${InspectorStrings.region}, $title',
      child: InspectorHeaderSlot(
        actions: _actions,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ValueListenableBuilder<InspectorHeaderActions>(
              valueListenable: _actions,
              builder: (context, actions, _) => InspectorHeader(
                title: title,
                actions: actions,
                onBack: editor.closeInspector,
                onDone: () {
                  editor.closeInspector();
                  editor.setTool(null);
                },
              ),
            ),
            const SizedBox(height: 1, child: ColoredBox(color: DanaviewColors.hairline)),
            Expanded(
              child: KeyedSubtree(
                key: ValueKey<Type>(route.runtimeType),
                child: InspectorRoutes.panelFor(route),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
