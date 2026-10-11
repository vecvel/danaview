// OWNER: UX-40
//
// The Missing media sheet (ux.md §13.2): `showRelinkSheet` opens a `showVwishSheet(title: 'Missing
// media')` over [RelinkSheet].
//
// * One [RelinkRowTile] per offline file: type icon, original name, kind · length · size, the last
//   known folder, "Used in 3 clips" and what is wrong. Actions: Locate… (Photos or Files),
//   "Use updated file" (changed files), "Find in same folder" (after a path pick), and a menu with
//   Remove clips that use it / Replace with other media….
// * A picked file is validated at once: a match shows ready, a different length asks "Use it
//   anyway?", the wrong kind or an unreadable file says why.
// * "Relink several": one multi-pick, then a confirm list of matched pairs (each can be switched
//   off), the picks that matched nothing and what stays missing.
// * Nothing changes the project until the primary button ("Relink 3 files"): every staged file is
//   relinked as ONE history entry.

import 'dart:async';

import 'package:flutter/material.dart' show Icons, Theme;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vwish_editor_core/model.dart' show MediaAsset, MediaKind, PickedMedia, ProjectId;
import 'package:vwish_editor_core/store.dart' show MediaAvailability, RelinkCheck, RelinkDurationMismatch, RelinkMatch, RelinkUnsupported;
import 'package:vwish_editor_engine_api/vwish_editor_engine_api.dart' show MediaPickSource;
import 'package:vwish_features/storage.dart' show formatDataSize;
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import '../../../app/editor_messages.dart' show EditorMessage;
import '../../../app/editor_providers.dart';
import '../../../app/strings/relink_strings.dart';
import 'relink_controller.dart';

/// Shows the Missing media sheet for [projectId].
Future<void> showRelinkSheet(BuildContext context, {required ProjectId projectId}) => showVwishSheet<void>(
      context,
      title: RelinkStrings.sheetTitle,
      builder: (context) => RelinkSheet(projectId: projectId),
    );

/// Missing media and relink choices (ux.md §13.2).
class RelinkSheet extends ConsumerWidget {
  /// Creates the sheet content for [projectId].
  const RelinkSheet({super.key, required this.projectId});

  /// The open project.
  final ProjectId projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = relinkControllerProvider(projectId);
    ref.listen<int>(provider.select((s) => s.applies), (previous, next) {
      if (next > (previous ?? 0)) {
        VwishToast.show(
          context,
          RelinkStrings.relinkedToast(ref.read(provider).lastRelinked),
          icon: Icons.check_circle_rounded,
          kind: VwishToastKind.success,
        );
      }
    });
    final state = ref.watch(provider);
    final controller = ref.read(provider.notifier);
    return switch (state.stage) {
      RelinkStage.matching => const _Working(label: RelinkStrings.matching),
      RelinkStage.applying => const _Working(label: RelinkStrings.relinking),
      RelinkStage.confirm => _ConfirmView(state: state, controller: controller),
      RelinkStage.list => _ListView(state: state, controller: controller),
    };
  }
}

class _Working extends StatelessWidget {
  const _Working({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        container: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: VwishSpacing.xl),
          child: Column(
            key: const ValueKey('relink-working'),
            mainAxisSize: MainAxisSize.min,
            children: [
              VwishSpinner(semanticLabel: label),
              const SizedBox(height: VwishSpacing.md),
              Text(label, textAlign: TextAlign.center, style: VwishTextStyles.bodySecondary),
            ],
          ),
        ),
      );
}

// =================================================================================================
// The list
// =================================================================================================

class _ListView extends StatelessWidget {
  const _ListView({required this.state, required this.controller});

