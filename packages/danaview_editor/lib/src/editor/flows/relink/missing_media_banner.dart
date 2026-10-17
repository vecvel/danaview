// OWNER: UX-40
//
// The editor's status banners (ux.md §13.1, §13.4), shown under the top bar:
//
// * [MissingMediaBanner]: "2 files are missing · Relink" with a warning icon, one line when it
//   fits (stacked on narrow screens). Relink opens the Missing media sheet through the `relink`
//   action; the close button hides it for this session. It returns when more files go missing, and
//   when the export pre-check calls `MediaHealthController.resurfaceBanner`.
// * [ReadOnlyBanner]: a project saved by a newer Danaview opened read-only (D-12): "Read-only: made
//   with a newer Danaview. You can look at it and export it. Update Danaview to save changes."
//
// Both render nothing (zero height) when there is nothing to say.

import 'package:flutter/material.dart' show Icons, Theme;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart' show ProjectId;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../../app/editor_providers.dart';
import '../../../app/strings/relink_strings.dart';
import '../../actions/editor_action_registry.dart';
import '../../contracts/contracts.dart';
import '../../editor_scope.dart';
import '../../state/editor_state.dart' show SavePhase;
import '../../state/media_health_controller.dart';

/// Below this width the banner stacks its text above its buttons.
const double _stackBelow = 420;

/// What the missing media banner shows: the count and whether every file is plainly missing.
@immutable
final class _BannerView {
  const _BannerView(this.count, this.onlyMissing);

  static _BannerView of(MediaHealthState s) => s.bannerVisible ? _BannerView(s.count, s.onlyMissing) : const _BannerView(0, true);

  final int count;
  final bool onlyMissing;

  @override
  bool operator ==(Object other) => other is _BannerView && other.count == count && other.onlyMissing == onlyMissing;

  @override
  int get hashCode => Object.hash(count, onlyMissing);
}

/// "2 files are missing · Relink" under the top bar (ux.md §13.1).
class MissingMediaBanner extends ConsumerWidget {
  /// Creates the banner for the project of the nearest `EditorScope` (or [projectId]).
  const MissingMediaBanner({super.key, this.projectId, this.onRelink});

  /// The project, when not below an `EditorScope`.
  final ProjectId? projectId;

  /// Opens the relink flow; defaults to the `relink` action of the action registry's bindings.
  final VoidCallback? onRelink;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = projectId ?? EditorScope.idOf(context);
    final view = ref.watch(mediaHealthControllerProvider(id).select(_BannerView.of));
    if (view.count == 0) return const SizedBox.shrink();
    final text = RelinkStrings.banner(view.count, onlyMissing: view.onlyMissing);
    final controller = ref.read(mediaHealthControllerProvider(id).notifier);
    return _BannerFrame(
      key: const ValueKey('missing-media-banner'),
      icon: Icons.link_off_rounded,
      color: DanaviewColors.warning,
      title: text,
      semanticLabel: RelinkStrings.bannerSemantics(text),
      actions: [
        DanaviewButton.tonal(
          key: const ValueKey('missing-media-relink'),
          label: RelinkStrings.relink,
          icon: Icons.link_rounded,
          size: DanaviewButtonSize.sm,
          onPressed: onRelink ?? () => _openRelink(context, ref, id),
        ),
        DanaviewIconButton(
          key: const ValueKey('missing-media-dismiss'),
          icon: Icons.close_rounded,
          size: 32,
          iconSize: 16,
          tooltip: RelinkStrings.dismissBanner,
          semanticLabel: RelinkStrings.dismissBanner,
          onPressed: controller.dismissBanner,
        ),
      ],
    );
  }

  static void _openRelink(BuildContext context, WidgetRef ref, ProjectId id) {
    final registry = ref.read(editorActionRegistryProvider).forPlatformOf(Theme.of(context).platform);
    registry.invoke(EditorActionId.relink, WidgetActionContext(projectId: id, context: context, ref: ref));
  }
}

