// OWNER: CORE-08
//
// Sub-barrel of `lib/src/validate/` (exported by `lib/eval.dart`): the project validator for
// invariants I1–I9 and `repair()` (ARCH §6.9, domain.md §5). `ProjectOpenWarning` stays declared
// here because the repository contract (`LoadedProject.warnings`, CORE-25) refers to it.

import 'package:meta/meta.dart';

export 'repair.dart';
export 'transition_bounds.dart';
export 'validator.dart';
export 'violation.dart';

/// Something `repair()` fixed or an unknown value met while opening a project (never fatal).
@immutable
final class ProjectOpenWarning {
  /// Creates a warning with a stable [code] and a message without paths or user content.
  const ProjectOpenWarning(this.code, [this.message = '']);

  /// Stable code (e.g. `unknownEnum`, `overlapRepaired`, `offGridSnapped`; `repair()` uses the
  /// codes of `RepairCodes`).
  final String code;

  /// Diagnostic detail.
  final String message;

  @override
  bool operator ==(Object other) => other is ProjectOpenWarning && other.code == code && other.message == message;

  @override
  int get hashCode => Object.hash(code, message);

  @override
  String toString() => 'ProjectOpenWarning($code${message.isEmpty ? '' : ': $message'})';
}
