// OWNER: HOM-30
//
// The public entry of lib/src/signatures/: saved signatures (ARCH v1.2 V2-29; HOM plan §8.5). The
// app-private store (`<app support>/signatures`, excluded from backups and from the Danaview
// folders, at most 10, never logged), making a signature (draw, type in a bundled script font,
// import a photo with its background removed), choosing and deleting saved ones, and the Settings ›
// Privacy rows with "Delete all". The PDF sign mode (lib/src/pdf/sign/) places them on pages.

/// The public entry of lib/src/signatures/: saved signatures (ARCH v1.2 V2-29).
library;

export 'signature_create_sheet.dart';
export 'signature_image.dart';
export 'signature_list.dart';
export 'signature_pad.dart';
export 'signature_store.dart';
