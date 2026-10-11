// OWNER: INT-02
//
// Placeholder (D-33) created by UX-01. INT-02 replaces this file:
// DefaultPlanCompiler over core compileRenderPlan/PlanMemo.
// Until then it declares only the public names other files compile against.

import 'package:vwish_editor_core/ops.dart' show EditSession;
import 'package:vwish_editor_engine_api/vwish_editor_engine_api.dart' show EditorCapabilities;

import 'plan_compiler_port.dart';

/// The app's plan compiler (ARCH §11.7).
final class DefaultPlanCompiler implements PlanCompilerPort {
  // Stub added by UX-08 when the port gained its member; INT-02 replaces this file.
  @override
  SessionPlanCompiler forSession(EditSession session, EditorCapabilities capabilities) =>
      throw UnimplementedError('DefaultPlanCompiler is implemented by INT-02');
}
