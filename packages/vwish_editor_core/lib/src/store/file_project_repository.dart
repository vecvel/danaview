// OWNER: CORE-25
//
// The on-disk project store (ARCH §8.1-8.5): `FileProjectRepository implements ProjectRepository`.
//
// Bundle (`<support>/vwish/editor/projects/<id>/`): `project.vwproj` (+ `.bak`, `tmp-*` from
// `AtomicFile`), `journal/{a,b}.vwproj` and `recovered-<ts>.vwproj` (CORE-26), `meta.json` (the
// Projects-list summary, rebuildable), `refs.json` (GC input, CORE-28), `poster.jpg`,
// `assets/{luts,recordings,stills}/`, `backups/pre-migration-s<N>.vwproj`. No persisted string
// holds an absolute app-container path: locators are relativized by the codec, `meta.json` names
// the poster relative to the bundle and `refs.json` stores root-relative paths (ARCH §8.2).
//
// * **open** = read (main, else newest valid tmp/bak) → classify (D-12) → migrate → decode →
//   repair (validate inside) → recovery check, all in `Isolate.run` (inline over a non-local
//   `StoreFs`). Opening never writes. A second open of the same project fails with
//   `StoreFailure(busy)`; a newer `minReader` with `newerSchema`; no readable copy with `corrupt`.
// * **save** (manual, lifecycle, close) encodes incrementally on the calling isolate with the
//   project's `FragmentCache` and hands the bytes to the [ProjectWriter] (hash + atomic write in
//   the long-lived writer isolate): pre-migration backup on the first save after a migration,
//   main document, poster (lifecycle/close, when a [PosterProvider] is set), `refs.json`,
//   `meta.json`, then the journal is truncated. **autosave** writes the next journal slot
//   (CORE-26 `AutosaveScheduler`). Writes of one project run through one [LatestWinsQueue].
// * **create(fromMedia)** imports through the `MediaPoolService` and derives the settings from the
//   first video ([deriveProjectSettings]); the media is placed on the timeline and the project is
//   still "untouched" (`editCount == 0`) for `findUntouchedProjectFor`.
// * The Projects list scans `projects/*/meta.json` (header-only reads otherwise) and rebuilds a
//   missing or stale `meta.json` / `refs.json` from the document, in an isolate.
// * **delete** renames the bundle into `trash/` (atomic), deletes it through `OwnedFileDeleter`
//   and calls [FileProjectRepository.onProjectDeleted] (the GC hook, CORE-28). Originals are never
//   touched: only the bundle's own files are deleted.

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../codec/migrations/migrations.dart';
import '../codec/project_json.dart';
import '../codec/schema_version.dart';
import '../ids/ids.dart';
import '../model/pool/fingerprint.dart';
import '../model/pool/media_access_port.dart';
import '../model/pool/media_asset.dart';
import '../model/pool/media_locator.dart';
import '../model/pool/media_pool.dart';
import '../model/pool/media_probe.dart';
import '../model/project.dart';
import '../model/settings.dart';
import '../model/timeline.dart';
import '../model/track.dart';
import '../model/view_state.dart';
import '../ops/edit_command.dart';
import '../session/session.dart';
import '../time/time.dart';
import '../validate/validate.dart';
import 'atomic_file.dart';
import 'autosave_scheduler.dart';
import 'gc.dart';
import 'journal.dart';
import 'import_policy.dart';
import 'media_pool_service.dart';
import 'owned_file_deleter.dart';
import 'project_repository.dart';
import 'project_summary.dart';
import 'recovery.dart';
import 'storage_report.dart';
import 'store_fs.dart';
import 'store_roots.dart';
import 'vwproj_format.dart';
import 'writer_isolate.dart';

/// Renders the poster (JPEG bytes) of a session on lifecycle/close saves (engine thumbnail; null
/// when none is available).
typedef PosterProvider = Future<Uint8List?> Function(EditSession session);

/// Warning code: the main document was unreadable and a backup or temporary copy was opened.
const String restoredFromBackupWarning = 'restoredFromBackup';

/// Thrown by `create(fromMedia)` when none of the picked items could be imported.
final class ProjectCreateFailure implements Exception {
  /// Creates the failure with every item's outcome.
  ProjectCreateFailure(List<ImportOutcome> outcomes) : outcomes = List.unmodifiable(outcomes);

  /// Why each item was rejected.
  final List<ImportOutcome> outcomes;

  @override
  String toString() => 'ProjectCreateFailure(${outcomes.length} items, none imported)';
}

// =============================================================================================
// Settings derivation (ARCH §8.4)
// =============================================================================================

/// Snaps `w:h` to a standard ratio within 1%, else the reduced ratio (clamped to 1:4 … 4:1).
AspectRatio snapAspect(int w, int h) {
  if (w <= 0 || h <= 0) return AspectRatio.landscape16x9;
  final r = w / h;
  for (final s in AspectRatio.standard) {
    if ((r / s.value - 1).abs() <= 0.01) return s;
  }
  if (r > 4) return const AspectRatio(4, 1);
  if (r < 0.25) return const AspectRatio(1, 4);
  final g = _gcd(w, h);
  return AspectRatio(w ~/ g, h ~/ g);
}

int _gcd(int a, int b) => b == 0 ? a : _gcd(b, a % b);

/// The supported integer project rate nearest to [fps] (capped at 60; 30 when unknown).
FrameRate snapFrameRate(double? fps) {
  if (fps == null || !fps.isFinite || fps <= 0) return FrameRate.fps30;
  if (fps >= 60) return FrameRate.fps60;
  var best = FrameRate.supportedProjectRates.first;
  for (final r in FrameRate.supportedProjectRates) {
    if ((r - fps).abs() < (best - fps).abs()) best = r;
  }
  return FrameRate(best, 1);
}

/// Base short side for a source whose short side is [sourceShortSide] px: 720 when ≤ 720, 2160
/// when ≥ 2160 and [allow2160], else 1080.
int baseShortSideFor(int sourceShortSide, {bool allow2160 = false}) {
  if (sourceShortSide <= 720) return 720;
  if (sourceShortSide >= 2160 && allow2160) return 2160;
  return 1080;
}

/// Settings derived from the first video's [probe] (defaults when null): aspect, frame rate and
/// base short side (ARCH §8.4). Rotation 90/270 swaps the dimensions.
ProjectSettings deriveProjectSettings(MediaProbe? probe, {bool allow2160 = false}) {
  if (probe == null) return const ProjectSettings();
  var w = probe.width, h = probe.height;
  if (w == null || h == null || w <= 0 || h <= 0) return const ProjectSettings();
  if (probe.rotation % 180 != 0) (w, h) = (h, w);
  final fps = probe.nominalFps ?? probe.nominalFrameRate?.fps;
  return ProjectSettings(
    canvas: CanvasSpec(aspect: snapAspect(w, h), baseShortSide: baseShortSideFor(math.min(w, h), allow2160: allow2160)),
    frameRate: probe.kind == MediaKind.video ? snapFrameRate(fps) : FrameRate.fps30,
  );
}

