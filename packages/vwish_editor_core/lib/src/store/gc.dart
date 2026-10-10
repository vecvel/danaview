// OWNER: CORE-28
//
// Garbage collection of shared editor files (ARCH §9.4).
//
// * `refs.json` ([ProjectRefs]) is written by the repository (CORE-25) next to every project
//   document, with root-relative paths only (ARCH §8.2): the managed-copy folders
//   (`vwish/editor/media/<hh>/<quickHash>`, with their sizes), the derived renditions
//   (`derived/<specHash>.*`), the persisted URI grants and the bookmarks the project uses.
// * **Mark** = the union of every project's `refs.json` (a project without a readable
//   `refs.json` is read from its document, and its journal slots are added), the media of open
//   sessions (`EditSession.retainedMedia()`: timeline, history snapshots and pool deltas), the
//   in-flight imports (`FileMediaPoolService.inFlightQuickHashes`) and in-flight engine jobs
//   (derived spec hashes).
// * **Sweep** = managed folders under `media/` and files under `derived/` that are not marked and
//   whose newest timestamp is older than the grace period (24 h), deleted through
//   `OwnedFileDeleter`; staged deletes left in `trash/`; and URI grants / bookmarks that some
//   project used before (the ledger `grants.json`) but none uses now, released through the port.
// * When any project's references cannot be read, nothing is swept (a false keep is safe, a
//   false delete is not). External files are never deleted: only folders under `media/` and
//   files under `derived/` are candidates, and the deleter refuses everything else.
// * **Never during an export**: [MediaGarbageCollector.exportInProgress] is checked before the
//   sweep and before every delete; a run that meets an export stops.
// * [GcScheduler] runs it 30 s after start, after a project delete and from Settings › Storage,
//   one run at a time.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../codec/project_json.dart';
import '../ids/ids.dart';
import '../model/pool/media_access_port.dart';
import '../model/pool/media_asset.dart';
import '../model/pool/media_locator.dart';
import '../model/project.dart';
import '../session/session.dart';
import 'atomic_file.dart';
import 'autosave_scheduler.dart';
import 'owned_file_deleter.dart';
import 'store_fs.dart';
import 'store_roots.dart';
import 'vwproj_format.dart';

/// Files and grants a project references (the content of `refs.json`).
@immutable
final class ProjectRefs {
  /// Creates refs.
  ProjectRefs({
    Map<String, int> managed = const {},
    Set<String> derived = const {},
    Set<String> grants = const {},
    Set<String> bookmarks = const {},
  })  : managed = Map.unmodifiable(managed),
        derived = Set.unmodifiable(derived),
        grants = Set.unmodifiable(grants),
        bookmarks = Set.unmodifiable(bookmarks);

  /// No references.
  static final ProjectRefs empty = ProjectRefs();

  /// Managed-copy folders relative to the support root (`vwish/editor/media/<hh>/<hash>`) → bytes.
  final Map<String, int> managed;

  /// Derived rendition keys: file names under `derived/` without extension (spec hashes).
  final Set<String> derived;

  /// Persisted `content://` grants.
  final Set<String> grants;

  /// Bookmarks (base64).
  final Set<String> bookmarks;

  /// The refs of [assets].
  static ProjectRefs ofAssets(Iterable<MediaAsset> assets) {
    final managed = <String, int>{};
    final derived = <String>{};
    final grants = <String>{};
    final bookmarks = <String>{};
    for (final a in assets) {
      final spec = a.derived;
      if (spec is ReversedSpec) derived.add(spec.specHash);
      switch (a.locator) {
        case AppRelativeLocator(:final root, :final relPath) when root == AppRoot.support:
          final parts = p.posix.split(relPath);
          if (parts.length >= 6 && parts[0] == 'vwish' && parts[1] == 'editor' && parts[2] == 'media') {
            final dir = p.posix.joinAll(parts.take(5));
            managed[dir] = (managed[dir] ?? 0) + (a.ownership == MediaOwnership.managedCopy ? a.fingerprint.sizeBytes : 0);
          } else if (parts.length >= 4 && parts[0] == 'vwish' && parts[1] == 'editor' && parts[2] == 'derived') {
            derived.add(p.posix.withoutExtension(parts[3]));
          }
        case ContentUriLocator(:final uri):
          grants.add(uri);
        case BookmarkLocator(:final bookmarkB64):
          bookmarks.add(bookmarkB64);
        default:
          break;
      }
    }
    return ProjectRefs(managed: managed, derived: derived, grants: grants, bookmarks: bookmarks);
  }

