// OWNER: UX-40
//
// RelinkController (ux.md §13.2): the Missing media sheet's state and actions.
//
// * Rows: one per offline asset of the pool (missing, access lost, changed), the ones the timeline
//   uses first. Each row can hold one *staged* replacement: `Locate…` picks a file (Photos or
//   Files) and `MediaPoolService.checkRelink` validates it (match, durationMismatch, differentKind,
//   unsupported); "Use updated file" stages the file a `changed` asset already points at; "Find in
//   same folder" stages the other files next to a picked path (path picks only).
// * "Relink several": one multi-pick, `autoMatch` pairs picks with missing assets, a confirm list
//   shows the matched pairs and what stayed unmatched, and confirming relinks them in one go.
// * Nothing changes the project until [RelinkController.apply]: every staged file is relinked in
//   ONE undoable "Relink media" history entry. The pool service persists the files and decides the
//   clamps of a shorter file; it applies them to the session it is given, so [apply] gives it a
//   scratch session over the committed project and replays the result through
//   `EditorController.applyPoolEdit` (the controller then owns history, save status, plan sync and
//   autosave).
// * "Remove clips that use it" and "Replace with other media…" are one history entry each as well.
//
// `relinkControllerProvider(id)` (declared by UX-01) builds this controller through
// [createRelinkController]; it lives while the sheet is open.

import 'dart:async';
import 'dart:convert' show base64;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart'
    show CompositeCommand, DeleteItems, EditCommand, EditSession, ReplaceMedia, TrimEdge, TrimItem;
import 'package:danaview_editor_core/store.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show MediaPickKind, MediaPickRequest, MediaPickSource;

import '../../../app/editor_messages.dart' show EditorMessage, EditorMessages;
import '../../../app/editor_providers.dart';
import '../../../app/strings/relink_strings.dart';
import '../../state/editor_controller.dart';
import '../../state/editor_session.dart';
import '../../state/media_health_controller.dart';

/// Where a row stands.
enum RelinkRowPhase {
  /// Waiting for a file.
  needsFile,

  /// A picked file is being checked.
  checking,

  /// The picked file matches: it will be relinked.
  ready,

  /// The picked file differs in length: the user must accept it.
  confirm,

  /// The picked file cannot replace the asset ([RelinkRow.message] says why).
  rejected,
}

/// One offline asset and the file staged for it.
@immutable
final class RelinkRow {
  /// Creates a row.
  const RelinkRow({
    required this.asset,
    required this.availability,
    required this.usedClips,
    this.pick,
    this.phase = RelinkRowPhase.needsFile,
    this.check,
    this.accepted = false,
    this.message,
  });

  /// The offline asset.
  final MediaAsset asset;

  /// Why it is offline.
  final MediaAvailability availability;

  /// Clips of the timeline that use it.
  final int usedClips;

  /// The staged file, or null.
  final PickedMedia? pick;

  /// State of the staged file.
  final RelinkRowPhase phase;

  /// The result of `checkRelink` for [pick].
  final RelinkCheck? check;

  /// Whether the user accepted a length difference.
  final bool accepted;

  /// Why [pick] was refused (copy), or null.
  final String? message;

  /// Whether [pick] will be relinked when the sheet's primary button runs.
  bool get willRelink => pick != null && (phase == RelinkRowPhase.ready || (phase == RelinkRowPhase.confirm && accepted));

  /// Whether the staged file sits at a plain path (so "Find in same folder" can look next to it).
  bool get hasPathPick {
    final p = pick;
    return p != null && p.bookmark == null && p.uri.startsWith('file://') && !p.isTemporaryCopy;
  }