// =============================================================================================
// meta.json
// =============================================================================================

/// The `meta.json` summary of a bundle (rebuildable from the document; no absolute paths).
@immutable
final class ProjectMetaFile {
  /// Creates the summary.
  const ProjectMetaFile({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    required this.durationUs,
    required this.aspect,
    required this.docRevision,
    required this.saveId,
    required this.schema,
    required this.editCount,
    this.origin = ProjectOrigin.projects,
    this.poster,
    this.missingMediaCount = 0,
    this.bundleBytes = 0,
  });

  /// The summary of [project] saved as [saveId].
  factory ProjectMetaFile.of(
    EditProject project, {
    required String saveId,
    int schema = currentProjectSchema,
    String? poster,
    int missingMediaCount = 0,
    int bundleBytes = 0,
  }) =>
      ProjectMetaFile(
        id: project.id,
        name: project.name,
        createdAt: project.meta.createdAt,
        updatedAt: project.meta.updatedAt,
        durationUs: project.duration,
        aspect: project.settings.canvas.aspect,
        docRevision: project.docRevision,
        saveId: saveId,
        schema: schema,
        editCount: project.meta.editCount,
        origin: project.meta.origin,
        poster: poster,
        missingMediaCount: missingMediaCount,
        bundleBytes: bundleBytes,
      );

  /// Project id.
  final ProjectId id;

  /// Name.
  final String name;

  /// Creation time (UTC).
  final DateTime createdAt;

  /// Last change (UTC).
  final DateTime updatedAt;

  /// Timeline duration.
  final int durationUs;

  /// Canvas aspect.
  final AspectRatio aspect;

  /// `docRevision` of the main document it describes.
  final int docRevision;

  /// `saveId` of the main document it describes (a mismatch means it is stale).
  final String saveId;

  /// Schema of that document.
  final int schema;

  /// Edit count (0 = untouched).
  final int editCount;

  /// Origin.
  final ProjectOrigin origin;

  /// Poster file name relative to the bundle, or null.
  final String? poster;

  /// Assets missing at the last save.
  final int missingMediaCount;

  /// Bytes of the bundle at the last save.
  final int bundleBytes;

  /// A copy with the given fields replaced.
  ProjectMetaFile copyWith({String? name, int? missingMediaCount, int? bundleBytes, String? poster}) => ProjectMetaFile(
        id: id,
        name: name ?? this.name,
        createdAt: createdAt,
        updatedAt: updatedAt,
        durationUs: durationUs,
        aspect: aspect,
        docRevision: docRevision,
        saveId: saveId,
        schema: schema,
        editCount: editCount,
        origin: origin,
        poster: poster ?? this.poster,
        missingMediaCount: missingMediaCount ?? this.missingMediaCount,
        bundleBytes: bundleBytes ?? this.bundleBytes,
      );

  /// Canonical JSON bytes.
  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode({
        'v': 1,
        'id': id,
        'name': name,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        'durationUs': durationUs,
        'aspect': [aspect.w, aspect.h],
        'docRevision': docRevision,
        'saveId': saveId,
        'schema': schema,
        'editCount': editCount,
        'origin': switch (origin) {
          FromPlayerOrigin(:final quickHash, :final sizeBytes, :final displayName) => {
              't': 'player',
              'quickHash': quickHash,
              'sizeBytes': sizeBytes,
              'displayName': displayName,
            },
          _ => {'t': 'projects'},
        },
        'poster': poster,
        'missing': missingMediaCount,
        'bundleBytes': bundleBytes,
      })));

  /// Parses [encode]'s output; null when it is not a valid `meta.json`.
  static ProjectMetaFile? tryDecode(List<int> bytes) {
    try {
      final j = jsonDecode(utf8.decode(bytes));
      if (j is! Map<String, Object?> || j['v'] != 1) return null;
      final aspect = j['aspect']! as List<Object?>;
      final o = j['origin']! as Map<String, Object?>;
      return ProjectMetaFile(
        id: ProjectId(j['id']! as String),
        name: j['name']! as String,
        createdAt: DateTime.parse(j['createdAt']! as String).toUtc(),
        updatedAt: DateTime.parse(j['updatedAt']! as String).toUtc(),
        durationUs: j['durationUs']! as int,
        aspect: AspectRatio(aspect[0]! as int, aspect[1]! as int),
        docRevision: j['docRevision']! as int,
        saveId: j['saveId']! as String,
        schema: j['schema']! as int,
        editCount: j['editCount']! as int,
        origin: o['t'] == 'player'
            ? FromPlayerOrigin(
                quickHash: o['quickHash']! as String,
                sizeBytes: o['sizeBytes']! as int,
                displayName: (o['displayName'] as String?) ?? '',
              )
            : ProjectOrigin.projects,
        poster: j['poster'] as String?,
        missingMediaCount: (j['missing'] as int?) ?? 0,
        bundleBytes: (j['bundleBytes'] as int?) ?? 0,
      );
    } on Object {
      return null;
    }
  }
}

// =============================================================================================
// Isolate work (top-level so closures capture only sendable values)
// =============================================================================================

/// What `open` reads (crosses the isolate boundary with `Isolate.exit`).
final class _Loaded {
  _Loaded({
    required this.health,
    this.project,
    this.warnings = const [],
    this.migratedFrom,
    this.header,
    this.readPath,
    this.pending,
  });

  final ProjectHealth health;
  final EditProject? project;
  final List<ProjectOpenWarning> warnings;
  final int? migratedFrom;
  final ProjectHeader? header;
  final String? readPath;
  final RecoverableSession? pending;
}

