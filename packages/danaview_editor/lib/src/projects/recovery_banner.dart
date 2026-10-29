// OWNER: UX-40
//
// The recovery banner on the Projects screen (ux.md §13.3, §5.1): shown above the list when
// projects closed before their last changes were saved (`ProjectsState.recoverable`). Each project
// gets Restore and Discard.
//
// * Restore promotes the journal (`ProjectsController.restore`; the project is closed again) and
//   toasts that the project can be opened from the list; the card's "Unsaved changes" badge goes.
// * Discard asks first: the unsaved changes are deleted and the last saved version stays.
// * Failures say so and change nothing.
//
// Several projects are laid out as a wrapping grid of equal-height cards ([recoveryColumns]); with
// more than [recoveryCollapsedCount] only the first ones show until "Show all (N)".

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart' show ProjectId;
import 'package:danaview_editor_core/store.dart' show RecoverableSession;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../app/strings/relink_strings.dart';
import 'projects_controller.dart';

/// Offers to restore projects that closed unexpectedly (ux.md §13.3).
class RecoveryBanner extends ConsumerStatefulWidget {
  /// Creates the banner. [onRestored] is called with the project after a successful restore (the
  /// screen may open it).
  const RecoveryBanner({super.key, this.onRestored});

  /// Called after a project was restored.
  final ValueChanged<ProjectId>? onRestored;

  @override
  ConsumerState<RecoveryBanner> createState() => _RecoveryBannerState();
}

class _RecoveryBannerState extends ConsumerState<RecoveryBanner> {
  final Set<ProjectId> _working = {};
  bool _expanded = false;

  Future<void> _restore(RecoverableSession session) async {
    if (_working.contains(session.projectId)) return;
    setState(() => _working.add(session.projectId));
    try {
      final id = await ref.read(projectsControllerProvider.notifier).restore(session);
      if (!mounted) return;
      DanaviewToast.show(context, RelinkStrings.restoredProject(session.projectName), icon: Icons.restore_rounded, kind: DanaviewToastKind.success);
      widget.onRestored?.call(id);
    } on Object catch (e) {
      if (e is Error) rethrow;
      if (mounted) DanaviewToast.show(context, RelinkStrings.recoveryActionFailed, icon: Icons.error_outline_rounded, kind: DanaviewToastKind.error);
    } finally {
      if (mounted) setState(() => _working.remove(session.projectId));
    }
  }

