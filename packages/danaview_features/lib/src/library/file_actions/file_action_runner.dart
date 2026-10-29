// OWNER: HOM-22
// EXTENDED: HOM-28 (Organise pages and Merge with… go to the app root's PDF page tools handler.)
// EXTENDED: HOM-30 (Sign… goes to the app root's sign handler.)
//
// Runs one file action on one item or a selection (ARCH v1.2 V2-08, V2-117, V2-118; HOM plan
// §8.3), shared by the single-file menu and the multi-select bar: the getting-files-out actions
// through the [FileOutPort] (the platform hands out temporary read-only copies and saves
// create-new copies), the library actions through [LibraryFileActions] (every write fires the
// store's changes, so tabs re-query in the same frame), with kit dialogs and toasts. Delete asks
// first and says "Used in N projects" when an editor project or photo edit holds a file. Nothing
// here logs (rule 30), and no error escapes: unexpected ones end in the generic toast.

import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../selection/selection_model.dart';
import 'file_action_providers.dart';
import 'file_action_sheets.dart';

/// The popover anchor of the widget at [context], in global logical pixels (null before layout).
OutAnchor? anchorOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize || !box.attached) return null;
  final topLeft = box.localToGlobal(Offset.zero);
  return OutAnchor(topLeft.dx, topLeft.dy, box.size.width, box.size.height);
}

/// The toast text of a [FileOutException] for [action].
String fileOutErrorMessage(FileOutError error, FileAction action) => switch (error) {
      FileOutError.unsupported => 'Not available on this device',
      FileOutError.denied => action == FileAction.saveToPhotos ? 'Danaview isn’t allowed to add to Photos' : 'Access was denied',
      FileOutError.missing => 'The file is no longer there',
      FileOutError.busy => 'Finish the open sheet first',
      FileOutError.failed => 'That didn’t work. Try again',
    };

/// The toast text after a save-out of [outcome] (null when cancelled).
String? saveOutMessage(SaveOutOutcome outcome, {required bool photos}) {
  if (outcome.cancelled) return null;
  final where = photos ? ' to Photos' : '';
  if (outcome.saved == 0) return outcome.failed == 1 ? 'The file couldn’t be saved$where' : 'The files couldn’t be saved$where';
  final saved = outcome.saved == 1 ? 'Saved a copy$where' : 'Saved ${outcome.saved} copies$where';
  return outcome.failed == 0 ? saved : '$saved; ${outcome.failed} couldn’t be saved';
}

/// The confirm title of deleting [count] items.
String deleteTitle(int count) => count == 1 ? 'Delete this file?' : 'Delete $count files?';

/// The confirm message of a delete: the "Used in N projects" warning first, then where files go.
String deleteMessage(RefUsage usage) {
  final warning = deleteWarningText(usage);
  const after = 'Deleted files stay in Recently deleted for 30 days.';
  return warning == null ? after : '$warning. Those projects will ask you to relink them.\n$after';
}

void _toast(BuildContext context, String message, {DanaviewToastKind kind = DanaviewToastKind.info, IconData? icon}) {
  if (context.mounted) DanaviewToast.show(context, message, kind: kind, icon: icon);
}

List<EntryId> _entryIds(List<MediaItem> items) => [
      for (final i in items)
        if (EntryId.tryParse(i.id.value) case final id?) id,
    ];

List<OutFile> _outFiles(LibraryFileActions? actions, List<MediaItem> items) {
  final targets = [for (final i in items) FileActionTarget.of(i)];
  if (actions != null) return actions.outFiles(targets);
  return [
    for (final t in targets)
      if (!t.isLibraryEntry && t.localPath != null) OutFile(path: t.localPath!, displayName: t.item.name, mime: t.item.mimeType),
  ];
}

