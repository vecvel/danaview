// OWNER: HOM-22
//
// The public entry of lib/src/actions/ (ARCH v1.2 V2-117, V2-118; BUILD_PLAN HOM-22): which file
// actions an item or a selection gets, the library-side actions over the store (rename, copy,
// move, favourites, delete with the "Used in N projects" warning, File info) and the port the app
// implements for getting files out (save a copy, share, open in).

/// File actions and getting files out (ARCH v1.2 V2-117, V2-118).
library;

export 'file_action.dart';
export 'file_out.dart';
export 'library_file_actions.dart';