  /// A copy with the given fields replaced; pass `pick: null` to clear the staged file.
  RelinkRow copyWith({
    int? usedClips,
    MediaAvailability? availability,
    Object? pick = _keep,
    RelinkRowPhase? phase,
    Object? check = _keep,
    bool? accepted,
    Object? message = _keep,
  }) =>
      RelinkRow(
        asset: asset,
        availability: availability ?? this.availability,
        usedClips: usedClips ?? this.usedClips,
        pick: identical(pick, _keep) ? this.pick : pick as PickedMedia?,
        phase: phase ?? this.phase,
        check: identical(check, _keep) ? this.check : check as RelinkCheck?,
        accepted: accepted ?? this.accepted,
        message: identical(message, _keep) ? this.message : message as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is RelinkRow &&
      other.asset == asset &&
      other.availability == availability &&
      other.usedClips == usedClips &&
      other.pick == pick &&
      other.phase == phase &&
      other.check == check &&
      other.accepted == accepted &&
      other.message == message;

  @override
  int get hashCode => Object.hash(asset, availability, usedClips, pick, phase, check, accepted, message);
}

const Object _keep = Object();

/// What the sheet shows.
enum RelinkStage {
  /// The list of rows.
  list,

  /// Matching the picks of "Relink several".
  matching,

  /// The confirm list of "Relink several".
  confirm,

  /// Relinking.
  applying,
}

/// One pick of "Relink several" and the missing asset it was paired with.
@immutable
final class RelinkMatchEntry {
  /// Creates an entry.
  const RelinkMatchEntry({required this.proposal, required this.asset, this.included = true});

  /// The proposal from `autoMatch`.
  final RelinkProposal proposal;

  /// The asset it would replace.
  final MediaAsset asset;

  /// Whether the user keeps it.
  final bool included;

  /// A copy with [included] replaced.
  RelinkMatchEntry withIncluded(bool value) => RelinkMatchEntry(proposal: proposal, asset: asset, included: value);
}

/// The confirm list of "Relink several".
@immutable
final class RelinkSeveralPlan {
  /// Creates a plan.
  RelinkSeveralPlan({required List<RelinkMatchEntry> matches, required List<RelinkProposal> unmatchedPicks, required List<MediaAsset> stillMissing})
      : matches = List.unmodifiable(matches),
        unmatchedPicks = List.unmodifiable(unmatchedPicks),
        stillMissing = List.unmodifiable(stillMissing);

  /// Pairs found.
  final List<RelinkMatchEntry> matches;

  /// Picks that matched nothing (unassigned, ambiguous, other kind, unreadable).
  final List<RelinkProposal> unmatchedPicks;

  /// Offline assets nothing was matched to.
  final List<MediaAsset> stillMissing;

  /// Files that were picked.
  int get picked => matches.length + unmatchedPicks.length;

  /// Pairs the user keeps.
  int get includedCount => matches.where((m) => m.included).length;
}

/// State of the relink flow (ux.md §13.2).
@immutable
class RelinkState {
  /// Creates the state.
  RelinkState({
    List<RelinkRow> rows = const [],
    this.stage = RelinkStage.list,
    this.checked = false,
    this.several,
    this.note,
    this.failure,
    this.lastRelinked = 0,
    this.applies = 0,
    this.busy = false,
  }) : rows = List.unmodifiable(rows);

  /// One per offline asset.
  final List<RelinkRow> rows;

  /// What the sheet shows.
  final RelinkStage stage;

  /// Whether the first availability report arrived.
  final bool checked;

  /// The confirm list while [stage] is [RelinkStage.confirm].
  final RelinkSeveralPlan? several;

  /// A one-line result ("Found 3 of 4 in the same folder"), or null.
  final String? note;

  /// The last failure, or null.
  final EditorMessage? failure;

  /// Files relinked by the last [RelinkController.apply] (for the sheet's toast).
  final int lastRelinked;

  /// How many times [RelinkController.apply] changed the project (the sheet toasts on each).
  final int applies;

  /// Whether a picker, check or edit is running (buttons wait).
  final bool busy;

  /// Rows with a staged file that will be relinked.
  int get readyCount => rows.where((r) => r.willRelink).length;

  /// The row of [id], or null.
  RelinkRow? rowOf(MediaId id) {
    for (final r in rows) {
      if (r.asset.id == id) return r;
    }
    return null;
  }

