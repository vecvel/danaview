// OWNER: UX-42 (Open-source licences row: FIX-LICENSES)

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../library/library_actions.dart';
import '../library/library_widgets.dart';
import 'app_info.dart';
import 'legal_texts.dart';
import 'settings_widgets.dart';

/// App identity, version, the legal pages, the open-source licences and support.
class DanaviewAboutScreen extends ConsumerWidget {
  const DanaviewAboutScreen({
    super.key,
    required this.onBack,
    required this.onOpenPrivacy,
    required this.onOpenTerms,
    this.onOpenLicenses,
  });

  final VoidCallback onBack;
  final VoidCallback onOpenPrivacy;
  final VoidCallback onOpenTerms;

  /// Opens Settings › About › Open-source licences (UX-42); null hides the row.
  final VoidCallback? onOpenLicenses;

  /// There is no mail client hand-off in the app, so tapping the address copies it.
  Future<void> _copyEmail(BuildContext context, String email) async {
    await Clipboard.setData(ClipboardData(text: email));
    if (context.mounted) showDanaviewSuccess(context, 'Email address copied');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final email = ref.watch(supportEmailProvider);
    return Scaffold(
      backgroundColor: DanaviewColors.background,
      body: DanaviewLibraryFrame(
        topBar: DanaviewLibraryTopBar(title: 'About', onBack: onBack),
        body: LayoutBuilder(
          builder: (context, constraints) {
            final insets = danaviewLibraryInsets(constraints.maxWidth);
            return ListView(
              padding: insets.copyWith(
                top: DanaviewSpacing.xxl,
                bottom: MediaQuery.paddingOf(context).bottom + DanaviewSpacing.xxl,
              ),
              children: [
                const _Identity(),
                const DanaviewLibrarySectionHeader('Legal', topSpacing: DanaviewSpacing.xl),
                DanaviewLibraryGroup(
                  children: [
                    SettingsNavRow(
                      icon: Icons.privacy_tip_rounded,
                      color: DanaviewColors.success,
                      title: 'Privacy Policy',
                      subtitle: 'Everything stays on your device',
                      onTap: onOpenPrivacy,
                    ),
                    SettingsNavRow(
                      icon: Icons.gavel_rounded,
                      color: DanaviewColors.textSecondary,
                      title: 'Terms of Use',
                      onTap: onOpenTerms,
                    ),
                    if (onOpenLicenses case final open?)
                      SettingsNavRow(
                        icon: Icons.description_rounded,
                        color: DanaviewColors.primaryLight,
                        title: 'Open-source licences',
                        subtitle: 'Software, fonts and models in Danaview',
                        onTap: open,
                      ),
                  ],
                ),
                if (email != null) ...[
                  const DanaviewLibrarySectionHeader('Support'),
                  DanaviewLibraryGroup(
                    children: [
                      SettingsNavRow(
                        icon: Icons.mail_rounded,
                        color: DanaviewColors.cyan,
                        title: 'Contact support',
                        subtitle: email,
                        subtitleMaxLines: 1,
                        trailing: const Padding(
                          padding: EdgeInsets.all(DanaviewSpacing.sm),
                          child: Icon(Icons.content_copy_rounded, size: 18, color: DanaviewColors.textMuted),
                        ),
                        semanticLabel: 'Contact support, $email. Copy address',
                        onTap: () => _copyEmail(context, email),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: DanaviewSpacing.xl),
                const Text(danaviewCopyright, textAlign: TextAlign.center, style: DanaviewTextStyles.caption),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Identity extends StatelessWidget {
  const _Identity();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const DanaviewLogo(size: 76, semanticLabel: 'Danaview logo'),
        const SizedBox(height: DanaviewSpacing.lg),
        Semantics(
          header: true,
          child: Text(
            'Danaview',
            style: DanaviewTextStyles.largeTitle.copyWith(fontSize: 24),
          ),
        ),
        const SizedBox(height: DanaviewSpacing.xs),
        const Text(
          'Version $danaviewAppVersion (build $danaviewBuildNumber)',
          style: DanaviewTextStyles.caption,
        ),
        const SizedBox(height: DanaviewSpacing.lg),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Text(
            'A fast video player for the files on your device and the streams you open. Danaview plays '
            'almost any format, remembers where you left off, and keeps your library, history and '
            'settings on your device.',
            style: DanaviewTextStyles.bodySecondary.copyWith(height: 1.45),
          ),
        ),
      ],
    );
  }
}
