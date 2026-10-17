// OWNER: UX-40
//
// The recovery dialog of the editor (ux.md §13.3): opening a project whose journal is newer than its
// saved document (`LoadedProject.pendingRecovery`) asks "Restore unsaved changes?" with Restore
// (primary) and Open last saved. Open last saved keeps the journal until the next successful save,
// so the changes stay restorable from Projects.
//
// [restoreUnsavedChanges] does the restore for an open editor: it closes the editor (nothing to
// save yet), lets the store promote the journal, closes the project again and rebuilds the editor
// controller, which opens the restored project. If the store refuses, the editor opens the last
// saved version again and the dialog's journal stays.

import 'dart:async';

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart' show ProjectId;
import 'package:danaview_editor_core/store.dart' show RecoverableSession;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../../app/editor_providers.dart';
import '../../../app/strings/relink_strings.dart';

/// What the user chose in the recovery dialog.
enum EditorRecoveryChoice {
  /// Restore the unsaved changes.
  restore,

  /// Keep the last saved version (the journal stays until the next save).
  openLastSaved,
}

/// Shows "Restore unsaved changes?" for [session]; resolves to the choice, or null when dismissed
/// (treated as Open last saved).
Future<EditorRecoveryChoice?> showEditorRecoveryDialog(BuildContext context, RecoverableSession session, {required DateTime now}) =>
    showDanaviewDialog<EditorRecoveryChoice>(
      context,
      barrierDismissible: false,
      builder: (context) => EditorRecoveryDialog(session: session, now: now),
    );

/// The dialog's content.
class EditorRecoveryDialog extends StatelessWidget {
  /// Creates the dialog for [session]; [now] decides how the time of the changes reads.
  const EditorRecoveryDialog({super.key, required this.session, required this.now});

  /// The journal that can be restored.
  final RecoverableSession session;

  /// The current time.
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final when = RelinkStrings.when(session.journalSavedAt, now);
    return DanaviewDialog(
      icon: Icons.history_rounded,
      title: RelinkStrings.recoveryTitle,
      message: RelinkStrings.recoveryMessage(session.projectName, when),
      content: Text(RelinkStrings.openLastSavedNote, style: DanaviewTextStyles.caption.copyWith(color: DanaviewColors.textSecondary, height: 1.35)),
      actions: [
        DanaviewButton.secondary(
          key: const ValueKey('recovery-open-last-saved'),
          label: RelinkStrings.openLastSaved,
          onPressed: () => Navigator.of(context).pop(EditorRecoveryChoice.openLastSaved),
        ),
        DanaviewButton.primary(
          key: const ValueKey('recovery-restore'),
          label: RelinkStrings.restore,
          onPressed: () => Navigator.of(context).pop(EditorRecoveryChoice.restore),
        ),
      ],
    );
  }
}

/// Restores [session]'s journal into the open editor of [id] (see the file header). Returns whether
/// the journal was restored.
Future<bool> restoreUnsavedChanges(WidgetRef ref, ProjectId id, RecoverableSession session) async {
  final repository = ref.read(projectRepositoryProvider);
  final editor = ref.read(editorControllerProvider(id).notifier);
  var restored = false;
  try {
    await editor.close();
    await repository.restore(session);
    restored = true;
    await repository.close(id);
  } on Object catch (e) {
    if (e is Error) rethrow;
    debugPrint('[Recovery] Restore failed: ${e.runtimeType}');
  } finally {
    // A fresh controller opens whatever the store has now.
    ref.invalidate(editorControllerProvider(id));
  }
  return restored;
}
