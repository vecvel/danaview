// OWNER: UX-28
//
// Placeholder (D-33) created by UX-01. UX-28 replaces this file:
// the chroma key panel (ux.md §10.10).
// Keep the constructor contract `ChromaPanel({Key? key, required ChromaInspector route})`: InspectorHost (UX-16)
// builds panels with it.
// Until then it declares only the public names other files compile against.

import 'package:flutter/widgets.dart';

import '../contracts/inspector_routes.dart';
import '../wiring/not_available_yet.dart';

/// The chroma key panel (ux.md §10.10).
class ChromaPanel extends StatelessWidget {
  /// Creates the placeholder.
  const ChromaPanel({super.key, required this.route});

  /// What the panel edits.
  final ChromaInspector route;

  @override
  Widget build(BuildContext context) => const EditorNotAvailableYet(label: 'Chroma key panel', owner: 'UX-28');
}
