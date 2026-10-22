// OWNER: HOM-22
//
// The entry of lib/src/library/file_actions/ (BUILD_PLAN HOM-22) for the app root (INT-103) and the
// screens that show a file menu (tabs, viewers): the providers to override (the Windows/Linux
// [DesktopFileOut] port, the Merge into PDF handler), the single-file menu, the File info sheet,
// the action runner and the multi-select file group.

/// File actions and getting files out in the Home (ARCH v1.2 V2-117, V2-118).
library;

export '../selection/file_actions.dart' show fileSelectionGroup, fileSelectionGroupId, fileSelectionGroupWith;
export 'file_action_providers.dart';
export 'file_action_runner.dart';
export 'file_action_sheets.dart';
export 'file_out_ports.dart';
