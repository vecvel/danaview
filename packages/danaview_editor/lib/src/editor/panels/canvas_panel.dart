// OWNER: UX-29
//
// Placeholder (D-33) created by UX-01. UX-29 replaces this file:
// the format panel (ux.md §10.14).
// Keep the constructor contract `CanvasPanel({Key? key, required CanvasInspector route})`: InspectorHost (UX-16)
// builds panels with it.
// Until then it declares only the public names other files compile against.

import 'package:flutter/widgets.dart';

import '../contracts/inspector_routes.dart';
import '../wiring/not_available_yet.dart';

/// The format panel (ux.md §10.14).
class CanvasPanel extends StatelessWidget {
  /// Creates the placeholder.
  const CanvasPanel({super.key, required this.route});

  /// What the panel edits.
  final CanvasInspector route;

  @override
  Widget build(BuildContext context) => const EditorNotAvailableYet(label: 'Format panel', owner: 'UX-29');
}
