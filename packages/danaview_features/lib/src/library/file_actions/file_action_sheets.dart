// OWNER: HOM-22
// EXTENDED: HOM-28 (a PDF's menu lists "Organise pages" and "Merge with…" when the page tools are
// wired.)
// EXTENDED: HOM-30 (a PDF's menu lists "Sign…" when a sign handler is wired.)
//
// The sheets of the file actions (ARCH v1.2 §1.4, V2-118; HOM plan §8.3), kit components only:
// the single-file menu (long-press menus and viewer toolbars call [showFileActionsMenu]), the
// Danaview folder picker of Copy to… and Move to…, and the File info sheet (type, size, dates,
// page count, dimensions or duration, where it came from).

import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'file_action_providers.dart';
import 'file_action_runner.dart';

/// The single-file actions [item] gets with [port] (null: nothing can leave the app);
/// [pdfTools] adds "Organise pages" and "Merge with…" for a PDF (HOM-28), [canCompress]
/// "Compress…" (HOM-31), [canSign] "Sign…" (HOM-30).
List<FileAction> fileMenuActions(MediaItem item, FileOutPort? port, {bool pdfTools = false, bool canCompress = false, bool canSign = false}) {
  final caps = port?.capabilities ?? FileOutCapabilities.none;
  return fileActionsFor(
    FileActionTarget.of(item),
    canShare: caps.canShare,
    canOpenIn: caps.canOpenIn,
    canSaveOut: caps.primarySaveTarget != null,
    canSaveToPhotos: caps.canSaveToPhotos,
    canPdfTools: pdfTools,
    canCompress: canCompress,
    canSign: canSign,
  );
}

/// Shows the file menu of [item] and runs the chosen action. [anchor] places share and open-in
/// popovers on iPad and macOS (defaults to the caller's widget).
Future<void> showFileActionsMenu(BuildContext context, WidgetRef ref, MediaItem item, {OutAnchor? anchor}) async {
  final where = anchor ?? anchorOf(context);
  final chosen = await showDanaviewSheet<FileAction>(
    context,
    title: item.name,
    builder: (sheetContext) => Consumer(builder: (context, ref, _) {
      final port = ref.watch(fileOutPortProvider);
      final actions = fileMenuActions(
        item,
        port,
        pdfTools: ref.watch(pdfPageToolsHandlerProvider) != null,
        canCompress: ref.watch(compressPdfHandlerProvider) != null,
        canSign: ref.watch(signPdfHandlerProvider) != null,
      );
      final favourite = ref.watch(libraryFileActionsProvider)?.liveEntry(item.id)?.isFavourite ?? false;
      return SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final action in actions)
              DanaviewListTile(
                key: ValueKey(fileActionId(action)),
                leading: DanaviewIconTile(
                  fileActionIcon(action, favourite: favourite),
                  color: action == FileAction.delete ? DanaviewColors.errorLight : DanaviewColors.primaryLight,
                ),
                title: fileActionLabel(action, capabilities: port?.capabilities, favourite: favourite),
                destructive: action == FileAction.delete,
                onTap: () => Navigator.of(sheetContext).pop(action),
              ),
          ],
        ),
      );
    }),
  );
  if (chosen == null || !context.mounted) return;
  await runFileAction(context, ref, chosen, [item], anchor: where);
}

/// Shows the Danaview folders and resolves to the one picked (null when dismissed). [current]
/// marks the folder the items are in (Move to… can't pick it).
Future<FolderChoice?> showFolderPicker(BuildContext context, List<FolderChoice> choices, {required String title, FolderId? current}) =>
    showDanaviewSheet<FolderChoice>(
      context,
      title: title,
      builder: (sheetContext) => choices.isEmpty
          ? const DanaviewEmptyState(icon: Icons.folder_off_outlined, title: 'No folders yet')
          : ListView(
              key: const ValueKey('file-folder-picker'),
              shrinkWrap: true,
              children: [
                for (final c in choices)
                  Padding(
                    padding: EdgeInsets.only(left: DanaviewSpacing.md * c.depth.clamp(0, 4)),
                    child: DanaviewListTile(
                      key: ValueKey('file-folder-${c.id.value}'),
                      leading: const DanaviewIconTile(Icons.folder_rounded),
                      title: c.name,
                      subtitle: c.depth > 0 ? c.path.sublist(0, c.path.length - 1).join(' › ') : null,
                      semanticLabel: c.label,
                      enabled: c.id != current,
                      selected: c.id == current,
                      onTap: c.id == current ? null : () => Navigator.of(sheetContext).pop(c),
                    ),
                  ),
              ],
            ),
    );

String _bytes(int n) {
  if (n < 1024) return '$n B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = n / 1024;
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return '${v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1)} ${units[u]}';
}

String _date(DateTime d) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final l = d.toLocal();
  final hh = l.hour.toString().padLeft(2, '0');
  final mm = l.minute.toString().padLeft(2, '0');
  return '${l.day} ${months[l.month - 1]} ${l.year}, $hh:$mm';
}

String _duration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(h > 0 ? 2 : 1, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// The rows of the File info sheet for [info], label first.
List<(String, String)> fileInfoRows(FileInfo info) => [
      ('Type', info.typeLabel),
      if (info.sizeBytes case final size?) ('Size', _bytes(size)),
      if (info.width != null && info.height != null) ('Dimensions', '${info.width} × ${info.height}'),
      if (info.duration case final d? when d > Duration.zero) ('Duration', _duration(d)),
      if (info.frameRate case final fps?) ('Frame rate', '${fps.toStringAsFixed(fps.truncateToDouble() == fps ? 0 : 2)} fps'),
      if (info.pageCount case final pages?) ('Pages', '$pages'),
      if (info.camera case final camera?) ('Camera', camera),
      if (info.takenAt case final taken?) ('Taken', _date(taken)),
      if (info.addedAt case final added?) ('Added', _date(added)),
      ('Modified', _date(info.modifiedAt)),
      if (info.lastOpenedAt case final opened?) ('Last opened', _date(opened)),
      if (info.folderPath.isNotEmpty) ('Folder', info.folderPath.join(' › ')),
      if (info.source case final source?) ('Came from', sourceLabel(source)),
      if (info.readOnly) ('Access', 'Read-only'),
    ];

/// Shows the File info sheet of [item].
Future<void> showFileInfoSheet(BuildContext context, WidgetRef ref, MediaItem item) {
  final actions = ref.read(libraryFileActionsProvider);
  final info = actions?.info(item) ?? LibraryFileActions.itemInfo(item);
  return showDanaviewSheet<void>(
    context,
    title: 'File info',
    builder: (context) => SingleChildScrollView(
      key: const ValueKey('file-info-sheet'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: DanaviewSpacing.sm),
            child: Text(
              info.name,
              style: DanaviewTextStyles.headline.copyWith(color: DanaviewColors.foregroundOn(DanaviewColors.surfaceElevated)),
            ),
          ),
          for (final (label, value) in fileInfoRows(info))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: DanaviewSpacing.xxs),
              child: Semantics(
                label: '$label: $value',
                excludeSemantics: true,
                child: Wrap(
                  spacing: DanaviewSpacing.sm,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 96),
                      child: Text(label, style: DanaviewTextStyles.bodySecondary.copyWith(color: DanaviewColors.textSecondary)),
                    ),
                    Text(value, style: DanaviewTextStyles.body.copyWith(color: DanaviewColors.textPrimary)),
                  ],
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

