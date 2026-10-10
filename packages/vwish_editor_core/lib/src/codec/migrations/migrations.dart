// OWNER: CORE-23
//
// Schema classification and the migration framework (ARCH §8.5, D-12).
//
// A `.vwproj` header carries two integers: `schema` (the body format; increments on every format
// change) and `minReader` (the oldest reader that can still read the document; increments only
// when an older app would misread). [Migrations] decides from the **header alone** what this build
// may do with a document ([SchemaCompatibility]; the body is never parsed for that decision) and
// upgrades older bodies by running a chain of pure, idempotent functions on raw JSON maps
// (`s<N> → s<N+1>`) in the decode isolate, before `ProjectJsonCodec.decodeJson`.
//
// Rules of the framework:
// - Opening never writes. A migration only produces an in-memory body; the repository (CORE-25)
//   copies the original document to `backups/pre-migration-s<N>.vwproj` on the first save after a
//   migration ([Migrations.needsPreMigrationBackup], [Migrations.preMigrationBackupName]) and
//   reports `LoadedProject.migratedFrom` ([MigrationResult.migratedFrom]).
// - A [MigrationStep] receives a private deep copy of the body and may mutate and return it; the
//   caller's map is never touched. A step must be idempotent (running it on a body that already
//   has the target shape returns an equal body) and must keep keys it does not know (the later
//   steps and the decoder decide what to do with them).
// - v1 ships the framework with an empty production chain (schema 1 is the first shipped schema)
//   plus the test-only [testMigrationS0ToS1] that exercises every part of it (see
//   `test/codec_migrations/`).

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../schema_version.dart';

part 's0_to_s1.dart';

/// What this build may do with a stored document, decided from its header alone (D-12).
enum SchemaCompatibility {
  /// Written with the schema this build writes: decode directly.
  current,

  /// Written by an older schema this build can migrate: run the chain, decode, and take a
  /// pre-migration backup on the first save.
  needsMigration,

  /// Written by a newer app (`schema` above this build's) that still lets this build read it
  /// (`minReader` at or below this build's schema): open read-only, never save (saving would drop
  /// the fields this build does not know).
  readOnlyNewer,

  /// Written by a newer app whose `minReader` is above this build's schema: blocked, the user must
  /// update the app.
  needsNewerApp,

  /// Written by an older schema that has no migration path here (a gap in the chain, a negative
  /// number, or a pre-release format): treated as unreadable.
  unsupportedOld,
}

/// The two numbers of a header that decide [SchemaCompatibility].
@immutable
final class SchemaStamp {
  /// Creates a stamp.
  const SchemaStamp({required this.schema, required this.minReader});

  /// The body schema of the document.
  final int schema;

  /// The oldest reader schema that can read the document.
  final int minReader;

  /// The stamp of a parsed header.
  factory SchemaStamp.of(ProjectHeader header) => SchemaStamp(schema: header.schema, minReader: header.minReader);

  /// Reads the stamp from the first line of [document] (or of any prefix containing the first
  /// `\n`): **only the bytes before the first `\n` are decoded**, so a corrupt or huge body is
  /// never touched, and the header may carry fields this build does not know (a newer app may
  /// have added, renamed or dropped any key other than `format`, `schema` and `minReader`).
  /// Throws [ProjectFormatException] when there is no complete, well-formed header line.
  static SchemaStamp readFrom(Uint8List document) {
    final end = ProjectHeader.headerLineEnd(document);
    if (end < 0) throw const ProjectFormatException('no header line');
    final Object? raw;
    try {
      raw = jsonDecode(utf8.decode(Uint8List.sublistView(document, 0, end)));
    } on FormatException {
      throw const ProjectFormatException('header is not JSON');
    }
    if (raw is! Map || raw['format'] != projectFormatName) throw const ProjectFormatException('not a project document', 'format');
    final header = raw;
    int count(String key) {
      final v = header[key];
      if (v is int && v >= 0) return v;
      throw ProjectFormatException('expected a non-negative integer', key);
    }

    return SchemaStamp(schema: count('schema'), minReader: count('minReader'));
  }

  @override
  bool operator ==(Object other) => other is SchemaStamp && other.schema == schema && other.minReader == minReader;

  @override
  int get hashCode => Object.hash(schema, minReader);

  @override
  String toString() => 'SchemaStamp(schema $schema, minReader $minReader)';
}

/// One migration `s<from> → s<from + 1>` on a raw JSON body.
@immutable
final class MigrationStep {
  /// Creates a step. [apply] gets a private deep copy of the body, may mutate and return it, and
  /// must be idempotent.
  const MigrationStep({required this.from, required this.name, required this.apply});

  /// The schema this step upgrades from; it produces `from + 1`.
  final int from;

  /// The schema this step produces.
  int get to => from + 1;

  /// Short stable name for diagnostics, e.g. `s0-to-s1`.
  final String name;

  /// The transformation.
  final Map<String, Object?> Function(Map<String, Object?> body) apply;
}

/// The outcome of [Migrations.migrate].
@immutable
final class MigrationResult {
  /// Creates a result.
  const MigrationResult({required this.body, required this.fromSchema, required this.toSchema, this.applied = const []});

  /// The body in the [toSchema] shape (the input map itself when nothing had to run).
  final Map<String, Object?> body;

  /// The schema of the document that was read.
  final int fromSchema;

  /// The schema of [body].
  final int toSchema;

  /// Names of the steps that ran, in order.
  final List<String> applied;

  /// Whether any step ran.
  bool get migrated => fromSchema != toSchema;

