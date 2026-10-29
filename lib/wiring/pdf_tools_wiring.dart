// OWNER: HOM-28
// EXTENDED: HOM-29 (the engine carries danaview_pdf's annotate engine; the PDF viewer's "Annotate"
// appears where the platform reports the annotate tool: PDFKit on iOS and macOS; Android once
// HOM-29A lands; never on Windows and Linux. Annotations are saved as "<name> (annotated).pdf"
// through the same result sink.)
// EXTENDED: HOM-30 (sign: where the platform reports the sign tool, the PDF viewer's "Sign" and a
// PDF's file menu "Sign…" ([signPdfHandlerProvider], which opens the viewer in sign mode) appear;
// saved signatures live app-private in `<app support>/signatures` ([signatureStoreProvider],
// excluded from backups, never in the Danaview folders); typed signatures use the OFL script fonts
// the app already bundles ([pdfSignatureFonts]); a photo of a signature comes through the system
// photo picker ([signaturePhotoPicker], its staged copy deleted at once). Signed copies are saved
// as "<name> (signed).pdf" through the same result sink.)
//
// S4 wiring of the PDF page tools (BUILD_PLAN v1.2 §1A slice S4; HOM plan §8.5), composed at the
// app root behind DANAVIEW_FILES_HOME (S4 uses the same flag; default false, never flipped in
// code). With the flag off [pdfToolsOverrides] returns nothing: no menu entry, no handler, no
// tool button. With it on, on a platform whose danaview_pdf reports the tools (PDFKit on iOS and
// macOS, HOM-28; PdfBox-Android once HOM-28A lands; nothing on Windows and Linux until 1.3.0):
//
// * the PDF viewer's top bar gets "Organise pages" and its menu "Merge with…" ([PdfToolsScope]
//   around the viewer, see `openDocumentViewer`);
// * a PDF's file menu gets "Organise pages" and "Merge with…" ([pdfPageToolsHandlerProvider]);
// * the multi-select bar's "Merge into PDF" for PDFs and photos ([mergeIntoPdfHandlerProvider]).
//
// Results are imported as new files through the one import path (next to the original, or in
// `Imported` for linked files); Replace only rewrites a Danaview folder file, through the
// library's writer. Nothing here logs a name or a path (ARCH v1.2 rule 30).

// The Files & Media Home surfaces are reached through their own entry files under lib/src/
// (INT-101 keeps the features barrel unchanged), as the S2 and S3 wiring do.
// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:danaview_documents/danaview_documents.dart';
import 'package:danaview_features/src/flags.dart';
import 'package:danaview_features/src/library/file_actions/file_actions.dart'
    show libraryFileActionsProvider, mergeIntoPdfHandlerProvider, pdfPageToolsHandlerProvider, signPdfHandlerProvider;
import 'package:danaview_features/src/library/files/library_store_providers.dart' show libraryStoreProvider;
import 'package:danaview_features/src/library/import/import_providers.dart' show importServiceProvider, importStagingDirectoryProvider;
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_library_native/danaview_library_native.dart'
    show LibraryNativeErrorCode, LibraryNativeException, NativeBackupFlags, NativePickers, PhotoPickFilter, PickedItem;
import 'package:danaview_pdf/danaview_pdf.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'documents_wiring.dart' show ProviderRead, openDocumentViewer, viewerFileOfEntry, viewerFileOfLinked;

/// Whether this build wires the S4 PDF tools (`DANAVIEW_FILES_HOME`, default false).
bool get pdfToolsWired => FeatureFlags.filesHomeEnabled;

/// The library offers at most this many PDFs and photos in the merge picker (newest first).
const int pdfMergeCandidateLimit = 2000;

/// The danaview_pdf documents and page tools of this platform.
@immutable
final class PdfToolsEngine {
  /// An engine of [documents], [tools] and [annotate].
  const PdfToolsEngine({required this.documents, required this.tools, this.annotate});

  /// Read-only documents (thumbnails, passwords).
  final PdfDocuments documents;

  /// The page tools.
  final PdfPageTools tools;

  /// Annotate mode and its save (HOM-29); the viewer shows it only where the tool is reported.
  final PdfAnnotateEngine? annotate;
}

/// The engine of this platform, or null (no PDF tools); the app root overrides it.
final pdfToolsEngineProvider = Provider<PdfToolsEngine?>((ref) => null);

/// The tools that landed on this platform (asked once; empty on failure).
final pdfToolsSupportedProvider = FutureProvider<Set<PdfTool>>((ref) async {
  final engine = ref.watch(pdfToolsEngineProvider);
  if (engine == null) return const {};
  try {
    return await engine.tools.supported();
  } on Object {
    return const {};
  }
});

/// The app-private saved signatures (HOM-30), or null where signing isn't wired.
final signatureStoreProvider = Provider<SignatureStore?>((ref) => null);

/// The photo picker of "New signature › Import" (null hides Import); the app root overrides it.
final signaturePhotoPickerProvider = Provider<SignaturePhotoPicker?>((ref) => null);