  final RelinkState state;
  final RelinkController controller;

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final rows = state.rows;
    final ready = state.readyCount;
    final failure = state.failure;
    final note = state.note;
    return Column(
      key: const ValueKey('relink-sheet'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!state.checked)
          const _Working(label: RelinkStrings.checking)
        else if (rows.isEmpty)
          const _AllGood()
        else ...[
          Text(RelinkStrings.sheetIntro, style: VwishTextStyles.bodySecondary),
          const SizedBox(height: VwishSpacing.md),
          if (failure != null) ...[
            _Message(message: failure, color: VwishColors.errorLight, icon: Icons.error_outline_rounded, onDismiss: controller.dismissFailure),
            const SizedBox(height: VwishSpacing.sm),
          ],
          if (note != null) ...[
            _Line(text: note, color: VwishColors.textSecondary, icon: Icons.info_outline_rounded),
            const SizedBox(height: VwishSpacing.sm),
          ],
          for (final row in rows) ...[
            RelinkRowTile(key: ValueKey('relink-row-${row.asset.id.value}'), row: row, controller: controller, platform: platform, busy: state.busy),
            const SizedBox(height: VwishSpacing.sm),
          ],
          const SizedBox(height: VwishSpacing.xs),
          _SeveralCard(controller: controller, platform: platform, busy: state.busy),
        ],
        const SizedBox(height: VwishSpacing.lg),
        VwishButtonBar(
          children: [
            VwishButton.secondary(
              key: const ValueKey('relink-close'),
              label: rows.isEmpty && state.checked ? RelinkStrings.done : RelinkStrings.close,
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            if (rows.isNotEmpty)
              VwishButton.primary(
                key: const ValueKey('relink-apply'),
                label: RelinkStrings.relinkFiles(ready == 0 ? rows.length : ready),
                icon: Icons.link_rounded,
                onPressed: ready == 0 || state.busy ? null : () => unawaited(controller.apply()),
              ),
          ],
        ),
      ],
    );
  }
}

class _AllGood extends StatelessWidget {
  const _AllGood();

  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        container: true,
        child: Row(
          key: const ValueKey('relink-all-good'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const VwishTileIcon(Icons.check_circle_rounded, color: VwishColors.success, size: 40),
            const SizedBox(width: VwishSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(RelinkStrings.allGoodTitle, style: VwishTextStyles.headline.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(RelinkStrings.allGoodMessage, style: VwishTextStyles.caption.copyWith(color: VwishColors.textSecondary, height: 1.35)),
                ],
              ),
            ),
          ],
        ),
      );
}

/// A message with an icon (failure line of the sheet).
class _Message extends StatelessWidget {
  const _Message({required this.message, required this.color, required this.icon, this.onDismiss});

  final EditorMessage message;
  final Color color;
  final IconData icon;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        container: true,
        child: VwishSurface(
          color: VwishColors.surface,
          borderColor: color.withValues(alpha: 0.5),
          padding: const EdgeInsets.all(VwishSpacing.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: VwishSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(message.title, style: VwishTextStyles.body.copyWith(fontWeight: FontWeight.w600)),
                    if (message.detail != null) ...[
                      const SizedBox(height: 2),
                      Text(message.detail!, style: VwishTextStyles.caption.copyWith(color: VwishColors.textSecondary, height: 1.35)),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}

/// One line of text with a small icon.
class _Line extends StatelessWidget {
  const _Line({required this.text, required this.color, required this.icon});

  final String text;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        container: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 16, color: color)),
            const SizedBox(width: VwishSpacing.sm),
            Expanded(child: Text(text, style: VwishTextStyles.caption.copyWith(color: color, height: 1.35))),
          ],
        ),
      );
}

// =================================================================================================
// One row
// =================================================================================================

/// The icon of a media kind.
IconData relinkKindIcon(MediaKind kind) => switch (kind) {
      MediaKind.video => Icons.movie_rounded,
      MediaKind.image || MediaKind.still => Icons.image_rounded,
      MediaKind.audio || MediaKind.recording => Icons.music_note_rounded,
      MediaKind.lut => Icons.palette_rounded,
    };

/// Whether the system photo picker can offer [kind] (videos and photos only).
bool relinkSupportsPhotos(MediaKind kind) => kind == MediaKind.video || kind == MediaKind.image || kind == MediaKind.still;

/// One offline file with its staged replacement and actions (ux.md §13.2).
class RelinkRowTile extends StatelessWidget {
  /// Creates the row.
  const RelinkRowTile({super.key, required this.row, required this.controller, required this.platform, this.busy = false});