  /// A copy with the given fields replaced; pass `several: null`, `note: null` or `failure: null`
  /// to clear them.
  RelinkState copyWith({
    List<RelinkRow>? rows,
    RelinkStage? stage,
    bool? checked,
    Object? several = _keep,
    Object? note = _keep,
    Object? failure = _keep,
    int? lastRelinked,
    int? applies,
    bool? busy,
  }) =>
      RelinkState(
        rows: rows ?? this.rows,
        stage: stage ?? this.stage,
        checked: checked ?? this.checked,
        several: identical(several, _keep) ? this.several : several as RelinkSeveralPlan?,
        note: identical(note, _keep) ? this.note : note as String?,
        failure: identical(failure, _keep) ? this.failure : failure as EditorMessage?,
        lastRelinked: lastRelinked ?? this.lastRelinked,
        applies: applies ?? this.applies,
        busy: busy ?? this.busy,
      );
}

/// The picker kinds that can replace [kind].
Set<MediaPickKind> relinkPickKinds(MediaKind kind) => switch (kind) {
      MediaKind.video => {MediaPickKind.video},
      MediaKind.image || MediaKind.still => {MediaPickKind.image},
      MediaKind.audio || MediaKind.recording => {MediaPickKind.audio},
      MediaKind.lut => {MediaPickKind.lut},
    };

/// The file an asset points at, as a pick ("Use updated file"), or null when the locator needs the
/// app's roots to resolve.
PickedMedia? pickedFromLocator(MediaAsset asset) {
  final locator = asset.locator;
  switch (locator) {
    case FileLocator(:final path):
      return PickedMedia(uri: Uri.file(path).toString(), displayName: asset.displayName, origin: asset.origin);
    case ContentUriLocator(:final uri):
      return PickedMedia(uri: uri, displayName: asset.displayName, origin: asset.origin);
    case BookmarkLocator(:final bookmarkB64, :final lastKnownPath):
      return PickedMedia(
        uri: Uri.file(lastKnownPath).toString(),
        displayName: asset.displayName,
        origin: asset.origin,
        bookmark: base64.decode(bookmarkB64),
      );
    case AppRelativeLocator():
      return null;
  }
}

/// The last known folder of [asset]'s file for the row's details, or null (managed copies and
/// content URIs have no folder worth showing).
String? lastKnownFolderOf(MediaAsset asset) {
  final locator = asset.locator;
  final path = switch (locator) {
    FileLocator(:final path) => path,
    BookmarkLocator(:final lastKnownPath) => lastKnownPath,
    AppRelativeLocator(:final root, :final relPath) when root == AppRoot.documents => relPath,
    _ => null,
  };
  if (path == null || path.isEmpty) return null;
  final cut = path.lastIndexOf('/');
  if (cut <= 0) return null;
  final folder = path.substring(0, cut);
  final name = folder.substring(folder.lastIndexOf('/') + 1);
  return name.isEmpty ? null : name;
}

/// The commands that turn [base] into [relinked] where a shorter file clamped clips of the media in
/// [ids]: a clip that vanished is deleted, one that lost its tail (or head, reversed) is trimmed.
/// Null when no clip changed.
EditCommand? relinkAdjustment(EditProject base, EditProject relinked, Set<MediaId> ids) {
  final now = <ItemId, MediaClip>{
    for (final t in relinked.tracks)
      for (final i in t.items)
        if (i is MediaClip) i.id: i,
  };
  final drop = <ItemId>{};
  final trims = <EditCommand>[];
  for (final t in base.tracks) {
    for (final i in t.items) {
      if (i is! MediaClip || !ids.contains(i.media)) continue;
      final after = now[i.id];
      if (after == null) {
        drop.add(i.id);
      } else if (after.start != i.start) {
        trims.add(TrimItem(i.id, TrimEdge.start, after.start, clamp: true));
      } else if (after.end != i.end) {
        trims.add(TrimItem(i.id, TrimEdge.end, after.end, clamp: true));
      }
    }
  }
  final commands = <EditCommand>[if (drop.isNotEmpty) DeleteItems(drop), ...trims];
  return commands.isEmpty ? null : CompositeCommand('Relink media', commands);
}

/// Relinks missing media (ux.md §13.2).
class RelinkController extends StateNotifier<RelinkState> {
  /// Creates the controller over the open [session] and its [editor]. [pickFiles] shows the system
  /// picker; [onRefreshHealth] re-checks availability after a change.
  RelinkController({
    required EditorSession session,
    required MediaPoolService pool,
    required EditorController editor,
    required Future<List<PickedMedia>> Function(MediaPickRequest request) pickFiles,
    required VoidCallback onRefreshHealth,
  })  : _session = session,
        _pool = pool,
        _editor = editor,
        _pickFiles = pickFiles,
        _refreshHealth = onRefreshHealth,
        super(RelinkState());

