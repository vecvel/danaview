// OWNER: UX-28
//
// Placeholder (D-33) created by UX-01. UX-28 replaces this file:
// the overlay panel (ux.md §10.13).
// Keep the constructor contract `OverlayPanel({Key? key, required OverlayInspector route})`: InspectorHost (UX-16)
// builds panels with it.
// Until then it declares only the public names other files compile against.

import 'package:flutter/widgets.dart';

import '../contracts/inspector_routes.dart';
import '../wiring/not_available_yet.dart';

/// The overlay panel (ux.md §10.13).
class OverlayPanel extends StatelessWidget {
  /// Creates the placeholder.
  const OverlayPanel({super.key, required this.route});

  /// What the panel edits.
  final OverlayInspector route;

  @override
  Widget build(BuildContext context) => const EditorNotAvailableYet(label: 'Overlay panel', owner: 'UX-28');
}
