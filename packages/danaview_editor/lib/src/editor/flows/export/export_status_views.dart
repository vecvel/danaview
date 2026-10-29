// OWNER: UX-39
//
// The non-settings states of the export sheet (ux.md §11.4): pre-check steps (relink, waiting for
// reverse and freeze jobs), the first-export notice, preflight warnings, Preparing, Running with
// phase, ETA and the background copy per `BackgroundExportKind`, Cancelling, Interrupted with
// "Resume export", Completed with the destinations, Failed with the fallbacks, and the one-shot
// "Your export finished" card (D-39). Custom components only; text wraps instead of truncating.

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter/widgets.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../../app/editor_messages.dart';
import '../../../app/strings/export_strings.dart';
import '../../state/editor_state.dart' show ExportFailed, ExportFailureKind;
import 'export_controller.dart';
import 'export_setup_view.dart' show ExportText;

/// Icon tile, title and detail of a state.
class ExportStatusHeader extends StatelessWidget {
  /// Creates the header; [spinner] shows a spinner instead of the icon.
  const ExportStatusHeader({super.key, this.icon, this.color = DanaviewColors.primaryLight, required this.title, this.detail, this.spinner = false});

  /// Icon.
  final IconData? icon;

  /// Icon colour.
  final Color color;

  /// Title.
  final String title;

  /// Detail under the title.
  final String? detail;

  /// Whether to show a spinner.
  final bool spinner;

  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        container: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (spinner)
              const SizedBox(width: 40, height: 40, child: Center(child: DanaviewSpinner(size: 24, semanticLabel: 'Working')))
            else
              ExcludeSemantics(child: DanaviewIconTile(icon ?? Icons.ios_share_rounded, color: color, size: 40)),
            const SizedBox(width: DanaviewSpacing.md),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: ExportText.headline),
                  if (detail != null) ...[
                    const SizedBox(height: 2),
                    Text(detail!, style: ExportText.caption.copyWith(color: DanaviewColors.textSecondary)),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
}

