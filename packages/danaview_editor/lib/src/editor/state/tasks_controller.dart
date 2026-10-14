// OWNER: UX-35
//
// TasksController (ux.md §10.15, §16.2, ARCH §12.3, §17.7): the background media jobs of one open
// project and the rows of the Tasks sheet.
//
// * **Derived media.** Reverse and freeze frame make project-owned assets that start as pending
//   pool entries (`PendingStatus`). Core `SetReversed` adds a pending `ReversedSpec` rendition with
//   the unstarted job id; `freeze` adds a pending `StillSpec` still itself before `FreezeFrame`. The
//   controller watches the editor state and starts an engine job for every pending derived asset it
//   does not track yet: unstarted ones always, and on reopen the ones the timeline still needs
//   (`MediaJobs.reverse` into `derived/<specHash>.mp4`, `MediaJobs.freezeFrame` into
//   `projects/<id>/assets/stills/<mediaId>.png`). Status changes are sticky pool changes
//   (`EditorController.applyPoolChange`, never in history) and the preview plan is re-synced so a
//   finished rendition replaces the placeholder at once.
// * **Cancel.** Cancelling a reverse marks the rendition failed (`cancelled`) and plays the waiting
//   clips forward again (one history entry "Cancel reverse"); cancelling a freeze removes the
//   waiting still with ripple (one entry "Cancel freeze frame"). A failed job keeps a failed row with
//   "Try again" (the asset goes back to pending-unstarted) and "Dismiss".
// * **Proxies** (`requestProxy`) follow the asset's `ProxyState`; pending proxies are resumed too.
// * **Other producers** (waveforms, captions, model download) report through [TasksController.track]
//   (a `MediaJob`) or [TasksController.begin] (a handle they drive).
// * **Export gating.** [TasksController.exportBlockersOf] counts the clips that wait for a pending
//   rendition or still; export (UX-39) waits while it is non-zero, and
//   [TasksController.cancelExportBlockers] is its "Cancel reverse".
// * Rows go to `EditorState.tasks` (`EditorController.setTasks`), which drives the preview's task
//   badge and the Tasks sheet. When the editor closes the jobs are cancelled quietly (the assets
//   stay pending and resume on the next open).

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/eval.dart' show MediaClipTimeMap;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart'
    show CompositeCommand, DeleteItems, EditCommand, FreezeFrame, SetReversed, unstartedJobId;
import 'package:danaview_editor_core/store.dart' show ManagedStore;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

import '../../app/editor_bootstrap.dart' show editorRuntimeProvider;
import '../../app/editor_providers.dart';
import '../../app/strings/clip_strings.dart';
import 'editor_controller.dart';
import 'editor_session.dart';
import 'editor_state.dart';

/// A task another feature drives (captions, model download): report progress, then finish.
abstract interface class EditorTaskHandle {
  /// Task id.
  String get id;

  /// Reports progress (0..1, or null when indeterminate).
  void progress(double? fraction);

  /// The task finished; its row goes away.
  void complete();

  /// The task failed; its row stays until dismissed (or retried when the producer gave a retry).
  void fail();
}

/// Background tasks: proxies, reverse, freeze, waveforms, captions, download (ux.md §10.15).
class TasksController {
  /// Creates the controller over [editor] and [session]; [jobs] runs the media jobs and
  /// [resolvePath] turns an app-relative locator into an absolute path.
  TasksController({
    required this.projectId,
    required EditorController editor,
    required EditorSession session,
    required MediaJobs jobs,
    required String Function(AppRelativeLocator locator) resolvePath,
    IdGenerator? ids,
    DateTime Function()? clock,
  })  : _editor = editor,
        _session = session,
        _jobs = jobs,
        _resolvePath = resolvePath,
        _ids = ids ?? SecureIdGenerator(),
        _clock = clock ?? (() => DateTime.now().toUtc()) {
    _removeListener = editor.addListener(_onState, fireImmediately: true);
  }

  /// The project.
  final ProjectId projectId;

  final EditorController _editor;
  final EditorSession _session;
  final MediaJobs _jobs;
  final String Function(AppRelativeLocator locator) _resolvePath;
  final IdGenerator _ids;
  final DateTime Function() _clock;

  final Map<String, _Task> _tasks = {};
  final Map<MediaId, String> _byAsset = {};
  VoidCallback? _removeListener;
  MediaPool? _seenPool;
  bool _reconcileQueued = false;
  bool _disposed = false;
  bool _suspended = false;
  int _local = 0;

