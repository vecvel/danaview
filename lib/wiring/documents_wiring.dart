// OWNER: S3-W
// EXTENDED: HOM-21A (Android Open with / Share to Danaview: the NativeIncoming batches are
// imported by IncomingIntentImporter and shown by the same opener and toasts as HOM-21's paths.)
//
// S3 wiring (BUILD_PLAN v1.2 §1A, slice S3 "Documents: view and share-in"; the slice's share of
// INT-103): the Documents tab, the viewers and Open with / the iOS Share Extension, composed at the
// app root behind DANAVIEW_FILES_HOME (default false, never flipped in code). With the flag off
// nothing here runs: [documentsOverrides] returns no override and [installIncomingDocumentOpen]
// leaves the 1.1 incoming-media path untouched.
//
// With the flag on:
//
// * the Home shows the Documents filter and tab (HOM-18) over the Danaview folder documents and
//   the documents of the user's linked folders ([linkedDocumentsProvider], a bounded background
//   walk of the 1.1 linked roots, read-only);
// * opening a document or other file goes through HOM-23's viewer router ([DocumentViewer]) with
//   the native viewers registered for this platform: PDFKit (iOS, macOS; HOM-24) or `PdfRenderer`
//   (Android; HOM-25) behind their probes, and Quick Look with editing disabled (iOS, macOS;
//   HOM-26). Text and CSV fall back to the in-app viewers, everything else to the file card;
// * Open with Danaview (HOM-21): incoming photos and documents are imported into `Imported` and
//   opened in their viewer; videos, streams and `danaview://` links keep the 1.1 play path (P-7);
// * Android Open with / Share to Danaview (HOM-21A, INT-104): the plugin's incoming batches are
//   imported into `Imported`; a VIEW opens its entry, a share shows the Share Extension's toast;
// * the iOS Share Extension inbox (HOM-21, INT-104): the App Group port, its change events and an
//   app-owned staging folder; the importer runs on start, on every foreground and when the
//   extension finishes a batch, and keeps the folder-list snapshot the extension's picker reads.
//
// Nothing here logs a name, a path or document text (ARCH v1.2 rule 30).

// The Files & Media Home surfaces are reached through their own entry files under lib/src/
// (INT-101 keeps the features barrel unchanged), as the S2 wiring does.
// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:danaview_documents/danaview_documents.dart';
import 'package:danaview_domain/danaview_domain.dart' as domain show LibraryFolder;
import 'package:danaview_features/danaview_features.dart';
import 'package:danaview_features/src/flags.dart';
import 'package:danaview_features/src/library/file_actions/file_actions.dart' show fileOutPortProvider;
import 'package:danaview_features/src/library/filters/filter_providers.dart' show linkedDocumentsProvider;
import 'package:danaview_features/src/library/import/import_providers.dart';
import 'package:danaview_features/src/library/import/incoming_intents.dart';
import 'package:danaview_features/src/library/organise/organise_providers.dart' show recordLibraryOpenProvider;
import 'package:danaview_features/src/player/danaview_player_actions.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_library_native/danaview_library_native.dart' show IncomingAction, NativeBackupFlags, NativeInbox;
import 'package:danaview_pdf/danaview_pdf.dart' show PdfDocuments, PlatformPdfDocuments;
import 'package:danaview_platform/danaview_platform.dart' show IncomingMediaBridge;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether this build wires the S3 documents features (`DANAVIEW_FILES_HOME`, default false).
bool get documentsWired => FeatureFlags.filesHomeEnabled;

/// S3 shows the Documents filter and tab that S2 kept hidden (HOM-18's `documentsFilterShown`
/// stays the package default; the app root passes this to `libraryFilterTabSlots`).
const bool s3DocumentsShown = true;

// ---------------------------------------------------------------------------------------------
// The viewers.
// ---------------------------------------------------------------------------------------------

/// The native viewers registered with HOM-23's [DocumentViewer] and their router probes.
@immutable
final class DocumentViewerSetup {
  /// A setup of [viewers] behind [probes].
  const DocumentViewerSetup({this.viewers = const {}, this.probes = const AcceptAllProbes()});

  /// No native viewer: text and CSV in app, everything else on the file card.
  static const DocumentViewerSetup builtInOnly = DocumentViewerSetup();

  /// The registered (non built-in) viewers.
  final Map<ViewerKind, ViewerBuilder> viewers;

  /// Their capability probes.
  final ViewerProbes probes;
}

