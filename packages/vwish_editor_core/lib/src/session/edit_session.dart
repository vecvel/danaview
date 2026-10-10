// OWNER: CORE-19
//
// The editing session of one open project (ARCH §7.3, domain.md §7.2): snapshot history,
// transactions, coalescing, pool changes and edits, view updates and the GC guard.
//
// * **Snapshots, not inverse commands.** Every entry stores the `Timeline` root before and after
//   (structurally shared). Undo/redo restore a snapshot's lanes, markers and settings identically
//   and only re-stamp the root revision.
// * **The pool lives outside snapshots.** Imports and probe/proxy/status updates are sticky
//   (`applyPoolChange`, never in history: undo never empties the bin). Relink and remove are
//   undoable (`applyPoolEdit`): the entry records a `PoolDelta` whose before/after values are
//   applied to the *current* pool on undo/redo. Assets a command adds (cross-project paste) are
//   sticky too; assets a command removes or changes get a delta.
// * **Stamps.** One monotonic counter, initialized to `max(revision, max changedAt) + 1` of the
//   opened project. Every apply, transaction update, pool edit, undo, redo and jump takes a fresh
//   stamp; stamps are never reused, so caches keyed on `Timeline.revision` / `Track.changedAt`
//   cannot collide after "undo, then a new edit". Pool and view changes bump only `docRevision`.
// * **editCount** counts committed entries (a coalesced apply joins an entry and does not count);
//   it lives in `ProjectMeta`, outside snapshots, and never decrements.
// * **Transactions** (gestures): `update` runs its command on the base captured at `begin` (never
//   on the previous update; a refused update shows the base), `commit` records exactly one entry
//   (none when nothing changed), `cancel` restores the base. A second `begin`, or any `apply`,
//   pool edit, undo, redo or jump while a transaction is open, cancels it first. Sticky pool
//   changes and view updates do not cancel it.
// * **Coalescing**: an `apply` with the same non-null `coalesceKey` as the newest entry, within
//   `coalesceWindow` of that entry's last change and with nothing else recorded or undone in
//   between, replaces that entry's `after` instead of pushing a new entry (typing).
// * **Limits**: `HistoryPolicy` (200 entries / ≈ 48 MB), oldest evicted, the newest always kept.
// * **Never throws** for command problems: exceptions inside a command become
//   `InternalInconsistency` and leave the project unchanged.

import 'package:meta/meta.dart';

import '../ids/ids.dart';
import '../model/items.dart';
import '../model/pool/media_asset.dart';
import '../model/pool/media_pool.dart';
import '../model/project.dart';
import '../model/timeline.dart';
import '../model/view_state.dart';
import '../model/visual_props.dart';
import '../ops/dry_run.dart' as ops;
import '../ops/edit_command.dart';
import '../ops/edit_context.dart';
import '../ops/limits.dart';
import '../ops/outcome.dart';
import '../ops/rejections.dart';
import '../validate/validator.dart';
import '../validate/violation.dart';
import 'history.dart';
import 'media_refs.dart';

/// A gesture's transaction (ARCH §7.3; wrapped by the UI's `EditTransaction`, ux.md §16.4).
abstract interface class SessionTransaction {
  /// History label of the entry [commit] records.
  String get label;

  /// Runs [command] on the base captured at `begin` (replacing the previous update) and shows
  /// the result as the session's project. A refused or no-op update shows the base. Returns the
  /// outcome; on a closed transaction it returns a no-op outcome and changes nothing.
  EditOutcome update(EditCommand command);

  /// The dry run of the latest update (placements for drag ghosts, the rejection), or null
  /// before the first update.
  EditPreview? get preview;

  /// The outcome of the latest update, or null before the first update.
  EditOutcome? get lastOutcome;

  /// Records exactly one history entry for the latest update (none when it changed nothing) and
  /// closes the transaction. On a closed transaction it is a no-op.
  EditOutcome commit();

