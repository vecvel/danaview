// OWNER: UX-04
//
// The Editor settings screen (ARCH §17.10, ux.md §4.8): proxy media, default preview quality,
// centre playhead on touch, snapping haptics, default new-project format, and the slot for UX-38's
// Auto captions section (shown only with DANAVIEW_AUTO_CAPTIONS, D-31). Every value is an `editor.`
// preference written through `EditorPrefs` the moment it changes. Reached from Settings › Video
// editor (`/settings/editor`, INT-02); navigation comes from the router.

import 'package:flutter/material.dart' show Icons, Scaffold;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_features/chrome.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

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
      backgroundColor: DanaviewColors.background,
      body: DanaviewLibraryFrame(
        topBar: DanaviewLibraryTopBar(title: SettingsStrings.title, onBack: onBack),
        body: LayoutBuilder(
          builder: (context, constraints) => ListenableBuilder(
            listenable: prefs,
            builder: (context, _) => ListView(
              key: const ValueKey('editor-settings-list'),
              padding: danaviewLibraryInsets(constraints.maxWidth).copyWith(
                top: DanaviewSpacing.sm,
                bottom: MediaQuery.paddingOf(context).bottom + DanaviewSpacing.xxl,
              ),
              children: [
                const DanaviewLibrarySectionHeader(SettingsStrings.previewSection, topSpacing: DanaviewSpacing.md),
                _ChoiceSetting<ProxyMediaMode>(
                  key: const ValueKey('editor-settings-proxy'),
                  icon: Icons.speed_rounded,
                  color: DanaviewColors.cyan,
                  title: SettingsStrings.proxyTitle,
                  description: SettingsStrings.proxyDescription,
                  hint: SettingsStrings.proxyHint(prefs.proxyMedia),
                  value: prefs.proxyMedia,
                  options: [
                    for (final mode in ProxyMediaMode.values) DanaviewOption(value: mode, label: SettingsStrings.proxyLabel(mode)),
                  ],
                  onChanged: prefs.setProxyMedia,
                ),
                const SizedBox(height: DanaviewSpacing.md),
                _ChoiceSetting<PreviewQualityPreference>(
                  key: const ValueKey('editor-settings-preview-quality'),
                  icon: Icons.high_quality_rounded,
                  color: DanaviewColors.primaryLight,
                  title: SettingsStrings.previewQualityTitle,
                  description: SettingsStrings.previewQualityDescription,
                  value: prefs.previewQuality,
                  options: [
                    for (final quality in PreviewQualityPreference.values)
                      DanaviewOption(value: quality, label: SettingsStrings.previewQualityLabel(quality)),
                  ],
                  onChanged: prefs.setPreviewQuality,
                ),
                const DanaviewLibrarySectionHeader(SettingsStrings.timelineSection),
                DanaviewLibraryGroup(
                  children: [
                    DanaviewSwitchRow(
                      key: const ValueKey('editor-settings-center-playhead'),
                      leading: const DanaviewTileIcon(Icons.center_focus_strong_rounded, color: DanaviewColors.purple, size: 40),
                      title: SettingsStrings.centerPlayheadTitle,
                      subtitle: SettingsStrings.centerPlayheadSubtitle,
                      value: prefs.centerPlayheadOnTouch,
                      onChanged: prefs.setCenterPlayheadOnTouch,
                    ),
                    DanaviewSwitchRow(
                      key: const ValueKey('editor-settings-snapping-haptics'),
                      leading: const DanaviewTileIcon(Icons.vibration_rounded, color: DanaviewColors.warning, size: 40),
                      title: SettingsStrings.snappingHapticsTitle,
                      subtitle: SettingsStrings.snappingHapticsSubtitle,
                      value: prefs.snappingHaptics,
                      onChanged: prefs.setSnappingHaptics,
                    ),
                  ],
                ),
                const DanaviewLibrarySectionHeader(SettingsStrings.newProjectsSection),
                _ChoiceSetting<NewProjectAspect>(
                  key: const ValueKey('editor-settings-aspect'),
                  icon: Icons.aspect_ratio_rounded,
                  color: DanaviewColors.success,
                  title: SettingsStrings.aspectTitle,
                  description: SettingsStrings.aspectDescription,
                  value: prefs.newProjectAspect,
                  options: [
                    for (final aspect in NewProjectAspect.values) DanaviewOption(value: aspect, label: SettingsStrings.aspectLabel(aspect)),
                  ],
                  onChanged: prefs.setNewProjectAspect,
                ),
                // Slot for UX-38 (model status, size, delete, default preset).
                if (EditorFlags.autoCaptionsEnabled) ...[
                  const SizedBox(height: DanaviewSpacing.xl),
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
  final List<DanaviewOption<T>> options;
  final Future<void> Function(T value) onChanged;

  @override
  Widget build(BuildContext context) {
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
                DanaviewTileIcon(icon, color: color, size: 40),
                const SizedBox(width: DanaviewSpacing.md),
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
                          style: DanaviewTextStyles.headline.copyWith(fontWeight: FontWeight.w500),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(description, style: DanaviewTextStyles.caption.copyWith(fontSize: 13, height: 1.3)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: DanaviewSpacing.md),
          DanaviewSegmentedControl<T>(value: value, options: options, onChanged: (next) => onChanged(next)),
          if (hint case final hint?) ...[
            const SizedBox(height: DanaviewSpacing.sm),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.xs),
              child: Text(hint, style: DanaviewTextStyles.caption.copyWith(fontSize: 13, height: 1.3)),
            ),
          ],
        ],
      ),
    );
  }
}
