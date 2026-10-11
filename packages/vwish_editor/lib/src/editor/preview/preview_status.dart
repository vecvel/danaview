// OWNER: UX-18
//
// Preview status overlays (ARCH §17.5, ux.md §7.1, §7.7): centred above the texture and the text
// overlay, ignoring pointers except on their buttons, so the manipulation overlay below still gets
// every other touch.
//
// * starting: `VwishSpinner` until the first frame.
// * failed: "Preview stopped" with "Restart preview" (`EditorController.restartPreview`: resends the
//   full plan and redraws, or re-creates the session when it never started).
// * offline media at the playhead: a hatched "Media missing" card with "Relink…" (the registry's
//   `relink` action, UX-40; disabled until it is bound). It is checked only when the project has
//   missing media, and then only when the playhead's frame changes.
// * degraded: a small "Preview ½" (or ¼) badge top-right with the quality tooltip.
// * pending jobs: a "2 tasks" badge top-left while background tasks (proxies, waveforms, captions…)
//   run.
// * The quality menu entries ([previewQualityEntries]: Auto/Full/Half/Quarter, the proxies toggle
//   and the footer note) are shared by the fullscreen preview; the editor's copy lives in the
//   transport bar (UX-14).
//
// Every card scales down to fit (FittedBox), so a short preview (keyboard up, text scale 1.35, a
// 280 px phone) never overflows. Copy is in [PreviewStrings].

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Icons, Theme;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_engine_api/vwish_editor_engine_api.dart' show PreviewQuality;
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../actions/editor_action_registry.dart';
import '../contracts/contracts.dart';
import '../editor_scope.dart';
import '../state/editor_controller.dart';
import '../state/editor_state.dart';
import '../transport/transport_strings.dart';
import 'text_overlay_painter.dart' show activeItemOf;

/// Copy of the preview region (ux.md §7.1, §7.7).
abstract final class PreviewStrings {
  /// Spinner label while the preview starts.
  static const String starting = 'Starting preview';

  /// Title of the failed card.
  static const String stopped = 'Preview stopped';

  /// Message of the failed card.
  static const String stoppedMessage = 'Your edits are safe. Restart the preview to keep watching.';

  /// Button of the failed card.
  static const String restart = 'Restart preview';

  /// Title of the offline card.
  static const String mediaMissing = 'Media missing';

  /// Button of the offline card.
  static const String relink = 'Relink…';

  /// Tooltip of the degraded badge.
  static const String degradedTooltip = 'Preview quality was lowered to keep playback smooth. Export is unaffected.';

  /// The degraded badge.
  static String degraded(PreviewQuality quality) => switch (quality) {
        PreviewQuality.quarter => 'Preview ¼',
        _ => 'Preview ½',
      };

  /// The pending jobs badge.
  static String tasks(int n) => n == 1 ? '1 task' : '$n tasks';

  /// Semantics of the pending jobs badge.
  static String tasksSemantics(int n) => n == 1 ? '1 background task running' : '$n background tasks running';

  /// Semantics label of the preview: "Preview, 1080 by 1920, 00:01:12".
  static String preview(int w, int h, String timecode) => 'Preview, $w by $h, $timecode';

  /// Fullscreen close button.
  static const String exitFullscreen = 'Exit fullscreen';

  /// Fullscreen rotate button.
  static const String rotate = 'Rotate';

  /// Fullscreen play button.
  static const String play = 'Play';

  /// Fullscreen pause button.
  static const String pause = 'Pause';
}

/// The chrome text style of the preview's cards and controls (Figtree; the preview may sit outside
/// any Material ancestor, e.g. in the fullscreen route).
const TextStyle previewChromeTextStyle = TextStyle(
  fontFamily: VwishFonts.family,
  fontSize: 14,
  fontWeight: FontWeight.w400,
  height: 1.35,
  color: VwishColors.textPrimary,
  decoration: TextDecoration.none,
);

