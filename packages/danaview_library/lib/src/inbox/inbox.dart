// OWNER: HOM-21
//
// The public entry of lib/src/inbox/ (ARCH v1.2 §5.6, V2-116): Open with Danaview (photos and
// documents imported and opened in their viewer, everything else played as in 1.1) and the iOS
// Share Extension inbox (the port over the App Group, the importer run on launch and foreground,
// and the folder-list snapshot the extension's picker reads).

/// The public entry of lib/src/inbox/: Open with Danaview and the Share Extension inbox (ARCH v1.2 §5.6).
library;

export 'folder_snapshot.dart';
export 'inbox_importer.dart';
export 'inbox_port.dart';
export 'incoming_open.dart';
