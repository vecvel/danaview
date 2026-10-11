// OWNER: UX-39
//
// The settings part of the export sheet (ux.md §11.2): preset chips, the summary with the size
// estimate, notices (aspect mismatch with "Change project to 9:16", clamps), the Custom settings
// (format, codec, resolution, frame rate, quality, video and audio bitrate; everything gated by the
// device's capabilities), captions (burn-in per subtitle track, SRT / VTT side files), the
// destination, "Keep a copy in Danaview", an inline storage problem and the Export button.
//
// Custom components only (ARCH §1.3): `DanaviewChoiceChip`, `DanaviewSegmentedControl`, `DanaviewSwitchRow`,
// `DanaviewSlider`, `DanaviewButton`. Text wraps instead of truncating, so nothing overflows from 280 px
// at a text scale of 1.35.

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:danaview_editor_core/plan.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../../app/strings/export_strings.dart';
import 'export_controller.dart';

/// Text styles of the export sheet (Figtree, ARCH §1.3 rule 6).
abstract final class ExportText {
  /// Section label.
  static final TextStyle section = DanaviewTextStyles.label.copyWith(fontFamily: DanaviewFonts.family, color: DanaviewColors.textSecondary);

  /// Body.
  static final TextStyle body = DanaviewTextStyles.body.copyWith(fontFamily: DanaviewFonts.family);

  /// Secondary body.
  static final TextStyle secondary = DanaviewTextStyles.bodySecondary.copyWith(fontFamily: DanaviewFonts.family);

  /// Caption.
  static final TextStyle caption = DanaviewTextStyles.caption.copyWith(fontFamily: DanaviewFonts.family, height: 1.35);

  /// Headline.
  static final TextStyle headline = DanaviewTextStyles.headline.copyWith(fontFamily: DanaviewFonts.family);

  /// Title.
  static final TextStyle title = DanaviewTextStyles.title.copyWith(fontFamily: DanaviewFonts.family);

  /// Big number.
  static final TextStyle big = DanaviewTextStyles.largeTitle.copyWith(fontFamily: DanaviewFonts.family, fontSize: 32);
}

/// Presets, settings, captions, destination and the Export button.
class ExportSetupView extends StatelessWidget {
  /// Creates the view.
  const ExportSetupView({
    super.key,
    required this.setup,
    required this.controller,
    required this.platform,
    required this.onChangeAspect,
  });

  /// The setup state.
  final ExportUiSetup setup;

  /// The controller.
  final ExportController controller;

  /// The theme platform (Photos or Gallery).
  final TargetPlatform platform;

  /// "Change project to 9:16": closes the sheet and opens the Canvas panel.
  final VoidCallback onChangeAspect;

  @override
  Widget build(BuildContext context) {
    final draft = setup.draft;
    final custom = draft.settings.preset == ExportPresetId.custom;
    final presets = [
      ExportPresetId.youtube,
      if (setup.limits.offer4kPreset) ExportPresetId.youtube4k,
      ExportPresetId.youtubeShorts,
      ExportPresetId.instagramReels,
      ExportPresetId.instagramFeed,
      ExportPresetId.tiktok,
      ExportPresetId.custom,
    ];
    final busy = setup.checkingStorage;
    return Column(
      key: const ValueKey('export-setup'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(ExportStrings.presetsSection, style: ExportText.section),
        const SizedBox(height: DanaviewSpacing.sm),
        DanaviewChipGroup(
          children: [
            for (final id in presets)
              DanaviewChoiceChip(
                key: ValueKey('export-preset-${id.name}'),
                label: ExportStrings.presetLabel(id),
                selected: draft.settings.preset == id,
                onTap: () => controller.selectPreset(id),
              ),
          ],
        ),
        const SizedBox(height: DanaviewSpacing.md),
        _Summary(setup: setup, custom: custom, onEdit: () => controller.selectPreset(ExportPresetId.custom)),
        for (final notice in setup.resolved.notices) ...[
          const SizedBox(height: DanaviewSpacing.sm),
          _NoticeRow(setup: setup, notice: notice, onChangeAspect: onChangeAspect),
        ],
        if (custom) ...[
          const SizedBox(height: DanaviewSpacing.lg),
          _CustomSettings(setup: setup, controller: controller),
        ],
        if (setup.subtitleTracks.isNotEmpty) ...[
          const SizedBox(height: DanaviewSpacing.lg),
          _Captions(setup: setup, controller: controller),
        ],
        const SizedBox(height: DanaviewSpacing.lg),
        Text(ExportStrings.saveToSection, style: ExportText.section),
        const SizedBox(height: DanaviewSpacing.sm),
        DanaviewSegmentedControl<ExportDestination>(
          key: const ValueKey('export-destination'),
          value: draft.destination,
          options: [
            DanaviewOption(value: ExportDestination.photos, label: ExportStrings.photosDestination(platform), icon: Icons.photo_library_rounded),
            const DanaviewOption(value: ExportDestination.files, label: ExportStrings.filesDestination, icon: Icons.folder_rounded),
            const DanaviewOption(value: ExportDestination.share, label: ExportStrings.shareDestination, icon: Icons.ios_share_rounded),
          ],
          onChanged: controller.setDestination,
        ),
        const SizedBox(height: DanaviewSpacing.xs),
        DanaviewSwitchRow(
          key: const ValueKey('export-keep-copy'),
          title: ExportStrings.keepCopy,
          subtitle: ExportStrings.keepCopyHint,
          value: draft.keepCopy,
          onChanged: controller.setKeepCopy,
        ),
        if (setup.issue != null) ...[
          const SizedBox(height: DanaviewSpacing.md),
          _StorageIssue(setup: setup, controller: controller),
        ],
        const SizedBox(height: DanaviewSpacing.lg),
        DanaviewButton.primary(
          key: const ValueKey('export-start'),
          label: ExportStrings.exportButton,
          icon: Icons.ios_share_rounded,
          expand: true,
          onPressed: busy ? null : controller.start,
        ),
      ],
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.setup, required this.custom, required this.onEdit});

