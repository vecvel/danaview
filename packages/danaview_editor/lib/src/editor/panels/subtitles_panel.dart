// OWNER: UX-31
//
// Placeholder (D-33) created by UX-01. UX-31 replaces this file:
// the captions panel (ux.md §10.9).
// Keep the constructor contract `SubtitlesPanel({Key? key, required SubtitlesInspector route})`: InspectorHost (UX-16)
// builds panels with it.
// Until then it declares only the public names other files compile against.

import 'package:flutter/widgets.dart';

import '../contracts/inspector_routes.dart';
import '../wiring/not_available_yet.dart';

/// The captions panel (ux.md §10.9).
class SubtitlesPanel extends StatelessWidget {
  /// Creates the placeholder.
  const SubtitlesPanel({super.key, required this.route});

  /// What the panel edits.
  final SubtitlesInspector route;

  @override
  Widget build(BuildContext context) => const EditorNotAvailableYet(label: 'Captions panel', owner: 'UX-31');
}
