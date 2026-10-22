// OWNER: HOM-22
//
// The file actions over the library store (ARCH v1.2 V2-08, V2-117, V2-118, rule 26; HOM plan
// §8.3): rename, Copy to…, Move to…, favourites and Delete (Recently deleted, with the "Used in N
// projects" warning) go through the store's one writer (HOM-17), so every action updates
// library.db and fires `LibraryStore.changes` for the UI; File info and the folder choices read
// the read-only connection; [outFiles] gives the files to hand to a [FileOutPort] — the library
// files themselves, which the platform only reads (temporary read-only copies for share and open
// in, create-new copies for save-out). Nothing here writes a file, and nothing logs (rule 30).

import 'dart:io';

import 'package:path/path.dart' as p;

import '../classify/classifier.dart';
import '../db/library_folder.dart';
import '../model/document_item.dart';
import '../model/file_entry.dart';
import '../model/file_kind.dart';
import '../model/ids.dart';
import '../model/media_item.dart';
import '../model/source_hint.dart';
import '../organise/natural_order.dart';
import '../refs/ref_holder.dart';
import '../store/library_store.dart';
import '../store/library_writer.dart';
import 'file_action.dart';
import 'file_out.dart';

/// Everything the File info sheet shows (HOM plan §8.3: type, size, dates, page count, dimensions
/// or duration, where it came from).
final class FileInfo {
  /// Info.
  const FileInfo({
    required this.name,
    required this.kind,
    required this.typeLabel,
    required this.modifiedAt,
    required this.readOnly,
    this.sizeBytes,
    this.addedAt,
    this.lastOpenedAt,
    this.takenAt,
    this.pageCount,
    this.width,
    this.height,
    this.duration,
    this.frameRate,
    this.camera,
    this.source,
    this.folderPath = const [],
    this.isFavourite = false,
  });

  /// The file name.
  final String name;

  /// The Home kind.
  final FileKind kind;

  /// "PDF document", "HEIC photo", "MP4 video", …
  final String typeLabel;

  /// Size, when known.
  final int? sizeBytes;

  /// When it was added to Danaview (library files).
  final DateTime? addedAt;

  /// Last modified.
  final DateTime modifiedAt;

  /// Last opened in a viewer.
  final DateTime? lastOpenedAt;

  /// When the photo was taken.
  final DateTime? takenAt;

  /// Pages (documents).
  final int? pageCount;

  /// Pixel width (photos, videos).
  final int? width;

  /// Pixel height.
  final int? height;

  /// Duration (videos).
  final Duration? duration;

  /// Frames per second (videos).
  final double? frameRate;

  /// The camera (photos).
  final String? camera;

  /// Where it came from (library files).
  final SourceHint? source;

  /// The Danaview folders from the top down (library files).
  final List<String> folderPath;

  /// Starred.
  final bool isFavourite;

  /// True when Danaview can't rename, move or delete it (linked folders, system library).
  final bool readOnly;

  // Never prints names (rule 30).
  @override
  String toString() => 'FileInfo(${kind.name})';
}

/// One Danaview folder offered by Copy to… and Move to….
final class FolderChoice {
  /// A choice.
  const FolderChoice({required this.id, required this.name, required this.path, required this.depth});

  /// The folder.
  final FolderId id;

  /// Its name.
  final String name;

  /// Its names from the top down (`[Trips, 2026]`).
  final List<String> path;

  /// 0 at the top level.
  final int depth;

  /// `Trips › 2026`.
  String get label => path.join(' › ');
}

/// The words of the delete warning ("Used in 2 projects"), or null when nothing holds the files.
String? deleteWarningText(RefUsage usage) {
  if (usage.isEmpty) return null;
  String count(int n, String one) => n == 1 ? '1 $one' : '$n ${one}s';
  final parts = [
    if (usage.projects > 0) count(usage.projects, 'project'),
    if (usage.photos > 0) count(usage.photos, 'photo edit'),
  ];
  return 'Used in ${parts.join(' and ')}';
}

/// What the File info sheet calls where a file came from.
String sourceLabel(SourceHint source) => switch (source) {
      SourceHint.photos => 'Photos',
      SourceHint.files => 'Files',
      SourceHint.openWith => 'Opened with Danaview',
      SourceHint.shareExtension => 'Shared to Danaview',
      SourceHint.linkedFolder => 'A linked folder',
      SourceHint.editorExport => 'Editor export',
      SourceHint.player => 'Saved from the player',
      SourceHint.unknown => 'Unknown',
    };