  Future<void> _discard(RecoverableSession session) async {
    if (_working.contains(session.projectId)) return;
    final ok = await showDanaviewConfirm(
      context,
      title: RelinkStrings.discardTitle(session.projectName),
      message: RelinkStrings.discardMessage,
      confirmLabel: RelinkStrings.discardConfirm,
      destructive: true,
      icon: Icons.delete_outline_rounded,
    );
    if (!ok || !mounted) return;
    setState(() => _working.add(session.projectId));
    try {
      await ref.read(projectsControllerProvider.notifier).discard(session);
      if (!mounted) return;
      DanaviewToast.show(context, RelinkStrings.discardedProject(session.projectName), icon: Icons.delete_outline_rounded);
    } on Object catch (e) {
      if (e is Error) rethrow;
      if (mounted) DanaviewToast.show(context, RelinkStrings.recoveryActionFailed, icon: Icons.error_outline_rounded, kind: DanaviewToastKind.error);
    } finally {
      if (mounted) setState(() => _working.remove(session.projectId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessions = ref.watch(projectsControllerProvider.select((s) => s.recoverable));
    if (sessions.isEmpty) return const SizedBox.shrink();
    final now = ref.watch(projectsClockProvider)();
    final one = sessions.length == 1;
    final title = one ? RelinkStrings.bannerTitleOne : RelinkStrings.bannerTitleMany(sessions.length);
    final first = sessions.first;
    final message = one ? RelinkStrings.bannerOne(first.projectName, RelinkStrings.when(first.journalSavedAt, now)) : RelinkStrings.bannerMany;
    final collapsible = sessions.length > recoveryCollapsedCount;
    final shown = collapsible && !_expanded ? sessions.take(recoveryCollapsedCount).toList() : sessions;
    Widget item(RecoverableSession session) => _SessionCard(
          key: ValueKey('recovery-${session.projectId.value}'),
          session: session,
          now: now,
          showName: !one,
          working: _working.contains(session.projectId),
          onRestore: () => unawaited(_restore(session)),
          onDiscard: () => unawaited(_discard(session)),
        );
    return Semantics(
      container: true,
      label: '$title. $message',
      explicitChildNodes: true,
      child: DanaviewSurface(
        key: const ValueKey('recovery-banner'),
        // The same dark card surface and hairline as the project cards: no warning outline; the
        // clock tile carries the warning colour.
        color: DanaviewColors.surface,
        padding: const EdgeInsets.all(DanaviewSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const ExcludeSemantics(child: DanaviewIconTile(Icons.history_rounded, color: DanaviewColors.warning, size: 36)),
                const SizedBox(width: DanaviewSpacing.md),
                Expanded(
                  child: ExcludeSemantics(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: DanaviewTextStyles.body.copyWith(fontWeight: FontWeight.w600)),
                        const SizedBox(height: DanaviewSpacing.xxs),
                        Text(message, style: DanaviewTextStyles.caption.copyWith(color: DanaviewColors.textSecondary, height: 1.35)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: DanaviewSpacing.md),
            if (one)
              item(first)
            else
              LayoutBuilder(
                builder: (context, constraints) {
                  final columns = recoveryColumns(constraints.maxWidth);
                  return Column(
                    key: const ValueKey('recovery-grid'),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var start = 0; start < shown.length; start += columns) ...[
                        if (start > 0) const SizedBox(height: recoveryGridGap),
                        IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (var i = start; i < start + columns; i++) ...[
                                if (i > start) const SizedBox(width: recoveryGridGap),
                                Expanded(child: i < shown.length ? item(shown[i]) : const SizedBox.shrink()),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
            if (collapsible) ...[
              const SizedBox(height: DanaviewSpacing.sm),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: DanaviewButton.ghost(
                  key: const ValueKey('recovery-show-all'),
                  label: _expanded ? RelinkStrings.bannerShowFewer : RelinkStrings.bannerShowAll(sessions.length),
                  size: DanaviewButtonSize.sm,
                  onPressed: () => setState(() => _expanded = !_expanded),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Recovery cards shown before "Show all" when there are more.
const int recoveryCollapsedCount = 4;

/// Minimum width of one recovery card in the grid.
const double recoveryCardMinWidth = 280;

/// Gap between recovery cards, both ways.
const double recoveryGridGap = DanaviewSpacing.md;

/// How many recovery cards fit side by side in [width] (at least one).
int recoveryColumns(double width) {
  if (!width.isFinite) return 1;
  return math.max(1, ((width + recoveryGridGap) / (recoveryCardMinWidth + recoveryGridGap)).floor());
}

/// One project's recovery card: name and time (several projects), Restore and Discard.
class _SessionCard extends StatelessWidget {
  const _SessionCard({super.key, required this.session, required this.now, required this.showName, required this.working, required this.onRestore, required this.onDiscard});

  final RecoverableSession session;
  final DateTime now;
  final bool showName;
  final bool working;
  final VoidCallback onRestore;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final when = RelinkStrings.changesFrom(RelinkStrings.when(session.journalSavedAt, now));
    final buttons = Wrap(
      spacing: DanaviewSpacing.sm,
      runSpacing: DanaviewSpacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        DanaviewButton.primary(
          key: ValueKey('recovery-restore-${session.projectId.value}'),
          label: RelinkStrings.bannerRestore,
          icon: Icons.restore_rounded,
          size: DanaviewButtonSize.sm,
          semanticLabel: RelinkStrings.restoreSemantics(session.projectName),
          onPressed: working ? null : onRestore,
        ),
        DanaviewButton.secondary(
          key: ValueKey('recovery-discard-${session.projectId.value}'),
          label: RelinkStrings.bannerDiscard,
          size: DanaviewButtonSize.sm,
          semanticLabel: RelinkStrings.discardSemantics(session.projectName),
          onPressed: working ? null : onDiscard,
        ),
        if (working) const DanaviewSpinner(size: 18),
      ],
    );
    if (!showName) return buttons;
    return DanaviewSurface(
      color: DanaviewColors.surfaceElevated,
      borderColor: DanaviewColors.hairlineSubtle,
      borderRadius: DanaviewRadius.controlAll,
      padding: const EdgeInsets.all(DanaviewSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(session.projectName, style: DanaviewTextStyles.body.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: DanaviewSpacing.xxs),
          Text(when, style: DanaviewTextStyles.caption.copyWith(color: DanaviewColors.textSecondary)),
          const SizedBox(height: DanaviewSpacing.md),
          const Spacer(),
          buttons,
        ],
      ),
    );
  }
}