/// The viewers of [platform] (ARCH v1.2 §3): PDF on iOS, macOS and Android, Quick Look on iOS and
/// macOS; Windows and Linux have only the built-in viewers. [pdf] and [quickLook] are test seams.
DocumentViewerSetup documentViewerSetupFor(TargetPlatform platform, {PdfDocuments? pdf, QuickLookPort? quickLook}) {
  final apple = platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
  final android = platform == TargetPlatform.android;
  final pdfDocs = apple || android ? (pdf ?? PlatformPdfDocuments()) : null;
  final ql = apple ? (quickLook ?? NativeQuickLookPort()) : null;
  return DocumentViewerSetup(
    viewers: {
      if (pdfDocs != null) ViewerKind.pdf: pdfViewerBuilder(pdfDocs),
      if (ql != null) ViewerKind.quickLook: quickLookViewerBuilder(ql),
    },
    probes: FunctionProbes({
      if (pdfDocs != null) ViewerKind.pdf: pdfViewerProbe(pdfDocs),
      if (ql != null) ViewerKind.quickLook: quickLookProbe(ql),
    }),
  );
}

/// The viewers the Home opens files with; the app root overrides it per platform.
final documentViewerSetupProvider = Provider<DocumentViewerSetup>((ref) => DocumentViewerSetup.builtInOnly);

/// The MIME type and UTType the classifier knows for [name] (for Quick Look and sharing).
({String? mime, String? uti}) documentTypeOf(String name) {
  final row = classify(fileName: name).row;
  return (mime: row.mimes.isEmpty ? null : row.mimes.first, uti: row.utis.isEmpty ? null : row.utis.first);
}

/// The viewer file of a Danaview folder [entry] whose file is at [path].
ViewerFile viewerFileOfEntry(FileEntry entry, String path) {
  final type = documentTypeOf(entry.displayName);
  return ViewerFile.fromEntry(entry, path, mime: type.mime, uti: type.uti);
}

/// The viewer file of a linked-folder [document] (read-only; never recorded in Recents).
ViewerFile viewerFileOfLinked(DocumentItem document) {
  final file = ViewerFile.fromItem(document);
  if (file.uti != null) return file;
  final type = documentTypeOf(document.name);
  return ViewerFile(
    path: file.path,
    displayName: file.displayName,
    kind: file.kind,
    docKind: file.docKind,
    id: file.id,
    sizeBytes: file.sizeBytes,
    modifiedAt: file.modifiedAt,
    mime: file.mime ?? type.mime,
    uti: type.uti,
    pageCount: file.pageCount,
    textEncoding: file.textEncoding,
  );
}

/// Reads a provider (a [WidgetRef] or a [ProviderContainer]).
typedef ProviderRead = T Function<T>(ProviderListenable<T> provider);

/// Opens [file] full screen in the viewer the router picks (HOM-23), with this build's native
/// viewers, the file-out port and Recents (Danaview folder entries only).
Future<void> openDocumentViewer(BuildContext context, ProviderRead read, ViewerFile file) {
  final setup = read(documentViewerSetupProvider);
  final fileOut = read(fileOutPortProvider);
  final record = read(recordLibraryOpenProvider);
  final disable = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  return Navigator.of(context).push<void>(PageRouteBuilder<void>(
    opaque: true,
    settings: const RouteSettings(name: 'document-viewer'),
    transitionDuration: disable ? Duration.zero : DanaviewMotion.normal,
    reverseTransitionDuration: disable ? Duration.zero : DanaviewMotion.fast,
    pageBuilder: (context, _, __) => DocumentViewer(
      key: const ValueKey('s3-document-viewer'),
      file: file,
      viewers: setup.viewers,
      probes: setup.probes,
      fileOut: fileOut,
      onOpened: record,
      onClose: () => unawaited(Navigator.of(context).maybePop()),
    ),
    transitionsBuilder: (context, animation, _, child) => FadeTransition(opacity: animation, child: child),
  ));
}

// ---------------------------------------------------------------------------------------------
// Documents in linked folders (read-only, HOM plan §8.1).
// ---------------------------------------------------------------------------------------------

/// The walk of the linked folders lists at most this many folders.
const int linkedDocumentFolderBudget = 2000;

/// The walk keeps at most this many documents.
const int linkedDocumentBudget = 5000;

/// The walk goes at most this deep below a linked root.
const int linkedDocumentDepth = 8;

/// Lists the documents under linked roots; the default walks them in a background isolate.
typedef LinkedDocumentWalker = Future<List<DocumentItem>> Function(List<domain.LibraryFolder> roots);

/// How the Documents tab finds the documents of the linked folders (tests override it).
final linkedDocumentWalkerProvider = Provider<LinkedDocumentWalker>(
  (ref) => (roots) {
    final paths = [for (final r in roots) r.path];
    return Isolate.run(() => walkLinkedDocuments(paths));
  },
);