  /// Restores the base and closes the transaction (idempotent).
  void cancel();

  /// Whether the transaction is still open.
  bool get isOpen;
}

/// The editing session of one open project (ARCH §7.3). Pure Dart, single-threaded.
final class EditSession {
  /// Opens a session on [initial]. [ids] mints item/lane/marker ids (default: secure random),
  /// [policy] sets the history limits, [clock] gives the current UTC time (coalescing window, `updatedAt`, `addedAt` of pasted
  /// media), [editPolicy] the command policy and D-14 caps (from `EditorCapabilities`).
  EditSession(
    EditProject initial, {
    IdGenerator? ids,
    HistoryPolicy policy = const HistoryPolicy(),
    EditPolicy editPolicy = const EditPolicy(),
    DateTime Function()? clock,
  })  : historyPolicy = policy,
        _committed = initial,
        _clock = clock ?? _utcNow,
        _ctx = EditContext(ids: ids, policy: editPolicy),
        _nextStamp = initialStampOf(initial.timeline);

  static DateTime _utcNow() => DateTime.now().toUtc();

  /// The first stamp a session opened on [timeline] uses: `max(revision, max changedAt) + 1`.
  static int initialStampOf(Timeline timeline) {
    var m = timeline.revision;
    for (final t in timeline.tracks) {
      if (t.changedAt > m) m = t.changedAt;
    }
    return m + 1;
  }

  /// History limits.
  final HistoryPolicy historyPolicy;

  final DateTime Function() _clock;
  EditContext _ctx;
  EditProject _committed;
  int _nextStamp;
  final List<HistoryEntry> _entries = [];
  int _cursor = 0;
  int _bytes = 0;
  _Transaction? _tx;

  /// The newest entry while it may still absorb a coalescing apply.
  HistoryEntry? _coalesceTarget;

  // -----------------------------------------------------------------------------------------
  // State
  // -----------------------------------------------------------------------------------------

  /// The current project: the transaction's working copy while one is open, else the committed
  /// project.
  EditProject get project => _tx?.working ?? _committed;

  /// The committed project (the base of an open transaction).
  EditProject get committedProject => _committed;

  /// Undo/redo availability and labels.
  HistoryStatus get history => HistoryStatus(
        position: _cursor,
        length: _entries.length,
        undoLabel: _cursor > 0 ? _entries[_cursor - 1].label : null,
        redoLabel: _cursor < _entries.length ? _entries[_cursor].label : null,
      );

  /// The kept entries, oldest first (entries `[0, history.position)` are applied).
  List<HistoryEntry> get entries => List.unmodifiable(_entries);

  /// Approximate bytes held by the kept entries.
  int get historyBytes => _bytes;

  /// Labels of the newest [max] entries, newest first (redoable ones included; compare the index
  /// with `history.length - history.position` to mark the current position).
  List<String> recentLabels(int max) => [for (final e in _entries.reversed.take(max < 0 ? 0 : max)) e.label];

  /// The open transaction, if any.
  SessionTransaction? get transaction => _tx;

  /// The stamp the next change will use (stamps used so far are all smaller).
  int get nextStamp => _nextStamp;

  /// The command policy and D-14 caps.
  EditPolicy get editPolicy => _ctx.policy;

  set editPolicy(EditPolicy policy) => _ctx = _ctx.copyWith(policy: policy);

  /// The per-session D-14 limit checker (its packing cache is shared by every command; use
  /// `limits.countsOf(project).exceeded(editPolicy)` for the banner and export preflight).
  LayerLimits get limits => _ctx.limits;

  // -----------------------------------------------------------------------------------------
  // Commands
  // -----------------------------------------------------------------------------------------