  /// A path for an app-relative locator when no runtime is wired (tests): never written to.
  static String unconfiguredPath(AppRelativeLocator locator) => '/danaview-unconfigured/${locator.root.name}/${locator.relPath}';

  /// The current rows, oldest first.
  List<EditorTaskInfo> get tasks => [for (final t in _tasks.values) t.info];

  /// The task id that produces [asset] (reverse rendition, freeze still or proxy), or null.
  String? taskOf(MediaId asset) => _byAsset[asset];

  /// The current progress of task [id] (null when indeterminate or unknown).
  double? progressOf(String id) => _tasks[id]?.progress;

  EditProject? get _project => _editor.mounted ? _editor.state.project : null;

  // -----------------------------------------------------------------------------------------------
  // Reverse and freeze
  // -----------------------------------------------------------------------------------------------

  /// Turns reverse on or off for [item] (one history entry); turning it on starts the rendition job
  /// when no usable rendition exists.
  EditResult reverse(ItemId item, {bool? on}) {
    final clip = _project?.index.item(item);
    if (clip is! MediaClip) return const EditUnchanged();
    final result = _editor.apply(SetReversed(item, on ?? !clip.reversed));
    _reconcile();
    return result;
  }

  /// Freezes the frame of [item] under [at] for [duration]: adds a pending still, applies
  /// `FreezeFrame` (one history entry) and starts the still job.
  EditResult freeze(ItemId item, TimeUs at, TimeUs duration) {
    final project = _project;
    final loc = project?.index.locate(item);
    final clip = loc?.item;
    if (project == null || loc == null || clip is! MediaClip) return const EditUnchanged();
    final source = project.pool[clip.media];
    if (source == null) return const EditUnchanged();
    final rate = project.settings.frameRate;
    final spec = StillSpec(clip.media, FreezeFrame.sourceTimeAt(clip, at, rate), sourceQuickHash: source.fingerprint.quickHash);
    var id = _ids.mediaId();
    while (project.pool.contains(id)) {
      id = _ids.mediaId();
    }
    final still = MediaAsset(
      id: id,
      kind: MediaKind.still,
      displayName: '${source.displayName} (freeze frame)',
      locator: AppRelativeLocator(AppRoot.support, ManagedStore.projectAssetRelPath(projectId.value, 'stills', '${id.value}.png')),
      ownership: MediaOwnership.projectOwned,
      fingerprint: MediaFingerprint(sizeBytes: 0, quickHash: spec.specHash),
      probe: MediaProbe(kind: MediaKind.still, hasVideo: true),
      origin: MediaOrigin.derived,
      derived: spec,
      status: const PendingStatus(unstartedJobId),
      addedAt: _clock(),
    );
    _editor.applyPoolChange(AddAssets([still]));
    final result = _editor.apply(FreezeFrame(item, at, duration, id));
    if (result is! EditApplied) {
      // Never used: leave it failed so nothing starts a job for it.
      _update(id, (a) => a.copyWith(status: const FailedStatus('unused')));
      return result;
    }
    _reconcile();
    return result;
  }

  // -----------------------------------------------------------------------------------------------
  // Proxies
  // -----------------------------------------------------------------------------------------------

  /// Starts a proxy for [media] (a video asset without a ready or pending proxy). Returns whether a
  /// job was started.
  bool requestProxy(MediaId media) {
    final asset = _project?.pool[media];
    if (asset == null || asset.kind != MediaKind.video || asset.status is! ReadyStatus) return false;
    if (asset.proxy == ProxyState.ready || _byAsset.containsKey(media)) return false;
    _update(media, (a) => a.copyWith(proxy: ProxyState.pending));
    return _startProxy(media);
  }

  // -----------------------------------------------------------------------------------------------
  // Other producers
  // -----------------------------------------------------------------------------------------------

  /// Shows [job] as a task of [kind] until it ends; Cancel calls `job.cancel()`. Returns [job].
  MediaJob<T> track<T>(EditorTaskKind kind, MediaJob<T> job, {String? label}) {
    if (_disposed) return job;
    final task = _Task(id: job.id, kind: kind, label: label ?? ClipStrings.taskLabel(kind), cancel: job.cancel);
    _add(task);
    task.sub = job.progress.listen((f) => _progress(task, f), onError: (Object _) {});
    job.result.then((_) => _remove(task), onError: (Object e) {
      if (e is EngineCancelled) {
        _remove(task);
      } else {
        _fail(task);
      }
    });
    return job;
  }