Future<_Loaded> _loadProject(StoreFs fs, StoreRoots roots, Migrations migrations, String id) async {
  final dir = roots.projectDir(id);
  if ((await fs.stat(dir)).type != StoreEntityType.directory) {
    throw const StoreFailure(StoreFailureKind.notFound, 'project');
  }
  final deleter = OwnedFileDeleter(roots, fs: fs, assertOnViolation: false);
  final recovery = ProjectRecovery(dir, fs: fs, deleter: deleter);
  final VwprojRead read;
  try {
    read = await VwprojFiles(fs: fs).read(recovery.mainPath);
  } on StoreFailure catch (e) {
    if (e.kind != StoreFailureKind.corrupt && e.kind != StoreFailureKind.notFound) rethrow;
    final c = await recovery.inspect(mainKnown: true);
    if (c == null && e.kind == StoreFailureKind.notFound) rethrow;
    return _Loaded(health: ProjectHealth.corrupt, pending: c?.toSession(ProjectId(id)));
  }
  final header = read.document.header;
  final compat = migrations.classifyHeader(header);
  if (compat == SchemaCompatibility.needsNewerApp) return _Loaded(health: ProjectHealth.needsNewerApp, header: header);
  if (compat == SchemaCompatibility.unsupportedOld) return _Loaded(health: ProjectHealth.corrupt, header: header);
  final EditProject project;
  final warnings = <ProjectOpenWarning>[];
  int? migratedFrom;
  try {
    final raw = jsonDecode(utf8.decode(read.document.body));
    if (raw is! Map<String, Object?>) throw const ProjectFormatException('body is not an object');
    var body = raw;
    if (compat == SchemaCompatibility.needsMigration) {
      final m = migrations.migrate(raw, from: header.schema);
      body = m.body;
      migratedFrom = m.migratedFrom;
    }
    final decoded = ProjectJsonCodec(relativize: roots.relativize).decodeJson(body);
    warnings.addAll(decoded.warnings);
    final (repaired, fixes) = repair(decoded.project);
    warnings.addAll(fixes);
    project = repaired;
  } on FormatException {
    return _Loaded(health: ProjectHealth.corrupt, header: header);
  }
  if (read.source != AtomicSource.main) warnings.add(const ProjectOpenWarning(restoredFromBackupWarning));
  final candidate = await recovery.inspect(main: header, mainKnown: true);
  return _Loaded(
    health: compat == SchemaCompatibility.readOnlyNewer ? ProjectHealth.readOnlyNewer : ProjectHealth.ok,
    project: project,
    warnings: warnings,
    migratedFrom: migratedFrom,
    header: header,
    readPath: read.path,
    pending: candidate?.toSession(ProjectId(id)),
  );
}

/// One scanned bundle.
final class _Scanned {
  _Scanned(this.id, this.summary, this.meta, this.refs, this.untouchedOrigin);

  final ProjectId id;
  final ProjectSummary summary;
  final ProjectMetaFile? meta;
  final ProjectRefs? refs;
  final FromPlayerOrigin? untouchedOrigin;
}

Future<List<_Scanned>> _scanProjects(StoreFs fs, StoreRoots roots, Migrations migrations, List<String>? only) async {
  final ids = <String>[];
  if (only != null) {
    ids.addAll(only);
  } else if ((await fs.stat(roots.projectsDir)).type == StoreEntityType.directory) {
    for (final e in await fs.list(roots.projectsDir)) {
      if (e.type == StoreEntityType.directory) ids.add(p.basename(e.path));
    }
  }
  final out = <_Scanned>[];
  for (final id in ids) {
    final s = await _scanProject(fs, roots, migrations, id);
    if (s != null) out.add(s);
  }
  return out;
}

Future<_Scanned?> _scanProject(StoreFs fs, StoreRoots roots, Migrations migrations, String id) async {
  final dir = roots.projectDir(id);
  if ((await fs.stat(dir)).type != StoreEntityType.directory) return null;
  final deleter = OwnedFileDeleter(roots, fs: fs, assertOnViolation: false);
  final atomic = AtomicFile(fs: fs, deleter: deleter);
  final mainPath = p.join(dir, 'project.vwproj');
  final files = VwprojFiles(fs: fs, atomic: atomic);

  ProjectHeader? header;
  VwprojRead? full;
  try {
    header = await files.readHeader(mainPath);
  } on Object {
    try {
      full = await files.read(mainPath);
      header = full.document.header;
    } on Object {
      header = null;
    }
  }
  if (header == null &&
      !(await fs.stat(mainPath)).exists &&
      !(await fs.stat(AtomicFile.backupPath(mainPath))).exists &&
      !(await ProjectJournal(dir, fs: fs, deleter: deleter).hasSlots())) {
    return null; // a bundle whose first write never completed is not a project
  }
  var health = ProjectHealth.corrupt;
  if (header != null) {
    health = switch (migrations.classifyHeader(header)) {
      SchemaCompatibility.needsNewerApp => ProjectHealth.needsNewerApp,
      SchemaCompatibility.readOnlyNewer => ProjectHealth.readOnlyNewer,
      SchemaCompatibility.unsupportedOld => ProjectHealth.corrupt,
      _ => ProjectHealth.ok,
    };
  }

  ProjectMetaFile? meta;
  final metaPath = p.join(dir, 'meta.json');
  try {
    if ((await fs.stat(metaPath)).type == StoreEntityType.file) meta = ProjectMetaFile.tryDecode(await fs.readBytes(metaPath));
  } on StoreFailure {
    meta = null;
  }
  ProjectRefs? refs;
  final refsPath = p.join(dir, 'refs.json');
  try {
    if ((await fs.stat(refsPath)).type == StoreEntityType.file) refs = ProjectRefs.decode(await fs.readBytes(refsPath));
  } on Object {
    refs = null;
  }

  final stale = meta == null || header == null || meta.saveId != header.saveId;
  if (header != null && (stale || refs == null) && health != ProjectHealth.needsNewerApp) {
    // Rebuild from the document.
    try {
      full ??= await files.read(mainPath);
      final raw = jsonDecode(utf8.decode(full.document.body)) as Map<String, Object?>;
      var body = raw;
      if (migrations.classifyHeader(header) == SchemaCompatibility.needsMigration) {
        body = migrations.migrate(raw, from: header.schema).body;
      }
      final project = ProjectJsonCodec(relativize: roots.relativize).decodeJson(body).project;
      if (stale) {
        final bundleBytes = await _treeBytes(fs, dir);
        final hasPoster = (await fs.stat(p.join(dir, 'poster.jpg'))).type == StoreEntityType.file;
        meta = ProjectMetaFile.of(
          project,
          saveId: header.saveId,
          schema: header.schema,
          poster: hasPoster ? 'poster.jpg' : null,
          missingMediaCount: meta?.missingMediaCount ?? 0,
          bundleBytes: bundleBytes,
        );
        await atomic.write(metaPath, meta.encode());
      }
      if (refs == null) {
        refs = ProjectRefs.ofProject(project);
        await atomic.write(refsPath, refs.encode());
      }
    } on Object {
      if (meta == null) health = ProjectHealth.corrupt;
    }
  }

  // Recovery (header-only check; `recoverable()` verifies checksums).
  var hasRecovery = false;
  for (final slot in ['a', 'b']) {
    final path = p.join(dir, 'journal', '$slot.vwproj');
    if ((await fs.stat(path)).type != StoreEntityType.file) continue;
    try {
      final jh = await files.readHeader(path);
      if (isRecoverableOver(jh, header)) hasRecovery = true;
    } on Object {
      // A torn slot recovers nothing.
    }
  }

  final m = meta;
  final summary = ProjectSummary(
    id: ProjectId(id),
    name: m?.name ?? 'Untitled project',
    updatedAt: m?.updatedAt ?? header?.savedAt ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    duration: m?.durationUs ?? 0,
    aspect: m?.aspect ?? AspectRatio.landscape16x9,
    thumbnailPath: m?.poster == null ? null : p.join(dir, m!.poster),
    missingMediaCount: m?.missingMediaCount ?? 0,
    hasRecovery: hasRecovery,
    bytesOwned: m?.bundleBytes ?? 0,
    health: health,
  );
  final origin = m?.origin;
  return _Scanned(
    ProjectId(id),
    summary,
    m,
    refs,
    origin is FromPlayerOrigin && m!.editCount == 0 && health == ProjectHealth.ok ? origin : null,
  );
}