  /// Applies [command] and records one history entry (or joins the newest one, see the
  /// coalescing rule in the file header). Refused and no-op commands record nothing. Cancels an
  /// open transaction first.
  EditOutcome apply(
    EditCommand command, {
    String? coalesceKey,
    Duration coalesceWindow = const Duration(seconds: 1),
  }) {
    _cancelTransaction();
    final now = _clock();
    final out = _run(_committed, command, now, stamp: _nextStamp);
    if (!out.changed) return _withProject(out, _committed);
    _nextStamp++;
    final top = _coalesceTarget;
    final merge = coalesceKey != null &&
        top != null &&
        top.coalesceKey == coalesceKey &&
        _cursor == _entries.length &&
        identical(_entries.last, top) &&
        !now.difference(top.at).isNegative &&
        now.difference(top.at) <= coalesceWindow;
    return _record(
      label: command.label,
      result: out.project,
      out: out,
      now: now,
      delta: _poolDeltaOf(_committed.pool, out.project.pool),
      coalesceKey: coalesceKey,
      merge: merge,
    );
  }

  /// Dry-runs [command] on the current project (no stamp, nothing recorded).
  EditPreview dryRun(EditCommand command) {
    final base = project;
    try {
      return ops.dryRun(base, command, _ctx.copyWith(now: _clock()));
    } catch (e) {
      return EditPreview.rejected(InternalInconsistency(const [], detail: e.runtimeType.toString()));
    }
  }

  /// Opens a transaction labelled [label] on the current committed project, cancelling an open
  /// one first.
  SessionTransaction begin(String label) {
    _cancelTransaction();
    return _tx = _Transaction(this, label);
  }

  // -----------------------------------------------------------------------------------------
  // Undo / redo
  // -----------------------------------------------------------------------------------------

  /// Undoes the newest applied entry, or returns null when there is none.
  HistoryStep? undo() => jump(-1);

  /// Re-applies the next undone entry, or returns null when there is none.
  HistoryStep? redo() => jump(1);

  /// Moves [steps] entries back (negative) or forward (positive) as one combined step with one
  /// new stamp (clamped to the available entries). Returns null when nothing moved. Cancels an
  /// open transaction first.
  HistoryStep? jump(int steps) {
    _cancelTransaction();
    final target = (_cursor + steps).clamp(0, _entries.length);
    if (target == _cursor) return null;
    final now = _clock();
    var pool = _committed.pool;
    final labels = <String>[];
    final affected = <ItemId>{};
    final Timeline snapshot;
    final HistoryDirection direction;
    if (target < _cursor) {
      direction = HistoryDirection.undo;
      for (var i = _cursor - 1; i >= target; i--) {
        final e = _entries[i];
        labels.add(e.label);
        affected.addAll(e.affected);
        pool = _applyValues(pool, e.poolDelta?.before);
      }
      snapshot = _entries[target].before;
    } else {
      direction = HistoryDirection.redo;
      for (var i = _cursor; i < target; i++) {
        final e = _entries[i];
        labels.add(e.label);
        affected.addAll(e.affected);
        pool = _applyValues(pool, e.poolDelta?.after);
      }
      snapshot = _entries[target - 1].after;
    }
    final previous = _committed.timeline;
    final timeline = snapshot.copyWith(revision: _nextStamp++);
    _committed = _committed.copyWith(
      timeline: timeline,
      pool: pool,
      meta: _committed.meta.copyWith(updatedAt: now),
      docRevision: _committed.docRevision + 1,
    );
    _cursor = target;
    _coalesceTarget = null;
    final index = _committed.index;
    final still = {for (final id in affected) if (index.locate(id) != null) id};
    return HistoryStep(
      direction: direction,
      labels: labels,
      project: _committed,
      affected: affected,
      changedTracks: _changedTracks(previous, timeline),
      selection: still.isEmpty ? null : SelectionHint(still),
    );
  }

  // -----------------------------------------------------------------------------------------
  // Pool and view
  // -----------------------------------------------------------------------------------------

