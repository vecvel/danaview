// OWNER: UX-35
//
// The clip info panel (ux.md §10.15, ARCH §17.7 "info"): read-only facts of one media clip.
//
// * Rows: name, source (the file's display name, never a path), duration, source in/out (on the
//   project's frame grid), speed, direction, resolution, frame rate, codec, audio, size, where the
//   file is stored (ownership) and its status.
// * A reversed clip whose rendition is being made shows "Reversing 45%" with "Cancel reverse"; a
//   freeze still being made shows its progress with "Cancel freeze frame"; a failed one shows
//   "Try again". Progress comes from `EditorState.tasks`, the actions from `TasksController`.
// * The panel owns its scrolling; it works on locked tracks (it only reads).
//
// Keep the constructor contract `ClipInfoPanel({Key? key, required ClipInfoInspector route})`:
// InspectorHost (UX-16) builds panels with it.

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/eval.dart' show MediaClipTimeMap;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_features/storage.dart' show formatDataSize;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../../app/strings/clip_strings.dart';
import '../contracts/inspector_routes.dart';
import '../editor_scope.dart';
import '../state/editor_state.dart';
import '../state/tasks_controller.dart';
import '../timeline/timeline_semantics.dart' show editorAnnounce;

/// What the panel shows of the project.
typedef ClipInfoView = ({
  MediaClip? clip,
  MediaAsset? asset,
  MediaAsset? source,
  MediaAsset? derived,
  FrameRate rate,
  bool offline,
  EditorTaskInfo? task,
});

ClipInfoView _viewOf(EditorState s, ItemId id) {
  final project = s.project;
  final item = project?.index.item(id);
  final rate = project?.settings.frameRate ?? FrameRate.fps30;
  if (project == null || item is! MediaClip) {
    return (clip: null, asset: null, source: null, derived: null, rate: rate, offline: false, task: null);
  }
  final asset = project.pool[item.media];
  // The asset being produced for this clip: a pending or failed still it shows, or the reversed
  // rendition it waits for.
  MediaAsset? derived;
  if (asset != null && asset.derived is StillSpec && asset.status is! ReadyStatus) {
    derived = asset;
  } else if (item.reversed) {
    final r = TasksController.renditionFor(project.pool, item);
    if (r != null && r.status is! ReadyStatus) derived = r;
  }
  EditorTaskInfo? task;
  final status = derived?.status;
  if (status is PendingStatus) {
    for (final t in s.tasks) {
      if (t.id == status.jobId) task = t;
    }
  }
  final from = switch (asset?.derived) {
    StillSpec(:final media) || ReversedSpec(:final media) => project.pool[media],
    null => null,
  };
  return (
    clip: item,
    asset: asset,
    source: from ?? asset,
    derived: derived,
    rate: rate,
    offline: asset == null || s.media.missing.contains(item.media),
    task: task,
  );
}

/// The clip info panel (ux.md §10.15).
class ClipInfoPanel extends ConsumerWidget {
  /// Creates the panel.
  const ClipInfoPanel({super.key, required this.route});

  /// What the panel shows.
  final ClipInfoInspector route;

