// OWNER: CORE-23
//
// Fixture handling for the migration tests: every schema keeps `test/fixtures/projects/s<N>/`
// (ARCH §8.5). A schema directory holds `<name>.body.json` (readable source of the body line) and
// the committed `<name>.vwproj` built from it (header + body, real checksums). `regenerate()`
// rebuilds the `.vwproj` files; `fixtures_test.dart` runs it when `REGENERATE_FIXTURES=1` and
// otherwise checks that the committed files are exactly what regeneration would produce.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:vwish_editor_core/store.dart';

/// Root of the schema fixture directories.
const String projectFixtureRoot = 'test/fixtures/projects';

/// One fixture: schema directory, base name, and the fixed header values it was written with.
final class FixtureSpec {
  /// Creates a spec.
  const FixtureSpec(this.schema, this.name, {required this.app, required this.docRevision, required this.saveId});

  /// Schema of the document header (and the directory `s<schema>`).
  final int schema;

  /// File base name.
  final String name;

  /// Header `app`.
  final String app;

  /// Header `docRevision`.
  final int docRevision;

  /// Header `saveId`.
  final String saveId;

  /// Directory of the fixture.
  String get dir => '$projectFixtureRoot/s$schema';

  /// Body source file.
  String get bodyPath => '$dir/$name.body.json';

  /// Committed document.
  String get documentPath => '$dir/$name.vwproj';
}

/// Every committed fixture. Add new schemas' fixtures here when a schema bump lands.
const List<FixtureSpec> allFixtures = [
  FixtureSpec(0, 'minimal', app: '0.9.0+1', docRevision: 1, saveId: 'sv_s0minimal001'),
  FixtureSpec(0, 'rich', app: '0.9.0+2', docRevision: 412, saveId: 'sv_s0rich000001'),
  FixtureSpec(0, 'fractional', app: '0.9.0+2', docRevision: 3, saveId: 'sv_s0fraction01'),
  FixtureSpec(1, 'minimal', app: '1.1.0+3', docRevision: 1, saveId: 'sv_s1minimal001'),
  // s1/kitchen_sink.vwproj is the CORE-22 golden document, copied verbatim (see `regenerate`).
  FixtureSpec(1, 'kitchen_sink', app: '1.1.0+3', docRevision: 9001, saveId: 'sv_kitchen00001'),
];

final DateTime _savedAt = DateTime.utc(2026, 10, 9, 18);

/// The bytes `regenerate` writes for [spec].
Uint8List expectedDocument(FixtureSpec spec) {
  final body = File(spec.bodyPath).readAsStringSync();
  final line = body.endsWith('\n') ? body.substring(0, body.length - 1) : body;
  return VwprojFormat.build(
    Uint8List.fromList(utf8.encode(line)),
    app: spec.app,
    savedAt: _savedAt,
    docRevision: spec.docRevision,
    saveId: spec.saveId,
    schema: spec.schema,
    minReader: spec.schema,
  );
}

/// Rewrites every `.vwproj` fixture from its `.body.json`.
void regenerate() {
  for (final spec in allFixtures) {
    File(spec.documentPath).writeAsBytesSync(expectedDocument(spec));
  }
}

/// Reads a committed document.
Uint8List readDocument(FixtureSpec spec) => File(spec.documentPath).readAsBytesSync();