  final EditorSession _session;
  final MediaPoolService _pool;
  final EditorController _editor;
  final Future<List<PickedMedia>> Function(MediaPickRequest request) _pickFiles;
  final VoidCallback _refreshHealth;

  /// A token so a late check of a pick that was replaced meanwhile is dropped.
  final Map<MediaId, int> _checkTokens = {};

  EditSession? get _edit => _session.editOrNull;

  // ---------------------------------------------------------------------------------------------
  // Rows
  // ---------------------------------------------------------------------------------------------

  /// Rebuilds the rows from the availability report; staged files of assets that stay offline are
  /// kept.
  void onHealth(MediaHealthState health) {
    if (!mounted) return;
    final project = _session.committedProject;
    if (project == null) return;
    final usage = <MediaId, int>{};
    for (final t in project.tracks) {
      for (final i in t.items) {
        if (i is MediaClip) usage[i.media] = (usage[i.media] ?? 0) + 1;
      }
    }
    final previous = {for (final r in state.rows) r.asset.id: r};
    final rows = <RelinkRow>[];
    for (final id in health.offline) {
      final asset = project.pool[id];
      if (asset == null || asset.derived != null) continue;
      final used = usage[id] ?? 0;
      final old = previous[id];
      rows.add(old == null
          ? RelinkRow(asset: asset, availability: health.of(id), usedClips: used)
          : old.copyWith(availability: health.of(id), usedClips: used));
    }
    rows.sort((a, b) {
      final byUse = (b.usedClips > 0 ? 1 : 0) - (a.usedClips > 0 ? 1 : 0);
      if (byUse != 0) return byUse;
      return a.asset.displayName.toLowerCase().compareTo(b.asset.displayName.toLowerCase());
    });
    state = state.copyWith(rows: rows, checked: health.checked);
  }

  void _replaceRow(MediaId id, RelinkRow Function(RelinkRow row) update) {
    if (!mounted) return;
    state = state.copyWith(rows: [for (final r in state.rows) r.asset.id == id ? update(r) : r]);
  }

  // ---------------------------------------------------------------------------------------------
  // One file
  // ---------------------------------------------------------------------------------------------

  /// Picks a replacement for [id] from [source] and checks it.
  Future<void> locate(MediaId id, MediaPickSource source) async {
    final row = state.rowOf(id);
    if (row == null || state.busy) return;
    state = state.copyWith(busy: true, note: null, failure: null);
    try {
      final picks = await _pickFiles(MediaPickRequest(source: source, kinds: relinkPickKinds(row.asset.kind), multiple: false));
      if (!mounted) return;
      if (picks.isEmpty) return;
      await stage(id, picks.first);
    } on Object catch (e) {
      if (e is Error) rethrow;
      debugPrint('[Relink] Picker failed: ${e.runtimeType}');
      if (mounted) state = state.copyWith(failure: const EditorMessage(RelinkStrings.pickerFailed));
    } finally {
      if (mounted) state = state.copyWith(busy: false);
    }
  }

  /// Stages [pick] for [id] and checks it with the pool service.
  Future<void> stage(MediaId id, PickedMedia pick) async {
    final edit = _edit;
    if (edit == null || state.rowOf(id) == null) return;
    final token = (_checkTokens[id] ?? 0) + 1;
    _checkTokens[id] = token;
    _replaceRow(id, (r) => r.copyWith(pick: pick, phase: RelinkRowPhase.checking, check: null, accepted: false, message: null));
    RelinkCheck check;
    try {
      check = await _pool.checkRelink(edit, id, pick);
    } on Object catch (e) {
      if (e is Error) rethrow;
      debugPrint('[Relink] Check failed: ${e.runtimeType}');
      check = const RelinkUnsupported('io');
    }
    if (!mounted || _checkTokens[id] != token) return;
    _replaceRow(id, (r) => _withCheck(r, check));
  }