String _clock(Duration d) {
  final total = d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

/// Spacing between the header block and the buttons.
const SizedBox _gap = SizedBox(height: DanaviewSpacing.lg);

/// The pre-checks are running.
class ExportCheckingView extends StatelessWidget {
  /// Creates the view.
  const ExportCheckingView({super.key});

  @override
  Widget build(BuildContext context) => const Column(
        key: ValueKey('export-checking'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [ExportStatusHeader(spinner: true, title: ExportStrings.checking)],
      );
}

/// Missing media: relink first (ux.md §11.1 check 1).
class ExportRelinkView extends StatelessWidget {
  /// Creates the view.
  const ExportRelinkView({super.key, required this.count, required this.onRelink, required this.onClose});

  /// Missing files.
  final int count;

  /// Opens the relink sheet.
  final VoidCallback onRelink;

  /// Closes the sheet.
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Column(
        key: const ValueKey('export-relink'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ExportStatusHeader(icon: Icons.link_off_rounded, color: DanaviewColors.warning, title: ExportStrings.relinkHeadline(count), detail: ExportStrings.relinkDetail),
          _gap,
          DanaviewButtonBar(children: [
            DanaviewButton.secondary(key: const ValueKey('export-relink-cancel'), label: ExportStrings.cancel, onPressed: onClose),
            DanaviewButton.primary(key: const ValueKey('export-relink-button'), label: ExportStrings.relinkButton, icon: Icons.link_rounded, onPressed: onRelink),
          ]),
        ],
      );
}

/// Waiting for reverse and freeze jobs (ux.md §11.1 check 2).
class ExportWaitingView extends StatelessWidget {
  /// Creates the view.
  const ExportWaitingView({super.key, required this.state, required this.onClose});

  /// The state.
  final ExportUiWaiting state;

  /// Closes the sheet (Cancel).
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Column(
        key: const ValueKey('export-waiting'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ExportStatusHeader(spinner: true, title: ExportStrings.waitingHeadline(state.count), detail: ExportStrings.waitingDetail),
          const SizedBox(height: DanaviewSpacing.md),
          DanaviewProgressBar(value: state.progress, semanticLabel: ExportStrings.waitingHeadline(state.count)),
          _gap,
          DanaviewButtonBar(children: [
            DanaviewButton.secondary(key: const ValueKey('export-waiting-cancel'), label: ExportStrings.cancel, onPressed: onClose),
          ]),
        ],
      );
}

/// The first-export notice about the background (ux.md §11.5).
class ExportNoticeView extends StatelessWidget {
  /// Creates the view.
  const ExportNoticeView({super.key, required this.state, required this.controller});

  /// The state.
  final ExportUiNotice state;

  /// The controller.
  final ExportController controller;

  @override
  Widget build(BuildContext context) => Column(
        key: const ValueKey('export-notice'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ExportStatusHeader(
            icon: Icons.notifications_active_rounded,
            title: ExportStrings.backgroundNoticeTitle,
            detail: state.explainNotifications ? ExportStrings.notificationExplainer : ExportStrings.backgroundCopy(state.kind),
          ),
          if (state.explainNotifications) ...[
            const SizedBox(height: DanaviewSpacing.md),
            Text(ExportStrings.backgroundCopy(state.kind), style: ExportText.secondary),
          ],
          _gap,
          DanaviewButtonBar(children: [
            DanaviewButton.secondary(key: const ValueKey('export-notice-back'), label: ExportStrings.noticeBack, onPressed: controller.backToSetup),
            DanaviewButton.primary(key: const ValueKey('export-notice-continue'), label: ExportStrings.noticeContinue, onPressed: controller.confirmNotice),
          ]),
        ],
      );
}

/// Preflight warnings to confirm.
class ExportWarningsView extends StatelessWidget {
  /// Creates the view.
  const ExportWarningsView({super.key, required this.state, required this.controller});

  /// The state.
  final ExportUiWarnings state;

  /// The controller.
  final ExportController controller;

  @override
  Widget build(BuildContext context) => Column(
        key: const ValueKey('export-warnings'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const ExportStatusHeader(icon: Icons.warning_amber_rounded, color: DanaviewColors.warning, title: ExportStrings.warningsTitle),
          const SizedBox(height: DanaviewSpacing.sm),
          for (final w in state.warnings)
            Padding(
              padding: const EdgeInsets.only(top: DanaviewSpacing.sm),
              child: Text(ExportStrings.warning(w.code), key: ValueKey('export-warning-${w.code}'), style: ExportText.body),
            ),
          _gap,
          DanaviewButtonBar(children: [
            DanaviewButton.secondary(key: const ValueKey('export-warnings-back'), label: ExportStrings.changeSettings, onPressed: controller.backToSetup),
            DanaviewButton.primary(key: const ValueKey('export-warnings-continue'), label: ExportStrings.exportAnyway, onPressed: controller.confirmWarnings),
          ]),
        ],
      );
}

/// Preparing: sprite pre-pass, compile and preflight.
class ExportPreparingView extends StatelessWidget {
  /// Creates the view.
  const ExportPreparingView({super.key, required this.state, required this.controller});

  /// The state.
  final ExportUiPreparing state;

  /// The controller.
  final ExportController controller;

  @override
  Widget build(BuildContext context) => Column(
        key: const ValueKey('export-preparing'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ExportStatusHeader(spinner: true, title: state.cancelling ? ExportStrings.cancelling : ExportStrings.preparing),
          const SizedBox(height: DanaviewSpacing.md),
          DanaviewProgressBar(value: state.fraction, semanticLabel: ExportStrings.preparing),
          _gap,
          DanaviewButtonBar(children: [
            DanaviewButton.secondary(
              key: const ValueKey('export-preparing-cancel'),
              label: ExportStrings.cancel,
              onPressed: state.cancelling ? null : controller.cancel,
            ),
          ]),
        ],
      );
}

/// Encoding: percent, phase, ETA, background copy, Cancel.
class ExportRunningView extends StatelessWidget {
  /// Creates the view; [onCancel] asks for confirmation.
  const ExportRunningView({super.key, required this.state, required this.onCancel});

  /// The state.
  final ExportUiRunning state;

  /// Cancel pressed.
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final note = state.pausedInBackground
        ? ExportStrings.pausedInBackground
        : state.backgrounded
            ? ExportStrings.runningInBackground
            : state.notificationsUnanswered
                ? ExportStrings.notificationsUnanswered
                : ExportStrings.backgroundCopy(state.backgroundKind);
    final eta = state.eta;
    return Column(
      key: const ValueKey('export-running'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          liveRegion: true,
          container: true,
          label: '${ExportStrings.progressLabel} ${ExportStrings.percent(state.fraction)}',
          child: ExcludeSemantics(
            child: Text(ExportStrings.percent(state.fraction), key: const ValueKey('export-percent'), style: ExportText.big),
          ),
        ),
        const SizedBox(height: DanaviewSpacing.sm),
        DanaviewProgressBar(value: state.fraction, height: 8, semanticLabel: ExportStrings.progressLabel),
        const SizedBox(height: DanaviewSpacing.sm),
        Text(ExportStrings.phaseLabel(state.phase), key: const ValueKey('export-phase'), style: ExportText.headline),
        if (eta != null) ...[
          const SizedBox(height: 2),
          Text(ExportStrings.eta(eta), key: const ValueKey('export-eta'), style: ExportText.secondary),
        ],
        const SizedBox(height: DanaviewSpacing.md),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(padding: EdgeInsets.only(top: 1), child: Icon(Icons.info_outline_rounded, size: 16, color: DanaviewColors.textSecondary)),
            const SizedBox(width: DanaviewSpacing.sm),
            Expanded(child: Text(note, key: const ValueKey('export-background-copy'), style: ExportText.caption.copyWith(color: DanaviewColors.textSecondary))),
          ],
        ),
        for (final w in state.warnings)
          if (w.code != 'backgroundPauses' && !exportBlockingWarnings.contains(w.code))
            Padding(
              padding: const EdgeInsets.only(top: DanaviewSpacing.xs),
              child: Text(ExportStrings.warning(w.code), style: ExportText.caption),
            ),
        _gap,
        DanaviewButtonBar(children: [
          DanaviewButton.secondary(key: const ValueKey('export-cancel'), label: ExportStrings.cancel, icon: Icons.close_rounded, onPressed: onCancel),
        ]),
      ],
    );
  }
}