  /// Applies a sticky pool change (imports, probe/proxy/status updates): never in history, bumps
  /// only `docRevision`. `UpdateAsset` of an asset that is not in the pool is ignored. An open
  /// transaction stays open and sees the new pool.
  void applyPoolChange(PoolChange change) {
    final current = _committed.pool;
    final MediaPool pool;
    switch (change) {
      case AddAssets(:final assets):
        if (assets.isEmpty) return;
        pool = MediaPool({...current.assets, for (final a in assets) a.id: a});
      case UpdateAsset(:final asset):
        final old = current[asset.id];
        if (old == null || old == asset) return;
        pool = current.upsert(asset);
    }
    if (pool == current) return;
    _committed = _committed.copyWith(pool: pool, docRevision: _committed.docRevision + 1);
  }

  /// Applies an undoable pool edit as one history entry with a `PoolDelta` (label from the
  /// edit). [adjust], when given, runs on the edited pool in the same entry (e.g. the clamps of a
  /// relink to a shorter file); its refusal refuses the whole edit.
  ///
  /// * `RelinkAssets`: every id must be in the pool (`MediaUnavailable`) and each replacement must
  ///   keep its id (`InvalidValue('replacements')`).
  /// * `RemoveAssets`: every id must be in the pool (`MediaUnavailable`) and unused by the
  ///   current timeline and by the derived assets that stay (`InvalidValue('mediaInUse')`).
  /// * The result must not break media invariants (kind, source range) on the lanes that use the
  ///   edited assets (`InternalInconsistency`).
  ///
  /// Cancels an open transaction first. Nothing to do is a no-op.
  EditOutcome applyPoolEdit(PoolEdit edit, {EditCommand? adjust}) {
    _cancelTransaction();
    final now = _clock();
    final base = _committed;
    final pool = base.pool;
    final Set<MediaId> touched;
    final MediaPool next;
    switch (edit) {
      case RelinkAssets(:final replacements):
        for (final e in replacements.entries) {
          if (!pool.contains(e.key)) return EditOutcome.rejected(base, MediaUnavailable(e.key));
          if (e.value.id != e.key) return EditOutcome.rejected(base, const InvalidValue('replacements'));
        }
        touched = {for (final e in replacements.entries) if (pool[e.key] != e.value) e.key};
        next = MediaPool({...pool.assets, for (final id in touched) id: replacements[id]!});
      case RemoveAssets(:final ids):
        for (final id in ids) {
          if (!pool.contains(id)) return EditOutcome.rejected(base, MediaUnavailable(id));
        }
        final used = mediaReferencedBy(base.timeline);
        final derivedUsers = {
          for (final a in pool.assets.values)
            if (!ids.contains(a.id))
              ...switch (a.derived) {
                ReversedSpec(:final media) => [media],
                StillSpec(:final media) => [media],
                null => const <MediaId>[],
              },
        };
        if (ids.any(used.contains) || ids.any(derivedUsers.contains)) {
          return EditOutcome.rejected(base, const InvalidValue('mediaInUse'));
        }
        touched = {...ids};
        next = pool.without(ids);
    }
    if (touched.isEmpty) return EditOutcome(project: base, noop: true);

    final stamp = _nextStamp;
    var result = base.copyWith(pool: next);
    EditOutcome? adjusted;
    if (adjust != null) {
      adjusted = _run(result, adjust, now, stamp: stamp);
      final r = adjusted.rejection;
      if (r != null) return EditOutcome.rejected(base, r);
      if (adjusted.changed) result = adjusted.project;
    }
    final lanes = {
      for (final t in result.tracks)
        if (t.items.any((i) => _uses(i, touched))) t.id,
    };
    if (lanes.isNotEmpty) {
      final v = _newViolations(base, result, lanes);
      if (v.isNotEmpty) return EditOutcome.rejected(base, InternalInconsistency(v));
    }
    _nextStamp++;
    if (result.timeline.revision != stamp) result = result.copyWith(timeline: result.timeline.copyWith(revision: stamp));
    final affected = <ItemId>{
      for (final t in base.tracks)
        for (final i in t.items)
          if (_uses(i, touched)) i.id,
      ...?adjusted?.affected,
    };
    final out = EditOutcome(
      project: result,
      affected: affected,
      changedTracks: adjusted?.changedTracks ?? const {},
      createdTracks: adjusted?.createdTracks ?? const {},
      selection: adjusted?.selection,
      notices: adjusted?.notices ?? const [],
    );
    return _record(
      label: edit.label,
      result: result,
      out: out,
      now: now,
      delta: PoolDelta(
        before: {for (final id in touched) id: pool[id]},
        after: {for (final id in touched) id: next[id]},
      ),
      merge: false,
    );
  }

