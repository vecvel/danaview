// OWNER: HOM-04
//
// Riverpod access to the Home thumbnail service (ARCH v1.2 V2-28, V2-104). The app root opens it
// with [openThumbnailService] (behind DANAVIEW_FILES_HOME; INT-103 wires it) under the platform
// cache directory and overrides [thumbnailServiceProvider]; with the flag off nothing opens it,
// the provider yields null and [LibraryThumbnail] cells show their placeholders, so the 1.1
// screens are untouched.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:danaview_library_native/danaview_library_native.dart';

import 'thumb_disk_cache.dart';
import 'thumbnail_service.dart';

/// The open thumbnail service, or null (flag off, or not opened yet). The app root overrides it.
final thumbnailServiceProvider = Provider<ThumbnailService?>((ref) => null);

/// Default size cap of the disk tier, enforced in the background after opening.
const thumbnailDiskBudgetBytes = 512 * 1024 * 1024;

/// Opens the thumbnail cache at `<cacheDir>/danaview/library/thumbs/` (V2-28) over the plugin's
/// thumbnailers. [excludeFromBackup] is the plugin's backup flag (`NativeBackupFlags`), applied to
/// the root; the disk tier is trimmed to [diskBudgetBytes] in the background.
Future<ThumbnailService> openThumbnailService({
  required String cacheDir,
  ThumbnailGenerator? generator,
  Future<void> Function(String path)? excludeFromBackup,
  int diskBudgetBytes = thumbnailDiskBudgetBytes,
}) async {
  final disk = IoThumbDiskCache(thumbsRootIn(cacheDir));
  await disk.open(excludeFromBackup: excludeFromBackup);
  unawaited(disk.trim(diskBudgetBytes).catchError((Object _) {}));
  return ThumbnailService(disk: disk, generator: generator ?? NativeThumbnails());
}

/// Drops the memory tier when the system reports memory pressure. The app root adds it with
/// `WidgetsBinding.instance.addObserver` next to the service.
final class ThumbnailMemoryPressureObserver with WidgetsBindingObserver {
  /// An observer for [service].
  ThumbnailMemoryPressureObserver(this.service);

  /// The service to trim.
  final ThumbnailService service;

  @override
  void didHaveMemoryPressure() => service.trimMemory();
}
