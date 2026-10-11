// OWNER: UX-39
//
// The export action binding (merged by wiring/action_bindings.dart, ARCH §17.6):
//
// * `export`: the top bar's Export button and the registry's Export action run the pre-checks and
//   open the export sheet (ux.md §11.1). It is enabled once the project has opened; read-only
//   projects (opened by a newer app, D-12) can still be exported.
//
// "Relink" and "Change project to 9:16" inside the sheet run UX-40's `relink` action and the
// Canvas panel (`format`) through the registry after the sheet closed.

import '../../../app/editor_providers.dart';
import '../../../app/strings/export_strings.dart';
import '../../contracts/action_binding.dart';
import '../../contracts/action_ids.dart';
import '../../flows/export/export_sheet.dart';

bool _isReady(EditorActionContext ctx) => ctx.read(editorControllerProvider(ctx.projectId)).isReady;

String? _notReady(EditorActionContext ctx) => ExportStrings.notReady;

Future<void> _export(EditorActionContext ctx) => ExportSheet.show(ctx.context, projectId: ctx.projectId);

/// The export actions bound by UX-39 (ARCH §17.6).
List<EditorActionBinding> get exportBindings => _exportBindings;

const List<EditorActionBinding> _exportBindings = <EditorActionBinding>[
  EditorActionBinding(id: EditorActionId.export, handler: _export, isEnabled: _isReady, disabledReason: _notReady),
];
