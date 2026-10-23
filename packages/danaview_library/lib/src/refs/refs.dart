// OWNER: HOM-17
//
// The public entry of lib/src/refs/: holders of library entries (editor projects and photo
// recipes, ARCH v1.2 V2-08). The writer adds and removes them (`LibraryWriter.addRef`), the reader
// counts them (`LibraryReader.refUsage`).

/// Project and recipe references to entries (ARCH v1.2 V2-08).
library;

export 'ref_holder.dart';