  RelinkRow _withCheck(RelinkRow row, RelinkCheck check) => switch (check) {
        RelinkMatch() => row.copyWith(phase: RelinkRowPhase.ready, check: check, message: null),
        RelinkDurationMismatch() => row.copyWith(phase: RelinkRowPhase.confirm, check: check, message: null),
        RelinkDifferentKind() =>
          row.copyWith(phase: RelinkRowPhase.rejected, check: check, message: RelinkStrings.differentKind(row.asset.kind)),
        RelinkUnsupported(:final reason) =>
          row.copyWith(phase: RelinkRowPhase.rejected, check: check, message: RelinkStrings.unsupported(reason)),
      };

  /// Accepts the length difference of [id]'s staged file.
  void acceptMismatch(MediaId id) => _replaceRow(id, (r) => r.phase == RelinkRowPhase.confirm ? r.copyWith(accepted: true) : r);

  /// Drops the staged file of [id].
  void clear(MediaId id) {
    _checkTokens[id] = (_checkTokens[id] ?? 0) + 1;
    _replaceRow(id, (r) => r.copyWith(pick: null, phase: RelinkRowPhase.needsFile, check: null, accepted: false, message: null));
  }

  /// "Use updated file": stages the file [id] already points at.
  Future<void> useUpdatedFile(MediaId id) async {
    final row = state.rowOf(id);
    if (row == null || state.busy) return;
    final pick = pickedFromLocator(row.asset);
    if (pick == null) return;
    await stage(id, pick);
  }

  /// Whether "Use updated file" is offered for [row].
  bool canUseUpdated(RelinkRow row) => row.availability == MediaAvailability.changed && pickedFromLocator(row.asset) != null;

  // ---------------------------------------------------------------------------------------------
  // Same folder
  // ---------------------------------------------------------------------------------------------

  /// Looks next to [anchor]'s staged file for files named like the other missing assets and stages
  /// the ones that match.
  Future<void> findInSameFolder(MediaId anchor) async {
    final edit = _edit;
    final pick = state.rowOf(anchor)?.pick;
    if (edit == null || pick == null || state.busy) return;
    state = state.copyWith(busy: true, note: null, failure: null);
    try {
      final others = state.rows.where((r) => r.asset.id != anchor && r.pick == null).length;
      final found = await _pool.findInSameFolder(edit, pick);
      if (!mounted) return;
      var staged = 0;
      for (final c in found) {
        final row = state.rowOf(c.media);
        if (row == null || row.pick != null) continue;
        staged++;
        _checkTokens[c.media] = (_checkTokens[c.media] ?? 0) + 1;
        _replaceRow(c.media, (r) => _withCheck(r.copyWith(pick: c.pick), c.check));
      }
      state = state.copyWith(note: staged == 0 ? RelinkStrings.foundNothingInFolder : RelinkStrings.foundInFolder(staged, others));
    } on Object catch (e) {
      if (e is Error) rethrow;
      debugPrint('[Relink] Folder search failed: ${e.runtimeType}');
      if (mounted) state = state.copyWith(note: RelinkStrings.foundNothingInFolder);
    } finally {
      if (mounted) state = state.copyWith(busy: false);
    }
  }

  // ---------------------------------------------------------------------------------------------
  // Relink several
  // ---------------------------------------------------------------------------------------------