  /// Starts a task of [kind] that the caller drives; [onCancel] makes it cancellable and [onRetry]
  /// retryable after a failure.
  EditorTaskHandle begin(EditorTaskKind kind, {String? label, VoidCallback? onCancel, VoidCallback? onRetry}) {
    final task = _Task(
      id: 'task-${_local++}',
      kind: kind,
      label: label ?? ClipStrings.taskLabel(kind),
      cancel: onCancel,
      retry: onRetry,
    );
    _add(task);
    return _Handle(this, task);
  }

  // -----------------------------------------------------------------------------------------------
  // Row actions
  // -----------------------------------------------------------------------------------------------

  /// Whether task [id] can be cancelled now.
  bool canCancel(String id) {
    final t = _tasks[id];
    return t != null && !t.failed && t.cancel != null;
  }

  /// Whether task [id] can be retried now.
  bool canRetry(String id) {
    final t = _tasks[id];
    return t != null && t.failed && (t.asset != null || t.retry != null);
  }

  /// Cancels task [id] (see the file header for what a cancelled reverse or freeze does).
  void cancel(String id) {
    final t = _tasks[id];
    if (t == null || t.failed) return;
    t.cancelledByUser = true;
    t.cancel?.call();
    // Tasks of other producers end here; derived and proxy jobs end through their result.
    if (t.asset == null) _remove(t);
  }

  /// Retries the failed task [id].
  void retry(String id) {
    final t = _tasks[id];
    if (t == null || !t.failed) return;
    _remove(t);
    final asset = t.asset;
    if (asset == null) {
      t.retry?.call();
      return;
    }
    if (t.kind == EditorTaskKind.proxy) {
      _update(asset, (a) => a.copyWith(proxy: ProxyState.pending));
      _startProxy(asset);
    } else {
      _update(asset, (a) => a.copyWith(status: const PendingStatus(unstartedJobId)));
      _reconcile();
    }
  }

  /// Removes the failed row [id].
  void dismiss(String id) {
    final t = _tasks[id];
    if (t != null && t.failed) _remove(t);
  }

  // -----------------------------------------------------------------------------------------------
  // Export gating
  // -----------------------------------------------------------------------------------------------

  /// The clips of [project] that wait for a pending reversed rendition or freeze still: export
  /// waits for (or cancels) them (ux.md §10.15, §11.1).
  static Set<ItemId> exportBlockersOf(EditProject project) {
    final out = <ItemId>{};
    final pool = project.pool;
    for (final track in project.tracks) {
      for (final item in track.items) {
        if (item is! MediaClip) continue;
        final media = pool[item.media];
        if (media == null) continue;
        if (media.status is PendingStatus) {
          out.add(item.id);
        } else if (item.reversed && media.status is ReadyStatus && (media.kind == MediaKind.video || media.kind == MediaKind.audio)) {
          final r = renditionFor(pool, item);
          if (r == null || r.status is PendingStatus) out.add(item.id);
        }
      }
    }
    return out;
  }

  /// The number of clips export waits for in the current project.
  int get exportBlockers {
    final p = _project;
    return p == null ? 0 : exportBlockersOf(p).length;
  }

  /// Whether export must wait for background jobs.
  bool get exportBlocked => exportBlockers > 0;

  /// Cancels every reverse and freeze job ("Cancel reverse" of the export wait).
  void cancelExportBlockers() {
    for (final t in _tasks.values.toList()) {
      if (t.kind == EditorTaskKind.reverse || t.kind == EditorTaskKind.freeze) cancel(t.id);
    }
  }

  /// The reversed rendition [clip] plays from: a ready one covering its source range, else a
  /// pending one, else a failed one, else null.
  static MediaAsset? renditionFor(MediaPool pool, MediaClip clip) {
    final media = pool[clip.media];
    if (media == null) return null;
    final range = clip.sourceRange;
    MediaAsset? pending;
    MediaAsset? failed;
    for (final a in pool.assets.values) {
      final spec = a.derived;
      if (spec is! ReversedSpec || spec.media != clip.media || spec.sourceQuickHash != media.fingerprint.quickHash) continue;
      if (spec.range.start > range.start || spec.range.end < range.end) continue;
      switch (a.status) {
        case ReadyStatus():
          return a;
        case PendingStatus():
          pending ??= a;
        case FailedStatus():
          failed ??= a;
      }
    }
    return pending ?? failed;
  }

