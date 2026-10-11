// OWNER: UX-39
//
// The export sheet (ux.md §11.2, §11.4, D-24): one `showVwishSheet` that follows the
// `ExportController` state: pre-check steps, presets and settings, preparing, progress, completion
// and failure. It is modal and not dismissible while an export prepares or runs (no scrim tap, no
// drag, no Close button; system back asks to stop the export), so editing is blocked meanwhile
// (D-24).
//
// * `ExportSheet.show` runs the pre-checks first: an empty timeline only shows the toast "Add a clip
//   before exporting."; everything else opens the sheet in the state the check found.
// * `ExportSheet.showIfPending` is for the editor and the Projects screen after opening: it reattaches
//   to a running or resumable export and shows one-shot records (interrupted, finished while away).
// * "Relink files" and "Change project to 9:16" close the sheet and run the `relink` and `format`
//   actions through the action registry (UX-40, the Canvas panel).

import 'dart:async';

import 'package:flutter/material.dart' show Icons, Theme;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vwish_editor_core/model.dart' show ProjectId;
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import '../../../app/strings/export_strings.dart';
import '../../actions/editor_action_registry.dart';
import '../../contracts/contracts.dart';
import '../../../app/editor_providers.dart';
import 'export_controller.dart';
import 'export_setup_view.dart';
import 'export_status_views.dart';

/// What the user asked for by leaving the sheet.
enum ExportSheetExit {
  /// Closed.
  closed,

  /// "Relink files".
  relink,

  /// "Change project to 9:16".
  changeFormat,
}

/// Presets, settings, progress and completion of an export (ux.md §11.2).
class ExportSheet extends ConsumerStatefulWidget {
  /// Creates the sheet content for [projectId]; use [show] or [showIfPending] to present it.
  const ExportSheet({super.key, required this.projectId});

  /// The project.
  final ProjectId projectId;

