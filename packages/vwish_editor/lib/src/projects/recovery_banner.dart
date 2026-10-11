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

import 'dart:async';

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vwish_editor_core/model.dart' show ProjectId;
import 'package:vwish_editor_core/store.dart' show RecoverableSession;
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

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

  Future<void> _restore(RecoverableSession session) async {
    if (_working.contains(session.projectId)) return;
    setState(() => _working.add(session.projectId));
    try {
      final id = await ref.read(projectsControllerProvider.notifier).restore(session);
      if (!mounted) return;
      VwishToast.show(context, RelinkStrings.restoredProject(session.projectName), icon: Icons.restore_rounded, kind: VwishToastKind.success);
      widget.onRestored?.call(id);
    } on Object catch (e) {
      if (e is Error) rethrow;
      if (mounted) VwishToast.show(context, RelinkStrings.recoveryActionFailed, icon: Icons.error_outline_rounded, kind: VwishToastKind.error);
    } finally {
      if (mounted) setState(() => _working.remove(session.projectId));
    }
  }

  Future<void> _discard(RecoverableSession session) async {
    if (_working.contains(session.projectId)) return;
    final ok = await showVwishConfirm(
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
      VwishToast.show(context, RelinkStrings.discardedProject(session.projectName), icon: Icons.delete_outline_rounded);
    } on Object catch (e) {
      if (e is Error) rethrow;
      if (mounted) VwishToast.show(context, RelinkStrings.recoveryActionFailed, icon: Icons.error_outline_rounded, kind: VwishToastKind.error);
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
    return Semantics(
      container: true,
      label: '$title. $message',
      explicitChildNodes: true,
      child: VwishSurface(
        key: const ValueKey('recovery-banner'),
        color: VwishColors.surfaceElevated,
        borderColor: VwishColors.warning.withValues(alpha: 0.45),
        shadow: VwishShadow.soft,
        padding: const EdgeInsets.all(VwishSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const ExcludeSemantics(child: VwishTileIcon(Icons.history_rounded, color: VwishColors.warning, size: 36)),
                const SizedBox(width: VwishSpacing.md),
                Expanded(
                  child: ExcludeSemantics(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: VwishTextStyles.body.copyWith(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(message, style: VwishTextStyles.caption.copyWith(color: VwishColors.textSecondary, height: 1.35)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            for (final session in sessions) ...[
              const SizedBox(height: VwishSpacing.md),
              _SessionRow(
                key: ValueKey('recovery-${session.projectId.value}'),
                session: session,
                now: now,
                showName: !one,
                working: _working.contains(session.projectId),
                onRestore: () => unawaited(_restore(session)),
                onDiscard: () => unawaited(_discard(session)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({super.key, required this.session, required this.now, required this.showName, required this.working, required this.onRestore, required this.onDiscard});

  final RecoverableSession session;
  final DateTime now;
  final bool showName;
  final bool working;
  final VoidCallback onRestore;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final when = RelinkStrings.changesFrom(RelinkStrings.when(session.journalSavedAt, now));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showName) ...[
          Text(session.projectName, style: VwishTextStyles.body),
          Text(when, style: VwishTextStyles.caption.copyWith(color: VwishColors.textSecondary)),
          const SizedBox(height: VwishSpacing.sm),
        ],
        Wrap(
          spacing: VwishSpacing.sm,
          runSpacing: VwishSpacing.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            VwishButton.primary(
              key: ValueKey('recovery-restore-${session.projectId.value}'),
              label: RelinkStrings.bannerRestore,
              icon: Icons.restore_rounded,
              size: VwishButtonSize.sm,
              semanticLabel: RelinkStrings.restoreSemantics(session.projectName),
              onPressed: working ? null : onRestore,
            ),
            VwishButton.secondary(
              key: ValueKey('recovery-discard-${session.projectId.value}'),
              label: RelinkStrings.bannerDiscard,
              size: VwishButtonSize.sm,
              semanticLabel: RelinkStrings.discardSemantics(session.projectName),
              onPressed: working ? null : onDiscard,
            ),
            if (working) const VwishSpinner(size: 18),
          ],
        ),
      ],
    );
  }
}