  // -----------------------------------------------------------------------------------------------
  // Lifecycle
  // -----------------------------------------------------------------------------------------------

  /// Cancels the running jobs without touching the project (editor closing); pending assets
  /// resume on the next open.
  void suspend() {
    if (_suspended) return;
    _suspended = true;
    for (final t in _tasks.values.toList()) {
      t.sub?.cancel();
      t.quiet = true;
      t.cancel?.call();
    }
    _tasks.clear();
    _byAsset.clear();
  }

  /// Stops listening and cancels running jobs quietly.
  void dispose() {
    if (_disposed) return;
    suspend();
    _disposed = true;
    _removeListener?.call();
    _removeListener = null;
  }

  // -----------------------------------------------------------------------------------------------
  // Internals
  // -----------------------------------------------------------------------------------------------

  void _onState(EditorState state) {
    final pool = state.project?.pool;
    if (pool == null || identical(pool, _seenPool)) return;
    _seenPool = pool;
    if (_reconcileQueued) return;
    _reconcileQueued = true;
    scheduleMicrotask(() {
      _reconcileQueued = false;
      _reconcile();
    });
  }

  /// Starts a job for every pending asset that needs one and is not tracked.
  void _reconcile() {
    if (_disposed || _suspended || !_session.isOpen) return;
    final project = _project;
    if (project == null) return;
    Set<MediaId>? used;
    Set<MediaId> usedMedia() => used ??= {
          for (final t in project.tracks)
            for (final i in t.items)
              if (i is MediaClip) i.media,
        };
    Set<MediaId>? needed;
    Set<MediaId> neededRenditions() => needed ??= {
          for (final t in project.tracks)
            for (final i in t.items)
              if (i is MediaClip && i.reversed)
                if (renditionFor(project.pool, i) case final r? when r.status is PendingStatus) r.id,
        };
    for (final asset in project.pool.assets.values) {
      if (_byAsset.containsKey(asset.id)) continue;
      final status = asset.status;
      if (status is PendingStatus) {
        final fresh = status.jobId == unstartedJobId;
        switch (asset.derived) {
          case ReversedSpec():
            if (fresh || neededRenditions().contains(asset.id)) _startReverse(asset);
          case StillSpec():
            if (fresh || usedMedia().contains(asset.id)) _startStill(asset);
          case null:
            break;
        }
      } else if (status is ReadyStatus && asset.proxy == ProxyState.pending) {
        _startProxy(asset.id);
      }
    }
  }

  void _startReverse(MediaAsset asset) {
    final spec = asset.derived! as ReversedSpec;
    _startDerived(
      asset,
      EditorTaskKind.reverse,
      spec.media,
      (media, path) => _jobs.reverse(media, spec.range, outputPath: path),
      duration: spec.range.duration,
    );
  }

  void _startStill(MediaAsset asset) {
    final spec = asset.derived! as StillSpec;
    _startDerived(asset, EditorTaskKind.freeze, spec.media, (media, path) => _jobs.freezeFrame(media, spec.sourceTime, outputPath: path));
  }

  void _startDerived(
    MediaAsset asset,
    EditorTaskKind kind,
    MediaId sourceId,
    MediaJob<GeneratedAsset> Function(EngineMedia media, String outputPath) start, {
    TimeUs? duration,
  }) {
    final project = _project!;
    final locator = asset.locator;
    final source = _session.compiler?.resolve(project, sourceId);
    if (source == null || locator is! AppRelativeLocator) {
      _update(asset.id, (a) => a.copyWith(status: FailedStatus(EngineErrorCode.mediaOffline.name)));
      return;
    }
    final MediaJob<GeneratedAsset> job;
    try {
      job = start(source, _resolvePath(locator));
    } on Object catch (e) {
      debugPrint('[TasksController] Could not start ${kind.name}: ${e.runtimeType}');
      _update(asset.id, (a) => a.copyWith(status: FailedStatus(_codeOf(e))));
      return;
    }
    job.setPriority(JobPriority.interactive);
    final task = _Task(id: job.id, kind: kind, label: ClipStrings.taskLabel(kind), asset: asset.id, cancel: job.cancel);
    _add(task);
    _update(asset.id, (a) => a.copyWith(status: PendingStatus(job.id)));
    task.sub = job.progress.listen((f) => _progress(task, f), onError: (Object _) {});
    job.result.then((r) => _derivedDone(task, r, duration), onError: (Object e) => _derivedFailed(task, e));
  }