  /// The value for `LoadedProject.migratedFrom`: [fromSchema] when [migrated], else null.
  int? get migratedFrom => migrated ? fromSchema : null;

  /// Whether the first save must copy the original document to
  /// `backups/pre-migration-s<N>.vwproj` before overwriting it (ARCH §8.5).
  bool get needsPreMigrationBackup => migrated;

  /// File name of that backup, or null when nothing was migrated.
  String? get preMigrationBackupName => migrated ? Migrations.preMigrationBackupName(fromSchema) : null;
}

/// Classifies stored documents and migrates their bodies (ARCH §8.5).
@immutable
final class Migrations {
  /// Creates a framework over [chain] migrating to [target] (the schema this build writes).
  ///
  /// The chain must be contiguous: its steps, sorted by `from`, upgrade `a → a+1 → … → target`
  /// with no gap or duplicate, and none may start at or above [target]. [supportedMinReader] is
  /// the highest `minReader` this build can still read (its own schema number).
  Migrations(Iterable<MigrationStep> chain, {this.target = currentProjectSchema, int? supportedMinReader})
      : chain = List.unmodifiable(_validated(chain, target)),
        supportedMinReader = supportedMinReader ?? target;

  /// The migrations this build ships: schema 1 is the first shipped schema, so the chain is empty
  /// and every `schema < 1` document is [SchemaCompatibility.unsupportedOld].
  static final Migrations standard = Migrations(const []);

  /// The steps, ordered by `from`.
  final List<MigrationStep> chain;

  /// The schema this build writes and decodes natively.
  final int target;

  /// The highest `minReader` this build can read.
  final int supportedMinReader;

  /// The oldest schema [migrate] accepts ([target] when the chain is empty).
  int get oldestMigratable => chain.isEmpty ? target : chain.first.from;

  /// Classifies [schema] and [minReader] (D-12): `needsNewerApp` when [minReader] is above this
  /// build, `readOnlyNewer` when only [schema] is above it, `current`, `needsMigration` when an
  /// older schema has a path, else `unsupportedOld`.
  SchemaCompatibility classify({required int schema, required int minReader}) {
    if (minReader > supportedMinReader) return SchemaCompatibility.needsNewerApp;
    if (schema > target) return SchemaCompatibility.readOnlyNewer;
    if (schema == target) return SchemaCompatibility.current;
    return schema >= oldestMigratable && schema >= 0 ? SchemaCompatibility.needsMigration : SchemaCompatibility.unsupportedOld;
  }

  /// [classify] for a parsed header.
  SchemaCompatibility classifyHeader(ProjectHeader header) => classify(schema: header.schema, minReader: header.minReader);

  /// [classify] for a document's bytes using only its first line (the body is never parsed).
  /// Throws [ProjectFormatException] when the header line is missing or malformed.
  SchemaCompatibility classifyDocument(Uint8List document) {
    final stamp = SchemaStamp.readFrom(document);
    return classify(schema: stamp.schema, minReader: stamp.minReader);
  }

  /// Whether a document of [documentSchema] must be backed up before its first save by this build.
  bool needsPreMigrationBackup(int documentSchema) => documentSchema < target;

  /// File name of the pre-migration backup of a schema [fromSchema] document.
  static String preMigrationBackupName(int fromSchema) => 'pre-migration-s$fromSchema.vwproj';

  /// Upgrades [body] (a schema [from] body) to [target] by running the chain. The input is never
  /// modified. Throws [ProjectFormatException] when [from] has no path to [target] (newer than
  /// this build, a gap, or below the oldest step) or when a step fails on a malformed body.
  MigrationResult migrate(Map<String, Object?> body, {required int from}) {
    if (from == target) return MigrationResult(body: body, fromSchema: from, toSchema: target);
    if (from > target) throw ProjectFormatException('schema $from is newer than this build supports ($target)');
    if (from < oldestMigratable) throw ProjectFormatException('no migration path from schema $from');
    var current = deepCopyJson(body);
    final applied = <String>[];
    for (final step in chain.skipWhile((s) => s.from < from)) {
      try {
        current = step.apply(current);
      } on ProjectFormatException {
        rethrow;
      } on Object catch (e) {
        throw ProjectFormatException('migration ${step.name} failed: ${e.runtimeType}');
      }
      applied.add(step.name);
    }
    return MigrationResult(body: current, fromSchema: from, toSchema: target, applied: applied);
  }

  static List<MigrationStep> _validated(Iterable<MigrationStep> chain, int target) {
    final steps = chain.toList()..sort((a, b) => a.from.compareTo(b.from));
    for (var i = 0; i < steps.length; i++) {
      if (steps[i].from >= target) throw ArgumentError('migration ${steps[i].name} starts at schema ${steps[i].from}, not below $target');
      if (i > 0 && steps[i].from != steps[i - 1].from + 1) {
        throw ArgumentError('migration chain has a gap or duplicate before ${steps[i].name}');
      }
    }
    if (steps.isNotEmpty && steps.last.to != target) {
      throw ArgumentError('migration chain ends at schema ${steps.last.to}, not $target');
    }
    return steps;
  }
}

/// A deep copy of a JSON tree (maps, lists and scalars). Used so steps never alias the caller's
/// body.
Map<String, Object?> deepCopyJson(Map<String, Object?> json) => _copy(json) as Map<String, Object?>;

Object? _copy(Object? v) => switch (v) {
      Map() => <String, Object?>{for (final e in v.entries) e.key as String: _copy(e.value)},
      List() => <Object?>[for (final e in v) _copy(e)],
      _ => v,
    };
