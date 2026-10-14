// OWNER: UX-35
//
// Background tasks with cancel (ux.md §10.15, §16.2, ARCH §17.7) and the freeze frame
// confirmation.
//
// * `TasksSheet` (`showDanaviewSheet(title: 'Background tasks')`) lists `EditorState.tasks`: proxies,
//   reverse, freeze, waveforms, captions and the model download, with progress, Cancel for running
//   tasks and "Try again" / "Dismiss" for failed ones (through `TasksController`). It follows the
//   state while open. The sheet route sits outside the editor's `EditorScope`, so it takes the
//   project id.
// * `FreezeFrameSheet` asks for the still's duration (`DanaviewNumberField`, default 3 s, 0.1-60 s)
//   and returns it, or null when cancelled.

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart' show ProjectId, TimeUs, microsPerSecond;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../../app/strings/clip_strings.dart';
import '../state/editor_state.dart';
import '../state/tasks_controller.dart';
import '../timeline/timeline_semantics.dart' show editorAnnounce;

TextStyle get _caption => DanaviewTextStyles.caption.copyWith(fontFamily: DanaviewFonts.family, color: DanaviewColors.textSecondary);

/// The icon of a task kind.
IconData taskIcon(EditorTaskKind kind) => switch (kind) {
      EditorTaskKind.proxy => Icons.speed_rounded,
      EditorTaskKind.reverse => Icons.fast_rewind_rounded,
      EditorTaskKind.freeze => Icons.ac_unit_rounded,
      EditorTaskKind.waveform => Icons.graphic_eq_rounded,
      EditorTaskKind.captions => Icons.closed_caption_rounded,
      EditorTaskKind.download => Icons.download_rounded,
    };

/// The Tasks sheet's content (ux.md §10.15).
class TasksSheet extends ConsumerWidget {
  /// Creates the sheet for project [projectId].
  const TasksSheet({super.key, required this.projectId});

  /// The open project.
  final ProjectId projectId;

  /// Shows the sheet for [projectId].
  static Future<void> show(BuildContext context, {required ProjectId projectId}) => showDanaviewSheet<void>(
        context,
        title: ClipStrings.tasksTitle,
        builder: (_) => TasksSheet(projectId: projectId),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(editorControllerProvider(projectId).select((s) => s.tasks));
    final controller = ref.watch(tasksControllerProvider(projectId));
    if (tasks.isEmpty) {
      return Padding(
        key: const ValueKey<String>('tasks.empty'),
        padding: const EdgeInsets.symmetric(vertical: DanaviewSpacing.lg),
        child: Text(ClipStrings.tasksEmpty, textAlign: TextAlign.center, style: _caption),
      );
    }
    return Column(
      key: const ValueKey<String>('tasks.list'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final t in tasks) TaskRow(key: ValueKey<String>('tasks.row.${t.id}'), task: t, controller: controller),
        Padding(
          padding: const EdgeInsets.only(top: DanaviewSpacing.sm),
          child: Text(ClipStrings.tasksHint, style: _caption),
        ),
      ],
    );
  }
}

/// One task: icon, label, progress or failure, and its actions.
class TaskRow extends StatelessWidget {
  /// Creates the row.
  const TaskRow({super.key, required this.task, required this.controller});

  /// The task.
  final EditorTaskInfo task;

  /// Runs Cancel / Try again / Dismiss.
  final TasksController controller;

