// OWNER: UX-23
//
// Placeholder (D-33) created by UX-01. UX-23 replaces this file:
// the transform panel (ux.md §10.2).
// Keep the constructor contract `TransformPanel({Key? key, required TransformInspector route})`: InspectorHost (UX-16)
// builds panels with it.
// Until then it declares only the public names other files compile against.

import 'package:flutter/widgets.dart';

import '../contracts/inspector_routes.dart';
import '../wiring/not_available_yet.dart';

/// The transform panel (ux.md §10.2).
class TransformPanel extends StatelessWidget {
  /// Creates the placeholder.
  const TransformPanel({super.key, required this.route});

  /// What the panel edits.
  final TransformInspector route;

  @override
  Widget build(BuildContext context) => const EditorNotAvailableYet(label: 'Transform panel', owner: 'UX-23');
}