/// Whether a visible visual item at [t] uses media in [missing].
bool offlineMediaAt(EditProject project, Set<MediaId> missing, TimeUs t) {
  if (missing.isEmpty) return false;
  for (final track in project.tracks) {
    if (track.hidden || (track.kind != TrackKind.video && track.kind != TrackKind.overlay)) continue;
    final item = activeItemOf(track, t);
    if (item is MediaClip && missing.contains(item.media)) return true;
  }
  return false;
}

/// The quality menu: Auto/Full/Half/Quarter, the proxies toggle and the footer note (ux.md §7.7).
List<VwishMenuEntry> previewQualityEntries(EditorController editor, PreviewStatus status, {bool enabled = true}) {
  VwishMenuItem quality(String label, PreviewQuality q) => VwishMenuItem(
        label: label,
        selected: status.quality == q,
        enabled: enabled,
        onTap: () => unawaited(editor.setPreviewQuality(q)),
      );
  return [
    const VwishMenuHeader(TransportStrings.quality),
    quality(TransportStrings.qualityAuto, PreviewQuality.auto),
    quality(TransportStrings.qualityFull, PreviewQuality.full),
    quality(TransportStrings.qualityHalf, PreviewQuality.half),
    quality(TransportStrings.qualityQuarter, PreviewQuality.quarter),
    const VwishMenuDivider(),
    VwishMenuItem(
      label: TransportStrings.useProxies,
      selected: status.useProxies,
      enabled: enabled,
      onTap: () => unawaited(editor.setUseProxies(!status.useProxies)),
    ),
    const VwishMenuDivider(),
    const VwishMenuHeader(TransportStrings.qualityNote),
  ];
}

/// The slice of EditorState the status overlay depends on.
@immutable
final class _StatusView {
  const _StatusView({required this.ready, required this.preview, required this.missing, required this.tasks, required this.project});

  static _StatusView of(EditorState s) {
    final missing = s.media.missing;
    return _StatusView(
      ready: s.isReady,
      preview: s.preview,
      missing: missing,
      tasks: s.tasks.where((t) => !t.failed).length,
      // The project matters only for the offline check.
      project: missing.isEmpty ? null : s.project,
    );
  }

  final bool ready;
  final PreviewStatus preview;
  final Set<MediaId> missing;
  final int tasks;
  final EditProject? project;

  @override
  bool operator ==(Object other) =>
      other is _StatusView &&
      other.ready == ready &&
      other.preview == preview &&
      setEquals(other.missing, missing) &&
      other.tasks == tasks &&
      identical(other.project, project);

  @override
  int get hashCode => Object.hash(ready, preview, Object.hashAllUnordered(missing), tasks, identityHashCode(project));
}

/// Starting, failed, offline and degraded overlays (ARCH §17.5).
class PreviewStatusOverlay extends ConsumerWidget {
  /// Creates the overlays for the project of the nearest `EditorScope` (or [projectId]).
  const PreviewStatusOverlay({super.key, this.projectId});

  /// The project, when not below an `EditorScope` (fullscreen route).
  final ProjectId? projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = projectId ?? EditorScope.idOf(context);
    final view = ref.watch(editorControllerProvider(id).select(_StatusView.of));
    if (!view.ready) return const SizedBox.shrink();
    final preview = view.preview;
    final children = <Widget>[];

    switch (preview.phase) {
      case PreviewPhase.starting:
        children.add(const IgnorePointer(
          child: Center(child: VwishSpinner(semanticLabel: PreviewStrings.starting)),
        ));
      case PreviewPhase.failed:
        children.add(Center(child: _FittedCard(child: _FailedCard(projectId: id))));
      case PreviewPhase.ready:
      case PreviewPhase.degraded:
        final project = view.project;
        if (project != null) {
          final playhead = ref.watch(playheadProvider(id));
          children.add(ValueListenableBuilder<TimeUs>(
            valueListenable: playhead,
            builder: (context, t, _) => offlineMediaAt(project, view.missing, t)
                ? Center(child: _FittedCard(child: _OfflineCard(projectId: id)))
                : const SizedBox.shrink(),
          ));
        }
    }

