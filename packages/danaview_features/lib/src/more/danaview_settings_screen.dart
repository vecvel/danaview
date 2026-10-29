// EXTENDED: INT-101 (settings section slots: privacy, library storage, search index; BUILD_PLAN §5)

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../controllers/providers.dart';
import '../library/library_widgets.dart';
import 'app_info.dart';
import 'profile_controller.dart';
import 'settings_destination.dart';
import 'settings_sections/settings_sections.dart';
import 'settings_widgets.dart';

export 'settings_sections/settings_sections.dart';

/// Settings hub: the profile card, built-in tools, playback preferences (touch screens only) and
/// the about pages. Each row is named like the page it opens.
class DanaviewSettingsScreen extends StatelessWidget {
  const DanaviewSettingsScreen({
    super.key,
    required this.onBack,
    required this.onNavigate,
    this.onOpenEditorSettings,
    this.sections = const SettingsSections(),
  });

  final VoidCallback onBack;
  final ValueChanged<SettingsDestination> onNavigate;

  /// Opens the video editor's settings (`/settings/editor`). The router passes it only where the
  /// editor is available (ARCH §17.1, D-17); null hides the "Video editor" row. Routes stay
  /// explicit, so [SettingsDestination] has no editor value.
  final VoidCallback? onOpenEditorSettings;

  /// The 1.2.0 sections (privacy, library storage, search index), built by their owners and passed
  /// by the app root (INT-103). Each set builder adds its section after the Tools group; the
  /// default (none) is the 1.1 screen.
  final SettingsSections sections;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: DanaviewColors.background,
      body: DanaviewLibraryFrame(
        topBar: DanaviewLibraryTopBar(title: 'Settings', onBack: onBack),
        body: LayoutBuilder(
          builder: (context, constraints) {
            final insets = DanaviewSpacing.pageInsets(constraints.maxWidth);
            return ListView(
              padding: insets.copyWith(
                top: DanaviewSpacing.lg,
                bottom: MediaQuery.paddingOf(context).bottom + DanaviewSpacing.xxl,
              ),
              children: [
                _ProfileCard(onTap: () => onNavigate(SettingsDestination.profile)),
                const DanaviewLibrarySectionHeader('Tools', topSpacing: DanaviewSpacing.xl),
                DanaviewLibraryGroup(
                  children: [
                    _row(
                      SettingsDestination.speedTest,
                      'Speed test',
                      'Internet download, upload and ping',
                      Icons.speed_rounded,
                    ),
                    _row(
                      SettingsDestination.streamCheck,
                      'Stream check',
                      'Test a video link before you play it',
                      Icons.network_check_rounded,
                    ),
                    _row(
                      SettingsDestination.mediaInfo,
                      'Media info',
                      'Format, size and details of a video file',
                      Icons.movie_filter_rounded,
                    ),
                    _row(
                      SettingsDestination.dataUsage,
                      'Data usage',
                      'Estimate data used by streaming',
                      Icons.data_usage_rounded,
                    ),
                    _row(
                      SettingsDestination.storage,
                      'Storage & history',
                      'History, resume points and saved data',
                      Icons.storage_rounded,
                    ),
                    if (onOpenEditorSettings case final openEditorSettings?)
                      SettingsNavRow(
                        key: const ValueKey('settings-video-editor'),
                        icon: Icons.movie_edit,
                        title: 'Video editor',
                        subtitle: 'Proxy media, preview quality and new projects',
                        onTap: openEditorSettings,
                      ),
                  ],
                ),
                for (final (slot, build) in sections.ordered)
                  KeyedSubtree(key: ValueKey('settings-section-${slot.name}'), child: Builder(builder: build)),
                // Desktops have no double-tap: a double-click there toggles fullscreen.
                if (context.isTouchPlatform) ...[
                  const DanaviewLibrarySectionHeader('Playback'),
                  const _DoubleTapSeekSetting(),
                ],
                const DanaviewLibrarySectionHeader('About'),
                DanaviewLibraryGroup(
                  children: [
                    SettingsNavRow(
                      leading: const DanaviewLogo(size: 40, semanticLabel: null),
                      title: 'About Danaview',
                      subtitle: 'Version $danaviewAppVersion',
                      onTap: () => onNavigate(SettingsDestination.about),
                    ),
                    _row(
                      SettingsDestination.privacy,
                      'Privacy Policy',
                      null,
                      Icons.privacy_tip_rounded,
                    ),
                    _row(
                      SettingsDestination.terms,
                      'Terms of Use',
                      null,
                      Icons.gavel_rounded,
                    ),
                  ],
                ),
                const SizedBox(height: DanaviewSpacing.xl),
                const Text(
                  'Danaview $danaviewAppVersion ($danaviewBuildNumber)',
                  textAlign: TextAlign.center,
                  style: DanaviewTextStyles.caption,
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _row(SettingsDestination destination, String title, String? subtitle, IconData icon) {
    return SettingsNavRow(
      icon: icon,
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

    return DanaviewPressable(
      onTap: onTap,
      borderRadius: DanaviewRadius.mediaAll,
      semanticLabel: empty ? 'Set up your profile' : 'Profile: $title. $subtitle',
      child: DanaviewSurface(
        shadow: DanaviewShadow.subtle,
        padding: const EdgeInsetsDirectional.fromSTEB(14, 14, 8, 14),
        child: Row(
          children: [
            ProfileAvatar(initials: profile.initials, size: 52),
            const SizedBox(width: DanaviewSpacing.md),
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
                    style: DanaviewTextStyles.headline,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: subtitleIsDetail ? 1 : 2,
                    softWrap: !subtitleIsDetail,
                    overflow: TextOverflow.ellipsis,
                    style: DanaviewTextStyles.caption.copyWith(fontSize: 13, height: 1.3),
                  ),
                ],
              ),
            ),
            const SizedBox(width: DanaviewSpacing.xs),
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
    return DanaviewSurface(
      color: DanaviewColors.surface,
      padding: const EdgeInsets.all(DanaviewSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(DanaviewSpacing.xs, DanaviewSpacing.xs, DanaviewSpacing.xs, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const DanaviewIconTile(Icons.touch_app_rounded, size: 40),
                const SizedBox(width: DanaviewSpacing.md),
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
                        style: DanaviewTextStyles.headline.copyWith(fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Double-tap the left or right of the video to jump back or forward by $seconds seconds.',
                        style: DanaviewTextStyles.caption.copyWith(fontSize: 13, height: 1.3),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: DanaviewSpacing.md),
          DanaviewSegmentedControl<int>(
            value: seconds,
            options: [
              for (final option in SessionRepository.doubleTapSeekOptions)
                DanaviewOption(value: option, label: '${option}s'),
            ],
            onChanged: (value) => ref.read(doubleTapSeekProvider.notifier).set(value),
          ),
        ],
      ),
    );
  }
}
