// OWNER: UX-37
//
// Placeholder (D-33) created by UX-01. UX-37 replaces this file:
// the speech-model download consent; the only caller of UserConsent.accepted (ARCH §4.2 rule 8).
// Until then it declares only the public names other files compile against.

import 'package:flutter/widgets.dart';

import '../../wiring/not_available_yet.dart';

/// The speech-model download consent; the only caller of UserConsent.accepted (ARCH §4.2 rule 8).
class ModelConsentView extends StatelessWidget {
  /// Creates the placeholder.
  const ModelConsentView({super.key});

  @override
  Widget build(BuildContext context) => const EditorNotAvailableYet(label: 'Model download', owner: 'UX-37');
}