/// "PDF document", "JPEG photo", "MP4 video", "File" for [name] of [kind].
String typeLabelOf(String name, FileKind kind) {
  final ext = extensionOf(name)?.toUpperCase();
  final noun = switch (kind) {
    FileKind.video => 'video',
    FileKind.photo => 'photo',
    FileKind.document => 'document',
    FileKind.audio => 'audio',
    FileKind.other => 'file',
  };
  if (ext == null || ext.isEmpty) return '${noun[0].toUpperCase()}${noun.substring(1)}';
  return '$ext $noun';
}

/// [input] as the new name of a file called [current]: trimmed, and with [current]'s extension
/// added back when the user typed none (so a photo stays a `.jpg`).
String resolvedRename(String current, String input) {
  final name = input.trim();
  if (name.isEmpty) return name;
  final ext = p.extension(current);
  if (ext.isNotEmpty && p.extension(name).isEmpty) return '$name$ext';
  return name;
}

/// Why [input] can't be the new name of [current], or null when it can.
String? renameProblem(String current, String input) {
  final name = resolvedRename(current, input);
  if (name.isEmpty) return 'Enter a name';
  if (!isValidEntryName(name)) return 'Names can’t contain / or \\';
  return null;
}

/// The file actions of one library.
final class LibraryFileActions {
  /// Actions over [store].
  LibraryFileActions(this.store);

  /// The library.
  final LibraryStore store;

  /// The live entry behind [id], or null (not a library file, trashed, gone).
  FileEntry? liveEntry(ItemId id) {
    final entry = EntryId.tryParse(id.value);
    if (entry == null) return null;
    final e = store.reader.entry(entry);
    return e == null || e.isTrashed ? null : e;
  }

  /// The live entries of [ids], in order (others skipped).
  List<FileEntry> liveEntries(Iterable<ItemId> ids) => [
        for (final id in ids)
          if (liveEntry(id) case final e?) e,
      ];

  /// The library file of entry [e].
  String pathOf(FileEntry e) => store.paths.entryFile(e.id, e.displayName);

  ({String? mime, String? uti}) _types(EntryId id) {
    final rows = store.reader.db.select('SELECT mime, uti FROM entries WHERE id = ?', [id.value]);
    if (rows.isEmpty) return (mime: null, uti: null);
    return (mime: rows.first['mime'] as String?, uti: rows.first['uti'] as String?);
  }

  /// The files of [targets] to hand out, in order: library files at their place in the library
  /// (the platform only reads them), read-only files at their local path. Targets without a
  /// readable file are skipped.
  List<OutFile> outFiles(Iterable<FileActionTarget> targets) {
    final out = <OutFile>[];
    for (final t in targets) {
      if (t.isLibraryEntry) {
        final e = liveEntry(t.item.id);
        if (e == null) continue;
        final path = pathOf(e);
        if (!File(path).existsSync()) continue;
        final types = _types(e.id);
        out.add(OutFile(path: path, displayName: e.displayName, mime: types.mime ?? _mimeOf(t.item), uti: types.uti));
      } else if (t.localPath case final path?) {
        if (!File(path).existsSync()) continue;
        out.add(OutFile(path: path, displayName: t.item.name.isEmpty ? p.basename(path) : t.item.name, mime: _mimeOf(t.item)));
      }
    }
    return out;
  }

  static String? _mimeOf(MediaItem item) => item.mimeType.isEmpty ? null : item.mimeType;

  /// Renames entry [id] to [input] (see [resolvedRename]); returns the stored name, made unique in
  /// its folder. Throws [LibraryWriteException] (`invalidName`, `trashed`, `notFound`).
  Future<String> rename(EntryId id, String input) {
    final e = store.reader.entry(id);
    final name = resolvedRename(e?.displayName ?? '', input);
    return store.write((w, now) => w.renameEntry(id, name, now: now));
  }

  /// Copies [ids] into [folder] as new entries (Copy to…), in one write; returns the copies.
  Future<List<FileEntry>> copyTo(List<EntryId> ids, FolderId folder) =>
      store.write((w, now) => [for (final id in ids) w.copyEntry(id, folder, now: now)]);

  /// Moves [ids] into [folder] (Move to…) in one transaction.
  Future<void> moveTo(List<EntryId> ids, FolderId folder) => store.write((w, now) => w.moveEntries(ids, folder, now: now));

