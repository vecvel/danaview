import 'package:flutter/material.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../library/library_widgets.dart';
import 'media_data_usage.dart';
import 'media_tool_format.dart';
import 'media_tool_widgets.dart';

export 'media_data_usage.dart' show DataUsageMath, StreamQuality;

enum _Mode { data, watchTime }

/// Data usage calculator: how much data a stretch of video uses at a given quality, or how long
/// an amount of data lasts. Pure arithmetic on typical streaming bitrates; nothing is measured.
class DanaviewDataUsageScreen extends StatefulWidget {
  const DanaviewDataUsageScreen({super.key, required this.onBack});

  final VoidCallback onBack;

  @override
  State<DanaviewDataUsageScreen> createState() => _DanaviewDataUsageScreenState();
}

class _DanaviewDataUsageScreenState extends State<DanaviewDataUsageScreen> {
  _Mode _mode = _Mode.data;

  /// Null when a custom bitrate is used.
  StreamQuality? _quality = StreamQuality.fullHd1080;
  double _customMbps = 8;
  double _hours = 2;
  double _minutes = 0;
  double _gigabytes = 5;

  double get _mbps => _quality?.megabitsPerSecond ?? _customMbps;

  String get _qualityLabel => _quality?.label ?? 'a custom bitrate';

  Duration get _duration => Duration(hours: _hours.round(), minutes: _minutes.round());

  @override
  Widget build(BuildContext context) {
    final watching = _mode == _Mode.watchTime;
    return MediaToolPage(
      title: 'Data usage',
      subtitle: 'Streaming and download estimates',
      onBack: widget.onBack,
      children: [
        DanaviewSegmentedControl<_Mode>(
          value: _mode,
          options: const [
            DanaviewOption(value: _Mode.data, label: 'Data needed', icon: Icons.data_usage_rounded),
            DanaviewOption(value: _Mode.watchTime, label: 'Watch time', icon: Icons.schedule_rounded),
          ],
          onChanged: (mode) => setState(() => _mode = mode),
        ),
        const SizedBox(height: DanaviewSpacing.lg),
        watching ? _watchTimeResult() : _dataResult(),
        DanaviewLibrarySectionHeader(watching ? 'Data you have' : 'How long'),
        DanaviewSurface(
          color: DanaviewColors.surface,
          padding: const EdgeInsets.fromLTRB(DanaviewSpacing.lg, DanaviewSpacing.md, DanaviewSpacing.md, DanaviewSpacing.sm),
          child: watching ? _dataInput() : _durationInput(),
        ),
        const DanaviewLibrarySectionHeader('Video quality'),
        DanaviewLibraryGroup(
          children: [
            for (final quality in StreamQuality.values)
              _qualityRow(
                title: quality.label,
                description: quality.description,
                icon: _qualityIcons[quality]!,
                mbps: quality.megabitsPerSecond,
                selected: _quality == quality,
                onTap: () => setState(() => _quality = quality),
              ),
            _qualityRow(
              title: 'Custom bitrate',
              icon: Icons.tune_rounded,
              mbps: _customMbps,
              selected: _quality == null,
              onTap: () => setState(() => _quality = null),
            ),
          ],
        ),
        if (_quality == null) ...[
          const SizedBox(height: DanaviewSpacing.md),
          DanaviewSurface(
            color: DanaviewColors.surface,
            padding: const EdgeInsets.fromLTRB(DanaviewSpacing.lg, DanaviewSpacing.md, DanaviewSpacing.md, DanaviewSpacing.sm),
            child: MediaStepperSlider(
              label: 'Bitrate',
              valueLabel: formatMbps(_customMbps),
              value: _customMbps,
              min: 0.5,
              max: 50,
              step: 0.5,
              onChanged: (v) => setState(() => _customMbps = v),
            ),
          ),
        ],
        const MediaToolFootnote(
          'Estimates use typical average bitrates. Real usage depends on the service, codec and '
          "scene, and downloading a video uses about as much data as streaming it. Media info shows a "
          "file's exact bitrate.",
        ),
      ],
    );
  }