  void _derivedDone(_Task task, GeneratedAsset r, TimeUs? duration) {
    if (task.quiet || _disposed) return;
    _remove(task);
    final asset = _project?.pool[task.asset!];
    if (asset == null) return;
    final d = r.duration ?? duration ?? asset.fingerprint.duration;
    final derived = asset.derived;
    _update(
      asset.id,
      (a) => a.copyWith(
        status: AssetStatus.ready,
        fingerprint: MediaFingerprint(sizeBytes: r.sizeBytes, quickHash: derived?.specHash ?? a.fingerprint.quickHash, duration: d),
        probe: a.probe.copyWith(sizeBytes: r.sizeBytes, duration: a.kind == MediaKind.still ? 0 : d),
      ),
    );
    _resync();
  }

  void _derivedFailed(_Task task, Object e) {
    if (task.quiet || _disposed) return;
    final id = task.asset!;
    if (e is EngineCancelled || task.cancelledByUser) {
      _remove(task);
      _update(id, (a) => a.copyWith(status: const FailedStatus('cancelled')));
      _undoWaiting(task.kind, id);
      _resync();
      return;
    }
    _update(id, (a) => a.copyWith(status: FailedStatus(_codeOf(e))));
    _fail(task);
    _resync();
  }

  /// After a cancel: plays the clips waiting for rendition [id] forward, or removes the clips that
  /// show still [id] (one history entry).
  void _undoWaiting(EditorTaskKind kind, MediaId id) {
    final project = _project;
    if (project == null || !_editor.canEdit) return;
    final asset = project.pool[id];
    if (asset == null) return;
    final commands = <EditCommand>[];
    String label;
    if (kind == EditorTaskKind.reverse) {
      label = ClipStrings.cancelReverseLabel;
      for (final t in project.tracks) {
        if (t.locked) continue;
        for (final i in t.items) {
          if (i is MediaClip && i.reversed && renditionFor(project.pool, i)?.id == id) commands.add(SetReversed(i.id, false));
        }
      }
    } else {
      label = ClipStrings.cancelFreezeLabel;
      final ids = <ItemId>{
        for (final t in project.tracks)
          if (!t.locked)
            for (final i in t.items)
              if (i is MediaClip && i.media == id) i.id,
      };
      if (ids.isNotEmpty) commands.add(DeleteItems(ids, ripple: true));
    }
    if (commands.isEmpty) return;
    _editor.apply(CompositeCommand(label, commands));
  }

  bool _startProxy(MediaId id) {
    final project = _project;
    final asset = project?.pool[id];
    if (project == null || asset == null) return false;
    final source = _session.compiler?.resolve(project, id);
    if (source == null) {
      _update(id, (a) => a.copyWith(proxy: ProxyState.none));
      return false;
    }
    final MediaJob<GeneratedAsset> job;
    try {
      job = _jobs.proxy(source);
    } on Object catch (e) {
      debugPrint('[TasksController] Could not start a proxy: ${e.runtimeType}');
      _update(id, (a) => a.copyWith(proxy: ProxyState.failed));
      return false;
    }
    job.setPriority(JobPriority.background);
    final task = _Task(id: job.id, kind: EditorTaskKind.proxy, label: ClipStrings.taskLabel(EditorTaskKind.proxy), asset: id, cancel: job.cancel);
    _add(task);
    task.sub = job.progress.listen((f) => _progress(task, f), onError: (Object _) {});
    job.result.then((_) {
      if (task.quiet || _disposed) return;
      _remove(task);
      _update(id, (a) => a.copyWith(proxy: ProxyState.ready));
      _resync();
    }, onError: (Object e) {
      if (task.quiet || _disposed) return;
      if (e is EngineCancelled || task.cancelledByUser) {
        _remove(task);
        _update(id, (a) => a.copyWith(proxy: ProxyState.none));
      } else {
        _update(id, (a) => a.copyWith(proxy: ProxyState.failed));
        _fail(task);
      }
    });
    return true;
  }