  /// The refs of a stored project (its pool).
  static ProjectRefs ofProject(EditProject project) => ofAssets(project.pool.assets.values);

  /// The refs of an open session: its pool plus every asset its history could bring back.
  static ProjectRefs ofSession(EditSession session) {
    final assets = <MediaAsset>[...session.project.pool.assets.values, ...session.committedProject.pool.assets.values];
    for (final e in session.entries) {
      final d = e.poolDelta;
      if (d == null) continue;
      for (final a in [...d.before.values, ...d.after.values]) {
        if (a != null) assets.add(a);
      }
    }
    return ofAssets(assets);
  }

  /// The union of [this] and [other].
  ProjectRefs union(ProjectRefs other) => ProjectRefs(
        managed: {...managed, ...other.managed},
        derived: {...derived, ...other.derived},
        grants: {...grants, ...other.grants},
        bookmarks: {...bookmarks, ...other.bookmarks},
      );

  /// Canonical JSON bytes (sorted; no absolute paths).
  Uint8List encode() {
    final m = managed.keys.toList()..sort();
    return Uint8List.fromList(utf8.encode(jsonEncode({
      'v': 1,
      'managed': [
        for (final d in m) {'dir': d, 'bytes': managed[d]},
      ],
      'derived': derived.toList()..sort(),
      'grants': grants.toList()..sort(),
      'bookmarks': bookmarks.toList()..sort(),
    })));
  }

  /// Parses [encode]'s output. Throws [FormatException] on anything else.
  static ProjectRefs decode(List<int> bytes) {
    final j = jsonDecode(utf8.decode(bytes));
    if (j is! Map<String, Object?> || j['v'] != 1) throw const FormatException('not a refs.json');
    List<Object?> list(String k) {
      final v = j[k];
      if (v is! List<Object?>) throw FormatException('refs.json: $k');
      return v;
    }

    final managed = <String, int>{};
    for (final e in list('managed')) {
      if (e is! Map<String, Object?> || e['dir'] is! String || e['bytes'] is! int) throw const FormatException('refs.json: managed');
      managed[e['dir']! as String] = e['bytes']! as int;
    }
    Set<String> strings(String k) {
      final out = <String>{};
      for (final e in list(k)) {
        if (e is! String) throw FormatException('refs.json: $k');
        out.add(e);
      }
      return out;
    }

    return ProjectRefs(managed: managed, derived: strings('derived'), grants: strings('grants'), bookmarks: strings('bookmarks'));
  }

  @override
  bool operator ==(Object other) =>
      other is ProjectRefs &&
      _mapEq(other.managed, managed) &&
      _setEq(other.derived, derived) &&
      _setEq(other.grants, grants) &&
      _setEq(other.bookmarks, bookmarks);

  @override
  int get hashCode => Object.hash(managed.length, derived.length, grants.length, bookmarks.length);

  static bool _setEq(Set<String> a, Set<String> b) => a.length == b.length && a.containsAll(b);
  static bool _mapEq(Map<String, int> a, Map<String, int> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);
}

/// Why a run did not sweep.
enum GcSkipReason {
  /// An export was running (before the sweep or during it).
  exportInProgress,

  /// Some project's references could not be read; nothing was deleted.
  unreadableProject,

  /// Another run was in progress.
  busy,
}

/// What a run did.
@immutable
final class GcReport {
  /// Creates a report.
  GcReport({
    this.skipped,
    List<String> deleted = const [],
    this.freedBytes = 0,
    List<String> released = const [],
    this.keptForGrace = 0,
  })  : deleted = List.unmodifiable(deleted),
        released = List.unmodifiable(released);

  /// Set when the run did not (fully) sweep.
  final GcSkipReason? skipped;

  /// Paths deleted, relative to the support root.
  final List<String> deleted;

  /// Bytes freed.
  final int freedBytes;

  /// Grants / bookmarks released.
  final List<String> released;

  /// Unreferenced entries kept because they are younger than the grace period.
  final int keptForGrace;

  @override
  String toString() => 'GcReport(${skipped?.name ?? 'swept'}, deleted ${deleted.length}, released ${released.length}, '
      'kept $keptForGrace)';
}