  @override
  Widget build(BuildContext context) {
    final failed = task.failed;
    final actions = <Widget>[
      if (!failed && controller.canCancel(task.id))
        DanaviewButton(
          key: ValueKey<String>('tasks.cancel.${task.id}'),
          label: ClipStrings.cancelTask,
          size: DanaviewButtonSize.sm,
          variant: DanaviewButtonVariant.ghost,
          semanticLabel: '${ClipStrings.cancelTask} ${task.label}',
          onPressed: () {
            controller.cancel(task.id);
            editorAnnounce(context, ClipStrings.taskCancelled);
          },
        ),
      if (failed && controller.canRetry(task.id))
        DanaviewButton(
          key: ValueKey<String>('tasks.retry.${task.id}'),
          label: ClipStrings.retry,
          size: DanaviewButtonSize.sm,
          variant: DanaviewButtonVariant.tonal,
          onPressed: () => controller.retry(task.id),
        ),
      if (failed)
        DanaviewButton(
          key: ValueKey<String>('tasks.dismiss.${task.id}'),
          label: ClipStrings.dismiss,
          size: DanaviewButtonSize.sm,
          variant: DanaviewButtonVariant.ghost,
          onPressed: () => controller.dismiss(task.id),
        ),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: DanaviewSpacing.xs + 2),
      child: Semantics(
        container: true,
        label: ClipStrings.taskSemantics(task.label, task.progress, failed: failed),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ExcludeSemantics(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(
                      failed ? Icons.error_outline_rounded : taskIcon(task.kind),
                      size: 20,
                      color: failed ? DanaviewColors.error : DanaviewColors.textSecondary,
                    ),
                  ),
                  const SizedBox(width: DanaviewSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(task.label,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: DanaviewTextStyles.body.copyWith(fontFamily: DanaviewFonts.family, color: DanaviewColors.textPrimary)),
                        const SizedBox(height: 2),
                        Text(failed ? ClipStrings.taskFailed : ClipStrings.taskProgress(task.progress),
                            maxLines: 2, overflow: TextOverflow.ellipsis, style: _caption),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (!failed) ...[
              const SizedBox(height: DanaviewSpacing.xs + 2),
              ExcludeSemantics(child: DanaviewProgressBar(key: ValueKey<String>('tasks.progress.${task.id}'), value: task.progress)),
            ],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: DanaviewSpacing.xs),
              Align(alignment: AlignmentDirectional.centerEnd, child: Wrap(spacing: 8, runSpacing: 4, children: actions)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Asks for the length of a freeze frame (ux.md §10.15).
class FreezeFrameSheet extends StatefulWidget {
  /// Creates the sheet content; [onDone] receives the duration or null.
  const FreezeFrameSheet({super.key, required this.onDone, this.initial = 3});

  /// Called with the chosen duration, or null on Cancel.
  final ValueChanged<TimeUs?> onDone;

  /// Initial length in seconds.
  final double initial;

  /// Shortest still in seconds.
  static const double minSeconds = 0.1;

  /// Longest still in seconds.
  static const double maxSeconds = 60;

  /// Shows the sheet; resolves to the duration, or null when dismissed.
  static Future<TimeUs?> show(BuildContext context) => showDanaviewSheet<TimeUs?>(
        context,
        title: ClipStrings.freezeTitle,
        builder: (sheet) => FreezeFrameSheet(onDone: (d) => Navigator.of(sheet).pop(d)),
      );

  @override
  State<FreezeFrameSheet> createState() => _FreezeFrameSheetState();
}

class _FreezeFrameSheetState extends State<FreezeFrameSheet> {
  late double _seconds = widget.initial;

  @override
  Widget build(BuildContext context) => Column(
        key: const ValueKey<String>('freeze.sheet'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(ClipStrings.freezeBody, style: _caption),
          const SizedBox(height: DanaviewSpacing.md),
          DanaviewNumberField(
            key: const ValueKey<String>('freeze.duration'),
            label: ClipStrings.freezeDuration,
            semanticLabel: ClipStrings.freezeDuration,
            value: _seconds,
            min: FreezeFrameSheet.minSeconds,
            max: FreezeFrameSheet.maxSeconds,
            step: 0.5,
            fractionDigits: 1,
            unit: ClipStrings.secondsUnit,
            onChanged: (v) => setState(() => _seconds = v),
          ),
          const SizedBox(height: DanaviewSpacing.lg),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              DanaviewButton(
                key: const ValueKey<String>('freeze.cancel'),
                label: ClipStrings.cancel,
                variant: DanaviewButtonVariant.ghost,
                onPressed: () => widget.onDone(null),
              ),
              DanaviewButton.primary(
                key: const ValueKey<String>('freeze.confirm'),
                label: ClipStrings.freezeConfirm,
                icon: Icons.ac_unit_rounded,
                onPressed: () => widget.onDone((_seconds * microsPerSecond).round()),
              ),
            ],
          ),
        ],
      );
}