/// Cancelling.
class ExportCancellingView extends StatelessWidget {
  /// Creates the view.
  const ExportCancellingView({super.key});

  @override
  Widget build(BuildContext context) => const Column(
        key: ValueKey('export-cancelling'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [ExportStatusHeader(spinner: true, title: ExportStrings.cancelling)],
      );
}

/// Interrupted: resume or start again (D-22).
class ExportInterruptedView extends StatelessWidget {
  /// Creates the view.
  const ExportInterruptedView({super.key, required this.state, required this.controller, required this.onClose});

  /// The state.
  final ExportUiInterrupted state;

  /// The controller.
  final ExportController controller;

  /// Closes the sheet.
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Column(
        key: const ValueKey('export-interrupted'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ExportStatusHeader(
            icon: Icons.pause_circle_outline_rounded,
            color: DanaviewColors.warning,
            title: ExportStrings.interruptedTitle,
            detail: state.canResume ? ExportStrings.interruptedCanResume(state.doneFraction) : ExportStrings.interruptedStartAgain,
          ),
          _gap,
          DanaviewButtonBar(children: [
            DanaviewButton.secondary(key: const ValueKey('export-interrupted-close'), label: ExportStrings.close, onPressed: onClose),
            if (state.canResume)
              DanaviewButton.primary(key: const ValueKey('export-resume'), label: ExportStrings.resume, icon: Icons.play_arrow_rounded, onPressed: controller.resume)
            else
              DanaviewButton.primary(key: const ValueKey('export-start-again'), label: ExportStrings.startAgain, onPressed: controller.startAgain),
          ]),
        ],
      );
}

/// Completed: where it went, what to do next.
class ExportCompletedView extends StatelessWidget {
  /// Creates the view.
  const ExportCompletedView({super.key, required this.state, required this.controller, required this.platform, required this.onDone});

  /// The state.
  final ExportUiCompleted state;

  /// The controller.
  final ExportController controller;

  /// The theme platform.
  final TargetPlatform platform;

  /// Done pressed.
  final VoidCallback onDone;

  String get _title {
    switch (state.handoff) {
      case ExportHandoffStatus.pending:
        return ExportStrings.saving(platform, toLibrary: state.destination == ExportDestination.photos);
      case ExportHandoffStatus.saved:
        return switch (state.destination) {
          ExportDestination.photos => ExportStrings.savedToLibrary(platform),
          ExportDestination.files => ExportStrings.savedToFiles,
          ExportDestination.share => ExportStrings.shared,
        };
      case ExportHandoffStatus.notSaved || ExportHandoffStatus.denied || ExportHandoffStatus.failed:
        return ExportStrings.exportReady;
    }
  }

