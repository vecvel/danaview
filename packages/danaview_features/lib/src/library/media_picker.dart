import 'package:flutter/foundation.dart';
import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_platform/danaview_platform.dart';

/// A picker failure other than the user cancelling; [message] is safe to show to the user.
class MediaPickerException implements Exception {
  final String message;
  final Object? cause;

  const MediaPickerException(this.message, {this.cause});

  @override
  String toString() => message;
}

/// Whether [pickFolderPath] can show a folder picker on this platform (desktop only).
bool get canPickFolders => PlatformBridge.supportsDirectoryPicking;

/// Lets the user pick videos and returns playable refs; empty when cancelled.
///
/// On iOS/Android the picked temporary copies are moved into the app's Documents/Imported
/// folder first so history and playlists keep working. Throws [MediaPickerException].
Future<List<MediaRef>> pickVideoRefs({LibraryStorage? storage}) async {
  final List<String> picked;
  try {
    picked = await PlatformBridge.pickVideoFiles();
  } catch (e) {
    debugPrint('[MediaPicker] pickVideoFiles failed: $e');
    throw MediaPickerException("Couldn't open the selected videos. Please try again.", cause: e);
  }
  if (picked.isEmpty) return const [];
  final paths = await (storage ?? LibraryStorage()).importPickedFiles(picked);
  return paths.map(LibraryRepository.mediaRefForFile).toList();
}

/// Lets the user pick a folder; null when cancelled or unsupported (see [canPickFolders]).
/// Throws [MediaPickerException].
Future<String?> pickFolderPath() async {
  if (!canPickFolders) return null;
  try {
    return await PlatformBridge.pickDirectory();
  } catch (e) {
    debugPrint('[MediaPicker] pickDirectory failed: $e');
    throw MediaPickerException("Couldn't open the folder picker. Please try again.", cause: e);
  }
}
