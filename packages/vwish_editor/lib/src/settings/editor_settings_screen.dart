// OWNER: UX-04
//
// The Editor settings screen (ARCH §17.10, ux.md §4.8): proxy media, default preview quality,
// centre playhead on touch, snapping haptics, default new-project format, and the slot for UX-38's
// Auto captions section (shown only with VWISH_AUTO_CAPTIONS, D-31). Every value is an `editor.`
// preference written through `EditorPrefs` the moment it changes. Reached from Settings › Video
// editor (`/settings/editor`, INT-02); navigation comes from the router.

import 'package:flutter/material.dart' show Icons, Scaffold;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vwish_features/chrome.dart';
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import '../app/editor_availability.dart';
import '../app/editor_prefs.dart';
import '../app/editor_providers.dart';
import '../app/strings/settings_strings.dart';
import 'captions_settings_section.dart';

/// Editor preferences (ARCH §17.10). Navigation comes from the router (INT-02).
class EditorSettingsScreen extends ConsumerWidget {
  /// Creates the screen.
  const EditorSettingsScreen({super.key, required this.onBack});

  /// Leaves the screen.
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(editorPrefsProvider);
    return Scaffold(
      backgroundColor: VwishColors.background,
      body: VwishLibraryFrame(
        topBar: VwishLibraryTopBar(title: SettingsStrings.title, onBack: onBack),
        body: LayoutBuilder(
          builder: (context, constraints) => ListenableBuilder(
            listenable: prefs,
            builder: (context, _) => ListView(
              key: const ValueKey('editor-settings-list'),
              padding: vwishLibraryInsets(constraints.maxWidth).copyWith(
                top: VwishSpacing.sm,
                bottom: MediaQuery.paddingOf(context).bottom + VwishSpacing.xxl,
              ),
              children: [
                const VwishLibrarySectionHeader(SettingsStrings.previewSection, topSpacing: VwishSpacing.md),
                _ChoiceSetting<ProxyMediaMode>(
                  key: const ValueKey('editor-settings-proxy'),
                  icon: Icons.speed_rounded,
                  color: VwishColors.cyan,
                  title: SettingsStrings.proxyTitle,
                  description: SettingsStrings.proxyDescription,
                  hint: SettingsStrings.proxyHint(prefs.proxyMedia),
                  value: prefs.proxyMedia,
                  options: [
                    for (final mode in ProxyMediaMode.values) VwishOption(value: mode, label: SettingsStrings.proxyLabel(mode)),
                  ],
                  onChanged: prefs.setProxyMedia,
                ),
                const SizedBox(height: VwishSpacing.md),
                _ChoiceSetting<PreviewQualityPreference>(
                  key: const ValueKey('editor-settings-preview-quality'),
                  icon: Icons.high_quality_rounded,
                  color: VwishColors.primaryLight,
                  title: SettingsStrings.previewQualityTitle,
                  description: SettingsStrings.previewQualityDescription,
                  value: prefs.previewQuality,
                  options: [
                    for (final quality in PreviewQualityPreference.values)
                      VwishOption(value: quality, label: SettingsStrings.previewQualityLabel(quality)),
                  ],
                  onChanged: prefs.setPreviewQuality,
                ),
                const VwishLibrarySectionHeader(SettingsStrings.timelineSection),
                VwishLibraryGroup(
                  children: [
                    VwishSwitchRow(
                      key: const ValueKey('editor-settings-center-playhead'),
                      leading: const VwishTileIcon(Icons.center_focus_strong_rounded, color: VwishColors.purple, size: 40),
                      title: SettingsStrings.centerPlayheadTitle,
                      subtitle: SettingsStrings.centerPlayheadSubtitle,
                      value: prefs.centerPlayheadOnTouch,
                      onChanged: prefs.setCenterPlayheadOnTouch,
                    ),
                    VwishSwitchRow(
                      key: const ValueKey('editor-settings-snapping-haptics'),
                      leading: const VwishTileIcon(Icons.vibration_rounded, color: VwishColors.warning, size: 40),
                      title: SettingsStrings.snappingHapticsTitle,
                      subtitle: SettingsStrings.snappingHapticsSubtitle,
                      value: prefs.snappingHaptics,
                      onChanged: prefs.setSnappingHaptics,
                    ),
                  ],
                ),
                const VwishLibrarySectionHeader(SettingsStrings.newProjectsSection),
                _ChoiceSetting<NewProjectAspect>(
                  key: const ValueKey('editor-settings-aspect'),
                  icon: Icons.aspect_ratio_rounded,
                  color: VwishColors.success,
                  title: SettingsStrings.aspectTitle,
                  description: SettingsStrings.aspectDescription,
                  value: prefs.newProjectAspect,
                  options: [
                    for (final aspect in NewProjectAspect.values) VwishOption(value: aspect, label: SettingsStrings.aspectLabel(aspect)),
                  ],
                  onChanged: prefs.setNewProjectAspect,
                ),
                // Slot for UX-38 (model status, size, delete, default preset).
                if (EditorFlags.autoCaptionsEnabled) ...[
                  const SizedBox(height: VwishSpacing.xl),
                  const CaptionsSettingsSection(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A setting with an icon, a title, a description and a segmented choice (chips when narrow).
class _ChoiceSetting<T> extends StatelessWidget {
  const _ChoiceSetting({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    required this.description,
    required this.value,
    required this.options,
    required this.onChanged,
    this.hint,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String description;
  final String? hint;
  final T value;
  final List<VwishOption<T>> options;
  final Future<void> Function(T value) onChanged;

  @override
  Widget build(BuildContext context) {
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
                VwishTileIcon(icon, color: color, size: 40),
                const SizedBox(width: VwishSpacing.md),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 1),
                      Semantics(
                        header: true,
                        child: Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: VwishTextStyles.headline.copyWith(fontWeight: FontWeight.w500),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(description, style: VwishTextStyles.caption.copyWith(fontSize: 13, height: 1.3)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: VwishSpacing.md),
          VwishSegmentedControl<T>(value: value, options: options, onChanged: (next) => onChanged(next)),
          if (hint case final hint?) ...[
            const SizedBox(height: VwishSpacing.sm),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: VwishSpacing.xs),
              child: Text(hint, style: VwishTextStyles.caption.copyWith(fontSize: 13, height: 1.3)),
            ),
          ],
        ],
      ),
    );
  }
}
