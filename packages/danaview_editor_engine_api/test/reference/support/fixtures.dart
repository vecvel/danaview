// OWNER: API-03
//
// Locates the package and its shared fixtures (test_fixtures/vectors, test_fixtures/images) for the
// reference tests, independent of the working directory `flutter test` runs in.

import 'dart:convert';
import 'dart:io';

/// The `danaview_editor_engine_api` package root.
Directory packageRoot() {
  var d = Directory.current;
  while (!(File('${d.path}/pubspec.yaml').existsSync() && d.path.endsWith('danaview_editor_engine_api'))) {
    final parent = d.parent;
    if (parent.path == d.path) {
      final nested = Directory('${Directory.current.path}/packages/danaview_editor_engine_api');
      if (nested.existsSync()) return nested;
      throw StateError('package root not found from ${Directory.current.path}');
    }
    d = parent;
  }
  return d;
}

/// `test_fixtures/vectors/<name>` decoded as JSON.
Map<String, Object?> vectorFile(String name) =>
    jsonDecode(File('${packageRoot().path}/test_fixtures/vectors/$name').readAsStringSync()) as Map<String, Object?>;

/// `test_fixtures/images/<path>` as a file.
File imageFixture(String path) => File('${packageRoot().path}/test_fixtures/images/$path');

/// Casts a decoded JSON list to doubles.
List<double> doubles(Object? json) => [for (final v in json! as List<Object?>) (v! as num).toDouble()];

/// Casts a decoded JSON object.
Map<String, Object?> obj(Object? json) => json! as Map<String, Object?>;

/// Casts a decoded JSON list.
List<Object?> list(Object? json) => json! as List<Object?>;

/// A JSON number as a double.
double asDouble(Object? json) => (json! as num).toDouble();
