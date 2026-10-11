// OWNER: UX-30
//
// Placeholder (D-33) created by UX-01. UX-30 replaces this file:
// the text panel (ux.md §10.8).
// Keep the constructor contract `TextPanel({Key? key, required TextInspector route})`: InspectorHost (UX-16)
// builds panels with it.
// Until then it declares only the public names other files compile against.

import 'package:flutter/widgets.dart';

import '../contracts/inspector_routes.dart';
import '../wiring/not_available_yet.dart';

/// The text panel (ux.md §10.8).
class TextPanel extends StatelessWidget {
  /// Creates the placeholder.
  const TextPanel({super.key, required this.route});

  /// What the panel edits.
  final TextInspector route;

  @override
  Widget build(BuildContext context) => const EditorNotAvailableYet(label: 'Text panel', owner: 'UX-30');
}
