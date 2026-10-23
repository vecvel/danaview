// OWNER: HOM-21A
//
// The Dart consumer of Android incoming intents (ARCH v1.2 §5.6, INT-104, BUILD_PLAN HOM-21A):
// "Open with Danaview" (ACTION_VIEW of a document, text or photo) and "Share to Danaview"
// (ACTION_SEND, ACTION_SEND_MULTIPLE) arrive from the plugin as [IncomingBatch]es of platform URIs
// (NativeIncoming). Each item is imported through the normal import queue as a
// [ImportSourceKind.nativeUri] source (NativeImportCopier: the plugin's streamed copy, while the
// Activity holds the sender's read grant) into `Imported`; the batch is then acknowledged, which
// releases what the plugin kept (a persisted grant, a text share's file).
//
// * VIEW: the copy is `sourceHint = openWith`; a file whose content is already in the library is
//   not copied again (the entry there is opened), as HOM-21's Open with does on Apple.
// * SEND / SEND_MULTIPLE: `sourceHint = shareExtension`, both copies kept, as the iOS Share
//   Extension inbox does (nobody may be looking when the share lands).
//
// Videos opened from another app (VIEW, a single SEND) never become batches: they keep the 1.1 path
// through IncomingMediaBridge and play (P-7). Apple and desktop have no incoming intents (the
// port answers notSupportedOnDevice; nothing runs). Nothing here logs a name or a URI (rule 30).

import 'dart:async';

import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_library_native/danaview_library_native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'import_providers.dart';

/// The incoming-intent surface the importer needs (NativeIncoming; tests fake it).
abstract interface class IncomingIntentPort {
  /// Each batch once (warm intents and those [takePending] returns).
  Stream<IncomingBatch> get batches;

  /// Asks for batches received before Dart listened; they arrive on [batches].
  Future<void> takePending();

  /// Releases what batch [batchId] held.
  Future<void> acknowledge(String batchId);
}

/// [IncomingIntentPort] over the plugin's [NativeIncoming].
final class NativeIncomingPort implements IncomingIntentPort {
  /// A port over [incoming] (the default engine's when null).
  NativeIncomingPort([NativeIncoming? incoming]) : incoming = incoming ?? NativeIncoming();

  /// The plugin wrapper.
  final NativeIncoming incoming;

  @override
  Stream<IncomingBatch> get batches => incoming.batches;

  @override
  Future<void> takePending() => incoming.takePending();

  @override
  Future<void> acknowledge(String batchId) => incoming.acknowledge(batchId);
}

/// The name an incoming [item] is imported as: the provider's, else the URI's last segment, else
/// "Shared file".
String incomingItemName(IncomingItem item) {
  final given = item.displayName?.trim();
  if (given != null && given.isNotEmpty) return given;
  try {
    final segments = Uri.parse(item.uri).pathSegments.where((s) => s.isNotEmpty);
    if (segments.isNotEmpty) {
      final last = segments.last;
      if (last.isNotEmpty && last != '.' && last != '..') return last;
    }
  } on FormatException {
    // Fall through.
  }
  return 'Shared file';
}

/// The import source of [item] of a batch of [action]. The plugin keeps (and releases on
/// acknowledge) any grant, so the import releases none.
ImportSource incomingImportSource(IncomingItem item, IncomingAction action) => ImportSource(
      kind: ImportSourceKind.nativeUri,
      location: item.uri,
      displayName: incomingItemName(item),
      mime: item.mimeType,
      sizeBytes: item.sizeBytes,
      sourceHint: action == IncomingAction.view ? SourceHint.openWith : SourceHint.shareExtension,
    );

/// What the import of one [IncomingBatch] did.
@immutable
final class IncomingIntentResult {
  /// A result.
  const IncomingIntentResult({required this.action, this.imported = const [], this.existing = const [], this.skipped = 0, this.failed = 0});

  /// The intent.
  final IncomingAction action;

  /// The entries added, in the sender's order.
  final List<FileEntry> imported;

  /// VIEW only: entries already in the library with the same content (opened instead of a copy).
  final List<FileEntry> existing;

  /// Items not copied because the same content is in the library.
  final int skipped;

  /// Items that could not be imported.
  final int failed;

  /// The entry a VIEW opens (the new copy, or the one already in the library), else null.
  FileEntry? get toOpen => action != IncomingAction.view ? null : (imported.isNotEmpty ? imported.first : (existing.isNotEmpty ? existing.first : null));

  /// The same counts as a Share Extension run (for its toast text).
  InboxRunResult get asInboxResult => InboxRunResult(batches: 1, imported: imported, skipped: skipped, failed: failed);