  final ExportUiSetup setup;
  final bool custom;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final e = setup.resolved.encode;
    final hardware = setup.limits.hardwareFor(e.codec);
    return DanaviewSurface(
      color: DanaviewColors.surface,
      padding: const EdgeInsets.all(DanaviewSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            ExportStrings.summary(width: e.width, height: e.height, fps: e.fps, codec: e.codec, estimatedBytes: setup.resolved.estimatedBytes),
            key: const ValueKey('export-summary'),
            style: ExportText.headline,
          ),
          const SizedBox(height: DanaviewSpacing.xs),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(hardware ? Icons.memory_rounded : Icons.hourglass_bottom_rounded, size: 16, color: DanaviewColors.textSecondary),
              ),
              const SizedBox(width: DanaviewSpacing.sm),
              Expanded(
                child: Text(
                  hardware ? ExportStrings.hardwareEncoder : ExportStrings.softwareEncoder,
                  key: const ValueKey('export-encoder-note'),
                  style: ExportText.caption.copyWith(color: DanaviewColors.textSecondary),
                ),
              ),
            ],
          ),
          if (!custom) ...[
            const SizedBox(height: DanaviewSpacing.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: DanaviewButton.ghost(
                key: const ValueKey('export-edit'),
                label: ExportStrings.editSettings,
                icon: Icons.tune_rounded,
                size: DanaviewButtonSize.sm,
                onPressed: onEdit,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _NoticeRow extends StatelessWidget {
  const _NoticeRow({required this.setup, required this.notice, required this.onChangeAspect});

  final ExportUiSetup setup;
  final ExportNotice notice;
  final VoidCallback onChangeAspect;

  @override
  Widget build(BuildContext context) {
    final preset = setup.draft.settings.preset;
    final encode = setup.resolved.encode;
    final text = switch (notice.code) {
      ExportNoticeCode.aspectMismatch => ExportStrings.aspectMismatch(
          project: setup.projectAspect,
          output: notice.suggestedAspect ?? setup.projectAspect,
          preset: preset,
        ),
      ExportNoticeCode.resolutionClamped => ExportStrings.resolutionClamped(setup.limits.caps.maxExportShortSide),
      ExportNoticeCode.fpsClamped => ExportStrings.fpsClamped(encode.fps),
      ExportNoticeCode.hevcUnavailable => ExportStrings.hevcUnavailable,
      ExportNoticeCode.movUnavailable => ExportStrings.movUnavailable,
      ExportNoticeCode.bitrateClamped => ExportStrings.bitrateClamped,
    };
    final mismatch = notice.code == ExportNoticeCode.aspectMismatch;
    return DanaviewSurface(
      key: ValueKey('export-notice-${notice.code.name}'),
      color: DanaviewColors.surface,
      padding: const EdgeInsets.all(DanaviewSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 1),
                child: Icon(Icons.info_outline_rounded, size: 18, color: DanaviewColors.warning),
              ),
              const SizedBox(width: DanaviewSpacing.sm),
              Expanded(child: Text(text, style: ExportText.secondary)),
            ],
          ),
          if (mismatch && notice.suggestedAspect != null) ...[
            const SizedBox(height: DanaviewSpacing.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: DanaviewButton.secondary(
                key: const ValueKey('export-change-aspect'),
                label: ExportStrings.changeProjectTo(notice.suggestedAspect!),
                size: DanaviewButtonSize.sm,
                onPressed: onChangeAspect,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.child, this.caption});

  final String label;
  final Widget child;
  final String? caption;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: DanaviewSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: ExportText.section),
            const SizedBox(height: DanaviewSpacing.xs),
            child,
            if (caption != null) ...[
              const SizedBox(height: DanaviewSpacing.xs),
              Text(caption!, style: ExportText.caption),
            ],
          ],
        ),
      );
}

