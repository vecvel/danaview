// OWNER: UX-35
//
// Placeholder (D-33) created by UX-01. UX-35 replaces this file:
// the clip info panel (ux.md §10.15).
// Keep the constructor contract `ClipInfoPanel({Key? key, required ClipInfoInspector route})`: InspectorHost (UX-16)
// builds panels with it.
// Until then it declares only the public names other files compile against.

import 'package:flutter/widgets.dart';

import '../contracts/inspector_routes.dart';
import '../wiring/not_available_yet.dart';

/// The clip info panel (ux.md §10.15).
class ClipInfoPanel extends StatelessWidget {
  /// Creates the placeholder.
  const ClipInfoPanel({super.key, required this.route});

  /// What the panel edits.
  final ClipInfoInspector route;

  @override
  Widget build(BuildContext context) => const EditorNotAvailableYet(label: 'Clip info panel', owner: 'UX-35');
}
