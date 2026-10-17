// OWNER: UX-29
//
// The Project sheet (ux.md §6.4, §14.3, ARCH §17.7): opened by the title button (`projectSheet`).
//
// * Header: the project name and its save status (Saved · Saving… · Edited · Couldn't save ·
//   Read-only), the same states as the title subtitle.
// * Rows: Rename, Format (current aspect · fps · resolution), Save now (`⌘S`/`Ctrl+S` shown where a
//   keyboard is likely: pointer platforms and tablets), Media in project, Keyboard shortcuts,
//   Background tasks, Edit history.
// * Every row except Rename is an editor action run through the registry after the sheet closes
//   (`format`, `save`, `media`, `showShortcuts`, `tasks`, `history`), so the sheet, the keyboard and
//   the tool tiles behave the same; a row whose action is disabled or unbound is disabled and says
//   why. Save is `saveNow(manual: true)` (the "Saved" toast comes from the controller).
// * Rename asks for a name (1-80 characters after trim) and calls [projectRenameProvider]
//   (default: `ProjectRepository.rename`). A store that refuses to rename an open project
//   (`StoreFailureKind.busy`) gets a toast that says where it can be done.
// * The sheet route sits outside the editor's `EditorScope`, so it takes the project id.

import 'dart:async';

import 'package:flutter/material.dart' show Icons, Theme;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart' show ProjectId;
import 'package:danaview_editor_core/store.dart' show StoreFailure, StoreFailureKind;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../../app/strings/project_strings.dart';
import '../../app/strings/projects_strings.dart' show ProjectsStrings;
import '../actions/editor_action_registry.dart';
import '../contracts/contracts.dart';
import '../state/editor_state.dart';

/// Renames project [id] to [name] (already validated and trimmed).
typedef ProjectRename = Future<void> Function(ProjectId id, String name);

/// How the Project sheet renames the open project (default: the repository). Tests and INT
/// wiring may override it.
final projectRenameProvider = Provider<ProjectRename>(
  (ref) => (id, name) => ref.read(projectRepositoryProvider).rename(id, name),
  name: 'projectRenameProvider',
);

/// A row of the Project sheet.
enum ProjectSheetChoice {
  /// Rename the project.
  rename(null, Icons.drive_file_rename_outline_rounded),

  /// The Format panel.
  format(EditorActionId.format, Icons.aspect_ratio_rounded),

  /// Save now.
  save(EditorActionId.save, Icons.save_rounded),

  /// The media bin.
  media(EditorActionId.media, Icons.video_library_rounded),

  /// The shortcuts sheet.
  shortcuts(EditorActionId.showShortcuts, Icons.keyboard_rounded),

  /// The tasks sheet.
  tasks(EditorActionId.tasks, Icons.pending_actions_rounded),

  /// The History sheet.
  history(EditorActionId.history, Icons.history_rounded);

  const ProjectSheetChoice(this.action, this.icon);

  /// The action the row runs (null: handled by the sheet).
  final EditorActionId? action;

  /// The row's icon.
  final IconData icon;

  /// The row's title.
  String get title => switch (this) {
        ProjectSheetChoice.rename => ProjectStrings.rename,
        ProjectSheetChoice.format => ProjectStrings.format,
        ProjectSheetChoice.save => ProjectStrings.saveNow,
        ProjectSheetChoice.media => ProjectStrings.media,
        ProjectSheetChoice.shortcuts => ProjectStrings.shortcuts,
        ProjectSheetChoice.tasks => ProjectStrings.tasks,
        ProjectSheetChoice.history => ProjectStrings.history,
      };
}

/// The text of save status [save] (ux.md §6.4).
String projectSaveStatusText(SaveStatus save) => switch (save.phase) {
      SavePhase.clean || SavePhase.saved => ProjectStrings.statusSaved,
      SavePhase.saving => ProjectStrings.statusSaving,
      SavePhase.edited => ProjectStrings.statusEdited,
      SavePhase.failed => ProjectStrings.statusFailed,
      SavePhase.readOnly => ProjectStrings.statusReadOnly,
    };

/// The Project sheet's content (ux.md §6.4).
class ProjectSheet extends ConsumerWidget {
  /// Creates the sheet for [projectId]; a row pops the sheet's route with its [ProjectSheetChoice].
  const ProjectSheet({super.key, required this.projectId});

  /// The open project.
  final ProjectId projectId;

  /// Shows the sheet from [ctx] and runs the chosen row with [ctx] (its context stays mounted after
  /// the sheet closes).
  static Future<void> show(EditorActionContext ctx) async {
    final choice = await showDanaviewSheet<ProjectSheetChoice>(
      ctx.context,
      title: ProjectStrings.projectTitle,
      builder: (_) => ProjectSheet(projectId: ctx.projectId),
    );
    if (choice == null || !ctx.context.mounted) return;
    await run(ctx, choice);
  }