  /// Changes the persisted view state (playhead, zoom, toggles): never in history, bumps only
  /// `docRevision`.
  void updateView(ViewState Function(ViewState view) update) {
    final view = update(_committed.view);
    if (view == _committed.view) return;
    _committed = _committed.copyWith(view: view, docRevision: _committed.docRevision + 1);
  }

  /// Media the open session may still need (the GC guard of ARCH §9.4): ids referenced by the
  /// current timeline (and an open transaction's working copy), by every history snapshot, by
  /// every pool delta (assets undo/redo could bring back), every asset of the current pool, and
  /// the sources of derived assets among them.
  Set<MediaId> retainedMedia() {
    final c = MediaRefCollector()
      ..addTimeline(project.timeline)
      ..addTimeline(_committed.timeline);
    final extra = <MediaAsset>[];
    for (final e in _entries) {
      c
        ..addTimeline(e.before)
        ..addTimeline(e.after);
      final d = e.poolDelta;
      if (d == null) continue;
      for (final m in [d.before, d.after]) {
        for (final entry in m.entries) {
          c.ids.add(entry.key);
          final a = entry.value;
          if (a != null) extra.add(a);
        }
      }
    }
    final pool = project.pool;
    c.ids.addAll(pool.assets.keys);
    c.addDerivedSources(pool, extra);
    return Set.unmodifiable(c.ids);
  }

  // -----------------------------------------------------------------------------------------
  // Internals
  // -----------------------------------------------------------------------------------------

  void _cancelTransaction() => _tx?.cancel();

  EditOutcome _run(EditProject base, EditCommand command, DateTime now, {int? stamp}) {
    try {
      return ops.applyCommand(base, command, _ctx.copyWith(now: now, stamp: stamp));
    } catch (e) {
      return EditOutcome.rejected(base, InternalInconsistency(const [], detail: e.runtimeType.toString()));
    }
  }

  /// Commits [result] (whose timeline is already stamped) as a new entry or merged into the
  /// newest one, and returns [out] with the committed project.
  EditOutcome _record({
    required String label,
    required EditProject result,
    required EditOutcome out,
    required DateTime now,
    required PoolDelta? delta,
    String? coalesceKey,
    required bool merge,
  }) {
    final before = _committed;
    _committed = EditProject(
      id: before.id,
      meta: before.meta.copyWith(updatedAt: now, editCount: merge ? before.meta.editCount : before.meta.editCount + 1),
      timeline: result.timeline,
      pool: result.pool,
      view: before.view,
      docRevision: before.docRevision + 1,
    );
    if (merge) {
      final top = _entries.last;
      final merged = HistoryEntry(
        label: top.label,
        before: top.before,
        after: result.timeline,
        at: now,
        approxBytes: approxEntryBytes(top.before, result.timeline),
        poolDelta: _mergeDeltas(top.poolDelta, delta),
        affected: {...top.affected, ...out.affected},
        selection: out.selection ?? top.selection,
        coalesceKey: coalesceKey,
      );
      _bytes += merged.approxBytes - top.approxBytes;
      _entries[_entries.length - 1] = merged;
      _coalesceTarget = merged;
    } else {
      for (var i = _entries.length - 1; i >= _cursor; i--) {
        _bytes -= _entries.removeLast().approxBytes;
      }
      final entry = HistoryEntry(
        label: label,
        before: before.timeline,
        after: result.timeline,
        at: now,
        approxBytes: approxEntryBytes(before.timeline, result.timeline),
        poolDelta: delta,
        affected: out.affected,
        selection: out.selection,
        coalesceKey: coalesceKey,
      );
      _entries.add(entry);
      _bytes += entry.approxBytes;
      _evict();
      _cursor = _entries.length;
      _coalesceTarget = coalesceKey == null ? null : entry;
    }
    return _withProject(out, _committed);
  }

