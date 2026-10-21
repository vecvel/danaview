// OWNER: ST-04
//
// Settings › Privacy (V2-402, ST plan D-ST2): the speed test's open-network answer, remembered
// from the one-time prompt and changeable here. Turning it on is the same agreement as "Run on
// open network"; turning it off withdraws it (revoked), and the speed test then never uses the open
// network and never asks again. The app root hands [buildPrivacySettingsSection] to
// `SettingsSections.privacy` (INT-103). No provider is named (D-ST5).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../library/library_widgets.dart';
import '../../tools/network_tool_providers.dart';

/// For `SettingsSections(privacy: buildPrivacySettingsSection)`.
Widget buildPrivacySettingsSection(BuildContext context) => const PrivacySettingsSection();

/// The Privacy header, the open-network toggle and what it means.
class PrivacySettingsSection extends ConsumerWidget {
  const PrivacySettingsSection({super.key});

  static const String title = 'Open network speed tests';
  static const String subtitle = 'Only when our usual test servers are busy';
  static const String explanation = 'Results on the open measurement network, including your IP address, '
      'are published publicly for research.';
  static const String unaskedNote = "You'll be asked the first time it's needed.";

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final answer = ref.watch(speedConsentProvider);
    final value = answer.valueOrNull;
    final allowed = value?.isAccepted ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const DanaviewLibrarySectionHeader('Privacy'),
        DanaviewLibraryGroup(
          children: [
            DanaviewSwitchRow(
              key: const ValueKey('privacy-open-network-speed-test'),
              leading: const DanaviewTileIcon(Icons.public_rounded, color: DanaviewColors.primaryLight, size: 40),
              title: title,
              subtitle: subtitle,
              value: allowed,
              onChanged: value == null
                  ? null
                  : (on) => ref.read(speedConsentProvider.notifier).setAllowed(on),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(DanaviewSpacing.xs, DanaviewSpacing.sm, DanaviewSpacing.xs, 0),
          child: Text(
            value?.choice == SpeedConsentChoice.unasked ? '$explanation $unaskedNote' : explanation,
            style: DanaviewTextStyles.caption,
          ),
        ),
      ],
    );
  }
}