    if (preview.phase == PreviewPhase.degraded) {
      children.add(Positioned(
        top: VwishSpacing.sm,
        right: VwishSpacing.sm,
        child: VwishPressable(
          isButton: false,
          tooltip: PreviewStrings.degradedTooltip,
          semanticLabel: '${PreviewStrings.degraded(preview.quality)}. ${PreviewStrings.degradedTooltip}',
          child: VwishBadge(PreviewStrings.degraded(preview.quality), color: VwishColors.warning, icon: Icons.speed_rounded),
        ),
      ));
    }
    if (view.tasks > 0) {
      children.add(Positioned(
        top: VwishSpacing.sm,
        left: VwishSpacing.sm,
        child: IgnorePointer(
          child: Semantics(
            label: PreviewStrings.tasksSemantics(view.tasks),
            excludeSemantics: true,
            child: VwishBadge(PreviewStrings.tasks(view.tasks), icon: Icons.sync_rounded),
          ),
        ),
      ));
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return DefaultTextStyle(style: previewChromeTextStyle, child: Stack(fit: StackFit.expand, children: children));
  }
}

/// Scales a card down to the space available (never overflows a short preview).
class _FittedCard extends StatelessWidget {
  const _FittedCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(VwishSpacing.sm),
        child: FittedBox(fit: BoxFit.scaleDown, child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 320), child: child)),
      );
}

class _FailedCard extends ConsumerWidget {
  const _FailedCard({required this.projectId});

  final ProjectId projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return VwishSurface(
      color: VwishColors.surfaceElevated,
      shadow: VwishShadow.soft,
      padding: const EdgeInsets.all(VwishSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline_rounded, color: VwishColors.errorLight, size: 28),
          const SizedBox(height: VwishSpacing.sm),
          Text(PreviewStrings.stopped, textAlign: TextAlign.center, style: VwishTextStyles.headline.copyWith(fontFamily: VwishFonts.family)),
          const SizedBox(height: VwishSpacing.xs),
          Text(
            PreviewStrings.stoppedMessage,
            textAlign: TextAlign.center,
            style: VwishTextStyles.bodySecondary.copyWith(fontFamily: VwishFonts.family),
          ),
          const SizedBox(height: VwishSpacing.md),
          VwishButton.primary(
            label: PreviewStrings.restart,
            icon: Icons.refresh_rounded,
            onPressed: () => unawaited(ref.read(editorControllerProvider(projectId).notifier).restartPreview()),
          ),
        ],
      ),
    );
  }
}

class _OfflineCard extends ConsumerWidget {
  const _OfflineCard({required this.projectId});

  final ProjectId projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final registry = ref.watch(editorActionRegistryProvider).forPlatformOf(Theme.of(context).platform);
    final ctx = WidgetActionContext(projectId: projectId, context: context, ref: ref);
    final spec = registry.spec(EditorActionId.relink);
    final enabled = spec.isBound && spec.isVisible(ctx) && spec.isEnabled(ctx);
    return ClipRRect(
      borderRadius: VwishRadius.lgAll,
      child: CustomPaint(
        painter: const _HatchPainter(),
        child: Container(
          padding: const EdgeInsets.all(VwishSpacing.lg),
          decoration: BoxDecoration(
            borderRadius: VwishRadius.lgAll,
            border: Border.all(color: VwishColors.borderBright),
            boxShadow: VwishShadows.soft,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.link_off_rounded, color: VwishColors.warning, size: 28),
              const SizedBox(height: VwishSpacing.sm),
              Text(PreviewStrings.mediaMissing, textAlign: TextAlign.center, style: VwishTextStyles.headline.copyWith(fontFamily: VwishFonts.family)),
              const SizedBox(height: VwishSpacing.md),
              VwishButton.secondary(
                label: PreviewStrings.relink,
                icon: Icons.link_rounded,
                onPressed: enabled ? () => registry.invoke(EditorActionId.relink, ctx) : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The hatched fill of the offline card.
class _HatchPainter extends CustomPainter {
  const _HatchPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = VwishColors.surfaceElevated);
    final line = Paint()
      ..color = VwishColors.hairline
      ..strokeWidth = 6;
    for (var x = -size.height; x < size.width; x += 18) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), line);
    }
  }

  @override
  bool shouldRepaint(_HatchPainter oldDelegate) => false;
}