/// Typed signatures: script fonts under the SIL Open Font Licence that the app already bundles
/// (danaview_editor_fonts, `fonts/*/OFL.txt`); nothing is downloaded.
const List<SignatureFont> pdfSignatureFonts = [
  SignatureFont('Caveat', 'Caveat', package: 'danaview_editor_fonts', weight: FontWeight.w500),
  SignatureFont('Pacifico', 'Pacifico', package: 'danaview_editor_fonts'),
  SignatureFont('Playfair italic', 'Playfair Display', package: 'danaview_editor_fonts', italic: true),
];

/// The page tools' environment: needs the engine, the library and its import queue.
final pdfToolsEnvironmentProvider = Provider<PdfToolsEnvironment?>((ref) {
  final engine = ref.watch(pdfToolsEngineProvider);
  final store = ref.watch(libraryStoreProvider);
  final imports = ref.watch(importServiceProvider);
  final actions = ref.watch(libraryFileActionsProvider);
  final staging = ref.watch(importStagingDirectoryProvider);
  if (engine == null || store == null || imports == null || actions == null || staging == null) return null;
  return PdfToolsEnvironment(
    documents: engine.documents,
    tools: engine.tools,
    sink: LibraryPdfResultSink(imports: imports, actions: actions, staging: pdfToolsStagingIn(staging)),
    pickMergeInputs: (context, current) => showPdfMergePicker(context, candidates: pdfMergeCandidates(store), current: current),
    annotate: engine.annotate,
    signatures: ref.watch(signatureStoreProvider),
    signatureFonts: pdfSignatureFonts,
    pickSignaturePhoto: ref.watch(signaturePhotoPickerProvider),
  );
});

/// Picks one photo of a signature with the system photo picker (or the file picker where there is
/// no photo picker, macOS), copied into an app-owned folder under [staging], read, and deleted
/// again at once; null when cancelled. Nothing is logged (rule 30).
SignaturePhotoPicker signaturePhotoPicker(String staging, {NativePickers? pickers}) => (context) async {
      final dir = Directory('$staging${Platform.pathSeparator}signature_photo');
      await dir.create(recursive: true);
      final p = pickers ?? NativePickers();
      try {
        List<PickedItem> picked;
        try {
          picked = await p.pickPhotos(stagingDirectory: dir.path, limit: 1, filter: PhotoPickFilter.photos);
        } on LibraryNativeException catch (e) {
          if (e.code != LibraryNativeErrorCode.notSupportedOnDevice) rethrow;
          picked = await p.pickDocuments(allowMultiple: false, utis: const ['public.image'], mimeTypes: const ['image/*'], stagingDirectory: dir.path);
        }
        final path = picked.isEmpty ? null : picked.first.path;
        if (path == null) return null;
        return Uint8List.fromList(await File(path).readAsBytes());
      } finally {
        try {
          await dir.delete(recursive: true);
        } on FileSystemException {
          // Already gone.
        }
      }
    };

/// The tools' staging folder: app-owned, under the import staging folder (never backed up).
String pdfToolsStagingIn(String importStaging) => '$importStaging/pdf_tools';

/// The library's PDFs and photos for the merge picker, newest first.
List<PdfMergeItem> pdfMergeCandidates(LibraryStore store) {
  final entries = store.reader.allEntries().where((e) => e.kind == FileKind.photo || e.docKind == DocumentKind.pdf).toList()
    ..sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
  return [
    for (final e in entries.take(pdfMergeCandidateLimit))
      PdfMergeItem(
        path: store.paths.entryFile(e.id, e.displayName),
        displayName: e.displayName,
        isImage: e.kind == FileKind.photo,
        entryId: e.id,
      ),
  ];
}

/// The merge input of a selected or menu [item] (a library file at its place in the library, a
/// linked file at its own path), or null when it has no readable file.
PdfMergeItem? pdfMergeItemOf(MediaItem item, LibraryStore? store) {
  final target = FileActionTarget.of(item);
  final entry = target.entryId == null || store == null ? null : store.reader.entry(target.entryId!);
  final path = entry != null ? store!.paths.entryFile(entry.id, entry.displayName) : target.localPath;
  if (path == null) return null;
  return PdfMergeItem(path: path, displayName: entry?.displayName ?? item.name, isImage: item is PhotoMediaItem, entryId: entry?.id);
}

/// The viewer file of a PDF [item] from a file menu (a Danaview folder entry or a linked file).
ViewerFile? pdfViewerFileOf(MediaItem item, LibraryStore? store) {
  final id = EntryId.tryParse(item.id.value);
  final entry = id == null || store == null ? null : store.reader.entry(id);
  if (entry != null && !entry.isTrashed) return viewerFileOfEntry(entry, store!.paths.entryFile(entry.id, entry.displayName));
  if (item is DocumentItem) return viewerFileOfLinked(item);
  return null;
}

