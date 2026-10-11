// OWNER: UX-16
//
// The tiles the toolbar shows right now (ux.md §9.1, §9.2), shared by the bottom strip, the
// expanded rail and the tool panes:
//
//   selection (ToolSets.forSelection) ─► [✕ Video clip] + context tools
//   else an open tool tab (Audio)     ─► [✕ Audio] + Add music, Record voiceover, Extract audio
//   else                              ─► the nine top-level tools
//
// * Every action tile is driven by the EditorActionRegistry (UX-15): label, icon, visibility,
//   enablement, the disabled reason and the handler (invoked with source `toolTile`). Hidden
//   actions are left out; disabled ones show at 40 % and explain themselves in a toast.
// * Top-level tools set `EditorState.tool` and run their primary action (Audio opens its tab).
// * Panel tools (text tabs, subtitle sections, transition settings) open their route directly.
// * Rebuilds: only when the editor state the predicates read changes (phase, selection, tool,
//   inspector, project, modes, history, media), never per playback frame.

import 'package:flutter/material.dart' show Theme;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart' show EditProject, ProjectId;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../actions/editor_action_registry.dart';
import '../contracts/contracts.dart';
import '../layout/editor_layout_scope.dart';
import '../state/editor_controller.dart';
import '../state/editor_state.dart';
import 'tool_sets.dart';
import 'tool_tile.dart';
import 'toolbar_strings.dart';

/// The leading chip of a context set or a tool tab.
@immutable
final class ToolbarChip {
  /// Creates the chip.
  const ToolbarChip({required this.label, required this.hint, required this.onTap});

  /// Label ("Video clip", "Audio").
  final String label;

  /// Semantics hint and tooltip ("Clear selection").
  final String hint;

  /// Clears the selection or closes the tab.
  final VoidCallback onTap;
}

/// What the toolbar shows.
@immutable
final class ToolbarContents {
  /// Creates the contents.
  ToolbarContents({required List<ToolTileData> tiles, this.chip, this.set, this.tab}) : tiles = List.unmodifiable(tiles);

  /// The tiles, in order.
  final List<ToolTileData> tiles;

  /// The leading chip (context set or tool tab), or null for the top-level tools.
  final ToolbarChip? chip;

  /// The context set, when something is selected.
  final ToolSet? set;

  /// The open tool tab, if any.
  final ToolId? tab;

  /// Whether the top-level tools show.
  bool get topLevel => chip == null;
}

/// The parts of [EditorState] the toolbar depends on.
@immutable
final class ToolbarInputs {
  /// Reads the inputs of [s].
  ToolbarInputs.of(EditorState s)
      : phase = s.phase,
        selection = s.selection,
        tool = s.tool,
        inspector = s.inspector,
        project = s.project,
        modes = s.modes,
        history = s.history,
        media = s.media;

  /// Phase.
  final EditorPhase phase;

  /// Selection.
  final EditorSelection selection;

  /// Active top-level tool.
  final ToolId? tool;

  /// Open inspector route.
  final InspectorRoute? inspector;

  /// Project (compared by identity).
  final EditProject? project;

  /// Edit modes.
  final EditModes modes;

  /// History.
  final HistoryStatus history;

  /// Media health.
  final MediaHealth media;

  @override
  bool operator ==(Object other) =>
      other is ToolbarInputs &&
      other.phase == phase &&
      other.selection == selection &&
      other.tool == tool &&
      other.inspector == inspector &&
      identical(other.project, project) &&
      other.modes == modes &&
      other.history == history &&
      other.media == media;

  @override
  int get hashCode => Object.hash(phase, selection, tool, inspector, identityHashCode(project), modes, history, media);
}

/// Builds [ToolbarContents] for the editor of [id] (ux.md §9).
abstract final class ToolbarModel {
  /// Watches the editor of [id] from a widget's build and returns what the toolbar shows.
  /// [topLevelOnly] returns the top-level tools whatever is selected (the expanded rail, whose
  /// pane shows the context tools).
  static ToolbarContents watch(BuildContext context, WidgetRef ref, ProjectId id, {bool topLevelOnly = false}) {
    final inputs = ref.watch(editorControllerProvider(id).select(ToolbarInputs.of));
    final registry = ref.watch(editorActionRegistryProvider).forPlatformOf(Theme.of(context).platform);
    final controller = ref.read(editorControllerProvider(id).notifier);
    final ctx = WidgetActionContext(projectId: id, context: context, ref: ref, source: EditorActionSource.toolTile);
    return resolve(
      inputs: inputs,
      registry: registry,
      ctx: ctx,
      controller: controller,
      explain: (reason) => showDisabledReason(context, reason),
      topLevelOnly: topLevelOnly,
    );
  }

  /// Shows why a tool is disabled (a toast above the strip).
  static void showDisabledReason(BuildContext context, String reason) {
    final spec = EditorLayoutScope.maybeOf(context);
    DanaviewToast.show(context, reason, bottomOffset: (spec?.toolStripHeight ?? 0) + 16);
  }