/// A project saved by a newer Danaview opened read-only (ux.md §13.4, D-12).
class ReadOnlyBanner extends ConsumerWidget {
  /// Creates the banner for the project of the nearest `EditorScope` (or [projectId]).
  const ReadOnlyBanner({super.key, this.projectId});

  /// The project, when not below an `EditorScope`.
  final ProjectId? projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = projectId ?? EditorScope.idOf(context);
    final readOnly = ref.watch(editorControllerProvider(id).select((s) => s.save.phase == SavePhase.readOnly));
    if (!readOnly) return const SizedBox.shrink();
    return const _BannerFrame(
      key: ValueKey('read-only-banner'),
      icon: Icons.lock_outline_rounded,
      color: DanaviewColors.cyan,
      title: RelinkStrings.readOnlyBannerTitle,
      detail: RelinkStrings.readOnlyBannerDetail,
      semanticLabel: '${RelinkStrings.readOnlyBannerTitle}. ${RelinkStrings.readOnlyBannerDetail}',
    );
  }
}

/// The newest copy of the project was damaged and the store opened the last good one (ux.md
/// §13.4): says so until dismissed.
class BackupRestoredBanner extends StatelessWidget {
  /// Creates the banner; [onDismiss] hides it.
  const BackupRestoredBanner({super.key, required this.onDismiss});

  /// Hides the banner.
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => _BannerFrame(
        key: const ValueKey('backup-restored-banner'),
        icon: Icons.history_rounded,
        color: DanaviewColors.warning,
        title: RelinkStrings.backupRestoredTitle,
        detail: RelinkStrings.backupRestoredDetail,
        semanticLabel: '${RelinkStrings.backupRestoredTitle}. ${RelinkStrings.backupRestoredDetail}',
        actions: [
          DanaviewIconButton(
            key: const ValueKey('backup-restored-dismiss'),
            icon: Icons.close_rounded,
            size: 32,
            iconSize: 16,
            tooltip: RelinkStrings.dismissNotice,
            semanticLabel: RelinkStrings.dismissNotice,
            onPressed: onDismiss,
          ),
        ],
      );
}

class _BannerFrame extends StatelessWidget {
  const _BannerFrame({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    required this.semanticLabel,
    this.detail,
    this.actions = const [],
  });

  final IconData icon;
  final Color color;
  final String title;
  final String? detail;
  final String semanticLabel;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final text = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: DanaviewTextStyles.label.copyWith(color: DanaviewColors.textPrimary)),
        if (detail != null)
          Text(detail!, style: DanaviewTextStyles.caption.copyWith(color: DanaviewColors.textSecondary, height: 1.3)),
      ],
    );
    final lead = Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, size: 18, color: color));
    return Semantics(
      container: true,
      liveRegion: true,
      label: semanticLabel,
      child: ExcludeSemantics(
        excluding: actions.isEmpty,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.sm, vertical: DanaviewSpacing.xs),
          child: DanaviewSurface(
            color: DanaviewColors.surfaceElevated,
            borderColor: color.withValues(alpha: 0.45),
            borderRadius: DanaviewRadius.mdAll,
            shadow: DanaviewShadow.soft,
            padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.md, vertical: DanaviewSpacing.xs),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final stacked = constraints.maxWidth < _stackBelow && actions.isNotEmpty;
                if (stacked) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: DanaviewSpacing.xs),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [lead, const SizedBox(width: DanaviewSpacing.sm), Expanded(child: text)],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: DanaviewSpacing.xxs),
                        child: Wrap(alignment: WrapAlignment.end, crossAxisAlignment: WrapCrossAlignment.center, spacing: DanaviewSpacing.xs, children: actions),
                      ),
                    ],
                  );
                }
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: DanaviewSpacing.xs),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      lead,
                      const SizedBox(width: DanaviewSpacing.sm),
                      Expanded(child: text),
                      for (final a in actions) ...[const SizedBox(width: DanaviewSpacing.xs), a],
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
