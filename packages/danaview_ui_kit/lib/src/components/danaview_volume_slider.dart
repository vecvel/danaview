import 'package:flutter/material.dart';

import '../theme/danaview_theme.dart';
import '../theme/danaview_tokens.dart';
import 'danaview_icon_button.dart';
import 'danaview_slider.dart';

class DanaviewVolumeSlider extends StatelessWidget {
  final double volume; // 0.0 to 300.0
  final bool muted;
  final ValueChanged<double> onVolumeChanged;
  final VoidCallback onToggleMute;

  const DanaviewVolumeSlider({
    super.key,
    required this.volume,
    required this.muted,
    required this.onVolumeChanged,
    required this.onToggleMute,
  });

  static const double _sliderWidth = 96;
  static const double _boostLabelWidth = 40;
  static const double _iconSize = 36;

  @override
  Widget build(BuildContext context) {
    final effectiveVol = muted ? 0.0 : volume.clamp(0.0, 300.0);
    final isBoosted = effectiveVol > 100.0;
    final accent = isBoosted ? DanaviewColors.boostBand : DanaviewColors.primary;
    final icon = muted || effectiveVol == 0
        ? Icons.volume_off_rounded
        : effectiveVol < 50
            ? Icons.volume_mute_rounded
            : effectiveVol <= 100
                ? Icons.volume_down_rounded
                : Icons.volume_up_rounded;
    final iconExtent = context.isTouchPlatform ? DanaviewSpacing.minTapTarget : _iconSize;

    final muteButton = DanaviewIconButton(
      icon: icon,
      size: _iconSize,
      iconSize: 20,
      color: isBoosted ? DanaviewColors.boostBand : DanaviewColors.textPrimary,
      tooltip: muted ? 'Unmute (M)' : 'Mute (M)',
      onPressed: onToggleMute,
    );
    final slider = DanaviewSlider(
      value: effectiveVol,
      min: 0,
      max: 300,
      activeColor: accent,
      semanticLabel: 'Volume',
      semanticFormatter: (v) => '${v.round()}%',
      onChanged: onVolumeChanged,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        if (maxWidth < iconExtent + 24) {
          return SizedBox(width: maxWidth.isFinite ? maxWidth : _sliderWidth, child: slider);
        }
        final bounded = maxWidth.isFinite;
        final showBoost = isBoosted && (!bounded || maxWidth >= iconExtent + _sliderWidth + _boostLabelWidth);
        final sliderBox = SizedBox(width: _sliderWidth, child: slider);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            muteButton,
            if (bounded) Flexible(child: sliderBox) else sliderBox,
            if (showBoost)
              SizedBox(
                width: _boostLabelWidth,
                child: Text(
                  '${effectiveVol.round()}%',
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.fade,
                  textAlign: TextAlign.end,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    fontFeatures: [FontFeature.tabularFigures()],
                    color: DanaviewColors.boostBand,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