// Isolate entry points: built in top-level scope so the closure sent to `Isolate.run` captures
// only these (sendable) parameters, never a repository instance. [fs] null = run in an isolate
// on the real file system.

Future<_Loaded> _loadOff(StoreFs? fs, StoreRoots roots, Migrations m, String id) =>
    fs != null ? _loadProject(fs, roots, m, id) : Isolate.run(() => _loadProject(const LocalStoreFs(), roots, m, id));

Future<List<_Scanned>> _scanOff(StoreFs? fs, StoreRoots roots, Migrations m, List<String>? only) => fs != null
    ? _scanProjects(fs, roots, m, only)
    : Isolate.run(() => _scanProjects(const LocalStoreFs(), roots, m, only));

Future<ProjectStorageReport> _reportOff(StoreFs? fs, StoreRoots roots) =>
    fs != null ? _storageReport(fs, roots) : Isolate.run(() => _storageReport(const LocalStoreFs(), roots));

Future<int> _treeBytes(StoreFs fs, String path) async {
  final s = await fs.stat(path);
  if (s.type == StoreEntityType.file) return s.size;
  if (s.type != StoreEntityType.directory) return 0;
  var n = 0;
  for (final e in await fs.list(path)) {
    n += await _treeBytes(fs, e.path);
  }
  return n;
}

Future<ProjectStorageReport> _storageReport(StoreFs fs, StoreRoots roots) async {
  var count = 0;
  if ((await fs.stat(roots.projectsDir)).type == StoreEntityType.directory) {
    count = (await fs.list(roots.projectsDir)).where((e) => e.type == StoreEntityType.directory).length;
  }
  return ProjectStorageReport(
    projectCount: count,
    projectBundlesBytes: await _treeBytes(fs, roots.projectsDir),
    managedMediaBytes: await _treeBytes(fs, roots.mediaDir),
    derivedBytes: await _treeBytes(fs, roots.derivedDir),
    cacheBytes: await _treeBytes(fs, roots.editorCache),
  );
}

// =============================================================================================
// The repository
// =============================================================================================

/// State of one open project.
final class _Open {
  _Open(this.id, this.dir, this.codec, this.queue);

  final ProjectId id;
  final String dir;
  final ProjectJsonCodec codec;
  final LatestWinsQueue<SaveReceipt> queue;
  AutosaveScheduler? scheduler;
  EditSession? session;
  EditProject? loaded;
  String? mainSaveId;
  int mainRevision = 0;
  int persistedRevision = -1;
  bool readOnly = false;
  int? migratedFrom;
  String? originalPath;
  RecoverableSession? pending;
  bool posterWanted = false;
  ProjectRefs mainRefs = ProjectRefs.empty;
  MediaPool? refsPool;
  int missingMediaCount = 0;
  SaveReceipt? lastReceipt;
}

/// The production [ProjectRepository] (see the file header).
final class FileProjectRepository implements ProjectRepository {
  /// Creates the repository over [roots].
  ///
  /// [fs] defaults to the real file system; [useIsolates] (default: [fs] is a `LocalStoreFs`)
  /// runs open/scan in `Isolate.run` and writes in a long-lived writer isolate. [writer]
  /// overrides the writer. [media] imports for `create(fromMedia)`; [access] fingerprints files
  /// for [findUntouchedProjectFor]. [allow2160] is the capability for 2160 p projects. [poster]
  /// renders posters. [onProjectDeleted] is the GC hook. [timer] and [clock] drive autosave.
  FileProjectRepository({
    required this.roots,
    StoreFs fs = const LocalStoreFs(),
    OwnedFileDeleter? deleter,
    bool? useIsolates,
    ProjectWriter? writer,
    this.media,
    this.access,
    IdGenerator? ids,
    DateTime Function()? clock,
    Migrations? migrations,
    this.appVersion = '1.1.0',
    this.allow2160 = false,
    this.poster,
    this.onProjectDeleted,
    this.autosavePolicy = const AutosavePolicy(),
    StoreTimerFactory? timer,
  })  : _fs = fs,
        deleter = deleter ?? OwnedFileDeleter(roots, fs: fs),
        useIsolates = useIsolates ?? fs is LocalStoreFs,
        _writerOverride = writer,
        _ids = ids ?? SecureIdGenerator(),
        _clock = clock ?? _utcNow,
        migrations = migrations ?? Migrations.standard,
        _timer = timer;

  static DateTime _utcNow() => DateTime.now().toUtc();

  /// App roots.
  final StoreRoots roots;

  /// The deletion guard.
  final OwnedFileDeleter deleter;

  /// Whether open/scan run in isolates and writes in the writer isolate.
  final bool useIsolates;

  /// Importer for `create(fromMedia)` (null: such creates fail with `StoreFailure(io)`).
  final MediaPoolService? media;

  /// Port used to fingerprint files for [findUntouchedProjectFor].
  final MediaAccessPort? access;

  /// Migration framework.
  final Migrations migrations;

  /// App version written into headers.
  final String appVersion;

  /// Whether 2160 p projects are allowed (capability).
  final bool allow2160;

  /// Poster renderer.
  final PosterProvider? poster;

  /// GC hook after a delete.
  final ProjectDeletedHook? onProjectDeleted;

  /// Autosave timing.
  final AutosavePolicy autosavePolicy;

  final StoreFs _fs;
  final ProjectWriter? _writerOverride;
  final IdGenerator _ids;
  final DateTime Function() _clock;
  final StoreTimerFactory? _timer;
  final Map<ProjectId, _Open> _open = {};
  final Set<ProjectId> _opening = {};
  Future<ProjectWriter>? _writer;

  final Map<ProjectId, _Scanned> _scanned = {};
  bool _scannedAll = false;
  Future<void>? _scanning;
  Future<void> _rescans = Future.value();
  final List<StreamController<List<ProjectSummary>>> _listeners = [];

  // ------------------------------------------------------------------------------------------
  // Infrastructure
  // ------------------------------------------------------------------------------------------

  Future<ProjectWriter> get _w => _writer ??= () async {
        final o = _writerOverride;
        if (o != null) return o;
        if (useIsolates) return IsolateProjectWriter.spawn(roots);
        return InlineProjectWriter(fs: _fs, deleter: deleter);
      }();

  /// The file system for inline work, or null to run it in an isolate.
  StoreFs? get _inline => useIsolates ? null : _fs;

  String _mainPath(String dir) => p.join(dir, 'project.vwproj');

  DocumentStamp _stamp(EditProject project, String saveId, {String? baseSaveId}) => DocumentStamp(
        app: appVersion,
        savedAt: _clock(),
        docRevision: project.docRevision,
        saveId: saveId,
        baseSaveId: baseSaveId,
      );

