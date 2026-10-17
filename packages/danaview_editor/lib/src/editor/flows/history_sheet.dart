// OWNER: UX-29
//
// The History sheet (ux.md §14.2, ARCH §7.3, §17.7): `showDanaviewSheet(title: 'Edit history')`
// with the last 50 history labels, newest first. Opened by the `history` action (long-press on
// undo, Project sheet › Edit history).
//
// * Rows come from the session's history entries (`EditorSession.historyEntries`) and the cursor
//   (`HistoryStatus.position`): entries at or after the cursor were undone (dimmed, "Undone · tap
//   to redo"); the entry just before the cursor is the current state (marked and selected).
// * When every kept entry fits, a last row "Start" stands for the state before them.
// * Tapping a row moves to that point with ONE controller call, `EditorController.jumpHistory(n)`,
//   which applies the N steps and patches the plan once (ARCH §7.3). The sheet stays open and
//   follows the history, so further taps keep working.
// * The sheet route sits outside the editor's `EditorScope`, so it takes the project id.

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart' show ProjectId;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_providers.dart';
import '../../app/strings/project_strings.dart';

/// One row of the History sheet.
@immutable
final class HistoryRow {
  /// Creates a row.
  const HistoryRow({required this.entry, required this.label, required this.steps, required this.current, required this.undone});

  /// Index of the history entry (oldest is 0), or -1 for the "Start" row.
  final int entry;

  /// What the row shows.
  final String label;

  /// The `jumpHistory` argument that moves to this row (0 for the current row).
  final int steps;

  /// Whether this is the current state.
  final bool current;

  /// Whether the entry was undone (redo would re-apply it).
  final bool undone;

  /// Whether this is the "Start" row.
  bool get isStart => entry < 0;

  @override
  bool operator ==(Object other) =>
      other is HistoryRow &&
      other.entry == entry &&
      other.label == label &&
      other.steps == steps &&
      other.current == current &&
      other.undone == undone;

  @override
  int get hashCode => Object.hash(entry, label, steps, current, undone);

  @override
  String toString() => 'HistoryRow($entry, $label, steps: $steps${current ? ', current' : ''}${undone ? ', undone' : ''})';
}

/// The rows of the History sheet for entry [labels] (oldest first) with [position] entries applied:
/// the newest [max] entries, newest first, then "Start" when every entry is shown.
List<HistoryRow> historyRows(List<String> labels, int position, {int max = HistorySheet.maxRows}) {
  final n = labels.length;
  final cursor = position.clamp(0, n);
  final shown = n < max ? n : max;
  final rows = <HistoryRow>[
    for (var i = n - 1; i >= n - shown; i--)
      HistoryRow(entry: i, label: labels[i], steps: i + 1 - cursor, current: i == cursor - 1, undone: i >= cursor),
  ];
  if (n > 0 && shown == n) {
    rows.add(HistoryRow(entry: -1, label: ProjectStrings.historyStart, steps: -cursor, current: cursor == 0, undone: false));
  }
  return rows;
}

/// The History sheet's content (ux.md §14.2).
class HistorySheet extends ConsumerWidget {
  /// Creates the sheet for project [projectId].
  const HistorySheet({super.key, required this.projectId});

  /// The open project.
  final ProjectId projectId;

  /// Most entries listed (ux.md §14.2).
  static const int maxRows = 50;

  /// Shows the sheet for [projectId].
  static Future<void> show(BuildContext context, {required ProjectId projectId}) => showDanaviewSheet<void>(
        context,
        title: ProjectStrings.historyTitle,
        builder: (_) => HistorySheet(projectId: projectId),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = editorControllerProvider(projectId);
    final history = ref.watch(provider.select((s) => s.history));
    // Rebuild on every commit too (a coalesced edit keeps the status but may change entries).
    ref.watch(provider.select((s) => s.project?.revision));
    final ready = ref.watch(provider.select((s) => s.isReady));
    final editor = ref.read(provider.notifier);
    final labels = [for (final e in editor.session.historyEntries) e.label];
    final rows = historyRows(labels, history.position);
    if (rows.isEmpty) {
      return const Padding(
        key: ValueKey<String>('history.empty'),
        padding: EdgeInsets.symmetric(vertical: DanaviewSpacing.lg),
        child: Text(ProjectStrings.historyEmpty, textAlign: TextAlign.center, style: _captionStyle),
      );
    }
    final hidden = labels.length - (rows.where((r) => !r.isStart).length);
    return Column(
      key: const ValueKey<String>('history.list'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final row in rows)
          DanaviewListTile(
            key: ValueKey<String>(row.isStart ? 'history.start' : 'history.row.${row.entry}'),
            title: row.label,
            subtitle: row.current
                ? ProjectStrings.historyCurrent
                : row.undone
                    ? ProjectStrings.historyUndone
                    : (row.isStart ? ProjectStrings.historyStartHint : null),
            leading: Icon(
              row.current
                  ? Icons.check_circle_rounded
                  : row.undone
                      ? Icons.redo_rounded
                      : (row.isStart ? Icons.flag_outlined : Icons.history_rounded),
              size: 20,
              color: row.current ? DanaviewColors.primaryLight : (row.undone ? DanaviewColors.textMuted : DanaviewColors.textSecondary),
            ),
            selected: row.current,
            dense: true,
            enabled: ready,
            semanticLabel: ProjectStrings.historyRowSemantics(row.label, current: row.current, undone: row.undone),
            onTap: row.steps == 0 ? null : () => editor.jumpHistory(row.steps),
          ),
        if (hidden > 0)
          Padding(
            key: const ValueKey<String>('history.older'),
            padding: const EdgeInsets.fromLTRB(4, DanaviewSpacing.sm, 4, 0),
            child: Text(ProjectStrings.historyOlder(hidden), style: _captionStyle),
          ),
      ],
    );
  }

  static const TextStyle _captionStyle = TextStyle(
    fontFamily: DanaviewFonts.family,
    fontSize: 13,
    height: 1.3,
    color: DanaviewColors.textSecondary,
  );
}
