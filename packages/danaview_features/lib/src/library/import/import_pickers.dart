// OWNER: HOM-20
//
// The pickers of the import sheet (ARCH v1.2 §5.6, HOM plan §8.2): [ImportPicker] turns a system
// pick into [ImportSource]s for the import service. [NativeImportPicker] uses the native plugin
// (iOS and macOS: PHPicker, UIDocumentPicker, NSOpenPanel; Android: Photo Picker and SAF, HOM-20A);
// [CallbackImportPicker] wraps the app root's desktop `file_selector` call on Windows and Linux.
// [NativeImportCopier] copies platform URIs (content URIs, security-scoped URLs) through the
// plugin's streamed copy. Only files inside the app's staging directory are marked as staged
// copies, so the import never deletes a user's original. Nothing is logged (rule 30).

import 'dart:async';
import 'dart:io';

import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_library_native/danaview_library_native.dart';

/// Why a pick failed (the user cancelling is an empty result, not a failure).
final class ImportPickException implements Exception {
  /// A failure; [unsupported] when the platform has no such picker.
  const ImportPickException({this.unsupported = false});

  /// True when this platform has no such picker.
  final bool unsupported;

  @override
  String toString() => 'ImportPickException(unsupported: $unsupported)';
}

/// The two pickers of the import sheet.
abstract interface class ImportPicker {
  /// True when "From Photos" is offered.
  bool get canPickPhotos;

  /// Photos and videos from the system photo picker (no library permission); empty on cancel.
  Future<List<ImportSource>> pickPhotos();

  /// Any files from the system file picker; empty on cancel.
  Future<List<ImportSource>> pickFiles();
}

/// [ImportSource]s of native picker results. Items with a readable [PickedItem.path] are read
/// locally; a path inside [stagingDirectory] is the platform's copy and is deleted after import;
/// items that need a copy become [ImportSourceKind.nativeUri] sources.
List<ImportSource> importSourcesOf(Iterable<PickedItem> items, {required String stagingDirectory}) {
  final staging = Directory(stagingDirectory).absolute.uri.normalizePath().path;
  bool staged(String path) {
    final file = File(path).absolute.uri.normalizePath().path;
    return file.length > staging.length && file.startsWith(staging);
  }

  return [
    for (final item in items)
      if (!item.needsCopy && item.path != null)
        ImportSource.file(
          item.path!,
          displayName: item.displayName,
          uti: item.uti,
          mime: item.mimeType,
          sizeBytes: item.sizeBytes,
          modifiedAt: item.modifiedAt,
          sourceHint: item.source == PickedItemSource.photoLibrary ? SourceHint.photos : SourceHint.files,
          stagedCopy: staged(item.path!),
        )
      else
        ImportSource(
          kind: ImportSourceKind.nativeUri,
          location: item.uri,
          displayName: item.displayName,
          uti: item.uti,
          mime: item.mimeType,
          sizeBytes: item.sizeBytes,
          modifiedAt: item.modifiedAt,
          sourceHint: item.source == PickedItemSource.photoLibrary ? SourceHint.photos : SourceHint.files,
          releaseUri: item.uri,
        ),
  ];
}

/// The native pickers, copying photo picks into [stagingDirectory] (app-owned, outside the
/// library root, e.g. `<caches>/danaview/import_staging/`).
final class NativeImportPicker implements ImportPicker {
  /// Pickers over [pickers] (the default engine's when null).
  NativeImportPicker({required this.stagingDirectory, NativePickers? pickers, this.canPickPhotos = true})
      : _pickers = pickers ?? NativePickers();

  /// Where picked photos and documents are staged.
  final String stagingDirectory;

  final NativePickers _pickers;

  @override
  final bool canPickPhotos;

  Future<List<ImportSource>> _guard(Future<List<PickedItem>> Function() pick) async {
    try {
      return importSourcesOf(await pick(), stagingDirectory: stagingDirectory);
    } on LibraryNativeException catch (e) {
      if (e.code == LibraryNativeErrorCode.cancelled) return const [];
      throw ImportPickException(unsupported: e.code == LibraryNativeErrorCode.notSupportedOnDevice);
    }
  }