/// Mark and sweep of managed copies, derived renditions, trash and grants (see the file header).
final class MediaGarbageCollector {
  /// Creates the collector. [deleter] must share [fs].
  MediaGarbageCollector({
    required this.roots,
    StoreFs fs = const LocalStoreFs(),
    OwnedFileDeleter? deleter,
    this.access,
    Iterable<EditSession> Function()? openSessions,
    Iterable<EditProject> Function()? openProjects,
    Set<String> Function()? inFlightQuickHashes,
    Set<String> Function()? inFlightDerived,
    bool Function()? exportInProgress,
    DateTime Function()? clock,
    this.grace = const Duration(hours: 24),
  })  : _fs = fs,
        deleter = deleter ?? OwnedFileDeleter(roots, fs: fs),
        _openSessions = openSessions ?? _none,
        _openProjects = openProjects ?? _none,
        _inFlightHashes = inFlightQuickHashes ?? _noStrings,
        _inFlightDerived = inFlightDerived ?? _noStrings,
        exportInProgress = exportInProgress ?? _no,
        _clock = clock ?? DateTime.now;

  static Iterable<Never> _none() => const [];
  static Set<String> _noStrings() => const {};
  static bool _no() => false;

  /// App roots.
  final StoreRoots roots;

  /// The deletion guard (the only delete path).
  final OwnedFileDeleter deleter;

  /// Port for releasing grants and bookmarks (null: nothing is released).
  final MediaAccessPort? access;

  /// The export gate.
  final bool Function() exportInProgress;

  /// Unreferenced files younger than this are kept.
  final Duration grace;

  final StoreFs _fs;
  final Iterable<EditSession> Function() _openSessions;
  final Iterable<EditProject> Function() _openProjects;
  final Set<String> Function() _inFlightHashes;
  final Set<String> Function() _inFlightDerived;
  final DateTime Function() _clock;

  /// `<editorSupport>/grants.json`: grants and bookmarks seen in earlier marks.
  String get ledgerPath => p.join(roots.editorSupport, 'grants.json');

  // ------------------------------------------------------------------------------------------
  // Mark
  // ------------------------------------------------------------------------------------------

  /// Everything referenced right now, or null when a project could not be read.
  Future<ProjectRefs?> mark() async {
    var refs = ProjectRefs.empty;
    final projects = roots.projectsDir;
    if ((await _fs.stat(projects)).type == StoreEntityType.directory) {
      for (final e in await _fs.list(projects)) {
        if (e.type != StoreEntityType.directory) continue;
        final r = await _refsOfBundle(e.path);
        if (r == null) return null;
        refs = refs.union(r);
      }
    }
    for (final s in _openSessions()) {
      refs = refs.union(ProjectRefs.ofSession(s));
    }
    for (final pr in _openProjects()) {
      refs = refs.union(ProjectRefs.ofProject(pr));
    }
    return refs;
  }

  Future<ProjectRefs?> _refsOfBundle(String dir) async {
    ProjectRefs? refs;
    final refsPath = p.join(dir, 'refs.json');
    try {
      if ((await _fs.stat(refsPath)).type == StoreEntityType.file) refs = ProjectRefs.decode(await _fs.readBytes(refsPath));
    } on FormatException {
      refs = null;
    } on StoreFailure {
      refs = null;
    }
    final main = p.join(dir, 'project.vwproj');
    if (refs == null) {
      final mainStat = await _fs.stat(main);
      final hasAny = mainStat.exists || (await AtomicFile(fs: _fs).tempFiles(main)).isNotEmpty || (await _fs.stat(AtomicFile.backupPath(main))).exists;
      if (!hasAny) {
        // An empty or half-created bundle references nothing unless its journal does.
        refs = ProjectRefs.empty;
      } else {
        try {
          final read = await VwprojFiles(fs: _fs).read(main);
          refs = _refsOfBody(read.document.body);
        } on Object {
          return null;
        }
        if (refs == null) return null;
      }
    }
    // Journal slots and kept recovered journals may reference media the main does not.
    final journalDir = p.join(dir, 'journal');
    if ((await _fs.stat(journalDir)).type == StoreEntityType.directory) {
      for (final j in await _fs.list(journalDir)) {
        if (j.type != StoreEntityType.file || !j.path.endsWith('.vwproj')) continue;
        final Uint8List bytes;
        try {
          bytes = await _fs.readBytes(j.path);
        } on StoreFailure {
          continue;
        }
        final doc = VwprojFormat.tryParse(bytes);
        if (doc == null) continue; // a torn slot recovers nothing
        final r = _refsOfBody(doc.body);
        if (r == null) return null;
        refs = refs!.union(r);
      }
    }
    return refs;
  }

