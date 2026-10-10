// OWNER: CORE-17
//
// Marker commands (ARCH §7.2, domain.md §4.10): `AddMarker`, `UpdateMarker`, `DeleteMarker`.
//
// Markers sit on the frame grid (times are quantized to the nearest frame, 0 … 24 h) and are
// kept sorted by time (equal times keep their order). The name is trimmed (at most
// [maxMarkerNameLength] graphemes), `colorIndex` is one of the [markerPaletteSize] palette
// colours (ux.md §8.5: 6 user colours), the note is optional free text (at most
// [maxMarkerNoteLength] graphemes; blank means none). Markers are not on lanes, so lane locks do
// not apply.

part of '../edit_command.dart';

/// Marker colours of the editor palette (`Marker.colorIndex` is `0 … markerPaletteSize − 1`).
const int markerPaletteSize = 6;

/// Longest marker name, in graphemes.
const int maxMarkerNameLength = 60;

/// Longest marker note, in graphemes.
const int maxMarkerNoteLength = 1000;

const Object _markerUnchanged = Object();

/// [time] on the grid, or an `InvalidValue('time')` refusal.
TimeUs _markerTime(_Draft d, TimeUs time) {
  if (time < 0 || time > maxProjectDurationUs) d.reject(const InvalidValue('time'));
  final t = d.rate.quantizeNearest(time);
  if (t > maxProjectDurationUs) d.reject(const InvalidValue('time'));
  return t;
}

void _checkMarkerFields(_Draft d, {String? name, int? colorIndex, String? note}) {
  if (name != null && name.trim().characters.length > maxMarkerNameLength) d.reject(const InvalidValue('name'));
  if (colorIndex != null && (colorIndex < 0 || colorIndex >= markerPaletteSize)) d.reject(const InvalidValue('colorIndex'));
  if (note != null && note.characters.length > maxMarkerNoteLength) d.reject(const InvalidValue('note'));
}

/// [markers] sorted by time (stable).
List<Marker> _sortedMarkers(Iterable<Marker> markers) {
  final list = markers.toList();
  final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
  indexed.sort((a, b) {
    final c = a.$2.time.compareTo(b.$2.time);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}

/// Adds a marker at [time] (quantized to the nearest frame).
///
/// Rejections: `InvalidValue` (`time` outside 0 … 24 h, `name`, `colorIndex`, `note`).
final class AddMarker extends EditCommand {
  /// Creates the command.
  const AddMarker(this.time, {this.name = '', this.colorIndex = 0, this.note});

  /// Marker time.
  final TimeUs time;

  /// Name (may be empty).
  final String name;

  /// Palette index.
  final int colorIndex;

  /// Optional note.
  final String? note;

  @override
  String get label => 'Add marker';

  @override
  void _apply(_Draft d) {
    final t = _markerTime(d, time);
    _checkMarkerFields(d, name: name, colorIndex: colorIndex, note: note);
    final trimmedNote = note?.trim();
    final marker = Marker(
      id: d.ids.markerId(),
      time: t,
      name: name.trim(),
      colorIndex: colorIndex,
      note: trimmedNote == null || trimmedNote.isEmpty ? null : note,
    );
    d.markers = _sortedMarkers([...d.markers, marker]);
  }

  @override
  String toString() => 'AddMarker($time, "$name")';
}

/// Changes a marker: any of its time (moved, quantized), name, colour and note. A null argument
/// keeps the field; pass `note: null` to clear the note. Changing nothing is a no-op.
///
/// Rejections: `ItemNotFound`, `InvalidValue` (`time`, `name`, `colorIndex`, `note`).
final class UpdateMarker extends EditCommand {
  /// Creates the command.
  const UpdateMarker(this.marker, {this.time, this.name, this.colorIndex, this.note = _markerUnchanged});

  /// The marker.
  final MarkerId marker;

  /// New time, or null to keep it.
  final TimeUs? time;

  /// New name, or null to keep it.
  final String? name;

  /// New palette index, or null to keep it.
  final int? colorIndex;

  /// New note (`String`), `null` to clear it, or left out to keep it.
  final Object? note;

  @override
  String get label => time != null && name == null && colorIndex == null && identical(note, _markerUnchanged) ? 'Move marker' : 'Edit marker';

  @override
  void _apply(_Draft d) {
    final index = d.markers.indexWhere((m) => m.id == marker);
    if (index < 0) d.reject(ItemNotFound(marker.value));
    final old = d.markers[index];
    final n = note;
    if (n != null && n is! String && !identical(n, _markerUnchanged)) d.reject(const InvalidValue('note'));
    _checkMarkerFields(d, name: name, colorIndex: colorIndex, note: n is String ? n : null);
    final t = time == null ? old.time : _markerTime(d, time!);
    Object? nextNote = old.note;
    if (!identical(n, _markerUnchanged)) {
      nextNote = n == null || (n as String).trim().isEmpty ? null : n;
    }
    final next = old.copyWith(time: t, name: name?.trim(), colorIndex: colorIndex, note: nextNote);
    if (next == old) return;
    final list = [...d.markers]..[index] = next;
    d.markers = _sortedMarkers(list);
  }

  @override
  String toString() => 'UpdateMarker($marker, time: $time, name: $name, colorIndex: $colorIndex)';
}

/// Deletes a marker.
///
/// Rejections: `ItemNotFound`.
final class DeleteMarker extends EditCommand {
  /// Creates the command.
  const DeleteMarker(this.marker);

  /// The marker.
  final MarkerId marker;

  @override
  String get label => 'Delete marker';

  @override
  void _apply(_Draft d) {
    if (d.markers.every((m) => m.id != marker)) d.reject(ItemNotFound(marker.value));
    d.markers = [for (final m in d.markers) if (m.id != marker) m];
  }

  @override
  String toString() => 'DeleteMarker($marker)';
}
