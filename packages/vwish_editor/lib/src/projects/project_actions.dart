// OWNER: UX-05
//
// The actions of one project (ux.md §5.2): Open (with the "needs a newer Vwish" and "damaged"
// dialogs instead of opening), Rename (a sheet with a validated text field, 1–80 characters),
// Duplicate (toast), Delete (destructive confirmation, then the undo window of
// `ProjectsController.requestDelete`). Failures are typed `ProjectsFailure`s shown as toasts with a
// next step.

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart' show TextInputAction;
import 'package:flutter/widgets.dart';
import 'package:vwish_editor_core/model.dart' show ProjectId;
import 'package:vwish_editor_core/store.dart' show ProjectHealth, ProjectSummary;
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import '../app/strings/projects_strings.dart';
import 'project_card.dart';
import 'projects_controller.dart';

/// Rename, duplicate, delete and open for the projects of the Projects screen (ux.md §5.2).
@immutable
final class ProjectActions {
  /// Creates the actions over [controller]; [onOpen] opens a project in the editor.
  const ProjectActions({required this.controller, required this.onOpen});

  /// The Projects controller.
  final ProjectsController controller;

  /// Opens a project in the editor (the router pushes `/editor/:id`).
  final void Function(ProjectId id) onOpen;

  /// Whether [summary] can be renamed or duplicated (not for newer or damaged projects).
  static bool editable(ProjectSummary summary) => summary.health == ProjectHealth.ok;

  /// The card menu of [summary].
  List<VwishMenuEntry> menuFor(BuildContext context, ProjectSummary summary) => [
        VwishMenuItem(
          label: ProjectsStrings.open,
          icon: Icons.open_in_new_rounded,
          onTap: () => open(context, summary),
        ),
        VwishMenuItem(
          label: ProjectsStrings.rename,
          icon: Icons.drive_file_rename_outline_rounded,
          enabled: editable(summary),
          onTap: () => rename(context, summary),
        ),
        VwishMenuItem(
          label: ProjectsStrings.duplicate,
          icon: Icons.copy_all_rounded,
          enabled: editable(summary),
          onTap: () => duplicate(context, summary),
        ),
        const VwishMenuDivider(),
        VwishMenuItem(
          label: ProjectsStrings.delete,
          icon: Icons.delete_outline_rounded,
          destructive: true,
          onTap: () => delete(context, summary),
        ),
      ];

  /// The semantics custom actions of [summary]'s card.
  List<ProjectCardAction> semanticActionsFor(BuildContext context, ProjectSummary summary) => [
        if (editable(summary)) ProjectCardAction(ProjectsStrings.rename, () => rename(context, summary)),
        if (editable(summary)) ProjectCardAction(ProjectsStrings.duplicate, () => duplicate(context, summary)),
        ProjectCardAction(ProjectsStrings.delete, () => delete(context, summary)),
      ];

  /// Opens [summary], or explains why it can't be opened (ux.md §5.2).
  Future<void> open(BuildContext context, ProjectSummary summary) async {
    switch (summary.health) {
      case ProjectHealth.needsNewerApp:
        await _explain(context, ProjectsStrings.needsUpdateTitle, ProjectsStrings.needsUpdateMessage, Icons.system_update_rounded);
      case ProjectHealth.corrupt:
        await _explain(context, ProjectsStrings.corruptTitle, ProjectsStrings.corruptMessage, Icons.report_rounded);
      case ProjectHealth.ok || ProjectHealth.readOnlyNewer:
        onOpen(summary.id);
    }
  }

  Future<void> _explain(BuildContext context, String title, String message, IconData icon) => showVwishDialog<void>(
        context,
        builder: (context) => VwishDialog(
          icon: icon,
          iconColor: VwishColors.warning,
          title: title,
          message: message,
          actions: [VwishButton.primary(label: ProjectsStrings.ok, onPressed: () => Navigator.of(context).pop())],
        ),
      );

