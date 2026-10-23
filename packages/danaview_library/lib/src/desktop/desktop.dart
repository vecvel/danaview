// OWNER: HOM-03
//
// The public entry of lib/src/desktop/: desktop photo directory discovery (ARCH v1.2 V2-109,
// HOM plan D-94). The package barrel exports this file; it re-exports the directory's public
// files: the read-only file-system surface, the Pictures-folder and volume roots of macOS,
// Windows and Linux, and the incremental read-only scanner.

/// Desktop photo directory discovery: roots (Pictures folders, external volumes) and the scanner.
library;

export 'desktop_fs.dart';
export 'desktop_roots.dart';
export 'desktop_scanner.dart';