  void _update(MediaId id, MediaAsset Function(MediaAsset a) change) {
    if (_disposed || !_editor.mounted) return;
    final asset = _session.editOrNull?.project.pool[id];
    if (asset == null) return;
    final next = change(asset);
    if (next == asset) return;
    _editor.applyPoolChange(UpdateAsset(next));
  }

  /// Pool status changes are not commits: re-sync the preview plan so it picks up a finished (or
  /// failed) rendition.
  void _resync() {
    final project = _session.editOrNull?.project;
    if (project != null) _session.planSync?.schedule(project);
  }

  static String _codeOf(Object e) => e is EngineFailure ? e.code.name : EngineErrorCode.internal.name;

  void _add(_Task task) {
    _tasks[task.id] = task;
    final asset = task.asset;
    if (asset != null) _byAsset[asset] = task.id;
    _publish();
  }

  void _remove(_Task task) {
    task.sub?.cancel();
    task.sub = null;
    if (_tasks[task.id] != task) return;
    _tasks.remove(task.id);
    final asset = task.asset;
    if (asset != null && _byAsset[asset] == task.id) _byAsset.remove(asset);
    _publish();
  }

  void _fail(_Task task) {
    task.sub?.cancel();
    task.sub = null;
    if (_tasks[task.id] != task) return;
    task.failed = true;
    final asset = task.asset;
    // A failed asset is not "being produced": reconcile must not restart it until a retry.
    if (asset != null && _byAsset[asset] == task.id) _byAsset.remove(asset);
    _publish();
  }

  void _progress(_Task task, double fraction) {
    if (_tasks[task.id] != task || task.failed) return;
    final f = fraction.isNaN ? null : fraction.clamp(0.0, 1.0).toDouble();
    if (f == task.progress) return;
    task.progress = f;
    _publish();
  }

  void _publish() {
    if (_disposed || !_editor.mounted) return;
    _editor.setTasks(tasks);
  }
}

/// Builds the value of `tasksControllerProvider` for [id]: alive while the editor is open, then
/// suspended and released when the session detaches.
TasksController createTasksController(Ref<Object?> ref, ProjectId id) {
  final session = ref.watch(editorSessionProvider(id));
  final editor = ref.watch(editorControllerProvider(id).notifier);
  final runtime = ref.watch(editorRuntimeProvider);
  final controller = TasksController(
    projectId: id,
    editor: editor,
    session: session,
    jobs: ref.watch(editorEngineProvider).jobs,
    resolvePath: runtime == null ? TasksController.unconfiguredPath : runtime.roots.resolve,
  );
  final link = ref.keepAlive();
  var wasOpen = session.isOpen;
  void onAttached() {
    if (session.attached.value) {
      wasOpen = true;
      return;
    }
    if (!wasOpen) return;
    controller.suspend();
    link.close();
  }

  session.attached.addListener(onAttached);
  ref.onDispose(() {
    try {
      session.attached.removeListener(onAttached);
    } on Object catch (_) {
      // The session's notifier was disposed first.
    }
    controller.dispose();
  });
  return controller;
}

/// The background tasks of an open project (ux.md §10.15). Read it to start reverse, freeze and
/// proxy jobs or to report other jobs; the rows are in `EditorState.tasks`.
final tasksControllerProvider = Provider.autoDispose.family<TasksController, ProjectId>(
  (ref, id) => createTasksController(ref, id),
  name: 'tasksControllerProvider',
);

class _Task {
  _Task({required this.id, required this.kind, required this.label, this.asset, this.cancel, this.retry});

  final String id;
  final EditorTaskKind kind;
  final String label;
  final MediaId? asset;
  final VoidCallback? cancel;
  final VoidCallback? retry;
  double? progress;
  bool failed = false;
  bool cancelledByUser = false;
  bool quiet = false;
  StreamSubscription<double>? sub;

  EditorTaskInfo get info => EditorTaskInfo(id: id, kind: kind, label: label, progress: progress, failed: failed);
}

final class _Handle implements EditorTaskHandle {
  _Handle(this._owner, this._task);

  final TasksController _owner;
  final _Task _task;

  @override
  String get id => _task.id;

  @override
  void progress(double? fraction) {
    if (fraction == null) {
      if (_task.progress == null || _owner._tasks[_task.id] != _task) return;
      _task.progress = null;
      _owner._publish();
    } else {
      _owner._progress(_task, fraction);
    }
  }

  @override
  void complete() => _owner._remove(_task);

  @override
  void fail() => _owner._fail(_task);
}
