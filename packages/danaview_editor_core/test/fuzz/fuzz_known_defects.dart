// OWNER: CORE-34
//
// Open defects the fuzzer found in code owned by other tickets (BUILD_PLAN §1 rule 8: the owner
// fixes them in `FIX-<ticket>-<n>` follow-ups). Each entry matches one narrow failure signature.
// A matching failure is counted in the run's stats (`known:<id>`) instead of failing the run:
//
// * a **refusal** defect ends in `InternalInconsistency`, which leaves the project unchanged, so
//   the runner treats the command as refused and goes on;
// * a **plan** defect makes the compiled preview plan invalid. The project itself is fine, so the
//   runner goes on (the diff/patch checks still run on the plan);
// * a **validator** defect leaves the session's project invalid, so the run stops there and
//   passes. The steps before it were checked.
//
// One defect can show up in several of these ways (an entry may match several kinds).
//
// Every other failure still fails the run. The minimized reproduction of each defect is a
// regression fixture in `regressions/` with `"defect": "<id>"`. The regression test checks that
// the fixture still reproduces while the entry is listed here. When the owner lands the fix,
// delete the entry here and the fixture's `defect` field. The fixture then replays as an
// ordinary regression test that must pass.

import 'package:danaview_editor_core/eval.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';
import 'package:danaview_editor_core/plan.dart';

import 'fuzz_generator.dart';

/// Where a failure was found.
enum DefectKind {
  /// A command was refused with `InternalInconsistency`.
  refusal,

  /// The validator found violations in the session's project.
  validator,

  /// The compiled preview plan has violations.
  plan,
}

/// What a known defect is matched against.
final class DefectContext {
  /// Creates a context.
  const DefectContext({
    required this.kind,
    this.command,
    this.rejection,
    this.action,
    this.violations = const [],
    this.planViolations = const [],
    this.project,
    this.policy,
  });

  /// Where the failure was found.
  final DefectKind kind;

  /// The refused command (refusal defects).
  final EditCommand? command;

  /// The refusal (refusal defects).
  final InternalInconsistency? rejection;

  /// The step's action (validator defects; null for the final history walk).
  final FuzzAction? action;

  /// The validator's violations (validator defects).
  final List<Violation> violations;

  /// The plan's violations (plan defects).
  final List<PlanViolation> planViolations;

  /// The project the refused command was applied to, or the compiled project (refusal and plan
  /// defects).
  final EditProject? project;

  /// The session's command policy (refusal defects).
  final EditPolicy? policy;
}

/// An open defect and the failure signature it explains.
final class KnownDefect {
  /// Creates an entry.
  const KnownDefect(this.id, this.summary, this.matches);

  /// The follow-up ticket id.
  final String id;

  /// What goes wrong.
  final String summary;

  /// Whether the failure is this defect.
  final bool Function(DefectContext context) matches;

}

/// [command] or one of its composite children satisfies [test].
bool anyCommand(EditCommand command, bool Function(EditCommand c) test) =>
    test(command) || (command is CompositeCommand && command.commands.any((c) => anyCommand(c, test)));

/// The commands [action] runs.
List<EditCommand> commandsOf(FuzzAction? action) => switch (action) {
      ApplyAction(:final command) => [command],
      TransactionAction(:final updates) => updates,
      PoolEditAction(:final adjust) => [if (adjust != null) adjust],
      _ => const [],
    };

bool _replacesCues(EditCommand c) =>
    c is ReplaceGeneratedCaptions || (c is ImportSubtitles && c.mode == SubtitleImportMode.replace);

/// Whether every violation of the refusal in [x] has [code].
bool _refusedOnlyWith(DefectContext x, ViolationCode code) =>
    x.kind == DefectKind.refusal && x.rejection!.violations.isNotEmpty && x.rejection!.violations.every((v) => v.code == code);

final RegExp _segmentRate = RegExp(r'^segment rate ([0-9.eE-]+) outside');

/// A map segment slower than 0.1×.
bool _belowMinRate(PlanViolation v) {
  final m = _segmentRate.firstMatch(v.message);
  return m != null && double.parse(m[1]!) < 0.1;
}

/// Whether the plan layer [layerId] (`<item id>#...`) shows a reversed media clip of [p].
bool _reversedClip(EditProject? p, String? layerId) {
  if (p == null || layerId == null) return false;
  final hash = layerId.indexOf('#');
  final item = p.index.item(ItemId(hash < 0 ? layerId : layerId.substring(0, hash)));
  return item is MediaClip && item.reversed;
}

