// OWNER: CORE-09
//
// The public entry points of the command framework (ARCH §7.1). Both run the command through the
// same code path (`EditCommand.applyTo` / `previewOn`, see edit_command.dart): the command logic,
// generic normalization, no-op detection, `LayerLimits` and post-step validation. Neither throws:
// refusals come back as `EditRejection` data and exceptions inside a command become
// `InternalInconsistency` with the project unchanged.

import '../model/project.dart';
import 'edit_command.dart';
import 'edit_context.dart';
import 'outcome.dart';

/// Applies [command] to [project] (pure: [project] is not modified).
EditOutcome applyCommand(EditProject project, EditCommand command, EditContext ctx) => command.applyTo(project, ctx);

/// Dry-runs [command] on [project]: where every affected item would land, which lanes would be
/// created, the clamped range of a gesture, or the rejection (limits included). The UI snaps the
/// proposed time before calling it; commands never snap on their own (ARCH §7.1).
EditPreview dryRun(EditProject project, EditCommand command, EditContext ctx) => command.previewOn(project, ctx);
