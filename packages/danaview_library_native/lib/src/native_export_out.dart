// OWNER: HOM-22
//
// Save a copy outside Danaview (ARCH v1.2 §8 "Getting files out", rule 26, V2-117; BUILD_PLAN
// HOM-22 / HOM-22A) over the frozen Pigeon surface: "Save to Files" (iOS
// `UIDocumentPickerViewController(forExporting:)`, macOS save panel, Android
// `ACTION_CREATE_DOCUMENT`), "Save to Downloads" (Android `MediaStore.Downloads`; Apple answers
// `notSupportedOnDevice`) and "Save to Photos" (add-only: `PHAssetCreationRequest`, MediaStore
// `Pictures`/`Movies`). Every destination is create-new: the platform never writes over a file it
// didn't create and never moves the library file. Also the value types the share and open-in
// wrappers use. Nothing here logs or prints a name, a path or a URI (rule 30).

import 'package:flutter/services.dart';

import 'pigeon/library_api.g.dart';
import 'pigeon/library_channels.dart';

/// One app file handed to the system (a library file; the platform makes temporary read-only
/// copies where the receiver could otherwise keep or change it).
final class NativeOutFile {
  /// A file at the absolute [path], shown to the receiver as [displayName].
  const NativeOutFile({required this.path, required this.displayName, this.mimeType, this.uti});

  /// Absolute path.
  final String path;

  /// The name the receiver sees.
  final String displayName;

  /// MIME type, when known.
  final String? mimeType;

  /// Apple UTType, when known.
  final String? uti;

  // Never prints names or paths (rule 30).
  @override
  String toString() => 'NativeOutFile(${mimeType ?? uti ?? '?'})';
}

/// Where a popover anchors on iPad and macOS, in logical pixels of the Flutter view.
final class NativeAnchor {
  /// A rectangle.
  const NativeAnchor(this.left, this.top, this.width, this.height);

  /// Left edge.
  final double left;

  /// Top edge.
  final double top;

  /// Width.
  final double width;

  /// Height.
  final double height;

  @override
  String toString() => 'NativeAnchor($left, $top, $width, $height)';
}

/// Where save-out writes.
enum NativeSaveDestination {
  /// The system file picker or save panel ("Save to Files", "Save…").
  files,

  /// Android `Download/` (Android 10+); not on Apple.
  downloads,

  /// The system photo library, add-only (photos and videos only).
  photos,
}

/// What save-out did.
final class NativeSaveResult {
  /// A result.
  const NativeSaveResult({required this.cancelled, required this.savedUris, required this.failedCount});

  /// True when the user closed the picker without saving.
  final bool cancelled;

  /// The created files (file URLs, content URIs or photo-library asset ids).
  final List<String> savedUris;

  /// Items that could not be saved (e.g. a document sent to Photos).
  final int failedCount;

  /// How many items were saved.
  int get savedCount => savedUris.length;

  // Never prints URIs (rule 30).
  @override
  String toString() => 'NativeSaveResult(cancelled: $cancelled, saved: $savedCount, failed: $failedCount)';
}

FileItemMsg _item(NativeOutFile file) =>
    FileItemMsg(path: file.path, displayName: file.displayName, mimeType: file.mimeType, uti: file.uti);

AnchorRectMsg? _anchor(NativeAnchor? anchor) =>
    anchor == null ? null : AnchorRectMsg(x: anchor.left, y: anchor.top, width: anchor.width, height: anchor.height);

void _checkFiles(List<NativeOutFile> files) {
  if (files.isEmpty) throw ArgumentError.value(files, 'files', 'empty');
  for (final f in files) {
    if (f.path.isEmpty) throw ArgumentError.value(f, 'files', 'empty path');
    if (f.displayName.isEmpty) throw ArgumentError.value(f, 'files', 'empty display name');
  }
}

/// Save-out over the plugin's Pigeon surface. Every call throws [LibraryNativeException]
/// (`notSupportedOnDevice` where the platform has no such destination; Windows and Linux use the
/// app's save dialog instead).
final class NativeExportOut {
  /// Save-out of the default engine; tests pass a mock [binaryMessenger].
  NativeExportOut({BinaryMessenger? binaryMessenger, String messageChannelSuffix = ''})
      : _api = ExportOutHostApi(binaryMessenger: binaryMessenger, messageChannelSuffix: messageChannelSuffix);

  final ExportOutHostApi _api;

  /// Saves copies of [files] to [destination]. [subdirectory] is the Android `Download/` sub-folder
  /// (default `Danaview`); [anchor] places the picker's popover on iPad and macOS.
  Future<NativeSaveResult> saveOut(
    List<NativeOutFile> files, {
    NativeSaveDestination destination = NativeSaveDestination.files,
    String? subdirectory,
    NativeAnchor? anchor,
  }) {
    _checkFiles(files);
    return guardNative(() async {
      final r = await _api.saveOut(SaveOutRequestMsg(
        items: [for (final f in files) _item(f)],
        destination: SaveOutDestinationMsg.values[destination.index],
        subdirectory: destination == NativeSaveDestination.downloads ? (subdirectory ?? 'Danaview') : null,
        anchor: _anchor(anchor),
      ));
      return NativeSaveResult(cancelled: r.cancelled, savedUris: List.unmodifiable(r.savedUris), failedCount: r.failedCount);
    });
  }
}