  /// Asks for a new name and renames [summary].
  Future<void> rename(BuildContext context, ProjectSummary summary) async {
    final name = await showRenameProjectSheet(context, initialName: summary.name);
    if (name == null || name == summary.name || !context.mounted) return;
    try {
      await controller.rename(summary.id, name);
      if (context.mounted) _toast(context, ProjectsStrings.renamed(name), success: true);
    } on ProjectsFailure catch (failure) {
      if (context.mounted) _fail(context, 'rename', summary.name, failure);
    }
  }

  /// Duplicates [summary].
  Future<void> duplicate(BuildContext context, ProjectSummary summary) async {
    try {
      final id = await controller.duplicate(summary.id);
      if (!context.mounted) return;
      final copy = controller.summaryOf(id)?.name;
      _toast(context, copy == null ? ProjectsStrings.duplicatedPlain : ProjectsStrings.duplicated(copy), success: true);
    } on ProjectsFailure catch (failure) {
      if (context.mounted) _fail(context, 'duplicate', summary.name, failure);
    }
  }

  /// Confirms, then deletes [summary] after the undo window.
  Future<void> delete(BuildContext context, ProjectSummary summary) async {
    final confirmed = await showVwishConfirm(
      context,
      title: ProjectsStrings.deleteTitle(summary.name),
      message: ProjectsStrings.deleteMessage,
      confirmLabel: ProjectsStrings.deleteConfirm,
      destructive: true,
      icon: Icons.delete_outline_rounded,
    );
    if (!confirmed) return;
    controller.requestDelete(summary.id);
  }

  static void _toast(BuildContext context, String message, {bool success = false}) => VwishToast.show(
        context,
        message,
        kind: success ? VwishToastKind.success : VwishToastKind.info,
        icon: success ? Icons.check_circle_rounded : Icons.info_outline_rounded,
      );

  static void _fail(BuildContext context, String action, String name, ProjectsFailure failure) => showProjectsFailure(
        context,
        ProjectsNotice(action: action, projectName: name, failure: failure),
      );
}

/// Shows a failed project action as an error toast with its next step.
void showProjectsFailure(BuildContext context, ProjectsNotice notice) => VwishToast.show(context, notice.text,
    kind: VwishToastKind.error, icon: Icons.error_outline_rounded, duration: const Duration(seconds: 4));

/// Asks for a project name in a sheet; resolves to the trimmed name, or null when cancelled.
Future<String?> showRenameProjectSheet(BuildContext context, {required String initialName}) => showVwishSheet<String>(
      context,
      title: ProjectsStrings.renameTitle,
      builder: (context) => RenameProjectForm(initialName: initialName),
    );

/// The rename sheet's content: a text field validated to 1–80 characters, Cancel and Save.
class RenameProjectForm extends StatefulWidget {
  /// Creates the form.
  const RenameProjectForm({super.key, required this.initialName});

  /// The current name.
  final String initialName;

  @override
  State<RenameProjectForm> createState() => _RenameProjectFormState();
}

class _RenameProjectFormState extends State<RenameProjectForm> {
  late final TextEditingController _text = TextEditingController(text: widget.initialName)
    ..selection = TextSelection(baseOffset: 0, extentOffset: widget.initialName.length);
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _save() {
    final error = ProjectsStrings.validateName(_text.text);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop(_text.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        VwishTextField(
          key: const ValueKey('rename-project-field'),
          controller: _text,
          autofocus: true,
          hint: ProjectsStrings.renameHint,
          errorText: _error,
          textInputAction: TextInputAction.done,
          semanticLabel: ProjectsStrings.renameHint,
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: VwishSpacing.lg),
        VwishButtonBar(
          children: [
            VwishButton.secondary(label: ProjectsStrings.cancel, onPressed: () => Navigator.of(context).pop()),
            VwishButton.primary(key: const ValueKey('rename-project-save'), label: ProjectsStrings.save, onPressed: _save),
          ],
        ),
      ],
    );
  }
}
