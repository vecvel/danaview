// OWNER: UX-44
//
// Settings › Video editor › Render preview (ARCH §17.10, D-45), shown in UX-04's second settings
// slot of `EditorSettingsScreen`:
//
// * **Render preview** Auto / Manual (`editor.renderPreview`). Unset, it shows the tier default
//   (`EditorTierDefaults`: Auto on the minimal and low tiers, Manual on mid and high) and marks it
//   "Recommended for this device"; choosing a value stores it, and the explicit value wins from
//   then on. Auto on a mid/high device explains that nothing renders automatically there.
// * A one-line description of the trade-off (smooth playback vs storage and battery; export never
//   changes).
// * **Clear rendered previews**: the size of `renders/` and a Clear button behind a confirmation
//   (the "Editor cache" storage contributor clears the same folder). Hidden when the app has no
//   render cache (`renderPreviewStoreProvider` not overridden).

import 'dart:async';

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/render_cache.dart' show RenderPreviewSetting;
import 'package:danaview_features/chrome.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../app/editor_providers.dart';
import '../app/editor_tier_defaults.dart';
import '../app/strings/render_preview_strings.dart';
import '../editor/state/render_preview_controller.dart' show RenderPreviewStore, renderPreviewStoreProvider;

/// The Render preview settings section (file header).
class RenderPreviewSettingsSection extends ConsumerStatefulWidget {
  /// Creates the section.
  const RenderPreviewSettingsSection({super.key});

  @override
  ConsumerState<RenderPreviewSettingsSection> createState() => _RenderPreviewSettingsSectionState();
}

class _RenderPreviewSettingsSectionState extends ConsumerState<RenderPreviewSettingsSection> {
  int? _bytes;
  bool _clearing = false;
  RenderPreviewStore? _measured;

  Future<void> _measure(RenderPreviewStore store) async {
    _measured = store;
    int bytes;
    try {
      bytes = await store.bytes();
    } on Object {
      bytes = 0;
    }
    if (mounted && identical(_measured, store)) setState(() => _bytes = bytes);
  }

  Future<void> _clear(RenderPreviewStore store) async {
    final ok = await showDanaviewConfirm(
      context,
      title: RenderPreviewStrings.clearConfirmTitle,
      message: RenderPreviewStrings.clearConfirmMessage,
      confirmLabel: RenderPreviewStrings.clear,
      destructive: true,
      icon: Icons.delete_sweep_rounded,
    );
    if (!ok || !mounted) return;
    setState(() => _clearing = true);
    try {
      await store.clear();
    } on Object catch (e) {
      debugPrint('[RenderPreview] clear failed: ${e.runtimeType}');
    }
    if (!mounted) return;
    setState(() => _clearing = false);
    DanaviewToast.show(context, RenderPreviewStrings.cleared, icon: Icons.check_circle_rounded, kind: DanaviewToastKind.success);
    await _measure(store);
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(editorPrefsProvider);
    final defaults = ref.watch(editorTierDefaultsProvider);
    final store = ref.watch(renderPreviewStoreProvider);
    if (store != null && !identical(store, _measured)) unawaited(_measure(store));
    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) {
        final value = defaults.effectiveRenderPreview(prefs);
        final hint = value == RenderPreviewSetting.auto && !defaults.isConstrained
            ? RenderPreviewStrings.autoNotOnThisDevice
            : RenderPreviewStrings.settingHint(value, isDefault: value == defaults.renderPreview);
        return Column(
          key: const ValueKey('render-preview-settings'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const DanaviewLibrarySectionHeader(RenderPreviewStrings.section, topSpacing: DanaviewSpacing.md),
            DanaviewSurface(
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
                        const DanaviewTileIcon(Icons.movie_filter_rounded, color: DanaviewColors.success, size: 40),
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
                                  RenderPreviewStrings.settingTitle,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: DanaviewTextStyles.headline.copyWith(fontWeight: FontWeight.w500),
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                RenderPreviewStrings.settingDescription,
                                key: const ValueKey('render-preview-description'),
                                style: DanaviewTextStyles.caption.copyWith(fontSize: 13, height: 1.3),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: DanaviewSpacing.md),
                  DanaviewSegmentedControl<RenderPreviewSetting>(
                    key: const ValueKey('render-preview-setting'),
                    value: value,
                    options: [
                      for (final s in RenderPreviewSetting.values) DanaviewOption(value: s, label: RenderPreviewStrings.settingLabel(s)),
                    ],
                    onChanged: (next) => EditorTierDefaults.setRenderPreview(prefs, next),
                  ),
                  const SizedBox(height: DanaviewSpacing.sm),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: DanaviewSpacing.xs),
                    child: Text(
                      hint,
                      key: const ValueKey('render-preview-hint'),
                      style: DanaviewTextStyles.caption.copyWith(fontSize: 13, height: 1.3),
                    ),
                  ),
                ],
              ),
            ),
            if (store != null) ...[
              const SizedBox(height: DanaviewSpacing.md),
              DanaviewSurface(
                key: const ValueKey('render-preview-clear'),
                color: DanaviewColors.surface,
                padding: const EdgeInsets.all(DanaviewSpacing.md),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  alignment: WrapAlignment.spaceBetween,
                  spacing: DanaviewSpacing.md,
                  runSpacing: DanaviewSpacing.sm,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 120),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            RenderPreviewStrings.clearTitle,
                            style: DanaviewTextStyles.headline.copyWith(fontWeight: FontWeight.w500),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            RenderPreviewStrings.clearSubtitle(_bytes),
                            key: const ValueKey('render-preview-size'),
                            style: DanaviewTextStyles.caption.copyWith(fontSize: 13, height: 1.3),
                          ),
                        ],
                      ),
                    ),
                    DanaviewButton(
                      key: const ValueKey('render-preview-clear-button'),
                      label: RenderPreviewStrings.clear,
                      variant: DanaviewButtonVariant.destructive,
                      onPressed: _clearing || (_bytes ?? 0) == 0 ? null : () => _clear(store),
                    ),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