  static ProjectRefs? _refsOfBody(Uint8List body) {
    try {
      return ProjectRefs.ofProject(ProjectJsonCodec().decodeBytes(body).project);
    } on Object {
      return null;
    }
  }

  // ------------------------------------------------------------------------------------------
  // Sweep
  // ------------------------------------------------------------------------------------------

  /// Marks and sweeps once.
  Future<GcReport> collect() async {
    if (exportInProgress()) return GcReport(skipped: GcSkipReason.exportInProgress);
    final deleted = <String>[];
    var freed = 0;
    var kept = 0;

    // Staged deletes never hold referenced files.
    for (final e in await _listOrEmpty(roots.trashDir)) {
      if (e.type == StoreEntityType.link) continue;
      if (exportInProgress()) return GcReport(skipped: GcSkipReason.exportInProgress, deleted: deleted, freedBytes: freed);
      freed += await _sizeOf(e.path);
      await deleter.delete(e.path, recursive: true);
      deleted.add(_rel(e.path));
    }

    final marked = await mark();
    if (marked == null) return GcReport(skipped: GcSkipReason.unreadableProject, deleted: deleted, freedBytes: freed);
    final hashes = _inFlightHashes();
    final jobs = _inFlightDerived();
    final cutoff = _clock().subtract(grace);
    final markedDirs = marked.managed.keys.toSet();

    // media/<hh>/<quickHash>/
    for (final hh in await _listOrEmpty(roots.mediaDir)) {
      if (hh.type != StoreEntityType.directory) continue;
      for (final dir in await _listOrEmpty(hh.path)) {
        if (dir.type != StoreEntityType.directory) continue; // links and strays are not ours to judge
        final rel = _rel(dir.path);
        final hash = p.basename(dir.path);
        if (markedDirs.contains(rel) || hashes.contains(hash)) continue;
        if (await _newest(dir.path) case final t? when t.isAfter(cutoff)) {
          kept++;
          continue;
        }
        if (exportInProgress()) return GcReport(skipped: GcSkipReason.exportInProgress, deleted: deleted, freedBytes: freed, keptForGrace: kept);
        freed += await _sizeOf(dir.path);
        await deleter.delete(dir.path, recursive: true);
        deleted.add(rel);
      }
      if ((await _listOrEmpty(hh.path)).isEmpty && !((await _newest(hh.path))?.isAfter(cutoff) ?? false)) {
        await deleter.delete(hh.path); // an empty, old shard folder
      }
    }

    // derived/<specHash>.<ext>
    for (final f in await _listOrEmpty(roots.derivedDir)) {
      if (f.type != StoreEntityType.file) continue;
      final key = p.withoutExtension(p.basename(f.path));
      final base = key.split('.').first;
      if (marked.derived.contains(key) || marked.derived.contains(base) || jobs.contains(key) || jobs.contains(base)) continue;
      if (await _newest(f.path) case final t? when t.isAfter(cutoff)) {
        kept++;
        continue;
      }
      if (exportInProgress()) return GcReport(skipped: GcSkipReason.exportInProgress, deleted: deleted, freedBytes: freed, keptForGrace: kept);
      freed += await _sizeOf(f.path);
      await deleter.delete(f.path, recursive: true);
      deleted.add(_rel(f.path));
    }

    final released = await _releaseGrants(marked);
    return GcReport(deleted: deleted, freedBytes: freed, released: released, keptForGrace: kept);
  }

  /// Adds [refs]'s grants and bookmarks to the ledger so the next run releases them when no
  /// project uses them any more (called with the refs of a deleted project).
  Future<void> noteReleaseCandidates(ProjectRefs refs) async {
    if (refs.grants.isEmpty && refs.bookmarks.isEmpty) return;
    final ledger = await _readLedger();
    await _writeLedger(ledger.union(ProjectRefs(grants: refs.grants, bookmarks: refs.bookmarks)));
  }