  /// Whether every one of [ids] is a favourite.
  bool allFavourite(Iterable<EntryId> ids) {
    var any = false;
    for (final id in ids) {
      final e = liveEntry(id);
      if (e == null || !e.isFavourite) return false;
      any = true;
    }
    return any;
  }

  /// Stars [ids] or, when all of them are starred, unstars them (one write); returns the new state.
  Future<bool> toggleFavourites(List<EntryId> ids) async {
    final next = !allFavourite(ids);
    await setFavourites(ids, next);
    return next;
  }

  /// Stars or unstars [ids] in one write.
  Future<void> setFavourites(List<EntryId> ids, bool favourite) => store.write((w, _) => w.transaction(() {
        for (final id in ids) {
          w.setEntryFavourite(id, favourite);
        }
      }));

  /// What deleting [ids] would break (V2-08).
  RefUsage deleteUsage(Iterable<EntryId> ids) => store.reader.refUsage(entries: ids);

  /// Moves [ids] to Recently deleted (files stay in place until the purge, V2-08).
  Future<void> delete(List<EntryId> ids) => store.write((w, now) => w.trashEntries(ids, now: now));

  /// The live Danaview folders for Copy to… and Move to…, in path order (natural, case-blind).
  List<FolderChoice> folderChoices() {
    final folders = store.reader.allFolders();
    final byId = {for (final f in folders) f.id: f};
    List<String> pathOf(LibraryFolder f) {
      final names = <String>[];
      LibraryFolder? at = f;
      final seen = <FolderId>{};
      while (at != null && seen.add(at.id)) {
        names.insert(0, at.name);
        at = at.parentId == null ? null : byId[at.parentId];
      }
      return names;
    }

    final choices = [
      for (final f in folders) (f, pathOf(f)),
    ]..sort((a, b) {
        for (var i = 0; i < a.$2.length && i < b.$2.length; i++) {
          final c = compareNatural(a.$2[i], b.$2[i]);
          if (c != 0) return c;
        }
        return a.$2.length.compareTo(b.$2.length);
      });
    return [for (final (f, path) in choices) FolderChoice(id: f.id, name: f.name, path: path, depth: path.length - 1)];
  }

  /// File info for [item]: from library.db for a library file, from the item otherwise.
  FileInfo info(MediaItem item) {
    final e = liveEntry(item.id);
    if (e == null) return itemInfo(item);
    final meta = store.reader.meta(e.id);
    final folders = store.reader.pathOf(e.folderId);
    return FileInfo(
      name: e.displayName,
      kind: e.kind,
      typeLabel: typeLabelOf(e.displayName, e.kind),
      sizeBytes: e.sizeBytes,
      addedAt: e.addedAt,
      modifiedAt: e.modifiedAt,
      lastOpenedAt: e.lastOpenedAt,
      takenAt: meta?.takenAt,
      pageCount: meta?.pageCount,
      width: meta?.width,
      height: meta?.height,
      duration: meta?.duration,
      frameRate: meta?.fps,
      camera: meta?.camera,
      source: e.sourceHint,
      folderPath: [for (final f in folders) f.name],
      isFavourite: e.isFavourite,
      readOnly: false,
    );
  }

  /// File info of [item] from its own fields (read-only items, or no library store).
  static FileInfo itemInfo(MediaItem item) {
    final kind = item.kind;
    return switch (item) {
      PhotoMediaItem() => FileInfo(
          name: item.name,
          kind: kind,
          typeLabel: typeLabelOf(item.name, kind),
          sizeBytes: item.sizeBytes,
          modifiedAt: item.modifiedAt,
          takenAt: item.takenAt,
          width: item.width,
          height: item.height,
          camera: item.cameraModel,
          readOnly: true,
        ),
      VideoMediaItem() => FileInfo(
          name: item.name,
          kind: kind,
          typeLabel: typeLabelOf(item.name, kind),
          sizeBytes: item.sizeBytes,
          modifiedAt: item.modifiedAt,
          width: item.width,
          height: item.height,
          duration: item.duration,
          frameRate: item.frameRate > 0 ? item.frameRate : null,
          readOnly: true,
        ),
      DocumentMediaItem() => FileInfo(
          name: item.name,
          kind: kind,
          typeLabel: typeLabelOf(item.name, kind),
          sizeBytes: item.sizeBytes,
          modifiedAt: item.modifiedAt,
          pageCount: item is DocumentItem ? item.pageCount : null,
          readOnly: true,
        ),
    };
  }
}
