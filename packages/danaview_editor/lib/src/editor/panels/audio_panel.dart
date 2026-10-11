// OWNER: UX-33
//
// Placeholder (D-33) created by UX-01. UX-33 replaces this file:
// the audio panel (ux.md §10.4).
// Keep the constructor contract `AudioPanel({Key? key, required AudioInspector route})`: InspectorHost (UX-16)
// builds panels with it.
// Until then it declares only the public names other files compile against.

import 'package:flutter/widgets.dart';

import '../contracts/inspector_routes.dart';
import '../wiring/not_available_yet.dart';

/// The audio panel (ux.md §10.4).
class AudioPanel extends StatelessWidget {
  /// Creates the placeholder.
  const AudioPanel({super.key, required this.route});

  /// What the panel edits.
  final AudioInspector route;

  @override
  Widget build(BuildContext context) => const EditorNotAvailableYet(label: 'Audio panel', owner: 'UX-33');
}