  Future<List<String>> _releaseGrants(ProjectRefs marked) async {
    final ledger = await _readLedger();
    final port = access;
    final released = <String>[];
    final keep = <String>{...marked.grants};
    final keepBookmarks = <String>{...marked.bookmarks};
    for (final g in ledger.grants.difference(marked.grants)) {
      if (port == null || !await _release(port, ContentUriLocator(g))) {
        keep.add(g);
      } else {
        released.add(g);
      }
    }
    for (final b in ledger.bookmarks.difference(marked.bookmarks)) {
      if (port == null || !await _release(port, BookmarkLocator(b))) {
        keepBookmarks.add(b);
      } else {
        released.add(b);
      }
    }
    final next = ProjectRefs(grants: keep, bookmarks: keepBookmarks);
    if (next != ledger) await _writeLedger(next);
    return released;
  }

  static Future<bool> _release(MediaAccessPort port, MediaLocator l) async {
    try {
      await port.release(l);
      return true;
    } on MediaAccessFailure {
      return false;
    }
  }

  Future<ProjectRefs> _readLedger() async {
    try {
      final r = await AtomicFile(fs: _fs).read(ledgerPath, isValid: (b) {
        try {
          ProjectRefs.decode(b);
          return true;
        } on FormatException {
          return false;
        }
      });
      return ProjectRefs.decode(r.bytes);
    } on StoreFailure {
      return ProjectRefs.empty;
    }
  }

  Future<void> _writeLedger(ProjectRefs refs) =>
      AtomicFile(fs: _fs, deleter: deleter).write(ledgerPath, ProjectRefs(grants: refs.grants, bookmarks: refs.bookmarks).encode());

  Future<List<StoreEntry>> _listOrEmpty(String dir) async {
    if ((await _fs.stat(dir)).type != StoreEntityType.directory) return const [];
    return _fs.list(dir);
  }

  /// The newest modification time of [path] and (for a directory) everything below it.
  Future<DateTime?> _newest(String path) async {
    final s = await _fs.stat(path);
    var t = s.modified;
    if (s.type == StoreEntityType.directory) {
      for (final e in await _fs.list(path)) {
        final c = await _newest(e.path);
        if (c != null && (t == null || c.isAfter(t))) t = c;
      }
    }
    return t;
  }

  Future<int> _sizeOf(String path) async {
    final s = await _fs.stat(path);
    if (s.type == StoreEntityType.file) return s.size;
    if (s.type != StoreEntityType.directory) return 0;
    var n = 0;
    for (final e in await _fs.list(path)) {
      n += await _sizeOf(e.path);
    }
    return n;
  }

  String _rel(String path) => roots.relativize(path)?.relPath ?? p.basename(path);
}

/// When garbage collection runs (ARCH §9.4): 30 s after [start], after a project delete and on
/// demand; one run at a time (a request during a run waits for it and runs again).
final class GcScheduler {
  /// Creates the scheduler over [collector].
  GcScheduler(this.collector, {StoreTimerFactory? timer, this.startDelay = const Duration(seconds: 30)})
      : _timer = timer ?? Timer.new;

  /// The collector.
  final MediaGarbageCollector collector;

  /// Delay of the first run after [start].
  final Duration startDelay;

  final StoreTimerFactory _timer;
  Timer? _startTimer;
  Future<GcReport>? _running;
  bool _disposed = false;

  /// Reports of finished runs (diagnostics, Settings › Storage).
  final List<GcReport> history = [];

  /// Schedules the idle run after app start.
  void start() {
    if (_disposed) return;
    _startTimer?.cancel();
    _startTimer = _timer(startDelay, () {
      _startTimer = null;
      unawaited(runNow());
    });
  }

  /// Runs now (Settings › Storage), after any run in progress.
  Future<GcReport> runNow() async {
    if (_disposed) return GcReport(skipped: GcSkipReason.busy);
    while (_running != null) {
      await _running;
    }
    final f = _running = collector.collect();
    try {
      final r = await f;
      history.add(r);
      return r;
    } finally {
      _running = null;
    }
  }

  /// The hook the repository calls after deleting a project (with the project's refs when they
  /// could be read, so its grants are released once nothing else uses them).
  Future<GcReport> projectDeleted([ProjectRefs? refs]) async {
    if (refs != null) await collector.noteReleaseCandidates(refs);
    return runNow();
  }

  /// Cancels the start timer; later requests are ignored.
  void dispose() {
    _disposed = true;
    _startTimer?.cancel();
  }
}

/// Signature of the repository's delete hook (`FileProjectRepository.onProjectDeleted`).
typedef ProjectDeletedHook = Future<void> Function(ProjectId id, ProjectRefs? refs);
