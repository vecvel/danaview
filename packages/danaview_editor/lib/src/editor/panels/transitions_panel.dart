// OWNER: UX-27
//
// Placeholder (D-33) created by UX-01. UX-27 replaces this file:
// the transitions panel (ux.md §10.12).
// Keep the constructor contract `TransitionsPanel({Key? key, required TransitionInspector route})`: InspectorHost (UX-16)
// builds panels with it.
// Until then it declares only the public names other files compile against.

import 'package:flutter/widgets.dart';

import '../contracts/inspector_routes.dart';
import '../wiring/not_available_yet.dart';

/// The transitions panel (ux.md §10.12).
class TransitionsPanel extends StatelessWidget {
  /// Creates the placeholder.
  const TransitionsPanel({super.key, required this.route});

  /// What the panel edits.
  final TransitionInspector route;

  @override
  Widget build(BuildContext context) => const EditorNotAvailableYet(label: 'Transitions panel', owner: 'UX-27');
}
