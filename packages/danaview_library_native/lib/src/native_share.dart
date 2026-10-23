// OWNER: HOM-22
//
// The system share sheet (ARCH v1.2 §3, §8, V2-118; BUILD_PLAN HOM-22 / HOM-22A) over the frozen
// Pigeon surface: `UIActivityViewController` (iOS), `NSSharingServicePicker` (macOS),
// `ACTION_SEND` / `ACTION_SEND_MULTIPLE` through the plugin's `FileProvider` (Android). The
// platform hands the receiver temporary read-only copies, never the library file, and removes
// them when the system is done. Nothing here logs or prints a name, a path or a URI (rule 30).

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

/// What the share sheet did.
final class NativeShareResult {
  /// A result.
  const NativeShareResult({required this.completed, this.activityType});

  /// True when the user shared (false when they closed the sheet).
  final bool completed;

  /// The activity or service chosen, when the platform says.
  final String? activityType;

  @override
  String toString() => 'NativeShareResult(completed: $completed)';
}

/// The share sheet over the plugin's Pigeon surface. Every call throws [LibraryNativeException]
/// (`notSupportedOnDevice` on Windows and Linux, which offer the save dialog instead).
final class NativeShare {
  /// The share sheet of the default engine; tests pass a mock [binaryMessenger].
  NativeShare({BinaryMessenger? binaryMessenger, String messageChannelSuffix = ''})
      : _api = ShareHostApi(binaryMessenger: binaryMessenger, messageChannelSuffix: messageChannelSuffix);

  final ShareHostApi _api;

  /// Shows the share sheet for [files]; [subject] goes to services that use one (mail);
  /// [anchor] places the popover on iPad and macOS.
  Future<NativeShareResult> share(List<NativeOutFile> files, {String? subject, NativeAnchor? anchor}) {
    _check(files);
    return guardNative(() async {
      final r = await _api.share(ShareRequestMsg(
        items: [for (final f in files) _item(f)],
        subject: subject,
        anchor: _anchor(anchor),
      ));
      return NativeShareResult(completed: r.completed, activityType: r.activityType);
    });
  }
}