  @override
  Widget build(BuildContext context) {
    final saved = state.handoff == ExportHandoffStatus.saved;
    final failure = state.handoffFailure;
    final failureMessage = failure == null ? null : editorFailureMessage(failure);
    final duration = Duration(microseconds: state.result.duration);
    final busy = state.busy;
    return Column(
      key: const ValueKey('export-completed'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExportStatusHeader(
          icon: saved ? Icons.check_circle_rounded : Icons.movie_rounded,
          color: saved ? DanaviewColors.success : DanaviewColors.primaryLight,
          spinner: state.handoff == ExportHandoffStatus.pending,
          title: _title,
          detail: ExportStrings.fileInfo(state.result.bytes, _clock(duration)),
        ),
        if (state.handoff == ExportHandoffStatus.notSaved) ...[
          const SizedBox(height: DanaviewSpacing.sm),
          Text(ExportStrings.notSavedYet, key: const ValueKey('export-not-saved'), style: ExportText.secondary),
        ],
        if (failureMessage != null) ...[
          const SizedBox(height: DanaviewSpacing.sm),
          Text(failureMessage.title, key: const ValueKey('export-handoff-failure'), style: ExportText.body),
          if (failureMessage.detail != null) Text(failureMessage.detail!, style: ExportText.caption.copyWith(color: DanaviewColors.textSecondary)),
        ],
        if (state.keptCopyName != null) ...[
          const SizedBox(height: DanaviewSpacing.sm),
          _InfoLine(icon: Icons.check_rounded, text: ExportStrings.keptCopy(state.keptCopyName!), key: const ValueKey('export-kept-copy')),
        ],
        if (state.keepCopyFailed) ...[
          const SizedBox(height: DanaviewSpacing.sm),
          const _InfoLine(icon: Icons.info_outline_rounded, text: ExportStrings.keepCopyFailed, key: ValueKey('export-keep-copy-failed')),
        ],
        if (state.sideFiles.isNotEmpty) ...[
          const SizedBox(height: DanaviewSpacing.md),
          Text(ExportStrings.captionFiles, style: ExportText.section),
          const SizedBox(height: DanaviewSpacing.xs),
          for (final (i, f) in state.sideFiles.indexed)
            Padding(
              padding: const EdgeInsets.only(top: DanaviewSpacing.xs),
              child: Align(
                alignment: Alignment.centerLeft,
                child: DanaviewButton.secondary(
                  key: ValueKey('export-side-file-$i'),
                  label: f.saved ? ExportStrings.savedToFiles : ExportStrings.saveCaptionFile(f.name),
                  icon: f.saved ? Icons.check_rounded : Icons.subtitles_rounded,
                  size: DanaviewButtonSize.sm,
                  onPressed: busy || f.saved ? null : () => controller.saveSideFile(i),
                ),
              ),
            ),
        ],
        _gap,
        DanaviewButtonBar(children: [
          if (!state.savedToLibrary)
            DanaviewButton.secondary(
              key: const ValueKey('export-save-library'),
              label: ExportStrings.saveToLibraryButton(platform),
              icon: Icons.photo_library_rounded,
              onPressed: busy ? null : controller.saveToLibrary,
            ),
          DanaviewButton.secondary(
            key: const ValueKey('export-save-files'),
            label: ExportStrings.saveToFilesButton,
            icon: Icons.folder_rounded,
            onPressed: busy ? null : controller.saveToFiles,
          ),
          DanaviewButton.secondary(
            key: const ValueKey('export-share'),
            label: ExportStrings.shareButton,
            icon: Icons.ios_share_rounded,
            onPressed: busy ? null : controller.share,
          ),
          if (controller.canPlay && state.playablePath != null)
            DanaviewButton.secondary(
              key: const ValueKey('export-play'),
              label: ExportStrings.play,
              icon: Icons.play_arrow_rounded,
              onPressed: busy ? null : controller.play,
            ),
          DanaviewButton.primary(key: const ValueKey('export-done'), label: ExportStrings.done, onPressed: busy ? null : onDone),
        ]),
      ],
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 16, color: DanaviewColors.textSecondary)),
          const SizedBox(width: DanaviewSpacing.sm),
          Expanded(child: Text(text, style: ExportText.caption.copyWith(color: DanaviewColors.textSecondary))),
        ],
      );
}

/// Failed: the message with the fallback the failure kind calls for.
class ExportFailedView extends StatelessWidget {
  /// Creates the view.
  const ExportFailedView({super.key, required this.state, required this.controller});

  /// The state.
  final ExportUiFailed state;

  /// The controller.
  final ExportController controller;

