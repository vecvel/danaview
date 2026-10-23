// OWNER: HOM-20
//
// The native import pickers (ARCH v1.2 §5.6, V2-116, BUILD_PLAN HOM-20 / HOM-20A) over the frozen
// Pigeon surface: the system photo picker (`PHPickerViewController` with the `.current`
// representation and no library permission on iOS and macOS 13+, the Android Photo Picker), the
// document picker (`UIDocumentPickerViewController` in import mode, `NSOpenPanel`, SAF
// `ACTION_OPEN_DOCUMENT`), and the streamed, resumable copy of a picked platform URI into an app
// file. Picked photos are copied by the platform into an app-owned staging directory (the
// picker's own files vanish after its callback); the import service copies them on into the
// library and deletes the staged copy. Nothing here logs a name, a path or a URI (rule 30).

import 'dart:async';

import 'package:flutter/services.dart';

import 'native_photo_library.dart';
import 'pigeon/library_api.g.dart';
import 'pigeon/library_channels.dart';

/// Which items the photo picker shows.
enum PhotoPickFilter {
  /// Photos and videos.
  all,

  /// Photos only.
  photos,

  /// Videos only.
  videos,
}

/// Where a picked item came from.
enum PickedItemSource {
  /// The system photo picker.
  photoLibrary,

  /// The system document picker or open panel.
  files,
}

/// One item a picker returned.
final class PickedItem {
  /// An item.
  const PickedItem({
    required this.uri,
    required this.displayName,
    required this.source,
    required this.needsCopy,
    this.path,
    this.uti,
    this.mimeType,
    this.sizeBytes,
    this.modifiedAt,
    this.assetIdentifier,
  });

  /// `file://` URL or `content://` URI.
  final String uri;

  /// A local path when the item can be read directly (a staged copy, an open-panel file).
  final String? path;

  /// The file name to show and import as.
  final String displayName;

  /// Apple UTType.
  final String? uti;

  /// MIME type.
  final String? mimeType;

  /// Size, when the platform reported it.
  final int? sizeBytes;

  /// Modification time, when the platform reported it.
  final DateTime? modifiedAt;

  /// The PhotoKit / MediaStore id when reported (no permission implied).
  final String? assetIdentifier;

  /// Which picker.
  final PickedItemSource source;

  /// True when the bytes can only be read through [NativePickers.copyToFile] (a content URI or a
  /// security-scoped URL); false when [path] is readable.
  final bool needsCopy;

  // Never prints names, paths or URIs (rule 30).
  @override
  String toString() => 'PickedItem(${source.name}, needsCopy: $needsCopy)';
}

/// The outcome of [NativePickers.copyToFile].
final class PickedCopy {
  /// An outcome.
  const PickedCopy({required this.bytesCopied, required this.totalBytes});

  /// Bytes in the destination after the copy.
  final int bytesCopied;

  /// Size of the source, or -1 when unknown before the copy finished.
  final int totalBytes;
}

DateTime? _time(int? ms) => ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);

/// [PickedItem] of a Pigeon message (tests and the plugin wrapper).
PickedItem pickedItemFromMessage(PickedItemMsg m) => PickedItem(
      uri: m.uri,
      path: m.path,
      displayName: m.displayName,
      uti: m.uti,
      mimeType: m.mimeType,
      sizeBytes: m.sizeBytes,
      modifiedAt: _time(m.modifiedTimeMs),
      assetIdentifier: m.assetIdentifier,
      source: m.source == PickedSourceMsg.photoLibrary ? PickedItemSource.photoLibrary : PickedItemSource.files,
      needsCopy: m.needsCopy,
    );