class _CustomSettings extends StatelessWidget {
  const _CustomSettings({required this.setup, required this.controller});

  final ExportUiSetup setup;
  final ExportController controller;

  @override
  Widget build(BuildContext context) {
    final s = setup.draft.settings;
    final limits = setup.limits;
    final encode = setup.resolved.encode;
    final auto = s.videoBitrateMbps == null;
    final shownMbps = (s.videoBitrateMbps ?? encode.videoBitrate / 1e6).clamp(minCustomVideoMbps, maxCustomVideoMbps).toDouble();
    return Column(
      key: const ValueKey('export-custom'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(ExportStrings.customSection, style: ExportText.headline),
        const SizedBox(height: DanaviewSpacing.md),
        if (limits.canMov)
          _Row(
            label: ExportStrings.formatRow,
            child: DanaviewChipGroup(children: [
              for (final c in ExportContainer.values)
                DanaviewChoiceChip(
                  key: ValueKey('export-container-${c.name}'),
                  label: ExportStrings.containerLabel(c),
                  selected: s.container == c,
                  onTap: () => controller.updateSettings((v) => v.copyWith(container: c)),
                ),
            ]),
          ),
        if (limits.canHevc)
          _Row(
            label: ExportStrings.codecRow,
            child: DanaviewChipGroup(children: [
              for (final c in VideoCodec.values)
                DanaviewChoiceChip(
                  key: ValueKey('export-codec-${c.name}'),
                  label: ExportStrings.codecLabel(c),
                  selected: s.codec == c,
                  onTap: () => controller.updateSettings((v) => v.copyWith(codec: c)),
                ),
            ]),
          ),
        _Row(
          label: ExportStrings.resolutionRow,
          caption: ExportStrings.resolutionSize(encode.width, encode.height),
          child: DanaviewChipGroup(children: [
            for (final side in limits.shortSides)
              DanaviewChoiceChip(
                key: ValueKey('export-size-$side'),
                label: ExportStrings.resolutionLabel(side),
                selected: s.shortSide == side,
                onTap: () => controller.updateSettings((v) => v.copyWith(shortSide: side)),
              ),
          ]),
        ),
        _Row(
          label: ExportStrings.fpsRow,
          child: DanaviewChipGroup(children: [
            DanaviewChoiceChip(
              key: const ValueKey('export-fps-match'),
              label: ExportStrings.fpsMatchProject,
              selected: s.fps == null,
              onTap: () => controller.updateSettings((v) => v.copyWith(fps: null)),
            ),
            for (final f in limits.fpsOptions(s.shortSide))
              DanaviewChoiceChip(
                key: ValueKey('export-fps-$f'),
                label: ExportStrings.fpsLabel(f),
                selected: s.fps == f,
                onTap: () => controller.updateSettings((v) => v.copyWith(fps: f)),
              ),
          ]),
        ),
        _Row(
          label: ExportStrings.qualityRow,
          child: DanaviewChipGroup(children: [
            for (final q in ExportQuality.values)
              DanaviewChoiceChip(
                key: ValueKey('export-quality-${q.name}'),
                label: ExportStrings.qualityLabel(q),
                selected: s.quality == q,
                onTap: () => controller.updateSettings((v) => v.copyWith(quality: q)),
              ),
          ]),
        ),
        _Row(
          label: ExportStrings.videoBitrateRow,
          caption: auto ? null : ExportStrings.bitrateValue(shownMbps),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              DanaviewChipGroup(children: [
                DanaviewChoiceChip(
                  key: const ValueKey('export-bitrate-auto'),
                  label: ExportStrings.bitrateAuto(encode.videoBitrate / 1e6),
                  selected: auto,
                  onTap: () => controller.updateSettings((v) => v.copyWith(videoBitrateMbps: null)),
                ),
                DanaviewChoiceChip(
                  key: const ValueKey('export-bitrate-custom'),
                  label: ExportStrings.bitrateCustom,
                  selected: !auto,
                  onTap: () => controller.updateSettings((v) => v.copyWith(videoBitrateMbps: auto ? shownMbps.roundToDouble() : v.videoBitrateMbps)),
                ),
              ]),
              if (!auto)
                Padding(
                  padding: const EdgeInsets.only(top: DanaviewSpacing.sm),
                  child: DanaviewSlider(
                    key: const ValueKey('export-bitrate-slider'),
                    value: shownMbps,
                    min: minCustomVideoMbps,
                    max: maxCustomVideoMbps,
                    divisions: (maxCustomVideoMbps - minCustomVideoMbps).round(),
                    semanticLabel: ExportStrings.bitrateSlider,
                    semanticFormatter: ExportStrings.bitrateValue,
                    onChanged: (v) => controller.updateSettings((x) => x.copyWith(videoBitrateMbps: v.roundToDouble())),
                  ),
                ),
            ],
          ),
        ),
        _Row(
          label: ExportStrings.audioBitrateRow,
          child: DanaviewChipGroup(children: [
            for (final k in const [96, 128, 192, 256, 320])
              DanaviewChoiceChip(
                key: ValueKey('export-audio-$k'),
                label: ExportStrings.audioLabel(k),
                selected: (s.audioBitrateKbps ?? 192) == k,
                onTap: () => controller.updateSettings((v) => v.copyWith(audioBitrateKbps: k)),
              ),
          ]),
        ),
      ],
    );
  }
}