  /// The rows of [view] as (label, value) pairs.
  static List<(String, String)> rowsOf(ClipInfoView view) {
    final clip = view.clip!;
    final asset = view.asset;
    final rate = view.rate;
    final p = asset?.probe;
    final source = view.source;
    final timeBased = asset != null && (asset.kind == MediaKind.video || asset.kind == MediaKind.audio || asset.kind == MediaKind.recording);
    final w = p?.width, h = p?.height;
    final swap = (p?.rotation ?? 0) % 180 != 0;
    final speed = clip.speed;
    return [
      (ClipStrings.infoName, clip.label?.isNotEmpty == true ? clip.label! : (asset?.displayName ?? '—')),
      (ClipStrings.infoSource, source?.displayName ?? '—'),
      (ClipStrings.infoDuration, Timecode.format(clip.duration, rate)),
      if (timeBased) ...[
        (ClipStrings.infoSourceIn, Timecode.format(clip.sourceIn, rate)),
        (ClipStrings.infoSourceOut, Timecode.format(clip.sourceOut, rate)),
        (ClipStrings.infoSpeed, speed is ConstantSpeed ? ClipStrings.speedValue(speed.rate) : ClipStrings.speedCurve),
        if (clip.visual != null) (ClipStrings.infoDirection, clip.reversed ? ClipStrings.reversed : ClipStrings.forward),
      ],
      if (w != null && h != null && w > 0 && h > 0) (ClipStrings.infoResolution, '${swap ? h : w}×${swap ? w : h}'),
      if (p?.nominalFps case final fps? when fps > 0) (ClipStrings.infoFrameRate, ClipStrings.fps(fps)),
      if (p?.videoCodec case final codec? when codec.isNotEmpty) (ClipStrings.infoCodec, codec.toUpperCase()),
      if (p != null && asset!.kind != MediaKind.image && asset.kind != MediaKind.still)
        (
          ClipStrings.infoAudio,
          p.hasAudio ? ClipStrings.audioValue(codec: p.audioCodec, channels: p.channels, sampleRate: p.sampleRate) : ClipStrings.noAudio
        ),
      if (asset != null && asset.fingerprint.sizeBytes > 0) (ClipStrings.infoSize, formatDataSize(asset.fingerprint.sizeBytes)),
      if (asset != null) (ClipStrings.infoLocation, ClipStrings.location(asset.ownership)),
      (ClipStrings.infoStatus, view.offline ? ClipStrings.statusMissing : ClipStrings.statusReady),
    ];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = EditorScope.idOf(context);
    final view = ref.watch(editorControllerProvider(id).select((s) => _viewOf(s, route.item)));
    if (view.clip == null) {
      return Padding(
        key: const ValueKey<String>('clipInfo.gone'),
        padding: const EdgeInsets.all(16),
        child: Align(alignment: Alignment.topLeft, child: Text(ClipStrings.clipGone, style: _caption)),
      );
    }
    return CustomScrollView(
      key: const ValueKey<String>('clipInfo.scroll'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (view.derived != null) ...[
                  _DerivedStatus(view: view, projectId: id),
                  const SizedBox(height: 12),
                ],
                for (final (label, value) in rowsOf(view)) _InfoRow(label: label, value: value),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

TextStyle get _caption => DanaviewTextStyles.caption.copyWith(fontFamily: DanaviewFonts.family, color: DanaviewColors.textSecondary);

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        key: ValueKey<String>('clipInfo.row.$label'),
        padding: const EdgeInsets.symmetric(vertical: DanaviewSpacing.xs + 1),
        child: Semantics(
          container: true,
          label: '$label, $value',
          child: ExcludeSemantics(
            child: LayoutBuilder(builder: (context, c) {
              final labelWidth = (c.maxWidth * 0.38).clamp(72.0, 140.0).toDouble();
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: labelWidth, child: Text(label, style: _caption.copyWith(height: 1.35))),
                  const SizedBox(width: DanaviewSpacing.sm),
                  Expanded(
                    child: Text(
                      value,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: DanaviewTextStyles.body.copyWith(
                        fontFamily: DanaviewFonts.family,
                        color: DanaviewColors.textPrimary,
                        height: 1.35,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              );
            }),
          ),
        ),
      );
}

/// Progress, cancel and retry of the reversed rendition or freeze still the clip waits for.
class _DerivedStatus extends ConsumerWidget {
  const _DerivedStatus({required this.view, required this.projectId});

  final ClipInfoView view;
  final ProjectId projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asset = view.derived!;
    final still = asset.derived is StillSpec;
    final status = asset.status;
    final failed = status is FailedStatus;
    final cancelled = status is FailedStatus && status.reason == 'cancelled';
    final progress = view.task?.progress;
    final title = failed
        ? (cancelled ? ClipStrings.cancelledStatus : (still ? ClipStrings.freezeFailed : ClipStrings.reverseFailed))
        : (still ? ClipStrings.freezing(progress) : ClipStrings.reversing(progress));
    final tasks = ref.read(tasksControllerProvider(projectId));
    final task = view.task;
    Widget? action;
    if (!failed && task != null && tasks.canCancel(task.id)) {
      action = DanaviewButton(
        key: const ValueKey<String>('clipInfo.cancel'),
        label: still ? ClipStrings.cancelFreeze : ClipStrings.cancelReverse,
        size: DanaviewButtonSize.sm,
        variant: DanaviewButtonVariant.secondary,
        onPressed: () {
          tasks.cancel(task.id);
          editorAnnounce(context, ClipStrings.taskCancelled);
        },
      );
    } else if (failed && !cancelled) {
      final failedTask = tasks.tasks.where((t) => t.failed && t.kind == (still ? EditorTaskKind.freeze : EditorTaskKind.reverse));
      final retryId = [
        for (final t in failedTask)
          if (tasks.canRetry(t.id)) t.id,
      ];
      action = DanaviewButton(
        key: const ValueKey<String>('clipInfo.retry'),
        label: ClipStrings.retry,
        size: DanaviewButtonSize.sm,
        variant: DanaviewButtonVariant.tonal,
        onPressed: retryId.isEmpty ? null : () => tasks.retry(retryId.first),
      );
    }
    return DecoratedBox(
      key: const ValueKey<String>('clipInfo.derived'),
      decoration: BoxDecoration(
        color: DanaviewColors.surfaceElevatedHigher,
        borderRadius: DanaviewRadius.controlAll,
        border: Border.fromBorderSide(DanaviewBorders.hairline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              liveRegion: true,
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(failed ? Icons.error_outline_rounded : (still ? Icons.ac_unit_rounded : Icons.fast_rewind_rounded),
                    size: 16, color: failed ? DanaviewColors.error : DanaviewColors.primaryLight),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(title,
                      key: const ValueKey<String>('clipInfo.derivedTitle'),
                      style: DanaviewTextStyles.body.copyWith(fontFamily: DanaviewFonts.family, color: DanaviewColors.textPrimary)),
                ),
              ]),
            ),
            if (!failed) ...[
              const SizedBox(height: 8),
              ExcludeSemantics(child: DanaviewProgressBar(value: progress)),
            ],
            if (action != null) ...[
              const SizedBox(height: 8),
              Align(alignment: AlignmentDirectional.centerEnd, child: action),
            ],
          ],
        ),
      ),
    );
  }
}
