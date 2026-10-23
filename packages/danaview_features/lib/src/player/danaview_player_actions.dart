// EXTENDED: HOM-21 (ARCH v1.2 §5.6, V2-116: "Save to Danaview folder" for the playing file, Open
// with Danaview for photos and documents through IncomingMediaBridge.interceptor, and the iOS Share
// Extension inbox run on launch, on every foreground and when the extension finishes a batch. All
// of it is inert until the app root (behind DANAVIEW_FILES_HOME) overrides the providers below and
// installs the interceptor; with the flag off the player behaves as in 1.1.)

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_library_native/danaview_library_native.dart' show NativeInbox;
import 'package:danaview_platform/danaview_platform.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import '../controllers/providers.dart';
import '../library/files/library_store_providers.dart';
import '../library/import/import_providers.dart';
import '../library/media_picker.dart';
import 'screen_orientation_policy.dart';

/// Height the bottom control bar occupies above the safe area, plus a small gap.
double playerControlsReserve(BuildContext context) => context.isTouchPlatform ? 118 : 98;

/// Whether this window draws its own [DanaviewTitleBar] (desktop, outside touch layouts).
bool hasDesktopWindowChrome(BuildContext context) => PlatformBridge.isDesktop && !context.isTouchPlatform;

/// Above the control bar; on short (landscape phone) screens just below the top bar instead, so it
/// can't cover the centre play button.
void showPlayerToast(BuildContext context, String message, {DanaviewToastKind kind = DanaviewToastKind.info}) {
  final short = MediaQuery.sizeOf(context).height < 560;
  DanaviewToast.show(
    context,
    message,
    kind: kind,
    // On desktop the controls' top bar sits under the window title bar and ends at about 84.
    topOffset: short ? (hasDesktopWindowChrome(context) ? DanaviewTitleBar.height + 52 : 64) : null,
    bottomOffset: playerControlsReserve(context),
  );
}

/// True once something was opened; the engine may report playback before the controller knows the source.
bool playerHasMedia(PlayerState state) =>
    state.currentSource != null || state.status != PlaybackStatus.idle;

/// Picks videos and plays them, or appends them to the queue when [append] is true.
Future<void> openVideoFiles(BuildContext context, WidgetRef ref, {bool append = false}) async {
  final List<MediaRef> refs;
  try {
    refs = await pickVideoRefs();
  } on MediaPickerException catch (e) {
    if (context.mounted) {
      showPlayerToast(context, e.message, kind: DanaviewToastKind.error);
    }
    return;
  }
  if (refs.isEmpty) return;
  final queueCtrl = ref.read(queueControllerProvider.notifier);
  if (append) {
    await queueCtrl.addToQueue(refs);
  } else {
    await queueCtrl.playFrom(refs);
  }
}

String formatPlaybackDuration(Duration d) {
  final hours = d.inHours;
  final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}

String formatPlaybackSpeed(double speed) {
  final fixed = speed.toStringAsFixed(2);
  final trimmed = fixed.replaceFirst(RegExp(r'\.?0+$'), '');
  return '${trimmed}x';
}

String playerErrorMessage(PlayerError error) {
  return switch (error) {
    FileNotFound() => "Couldn't find this video. It may have been moved or deleted.",
    UnsupportedFormat() => "This video's format isn't supported.",
    DecoderInitFailed() => 'Hardware decoding failed, so Danaview switched to software decoding.',
    NetworkUnreachable() => "Can't reach this stream. Check your connection and try again.",
    YtdlpFailed() => "Couldn't load this online video. Check the link and try again.",
    PermissionDenied() => "Danaview doesn't have permission to open this video.",
    AudioDeviceLost() => 'The audio device was disconnected.',
    AudioOutputUnavailable() => 'No audio output available',
    PlaybackWarning() || GenericPlayerError() => "Couldn't play this video.",
  };
}