  void _evict() {
    while (_entries.length > 1 &&
        (_entries.length > historyPolicy.maxEntries || _bytes > historyPolicy.maxApproxBytes)) {
      _bytes -= _entries.removeAt(0).approxBytes;
    }
  }

  static EditOutcome _withProject(EditOutcome o, EditProject p) => identical(o.project, p)
      ? o
      : EditOutcome(
          project: p,
          affected: o.affected,
          changedTracks: o.changedTracks,
          createdTracks: o.createdTracks,
          selection: o.selection,
          notices: o.notices,
          rejection: o.rejection,
          noop: o.noop,
        );

  static bool _uses(Object item, Set<MediaId> ids) {
    if (item is! MediaClip) return false;
    if (ids.contains(item.media)) return true;
    final look = item.visual?.look;
    return look is ImportedLut && ids.contains(look.lut);
  }

  static List<Violation> _newViolations(EditProject before, EditProject after, Set<TrackId> lanes) {
    final now = validate(after, only: lanes);
    if (now.isEmpty) return const [];
    final had = {for (final v in validate(before, only: lanes)) (v.code, v.track, v.subject)};
    return [for (final v in now) if (!had.contains((v.code, v.track, v.subject))) v];
  }

  /// Removed or changed assets between [before] and [after] (additions are sticky: no delta).
  static PoolDelta? _poolDeltaOf(MediaPool before, MediaPool after) {
    if (identical(before, after)) return null;
    final b = <MediaId, MediaAsset?>{};
    final a = <MediaId, MediaAsset?>{};
    for (final e in before.assets.entries) {
      final now = after[e.key];
      if (now == e.value) continue;
      b[e.key] = e.value;
      a[e.key] = now;
    }
    return b.isEmpty ? null : PoolDelta(before: b, after: a);
  }

  static PoolDelta? _mergeDeltas(PoolDelta? first, PoolDelta? second) {
    if (first == null) return second;
    if (second == null) return first;
    return PoolDelta(
      before: {...second.before, ...first.before},
      after: {...first.after, ...second.after},
    );
  }

  static MediaPool _applyValues(MediaPool pool, Map<MediaId, MediaAsset?>? values) {
    if (values == null || values.isEmpty) return pool;
    final m = Map.of(pool.assets);
    values.forEach((id, asset) {
      if (asset == null) {
        m.remove(id);
      } else {
        m[id] = asset;
      }
    });
    return MediaPool(m);
  }

  static Set<TrackId> _changedTracks(Timeline from, Timeline to) {
    final old = {for (final t in from.tracks) t.id: t};
    final changed = <TrackId>{};
    for (final t in to.tracks) {
      if (!identical(old.remove(t.id), t)) changed.add(t.id);
    }
    changed.addAll(old.keys);
    return changed;
  }
}

/// Approximate retained size of an entry from [before] to [after] (ARCH §7.3): 64 B per entry
/// and per changed lane, 8 B per slot of every changed item list, ~300 B per new item, new
/// transition, new marker and changed settings.
@visibleForTesting
int approxEntryBytes(Timeline before, Timeline after) {
  const entry = 64, lane = 64, slot = 8, object = 300;
  var bytes = entry;
  final old = {for (final t in before.tracks) t.id: t};
  for (final t in after.tracks) {
    final o = old[t.id];
    if (identical(o, t)) continue;
    bytes += lane;
    bytes += _listBytes(o?.items, t.items, slot, object);
    bytes += _listBytes(o?.transitions, t.transitions, slot, object);
  }
  bytes += _listBytes(before.markers, after.markers, slot, object);
  if (!identical(before.settings, after.settings)) bytes += object;
  return bytes;
}