  /// Runs [choice] in [ctx].
  static Future<void> run(EditorActionContext ctx, ProjectSheetChoice choice) async {
    final action = choice.action;
    if (action != null) {
      ctx.read(editorActionRegistryProvider).invoke(action, ctx);
      return;
    }
    await rename(ctx);
  }

  /// Asks for a new name and renames the project.
  static Future<void> rename(EditorActionContext ctx) async {
    final context = ctx.context;
    final current = ctx.read(editorControllerProvider(ctx.projectId)).project?.name ?? '';
    final name = await showDanaviewPrompt(
      context,
      title: ProjectStrings.renameTitle,
      hint: ProjectStrings.renameHint,
      initialValue: current,
      confirmLabel: ProjectStrings.renameConfirm,
      cancelLabel: ProjectStrings.cancel,
      validator: ProjectsStrings.validateName,
      prefixIcon: Icons.drive_file_rename_outline_rounded,
    );
    if (name == null || !context.mounted) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == current) return;
    String message;
    var ok = false;
    try {
      await ctx.read(projectRenameProvider)(ctx.projectId, trimmed);
      message = ProjectStrings.renamed(trimmed);
      ok = true;
    } on StoreFailure catch (f) {
      message = f.kind == StoreFailureKind.busy ? ProjectStrings.renameBusy : ProjectStrings.renameFailed;
    } catch (_) {
      message = ProjectStrings.renameFailed;
    }
    if (!context.mounted) return;
    DanaviewToast.show(
      context,
      message,
      kind: ok ? DanaviewToastKind.success : DanaviewToastKind.error,
      icon: ok ? Icons.check_circle_rounded : Icons.error_outline_rounded,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = editorControllerProvider(projectId);
    final state = ref.watch(provider);
    final registry = ref.watch(editorActionRegistryProvider).forPlatformOf(Theme.of(context).platform);
    final ctx = WidgetActionContext(projectId: projectId, context: context, ref: ref, source: EditorActionSource.button);
    final project = state.project;
    final ready = state.isReady && project != null;
    final status = state.isReady ? projectSaveStatusText(state.save) : ProjectStrings.statusOpening;
    final showKeys = !context.isTouchPlatform || MediaQuery.sizeOf(context).shortestSide >= 600;

    String? subtitleOf(ProjectSheetChoice c) => switch (c) {
          ProjectSheetChoice.format when project != null => ProjectStrings.formatSummary(
              project.settings.canvas.aspect, project.settings.frameRate, project.settings.canvas.baseShortSide),
          ProjectSheetChoice.save when state.save.phase == SavePhase.failed => ProjectStrings.saveRetry,
          ProjectSheetChoice.media when project != null => ProjectStrings.mediaCount(project.pool.length),
          ProjectSheetChoice.history => ProjectStrings.historyCount(state.history.length),
          _ => null,
        };

    final rows = <Widget>[];
    for (final c in ProjectSheetChoice.values) {
      final action = c.action;
      final spec = action == null ? null : registry.spec(action);
      if (spec != null && !spec.isVisible(ctx)) continue;
      final enabled = action == null ? ready && state.save.phase != SavePhase.readOnly : spec!.isEnabled(ctx);
      final reason = action == null
          ? (ready ? (enabled ? null : ProjectStrings.statusReadOnly) : ProjectStrings.notOpen)
          : spec!.disabledReason(ctx);
      final shortcut = showKeys ? spec?.primaryShortcut : null;
      rows.add(DanaviewListTile(
        key: ValueKey<String>('project.${c.name}'),
        title: c.title,
        subtitle: enabled ? subtitleOf(c) : reason,
        leading: Icon(c.icon, size: 20, color: DanaviewColors.textSecondary),
        trailing: shortcut == null
            ? null
            : Text(shortcut, style: DanaviewTextStyles.caption.copyWith(fontFamily: DanaviewFonts.family, color: DanaviewColors.textSecondary)),
        enabled: enabled,
        showChevron: shortcut == null && c != ProjectSheetChoice.save,
        onTap: () => Navigator.of(context).pop(c),
      ));
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          key: const ValueKey<String>('project.header'),
          padding: const EdgeInsets.fromLTRB(4, 0, 4, DanaviewSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                project?.name ?? '',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: DanaviewTextStyles.body.copyWith(fontFamily: DanaviewFonts.family, fontWeight: FontWeight.w600, color: DanaviewColors.textPrimary),
              ),
              const SizedBox(height: DanaviewSpacing.xxs),
              Semantics(
                label: ProjectStrings.statusSemantics(status),
                excludeSemantics: true,
                child: Text(
                  status,
                  key: const ValueKey<String>('project.status'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DanaviewTextStyles.caption.copyWith(
                    fontFamily: DanaviewFonts.family,
                    color: state.save.phase == SavePhase.failed ? DanaviewColors.errorLight : DanaviewColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
        ...rows,
      ],
    );
  }
}
