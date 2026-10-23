// OWNER: HOM-22
//
// Open in another app (ARCH v1.2 §3, §8, V2-117, D-98h, D-98k; BUILD_PLAN HOM-22 / HOM-22A) over
// the frozen Pigeon surface: `UIDocumentInteractionController` "Open in…" (iOS), `NSWorkspace`
// with the default app (macOS), `ACTION_VIEW` with a read-only `FileProvider` grant (Android). The
// other app gets a temporary read-only copy and can never change the library file. Nothing here
// logs or prints a name, a path or a URI (rule 30).

import 'package:flutter/services.dart';

import 'native_export_out.dart';
import 'pigeon/library_api.g.dart';
import 'pigeon/library_channels.dart';

FileItemMsg _item(NativeOutFile file) =>
    FileItemMsg(path: file.path, displayName: file.displayName, mimeType: file.mimeType, uti: file.uti);

AnchorRectMsg? _anchor(NativeAnchor? anchor) =>
    anchor == null ? null : AnchorRectMsg(x: anchor.left, y: anchor.top, width: anchor.width, height: anchor.height);

void _check(List<NativeOutFile> files) {
  if (files.isEmpty) throw ArgumentError.value(files, 'files', 'empty');
  for (final f in files) {
    if (f.path.isEmpty) throw ArgumentError.value(f, 'files', 'empty path');
    if (f.displayName.isEmpty) throw ArgumentError.value(f, 'files', 'empty display name');
  }
}

/// "Open in another app" over the plugin's Pigeon surface. Every call throws
/// [LibraryNativeException] (`notSupportedOnDevice` on Windows and Linux, where the app root opens
/// the default app itself).
final class NativeOpenIn {
  /// Open-in of the default engine; tests pass a mock [binaryMessenger].
  NativeOpenIn({BinaryMessenger? binaryMessenger, String messageChannelSuffix = ''})
      : _api = OpenInHostApi(binaryMessenger: binaryMessenger, messageChannelSuffix: messageChannelSuffix);

  final OpenInHostApi _api;

  /// Offers [file] to other apps. True when an app chooser or the default app was shown; false
  /// when no installed app takes the file.
  Future<bool> openIn(NativeOutFile file, {NativeAnchor? anchor}) {
    _check([file]);
    return guardNative(() => _api.openIn(OpenInRequestMsg(item: _item(file), anchor: _anchor(anchor))));
  }
}