  /// The row.
  final RelinkRow row;

  /// The flow.
  final RelinkController controller;

  /// The platform (Photos or Gallery wording).
  final TargetPlatform platform;

  /// Whether another action is running.
  final bool busy;

  MediaAsset get _asset => row.asset;

  (String, Color, IconData) _status() {
    switch (row.phase) {
      case RelinkRowPhase.needsFile:
        return switch (row.availability) {
          MediaAvailability.accessLost => (RelinkStrings.statusAccessLost, VwishColors.errorLight, Icons.lock_outline_rounded),
          MediaAvailability.changed => (RelinkStrings.statusChanged, VwishColors.warning, Icons.edit_note_rounded),
          _ => (RelinkStrings.statusMissing, VwishColors.warning, Icons.link_off_rounded),
        };
      case RelinkRowPhase.checking:
        return (RelinkStrings.checkingFile, VwishColors.textSecondary, Icons.hourglass_top_rounded);
      case RelinkRowPhase.ready:
        final check = row.check;
        final exact = check is RelinkMatch && check.exactFingerprint;
        return (exact ? RelinkStrings.matchesExactly : RelinkStrings.matches, VwishColors.success, Icons.check_circle_rounded);
      case RelinkRowPhase.confirm:
        final check = row.check;
        if (row.accepted) return (RelinkStrings.durationAccepted, VwishColors.warning, Icons.check_circle_outline_rounded);
        return check is RelinkDurationMismatch
            ? (RelinkStrings.durationQuestion(check.expectedUs, check.actualUs), VwishColors.warning, Icons.help_outline_rounded)
            : (RelinkStrings.matches, VwishColors.success, Icons.check_circle_rounded);
      case RelinkRowPhase.rejected:
        return (row.message ?? RelinkStrings.unsupported('io'), VwishColors.errorLight, Icons.error_outline_rounded);
    }
  }