/// Problems playback recovers from are informational, not failures.
DanaviewToastKind playerErrorToastKind(PlayerError error) => switch (error) {
      AudioOutputUnavailable() || DecoderInitFailed() || PlaybackWarning() => DanaviewToastKind.info,
      _ => DanaviewToastKind.error,
    };

/// Orientation policy for the player: phones keep the library upright, the player follows the
/// device (or the orientation the rotate button locked), and tablets rotate freely everywhere.
///
/// A thin wrapper over [ScreenOrientationPolicy] that keeps the player's call sites unchanged:
/// each player screen is an owner in the policy's stack (mode [OrientationMode.followDevice]), so
/// an editor opened over it can enter and release without leaving the player without an owner.
abstract final class PlayerOrientation {
  static Future<void> applyAppDefault() => ScreenOrientationPolicy.applyAppDefault();

  static Future<void> enter(Object owner) => ScreenOrientationPolicy.enter(owner, OrientationMode.followDevice);

  /// Flips between portrait and landscape and holds it there regardless of how the device is held.
  static Future<void> toggle(Orientation current) {
    final owner = ScreenOrientationPolicy.topOwner;
    return owner == null ? Future<void>.value() : ScreenOrientationPolicy.toggle(owner, current);
  }

  /// Restoring the app default also rotates a phone back upright, however the player was held.
  /// Does nothing once [owner] has released.
  static Future<void> release(Object owner) => ScreenOrientationPolicy.release(owner);
}

// ---------------------------------------------------------------------------------------------
// HOM-21: Save to Danaview folder, Open with Danaview, the Share Extension inbox.
// Nothing here logs a name, a path or a link (ARCH v1.2 rule 30).
// ---------------------------------------------------------------------------------------------

/// The playing queue item when it is a local file that can be saved into a Danaview folder.
MediaRef? saveableCurrentMedia(WidgetRef ref) {
  final item = ref.read(queueControllerProvider).currentItem;
  if (item == null || item.isRemote || item.pathOrUri.isEmpty) return null;
  final path = incomingLocalPath(item.pathOrUri);
  return path == null ? null : item;
}

/// True when the player menu should offer "Save to Danaview folder": a local file is playing and
/// the library is open (DANAVIEW_FILES_HOME).
bool canSaveToDanaviewFolder(WidgetRef ref) => ref.read(importServiceProvider) != null && saveableCurrentMedia(ref) != null;

/// Copies the playing file into [target] (`Imported` when null) with `sourceHint = player`. The
/// file itself is only read (rule 27); a file already in the library is not copied twice. Shows
/// a toast with the outcome and returns the entry (new or existing), or null.
Future<FileEntry?> saveToDanaviewFolder(BuildContext context, WidgetRef ref, {FolderId? target}) async {
  final imports = ref.read(importServiceProvider);
  final media = saveableCurrentMedia(ref);
  if (imports == null || media == null) return null;
  final path = incomingLocalPath(media.pathOrUri)!;
  final ImportItem item;
  try {
    item = await imports.result(imports.enqueue(
      ImportSource.file(path, sourceHint: SourceHint.player),
      target: target,
      duplicates: DuplicatePolicy.skip,
    ));
  } on Object {
    if (context.mounted) showPlayerToast(context, "Couldn't save this video.", kind: DanaviewToastKind.error);
    return null;
  }
  if (!context.mounted) return item.entry ?? item.duplicateOf;
  switch (item.state) {
    case ImportItemState.done:
      showPlayerToast(context, 'Saved to Danaview folders', kind: DanaviewToastKind.success);
    case ImportItemState.skipped:
      showPlayerToast(context, 'Already in Danaview folders');
    case ImportItemState.cancelled:
      break;
    case _:
      showPlayerToast(context, "Couldn't save this video.", kind: DanaviewToastKind.error);
  }
  return item.entry ?? item.duplicateOf;
}

