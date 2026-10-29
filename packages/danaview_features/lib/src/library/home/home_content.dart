// Whether the Files & Media Home holds anything beyond the 1.1 library (DESIGN_SYSTEM §10.3: "If
// everything is empty, Home shows one empty state"). The 1.1 Home counts its watch history,
// playlists and folders; with DANAVIEW_FILES_HOME on the Home also shows photos, videos and
// documents of the Danaview library, the opted-in system and desktop photos, the documents of
// linked folders, Danaview folders and the editor's projects. Any one of them hides the empty
// state, so a library holding only photos never claims to be empty.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../filters/filter_providers.dart';
import '../filters/library_filters.dart';
import 'home_projects.dart';
import 'recent_photos_tray.dart';

/// True when the Files Home has any content of its own: a Danaview entry of any kind (video,
/// photo, document, audio, other), a recent system or desktop photo, a linked-folder document, a
/// Danaview folder or an editor project. Reads cheap counts only (one COUNT per library revision).
final homeHasFilesContentProvider = Provider.autoDispose<bool>((ref) {
  if (!ref.watch(libraryFilterEntriesProvider((filter: LibraryFilter.all, subFilter: null))).isEmpty) return true;
  if (ref.watch(libraryChildFoldersProvider(null)).isNotEmpty) return true;
  if (ref.watch(homeProjectsProvider).isNotEmpty) return true;
  if (ref.watch(linkedDocumentsProvider).isNotEmpty) return true;
  return ref.watch(recentPhotosProvider(recentPhotosTrayLimit)).items.isNotEmpty;
}, name: 'homeHasFilesContentProvider');