  @override
  Widget build(BuildContext context) {
    final (status, statusColor, statusIcon) = _status();
    final asset = _asset;
    final folder = lastKnownFolderOf(asset);
    final size = asset.fingerprint.sizeBytes > 0 ? formatDataSize(asset.fingerprint.sizeBytes) : null;
    final details = RelinkStrings.details(kind: asset.kind, duration: asset.probe.duration, size: size);
    final pick = row.pick;
    final checking = row.phase == RelinkRowPhase.checking;
    final locateLabel = pick == null ? RelinkStrings.locate : RelinkStrings.locateAgain;
    final canMenu = row.usedClips > 0;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: '${asset.displayName}. $status',
      child: VwishSurface(
        color: VwishColors.surface,
        padding: const EdgeInsets.all(VwishSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(child: VwishTileIcon(relinkKindIcon(asset.kind), color: VwishColors.warning, size: 36)),
                const SizedBox(width: VwishSpacing.md),
                Expanded(
                  child: ExcludeSemantics(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          RelinkStrings.middleEllipsis(asset.displayName, max: 48),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: VwishTextStyles.body.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(details, style: VwishTextStyles.caption.copyWith(color: VwishColors.textSecondary)),
                        if (folder != null)
                          Text(
                            RelinkStrings.lastSeenIn(RelinkStrings.middleEllipsis(folder, max: 32)),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: VwishTextStyles.caption.copyWith(color: VwishColors.textMuted),
                          ),
                        Text(RelinkStrings.usedIn(row.usedClips), style: VwishTextStyles.caption.copyWith(color: VwishColors.textMuted)),
                      ],
                    ),
                  ),
                ),
                if (pick != null && !checking)
                  VwishIconButton(
                    key: ValueKey('relink-clear-${asset.id.value}'),
                    icon: Icons.close_rounded,
                    size: 32,
                    iconSize: 16,
                    tooltip: RelinkStrings.clearPick,
                    semanticLabel: RelinkStrings.clearPick,
                    onPressed: busy ? null : () => controller.clear(asset.id),
                  ),
              ],
            ),
            const SizedBox(height: VwishSpacing.sm),
            Row(
              key: ValueKey('relink-status-${asset.id.value}'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(padding: const EdgeInsets.only(top: 1), child: Icon(statusIcon, size: 16, color: statusColor)),
                const SizedBox(width: VwishSpacing.sm),
                Expanded(child: Text(status, style: VwishTextStyles.caption.copyWith(color: statusColor, height: 1.35))),
              ],
            ),
            if (pick != null && row.phase != RelinkRowPhase.needsFile) ...[
              const SizedBox(height: 2),
              Padding(
                padding: const EdgeInsets.only(left: 24),
                child: Text(
                  RelinkStrings.middleEllipsis(pick.displayName, max: 40),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: VwishTextStyles.caption.copyWith(color: VwishColors.textMuted),
                ),
              ),
            ],
            if (checking) ...[
              const SizedBox(height: VwishSpacing.sm),
              const VwishProgressBar(height: 4),
            ],
            const SizedBox(height: VwishSpacing.sm),
            Wrap(
              spacing: VwishSpacing.sm,
              runSpacing: VwishSpacing.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (row.phase == RelinkRowPhase.confirm && !row.accepted)
                  VwishButton.tonal(
                    key: ValueKey('relink-accept-${asset.id.value}'),
                    label: RelinkStrings.useAnyway,
                    size: VwishButtonSize.sm,
                    onPressed: busy ? null : () => controller.acceptMismatch(asset.id),
                  ),
                if (!checking) _locate(locateLabel),
                if (pick == null && controller.canUseUpdated(row))
                  VwishButton.secondary(
                    key: ValueKey('relink-updated-${asset.id.value}'),
                    label: RelinkStrings.useUpdated,
                    icon: Icons.refresh_rounded,
                    size: VwishButtonSize.sm,
                    onPressed: busy ? null : () => unawaited(controller.useUpdatedFile(asset.id)),
                  ),
                if (row.hasPathPick && (row.phase == RelinkRowPhase.ready || row.phase == RelinkRowPhase.confirm))
                  VwishButton.secondary(
                    key: ValueKey('relink-folder-${asset.id.value}'),
                    label: RelinkStrings.findInFolder,
                    icon: Icons.folder_open_rounded,
                    size: VwishButtonSize.sm,
                    onPressed: busy ? null : () => unawaited(controller.findInSameFolder(asset.id)),
                  ),
                if (canMenu && !checking) _moreMenu(context),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<VwishMenuEntry> _sourceEntries(void Function(MediaPickSource source) pick) => [
        if (relinkSupportsPhotos(_asset.kind))
          VwishMenuItem(
            label: RelinkStrings.fromPhotos(platform),
            icon: Icons.photo_library_outlined,
            onTap: () => pick(MediaPickSource.photos),
          ),
        VwishMenuItem(label: RelinkStrings.fromFiles, icon: Icons.folder_open_rounded, onTap: () => pick(MediaPickSource.files)),
      ];

  Widget _locate(String label) {
    final id = _asset.id;
    if (!relinkSupportsPhotos(_asset.kind)) {
      return VwishButton.secondary(
        key: ValueKey('relink-locate-${id.value}'),
        label: label,
        icon: Icons.search_rounded,
        size: VwishButtonSize.sm,
        onPressed: busy ? null : () => unawaited(controller.locate(id, MediaPickSource.files)),
      );
    }
    return VwishMenuAnchor(
      entries: _sourceEntries((source) => unawaited(controller.locate(id, source))),
      builder: (context, open, isOpen) => VwishButton.secondary(
        key: ValueKey('relink-locate-${id.value}'),
        label: label,
        icon: Icons.search_rounded,
        size: VwishButtonSize.sm,
        onPressed: busy ? null : open,
      ),
    );
  }

  Widget _moreMenu(BuildContext context) {
    final id = _asset.id;
    final entries = <VwishMenuEntry>[
      const VwishMenuHeader(RelinkStrings.replaceWith),
      ..._sourceEntries((source) => unawaited(_replace(context, source))),
      const VwishMenuDivider(),
      VwishMenuItem(
        label: RelinkStrings.removeClips,
        icon: Icons.delete_outline_rounded,
        destructive: true,
        onTap: () => unawaited(_remove(context)),
      ),
    ];
    return VwishMenuIconTrigger(
      key: ValueKey('relink-more-${id.value}'),
      icon: Icons.more_horiz_rounded,
      entries: entries,
      enabled: !busy,
      size: 36,
      iconSize: 18,
      menuWidth: 240,
      tooltip: RelinkStrings.moreActions,
      semanticLabel: RelinkStrings.moreActions,
    );
  }

  Future<void> _remove(BuildContext context) async {
    final clips = row.usedClips;
    final ok = await showVwishConfirm(
      context,
      title: RelinkStrings.removeClipsTitle(clips),
      message: RelinkStrings.removeClipsMessage,
      confirmLabel: RelinkStrings.removeClipsConfirm,
      destructive: true,
      icon: Icons.delete_outline_rounded,
    );
    if (!ok || !context.mounted) return;
    final removed = controller.removeClips(_asset.id);
    if (removed > 0 && context.mounted) {
      VwishToast.show(context, RelinkStrings.removedClips(removed), icon: Icons.delete_outline_rounded);
    }
  }

  Future<void> _replace(BuildContext context, MediaPickSource source) async {
    final replaced = await controller.replaceWith(_asset.id, source);
    if (replaced > 0 && context.mounted) {
      VwishToast.show(context, RelinkStrings.replacedClips(replaced), icon: Icons.swap_horiz_rounded, kind: VwishToastKind.success);
    }
  }
}

