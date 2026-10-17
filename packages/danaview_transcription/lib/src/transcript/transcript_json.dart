// OWNER: AI-10
//
// Strict JSON readers shared by the transcript sub-library (not exported): a wrong type is a
// [FormatException], never a cast error, so corrupt cache files are recognised and regenerated.

import 'package:danaview_editor_core/model.dart';

/// A string, or [FormatException].
String jsonString(Object? v, String name) {
  if (v is String) return v;
  throw FormatException('Expected string for "$name"');
}

/// An integer (a whole double is accepted), or [FormatException].
int jsonInt(Object? v, String name) {
  if (v is int) return v;
  if (v is double && v == v.roundToDouble()) return v.toInt();
  throw FormatException('Expected integer for "$name"');
}

/// A number, or [FormatException].
double jsonDouble(Object? v, String name) {
  if (v is num) return v.toDouble();
  throw FormatException('Expected number for "$name"');
}

/// A list, or [FormatException].
List<Object?> jsonList(Object? v, String name) {
  if (v is List<Object?>) return v;
  throw FormatException('Expected list for "$name"');
}

/// An object, or [FormatException].
Map<String, Object?> jsonMap(Object? v, String name) {
  if (v is Map<String, Object?>) return v;
  if (v is Map) return v.cast<String, Object?>();
  throw FormatException('Expected object for "$name"');
}

/// A `{startUs, endUs}` range, or [FormatException].
TimeRange jsonRange(Map<String, Object?> json) {
  final s = jsonInt(json['startUs'], 'startUs');
  final e = jsonInt(json['endUs'], 'endUs');
  if (e < s) throw const FormatException('Range end before start');
  return TimeRange(s, e);
}