  /// Sessions of open projects (the GC's `openSessions`).
  Iterable<EditSession> get openSessions => [
        for (final s in _open.values)
          if (s.session != null) s.session!,
      ];

  /// Projects opened without a session yet (the GC's `openProjects`).
  Iterable<EditProject> get openProjects => [
        for (final s in _open.values)
          if (s.session == null && s.loaded != null) s.loaded!,
      ];

  /// Ids of open projects.
  Set<ProjectId> get openIds => Set.unmodifiable(_open.keys);

  /// The autosave state of open project [id] (the editor's `SaveStatus`).
  Stream<AutosaveStatus> watchAutosave(ProjectId id) {
    final st = _open[id];
    if (st == null) return const Stream.empty();
    return _schedulerOf(st).statuses;
  }

  /// Notes the availability of open project [id] (stored as `missingMediaCount` on the next save).
  void noteMissingMedia(ProjectId id, int count) {
    final st = _open[id];
    if (st != null) st.missingMediaCount = count;
  }

  /// Stops the writer isolate and every autosave timer.
  Future<void> dispose() async {
    for (final id in [..._open.keys]) {
      await close(id);
    }
    final w = _writer;
    if (w != null) await (await w).close();
    for (final c in [..._listeners]) {
      await c.close();
    }
  }

  // ------------------------------------------------------------------------------------------
  // Summaries
  // ------------------------------------------------------------------------------------------

  @override
  Stream<List<ProjectSummary>> watchSummaries() {
    late final StreamController<List<ProjectSummary>> c;
    c = StreamController<List<ProjectSummary>>(
      onListen: () {
        _listeners.add(c);
        unawaited(_ensureScanned().then((_) {
          if (!c.isClosed) c.add(_summaries());
        }, onError: (Object e, StackTrace s) {
          if (!c.isClosed) c.addError(e, s);
        }));
      },
      onCancel: () {
        _listeners.remove(c);
      },
    );
    return c.stream;
  }

  /// The current summaries (scanning first when needed).
  Future<List<ProjectSummary>> summaries() async {
    await _ensureScanned();
    return _summaries();
  }

  Future<void> _ensureScanned() {
    if (_scannedAll) return _rescans;
    return _scanning ??= () async {
      try {
        await _rescans;
        final all = await _scanOff(_inline, roots, migrations, null);
        _scanned
          ..clear()
          ..addEntries(all.map((s) => MapEntry(s.id, s)));
        _scannedAll = true;
      } finally {
        _scanning = null;
      }
    }();
  }

  /// Queues a rescan of [id] (the summaries wait for queued rescans).
  Future<void> _rescan(ProjectId id) => _rescans = _rescans.then((_) => _rescanNow(id)).catchError((Object _) {});

  Future<void> _rescanNow(ProjectId id) async {
    if (!_scannedAll) {
      _emit();
      return;
    }
    final one = await _scanOff(_inline, roots, migrations, [id]);
    if (one.isEmpty) {
      _scanned.remove(id);
    } else {
      _scanned[id] = one.single;
    }
    _emit();
  }

  void _emit() {
    if (_listeners.isEmpty || !_scannedAll) return;
    final list = _summaries();
    for (final c in [..._listeners]) {
      if (!c.isClosed) c.add(list);
    }
  }

  List<ProjectSummary> _summaries() {
    // bytesOwned = bundle + managed copies referenced by this project only.
    final users = <String, int>{};
    for (final s in _scanned.values) {
      for (final d in s.refs?.managed.keys ?? const <String>[]) {
        users[d] = (users[d] ?? 0) + 1;
      }
    }
    final out = [
      for (final s in _scanned.values)
        _withBytes(
          s.summary,
          s.summary.bytesOwned +
              [
                for (final e in s.refs?.managed.entries ?? const <MapEntry<String, int>>[])
                  if (users[e.key] == 1) e.value,
              ].fold<int>(0, (a, b) => a + b),
          hasRecovery: s.summary.hasRecovery && !_open.containsKey(s.id),
        ),
    ]..sort((a, b) {
        final t = b.updatedAt.compareTo(a.updatedAt);
        return t != 0 ? t : a.id.compareTo(b.id);
      });
    return List.unmodifiable(out);
  }

  static ProjectSummary _withBytes(ProjectSummary s, int bytes, {required bool hasRecovery}) => ProjectSummary(
        id: s.id,
        name: s.name,
        updatedAt: s.updatedAt,
        duration: s.duration,
        aspect: s.aspect,
        thumbnailPath: s.thumbnailPath,
        missingMediaCount: s.missingMediaCount,
        hasRecovery: hasRecovery,
        bytesOwned: bytes,
        health: s.health,
      );

  // ------------------------------------------------------------------------------------------
  // Create
  // ------------------------------------------------------------------------------------------

  @override
  Future<ProjectId> create(NewProjectSpec spec) async {
    final id = _ids.projectId();
    final now = _clock();
    switch (spec) {
      case EmptyProjectSpec(:final name, :final canvas):
        final project = EditProject(
          id: id,
          meta: ProjectMeta(name: _checkedName(name), createdAt: now, updatedAt: now),
          timeline: Timeline(
            settings: ProjectSettings(canvas: canvas ?? const CanvasSpec()),
            tracks: [Track(id: _ids.trackId(), kind: TrackKind.video, isMain: true)],
          ),
        );
        await writeNewProject(project);
      case FromMediaProjectSpec():
        await writeNewProject(await _fromMedia(id, spec, now));
    }
    return id;
  }

  Future<EditProject> _fromMedia(ProjectId id, FromMediaProjectSpec spec, DateTime now) async {
    final importer = media;
    if (importer == null) throw const StoreFailure(StoreFailureKind.io, 'no media service');
    final name = _checkedName(spec.name);
    final mainTrack = Track(id: _ids.trackId(), kind: TrackKind.video, isMain: true);
    final empty = EditProject(
      id: id,
      meta: ProjectMeta(name: name, createdAt: now, updatedAt: now, origin: spec.origin),
      timeline: Timeline(tracks: [mainTrack]),
    );
    final importSession = EditSession(empty, ids: _ids, clock: _clock);
    final outcomes = await importer.import(importSession, spec.picks);
    final imported = [
      for (final o in outcomes)
        if (o is ImportedMedia && o.asset.kind != MediaKind.lut) o.asset,
    ];
    if (imported.isEmpty) {
      await deleter.delete(roots.projectDir(id), recursive: true); // LUTs or partial files
      throw ProjectCreateFailure(outcomes);
    }
    MediaProbe? first;
    for (final a in imported) {
      if (a.kind == MediaKind.video) {
        first = a.probe;
        break;
      }
    }
    first ??= imported.where((a) => a.kind == MediaKind.image).map((a) => a.probe).firstOrNull;
    final settings = deriveProjectSettings(first, allow2160: allow2160);
    final pool = importSession.committedProject.pool;
    final base = empty.copyWith(timeline: Timeline(settings: settings, tracks: [mainTrack]), pool: pool);
    final placing = EditSession(base, ids: _ids, clock: _clock);
    final seen = <MediaId>{};
    placing.apply(InsertMedia([for (final a in imported) if (seen.add(a.id)) a.id], 0));
    final placed = placing.committedProject;
    return EditProject(
      id: id,
      meta: placed.meta.copyWith(editCount: 0, updatedAt: now),
      timeline: placed.timeline,
      pool: placed.pool,
      view: ViewState(playhead: settings.frameRate.quantize(spec.initialPlayhead < 0 ? 0 : spec.initialPlayhead)),
    );
  }

