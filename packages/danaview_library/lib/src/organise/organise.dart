// OWNER: HOM-19
//
// The public entry of lib/src/organise/ (HOM plan §8.1, D-98f / V2-119): favourites, recents,
// natural name order, sort remembered per folder, and the name search with its SearchBackend hook
// (AIS-51 swaps in the on-device index). The package barrel exports this file.

/// The public entry of lib/src/organise/: favourites, recents, name search and sort.
library;

export 'library_organiser.dart';
export 'library_search_source.dart';
export 'library_sort.dart';
export 'name_search.dart';
export 'natural_order.dart';
export 'sort_memory.dart';
