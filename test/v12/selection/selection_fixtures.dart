// OWNER: HOM-12
//
// Fixtures of the multi-select tests (BUILD_PLAN HOM-12): photos, videos and documents with fixed
// ids and paths.

// The root package reaches danaview_library through danaview_features.
// ignore_for_file: depend_on_referenced_packages

import 'package:danaview_library/danaview_library.dart';

final DateTime fixtureDate = DateTime.utc(2026, 10, 20, 12);

/// Photo number [n] (a Danaview file, `fe_` id).
PhotoMediaItem photo(int n, {String? uri, String mimeType = 'image/jpeg'}) => PhotoMediaItem(
      id: ItemId.opaque('fe_photo$n'),
      uri: uri ?? '/library/files/photo$n.jpg',
      name: 'Photo $n.jpg',
      modifiedAt: fixtureDate,
      mimeType: mimeType,
      width: 4032,
      height: 3024,
    );

/// Video number [n].
VideoMediaItem video(int n) => VideoMediaItem(
      id: ItemId.opaque('fe_video$n'),
      uri: '/library/files/video$n.mp4',
      name: 'Video $n.mp4',
      modifiedAt: fixtureDate,
      mimeType: 'video/mp4',
      duration: Duration(seconds: 30 + n),
    );

/// Document number [n].
DocumentItem document(int n) => DocumentItem(
      id: ItemId.opaque('fe_doc$n'),
      uri: '/library/files/doc$n.pdf',
      name: 'Doc $n.pdf',
      modifiedAt: fixtureDate,
      mimeType: 'application/pdf',
      docKind: DocumentKind.pdf,
      pageCount: 3,
    );