  @override
  Widget build(BuildContext context) {
    final message = editorFailureMessage(state.failure);
    var retryIsPrimary = false;
    final primary = switch (message.action) {
      EditorMessageAction.exportH264 =>
        DanaviewButton.primary(key: const ValueKey('export-fallback-h264'), label: ExportStrings.exportH264, onPressed: controller.exportWithH264),
      EditorMessageAction.lowerResolution =>
        DanaviewButton.primary(key: const ValueKey('export-fallback-lower'), label: ExportStrings.lowerResolution, onPressed: controller.lowerResolution),
      EditorMessageAction.freeUpSpace when controller.canFreeUpSpace =>
        DanaviewButton.primary(key: const ValueKey('export-fallback-space'), label: ExportStrings.freeUpSpace, onPressed: controller.freeUpSpace),
      EditorMessageAction.openSettings when controller.canOpenSettings =>
        DanaviewButton.primary(key: const ValueKey('export-fallback-settings'), label: ExportStrings.openSettings, onPressed: controller.openSettings),
      _ => () {
          retryIsPrimary = true;
          return DanaviewButton.primary(key: const ValueKey('export-try-again'), label: ExportStrings.tryAgain, icon: Icons.refresh_rounded, onPressed: controller.retry);
        }(),
    };
    // The fallbacks that leave the export as it is keep "Try again" next to them.
    final retryToo = !retryIsPrimary && (message.action == EditorMessageAction.freeUpSpace || message.action == EditorMessageAction.openSettings);
    return Column(
      key: const ValueKey('export-failed'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExportStatusHeader(icon: Icons.error_outline_rounded, color: DanaviewColors.errorLight, title: message.title, detail: message.detail),
        _gap,
        DanaviewButtonBar(children: [
          DanaviewButton.secondary(
            key: const ValueKey('export-copy-details'),
            label: ExportStrings.copyDetails,
            icon: Icons.copy_rounded,
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: state.details));
              if (context.mounted) DanaviewToast.show(context, ExportStrings.detailsCopied);
            },
          ),
          DanaviewButton.secondary(key: const ValueKey('export-back-to-settings'), label: ExportStrings.backToSettings, onPressed: controller.backToSetup),
          if (retryToo)
            DanaviewButton.secondary(key: const ValueKey('export-try-again'), label: ExportStrings.tryAgain, onPressed: controller.retry),
          primary,
        ]),
      ],
    );
  }
}

/// A one-shot card for an export that finished while Danaview was away (D-39).
class ExportFinishedAwayView extends StatelessWidget {
  /// Creates the view.
  const ExportFinishedAwayView({super.key, required this.state, required this.controller, required this.platform, required this.onDone});

  /// The state.
  final ExportUiFinishedAway state;

  /// The controller.
  final ExportController controller;

  /// The theme platform.
  final TargetPlatform platform;

  /// Done pressed.
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final hasFile = state.result != null;
    final busy = state.busy;
    return Column(
      key: const ValueKey('export-finished-away'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExportStatusHeader(
          icon: Icons.check_circle_rounded,
          color: DanaviewColors.success,
          title: ExportStrings.finishedTitle,
          detail: [
            if (state.savedToGallery) ExportStrings.finishedSaved(platform),
            if (hasFile) ExportStrings.finishedKept,
          ].join(' '),
        ),
        if (state.failed) ...[
          const SizedBox(height: DanaviewSpacing.sm),
          Text(editorFailureMessage(const ExportFailed(ExportFailureKind.destinationDenied)).title, style: ExportText.body),
        ],
        _gap,
        DanaviewButtonBar(children: [
          if (hasFile) ...[
            DanaviewButton.destructive(
              key: const ValueKey('export-finished-delete'),
              label: ExportStrings.deleteExport,
              icon: Icons.delete_outline_rounded,
              onPressed: busy ? null : () async {
                await controller.deleteFinished();
                onDone();
              },
            ),
            DanaviewButton.secondary(
              key: const ValueKey('export-finished-files'),
              label: ExportStrings.saveToFilesButton,
              icon: Icons.folder_rounded,
              onPressed: busy ? null : controller.saveFinishedToFiles,
            ),
            DanaviewButton.secondary(
              key: const ValueKey('export-finished-share'),
              label: ExportStrings.shareButton,
              icon: Icons.ios_share_rounded,
              onPressed: busy ? null : controller.shareFinished,
            ),
          ],
          DanaviewButton.primary(key: const ValueKey('export-finished-done'), label: ExportStrings.done, onPressed: busy ? null : onDone),
        ]),
      ],
    );
  }
}