class _Captions extends StatelessWidget {
  const _Captions({required this.setup, required this.controller});

  final ExportUiSetup setup;
  final ExportController controller;

  @override
  Widget build(BuildContext context) {
    final sides = setup.draft.settings.sideFiles;
    return Column(
      key: const ValueKey('export-captions'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(ExportStrings.captionsSection, style: ExportText.section),
        for (final track in setup.subtitleTracks)
          DanaviewSwitchRow(
            key: ValueKey('export-burn-${track.id.value}'),
            title: ExportStrings.burnTrack(track.name),
            value: track.burnIn,
            onChanged: (on) => controller.setBurnIn(track.id, on),
          ),
        const SizedBox(height: DanaviewSpacing.sm),
        Text(ExportStrings.sideFilesRow, style: ExportText.secondary),
        const SizedBox(height: DanaviewSpacing.xs),
        DanaviewChipGroup(children: [
          for (final f in SideFileFormat.values)
            DanaviewChoiceChip(
              key: ValueKey('export-side-${f.name}'),
              label: ExportStrings.sideFileLabel(f),
              selected: sides.contains(f),
              onTap: () => controller.setSideFile(f, !sides.contains(f)),
            ),
        ]),
      ],
    );
  }
}

class _StorageIssue extends StatelessWidget {
  const _StorageIssue({required this.setup, required this.controller});

  final ExportUiSetup setup;
  final ExportController controller;

  @override
  Widget build(BuildContext context) {
    final issue = setup.issue!;
    return DanaviewSurface(
      key: const ValueKey('export-storage-issue'),
      color: DanaviewColors.surface,
      padding: const EdgeInsets.all(DanaviewSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 1),
                child: Icon(Icons.sd_card_alert_rounded, size: 18, color: DanaviewColors.warning),
              ),
              const SizedBox(width: DanaviewSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(ExportStrings.lowStorage(issue.neededBytes), style: ExportText.body),
                    const SizedBox(height: 2),
                    Text(ExportStrings.lowStorageFree(issue.freeBytes), style: ExportText.caption),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: DanaviewSpacing.md),
          DanaviewButtonBar(
            children: [
              DanaviewButton.secondary(
                key: const ValueKey('export-lower-resolution'),
                label: ExportStrings.lowerResolution,
                onPressed: controller.lowerResolution,
              ),
              if (controller.canFreeUpSpace)
                DanaviewButton.secondary(
                  key: const ValueKey('export-free-up-space'),
                  label: ExportStrings.freeUpSpace,
                  onPressed: controller.freeUpSpace,
                ),
            ],
          ),
        ],
      ),
    );
  }
}