/// Runs [action] on [items] (selection order). Resolves to true when the action finished (the
/// bar then leaves selection mode), false when the user cancelled or it failed.
Future<bool> runFileAction(BuildContext context, WidgetRef ref, FileAction action, List<MediaItem> items, {OutAnchor? anchor}) async {
  if (items.isEmpty) return false;
  final actions = ref.read(libraryFileActionsProvider);
  final port = ref.read(fileOutPortProvider);
  try {
    switch (action) {
      case FileAction.share || FileAction.saveOut || FileAction.saveToPhotos || FileAction.openIn:
        if (port == null) {
          _toast(context, fileOutErrorMessage(FileOutError.unsupported, action));
          return false;
        }
        final files = _outFiles(actions, items);
        if (files.isEmpty) {
          _toast(context, fileOutErrorMessage(FileOutError.missing, action), kind: DanaviewToastKind.error);
          return false;
        }
        return await _out(context, port, action, files, anchor);
      case FileAction.info:
        await showFileInfoSheet(context, ref, items.first);
        return true;
      case FileAction.mergeIntoPdf:
        final merge = ref.read(mergeIntoPdfHandlerProvider);
        if (merge == null) return false;
        await merge(context, items);
        return true;
      case FileAction.organisePages || FileAction.mergeWith:
        final tools = ref.read(pdfPageToolsHandlerProvider);
        if (tools == null) return false;
        await tools(context, action, items.first);
        return true;
      case FileAction.compressPdf:
        final compress = ref.read(compressPdfHandlerProvider);
        if (compress == null) return false;
        await compress(context, items.first);
        return true;
      case FileAction.signPdf:
        final sign = ref.read(signPdfHandlerProvider);
        if (sign == null) return false;
        await sign(context, items.first);
        return true;
      case FileAction.rename || FileAction.copyTo || FileAction.moveTo || FileAction.favourite || FileAction.delete:
        final ids = _entryIds(items);
        if (actions == null || ids.isEmpty) {
          _toast(context, fileOutErrorMessage(FileOutError.unsupported, action));
          return false;
        }
        return await _library(context, ref, actions, action, items, ids);
    }
  } on FileOutException catch (e) {
    if (context.mounted) _toast(context, fileOutErrorMessage(e.error, action), kind: DanaviewToastKind.error);
    return false;
  } on LibraryWriteException catch (e) {
    final message = switch (e.error) {
      LibraryWriteError.invalidName => 'That name can’t be used',
      LibraryWriteError.readOnly => 'This library was made by a newer Danaview and is read-only',
      LibraryWriteError.trashed || LibraryWriteError.notFound => 'The file is no longer there',
      _ => 'That didn’t work. Try again',
    };
    if (context.mounted) _toast(context, message, kind: DanaviewToastKind.error);
    return false;
  } catch (_) {
    // Anything else (a raw FileSystemException in process, the writer isolate's StateError, a
    // platform error): its text can carry library paths and file names, so it is neither logged
    // nor rethrown (rule 30); the user gets the generic toast.
    if (context.mounted) _toast(context, fileOutErrorMessage(FileOutError.failed, action), kind: DanaviewToastKind.error);
    return false;
  }
}

Future<bool> _out(BuildContext context, FileOutPort port, FileAction action, List<OutFile> files, OutAnchor? anchor) async {
  switch (action) {
    case FileAction.share:
      final r = await port.share(files, anchor: anchor);
      return r.completed;
    case FileAction.openIn:
      final shown = await port.openIn(files.first, anchor: anchor);
      if (!shown && context.mounted) _toast(context, 'No app on this device opens this file');
      return shown;
    case FileAction.saveOut || FileAction.saveToPhotos:
      final photos = action == FileAction.saveToPhotos;
      final target = photos ? SaveOutTarget.photos : port.capabilities.primarySaveTarget;
      if (target == null) throw const FileOutException(FileOutError.unsupported);
      final r = await port.saveOut(files, target, anchor: anchor);
      final message = saveOutMessage(r, photos: photos);
      if (message != null && context.mounted) {
        _toast(context, message, kind: r.saved == 0 ? DanaviewToastKind.error : DanaviewToastKind.success);
      }
      return !r.cancelled && r.saved > 0;
    default:
      return false;
  }
}

Future<bool> _library(BuildContext context, WidgetRef ref, LibraryFileActions actions, FileAction action, List<MediaItem> items, List<EntryId> ids) async {
  switch (action) {
    case FileAction.rename:
      final entry = actions.liveEntry(ids.first);
      if (entry == null) throw const LibraryWriteException(LibraryWriteError.notFound);
      final input = await showDanaviewPrompt(
        context,
        title: 'Rename',
        initialValue: entry.displayName,
        confirmLabel: 'Rename',
        validator: (v) => renameProblem(entry.displayName, v),
      );
      if (input == null) return false;
      await actions.rename(entry.id, input);
      return true;
    case FileAction.copyTo || FileAction.moveTo:
      final move = action == FileAction.moveTo;
      final entries = actions.liveEntries(ids);
      final folders = {for (final e in entries) e.folderId};
      final choice = await showFolderPicker(
        context,
        actions.folderChoices(),
        title: move ? 'Move to' : 'Copy to',
        current: move && folders.length == 1 ? folders.first : null,
      );
      if (choice == null) return false;
      if (move) {
        await actions.moveTo(ids, choice.id);
      } else {
        await actions.copyTo(ids, choice.id);
      }
      if (context.mounted) {
        final what = ids.length == 1 ? '' : ' ${ids.length} files';
        _toast(context, move ? 'Moved$what to ${choice.name}' : 'Copied$what to ${choice.name}', kind: DanaviewToastKind.success);
      }
      return true;
    case FileAction.favourite:
      final on = await actions.toggleFavourites(ids);
      if (context.mounted) _toast(context, on ? 'Added to favourites' : 'Removed from favourites', icon: on ? Icons.star_rounded : Icons.star_outline_rounded);
      return true;
    case FileAction.delete:
      final usage = actions.deleteUsage(ids);
      final ok = await showDanaviewConfirm(
        context,
        title: deleteTitle(ids.length),
        message: deleteMessage(usage),
        confirmLabel: 'Delete',
        destructive: true,
        icon: Icons.delete_outline_rounded,
      );
      if (!ok) return false;
      await actions.delete(ids);
      ref.read(homeSelectionProvider.notifier).removeIds({for (final id in ids) id});
      if (context.mounted) _toast(context, ids.length == 1 ? 'Moved to Recently deleted' : 'Moved ${ids.length} files to Recently deleted');
      return true;
    default:
      return false;
  }
}
