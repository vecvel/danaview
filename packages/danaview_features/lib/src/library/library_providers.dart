import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_domain/danaview_domain.dart';
import '../controllers/providers.dart';
import 'library_controller.dart';

final libraryControllerProvider = StateNotifierProvider<LibraryController, LibraryState>((ref) {
  return LibraryController(
    ref.watch(libraryRepositoryProvider),
    ref.watch(sessionRepositoryProvider),
  );
});

/// One level of a folder; invalidate it to re-read the disk.
final folderListingProvider = FutureProvider.autoDispose.family<DirectoryListing, String>(
  (ref, path) => LibraryRepository.browseDirectory(path),
);

/// Items of a playlist in order; null when no playlist has that name.
final playlistItemsProvider = Provider.autoDispose.family<List<MediaRef>?, String>((ref, name) {
  ref.watch(libraryControllerProvider.select((s) => s.playlistRevision));
  final controller = ref.read(libraryControllerProvider.notifier);
  return controller.hasPlaylist(name) ? controller.playlistItems(name) : null;
});
