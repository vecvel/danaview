// OWNER: CORE-25
//
// Shared helpers of the repository, recovery and GC tests: a fake timer/clock, a media access
// port over `MemoryStoreFs`, project builders and an in-memory repository factory.

import 'dart:async';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:danaview_editor_core/store.dart';
import 'package:danaview_editor_core/testing.dart';

import '../../../ops/framework/ops_support.dart';

export '../../../ops/framework/ops_support.dart';

/// A manual clock with one-shot timers (`StoreTimerFactory`).
final class FakeTimers {
  /// Creates the clock at [start].
  FakeTimers([DateTime? start]) : now = start ?? DateTime.utc(2026, 10, 10, 9);

  /// Current time.
  DateTime now;

  final List<_FakeTimer> _timers = [];

  /// The `StoreTimerFactory`.
  Timer call(Duration d, void Function() callback) {
    final t = _FakeTimer(this, now.add(d), callback);
    _timers.add(t);
    return t;
  }

  /// The clock function.
  DateTime clock() => now;

  /// Number of timers waiting.
  int get pending => _timers.where((t) => t.isActive).length;

  /// Advances time by [d], firing due timers in order (and letting their async work run).
  Future<void> elapse(Duration d) async {
    final end = now.add(d);
    while (true) {
      final due = _timers.where((t) => t.isActive && !t.at.isAfter(end)).toList()..sort((a, b) => a.at.compareTo(b.at));
      if (due.isEmpty) break;
      final t = due.first;
      now = t.at;
      t.fire();
      await settle();
    }
    now = end;
    await settle();
  }
}

/// Lets pending microtasks and short async I/O finish.
Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

final class _FakeTimer implements Timer {
  _FakeTimer(this._owner, this.at, this._callback);

  final FakeTimers _owner;
  final DateTime at;
  final void Function() _callback;
  bool _active = true;

  void fire() {
    if (!_active) return;
    _active = false;
    _owner._timers.remove(this);
    _callback();
  }

  @override
  void cancel() {
    _active = false;
    _owner._timers.remove(this);
  }

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}

/// A `MediaAccessPort` over a [MemoryStoreFs] (app-relative and file locators; content URIs and
/// bookmarks resolve through maps).
final class MemoryMediaAccess implements MediaAccessPort {
  /// Creates the port.
  MemoryMediaAccess(this.roots, this.fs);

  /// Roots for app-relative locators.
  StoreRoots roots;

  /// The file system.
  final StoreFs fs;

  /// `content://` URI → path (absent = access lost).
  final Map<String, String> content = {};

  /// Bookmark → path.
  final Map<String, String> bookmarks = {};

  /// Released locators.
  final List<MediaLocator> released = [];

  String _path(MediaLocator l) => switch (l) {
        AppRelativeLocator() => roots.resolve(l),
        FileLocator(:final path) => path,
        ContentUriLocator(:final uri) => content[uri] ?? (throw const MediaAccessFailure(MediaAccessFailureKind.accessLost)),
        BookmarkLocator(:final bookmarkB64) =>
          bookmarks[bookmarkB64] ?? (throw const MediaAccessFailure(MediaAccessFailureKind.accessLost)),
      };

  @override
  Future<ResolvedMedia> resolve(MediaLocator locator) async =>
      ResolvedMedia(uri: Uri.file(_path(locator)).toString(), fingerprint: await quickHash(locator));

  @override
  Future<MediaStat?> stat(MediaLocator locator) async {
    final s = await fs.stat(_path(locator));
    if (s.type != StoreEntityType.file) return null;
    return MediaStat(sizeBytes: s.size, modifiedMs: s.modified?.millisecondsSinceEpoch);
  }

  @override
  Future<String> quickHash(MediaLocator locator) async {
    final b = await fs.readBytes(_path(locator));
    final head = Uint8List.sublistView(b, 0, b.length < quickHashChunkBytes ? b.length : quickHashChunkBytes);
    final tail = Uint8List.sublistView(b, b.length > quickHashChunkBytes ? b.length - quickHashChunkBytes : 0);
    return computeQuickHash(head, tail, b.length);
  }

  @override
  Future<MediaLocator> persist(PickedMediaHandle handle) async =>
      handle.uri.startsWith('content://') ? ContentUriLocator(handle.uri) : FileLocator(handle.uri);

  @override
  Future<void> release(MediaLocator locator) async => released.add(locator);

  @override
  Future<void> excludeFromBackup(String dirPath) async {}

  @override
  Future<int> remainingGrantBudget() async => 500;
}

/// quickHash of [bytes] (same as the ports).
String hashOf(List<int> bytes) {
  final b = Uint8List.fromList(bytes);
  final head = Uint8List.sublistView(b, 0, b.length < quickHashChunkBytes ? b.length : quickHashChunkBytes);
  final tail = Uint8List.sublistView(b, b.length > quickHashChunkBytes ? b.length - quickHashChunkBytes : 0);
  return computeQuickHash(head, tail, b.length);
}

/// An in-memory repository on fake timers with seeded ids.
InMemoryProjectRepository memRepo(FakeTimers timers, {StoreRoots? roots, int seed = 11, MediaPoolService? media, MediaAccessPort? access}) =>
    InMemoryProjectRepository(
      ids: SeededIdGenerator(seed),
      clock: timers.clock,
      timer: timers.call,
      roots: roots ?? InMemoryProjectRepository.defaultRoots,
      media: media,
      access: access,
    );

/// A project with [n] one-second clips on the main lane over the standard pool.
EditProject bigProject(int n, {String id = 'pr_big00000001', String name = 'Big'}) => EditProject(
      id: ProjectId(id),
      meta: ProjectMeta(name: name, createdAt: when, updatedAt: when),
      timeline: Timeline(tracks: [
        lane('tr_main', TrackKind.video, [for (var i = 0; i < n; i++) vclip('it_c$i', i * 30, 30, media: 'md_video', sourceIn: 0)], main: true),
      ]),
      pool: basePool,
    );

/// A small project with a main lane holding one clip of [media].
EditProject smallProject({String id = 'pr_small0000001', String name = 'Small', MediaPool? pool, String media = 'md_video'}) => EditProject(
      id: ProjectId(id),
      meta: ProjectMeta(name: name, createdAt: when, updatedAt: when),
      timeline: Timeline(tracks: [
        lane('tr_main', TrackKind.video, [vclip('it_a', 0, 30, media: media)], main: true),
      ]),
      pool: pool ?? basePool,
    );

/// The bundle directory of [id] under [roots].
String bundleOf(StoreRoots roots, String id) => roots.projectDir(id);

/// Path of the main document.
String mainOf(StoreRoots roots, String id) => p.join(roots.projectDir(id), 'project.dnproj');

/// Opens [id], wraps it in a session on the fake clock.
Future<(LoadedProject, EditSession)> openSession(ProjectRepository repo, ProjectId id, FakeTimers timers) async {
  final loaded = await repo.open(id);
  return (loaded, EditSession(loaded.project, ids: SeededIdGenerator(5), clock: timers.clock));
}

/// One edit that changes the timeline (moves the playhead marker-free: adds a marker).
EditOutcome edit(EditSession s, [int k = 3]) => s.apply(AddMarker(rate.timeOfFrame(k), name: 'm$k'));