// =================================================================================================
// Relink several
// =================================================================================================

class _SeveralCard extends StatelessWidget {
  const _SeveralCard({required this.controller, required this.platform, required this.busy});

  final RelinkController controller;
  final TargetPlatform platform;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return VwishSurface(
      key: const ValueKey('relink-several'),
      color: VwishColors.surface,
      padding: const EdgeInsets.all(VwishSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const ExcludeSemantics(child: VwishTileIcon(Icons.auto_fix_high_rounded, size: 36)),
              const SizedBox(width: VwishSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(RelinkStrings.relinkSeveral, style: VwishTextStyles.body.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(RelinkStrings.relinkSeveralHint, style: VwishTextStyles.caption.copyWith(color: VwishColors.textSecondary, height: 1.35)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: VwishSpacing.sm),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: VwishMenuAnchor(
              entries: [
                VwishMenuItem(
                  label: RelinkStrings.fromPhotos(platform),
                  icon: Icons.photo_library_outlined,
                  onTap: () => unawaited(controller.relinkSeveral(MediaPickSource.photos)),
                ),
                VwishMenuItem(
                  label: RelinkStrings.fromFiles,
                  icon: Icons.folder_open_rounded,
                  onTap: () => unawaited(controller.relinkSeveral(MediaPickSource.files)),
                ),
              ],
              builder: (context, open, isOpen) => VwishButton.secondary(
                key: const ValueKey('relink-several-button'),
                label: RelinkStrings.relinkSeveral,
                icon: Icons.photo_library_rounded,
                size: VwishButtonSize.sm,
                onPressed: busy ? null : open,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConfirmView extends StatelessWidget {
  const _ConfirmView({required this.state, required this.controller});

  final RelinkState state;
  final RelinkController controller;

  @override
  Widget build(BuildContext context) {
    final plan = state.several!;
    final kept = plan.includedCount;
    return Column(
      key: const ValueKey('relink-confirm'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          liveRegion: true,
          child: Text(RelinkStrings.confirmTitle, style: VwishTextStyles.headline.copyWith(fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: 2),
        Text(
          plan.matches.isEmpty ? RelinkStrings.nothingMatched : RelinkStrings.matched(plan.matches.length, plan.picked),
          key: const ValueKey('relink-confirm-summary'),
          style: VwishTextStyles.caption.copyWith(color: VwishColors.textSecondary, height: 1.35),
        ),
        if (plan.matches.isNotEmpty) ...[
          const VwishSectionHeader(RelinkStrings.matchedHeader),
          VwishSurface(
            color: VwishColors.surface,
            padding: const EdgeInsets.symmetric(horizontal: VwishSpacing.md, vertical: VwishSpacing.xs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, m) in plan.matches.indexed)
                  _MatchRow(key: ValueKey('relink-match-$i'), entry: m, onChanged: (v) => controller.setMatchIncluded(i, v)),
              ],
            ),
          ),
        ],
        if (plan.unmatchedPicks.isNotEmpty) ...[
          const VwishSectionHeader(RelinkStrings.unassignedPicksHeader),
          VwishSurface(
            key: const ValueKey('relink-unmatched'),
            color: VwishColors.surface,
            padding: const EdgeInsets.symmetric(horizontal: VwishSpacing.md, vertical: VwishSpacing.xs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (final p in plan.unmatchedPicks) _UnmatchedRow(pick: p.pick, check: p.check)],
            ),
          ),
        ],
        if (plan.stillMissing.isNotEmpty) ...[
          const VwishSectionHeader(RelinkStrings.stillMissingHeader),
          VwishSurface(
            key: const ValueKey('relink-still-missing'),
            color: VwishColors.surface,
            padding: const EdgeInsets.symmetric(horizontal: VwishSpacing.md, vertical: VwishSpacing.xs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final a in plan.stillMissing)
                  _NameRow(icon: relinkKindIcon(a.kind), color: VwishColors.warning, title: a.displayName, subtitle: RelinkStrings.statusMissing),
              ],
            ),
          ),
        ],
        const SizedBox(height: VwishSpacing.lg),
        VwishButtonBar(
          children: [
            VwishButton.secondary(key: const ValueKey('relink-confirm-back'), label: RelinkStrings.back, onPressed: controller.cancelSeveral),
            if (plan.matches.isNotEmpty)
              VwishButton.primary(
                key: const ValueKey('relink-confirm-apply'),
                label: RelinkStrings.confirmRelink(kept),
                icon: Icons.link_rounded,
                onPressed: kept == 0 || state.busy ? null : () => unawaited(controller.confirmSeveral()),
              ),
          ],
        ),
      ],
    );
  }
}

class _MatchRow extends StatelessWidget {
  const _MatchRow({super.key, required this.entry, required this.onChanged});

  final RelinkMatchEntry entry;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final pick = entry.proposal.pick;
    return Semantics(
      container: true,
      label: RelinkStrings.includeMatch(pick.displayName, entry.asset.displayName),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: VwishSpacing.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: ExcludeSemantics(
                child: _NameRow(
                  icon: relinkKindIcon(entry.asset.kind),
                  color: entry.included ? VwishColors.success : VwishColors.textMuted,
                  title: pick.displayName,
                  subtitle: RelinkStrings.replacesName(entry.asset.displayName),
                  padding: EdgeInsets.zero,
                ),
              ),
            ),
            const SizedBox(width: VwishSpacing.sm),
            VwishSwitch(value: entry.included, onChanged: onChanged, semanticLabel: RelinkStrings.includeMatch(pick.displayName, entry.asset.displayName)),
          ],
        ),
      ),
    );
  }
}

class _UnmatchedRow extends StatelessWidget {
  const _UnmatchedRow({required this.pick, required this.check});

  final PickedMedia pick;
  final RelinkCheck check;

  @override
  Widget build(BuildContext context) {
    final text = switch (check) {
      RelinkUnsupported(:final reason) => RelinkStrings.unsupported(reason),
      _ => RelinkStrings.notMatched,
    };
    return _NameRow(icon: Icons.help_outline_rounded, color: VwishColors.textMuted, title: pick.displayName, subtitle: text);
  }
}

class _NameRow extends StatelessWidget {
  const _NameRow({required this.icon, required this.color, required this.title, required this.subtitle, this.padding});

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) => Padding(
        padding: padding ?? const EdgeInsets.symmetric(vertical: VwishSpacing.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 18, color: color)),
            const SizedBox(width: VwishSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(RelinkStrings.middleEllipsis(title, max: 48), maxLines: 2, overflow: TextOverflow.ellipsis, style: VwishTextStyles.body),
                  Text(subtitle, style: VwishTextStyles.caption.copyWith(color: VwishColors.textSecondary, height: 1.3)),
                ],
              ),
            ),
          ],
        ),
      );
}