  @override
  String toString() => 'IncomingIntentResult(${action.name}, imported: ${imported.length}, existing: ${existing.length}, skipped: $skipped, failed: $failed)';
}

/// Imports Android incoming batches through an [ImportService].
final class IncomingIntentImporter {
  /// An importer of [port]'s batches into `Imported` with [imports].
  IncomingIntentImporter({required this.port, required this.imports});

  /// The plugin surface.
  final IncomingIntentPort port;

  /// The import queue.
  final ImportService imports;

  final StreamController<IncomingIntentResult> _results = StreamController<IncomingIntentResult>.broadcast();
  StreamSubscription<IncomingBatch>? _subscription;
  AppLifecycleListener? _lifecycle;
  Future<void> _chain = Future<void>.value();
  bool _started = false;
  bool _disposed = false;

  /// One result per handled batch (VIEW: open [IncomingIntentResult.toOpen]; shares: a toast).
  Stream<IncomingIntentResult> get results => _results.stream;

  /// Listens to batches, takes the pending ones now and on every return to the foreground.
  /// Idempotent. [observeLifecycle] is false in tests without a binding.
  void start({bool observeLifecycle = true}) {
    if (_started) return;
    _started = true;
    // A platform without the native incoming channel (desktop, tests) errors the stream with a
    // MissingPluginException: nothing arrives there, so the error is dropped, not thrown.
    _subscription = port.batches.listen(
      (batch) => _chain = _chain.then((_) => _handleQuietly(batch)),
      onError: (Object _) {},
    );
    if (observeLifecycle) _lifecycle = AppLifecycleListener(onResume: () => unawaited(takePending()));
    unawaited(takePending());
  }

  /// Asks the plugin for batches that arrived while nothing listened (never throws).
  Future<void> takePending() async {
    try {
      await port.takePending();
    } on Object {
      // Not Android, or the engine is going away: nothing pending here.
    }
  }

  Future<void> _handleQuietly(IncomingBatch batch) async {
    try {
      final result = await handle(batch);
      if (result != null && !_results.isClosed) _results.add(result);
    } on Object {
      // A batch that failed as a whole stays pending in the plugin until its 24 h sweep.
    }
  }

  /// Imports every item of [batch], then acknowledges it. Null when the import service is gone
  /// (the batch is not acknowledged; the plugin sweeps it after 24 h).
  Future<IncomingIntentResult?> handle(IncomingBatch batch) async {
    if (_disposed) return null;
    final duplicates = batch.action == IncomingAction.view ? DuplicatePolicy.skip : DuplicatePolicy.keepBoth;
    final ids = <String>[];
    for (final item in batch.items) {
      try {
        ids.add(imports.enqueue(incomingImportSource(item, batch.action), duplicates: duplicates));
      } on StateError {
        return null; // disposed
      }
    }
    final imported = <FileEntry>[];
    final existing = <FileEntry>[];
    var skipped = 0, failed = 0;
    for (final id in ids) {
      final ImportItem item;
      try {
        item = await imports.result(id);
      } on Object {
        failed++;
        continue;
      }
      switch (item.state) {
        case ImportItemState.done when item.entry != null:
          imported.add(item.entry!);
        case ImportItemState.skipped:
          skipped++;
          if (item.duplicateOf case final dup?) existing.add(dup);
        case _:
          failed++;
      }
    }
    try {
      await port.acknowledge(batch.batchId);
    } on Object {
      // Released by the plugin's 24 h sweep.
    }
    return IncomingIntentResult(action: batch.action, imported: imported, existing: existing, skipped: skipped, failed: failed);
  }

  /// Stops listening.
  void dispose() {
    _disposed = true;
    _lifecycle?.dispose();
    _lifecycle = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(_results.close());
  }
}

/// The Android incoming-intent port; the app root overrides it with [NativeIncomingPort] on
/// Android behind DANAVIEW_FILES_HOME (null: no incoming intents).
final incomingIntentPortProvider = Provider<IncomingIntentPort?>((ref) => null);

/// The started [IncomingIntentImporter], or null without a port or an import service. The app root
/// reads it once after the library opened.
final incomingIntentImportProvider = Provider<IncomingIntentImporter?>((ref) {
  final port = ref.watch(incomingIntentPortProvider);
  final imports = ref.watch(importServiceProvider);
  if (port == null || imports == null) return null;
  final importer = IncomingIntentImporter(port: port, imports: imports)..start();
  ref.onDispose(importer.dispose);
  return importer;
});