  /// Picks many files at once and pairs them with the missing assets (`autoMatch`).
  Future<void> relinkSeveral(MediaPickSource source) async {
    final edit = _edit;
    if (edit == null || state.busy || state.rows.isEmpty) return;
    state = state.copyWith(busy: true, note: null, failure: null);
    try {
      final kinds = {for (final r in state.rows) ...relinkPickKinds(r.asset.kind)};
      final picks = await _pickFiles(MediaPickRequest(source: source, kinds: kinds));
      if (!mounted || picks.isEmpty) return;
      state = state.copyWith(stage: RelinkStage.matching);
      final proposals = await _pool.autoMatch(edit, picks);
      if (!mounted) return;
      final byId = {for (final r in state.rows) r.asset.id: r.asset};
      final matches = <RelinkMatchEntry>[];
      final unmatched = <RelinkProposal>[];
      final taken = <MediaId>{};
      for (final p in proposals) {
        final asset = p.media == null ? null : byId[p.media];
        if (asset != null && p.check is RelinkMatch) {
          matches.add(RelinkMatchEntry(proposal: p, asset: asset));
          taken.add(asset.id);
        } else {
          unmatched.add(p);
        }
      }
      state = state.copyWith(
        stage: RelinkStage.confirm,
        several: RelinkSeveralPlan(
          matches: matches,
          unmatchedPicks: unmatched,
          stillMissing: [for (final r in state.rows) if (!taken.contains(r.asset.id)) r.asset],
        ),
      );
    } on Object catch (e) {
      if (e is Error) rethrow;
      debugPrint('[Relink] Relink several failed: ${e.runtimeType}');
      if (mounted) state = state.copyWith(stage: RelinkStage.list, failure: const EditorMessage(RelinkStrings.pickerFailed));
    } finally {
      if (mounted) state = state.copyWith(busy: false);
    }
  }

  /// Includes or excludes the pair [index] of the confirm list.
  void setMatchIncluded(int index, bool included) {
    final plan = state.several;
    if (plan == null || index < 0 || index >= plan.matches.length) return;
    final matches = [for (final (i, m) in plan.matches.indexed) i == index ? m.withIncluded(included) : m];
    state = state.copyWith(
      several: RelinkSeveralPlan(matches: matches, unmatchedPicks: plan.unmatchedPicks, stillMissing: plan.stillMissing),
    );
  }

  /// Leaves the confirm list without relinking.
  void cancelSeveral() {
    if (!mounted) return;
    state = state.copyWith(stage: RelinkStage.list, several: null);
  }

  /// Stages the kept pairs and relinks everything staged, as one history entry.
  Future<bool> confirmSeveral() async {
    final plan = state.several;
    if (plan == null || state.busy) return false;
    for (final m in plan.matches.where((m) => m.included)) {
      _checkTokens[m.asset.id] = (_checkTokens[m.asset.id] ?? 0) + 1;
      _replaceRow(m.asset.id, (r) => _withCheck(r.copyWith(pick: m.proposal.pick, accepted: false), m.proposal.check));
    }
    state = state.copyWith(several: null, stage: RelinkStage.list);
    return apply();
  }

  // ---------------------------------------------------------------------------------------------
  // Apply
  // ---------------------------------------------------------------------------------------------

  /// Relinks every staged file in ONE undoable "Relink media" history entry. Returns whether the
  /// project changed.
  Future<bool> apply() async {
    final edit = _edit;
    if (edit == null || state.busy) return false;
    final picks = {
      for (final r in state.rows)
        if (r.willRelink) r.asset.id: r.pick!,
    };
    if (picks.isEmpty) return false;
    state = state.copyWith(stage: RelinkStage.applying, busy: true, failure: null, note: null);
    var changed = false;
    try {
      final base = edit.committedProject;
      final scratch = EditSession(base, editPolicy: edit.editPolicy);
      final outcome = await _pool.relink(scratch, picks);
      if (!mounted) return false;
      if (outcome.rejection != null) {
        state = state.copyWith(failure: _applyFailed);
        return false;
      }
      if (!outcome.changed) {
        // Nothing to change (the files were already linked).
        _refreshHealth();
        return false;
      }
      final relinked = scratch.committedProject;
      final replacements = <MediaId, MediaAsset>{
        for (final id in picks.keys)
          if (relinked.pool[id] case final MediaAsset a) id: a,
      };
      final result = _editor.applyPoolEdit(
        RelinkAssets(replacements),
        adjust: relinkAdjustment(base, relinked, picks.keys.toSet()),
        label: 'Relink media',
      );
      switch (result) {
        case EditApplied():
          changed = true;
          state = state.copyWith(lastRelinked: replacements.length, applies: state.applies + 1);
        case EditRejected():
          state = state.copyWith(failure: _applyFailed);
        case EditUnchanged():
          break;
      }
      _refreshHealth();
    } on Object catch (e) {
      if (e is Error) rethrow;
      debugPrint('[Relink] Relink failed: ${e.runtimeType}');
      if (mounted) state = state.copyWith(failure: _applyFailed);
    } finally {
      if (mounted) {
        // The rows are rebuilt by the next availability report; the ones that were relinked leave.
        state = state.copyWith(stage: RelinkStage.list, busy: false);
      }
    }
    return changed;
  }