  @override
  Future<List<ImportSource>> pickPhotos() => _guard(() => _pickers.pickPhotos(stagingDirectory: stagingDirectory));

  @override
  Future<List<ImportSource>> pickFiles() => _guard(() => _pickers.pickDocuments(stagingDirectory: stagingDirectory));
}

/// A desktop picker over a callback returning chosen paths (the app root passes `file_selector`'s
/// `openFiles`). Desktop has no photo picker.
final class CallbackImportPicker implements ImportPicker {
  /// A picker calling [openFiles].
  const CallbackImportPicker(this.openFiles);

  /// Shows the system open dialog; returns the chosen paths (empty on cancel).
  final Future<List<String>> Function() openFiles;

  @override
  bool get canPickPhotos => false;

  @override
  Future<List<ImportSource>> pickPhotos() async => const [];

  @override
  Future<List<ImportSource>> pickFiles() async {
    try {
      return [for (final path in await openFiles()) ImportSource.file(path)];
    } on Object {
      throw const ImportPickException();
    }
  }
}

/// Copies [ImportSourceKind.nativeUri] sources through the plugin's streamed copy. Native progress
/// rows are the checkpoints (the Apple copy fsyncs before each report; a resume truncates to
/// `bytes_done`).
final class NativeImportCopier implements ImportCopier {
  /// A copier over [pickers] (the default engine's when null).
  NativeImportCopier({NativePickers? pickers}) : _pickers = pickers ?? NativePickers();

  final NativePickers _pickers;
  int _next = 0;

  @override
  bool handles(ImportSource source) => source.kind == ImportSourceKind.nativeUri;

  /// Gives up the platform grant of [uri] after its import (never throws).
  Future<void> release(String uri) async {
    try {
      await _pickers.release(uri);
    } on LibraryNativeException {
      // Nothing held, or the platform has no grants.
    }
  }

  @override
  Future<SourceStat> stat(ImportSource source) async => SourceStat(size: source.sizeBytes ?? -1, modifiedAt: source.modifiedAt);

  @override
  ImportCopyRun start({
    required ImportSource source,
    required String partPath,
    required int resumeFrom,
    required bool hash,
    required void Function(int bytesDone) onProgress,
    required void Function(int bytesDone) onCheckpoint,
  }) {
    final id = 'import-copy-${++_next}-${DateTime.now().microsecondsSinceEpoch}';
    final run = _NativeCopyRun(_pickers, id);
    run._done = () async {
      try {
        final r = await _pickers.copyToFile(
          sourceUri: source.location,
          destinationPath: partPath,
          resumeFromOffset: resumeFrom,
          requestId: id,
          onProgress: (done, _) {
            onProgress(done);
            onCheckpoint(done);
          },
        );
        onCheckpoint(r.bytesCopied);
        final sha = hash ? await sha256OfFile(partPath) : null;
        return CopyOutcome(bytes: r.bytesCopied, sha256: sha);
      } on LibraryNativeException catch (e) {
        throw ImportException(switch (e.code) {
          LibraryNativeErrorCode.cancelled => ImportFailure.cancelled,
          LibraryNativeErrorCode.notFound || LibraryNativeErrorCode.permissionDenied || LibraryNativeErrorCode.unavailableOffline => ImportFailure.sourceUnreadable,
          LibraryNativeErrorCode.notSupportedOnDevice || LibraryNativeErrorCode.invalidArgument => ImportFailure.unsupportedSource,
          _ => ImportFailure.ioError,
        });
      }
    }();
    return run;
  }
}

final class _NativeCopyRun implements ImportCopyRun {
  _NativeCopyRun(this._pickers, this._id);

  final NativePickers _pickers;
  final String _id;
  late final Future<CopyOutcome> _done;

  @override
  Future<CopyOutcome> get done => _done;

  @override
  Future<void> cancel() async {
    try {
      await _pickers.cancelCopy(_id);
    } on LibraryNativeException {
      // Finished already.
    }
    await _done.then<void>((_) {}, onError: (Object _) {});
  }
}
