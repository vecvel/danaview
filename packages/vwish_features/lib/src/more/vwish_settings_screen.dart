import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vwish_data/vwish_data.dart';
import 'package:vwish_domain/vwish_domain.dart';
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import '../controllers/providers.dart';
import '../library/library_widgets.dart';
import 'app_info.dart';
import 'profile_controller.dart';
import 'settings_destination.dart';
import 'settings_widgets.dart';

/// Settings hub: the profile card, built-in tools, playback preferences (touch screens only) and
/// the about pages. Each row is named like the page it opens.
class VwishSettingsScreen extends StatelessWidget {
  const VwishSettingsScreen({
    super.key,
    required this.onBack,
    required this.onNavigate,
    this.onOpenEditorSettings,
  });

  final VoidCallback onBack;
  final ValueChanged<SettingsDestination> onNavigate;

  /// Opens the video editor's settings (`/settings/editor`). The router passes it only where the
  /// editor is available (ARCH §17.1, D-17); null hides the "Video editor" row. Routes stay
  /// explicit, so [SettingsDestination] has no editor value.
  final VoidCallback? onOpenEditorSettings;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: VwishColors.background,
      body: VwishLibraryFrame(
        topBar: VwishLibraryTopBar(title: 'Settings', onBack: onBack),
        body: LayoutBuilder(
          builder: (context, constraints) {
            final insets = vwishLibraryInsets(constraints.maxWidth);
            return ListView(
              padding: insets.copyWith(
                top: VwishSpacing.lg,
                bottom: MediaQuery.paddingOf(context).bottom + VwishSpacing.xxl,
              ),
              children: [
                _ProfileCard(onTap: () => onNavigate(SettingsDestination.profile)),
                const VwishLibrarySectionHeader('Tools', topSpacing: VwishSpacing.xl),
                VwishLibraryGroup(
                  children: [
                    _row(
                      SettingsDestination.speedTest,
                      'Speed test',
                      'Internet download, upload and ping',
                      Icons.speed_rounded,
                      VwishColors.cyan,
                    ),
                    _row(
                      SettingsDestination.streamCheck,
                      'Stream check',
                      'Test a video link before you play it',
                      Icons.network_check_rounded,
                      VwishColors.primaryLight,
                    ),
                    _row(
                      SettingsDestination.mediaInfo,
                      'Media info',
                      'Format, size and details of a video file',
                      Icons.movie_filter_rounded,
                      VwishColors.purple,
                    ),
                    _row(
                      SettingsDestination.dataUsage,
                      'Data usage',
                      'Estimate data used by streaming',
                      Icons.data_usage_rounded,
                      VwishColors.warning,
                    ),
                    _row(
                      SettingsDestination.storage,
                      'Storage & history',
                      'History, resume points and saved data',
                      Icons.storage_rounded,
                      VwishColors.success,
                    ),
                    if (onOpenEditorSettings case final openEditorSettings?)
                      SettingsNavRow(
                        key: const ValueKey('settings-video-editor'),
                        icon: Icons.movie_edit,
                        color: VwishColors.purple,
                        title: 'Video editor',
                        subtitle: 'Proxy media, preview quality and new projects',
                        onTap: openEditorSettings,
                      ),
                  ],
                ),
                // Desktops have no double-tap: a double-click there toggles fullscreen.
                if (context.isTouchPlatform) ...[
                  const VwishLibrarySectionHeader('Playback'),
                  const _DoubleTapSeekSetting(),
                ],
                const VwishLibrarySectionHeader('About'),
                VwishLibraryGroup(
                  children: [
                    SettingsNavRow(
                      leading: const VwishLogo(size: 40, semanticLabel: null),
                      title: 'About Vwish',
                      subtitle: 'Version $vwishAppVersion',
                      onTap: () => onNavigate(SettingsDestination.about),
                    ),
                    _row(
                      SettingsDestination.privacy,
                      'Privacy Policy',
                      null,
                      Icons.privacy_tip_rounded,
                      VwishColors.success,
                    ),
                    _row(
                      SettingsDestination.terms,
                      'Terms of Use',
                      null,
                      Icons.gavel_rounded,
                      VwishColors.textSecondary,
                    ),
                  ],
                ),
                const SizedBox(height: VwishSpacing.xl),
                const Text(
                  'Vwish $vwishAppVersion ($vwishBuildNumber)',
                  textAlign: TextAlign.center,
                  style: VwishTextStyles.caption,
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _row(SettingsDestination destination, String title, String? subtitle, IconData icon, Color color) {
    return SettingsNavRow(
      icon: icon,
      color: color,
      title: title,
      subtitle: subtitle,
      onTap: () => onNavigate(destination),
    );
  }
}

class _ProfileCard extends ConsumerWidget {
  const _ProfileCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider).valueOrNull ?? UserProfile.empty;
    final empty = profile.isEmpty;
    final name = profile.name.isNotEmpty ? profile.name : null;
    final detail = profile.email.isNotEmpty ? profile.email : (profile.phone.isNotEmpty ? profile.phone : null);
    final title = empty ? 'Set up your profile' : name ?? detail ?? 'Your profile';
    final subtitle = empty
        ? 'Add your name and contact details. They stay on this device.'
        : name != null && detail != null
            ? detail
            : 'View and edit your profile';
    // An email or phone number has nowhere to wrap, so it gets one line and an ellipsis.
    final titleIsDetail = !empty && name == null && detail != null;
    final subtitleIsDetail = !empty && name != null && detail != null;

    return VwishPressable(
      onTap: onTap,
      borderRadius: VwishRadius.lgAll,
      semanticLabel: empty ? 'Set up your profile' : 'Profile: $title. $subtitle',
      child: VwishSurface(
        shadow: VwishShadow.subtle,
        padding: const EdgeInsetsDirectional.fromSTEB(14, 14, 8, 14),
        child: Row(
          children: [
            ProfileAvatar(initials: profile.initials, size: 52),
            const SizedBox(width: VwishSpacing.md),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: titleIsDetail ? 1 : 2,
                    softWrap: !titleIsDetail,
                    overflow: TextOverflow.ellipsis,
                    style: VwishTextStyles.headline,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: subtitleIsDetail ? 1 : 2,
                    softWrap: !subtitleIsDetail,
                    overflow: TextOverflow.ellipsis,
                    style: VwishTextStyles.caption.copyWith(fontSize: 13, height: 1.3),
                  ),
                ],
              ),
            ),
            const SizedBox(width: VwishSpacing.xs),
            const SettingsChevron(),
          ],
        ),
      ),
    );
  }
}

class _DoubleTapSeekSetting extends ConsumerWidget {
  const _DoubleTapSeekSetting();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seconds = ref.watch(doubleTapSeekProvider);
    return VwishSurface(
      color: VwishColors.surface,
      padding: const EdgeInsets.all(VwishSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(VwishSpacing.xs, VwishSpacing.xs, VwishSpacing.xs, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const VwishTileIcon(Icons.touch_app_rounded, color: VwishColors.primaryLight, size: 40),
                const SizedBox(width: VwishSpacing.md),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 1),
                      Text(
                        'Double-tap to seek',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: VwishTextStyles.headline.copyWith(fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Double-tap the left or right of the video to jump back or forward by $seconds seconds.',
                        style: VwishTextStyles.caption.copyWith(fontSize: 13, height: 1.3),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: VwishSpacing.md),
          VwishSegmentedControl<int>(
            value: seconds,
            options: [
              for (final option in SessionRepository.doubleTapSeekOptions)
                VwishOption(value: option, label: '${option}s'),
            ],
            onChanged: (value) => ref.read(doubleTapSeekProvider.notifier).set(value),
          ),
        ],
      ),
    );
  }
}