/// The documents of the linked roots, re-walked when the roots change.
final linkedDocumentScanProvider = FutureProvider<List<DocumentItem>>((ref) async {
  final roots = ref.watch(libraryControllerProvider.select((s) => s.roots));
  if (roots.isEmpty) return const [];
  try {
    return await ref.watch(linkedDocumentWalkerProvider)(roots);
  } on Object {
    return const [];
  }
});

/// A stable linked-root token of [rootPath] (64-bit FNV-1a, hex): the root id part of a
/// `lk:` id ([LinkedItemId]).
String linkedRootToken(String rootPath) {
  var hash = BigInt.parse('cbf29ce484222325', radix: 16);
  final prime = BigInt.parse('100000001b3', radix: 16);
  final mask = (BigInt.one << 64) - BigInt.one;
  for (final unit in rootPath.codeUnits) {
    hash = ((hash ^ BigInt.from(unit)) * prime) & mask;
  }
  return 'r${hash.toRadixString(16).padLeft(16, '0')}';
}

bool _hidden(String name) => name.startsWith('.') || name.startsWith(r'$') || name == 'Thumbs.db' || name == 'desktop.ini';

/// Every document under [rootPaths], breadth first, within the budgets: classified by name
/// (HOM-16), never opened, hidden entries and the copies iOS makes for "Open in" skipped. Never
/// throws; unreadable folders are passed over. Runs anywhere (no Flutter bindings).
Future<List<DocumentItem>> walkLinkedDocuments(List<String> rootPaths) async {
  final out = <DocumentItem>[];
  final seenFiles = <String>{};
  for (final rootPath in rootPaths) {
    if (out.length >= linkedDocumentBudget) break;
    final token = linkedRootToken(rootPath);
    final queue = <(String path, int depth)>[(rootPath, 0)];
    var listed = 0;
    for (var i = 0; i < queue.length && listed < linkedDocumentFolderBudget && out.length < linkedDocumentBudget; i++) {
      final (dirPath, depth) = queue[i];
      final List<FileSystemEntity> children;
      try {
        children = await Directory(dirPath).list(followLinks: false).toList();
      } on Object {
        continue;
      }
      listed++;
      for (final child in children) {
        if (out.length >= linkedDocumentBudget) break;
        final name = child.uri.pathSegments.lastWhere((s) => s.isNotEmpty, orElse: () => '');
        if (name.isEmpty || _hidden(name)) continue;
        if (child is Directory) {
          if (depth + 1 <= linkedDocumentDepth) queue.add((child.path, depth + 1));
          continue;
        }
        if (child is! File || isSystemOpenInCopy(child.path) || !seenFiles.add(child.path)) continue;
        final cls = classify(fileName: name);
        if (cls.kind != FileKind.document) continue;
        FileStat stat;
        try {
          stat = await child.stat();
        } on Object {
          continue;
        }
        final relative = child.path.substring(rootPath.length).replaceAll(r'\', '/').replaceFirst(RegExp('^/+'), '');
        ItemId id;
        try {
          id = LinkedItemId.of(token, relative);
        } on Object {
          id = ItemId.opaque('lk:$token/${relative.hashCode}');
        }
        out.add(DocumentItem(
          id: id,
          uri: child.path,
          name: name,
          modifiedAt: stat.modified.toUtc(),
          mimeType: cls.row.mimes.isEmpty ? 'application/octet-stream' : cls.row.mimes.first,
          sizeBytes: stat.size,
          docKind: cls.docKind ?? DocumentKind.other,
        ));
      }
    }
  }
  out.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
  return out;
}

// ---------------------------------------------------------------------------------------------
// Start-up overrides.
// ---------------------------------------------------------------------------------------------

/// Where Share Extension files wait for their import: app-owned, under the support directory
/// (not the cache, which the system may purge while a staged file waits), never backed up.
String inboxStagingIn(String support) => '$support${Platform.pathSeparator}DanaviewInboxStaging';

/// The S3 overrides of the app root: nothing with DANAVIEW_FILES_HOME off.
///
/// With the flag on: the viewers of [platform], the linked-document scan, and on iOS the Share
/// Extension inbox ([inbox] is a test seam) with its staging folder under [support]; on Android
/// the incoming intents ([incoming] is a test seam).
List<Override> documentsOverrides({
  required TargetPlatform platform,
  required String support,
  DocumentViewerSetup? viewers,
  NativeInbox? inbox,
  IncomingIntentPort? incoming,
  bool excludeStagingFromBackup = true,
}) {
  if (!documentsWired) return const [];
  final ios = platform == TargetPlatform.iOS;
  final staging = inboxStagingIn(support);
  final appGroup = ios ? (inbox ?? NativeInbox()) : null;
  if (appGroup != null && excludeStagingFromBackup) unawaited(_prepareStaging(staging));
  return [
    documentViewerSetupProvider.overrideWithValue(viewers ?? documentViewerSetupFor(platform)),
    linkedDocumentsProvider.overrideWith((ref) => ref.watch(linkedDocumentScanProvider).valueOrNull ?? const <DocumentItem>[]),
    if (appGroup != null) ...[
      inboxPortProvider.overrideWithValue(NativeInboxPort(appGroup)),
      inboxChangesProvider.overrideWithValue(appGroup.changes),
      inboxStagingDirectoryProvider.overrideWithValue(staging),
    ],
    // The plugin's port only on a real Android host (widget tests run as Android on the desktop VM).
    if (platform == TargetPlatform.android && (incoming != null || Platform.isAndroid))
      incomingIntentPortProvider.overrideWithValue(incoming ?? NativeIncomingPort()),
  ];
}

Future<void> _prepareStaging(String staging) async {
  try {
    await Directory(staging).create(recursive: true);
    await NativeBackupFlags().setExcludedFromBackup(staging, excluded: true);
  } on Object {
    // The importer creates the folder itself; a missing backup flag only costs backup space.
  }
}

// ---------------------------------------------------------------------------------------------
// Open with Danaview and the Share Extension inbox at run time.
// ---------------------------------------------------------------------------------------------

/// Opens a Danaview folder entry that arrived from another app (Open with, HOM-21): see
/// `openLibraryEntryWith` in files_home_wiring.dart. Set by [installIncomingDocumentOpen].
typedef IncomingEntryOpener = Future<void> Function(BuildContext context, ProviderRead read, FileEntry entry);

/// Installs HOM-21's interceptor on [IncomingMediaBridge] (flag on only): photos and documents
/// another app opens with Danaview are imported into `Imported` and shown by [openEntry] on the
/// root navigator of [navigator]; everything else plays as in 1.1. Returns whether it installed.
bool installIncomingDocumentOpen(GlobalKey<NavigatorState> navigator, {required IncomingEntryOpener openEntry}) {
  if (!documentsWired) return false;
  BuildContext? context() => navigator.currentContext;
  ProviderContainer? container() {
    final c = context();
    return c == null ? null : ProviderScope.containerOf(c, listen: false);
  }

  void open(FileEntry entry) {
    final c = context();
    final scope = container();
    if (c == null || scope == null) return;
    unawaited(openEntry(c, scope.read, entry));
  }

  _incomingOpen = open;
  IncomingMediaBridge.interceptor = incomingDocumentInterceptor(
    imports: () => container()?.read(importServiceProvider),
    openEntry: open,
    onFailed: () {
      final c = context();
      if (c != null && c.mounted) {
        DanaviewToast.show(c, "Couldn't open this file.", kind: DanaviewToastKind.error, icon: Icons.error_outline_rounded);
      }
    },
  );
  return true;
}

/// Opens an entry Android's Open with imported (HOM-21A); set by [installIncomingDocumentOpen].
void Function(FileEntry entry)? _incomingOpen;

/// Starts the Share Extension inbox import (iOS with the flag on) and the Android incoming-intent
/// import (HOM-21A; Android with the flag on) and shows a toast after a run that saved or failed
/// something; an Android Open with opens its entry. Wraps the Home, which stays mounted under
/// every route.
class InboxImportHost extends ConsumerStatefulWidget {
  /// The host around [child].
  const InboxImportHost({super.key, required this.child});

  /// The Home.
  final Widget child;

  @override
  ConsumerState<InboxImportHost> createState() => _InboxImportHostState();
}

class _InboxImportHostState extends ConsumerState<InboxImportHost> {
  StreamSubscription<InboxRunResult>? _results;
  StreamSubscription<IncomingIntentResult>? _incoming;

  @override
  void initState() {
    super.initState();
    final auto = ref.read(inboxAutoImportProvider);
    _results = auto?.results.listen(_toast);
    _incoming = ref.read(incomingIntentImportProvider)?.results.listen((result) {
      if (result.action == IncomingAction.view) {
        final entry = result.toOpen;
        final open = _incomingOpen;
        if (entry != null && open != null) {
          open(entry);
        } else if (mounted) {
          DanaviewToast.show(context, "Couldn't open this file.", kind: DanaviewToastKind.error, icon: Icons.error_outline_rounded);
        }
        return;
      }
      _toast(result.asInboxResult);
    });
  }

  void _toast(InboxRunResult result) {
    final message = inboxResultMessage(result);
    if (message == null || !mounted) return;
    DanaviewToast.show(
      context,
      message,
      kind: result.failed > 0 ? DanaviewToastKind.error : DanaviewToastKind.success,
    );
  }

  @override
  void dispose() {
    unawaited(_results?.cancel());
    unawaited(_incoming?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