  static const EditorMessage _applyFailed = EditorMessage(RelinkStrings.applyFailedTitle, detail: RelinkStrings.applyFailedDetail);

  // ---------------------------------------------------------------------------------------------
  // Remove and replace
  // ---------------------------------------------------------------------------------------------

  /// The ids of the clips that use [media].
  List<ItemId> clipsUsing(MediaId media) {
    final project = _session.committedProject;
    if (project == null) return const [];
    return [
      for (final t in project.tracks)
        for (final i in t.items)
          if (i is MediaClip && i.media == media) i.id,
    ];
  }

  /// Removes the clips that use [media] (one history entry). Returns how many were removed.
  int removeClips(MediaId media) {
    final ids = clipsUsing(media);
    if (ids.isEmpty) return 0;
    final result = _editor.apply(DeleteItems(ids.toSet()));
    if (result is EditApplied) {
      _refreshHealth();
      return ids.length;
    }
    if (result is EditRejected) state = state.copyWith(failure: EditorMessages.forRejection(result.reason));
    return 0;
  }

  /// Picks other media from [source], imports it and replaces the clips that use [media] with it
  /// (one history entry). Returns how many clips were replaced.
  Future<int> replaceWith(MediaId media, MediaPickSource source) async {
    final edit = _edit;
    final row = state.rowOf(media);
    if (edit == null || row == null || state.busy) return 0;
    state = state.copyWith(busy: true, note: null, failure: null);
    try {
      final picks = await _pickFiles(MediaPickRequest(source: source, kinds: relinkPickKinds(row.asset.kind), multiple: false));
      if (!mounted || picks.isEmpty) return 0;
      final outcomes = await _pool.import(edit, picks);
      if (!mounted) return 0;
      final first = outcomes.isEmpty ? null : outcomes.first;
      if (first is! ImportedMedia) {
        final reason = first is ImportRejected ? first.reason : 'io';
        state = state.copyWith(failure: EditorMessage(RelinkStrings.unsupported(reason)));
        return 0;
      }
      final clips = clipsUsing(media);
      final result = _editor.apply(CompositeCommand('Replace media', [for (final c in clips) ReplaceMedia(c, first.asset.id)]));
      if (result is EditApplied) {
        _refreshHealth();
        return clips.length;
      }
      if (result is EditRejected) state = state.copyWith(failure: EditorMessages.forRejection(result.reason));
      return 0;
    } on Object catch (e) {
      if (e is Error) rethrow;
      debugPrint('[Relink] Replace failed: ${e.runtimeType}');
      if (mounted) state = state.copyWith(failure: const EditorMessage(RelinkStrings.pickerFailed));
      return 0;
    } finally {
      if (mounted) state = state.copyWith(busy: false);
    }
  }

  /// Clears the failure line.
  void dismissFailure() {
    if (mounted && state.failure != null) state = state.copyWith(failure: null);
  }
}

/// Builds the value of `relinkControllerProvider` for [id]: the controller watches the media health
/// of the project (and so starts it) and rebuilds its rows after every report.
RelinkController createRelinkController(Ref<Object?> ref, ProjectId id) {
  final session = ref.watch(editorSessionProvider(id));
  final health = ref.read(mediaHealthControllerProvider(id).notifier);
  final controller = RelinkController(
    session: session,
    pool: ref.watch(mediaPoolServiceProvider),
    editor: ref.read(editorControllerProvider(id).notifier),
    pickFiles: ref.read(editorEngineProvider).picker.pick,
    onRefreshHealth: health.refresh,
  );
  ref.listen<MediaHealthState>(mediaHealthControllerProvider(id), (_, next) => controller.onHealth(next), fireImmediately: true);
  return controller;
}