  /// Writes [project] as a new, closed bundle (main + meta + refs). Fails with `busy` when a
  /// bundle with its id is open.
  Future<ProjectId> writeNewProject(EditProject project) async {
    if (_open.containsKey(project.id)) throw const StoreFailure(StoreFailureKind.busy, 'project open');
    final dir = roots.projectDir(project.id);
    final body = ProjectJsonCodec(relativize: roots.relativize).encodeBytes(project);
    await _writeMain(dir, project, body, ProjectRefs.ofProject(project));
    await _rescan(project.id);
    return project.id;
  }

  /// Writes main, refs and meta of a closed project; returns the new `saveId`.
  Future<String> _writeMain(String dir, EditProject project, Uint8List body, ProjectRefs refs, {int missing = 0}) async {
    final w = await _w;
    final saveId = _ids.next(IdKind.save);
    await w.writeDocument(_mainPath(dir), body, _stamp(project, saveId));
    await w.writeFile(p.join(dir, 'refs.json'), refs.encode());
    await _writeMeta(dir, project, saveId, missing: missing);
    return saveId;
  }

  Future<void> _writeMeta(String dir, EditProject project, String saveId, {int missing = 0}) async {
    final w = await _w;
    final hasPoster = (await _fs.stat(p.join(dir, 'poster.jpg'))).type == StoreEntityType.file;
    final bytes = await _treeBytes(_fs, dir);
    await w.writeFile(
      p.join(dir, 'meta.json'),
      ProjectMetaFile.of(project, saveId: saveId, poster: hasPoster ? 'poster.jpg' : null, missingMediaCount: missing, bundleBytes: bytes)
          .encode(),
    );
  }

  static String _checkedName(String name) {
    final t = name.trim();
    final n = t.characters.length;
    if (n < 1 || n > 80) throw ArgumentError.value(name, 'name', 'must be 1-80 characters after trim');
    return t;
  }

  // ------------------------------------------------------------------------------------------
  // Open, save, autosave, close
  // ------------------------------------------------------------------------------------------

  @override
  Future<LoadedProject> open(ProjectId id) async {
    if (_open.containsKey(id) || _opening.contains(id)) throw const StoreFailure(StoreFailureKind.busy, 'already open');
    _opening.add(id);
    try {
      final loaded = await _loadOff(_inline, roots, migrations, id);
      switch (loaded.health) {
        case ProjectHealth.needsNewerApp:
          throw const StoreFailure(StoreFailureKind.newerSchema, 'minReader above this app');
        case ProjectHealth.corrupt:
          throw const StoreFailure(StoreFailureKind.corrupt, 'no valid copy');
        case ProjectHealth.ok || ProjectHealth.readOnlyNewer:
          break;
      }
      final project = loaded.project!;
      final st = _Open(id, roots.projectDir(id), ProjectJsonCodec(relativize: roots.relativize), LatestWinsQueue())
        ..loaded = project
        ..mainSaveId = loaded.header?.saveId
        ..mainRevision = loaded.header?.docRevision ?? 0
        ..persistedRevision = loaded.migratedFrom == null && loaded.pending == null ? project.docRevision : -1
        ..readOnly = loaded.health == ProjectHealth.readOnlyNewer
        ..migratedFrom = loaded.migratedFrom
        ..originalPath = loaded.readPath
        ..pending = loaded.pending
        ..mainRefs = ProjectRefs.ofProject(project)
        ..refsPool = project.pool
        ..missingMediaCount = _scanned[id]?.meta?.missingMediaCount ?? 0;
      _open[id] = st;
      _emit();
      return LoadedProject(
        project: project,
        health: loaded.health,
        warnings: loaded.warnings,
        migratedFrom: loaded.migratedFrom,
        pendingRecovery: loaded.pending,
      );
    } finally {
      _opening.remove(id);
    }
  }

  _Open _stateOf(EditSession session) {
    final st = _open[session.project.id];
    if (st == null) throw const StoreFailure(StoreFailureKind.notFound, 'project not open');
    return st;
  }

  @override
  Future<SaveReceipt> save(EditSession session, {required SaveReason reason}) {
    final _Open st;
    try {
      st = _stateOf(session);
    } on StoreFailure catch (e) {
      return Future.error(e);
    }
    if (st.readOnly) return Future.error(const StoreFailure(StoreFailureKind.newerSchema, 'read-only'));
    st.session = session;
    if (reason == SaveReason.autosave) return _enqueueJournal(st);
    if (reason == SaveReason.lifecycle || reason == SaveReason.close) st.posterWanted = true;
    st.scheduler?.cancel();
    return st.queue.enqueue('main', () => _mainSave(st, reason), supersedes: const {'main', 'journal'});
  }

  Future<SaveReceipt> _mainSave(_Open st, SaveReason reason) async {
    final session = st.session!;
    final project = session.project;
    final w = await _w;
    final body = st.codec.encodeBytes(project); // incremental, on this isolate
    final recovery = ProjectRecovery(st.dir, fs: _fs, deleter: deleter);

    await _preMigrationBackup(st.dir, st.migratedFrom, st.originalPath);

    final saveId = _ids.next(IdKind.save);
    final savedAt = _clock();
    await w.writeDocument(_mainPath(st.dir), body, _stamp(project, saveId));
    st
      ..mainSaveId = saveId
      ..mainRevision = project.docRevision
      ..persistedRevision = project.docRevision
      ..migratedFrom = null
      ..originalPath = _mainPath(st.dir);

    if (st.posterWanted) {
      st.posterWanted = false;
      final render = poster;
      if (render != null) {
        try {
          final jpg = await render(session);
          if (jpg != null && jpg.isNotEmpty) await w.writeFile(p.join(st.dir, 'poster.jpg'), jpg);
        } on StoreFailure {
          rethrow;
        } on Object {
          // A poster is decoration: its failure never fails the save.
        }
      }
    }
    final refs = ProjectRefs.ofSession(session);
    await w.writeFile(p.join(st.dir, 'refs.json'), refs.encode());
    st
      ..mainRefs = ProjectRefs.ofProject(project)
      ..refsPool = project.pool;
    await _writeMeta(st.dir, project, saveId, missing: st.missingMediaCount);
    await recovery.journal.truncate();
    st.pending = null;
    final receipt = SaveReceipt(projectId: st.id, docRevision: project.docRevision, saveId: saveId, savedAt: savedAt, reason: reason);
    st.lastReceipt = receipt;
    unawaited(_rescan(st.id));
    return receipt;
  }

