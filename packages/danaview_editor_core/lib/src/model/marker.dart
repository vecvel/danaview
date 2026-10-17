// OWNER: CORE-03

import 'package:meta/meta.dart';

import '../ids/ids.dart';
import '../time/time.dart';

const Object _keep = Object();

/// A timeline marker (on the frame grid). Markers are snap targets and edit points.
@immutable
final class Marker {
  /// Creates a marker.
  const Marker({required this.id, required this.time, this.name = '', this.colorIndex = 0, this.note});

  /// Stable id.
  final MarkerId id;

  /// Timeline time (on grid).
  final TimeUs time;

  /// User label (may be empty).
  final String name;

  /// Index into the editor's marker palette.
  final int colorIndex;

  /// Optional free text.
  final String? note;

  /// A copy with the given fields replaced; pass `note: null` to clear the note.
  Marker copyWith({TimeUs? time, String? name, int? colorIndex, Object? note = _keep}) => Marker(
        id: id,
        time: time ?? this.time,
        name: name ?? this.name,
        colorIndex: colorIndex ?? this.colorIndex,
        note: identical(note, _keep) ? this.note : note as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is Marker &&
      other.id == id &&
      other.time == time &&
      other.name == name &&
      other.colorIndex == colorIndex &&
      other.note == note;

  @override
  int get hashCode => Object.hash(id, time, name, colorIndex, note);
}
