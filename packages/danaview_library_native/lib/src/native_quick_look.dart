// OWNER: HOM-26
//
// Quick Look (ARCH v1.2 §3 "Office / other files", "Text / CSV", V2-120, G-R3; BUILD_PLAN HOM-26)
// over the frozen Pigeon surface: `QLPreviewController` on iOS and a `QLPreviewView` sheet on macOS,
// both with editing disabled and showing temporary read-only copies, so Markup can never change a
// library file. Android, Windows and Linux have no Quick Look: every call fails with
// `notSupportedOnDevice` and the viewer router shows the file card. Document thumbnails are on
// [NativeThumbnails.documentThumbnail] (HOM-04's cache calls them). Nothing here logs or prints a
// name or a path (rule 30).

import 'package:flutter/services.dart';

import 'native_export_out.dart';
import 'pigeon/library_api.g.dart';
import 'pigeon/library_channels.dart';

FileItemMsg _item(NativeOutFile file) =>
    FileItemMsg(path: file.path, displayName: file.displayName, mimeType: file.mimeType, uti: file.uti);

void _check(NativeOutFile f) {
  if (f.path.isEmpty) throw ArgumentError.value(f, 'file', 'empty path');
  if (f.displayName.isEmpty) throw ArgumentError.value(f, 'file', 'empty display name');
}

/// Quick Look previews over the plugin's Pigeon surface. Every call throws
/// [LibraryNativeException] (`notSupportedOnDevice` where the platform has no Quick Look).
final class NativeQuickLook {
  /// Quick Look of the default engine; tests pass a mock [binaryMessenger].
  NativeQuickLook({BinaryMessenger? binaryMessenger, String messageChannelSuffix = ''})
      : _api = QuickLookHostApi(binaryMessenger: binaryMessenger, messageChannelSuffix: messageChannelSuffix);

  final QuickLookHostApi _api;

  /// Whether Quick Look can preview [file] (a readable file of a type it shows). Throws `notFound`
  /// for a missing file.
  Future<bool> canPreview(NativeOutFile file) {
    _check(file);
    return guardNative(() => _api.canPreview(_item(file)));
  }

  /// Shows [files] starting at [initialIndex], editing disabled; completes when the preview is
  /// dismissed. Throws `busy` while another preview is open, `notFound` for a missing file,
  /// `ioError` when there is no window to present from.
  Future<void> present(List<NativeOutFile> files, {int initialIndex = 0}) {
    if (files.isEmpty) throw ArgumentError.value(files, 'files', 'empty');
    files.forEach(_check);
    if (initialIndex < 0 || initialIndex >= files.length) {
      throw RangeError.index(initialIndex, files, 'initialIndex');
    }
    return guardNative(() => _api.present(QuickLookRequestMsg(items: files.map(_item).toList(), initialIndex: initialIndex)));
  }
}