  /// Pre-migration backup (ARCH §8.5): copies the original document (as read on open) to
  /// `backups/pre-migration-s<N>.vwproj` before anything of the new schema is written.
  Future<void> _preMigrationBackup(String dir, int? from, String? original) async {
    if (from == null || original == null) return;
    final backup = p.join(dir, 'backups', Migrations.preMigrationBackupName(from));
    await _fs.createDirectory(p.dirname(backup));
    await _fs.copyExclusive(original, backup);
  }

  Future<SaveReceipt> _enqueueJournal(_Open st) =>
      st.queue.enqueue('journal', () => _journalSave(st), supersedes: const {'journal'});

  Future<SaveReceipt> _journalSave(_Open st) async {
    final session = st.session!;
    final project = session.project;
    if (project.docRevision == st.persistedRevision) {
      // Nothing new since the last write (main or journal).
      return st.lastReceipt ??
          SaveReceipt(projectId: st.id, docRevision: st.mainRevision, saveId: st.mainSaveId ?? '', savedAt: _clock(), reason: SaveReason.autosave);
    }
    final w = await _w;
    final recovery = ProjectRecovery(st.dir, fs: _fs, deleter: deleter);
    if (st.pending != null) {
      // "Open last saved": the journal the user did not restore is kept as recovered-<ts>.
      await recovery.keepLastSaved(_clock());
      st.pending = null;
    }
    await _preMigrationBackup(st.dir, st.migratedFrom, st.originalPath);
    final slot = await recovery.journal.nextSlot(baseSaveId: st.mainSaveId);
    final body = st.codec.encodeBytes(project); // incremental, on this isolate
    final saveId = _ids.next(IdKind.save);
    final savedAt = _clock();
    await w.writeDocument(recovery.journal.pathOf(slot), body, _stamp(project, saveId, baseSaveId: st.mainSaveId), atomic: false);
    st.persistedRevision = project.docRevision;
    if (!identical(project.pool, st.refsPool)) {
      // New media must be marked before the next main save (GC, ARCH §9.4).
      await w.writeFile(p.join(st.dir, 'refs.json'), ProjectRefs.ofSession(session).union(st.mainRefs).encode());
      st.refsPool = project.pool;
    }
    final receipt = SaveReceipt(projectId: st.id, docRevision: project.docRevision, saveId: saveId, savedAt: savedAt, reason: SaveReason.autosave);
    st.lastReceipt = receipt;
    return receipt;
  }

  AutosaveScheduler _schedulerOf(_Open st) => st.scheduler ??= AutosaveScheduler(
        save: () async {
          if (st.session == null || st.readOnly) return;
          await _enqueueJournal(st);
        },
        isPaused: () => st.session?.transaction?.isOpen ?? false,
        policy: autosavePolicy,
        timer: _timer,
        now: _clock,
      );

  @override
  void requestAutosave(EditSession session) {
    final st = _open[session.project.id];
    if (st == null || st.readOnly) return;
    st.session = session;
    _schedulerOf(st).request();
  }

  @override
  Future<void> flush(ProjectId id) async {
    final st = _open[id];
    if (st == null) return;
    await st.scheduler?.flush();
    await st.queue.idle();
  }

  @override
  Future<void> close(ProjectId id) async {
    final st = _open[id];
    if (st == null) return;
    try {
      await flush(id);
    } finally {
      await st.scheduler?.dispose();
      _open.remove(id);
      _emit();
    }
  }

  // ------------------------------------------------------------------------------------------
  // Rename, duplicate, delete
  // ------------------------------------------------------------------------------------------

  Future<_Loaded> _loadClosed(ProjectId id) async {
    if (_open.containsKey(id) || _opening.contains(id)) throw const StoreFailure(StoreFailureKind.busy, 'project open');
    final loaded = await _loadOff(_inline, roots, migrations, id);
    switch (loaded.health) {
      case ProjectHealth.ok:
        return loaded;
      case ProjectHealth.readOnlyNewer || ProjectHealth.needsNewerApp:
        throw const StoreFailure(StoreFailureKind.newerSchema, 'newer schema');
      case ProjectHealth.corrupt:
        throw const StoreFailure(StoreFailureKind.corrupt, 'no valid copy');
    }
  }

  @override
  Future<void> rename(ProjectId id, String name) async {
    final newName = _checkedName(name);
    final loaded = await _loadClosed(id);
    _opening.add(id);
    try {
      final dir = roots.projectDir(id);
      final now = _clock();
      EditProject renamed(EditProject pr) =>
          pr.copyWith(meta: pr.meta.copyWith(name: newName, updatedAt: now), docRevision: pr.docRevision + 1);
      final project = renamed(loaded.project!);
      final codec = ProjectJsonCodec(relativize: roots.relativize);
      await _preMigrationBackup(dir, loaded.migratedFrom, loaded.readPath);
      final recovery = ProjectRecovery(dir, fs: _fs, deleter: deleter);
      final candidate = loaded.pending == null ? null : await recovery.inspect();
      final saveId = await _writeMain(dir, project, codec.encodeBytes(project), ProjectRefs.ofProject(project));
      if (candidate != null) {
        // Keep the pending recovery valid: rename the journal too and rebase it on the new main.
        try {
          final j = ProjectJsonCodec(relativize: roots.relativize).decodeBytes(candidate.entry.document.body).project;
          final jr = renamed(j);
          final w = await _w;
          await w.writeDocument(
            recovery.journal.pathOf(candidate.entry.slot.other),
            codec.encodeBytes(jr),
            _stamp(jr, _ids.next(IdKind.save), baseSaveId: saveId),
            atomic: false,
          );
        } on FormatException {
          // An undecodable journal stays as it is (no longer recoverable).
        }
      }
    } finally {
      _opening.remove(id);
    }
    await _rescan(id);
  }

