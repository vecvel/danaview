// OWNER: CORE-04
//
// Items handed over by pickers, drops and the player entry (ARCH §9.1).

import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

const Object _keep = Object();

/// Where an asset came from; drives the import policy (D-13).
enum MediaOrigin {
  /// iOS Photos / Android Photo Picker.
  photos,

  /// iOS Files / Android SAF.
  files,

  /// The app's own "On This Device" library (`Documents`).
  library,

  /// The player's Edit action.
  player,

  /// External drag and drop.
  drop,

  /// Voice recording.
  recorded,

  /// Engine-made rendition or still.
  derived,

  /// Imported support file (LUT).
  imported,
}

/// One picked or dropped item before import.
@immutable
final class PickedMedia {
  /// Creates a picked item.
  const PickedMedia({
    required this.uri,
    required this.displayName,
    this.origin = MediaOrigin.files,
    this.isTemporaryCopy = false,
    this.bookmark,
    this.sizeBytes,
  });

  /// `file://` path or `content://` URI. iOS Photos picks and drops are app-owned copies under
  /// `<cache>/danaview/editor/work/{picks,drops}/` made natively inside the provider callback
  /// (ARCH §9.1).
  final String uri;

  /// File name shown to the user.
  final String displayName;

  /// Source of the item.
  final MediaOrigin origin;

  /// Whether [uri] is an app-owned temporary copy that may be moved into `media/`.
  final bool isTemporaryCopy;

  /// iOS security-scoped bookmark for Files picks.
  final Uint8List? bookmark;

  /// Size when known.
  final int? sizeBytes;

  /// A copy with the given fields replaced; pass `bookmark: null` or `sizeBytes: null` to clear them.
  PickedMedia copyWith({
    String? uri,
    String? displayName,
    MediaOrigin? origin,
    bool? isTemporaryCopy,
    Object? bookmark = _keep,
    Object? sizeBytes = _keep,
  }) =>
      PickedMedia(
        uri: uri ?? this.uri,
        displayName: displayName ?? this.displayName,
        origin: origin ?? this.origin,
        isTemporaryCopy: isTemporaryCopy ?? this.isTemporaryCopy,
        bookmark: identical(bookmark, _keep) ? this.bookmark : bookmark as Uint8List?,
        sizeBytes: identical(sizeBytes, _keep) ? this.sizeBytes : sizeBytes as int?,
      );

  @override
  bool operator ==(Object other) =>
      other is PickedMedia &&
      other.uri == uri &&
      other.displayName == displayName &&
      other.origin == origin &&
      other.isTemporaryCopy == isTemporaryCopy &&
      other.sizeBytes == sizeBytes &&
      const ListEquality<int>().equals(other.bookmark, bookmark);

  @override
  int get hashCode => Object.hash(
      uri, displayName, origin, isTemporaryCopy, sizeBytes, bookmark == null ? null : Object.hashAll(bookmark!));
}

/// Handle passed to `MediaAccessPort.persist` (currently the picked item itself).
typedef PickedMediaHandle = PickedMedia;
