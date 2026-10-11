// OWNER: UX-34
//
// Placeholder (D-33) created by UX-01. UX-34 replaces this file:
// the voiceover panel (ux.md §10.5).
// Keep the constructor contract `VoiceoverPanel({Key? key, required VoiceoverInspector route})`: InspectorHost (UX-16)
// builds panels with it.
// Until then it declares only the public names other files compile against.

import 'package:flutter/widgets.dart';

import '../contracts/inspector_routes.dart';
import '../wiring/not_available_yet.dart';

/// The voiceover panel (ux.md §10.5).
class VoiceoverPanel extends StatelessWidget {
  /// Creates the placeholder.
  const VoiceoverPanel({super.key, required this.route});

  /// What the panel edits.
  final VoiceoverInspector route;

  @override
  Widget build(BuildContext context) => const EditorNotAvailableYet(label: 'Voiceover panel', owner: 'UX-34');
}