  @override
  Future<ProjectId> duplicate(ProjectId id, {String? name}) async {
    final loaded = await _loadClosed(id);
    final src = loaded.project!;
    await _ensureScanned();
    final taken = {for (final s in _scanned.values) s.summary.name};
    final String newName;
    if (name != null) {
      newName = _checkedName(name);
    } else {
      var n = 1;
      String candidate() => _fitName(src.name, n == 1 ? ' copy' : ' copy $n');
      while (taken.contains(candidate())) {
        n++;
      }
      newName = candidate();
    }
    final newId = _ids.projectId();
    final now = _clock();
    final from = roots.projectDir(id);
    final to = roots.projectDir(newId);
    final oldPrefix = '${roots.relativize(from)!.relPath}/';
    final newPrefix = '${roots.relativize(to)!.relPath}/';
    // Project-owned files are copied; managed copies and external files are shared.
    final assets = <MediaId, MediaAsset>{};
    for (final a in src.pool.assets.values) {
      final l = a.locator;
      if (l is AppRelativeLocator && l.root == AppRoot.support && l.relPath.startsWith(oldPrefix)) {
        final rel = '$newPrefix${l.relPath.substring(oldPrefix.length)}';
        await _copyIfPresent(roots.resolve(l), roots.resolve(AppRelativeLocator(AppRoot.support, rel)));
        if (a.kind == MediaKind.lut) {
          final vl = AppRelativeLocator(AppRoot.support, '${p.posix.withoutExtension(l.relPath)}.vlut');
          await _copyIfPresent(roots.resolve(vl), roots.resolve(AppRelativeLocator(AppRoot.support, '${p.posix.withoutExtension(rel)}.vlut')));
        }
        assets[a.id] = a.copyWith(locator: AppRelativeLocator(AppRoot.support, rel));
      } else {
        assets[a.id] = a;
      }
    }
    await _copyIfPresent(p.join(from, 'poster.jpg'), p.join(to, 'poster.jpg'));
    final copy = EditProject(
      id: newId,
      meta: ProjectMeta(name: newName, createdAt: now, updatedAt: now, editCount: src.meta.editCount),
      timeline: src.timeline,
      pool: MediaPool(assets),
      view: src.view,
    );
    await writeNewProject(copy);
    return newId;
  }

  static String _fitName(String base, String suffix) {
    final room = 80 - suffix.characters.length;
    final b = base.characters.length > room ? base.characters.take(room).toString().trimRight() : base;
    return '$b$suffix';
  }

  Future<void> _copyIfPresent(String from, String to) async {
    if ((await _fs.stat(from)).type != StoreEntityType.file) return;
    await _fs.createDirectory(p.dirname(to));
    await _fs.copyFile(from, to);
  }

  @override
  Future<void> delete(ProjectId id) async {
    if (_open.containsKey(id) || _opening.contains(id)) throw const StoreFailure(StoreFailureKind.busy, 'project open');
    final dir = roots.projectDir(id);
    if ((await _fs.stat(dir)).type != StoreEntityType.directory) throw const StoreFailure(StoreFailureKind.notFound, 'project');
    ProjectRefs? refs;
    try {
      refs = ProjectRefs.decode(await _fs.readBytes(p.join(dir, 'refs.json')));
    } on Object {
      refs = null;
    }
    final stamp = _clock().microsecondsSinceEpoch;
    final trash = p.join(roots.trashDir, '$id-$stamp');
    await _fs.createDirectory(roots.trashDir);
    await _fs.rename(dir, trash); // atomic: the project disappears at once
    _scanned.remove(id);
    _emit();
    try {
      await deleter.delete(trash, recursive: true);
    } on StoreFailure {
      // The GC sweeps trash/ later.
    }
    final hook = onProjectDeleted;
    if (hook != null) await hook(id, refs);
  }

  // ------------------------------------------------------------------------------------------
  // Recovery (CORE-26)
  // ------------------------------------------------------------------------------------------

  @override
  Future<List<RecoverableSession>> recoverable() async {
    final out = <RecoverableSession>[];
    if ((await _fs.stat(roots.projectsDir)).type != StoreEntityType.directory) return out;
    for (final e in await _fs.list(roots.projectsDir)) {
      if (e.type != StoreEntityType.directory) continue;
      final id = ProjectId(p.basename(e.path));
      if (_open.containsKey(id)) continue; // an open project's journal is its live autosave
      final c = await ProjectRecovery(e.path, fs: _fs, deleter: deleter).inspect();
      if (c != null) out.add(c.toSession(id));
    }
    out.sort((a, b) => b.journalSavedAt.compareTo(a.journalSavedAt));
    return out;
  }

  @override
  Future<LoadedProject> restore(RecoverableSession session) async {
    final id = session.projectId;
    final st = _open[id];
    if (st != null) {
      if (st.pending == null) throw const StoreFailure(StoreFailureKind.busy, 'project open');
      // Drop the open state without autosaving over the journal being restored.
      st.scheduler?.cancel();
      await st.queue.idle();
      await st.scheduler?.dispose();
      _open.remove(id);
    }
    final dir = roots.projectDir(id);
    await ProjectRecovery(dir, fs: _fs, deleter: deleter).restore();
    final loaded = await open(id);
    // meta.json and refs.json follow the promoted document.
    final now = _open[id]!;
    await _writeMeta(dir, loaded.project, now.mainSaveId ?? '', missing: now.missingMediaCount);
    await (await _w).writeFile(p.join(dir, 'refs.json'), ProjectRefs.ofProject(loaded.project).encode());
    await _rescan(id);
    return loaded;
  }

  @override
  Future<void> discard(RecoverableSession session) async {
    final id = session.projectId;
    final st = _open[id];
    if (st != null) {
      if (st.pending == null) return; // the live journal of an open project is not "recoverable"
      await st.queue.enqueue('discard', () async {
        await ProjectRecovery(st.dir, fs: _fs, deleter: deleter).discard();
        st.pending = null;
        return st.lastReceipt ??
            SaveReceipt(projectId: id, docRevision: st.mainRevision, saveId: st.mainSaveId ?? '', savedAt: _clock(), reason: SaveReason.manual);
      });
    } else {
      await ProjectRecovery(roots.projectDir(id), fs: _fs, deleter: deleter).discard();
    }
    await _rescan(id);
  }

  // ------------------------------------------------------------------------------------------
  // Player handoff, storage
  // ------------------------------------------------------------------------------------------

  @override
  Future<ProjectId?> findUntouchedProjectFor(String pathOrUri) async {
    final port = access;
    if (port == null) return null;
    final MediaLocator locator;
    if (pathOrUri.startsWith('content://')) {
      locator = ContentUriLocator(pathOrUri);
    } else {
      final path = ImportPolicy.pathOf(pathOrUri);
      if (path == null) return null;
      locator = FileLocator(path);
    }
    final MediaStat? stat;
    final String hash;
    try {
      stat = await port.stat(locator);
      if (stat == null) return null;
      hash = await port.quickHash(locator);
    } on MediaAccessFailure {
      return null;
    }
    await _ensureScanned();
    final matches = [
      for (final s in _scanned.values)
        if (s.untouchedOrigin case final o? when o.quickHash == hash && o.sizeBytes == stat.sizeBytes) s,
    ]..sort((a, b) => b.summary.updatedAt.compareTo(a.summary.updatedAt));
    return matches.isEmpty ? null : matches.first.id;
  }

  @override
  Future<ProjectStorageReport> storageReport() => _reportOff(_inline, roots);

  /// The quickHash fingerprint a player handoff stores in `FromPlayerOrigin` (helper for INT-02).
  static FromPlayerOrigin playerOriginOf(MediaFingerprint fp, String displayName) =>
      FromPlayerOrigin(quickHash: fp.quickHash, sizeBytes: fp.sizeBytes, displayName: displayName);
}
