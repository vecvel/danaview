// OWNER: ST-04
//
// The one-time open-network prompt of the speed test (V2-402, ST plan D-ST2), and the only place
// that creates an `OpenNetworkConsent` ticket (V2-23, ARCH v1.2 rule 28). The ticket comes either
// from the user choosing "Run on open network" here, or from that remembered answer (which the
// user can also give or withdraw in Settings › Privacy). The wording names no provider (D-ST5).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import 'network_tool_providers.dart';

/// The prompt's wording (D-ST2), shared with Settings › Privacy.
abstract final class SpeedConsentCopy {
  static const String title = 'Use an open network for this test?';
  static const String body = 'Our usual test servers are busy right now. Run the test on an open measurement '
      'network instead? Results there, including your IP address, are published publicly for research.';
  static const String accept = 'Run on open network';
  static const String decline = 'Not now';
  static const String remembered = 'Your answer is remembered. You can change it in Settings › Privacy.';
}

/// What the prompt returns.
enum SpeedConsentSheetResult { run, notNow }

/// Shows the prompt. Null when it was dismissed without an answer.
Future<SpeedConsentSheetResult?> showSpeedConsentSheet(BuildContext context) {
  return showDanaviewSheet<SpeedConsentSheetResult>(
    context,
    builder: (context) => const SpeedConsentSheet(),
  );
}

/// The prompt's content: what happens, and the two choices.
class SpeedConsentSheet extends StatelessWidget {
  const SpeedConsentSheet({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: DanaviewSpacing.sm),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const ExcludeSemantics(
              child: DanaviewTileIcon(Icons.public_rounded, color: DanaviewColors.primaryLight, size: 44),
            ),
            const SizedBox(width: DanaviewSpacing.md),
            Expanded(
              child: Semantics(
                header: true,
                child: const Text(SpeedConsentCopy.title, style: DanaviewTextStyles.headline),
              ),
            ),
          ],
        ),
        const SizedBox(height: DanaviewSpacing.md),
        const Text(SpeedConsentCopy.body, style: DanaviewTextStyles.bodySecondary),
        const SizedBox(height: DanaviewSpacing.sm),
        const Text(SpeedConsentCopy.remembered, style: DanaviewTextStyles.caption),
        const SizedBox(height: DanaviewSpacing.lg),
        DanaviewButton.primary(
          label: SpeedConsentCopy.accept,
          icon: Icons.public_rounded,
          size: DanaviewButtonSize.lg,
          expand: true,
          onPressed: () => Navigator.of(context).pop(SpeedConsentSheetResult.run),
        ),
        const SizedBox(height: DanaviewSpacing.sm),
        DanaviewButton.secondary(
          label: SpeedConsentCopy.decline,
          size: DanaviewButtonSize.lg,
          expand: true,
          onPressed: () => Navigator.of(context).pop(SpeedConsentSheetResult.notNow),
        ),
      ],
    );
  }
}

/// The coordinator's consent request for one run of the screen at [context].
///
/// A remembered "Run on open network" becomes a ticket without asking; a remembered "Not now"
/// (or a toggle turned off in Settings) returns null without asking. Never asked: the prompt
/// shows; its answer is remembered. Dismissing the prompt counts as "Not now" for this run only.
Future<OpenNetworkConsent?> requestOpenNetworkConsent(
  BuildContext context,
  WidgetRef ref, {
  DateTime Function() now = DateTime.now,
}) async {
  final SpeedConsentAnswer answer;
  try {
    answer = await ref.read(speedConsentProvider.future);
  } catch (_) {
    return null;
  }
  switch (answer.choice) {
    case SpeedConsentChoice.accepted:
      return OpenNetworkConsent.accepted(answer.acceptedAt!);
    case SpeedConsentChoice.declined:
      return null;
    case SpeedConsentChoice.unasked:
      break;
  }
  if (!context.mounted) return null;
  final result = await showSpeedConsentSheet(context);
  if (!context.mounted) return null;
  final controller = ref.read(speedConsentProvider.notifier);
  switch (result) {
    case SpeedConsentSheetResult.run:
      final at = now();
      await controller.accept(at);
      return OpenNetworkConsent.accepted(at);
    case SpeedConsentSheetResult.notNow:
      await controller.decline();
      return null;
    case null:
      return null;
  }
}