  /// The contents for [inputs]; [explain] shows a disabled tool's reason.
  static ToolbarContents resolve({
    required ToolbarInputs inputs,
    required EditorActionRegistry registry,
    required EditorActionContext ctx,
    required EditorController controller,
    required void Function(String reason) explain,
    bool topLevelOnly = false,
  }) {
    final ready = inputs.phase == EditorPhase.ready;

    ToolTileData? actionTile(ActionToolEntry e) {
      final spec = registry.spec(e.action);
      if (!spec.isVisible(ctx)) return null;
      final enabled = ready && spec.isEnabled(ctx);
      final reason = enabled ? null : (ready ? spec.disabledReason(ctx) : ToolbarStrings.notOpen);
      final label = e.label ?? spec.label;
      return ToolTileData(
        key: e.key,
        label: label,
        icon: e.icon ?? spec.icon,
        enabled: enabled,
        reason: reason,
        tooltip: registry.tooltip(e.action, label),
        shortcut: spec.primaryShortcut,
        onTap: () {
          if (!enabled) return explain(reason ?? ToolbarStrings.notOpen);
          final result = registry.invoke(e.action, ctx);
          if (result == EditorActionResult.disabled || result == EditorActionResult.unbound) {
            explain(spec.disabledReason(ctx) ?? ToolbarStrings.notOpen);
          }
        },
      );
    }

    final set = topLevelOnly ? null : ToolSets.forSelection(inputs.selection, inputs.project);
    if (set != null) {
      final tiles = <ToolTileData>[];
      for (final e in set.entries) {
        switch (e) {
          case ActionToolEntry():
            final tile = actionTile(e);
            if (tile != null) tiles.add(tile);
          case PanelToolEntry():
            final enabled = ready && !set.locked;
            final reason = enabled ? null : (ready ? ToolbarStrings.trackLocked : ToolbarStrings.notOpen);
            tiles.add(ToolTileData(
              key: e.key,
              label: e.label,
              icon: e.icon,
              enabled: enabled,
              reason: reason,
              selected: inputs.inspector == e.route,
              onTap: () => enabled ? controller.openInspector(e.route) : explain(reason!),
            ));
        }
      }
      return ToolbarContents(
        tiles: tiles,
        set: set,
        chip: ToolbarChip(label: set.chipLabel, hint: ToolbarStrings.clearSelection, onTap: controller.clearSelection),
      );
    }

    final tab = inputs.tool;
    final tabActions = tab == null ? null : ToolSets.toolTabs[tab];
    if (!topLevelOnly && tab != null && tabActions != null) {
      return ToolbarContents(
        tab: tab,
        tiles: [
          for (final a in tabActions)
            if (actionTile(ActionToolEntry(a)) case final tile?) tile,
        ],
        chip: ToolbarChip(label: ToolbarStrings.tool(tab), hint: ToolbarStrings.closeTool, onTap: () => controller.setTool(null)),
      );
    }

    return ToolbarContents(tiles: [
      for (final tool in ToolId.stripOrder) _topLevelTile(tool, inputs, registry, ctx, controller, explain, ready),
    ]);
  }

  static ToolTileData _topLevelTile(
    ToolId tool,
    ToolbarInputs inputs,
    EditorActionRegistry registry,
    EditorActionContext ctx,
    EditorController controller,
    void Function(String reason) explain,
    bool ready,
  ) {
    final label = ToolbarStrings.tool(tool);
    final icon = ToolbarStrings.toolIcon(tool);
    final selected = inputs.tool == tool;
    if (ToolSets.toolTabs.containsKey(tool)) {
      return ToolTileData(
        key: 'tool.${tool.name}',
        label: label,
        icon: icon,
        enabled: ready,
        selected: selected,
        reason: ready ? null : ToolbarStrings.notOpen,
        onTap: () => ready ? controller.setTool(tool) : explain(ToolbarStrings.notOpen),
      );
    }
    final spec = registry.spec(tool.primaryAction);
    final enabled = ready && spec.isVisible(ctx) && spec.isEnabled(ctx);
    final reason = enabled ? null : (ready ? spec.disabledReason(ctx) ?? EditorActionStrings.notAvailableNow : ToolbarStrings.notOpen);
    return ToolTileData(
      key: 'tool.${tool.name}',
      label: label,
      icon: icon,
      enabled: enabled,
      selected: selected,
      reason: reason,
      tooltip: registry.tooltip(tool.primaryAction, label),
      shortcut: spec.primaryShortcut,
      onTap: () {
        if (!enabled) return explain(reason!);
        controller.setTool(tool);
        final result = registry.invoke(tool.primaryAction, ctx);
        if (result != EditorActionResult.ran && result != EditorActionResult.failed) {
          explain(spec.disabledReason(ctx) ?? EditorActionStrings.notAvailableNow);
        }
      },
    );
  }
}
