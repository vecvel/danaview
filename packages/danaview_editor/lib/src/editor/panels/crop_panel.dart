// OWNER: UX-23
//
// Placeholder (D-33) created by UX-01. UX-23 replaces this file:
// the crop (ux.md §7.5).
// Keep the constructor contract `CropPanel({Key? key, required CropInspector route})`: InspectorHost (UX-16)
// builds panels with it.
// Until then it declares only the public names other files compile against.

import 'package:flutter/widgets.dart';

import '../contracts/inspector_routes.dart';
import '../wiring/not_available_yet.dart';

/// The crop (ux.md §7.5).
class CropPanel extends StatelessWidget {
  /// Creates the placeholder.
  const CropPanel({super.key, required this.route});

  /// What the panel edits.
  final CropInspector route;

  @override
  Widget build(BuildContext context) => const EditorNotAvailableYet(label: 'Crop', owner: 'UX-23');
}