int _listBytes(List<Object>? before, List<Object> after, int slot, int object) {
  if (before != null && before.length == after.length) {
    var same = true;
    for (var i = 0; i < after.length && same; i++) {
      same = identical(before[i], after[i]);
    }
    if (same) return 0;
  }
  final prev = Set<Object>.identity()..addAll(before ?? const []);
  var bytes = slot * after.length;
  for (final x in after) {
    if (!prev.contains(x)) bytes += object;
  }
  return bytes;
}

/// The session's transaction. A refused or no-op update shows the base.
final class _Transaction implements SessionTransaction {
  _Transaction(this._session, this.label) : _baseTimeline = _session._committed.timeline;

  final EditSession _session;
  final Timeline _baseTimeline;

  @override
  final String label;

  bool _open = true;
  EditCommand? _command;
  EditOutcome? _last;
  EditPreview? _preview;

  /// The pool the latest changed update ran on (to find the assets it added).
  MediaPool? _runPool;
  EditProject? _cache;
  EditProject? _cacheFor;

  @override
  bool get isOpen => _open;

  @override
  EditOutcome? get lastOutcome => _last;

  /// The working copy shown as the session's project: the latest changed update over the live
  /// pool and view, or null when it shows the base.
  EditProject? get working {
    final o = _last;
    if (o == null || !o.changed) return null;
    final committed = _session._committed;
    final cached = _cache;
    if (cached != null && identical(_cacheFor, committed)) return cached;
    var pool = committed.pool;
    final runPool = _runPool!;
    final added = [for (final a in o.project.pool.assets.values) if (!runPool.contains(a.id)) a];
    if (added.isNotEmpty) pool = MediaPool({...pool.assets, for (final a in added) a.id: a});
    _cacheFor = committed;
    return _cache = committed.copyWith(timeline: o.project.timeline, pool: pool);
  }

  @override
  EditOutcome update(EditCommand command) {
    final s = _session;
    if (!_open) return EditOutcome(project: s.project, noop: true);
    assert(identical(s._committed.timeline, _baseTimeline), 'the base changed under an open transaction');
    final base = s._committed;
    final out = s._run(base, command, s._clock(), stamp: s._nextStamp);
    if (out.changed) s._nextStamp++;
    _command = command;
    _last = out;
    _runPool = base.pool;
    _preview = null;
    _cache = null;
    return EditSession._withProject(out, s.project);
  }

  @override
  EditPreview? get preview {
    final c = _command;
    if (c == null || !_open) return _preview;
    return _preview ??= () {
      try {
        return ops.dryRun(_session._committed, c, _session._ctx.copyWith(now: _session._clock()));
      } catch (e) {
        return EditPreview.rejected(InternalInconsistency(const [], detail: e.runtimeType.toString()));
      }
    }();
  }

  @override
  EditOutcome commit() {
    final s = _session;
    if (!_open) return EditOutcome(project: s.project, noop: true);
    final result = working;
    final o = _last;
    _close();
    if (result == null || o == null) return EditOutcome(project: s._committed, noop: true);
    return s._record(
      label: label,
      result: result,
      out: o,
      now: s._clock(),
      delta: EditSession._poolDeltaOf(s._committed.pool, result.pool),
      merge: false,
    );
  }

  @override
  void cancel() {
    if (_open) _close();
  }

  void _close() {
    _open = false;
    _cache = null;
    if (identical(_session._tx, this)) _session._tx = null;
  }

  @override
  String toString() => 'SessionTransaction($label, ${_open ? 'open' : 'closed'})';
}