/// Runs a PDF's "Organise pages" or "Merge with…" from its file menu.
Future<void> runPdfFileTool(BuildContext context, ProviderRead read, FileAction action, MediaItem item) async {
  final environment = read(pdfToolsEnvironmentProvider);
  final store = read(libraryStoreProvider);
  if (environment == null) return;
  switch (action) {
    case FileAction.organisePages:
      final file = pdfViewerFileOf(item, store);
      if (file != null) await openPdfOrganiser(context, environment, file);
    case FileAction.mergeWith:
      final first = pdfMergeItemOf(item, store);
      if (first != null) await openPdfMerge(context, environment, [first], pickFirst: true);
    default:
      return;
  }
}

/// Merges the multi-select bar's PDFs and photos (in selection order) on the merge screen.
Future<void> runMergeIntoPdf(BuildContext context, ProviderRead read, List<MediaItem> items) async {
  final environment = read(pdfToolsEnvironmentProvider);
  if (environment == null) return;
  final store = read(libraryStoreProvider);
  final inputs = [
    for (final i in items)
      if (pdfMergeItemOf(i, store) case final m?) m,
  ];
  if (inputs.isEmpty) return;
  await openPdfMerge(context, environment, inputs);
}

/// Runs a PDF's "Sign…" from its file menu: the viewer opens in sign mode (HOM-30).
Future<void> runPdfSign(BuildContext context, ProviderRead read, MediaItem item) async {
  final file = pdfViewerFileOf(item, read(libraryStoreProvider));
  if (file == null || !context.mounted) return;
  await openDocumentViewer(context, read, file, startWith: PdfViewerStartTool.sign);
}

/// Wraps a document viewer with the page tools' scope when they are wired here (the PDF viewer
/// then shows "Organise pages" and "Merge with…"); [startWith] opens it in a tool at once (the file
/// menu's "Sign…", HOM-30).
Widget withPdfTools(ProviderRead read, Widget viewer, {PdfViewerStartTool? startWith}) {
  if (!pdfToolsWired) return viewer;
  final environment = read(pdfToolsEnvironmentProvider);
  if (environment == null) return viewer;
  return PdfToolsScope(environment: environment, startWith: startWith, child: viewer);
}

/// The S4 overrides of the app root: nothing with DANAVIEW_FILES_HOME off. With it on, the engine
/// of [platform] (iOS, macOS and Android have danaview_pdf; [engine] is a test seam) and the
/// handlers, each present only once its tools are reported. With [support] (the app support
/// folder) the saved signatures live in `<support>/signatures` ([signatures] is a test seam).
List<Override> pdfToolsOverrides({required TargetPlatform platform, PdfToolsEngine? engine, String? support, SignatureStore? signatures}) {
  if (!pdfToolsWired) return const [];
  final native = platform == TargetPlatform.iOS || platform == TargetPlatform.macOS || platform == TargetPlatform.android;
  final apple = platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
  final store = signatures ??
      (native && support != null
          ? FileSignatureStore.inAppSupport(
              support,
              // iCloud and device backups skip the folder (Android: HOM-30A's backup rules).
              excludeFromBackup: apple ? (path) => NativeBackupFlags().setExcludedFromBackup(path, excluded: true) : null,
            )
          : null);
  final chosen = engine ??
      (native ? PdfToolsEngine(documents: PlatformPdfDocuments(), tools: PlatformPdfPageTools(), annotate: PlatformPdfAnnotateEngine()) : null);
  return [
    if (chosen != null) pdfToolsEngineProvider.overrideWithValue(chosen),
    if (store != null) signatureStoreProvider.overrideWithValue(store),
    signaturePhotoPickerProvider.overrideWith((ref) {
      final staging = ref.watch(importStagingDirectoryProvider);
      return native && staging != null ? signaturePhotoPicker(pdfToolsStagingIn(staging)) : null;
    }),
    pdfPageToolsHandlerProvider.overrideWith((ref) {
      final tools = ref.watch(pdfToolsSupportedProvider).valueOrNull ?? const {};
      if (ref.watch(pdfToolsEnvironmentProvider) == null || !canOrganise(tools) || !tools.contains(PdfTool.merge)) return null;
      return (context, action, item) => runPdfFileTool(context, ProviderScope.containerOf(context, listen: false).read, action, item);
    }),
    signPdfHandlerProvider.overrideWith((ref) {
      final tools = ref.watch(pdfToolsSupportedProvider).valueOrNull ?? const {};
      final environment = ref.watch(pdfToolsEnvironmentProvider);
      if (environment == null || environment.annotate == null || environment.signatures == null || !tools.contains(PdfTool.sign)) return null;
      return (context, item) => runPdfSign(context, ProviderScope.containerOf(context, listen: false).read, item);
    }),
    mergeIntoPdfHandlerProvider.overrideWith((ref) {
      final tools = ref.watch(pdfToolsSupportedProvider).valueOrNull ?? const {};
      if (ref.watch(pdfToolsEnvironmentProvider) == null || !tools.contains(PdfTool.merge)) return null;
      return (context, items) => runMergeIntoPdf(context, ProviderScope.containerOf(context, listen: false).read, items);
    }),
  ];
}
