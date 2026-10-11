import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import '../controllers/player_controller.dart';
import '../controllers/providers.dart';
import '../player/danaview_player_actions.dart';

enum SettingsCategory {
  main,
  video,
  color,
  audio,
  subtitles,
  playback,
  shortcuts,
}

/// Settings panel; sizes to its content within the bounds its parent allows and scrolls beyond them.
class DanaviewSettingsPanel extends ConsumerStatefulWidget {
  final VoidCallback onClose;

  /// Lists "E – Edit video" in the Keyboard Shortcuts cheat sheet (the player has an Edit action).
  final bool showEditShortcut;

  const DanaviewSettingsPanel({super.key, required this.onClose, this.showEditShortcut = false});

  @override
  ConsumerState<DanaviewSettingsPanel> createState() => _DanaviewSettingsPanelState();
}

class _DanaviewSettingsPanelState extends ConsumerState<DanaviewSettingsPanel> {
  SettingsCategory _category = SettingsCategory.main;

  static const TextStyle _valueStyle = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    color: DanaviewColors.primaryLight,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  void _open(SettingsCategory category) => setState(() => _category = category);

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(playerControllerProvider);
    final playerCtrl = ref.read(playerControllerProvider.notifier);

    return DanaviewSurface(
      shadow: DanaviewShadow.subtle,
      child: AnimatedSize(
        duration: DanaviewMotion.normal,
        curve: DanaviewMotion.curve,
        alignment: Alignment.bottomCenter,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(),
            Container(height: DanaviewBorders.width, color: DanaviewColors.hairline),
            Flexible(
              child: SingleChildScrollView(
                key: ValueKey(_category),
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                child: switch (_category) {
                  SettingsCategory.main => _buildMainMenu(state, playerCtrl),
                  SettingsCategory.video => _buildVideoMenu(state, playerCtrl),
                  SettingsCategory.color => _buildColorMenu(state, playerCtrl),
                  SettingsCategory.audio => _buildAudioMenu(state, playerCtrl),
                  SettingsCategory.subtitles => _buildSubtitlesMenu(state, playerCtrl),
                  SettingsCategory.playback => _buildPlaybackMenu(state, playerCtrl),
                  SettingsCategory.shortcuts => _buildShortcutsMenu(),
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final title = switch (_category) {
      SettingsCategory.main => 'Settings',
      SettingsCategory.video => 'Video',
      SettingsCategory.color => 'Color Adjustments',
      SettingsCategory.audio => 'Audio & Equalizer',
      SettingsCategory.subtitles => 'Subtitles',
      SettingsCategory.playback => 'Playback & A-B Loop',
      SettingsCategory.shortcuts => 'Keyboard Shortcuts',
    };
    final isMain = _category == SettingsCategory.main;

    return Padding(
      padding: EdgeInsets.fromLTRB(isMain ? 24 : 8, 6, 6, 6),
      child: Row(
        children: [
          if (isMain)
            const DanaviewTileIcon(Icons.tune_rounded, size: 28)
          else
            DanaviewIconButton(
              icon: Icons.arrow_back_ios_new_rounded,
              size: 36,
              iconSize: 16,
              tooltip: 'Back',
              semanticLabel: 'Back to settings',
              onPressed: () => _open(SettingsCategory.main),
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Semantics(
              header: true,
              child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: DanaviewTextStyles.headline),
            ),
          ),
          DanaviewIconButton(
            icon: Icons.close_rounded,
            size: 36,
            iconSize: 18,
            tooltip: 'Close',
            semanticLabel: 'Close settings',
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }

  Widget _section(String title, {String? value}) {
    return DanaviewSectionHeader(
      title,
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
      action: value == null
          ? null
          : Text(value, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: _valueStyle),
    );
  }

  Widget _buildMainMenu(PlayerState state, PlayerController playerCtrl) {
    final preset = _activePreset(state.audioFilter);
    final aspect = state.transform.aspectOverride ?? 'Auto';
    final loop = state.abLoop == null ? 'A-B loop off' : 'A-B loop on';

    Widget tile(IconData icon, String title, String subtitle, SettingsCategory category) {
      return DanaviewListTile(
        leading: DanaviewTileIcon(icon),
        title: title,
        subtitle: subtitle,
        showChevron: true,
        onTap: () => _open(category),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 4),
        tile(Icons.videocam_rounded, 'Video', 'Aspect $aspect · ${_hwdecLabel(playerCtrl.hwdecMode)} decoding',
            SettingsCategory.video),
        tile(Icons.palette_rounded, 'Color', _isNeutral(state.adjust) ? 'Brightness, contrast, saturation' : 'Adjusted',
            SettingsCategory.color),
        tile(Icons.graphic_eq_rounded, 'Audio & Equalizer',
            '${preset ?? 'Custom'} EQ · Delay ${_formatMs(state.audioDelay)}', SettingsCategory.audio),
        tile(Icons.subtitles_rounded, 'Subtitles',
            '${state.subtitleStyle.fontSize.round()} pt · Delay ${_formatMs(state.subtitleDelay)}',
            SettingsCategory.subtitles),
        tile(Icons.speed_rounded, 'Playback', '${formatPlaybackSpeed(state.speed)} · $loop', SettingsCategory.playback),
        tile(Icons.keyboard_rounded, 'Keyboard Shortcuts', 'Hotkey cheat sheet', SettingsCategory.shortcuts),
      ],
    );
  }

  Widget _buildVideoMenu(PlayerState state, PlayerController playerCtrl) {
    final transform = state.transform;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section('Aspect ratio'),
        DanaviewSegmentedControl<String?>(
          value: transform.aspectOverride,
          options: const [
            DanaviewOption(value: null, label: 'Auto'),
            DanaviewOption(value: '16:9', label: '16:9'),
            DanaviewOption(value: '4:3', label: '4:3'),
            DanaviewOption(value: '2.35:1', label: '2.35:1'),
          ],
          onChanged: (aspect) => playerCtrl.setVideoTransform(transform.copyWith(aspectOverride: aspect)),
        ),
        _section('Hardware decoding'),
        DanaviewSegmentedControl<HwdecMode>(
          value: playerCtrl.hwdecMode,
          options: [
            for (final mode in HwdecMode.values) DanaviewOption(value: mode, label: _hwdecLabel(mode)),
          ],
          onChanged: (mode) {
            playerCtrl.setHwdec(mode);
            setState(() {});
          },
        ),
        _section('Zoom', value: '${(transform.zoom * 100).round()}%'),
        DanaviewSlider(
          value: transform.zoom.clamp(0.5, 3.0),
          min: 0.5,
          max: 3.0,
          divisions: 25,
          origin: 1.0,
          semanticLabel: 'Zoom',
          semanticFormatter: (v) => '${(v * 100).round()}%',
          onChanged: (zoom) => playerCtrl.setVideoTransform(transform.copyWith(zoom: zoom)),
        ),
      ],
    );
  }

  Widget _buildColorMenu(PlayerState state, PlayerController playerCtrl) {
    final adjust = state.adjust;
    final channels = <(String, double, VideoAdjust Function(double))>[
      ('Brightness', adjust.brightness, (v) => adjust.copyWith(brightness: v)),
      ('Contrast', adjust.contrast, (v) => adjust.copyWith(contrast: v)),
      ('Saturation', adjust.saturation, (v) => adjust.copyWith(saturation: v)),
      ('Gamma', adjust.gamma, (v) => adjust.copyWith(gamma: v)),
      ('Hue', adjust.hue, (v) => adjust.copyWith(hue: v)),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (label, value, update) in channels) ...[
          _section(label, value: _signed(value.round())),
          DanaviewSlider(
            value: value.clamp(-100.0, 100.0),
            min: -100,
            max: 100,
            divisions: 200,
            origin: 0,
            semanticLabel: label,
            semanticFormatter: (v) => _signed(v.round()),
            onChanged: (v) => playerCtrl.setVideoAdjust(update(v)),
          ),
        ],
        const SizedBox(height: 16),
        DanaviewButton.secondary(
          label: 'Reset colors',
          icon: Icons.refresh_rounded,
          expand: true,
          onPressed: _isNeutral(adjust) ? null : () => playerCtrl.setVideoAdjust(VideoAdjust.normal),
        ),
      ],
    );
  }

  Widget _buildAudioMenu(PlayerState state, PlayerController playerCtrl) {
    final filter = state.audioFilter;
    final activePreset = _activePreset(filter);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section('Audio delay', value: _formatMs(state.audioDelay)),
        DanaviewSlider(
          value: state.audioDelay.inMilliseconds.toDouble().clamp(-2000.0, 2000.0),
          min: -2000,
          max: 2000,
          divisions: 80,
          origin: 0,
          semanticLabel: 'Audio delay',
          semanticFormatter: (v) => '${v.round()} milliseconds',
          onChanged: (ms) => playerCtrl.setAudioDelay(Duration(milliseconds: ms.round())),
        ),
        _section('Equalizer presets'),
        DanaviewChipGroup(
          children: [
            for (final preset in AudioFilter.presets.keys)
              DanaviewChoiceChip(
                label: preset,
                selected: preset == activePreset,
                onTap: () => playerCtrl.setAudioFilters(filter.applyPreset(preset)),
              ),
          ],
        ),
        _section('10-band equalizer', value: activePreset ?? 'Custom'),
        _EqualizerBands(
          bands: filter.equalizerBands,
          onChanged: (bands) => playerCtrl.setAudioFilters(filter.copyWith(equalizerBands: bands)),
        ),
        _section('Processing'),
        DanaviewSurface(
          color: DanaviewColors.surface,
          borderRadius: DanaviewRadius.mdAll,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DanaviewSwitchRow(
                title: 'Night mode',
                subtitle: 'Softens loud peaks and lifts quiet dialogue',
                value: filter.nightModeDrc,
                onChanged: (on) => playerCtrl.setAudioFilters(filter.copyWith(nightModeDrc: on)),
              ),
              Container(
                height: DanaviewBorders.width,
                margin: const EdgeInsets.only(left: 12),
                color: DanaviewColors.hairline,
              ),
              DanaviewSwitchRow(
                title: 'Loudness normalization',
                subtitle: 'Evens out volume at -16 LUFS',
                value: filter.loudnessNormalization,
                onChanged: (on) => playerCtrl.setAudioFilters(filter.copyWith(loudnessNormalization: on)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSubtitlesMenu(PlayerState state, PlayerController playerCtrl) {
    final style = state.subtitleStyle;
    final tracks = state.tracks;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section('Track'),
        DanaviewDropdown<String>(
          value: tracks.selectedSubtitleTrackId ?? 'no',
          expand: true,
          icon: Icons.subtitles_rounded,
          placeholder: 'Auto',
          options: [
            const DanaviewOption(value: 'no', label: 'Off'),
            for (final track in tracks.subtitleTracks) DanaviewOption(value: track.id, label: track.displayName),
          ],
          onChanged: playerCtrl.setSubtitleTrack,
        ),
        _section('Delay', value: _formatMs(state.subtitleDelay)),
        DanaviewSlider(
          value: state.subtitleDelay.inMilliseconds.toDouble().clamp(-5000.0, 5000.0),
          min: -5000,
          max: 5000,
          divisions: 200,
          origin: 0,
          semanticLabel: 'Subtitle delay',
          semanticFormatter: (v) => '${v.round()} milliseconds',
          onChanged: (ms) => playerCtrl.setSubtitleDelay(Duration(milliseconds: ms.round())),
        ),
        _section('Font size', value: '${style.fontSize.round()} pt'),
        DanaviewSlider(
          value: style.fontSize.clamp(24.0, 96.0),
          min: 24,
          max: 96,
          divisions: 72,
          semanticLabel: 'Subtitle font size',
          semanticFormatter: (v) => '${v.round()} points',
          onChanged: (size) => playerCtrl.setSubtitleStyle(style.copyWith(fontSize: size)),
        ),
        _section('Outline', value: '${style.borderSize.toStringAsFixed(1)} px'),
        DanaviewSlider(
          value: style.borderSize.clamp(0.0, 8.0),
          min: 0,
          max: 8,
          divisions: 16,
          semanticLabel: 'Subtitle outline',
          semanticFormatter: (v) => '${v.toStringAsFixed(1)} pixels',
          onChanged: (size) => playerCtrl.setSubtitleStyle(style.copyWith(borderSize: size)),
        ),
      ],
    );
  }

  Widget _buildPlaybackMenu(PlayerState state, PlayerController playerCtrl) {
    final loop = state.abLoop;
    final loopLabel = switch (loop) {
      null => 'Off',
      AbLoop(:final a, b: null) => 'A ${formatPlaybackDuration(a)}',
      AbLoop(:final a, :final b?) => '${formatPlaybackDuration(a)} – ${formatPlaybackDuration(b)}',
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section('Speed', value: formatPlaybackSpeed(state.speed)),
        DanaviewSlider(
          value: state.speed.clamp(0.25, 3.0),
          min: 0.25,
          max: 3.0,
          divisions: 11,
          origin: 1.0,
          semanticLabel: 'Playback speed',
          semanticFormatter: formatPlaybackSpeed,
          onChanged: playerCtrl.setSpeed,
        ),
        if (context.isTouchPlatform) ...[
          _section('Double-tap to seek', value: '${ref.watch(doubleTapSeekProvider)}s'),
          DanaviewSegmentedControl<int>(
            value: ref.watch(doubleTapSeekProvider),
            options: [
              for (final seconds in SessionRepository.doubleTapSeekOptions)
                DanaviewOption(value: seconds, label: '${seconds}s'),
            ],
            onChanged: (seconds) => ref.read(doubleTapSeekProvider.notifier).set(seconds),
          ),
        ],
        _section('A-B loop', value: loopLabel),
        DanaviewButtonBar(
          reverseWhenStacked: false,
          children: [
            DanaviewButton.secondary(
              label: 'Set A',
              icon: Icons.first_page_rounded,
              onPressed: () => playerCtrl.setAbLoop(state.position, null),
            ),
            DanaviewButton.secondary(
              label: 'Set B',
              icon: Icons.last_page_rounded,
              onPressed: loop == null ? null : () => playerCtrl.setAbLoop(loop.a, state.position),
            ),
            DanaviewButton.ghost(
              label: 'Clear',
              icon: Icons.clear_rounded,
              onPressed: loop == null ? null : () => playerCtrl.setAbLoop(null, null),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildShortcutsMenu() {
    final apple = defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.iOS;
    final shortcuts = <(List<String>, String)>[
      (['Space', 'K'], 'Play / Pause'),
      (['←', '→'], 'Seek 5 seconds'),
      (['J', 'L'], 'Seek 10 seconds'),
      (['↑', '↓'], 'Volume ±5%'),
      (['M'], 'Mute'),
      (['F'], 'Fullscreen'),
      (['T'], 'Always on top'),
      (['C'], 'Next subtitle track'),
      (['#'], 'Next audio track'),
      (['[', ']'], 'Speed ±0.1x'),
      (['I'], 'Stats for nerds'),
      (['P'], 'Queue'),
      (['O'], 'Open files'),
      if (widget.showEditShortcut) (['E'], 'Edit video'),
      ([apple ? '⌘ ,' : 'Ctrl ,'], 'Settings'),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final keysWidth = (constraints.maxWidth * 0.4).clamp(0.0, 120.0);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 6),
            for (final (keys, description) in shortcuts)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                child: Row(
                  children: [
                    SizedBox(
                      width: keysWidth,
                      child: Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [for (final key in keys) DanaviewBadge(key, color: DanaviewColors.textSecondary)],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: DanaviewTextStyles.body,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  static String _hwdecLabel(HwdecMode mode) => switch (mode) {
        HwdecMode.autoSafe => 'Auto-safe',
        HwdecMode.auto => 'Auto',
        HwdecMode.no => 'Software',
      };

  static bool _isNeutral(VideoAdjust a) =>
      a.brightness == 0 && a.contrast == 0 && a.saturation == 0 && a.gamma == 0 && a.hue == 0;

  static String _signed(int value) => value > 0 ? '+$value' : '$value';

  static String _formatMs(Duration d) => '${_signed(d.inMilliseconds)} ms';

  static String? _activePreset(AudioFilter filter) {
    final bands = filter.equalizerBands;
    for (final MapEntry(key: name, value: gains) in AudioFilter.presets.entries) {
      if (gains.length != bands.length) continue;
      var matches = true;
      for (var i = 0; i < gains.length && matches; i++) {
        matches = (bands[i].gain - gains[i]).abs() < 0.05;
      }
      if (matches) return name;
    }
    return null;
  }
}

class _EqualizerBands extends StatelessWidget {
  const _EqualizerBands({required this.bands, required this.onChanged});

  final List<EqualizerBand> bands;
  final ValueChanged<List<EqualizerBand>> onChanged;

  static const TextStyle _labelStyle = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w500,
    color: DanaviewColors.textMuted,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  Widget _label(String text, {Color? color}) {
    return SizedBox(
      height: 18,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(text, maxLines: 1, style: color == null ? _labelStyle : _labelStyle.copyWith(color: color)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 172,
      child: Row(
        children: [
          for (var i = 0; i < bands.length; i++)
            Expanded(
              child: Column(
                children: [
                  _label(
                    _gainLabel(bands[i].gain),
                    color: bands[i].gain.abs() >= 0.5 ? DanaviewColors.primaryLight : null,
                  ),
                  const SizedBox(height: 4),
                  Expanded(
                    child: DanaviewSlider(
                      axis: Axis.vertical,
                      value: bands[i].gain.clamp(-12.0, 12.0),
                      min: -12,
                      max: 12,
                      divisions: 48,
                      origin: 0,
                      semanticLabel: '${bands[i].label} hertz',
                      semanticFormatter: (v) => '${v.toStringAsFixed(1)} decibels',
                      onChanged: (gain) {
                        final updated = List<EqualizerBand>.of(bands);
                        updated[i] = bands[i].copyWith(gain: gain);
                        onChanged(updated);
                      },
                    ),
                  ),
                  const SizedBox(height: 4),
                  _label(bands[i].label),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _gainLabel(double gain) {
    final rounded = gain.round();
    return rounded > 0 ? '+$rounded' : '$rounded';
  }
}