  Widget _dataResult() {
    final duration = _duration;
    final total = DataUsageMath.bytesFor(_mbps, duration);
    final perHour = DataUsageMath.bytesPerHour(_mbps);
    return MediaResultCard(
      eyebrow: 'Estimated data',
      value: formatDataSize(total),
      caption: duration == Duration.zero
          ? 'Choose how long you plan to watch.'
          : 'For ${formatWatchTime(duration)} of $_qualityLabel video (${formatMbps(_mbps)}).',
      stats: [
        (label: 'Per hour', value: formatDataSize(perHour)),
        (label: 'Per minute', value: formatDataSize(perHour / 60)),
      ],
    );
  }

  Widget _watchTimeResult() {
    final bytes = _gigabytes * DataUsageMath.bytesPerGigabyte;
    return MediaResultCard(
      eyebrow: 'Watch time',
      value: formatWatchTime(DataUsageMath.watchTimeFor(_mbps, bytes)),
      caption: 'With ${formatDataSize(bytes)} of $_qualityLabel video (${formatMbps(_mbps)}).',
      stats: [
        (label: 'Per hour', value: formatDataSize(DataUsageMath.bytesPerHour(_mbps))),
        (label: 'Per GB', value: formatWatchTime(DataUsageMath.watchTimeFor(_mbps, DataUsageMath.bytesPerGigabyte))),
      ],
    );
  }

  Widget _durationInput() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MediaStepperSlider(
          label: 'Hours',
          valueLabel: _hours.round() == 1 ? '1\u00A0hour' : '${_hours.round()}\u00A0hours',
          value: _hours,
          min: 0,
          max: 24,
          step: 1,
          onChanged: (v) => setState(() => _hours = v),
        ),
        const SizedBox(height: DanaviewSpacing.md),
        MediaStepperSlider(
          label: 'Minutes',
          valueLabel: '${_minutes.round()}\u00A0min',
          value: _minutes,
          min: 0,
          max: 55,
          step: 5,
          onChanged: (v) => setState(() => _minutes = v),
        ),
      ],
    );
  }

  Widget _dataInput() {
    return MediaStepperSlider(
      label: 'Data allowance',
      valueLabel: formatDataSize(_gigabytes * DataUsageMath.bytesPerGigabyte),
      value: _gigabytes,
      min: 0.5,
      max: 100,
      step: 0.5,
      onChanged: (v) => setState(() => _gigabytes = v),
    );
  }

  /// A selectable quality with what it costs per hour, or how long the allowance lasts with it.
  ///
  /// The description goes in the subtitle rather than a badge, which can't shrink on narrow rows.
  Widget _qualityRow({
    required String title,
    String? description,
    required IconData icon,
    required double mbps,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final figure = _mode == _Mode.watchTime
        ? formatWatchTime(DataUsageMath.watchTimeFor(mbps, _gigabytes * DataUsageMath.bytesPerGigabyte))
        : '${formatDataSize(DataUsageMath.bytesPerHour(mbps))} per hour';
    final subtitle = [if (description != null) description, figure, formatMbps(mbps)].join(' · ');
    return DanaviewLibraryRow(
      leading: DanaviewIconTile(icon, color: selected ? DanaviewColors.primaryLight : DanaviewColors.textSecondary, size: 40),
      title: title,
      subtitle: subtitle,
      subtitleMaxLines: 2,
      highlighted: selected,
      onTap: onTap,
      semanticLabel: '$title, $subtitle${selected ? ', selected' : ''}',
      trailing: selected
          ? const Padding(
              padding: EdgeInsets.all(DanaviewSpacing.sm),
              child: Icon(Icons.check_rounded, size: 22, color: DanaviewColors.primaryLight),
            )
          : null,
    );
  }
}

const _qualityIcons = {
  StreamQuality.sd480: Icons.sd_rounded,
  StreamQuality.hd720: Icons.hd_rounded,
  StreamQuality.fullHd1080: Icons.hd_rounded,
  StreamQuality.qhd1440: Icons.high_quality_rounded,
  StreamQuality.uhd4k: Icons.four_k_rounded,
};
