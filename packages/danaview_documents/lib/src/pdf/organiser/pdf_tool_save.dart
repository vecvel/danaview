// OWNER: HOM-28
//
// Where the results of the PDF page tools go (HOM plan §8.5, G-H6, ARCH v1.2 §9.3 and rule 27):
// a tool writes into an app-owned staging folder, then the result is imported into the library as
// a NEW file next to the original (its Danaview folder; linked and incoming files go to
// `Imported`), named `Report (edited).pdf`, `Report (pages 1–3).pdf`, `Report (merged).pdf`. The
// original is never modified. "Replace" exists only for a file in a Danaview folder: the finished
// file is renamed over the entry's file through the library's writer (same id, name, folder,
// favourite and references), and only after it was written in full. Nothing here logs a name or
// a path (rule 30).

import 'dart:async';
import 'dart:io';

import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:flutter/foundation.dart';

import '../../router/viewer_file.dart';

/// How a tool's single result is saved.
enum PdfSaveMode {
  /// A new file next to the original (always available).
  newFile,

  /// Over the original (Danaview folder files only, [canReplacePdf]).
  replace,
}

/// A saved result.
@immutable
final class PdfSavedFile {
  /// A file named [displayName]; [entryId] is its library entry.
  const PdfSavedFile({required this.displayName, this.entryId, this.path, this.replaced = false});

  /// The name it got (deduplicated in its folder).
  final String displayName;

  /// The library entry, when it is one.
  final EntryId? entryId;

  /// Its file, when known.
  final String? path;

  /// True when it replaced the original.
  final bool replaced;

  // Never prints the name or the path (rule 30).
  @override
  String toString() => 'PdfSavedFile(${replaced ? 'replaced' : 'new'})';
}

/// Takes the files the tools wrote and puts them into the library. Implementations:
/// [LibraryPdfResultSink]; tests fake it.
abstract interface class PdfResultSink {
  /// An app-owned folder for the tools' outputs (created when missing).
  Future<String> stagingDirectory();

  /// Imports [paths] as new files named [names] (same order) into the folder of [besideEntry],
  /// or `Imported` when it is null or gone. The staged files are removed afterwards.
  Future<List<PdfSavedFile>> saveNew(List<String> paths, List<String> names, {EntryId? besideEntry});

  /// Replaces the file of the Danaview folder entry [entry] with [path] (fully written), then
  /// removes [path]. [pageCount] updates the entry's facts.
  Future<PdfSavedFile> replace(EntryId entry, String path, {int? pageCount});
}

/// Thrown by a [PdfResultSink] that couldn't save (no library, a failed import).
final class PdfSaveException implements Exception {
  /// A failure; [message] is debug text without names or paths.
  const PdfSaveException(this.message);

  /// What went wrong.
  final String message;

  @override
  String toString() => 'PdfSaveException($message)';
}

/// Whether "Replace" is offered for [file]: only for a Danaview folder file (a `fe_` entry), never
/// for linked-folder or incoming files (they are read-only, G-H6).
bool canReplacePdf(ViewerFile file) => file.entryId != null;

/// A fresh, unused output path in [dir] for [name] (never an existing file).
String stagingPathFor(String dir, String name) {
  final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_');
  final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  for (var n = 0;; n++) {
    final candidate = '$dir${Platform.pathSeparator}pt_${stamp}_$n-$safe';
    if (!File(candidate).existsSync()) return candidate;
  }
}

// -----------------------------------------------------------------------------------------------
// Names (HOM plan §8.5: "Report (edited).pdf").

String _base(String name) {
  final dot = name.lastIndexOf('.');
  final base = dot > 0 ? name.substring(0, dot) : name;
  return base.trim().isEmpty ? 'Document' : base.trim();
}

/// The name of an organised copy of [name]: `Report (edited).pdf`.
String editedPdfName(String name) => '${_base(name)} (edited).pdf';

/// The name of the part of [name] holding [range]: `Report (pages 1–3).pdf`, `Report (page 4).pdf`.
String splitPdfName(String name, PdfPageRange range) =>
    '${_base(name)} (${range.length == 1 ? 'page' : 'pages'} ${range.label}).pdf';

/// The name of the pages [pages] (0-based) of [name] extracted into one file: consecutive pages
/// grouped (`Report (pages 1–3, 5).pdf`), or `Report (extract).pdf` when the list is long.
String extractPdfName(String name, List<int> pages) {
  final sorted = pages.toSet().toList()..sort();
  final ranges = <PdfPageRange>[];
  for (final p in sorted) {
    if (ranges.isNotEmpty && ranges.last.end == p) {
      ranges[ranges.length - 1] = PdfPageRange(ranges.last.start, p + 1);
    } else {
      ranges.add(PdfPageRange(p, p + 1));
    }
  }
  if (ranges.isEmpty || ranges.length > 4) return '${_base(name)} (extract).pdf';
  final single = ranges.length == 1 && ranges.single.length == 1;
  return '${_base(name)} (${single ? 'page' : 'pages'} ${formatPageRanges(ranges)}).pdf';
}

/// The name of a merge whose first input is [firstName]: `Report (merged).pdf`.
String mergedPdfName(String firstName) => '${_base(firstName)} (merged).pdf';

// -----------------------------------------------------------------------------------------------
// The library sink.

/// [PdfResultSink] over the library: new files through [imports] (the one import path, HOM-20),
/// Replace through [actions] (`LibraryFileActions.replaceFile`, one rename over the old file).
final class LibraryPdfResultSink implements PdfResultSink {
  /// A sink staging under [staging].
  LibraryPdfResultSink({required this.imports, required this.actions, required String staging}) : _staging = staging;

  /// The import queue.
  final ImportService imports;

  /// The library's file actions.
  final LibraryFileActions actions;

  final String _staging;

  @override
  Future<String> stagingDirectory() async {
    await Directory(_staging).create(recursive: true);
    return _staging;
  }

  @override
  Future<List<PdfSavedFile>> saveNew(List<String> paths, List<String> names, {EntryId? besideEntry}) async {
    if (paths.length != names.length) throw ArgumentError('one name per file');
    final folder = besideEntry == null ? null : actions.liveEntry(besideEntry)?.folderId;
    final items = await imports.importAll(
      [
        for (var i = 0; i < paths.length; i++)
          ImportSource.file(paths[i], displayName: names[i], mime: 'application/pdf', uti: 'com.adobe.pdf', stagedCopy: true),
      ],
      target: folder,
      duplicates: DuplicatePolicy.keepBoth,
    );
    final out = <PdfSavedFile>[];
    for (final item in items) {
      final entry = item.entry;
      if (item.state != ImportItemState.done || entry == null) {
        // Leave nothing behind for the items that didn't make it.
        for (final p in paths) {
          _deleteQuietly(p);
        }
        throw const PdfSaveException('import failed');
      }
      out.add(PdfSavedFile(displayName: entry.displayName, entryId: entry.id, path: actions.pathOf(entry)));
    }
    return out;
  }

  @override
  Future<PdfSavedFile> replace(EntryId entry, String path, {int? pageCount}) async {
    try {
      final e = await actions.replaceFile(entry, path, pageCount: pageCount);
      return PdfSavedFile(displayName: e.displayName, entryId: e.id, path: actions.pathOf(e), replaced: true);
    } finally {
      _deleteQuietly(path);
    }
  }

  static void _deleteQuietly(String path) {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } on FileSystemException {
      // A staged file left behind is app-owned and cleared with the staging folder.
    }
  }
}