/// The system pickers and the streamed copy over the plugin's Pigeon surface. Every call throws
/// [LibraryNativeException]; `notSupportedOnDevice` where a platform has no such picker (Windows
/// and Linux use the app's `file_selector` instead).
final class NativePickers {
  /// The pickers of the default engine; tests pass a mock [binaryMessenger] and an [events] hub.
  NativePickers({BinaryMessenger? binaryMessenger, String messageChannelSuffix = '', LibraryEventHub? events})
      : _api = PickerHostApi(binaryMessenger: binaryMessenger, messageChannelSuffix: messageChannelSuffix),
        _events = events ?? LibraryEventHub.forInstance(messageChannelSuffix);

  final PickerHostApi _api;
  final LibraryEventHub _events;
  int _copies = 0;

  /// Shows the photo picker (at most [limit] items, 0 for no limit) and copies each pick into
  /// [stagingDirectory] (app-owned, never the library root). Empty when the user cancelled.
  Future<List<PickedItem>> pickPhotos({required String stagingDirectory, int limit = 0, PhotoPickFilter filter = PhotoPickFilter.all}) {
    if (limit < 0) throw ArgumentError.value(limit, 'limit', 'negative');
    if (stagingDirectory.isEmpty) throw ArgumentError.value(stagingDirectory, 'stagingDirectory', 'empty');
    return guardNative(() async => [
          for (final m in await _api.pickPhotos(PhotoPickRequestMsg(
            selectionLimit: limit,
            filter: PhotoMediaFilterMsg.values[filter.index],
            destinationDirectory: stagingDirectory,
          )))
            pickedItemFromMessage(m),
        ]);
  }

  /// Shows the document picker in import mode. [utis] (Apple) and [mimeTypes] (Android) limit the
  /// types (empty: any). With a [stagingDirectory] the platform copies each pick there; without one
  /// the items are platform URIs for [copyToFile]. Empty when the user cancelled.
  Future<List<PickedItem>> pickDocuments({
    bool allowMultiple = true,
    List<String> utis = const [],
    List<String> mimeTypes = const [],
    String? stagingDirectory,
  }) =>
      guardNative(() async => [
            for (final m in await _api.pickDocuments(DocumentPickRequestMsg(
              allowMultiple: allowMultiple,
              utis: utis,
              mimeTypes: mimeTypes,
              destinationDirectory: stagingDirectory,
            )))
              pickedItemFromMessage(m),
          ]);

  /// Streams the platform URI [sourceUri] (opened read-only) into [destinationPath], appending from
  /// [resumeFromOffset]. [onProgress] receives the bytes copied so far. [requestId] lets
  /// [cancelCopy] stop it.
  Future<PickedCopy> copyToFile({
    required String sourceUri,
    required String destinationPath,
    int resumeFromOffset = 0,
    String? requestId,
    void Function(int bytesDone, int? bytesTotal)? onProgress,
  }) async {
    if (resumeFromOffset < 0) throw ArgumentError.value(resumeFromOffset, 'resumeFromOffset', 'negative');
    final id = requestId ?? 'picker-copy-${++_copies}-${DateTime.now().microsecondsSinceEpoch}';
    StreamSubscription<LibraryEventMsg>? sub;
    if (onProgress != null) {
      sub = _events.of(LibraryEventKindMsg.copyProgress).listen((e) {
        final p = e.copyProgress;
        if (p != null && p.requestId == id) onProgress(p.bytesDone, p.bytesTotal);
      });
    }
    try {
      return await guardNative(() async {
        final r = await _api.copyToFile(CopyRequestMsg(
          requestId: id,
          sourceUri: sourceUri,
          destinationPath: destinationPath,
          resumeFromOffset: resumeFromOffset,
        ));
        return PickedCopy(bytesCopied: r.bytesCopied, totalBytes: r.totalBytes);
      });
    } finally {
      await sub?.cancel();
    }
  }

  /// Stops the copy [requestId]; it then fails with `cancelled`.
  Future<void> cancelCopy(String requestId) => guardNative(() => _api.cancelCopy(requestId));

  /// Gives up the security-scoped access or URI grant held for [uri] (no-op when none is held).
  Future<void> release(String uri) => guardNative(() => _api.release(uri));
}