/// True for a copy iOS made for the app when another app opened a file with Danaview
/// (`Documents/Inbox/`, or a `<bundle id>-Inbox` folder under `tmp/`): it is app-owned, so the
/// import removes it afterwards. Any other path is the user's file and is only read.
bool isSystemOpenInCopy(String path) {
  final p = path.replaceAll(r'\', '/');
  return p.contains('/Documents/Inbox/') || RegExp(r'/tmp/[^/]+-Inbox/').hasMatch(p);
}

/// Opens [media] for viewing when it is a photo or a document: imports it into `Imported`
/// (`sourceHint = openWith`) and calls [openEntry] with the new entry, or with the entry already
/// in the library for the same content. Returns false (the player takes it, as in 1.1) for
/// videos, audio, streams, `danaview://` links and unknown types, and when [imports] is null.
/// [onFailed] runs when a photo or document could not be imported.
Future<bool> openIncomingForViewing(
  String media, {
  required ImportService? imports,
  required void Function(FileEntry entry) openEntry,
  bool Function(String path) isAppOwnedCopy = isSystemOpenInCopy,
  void Function()? onFailed,
}) async {
  if (imports == null || routeIncoming(media) != IncomingRoute.importAndView) return false;
  final IncomingImport? result;
  try {
    result = await IncomingOpenImporter(imports: imports, isAppOwnedCopy: isAppOwnedCopy).importForViewing(media);
  } on Object {
    onFailed?.call();
    return true;
  }
  final entry = result?.entry;
  if (entry == null) {
    onFailed?.call();
  } else {
    openEntry(entry);
  }
  return true;
}

/// The interceptor the app root installs on [IncomingMediaBridge.interceptor] (behind
/// DANAVIEW_FILES_HOME): photos and documents go to [openIncomingForViewing] with the import
/// service [imports] returns at that moment; everything else plays as in 1.1.
IncomingMediaInterceptor incomingDocumentInterceptor({
  required ImportService? Function() imports,
  required void Function(FileEntry entry) openEntry,
  void Function()? onFailed,
}) =>
    (media) => openIncomingForViewing(media, imports: imports(), openEntry: openEntry, onFailed: onFailed);

/// [InboxPort] over the plugin's [NativeInbox] (the only App Group reader, rule 26).
final class NativeInboxPort implements InboxPort {
  /// A port over [inbox].
  NativeInboxPort([NativeInbox? inbox]) : inbox = inbox ?? NativeInbox();

  /// The plugin wrapper.
  final NativeInbox inbox;

  @override
  Future<bool> isAvailable() => inbox.isAvailable();

  @override
  Future<List<InboxBatch>> listBatches() async => [
        for (final b in await inbox.listBatches())
          InboxBatch(
            batchId: b.batchId,
            createdAt: b.createdAt,
            complete: b.complete,
            targetFolder: b.targetFolderId == null ? null : FolderId.tryParse(b.targetFolderId!),
            files: [
              for (final f in b.files)
                InboxFile(relativePath: f.relativePath, displayName: f.displayName, sizeBytes: f.sizeBytes, uti: f.uti, mimeType: f.mimeType),
            ],
          ),
      ];

  @override
  Future<void> takeFile(String batchId, String relativePath, String destinationPath) => inbox.takeFile(batchId, relativePath, destinationPath);

  @override
  Future<void> deleteBatch(String batchId) => inbox.deleteBatch(batchId);

  @override
  Future<int> deleteStaleBatches(Duration age) => inbox.deleteStaleBatches(age);

  @override
  Future<void> writeFolderSnapshot(List<int> json) => inbox.writeFolderSnapshot(json);
}

/// The Share Extension inbox; the app root overrides it with [NativeInboxPort] on iOS (null:
/// no inbox).
final inboxPortProvider = Provider<InboxPort?>((ref) => null);

/// Fires when the extension finished a batch while the app runs ([NativeInbox.changes]).
final inboxChangesProvider = Provider<Stream<void>?>((ref) => null);

/// The app-owned directory inbox files wait in for their import (not the picker staging
/// directory: each is swept on its own).
final inboxStagingDirectoryProvider = Provider<String?>((ref) => null);

/// The inbox importer, or null without a library, an inbox or a staging directory.
final inboxImporterProvider = Provider<InboxImporter?>((ref) {
  final imports = ref.watch(importServiceProvider);
  final port = ref.watch(inboxPortProvider);
  final staging = ref.watch(inboxStagingDirectoryProvider);
  if (imports == null || port == null || staging == null) return null;
  return InboxImporter(port: port, imports: imports, stagingDirectory: staging);
});

/// Runs an [InboxImporter] on start, on every return to the foreground and on every [changes]
/// event, and refreshes the folder snapshot after library writes.
final class InboxAutoImport {
  /// Drives [importer]; [results] reports each run that imported or failed something.
  InboxAutoImport(this.importer, {Stream<void>? changes, Stream<void>? libraryWrites, this.snapshotDelay = const Duration(milliseconds: 500)})
      : _changes = changes,
        _libraryWrites = libraryWrites;

  /// The importer.
  final InboxImporter importer;

  /// How long library writes settle before the folder snapshot is rewritten.
  final Duration snapshotDelay;

  final Stream<void>? _changes;
  final Stream<void>? _libraryWrites;
  final StreamController<InboxRunResult> _results = StreamController<InboxRunResult>.broadcast();
  AppLifecycleListener? _lifecycle;
  final List<StreamSubscription<void>> _subs = [];
  Timer? _snapshotTimer;
  bool _started = false;

  /// Runs that imported, skipped or failed something (for a toast).
  Stream<InboxRunResult> get results => _results.stream;

  /// Starts: one run now, then on resume and on changes. Idempotent.
  void start() {
    if (_started) return;
    _started = true;
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(runNow()));
    if (_changes case final changes?) _subs.add(changes.listen((_) => unawaited(runNow())));
    if (_libraryWrites case final writes?) {
      _subs.add(writes.listen((_) {
        _snapshotTimer?.cancel();
        _snapshotTimer = Timer(snapshotDelay, () => unawaited(importer.refreshFolderSnapshot()));
      }));
    }
    unawaited(runNow());
  }

  /// One run (joining a run in flight).
  Future<InboxRunResult> runNow() async {
    final InboxRunResult result;
    try {
      result = await importer.run();
    } on Object {
      return const InboxRunResult();
    }
    if (!_results.isClosed && (result.imported.isNotEmpty || result.failed > 0 || result.skipped > 0)) _results.add(result);
    return result;
  }

  /// Stops listening.
  void dispose() {
    _lifecycle?.dispose();
    _lifecycle = null;
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    _snapshotTimer?.cancel();
    unawaited(_results.close());
  }
}

/// The started [InboxAutoImport], or null without an importer. The app root reads it once after
/// the library opened.
final inboxAutoImportProvider = Provider<InboxAutoImport?>((ref) {
  final importer = ref.watch(inboxImporterProvider);
  if (importer == null) return null;
  final revisions = StreamController<void>();
  ref.listen(libraryRevisionProvider, (_, __) => revisions.add(null));
  final auto = InboxAutoImport(importer, changes: ref.watch(inboxChangesProvider), libraryWrites: revisions.stream)..start();
  ref.onDispose(() {
    auto.dispose();
    unawaited(revisions.close());
  });
  return auto;
});

/// The toast text of an inbox run, or null when there is nothing to say.
String? inboxResultMessage(InboxRunResult r) {
  final n = r.imported.length;
  if (n == 0 && r.failed == 0) return null;
  final saved = n == 0 ? null : (n == 1 ? '1 shared item saved' : '$n shared items saved');
  final failed = r.failed == 0 ? null : (r.failed == 1 ? "1 item couldn't be saved" : "${r.failed} items couldn't be saved");
  return [if (saved != null) saved, if (failed != null) failed].join(' · ');
}
