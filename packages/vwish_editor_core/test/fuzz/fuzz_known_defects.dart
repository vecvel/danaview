// OWNER: CORE-34
//
// Open defects the fuzzer found in code owned by other tickets (BUILD_PLAN §1 rule 8: the owner
// fixes them in `FIX-<ticket>-<n>` follow-ups). Each entry matches one narrow failure signature.
// A matching failure is counted in the run's stats (`known:<id>`) instead of failing the run:
//
// * a **refusal** defect ends in `InternalInconsistency`, which leaves the project unchanged, so
//   the runner treats the command as refused and goes on;
// * a **terminal** defect leaves the project invalid, so the run stops there and passes. The
//   steps before it were checked.
//
// Every other failure still fails the run. The minimized reproduction of each defect is a
// regression fixture in `regressions/` with `"defect": "<id>"`. The regression test checks that
// the fixture still reproduces while the entry is listed here. When the owner lands the fix,
// delete the entry here and the fixture's `defect` field. The fixture then replays as an
// ordinary regression test that must pass.

import 'package:vwish_editor_core/eval.dart';
import 'package:vwish_editor_core/ops.dart';

import 'fuzz_generator.dart';

/// What a known defect is matched against.
final class DefectContext {
  /// Creates a context.
  const DefectContext({required this.validator, this.command, this.rejection, this.action, this.violations = const []});

  /// True for a validator failure of the current project, false for a refused command.
  final bool validator;

  /// The refused command (refusal defects).
  final EditCommand? command;

  /// The refusal (refusal defects).
  final InternalInconsistency? rejection;

  /// The step's action (terminal defects).
  final FuzzAction? action;

  /// The validator's violations (terminal defects).
  final List<Violation> violations;
}

/// An open defect and the failure signature it explains.
final class KnownDefect {
  /// Creates an entry. [terminal] defects leave the project invalid and stop the run.
  const KnownDefect(this.id, this.summary, this.matches, {this.terminal = false});

  /// The follow-up ticket id.
  final String id;

  /// What goes wrong.
  final String summary;

  /// Whether the failure is this defect.
  final bool Function(DefectContext context) matches;

  /// Whether the run has to stop (the project is invalid).
  final bool terminal;
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

/// The open defects (empty when everything the fuzzer found is fixed).
final List<KnownDefect> knownDefects = [
  KnownDefect(
    'FIX-CORE-15-1',
    'ReplaceGeneratedCaptions with a range: `_fitCues` (subtitle_commands.dart) advances its '
        'pointer into the kept cues while it fits a draft that is then dropped. The next draft is '
        'not checked against the kept cue it skipped, so the new cues overlap the kept ones (I2). '
        'The command is refused with InternalInconsistency instead of fitting the drafts.',
    (x) =>
        !x.validator &&
        x.rejection!.violations.isNotEmpty &&
        x.rejection!.violations.every((v) => v.code == ViolationCode.itemsOverlap) &&
        anyCommand(x.command!, (c) => c is ReplaceGeneratedCaptions && c.range != null),
  ),
  KnownDefect(
    'FIX-CORE-15-2',
    'ImportSubtitles (replace mode) and ReplaceGeneratedCaptions replace the cues of a lane with '
        '`putTrack`/`setItems` and do not hand the links of the removed cues to the singleton '
        'check of `finish()` (`noteLink`). A cue linked to an item on another lane (LinkItems '
        'allows it) leaves that item alone in its group (I7). The post-step validation checks only '
        'the changed lanes, so the invalid project is accepted.',
    (x) =>
        x.validator &&
        x.violations.isNotEmpty &&
        x.violations.every((v) => v.code == ViolationCode.linkInvalid) &&
        commandsOf(x.action).any((c) => anyCommand(c, _replacesCues)),
    terminal: true,
  ),
];

/// The open defect explaining [context], or null.
KnownDefect? knownDefectOf(DefectContext context) {
  for (final d in knownDefects) {
    if (d.matches(context)) return d;
  }
  return null;
}