  /// Runs the pre-checks and shows the sheet. Returns false when nothing was shown (empty timeline).
  static Future<bool> show(BuildContext context, {required ProjectId projectId}) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final hold = container.listen<ExportUiState>(exportControllerProvider(projectId), (_, __) {});
    try {
      final result = await container.read(exportControllerProvider(projectId).notifier).prepare();
      if (!context.mounted) return false;
      if (result == ExportPrepare.emptyTimeline) {
        VwishToast.show(context, ExportStrings.emptyTimeline);
        return false;
      }
      await _present(context, container, projectId);
      return true;
    } finally {
      hold.close();
    }
  }

  /// After the editor (or the Projects screen) opened: shows the sheet when an export is running,
  /// can be resumed, was interrupted or finished while Vwish was away (ARCH §14.1, D-22, D-39).
  /// Returns whether it was shown.
  static Future<bool> showIfPending(BuildContext context, {required ProjectId projectId}) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final hold = container.listen<ExportUiState>(exportControllerProvider(projectId), (_, __) {});
    try {
      final found = await container.read(exportControllerProvider(projectId).notifier).reattach();
      if (found == ExportReattach.none || !context.mounted) return false;
      await _present(context, container, projectId);
      return true;
    } finally {
      hold.close();
    }
  }

  static Future<void> _present(BuildContext context, ProviderContainer container, ProjectId projectId) async {
    final exit = await showVwishSheet<ExportSheetExit>(
      context,
      isDismissible: false,
      showDragHandle: false,
      builder: (_) => ExportSheet(projectId: projectId),
    );
    if (exit == null || exit == ExportSheetExit.closed || !context.mounted) return;
    final registry = container.read(editorActionRegistryProvider);
    final id = exit == ExportSheetExit.relink ? EditorActionId.relink : EditorActionId.format;
    registry.invoke(id, WidgetActionContext.container(projectId: projectId, context: context, container: container));
  }

  @override
  ConsumerState<ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends ConsumerState<ExportSheet> {
  ExportController get _controller => ref.read(exportControllerProvider(widget.projectId).notifier);

  void _pop([ExportSheetExit exit = ExportSheetExit.closed]) {
    if (!mounted) return;
    Navigator.of(context).pop(exit);
  }

  Future<void> _confirmCancel() async {
    final stop = await showVwishConfirm(
      context,
      title: ExportStrings.cancelConfirmTitle,
      message: ExportStrings.cancelConfirmMessage,
      confirmLabel: ExportStrings.stopExport,
      cancelLabel: ExportStrings.keepExporting,
      destructive: true,
      icon: Icons.stop_circle_outlined,
    );
    if (stop && mounted) unawaited(_controller.cancel());
  }

  void _onBlockedPop(ExportUiState state) {
    if (state is ExportUiRunning) {
      unawaited(_confirmCancel());
    } else if (state is ExportUiPreparing) {
      unawaited(_controller.cancel());
    }
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.projectId;
    final state = ref.watch(exportControllerProvider(id));
    final controller = _controller;
    ref.listen<ExportUiState>(exportControllerProvider(id), (previous, next) {
      if (next is ExportUiCancelled && previous is! ExportUiCancelled) {
        VwishToast.show(context, ExportStrings.cancelled);
        _pop();
      }
    });
    final platform = Theme.of(context).platform;
    final busy = exportIsBusy(state);
    return PopScope(
      canPop: !busy,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          unawaited(controller.acknowledgeRecord());
        } else {
          _onBlockedPop(ref.read(exportControllerProvider(id)));
        }
      },
      child: Semantics(
        container: true,
        label: ExportStrings.sheetLabel,
        child: Column(
          key: const ValueKey('export-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SheetHeader(busy: busy, onClose: _pop),
            const SizedBox(height: VwishSpacing.sm),
            switch (state) {
              ExportUiIdle() => const ExportCheckingView(),
              ExportUiNeedsRelink(:final count) => ExportRelinkView(
                  count: count,
                  onRelink: () => _pop(ExportSheetExit.relink),
                  onClose: _pop,
                ),
              ExportUiWaiting() => ExportWaitingView(state: state, onClose: _pop),
              ExportUiSetup() => ExportSetupView(
                  setup: state,
                  controller: controller,
                  platform: platform,
                  onChangeAspect: () => _pop(ExportSheetExit.changeFormat),
                ),
              ExportUiNotice() => ExportNoticeView(state: state, controller: controller),
              ExportUiWarnings() => ExportWarningsView(state: state, controller: controller),
              ExportUiPreparing() => ExportPreparingView(state: state, controller: controller),
              ExportUiRunning() => ExportRunningView(state: state, onCancel: _confirmCancel),
              ExportUiCancelling() => const ExportCancellingView(),
              ExportUiCancelled() => const ExportCancellingView(),
              ExportUiInterrupted() => ExportInterruptedView(state: state, controller: controller, onClose: _pop),
              ExportUiCompleted() => ExportCompletedView(
                  state: state,
                  controller: controller,
                  platform: platform,
                  onDone: () async {
                    await controller.done();
                    _pop();
                  },
                ),
              ExportUiFailed() => ExportFailedView(state: state, controller: controller),
              ExportUiFinishedAway() => ExportFinishedAwayView(
                  state: state,
                  controller: controller,
                  platform: platform,
                  onDone: () async {
                    await controller.acknowledgeRecord();
                    _pop();
                  },
                ),
            },
          ],
        ),
      ),
    );
  }
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({required this.busy, required this.onClose});

  final bool busy;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: VwishSpacing.sm),
        child: Row(
          children: [
            Expanded(
              child: Semantics(header: true, child: Text(ExportStrings.sheetTitle, style: ExportText.title)),
            ),
            if (!busy)
              VwishIconButton(
                key: const ValueKey('export-close'),
                icon: Icons.close_rounded,
                size: 32,
                iconSize: 18,
                variant: VwishIconButtonVariant.filled,
                tooltip: ExportStrings.close,
                onPressed: onClose,
              ),
          ],
        ),
      );
}