/// The open defects (empty when everything the fuzzer found is fixed).
final List<KnownDefect> knownDefects = [
  KnownDefect(
    'FIX-CORE-10-1',
    'MoveItems(clamp: true) under OverlapPolicy.reject (clip_commands.dart `_plainMove`): when the '
        'requested shift does not fit, `LanePlacement.nearestFreeShift` picks a shift for the primary '
        'lane only, and `fits(shift)` checks the other lanes for overlaps but not for the 0 bound. '
        'The shift can be larger than the requested delta (the free slot is on the far side of an '
        'item), so an item of another lane lands before 0 (I1 itemTooShort). The command is refused '
        'with InternalInconsistency instead of being clamped.',
    (x) =>
        _refusedOnlyWith(x, ViolationCode.itemTooShort) &&
        x.policy?.overlap == OverlapPolicy.reject &&
        anyCommand(x.command!, (c) => c is MoveItems && c.clamp && !c.ripple),
  ),
  KnownDefect(
    'FIX-CORE-19-1',
    'EditSession keeps pool assets that a command adds (PasteItems imports the payload\'s media and '
        'LUTs) as sticky changes outside the history entry. When the asset is removed with '
        '`applyPoolEdit(RemoveAssets)` while unused and a later paste imports it again, walking the '
        'history back over the removal and forward again re-applies the removal (its PoolDelta) but '
        'not the re-import, so the redone paste references media the pool no longer has (I4 '
        'mediaMissing) after redo or jump.',
    (x) =>
        x.kind == DefectKind.validator &&
        x.violations.isNotEmpty &&
        x.violations.every((v) => v.code == ViolationCode.mediaMissing) &&
        (x.action == null || x.action is UndoAction || x.action is RedoAction || x.action is JumpAction || x.action is HistoryWalkAction),
  ),
  KnownDefect(
    'FIX-CORE-30-1',
    '`extendMap` (lowering_visual.dart, used by the CORE-31 transition lowering for handles) '
        'extends the first map segment back to the transition window at the edge rate and clamps the '
        'source start at 0. When the handle reaches before the source start, the clamp lowers the '
        'segment rate below 0.1 and the plan fails PlanValidator (map segment rate outside '
        '[0.1, 10]). Seen with a reversed clip whose rendition is pending: its forward-fallback map '
        'starts at sourceIn 0, while the transition limits assumed the mirrored handles of the '
        'reversed clip.',
    (x) =>
        x.kind == DefectKind.plan &&
        x.planViolations.isNotEmpty &&
        x.planViolations.every((v) => _belowMinRate(v) && _reversedClip(x.project, v.id)),
  ),
  KnownDefect(
    'FIX-CORE-11-1',
    'PasteItems across frame rates (clipboard_commands.dart): each item\'s start (`offset`) and '
        'length are rounded to the new grid separately, so two items that touch on the source grid '
        'can overlap by a frame on the target grid (for example 48 fps clips pasted into a 25 fps '
        'project). `placeGroup` places the group as it is, and the paste is refused with '
        'InternalInconsistency (I2) instead of keeping the items adjacent (map both edges, as '
        '`requantize` does).',
    (x) =>
        _refusedOnlyWith(x, ViolationCode.itemsOverlap) &&
        anyCommand(x.command!, (c) => c is PasteItems && c.payload.rate != x.project?.settings.frameRate),
  ),
  KnownDefect(
    'FIX-CORE-15-1',
    'ReplaceGeneratedCaptions with a range: `_fitCues` (subtitle_commands.dart) advances its '
        'pointer into the kept cues while it fits a draft that is then dropped. The next draft is '
        'not checked against the kept cue it skipped, so the new cues overlap the kept ones (I2). '
        'The command is refused with InternalInconsistency instead of fitting the drafts.',
    (x) =>
        _refusedOnlyWith(x, ViolationCode.itemsOverlap) &&
        anyCommand(x.command!, (c) => c is ReplaceGeneratedCaptions && c.range != null),
  ),
  KnownDefect(
    'FIX-CORE-15-2',
    'ImportSubtitles (replace mode) and ReplaceGeneratedCaptions replace the cues of a lane with '
        '`putTrack`/`setItems` and do not hand the links of the removed cues to the singleton '
        'check of `finish()` (`noteLink`). A cue linked to an item on another lane (LinkItems '
        'allows it) leaves that item alone in its group (I7). The post-step validation checks only '
        'the changed lanes, so the invalid project is accepted (validator failure). When the same '
        'step also changes the partner\'s lane (a composite), the step is refused with '
        'InternalInconsistency (linkInvalid) instead.',
    (x) => switch (x.kind) {
      DefectKind.validator => x.violations.isNotEmpty &&
          x.violations.every((v) => v.code == ViolationCode.linkInvalid) &&
          commandsOf(x.action).any((c) => anyCommand(c, _replacesCues)),
      DefectKind.refusal =>
        _refusedOnlyWith(x, ViolationCode.linkInvalid) && anyCommand(x.command!, _replacesCues),
      DefectKind.plan => false,
    },
  ),
];

/// The open defect explaining [context], or null.
KnownDefect? knownDefectOf(DefectContext context) {
  for (final d in knownDefects) {
    if (d.matches(context)) return d;
  }
  return null;
}
