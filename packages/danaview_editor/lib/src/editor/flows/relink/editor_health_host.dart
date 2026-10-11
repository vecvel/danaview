// OWNER: UX-40
//
// EditorHealthHost: the one widget the editor screen places under its top bar for the health of the
// open project (ux.md §13).
//
// * It starts the media health controller (watching availability for as long as the host is
//   mounted, with a re-check when the app resumes) and shows the read-only banner (newer schema,
//   D-12) and the missing media banner above each other.
// * When the project opens with a pending recovery (`LoadedProject.pendingRecovery`) it asks once
//   "Restore unsaved changes?" and restores or keeps the last saved version (see
//   recovery_dialog.dart).
// * A project whose newest copy was damaged opens from the last good one (the store falls back to
//   its backup) and says so in a banner until dismissed.
// * Migration is a one-time toast the controller already emits (`EditorMessages.migrated`); a
//   project that needs a newer app never opens (the shell shows the failure).

import 'dart:async';

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart' show ProjectId;
import 'package:danaview_editor_core/store.dart' show RecoverableSession, restoredFromBackupWarning;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../../app/editor_providers.dart';
import '../../../app/strings/relink_strings.dart';
import '../../../projects/projects_controller.dart' show projectsClockProvider;
import '../../editor_scope.dart';
import '../../state/editor_session.dart';
import '../../state/media_health_controller.dart';
import 'missing_media_banner.dart';
import 'recovery_dialog.dart';

/// Banners and the recovery prompt of the open project (see the file header).
class EditorHealthHost extends ConsumerStatefulWidget {
  /// Creates the host for the project of the nearest `EditorScope` (or [projectId]).
  const EditorHealthHost({super.key, this.projectId});

  /// The project, when not below an `EditorScope`.
  final ProjectId? projectId;

  @override
  ConsumerState<EditorHealthHost> createState() => _EditorHealthHostState();
}

class _EditorHealthHostState extends ConsumerState<EditorHealthHost> with WidgetsBindingObserver {
  EditorSession? _session;
  RecoverableSession? _prompted;
  bool _prompting = false;
  bool _backupDismissed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session?.attached.removeListener(_attachedChanged);
    super.dispose();
  }

  ProjectId get _id => widget.projectId ?? EditorScope.idOf(context);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) ref.read(mediaHealthControllerProvider(_id).notifier).refresh();
  }

  void _attachedChanged() {
    final session = _session;
    if (!mounted || session == null || !session.attached.value) return;
    final pending = session.loaded?.pendingRecovery;
    if (pending == null || identical(pending, _prompted) || _prompting) return;
    _prompted = pending;
    unawaited(_prompt(pending));
  }

  Future<void> _prompt(RecoverableSession pending) async {
    _prompting = true;
    try {
      final id = _id;
      final now = ref.read(projectsClockProvider)();
      final choice = await showEditorRecoveryDialog(context, pending, now: now);
      if (!mounted || choice != EditorRecoveryChoice.restore) return;
      final restored = await restoreUnsavedChanges(ref, id, pending);
      if (!mounted) return;
      DanaviewToast.show(
        context,
        restored ? RelinkStrings.restored : RelinkStrings.restoreFailed,
        icon: restored ? Icons.restore_rounded : Icons.error_outline_rounded,
        kind: restored ? DanaviewToastKind.success : DanaviewToastKind.error,
      );
    } finally {
      _prompting = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final id = _id;
    // Starts the health controller; stays subscribed while the host is mounted.
    ref.watch(mediaHealthControllerProvider(id).select((s) => s.checked));
    final session = ref.watch(editorSessionProvider(id));
    if (!identical(session, _session)) {
      _session?.attached.removeListener(_attachedChanged);
      _session = session..attached.addListener(_attachedChanged);
      WidgetsBinding.instance.addPostFrameCallback((_) => _attachedChanged());
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ReadOnlyBanner(projectId: id),
        ValueListenableBuilder<bool>(
          valueListenable: session.attached,
          builder: (context, attached, _) {
            final restored = attached && !_backupDismissed && (session.loaded?.warnings.any((w) => w.code == restoredFromBackupWarning) ?? false);
            return restored ? BackupRestoredBanner(onDismiss: () => setState(() => _backupDismissed = true)) : const SizedBox.shrink();
          },
        ),
        MissingMediaBanner(projectId: id),
      ],
    );
  }
}
