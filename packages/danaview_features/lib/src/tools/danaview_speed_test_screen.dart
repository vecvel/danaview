import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_data/danaview_data.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../library/library_widgets.dart';
import 'media_tool_format.dart' show formatDataSize;
import 'network_format.dart';
import 'network_tool_providers.dart';
import 'speed_gauge.dart';

export 'network_tool_providers.dart' show speedTestServiceProvider;

enum _TestStatus { idle, running, done, stopped, failed }

/// Internet speed test: a live dial, download / upload / ping / jitter, and what the result means
/// for streaming video. Leaving the page stops a running test.
class DanaviewSpeedTestScreen extends ConsumerStatefulWidget {
  const DanaviewSpeedTestScreen({super.key, required this.onBack});

  final VoidCallback onBack;

  @override
  ConsumerState<DanaviewSpeedTestScreen> createState() => _DanaviewSpeedTestScreenState();
}

class _DanaviewSpeedTestScreenState extends ConsumerState<DanaviewSpeedTestScreen> {
  static const _dialMaxSize = 300.0;
  static const _dialMinSize = 180.0;
  static const _twoColumnWidth = 640.0;

  _TestStatus _status = _TestStatus.idle;
  SpeedTestUpdate? _update;
  String? _error;
  StreamSubscription<SpeedTestUpdate>? _subscription;

  SpeedTestResult? get _result => _update?.result;

  @override
  void dispose() {
    // Cancelling the subscription stops the test and closes its sockets.
    _subscription?.cancel();
    super.dispose();
  }

  void _start() {
    _subscription?.cancel();
    setState(() {
      _status = _TestStatus.running;
      _update = null;
      _error = null;
    });
    _subscription = ref.read(speedTestServiceProvider).run().listen(
      (update) {
        if (!mounted) return;
        setState(() {
          _update = update;
          if (update.result != null) _status = _TestStatus.done;
        });
      },
      onError: (Object error) {
        if (!mounted) return;
        setState(() {
          _status = _TestStatus.failed;
          _error = error is SpeedTestException ? error.message : 'The speed test stopped unexpectedly. Try again.';
        });
      },
      onDone: () {
        _subscription = null;
        if (mounted && _status == _TestStatus.running) setState(() => _status = _TestStatus.stopped);
      },
    );
  }

  void _stop() {
    _subscription?.cancel();
    _subscription = null;
    setState(() => _status = _TestStatus.stopped);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: DanaviewColors.background,
      body: DanaviewLibraryFrame(
        topBar: DanaviewLibraryTopBar(title: 'Speed test', subtitle: 'Download, upload and ping', onBack: widget.onBack),
        body: LayoutBuilder(
          builder: (context, constraints) {
            final insets = danaviewLibraryInsets(constraints.maxWidth);
            final contentWidth = constraints.maxWidth - insets.horizontal;
            // Small enough that Start stays on screen in a short landscape window.
            final dialSize = math.min(_dialMaxSize, math.max(_dialMinSize, constraints.maxHeight - 170));
            final dial = _dialColumn(dialSize);
            final details = _detailsColumn();
            return SingleChildScrollView(
              padding: insets.copyWith(
                top: DanaviewSpacing.lg,
                bottom: MediaQuery.paddingOf(context).bottom + DanaviewSpacing.xxl,
              ),
              child: contentWidth >= _twoColumnWidth
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(width: _dialMaxSize, child: dial),
                        const SizedBox(width: DanaviewSpacing.xl),
                        Expanded(child: details),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [dial, const SizedBox(height: DanaviewSpacing.xl), details],
                    ),
            );
          },
        ),
      ),
    );
  }

  Widget _dialColumn(double maxSize) {
    final update = _update;
    final server = _result?.serverLabel ?? _serverLabel(update);
    return Column(
      children: [
        LayoutBuilder(
          builder: (context, constraints) => Center(child: _gauge(math.min(constraints.maxWidth, maxSize))),
        ),
        const SizedBox(height: DanaviewSpacing.md),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: _PhaseSteps(update: update, running: _status == _TestStatus.running),
        ),
        const SizedBox(height: DanaviewSpacing.lg),
        ConstrainedBox(constraints: const BoxConstraints(maxWidth: 320), child: _actionButton()),
        if (server != null) ...[
          const SizedBox(height: DanaviewSpacing.sm),
          Text(
            'Cloudflare · $server',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: DanaviewTextStyles.caption,
          ),
        ],
      ],
    );
  }

  static String? _serverLabel(SpeedTestUpdate? update) {
    if (update == null) return null;
    final (city, colo) = (update.city, update.colo);
    if (city != null && colo != null) return '$city ($colo)';
    return city ?? colo;
  }

  Widget _gauge(double size) {
    final update = _update;
    final result = _result;
    if (_status == _TestStatus.running && update != null) {
      return switch (update.phase) {
        SpeedTestPhase.latency => DanaviewSpeedGauge(
            size: size,
            mbps: 0,
            color: DanaviewColors.primaryLight,
            label: 'PING',
            value: update.latencyMs == null ? '…' : update.latencyMs!.round().toString(),
            unit: 'ms',
          ),
        SpeedTestPhase.download || SpeedTestPhase.upload => DanaviewSpeedGauge(
            size: size,
            mbps: update.currentMbps,
            color: update.phase == SpeedTestPhase.download ? DanaviewColors.cyan : DanaviewColors.purple,
            label: update.phase == SpeedTestPhase.download ? 'DOWNLOAD' : 'UPLOAD',
            value: formatMbps(update.currentMbps),
            unit: 'Mbps',
          ),
        SpeedTestPhase.done => _downloadGauge(size, update.downloadMbps),
      };
    }
    if (_status == _TestStatus.running) {
      return DanaviewSpeedGauge(
        size: size,
        mbps: 0,
        color: DanaviewColors.primaryLight,
        label: 'CONNECTING',
        value: '…',
        unit: 'Mbps',
      );
    }
    if (result != null) return _downloadGauge(size, result.downloadMbps);
    if (update?.downloadMbps != null) return _downloadGauge(size, update!.downloadMbps);
    return DanaviewSpeedGauge(
      size: size,
      mbps: 0,
      color: DanaviewColors.primary,
      label: switch (_status) {
        _TestStatus.failed => 'NOT FINISHED',
        _TestStatus.stopped => 'STOPPED',
        _ => 'READY',
      },
      value: _status == _TestStatus.idle ? '0' : '–',
      unit: 'Mbps',
    );
  }

  Widget _downloadGauge(double size, double? mbps) => DanaviewSpeedGauge(
        size: size,
        mbps: mbps ?? 0,
        color: DanaviewColors.cyan,
        label: 'DOWNLOAD',
        value: mbps == null ? '–' : formatMbps(mbps),
        unit: 'Mbps',
      );

  Widget _actionButton() {
    return switch (_status) {
      _TestStatus.idle => DanaviewButton.primary(
          label: 'Start test',
          icon: Icons.play_arrow_rounded,
          size: DanaviewButtonSize.lg,
          expand: true,
          onPressed: _start,
        ),
      _TestStatus.running => DanaviewButton.secondary(
          label: 'Stop',
          icon: Icons.stop_rounded,
          size: DanaviewButtonSize.lg,
          expand: true,
          onPressed: _stop,
        ),
      _TestStatus.failed => DanaviewButton.primary(
          label: 'Try again',
          icon: Icons.refresh_rounded,
          size: DanaviewButtonSize.lg,
          expand: true,
          onPressed: _start,
        ),
      _TestStatus.done || _TestStatus.stopped => DanaviewButton.primary(
          label: 'Test again',
          icon: Icons.refresh_rounded,
          size: DanaviewButtonSize.lg,
          expand: true,
          onPressed: _start,
        ),
    };
  }

  Widget _detailsColumn() {
    final update = _update;
    final result = _result;
    final running = _status == _TestStatus.running;
    final phase = update?.phase;
    final download = result?.downloadMbps ?? update?.downloadMbps;
    final upload = result?.uploadMbps ?? update?.uploadMbps;
    final latency = result?.latencyMs ?? update?.latencyMs;
    final jitter = result?.jitterMs ?? update?.jitterMs;
    final latencyDone = latency != null && (!running || (phase != null && phase != SpeedTestPhase.latency));

    String mbps(double? done, SpeedTestPhase measuring) {
      if (done != null) return formatMbps(done);
      if (running && phase == measuring) return formatMbps(update!.currentMbps);
      return '–';
    }

    final metrics = [
      _Metric(
        label: 'Download',
        icon: Icons.download_rounded,
        color: DanaviewColors.cyan,
        value: mbps(download, SpeedTestPhase.download),
        unit: 'Mbps',
        measured: download != null,
      ),
      _Metric(
        label: 'Upload',
        icon: Icons.upload_rounded,
        color: DanaviewColors.purple,
        value: mbps(upload, SpeedTestPhase.upload),
        unit: 'Mbps',
        measured: upload != null,
      ),
      _Metric(
        label: 'Ping',
        icon: Icons.timer_rounded,
        color: DanaviewColors.primaryLight,
        value: latency == null ? '–' : formatMsValue(latency),
        unit: 'ms',
        measured: latencyDone,
      ),
      _Metric(
        label: 'Jitter',
        icon: Icons.waves_rounded,
        color: DanaviewColors.warning,
        value: jitter == null ? '–' : formatMsValue(jitter),
        unit: 'ms',
        measured: latencyDone,
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_status == _TestStatus.idle) ...[
          _dataNotice(),
          const SizedBox(height: DanaviewSpacing.lg),
        ],
        if (_status == _TestStatus.failed) ...[
          DanaviewInlineEmpty(
            icon: Icons.wifi_off_rounded,
            iconColor: DanaviewColors.errorLight,
            title: "The test didn't finish",
            message: _error,
          ),
          const SizedBox(height: DanaviewSpacing.lg),
        ],
        _MetricGrid(metrics: metrics),
        if (result != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, DanaviewSpacing.sm, 4, 0),
            child: Text(
              'Used ${formatDataSize(result.bytesTransferred)} of data in ${formatStreamDuration(result.duration)}.',
              style: DanaviewTextStyles.caption,
            ),
          ),
        if (!running && download != null)
          _VideoVerdict(downloadMbps: download, uploadMbps: upload, latencyMs: latency, jitterMs: jitter),
      ],
    );
  }

  Widget _dataNotice() {
    final config = ref.read(speedTestServiceProvider).config;
    final seconds = (config.downloadDuration + config.uploadDuration).inSeconds + 2;
    final roughSeconds = math.max(5, (seconds / 5).round() * 5);
    return DanaviewInlineEmpty(
      icon: Icons.data_usage_rounded,
      iconColor: DanaviewColors.warning,
      title: 'Uses up to ${formatDataSize(config.maxTotalBytes)} of data',
      message: 'The test downloads and uploads data for about $roughSeconds seconds; fast connections '
          'finish sooner. On mobile data, this counts toward your plan. '
          "It runs against Cloudflare's speed test servers.",
    );
  }
}

/// Ping, download and upload as three bars that fill as each phase runs.
class _PhaseSteps extends StatelessWidget {
  const _PhaseSteps({required this.update, required this.running});

  final SpeedTestUpdate? update;
  final bool running;

  @override
  Widget build(BuildContext context) {
    const steps = [
      (SpeedTestPhase.latency, 'Ping', DanaviewColors.primaryLight),
      (SpeedTestPhase.download, 'Download', DanaviewColors.cyan),
      (SpeedTestPhase.upload, 'Upload', DanaviewColors.purple),
    ];
    final current = update?.phase;
    return Row(
      children: [
        for (var i = 0; i < steps.length; i++) ...[
          if (i > 0) const SizedBox(width: DanaviewSpacing.sm),
          Expanded(child: _step(steps[i].$1, steps[i].$2, steps[i].$3, current)),
        ],
      ],
    );
  }

  Widget _step(SpeedTestPhase phase, String label, Color color, SpeedTestPhase? current) {
    final double fill;
    if (current == null) {
      fill = 0;
    } else if (current.index > phase.index) {
      fill = 1;
    } else if (current == phase) {
      fill = update!.phaseProgress;
    } else {
      fill = 0;
    }
    final active = running && current == phase;
    final radius = BorderRadius.circular(2);
    return Column(
      children: [
        Container(
          height: 4,
          decoration: BoxDecoration(color: DanaviewColors.trackBackground, borderRadius: radius),
          alignment: AlignmentDirectional.centerStart,
          child: FractionallySizedBox(
            widthFactor: fill.clamp(0.0, 1.0),
            heightFactor: 1,
            child: DecoratedBox(decoration: BoxDecoration(color: color, borderRadius: radius)),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: DanaviewTextStyles.micro.copyWith(
            color: active ? DanaviewColors.textPrimary : (fill >= 1 ? DanaviewColors.textSecondary : DanaviewColors.textMuted),
            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class _Metric {
  const _Metric({
    required this.label,
    required this.icon,
    required this.color,
    required this.value,
    required this.unit,
    required this.measured,
  });

  final String label;
  final IconData icon;
  final Color color;
  final String value;
  final String unit;

  /// Measured, rather than a live or missing reading.
  final bool measured;
}

/// Four columns when wide, two on a phone, and plain rows when even two would squeeze the numbers.
class _MetricGrid extends StatelessWidget {
  const _MetricGrid({required this.metrics});

  final List<_Metric> metrics;

  static const _gap = 10.0;
  static const _minTileWidth = 140.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
        final width = constraints.maxWidth;
        final minTile = _minTileWidth * scale;
        if (width < 2 * minTile + _gap) {
          return DanaviewLibraryGroup(children: [for (final metric in metrics) _MetricRow(metric: metric)]);
        }
        final columns = width >= 4 * minTile + 3 * _gap ? 4 : 2;
        return Column(
          children: [
            for (var start = 0; start < metrics.length; start += columns) ...[
              if (start > 0) const SizedBox(height: _gap),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = start; i < start + columns && i < metrics.length; i++) ...[
                      if (i > start) const SizedBox(width: _gap),
                      Expanded(child: _MetricTile(metric: metrics[i])),
                    ],
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

class _MetricTile extends StatelessWidget {
  const _MetricTile({required this.metric});

  final _Metric metric;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '${metric.label}: ${metric.value} ${metric.unit}',
      excludeSemantics: true,
      child: DanaviewSurface(
        color: DanaviewColors.surface,
        padding: const EdgeInsets.all(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                DanaviewTileIcon(metric.icon, color: metric.color, size: 28),
                const SizedBox(width: DanaviewSpacing.sm),
                Expanded(
                  child: Text(
                    metric.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DanaviewTextStyles.caption.copyWith(color: DanaviewColors.textSecondary),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: _MetricValue(metric: metric, fontSize: 26),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A metric as a list row, for widths too narrow for tiles side by side.
class _MetricRow extends StatelessWidget {
  const _MetricRow({required this.metric});

  final _Metric metric;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '${metric.label}: ${metric.value} ${metric.unit}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            DanaviewTileIcon(metric.icon, color: metric.color, size: 40),
            const SizedBox(width: DanaviewSpacing.md),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    metric.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DanaviewTextStyles.caption.copyWith(color: DanaviewColors.textSecondary),
                  ),
                  const SizedBox(height: 2),
                  SizedBox(
                    width: double.infinity,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerStart,
                      child: _MetricValue(metric: metric, fontSize: 22),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricValue extends StatelessWidget {
  const _MetricValue({required this.metric, required this.fontSize});

  final _Metric metric;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          metric.value,
          maxLines: 1,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.6,
            color: metric.measured ? DanaviewColors.textPrimary : DanaviewColors.textSecondary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 4),
        Text(metric.unit, maxLines: 1, style: DanaviewTextStyles.caption),
      ],
    );
  }
}

typedef _Need = ({String title, double mbps});

/// Plain-language reading of a result for watching, calling and uploading video.
class _VideoVerdict extends StatelessWidget {
  const _VideoVerdict({
    required this.downloadMbps,
    required this.uploadMbps,
    required this.latencyMs,
    required this.jitterMs,
  });

  final double downloadMbps;
  final double? uploadMbps;
  final double? latencyMs;
  final double? jitterMs;

  /// Typical bitrates streaming services ask for.
  static const List<_Need> _streaming = [
    (title: '4K Ultra HD', mbps: 25),
    (title: 'Full HD 1080p', mbps: 8),
    (title: 'HD 720p', mbps: 5),
    (title: 'SD 480p', mbps: 3),
  ];

  ({String title, String message, IconData icon, Color color}) get _headline {
    final d = downloadMbps;
    if (d >= 25) {
      return (
        title: 'Great for 4K streaming',
        message: 'Ultra HD video should play without buffering.',
        icon: Icons.four_k_rounded,
        color: DanaviewColors.success,
      );
    }
    if (d >= 8) {
      return (
        title: 'Good for Full HD',
        message: 'Full HD 1080p plays smoothly; 4K may buffer.',
        icon: Icons.hd_rounded,
        color: DanaviewColors.success,
      );
    }
    if (d >= 5) {
      return (
        title: 'Fine for HD 720p',
        message: 'HD plays smoothly; Full HD may pause to buffer at times.',
        icon: Icons.hd_rounded,
        color: DanaviewColors.primaryLight,
      );
    }
    if (d >= 3) {
      return (
        title: 'Good enough for SD',
        message: 'Expect standard definition; higher qualities may buffer.',
        icon: Icons.sd_rounded,
        color: DanaviewColors.warning,
      );
    }
    return (
      title: 'Too slow for smooth streaming',
      message: 'Even SD video may pause to buffer. Try moving closer to your router or switching networks.',
      icon: Icons.signal_cellular_alt_rounded,
      color: DanaviewColors.errorLight,
    );
  }

  @override
  Widget build(BuildContext context) {
    final headline = _headline;
    final upload = uploadMbps;
    final latency = latencyMs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const DanaviewLibrarySectionHeader('What this means for video', topSpacing: 24),
        DanaviewSurface(
          color: DanaviewColors.surface,
          padding: const EdgeInsets.all(DanaviewSpacing.lg),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DanaviewTileIcon(headline.icon, color: headline.color, size: 40),
              const SizedBox(width: DanaviewSpacing.md),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 2),
                    Text(headline.title, style: DanaviewTextStyles.headline),
                    const SizedBox(height: 4),
                    Text(headline.message, style: DanaviewTextStyles.caption.copyWith(fontSize: 13, height: 1.35)),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: DanaviewSpacing.sm),
        DanaviewLibraryGroup(
          children: [
            for (final need in _streaming)
              _verdictRow(
                ok: downloadMbps >= need.mbps,
                title: need.title,
                subtitle: '${downloadMbps >= need.mbps ? 'Smooth' : 'May buffer'} · '
                    'needs ${need.mbps.toStringAsFixed(0)}\u00A0Mbps',
              ),
          ],
        ),
        if (upload != null || latency != null) ...[
          const DanaviewLibrarySectionHeader('Calls and uploads', topSpacing: 20),
          DanaviewLibraryGroup(
            children: [
              if (upload != null) ...[
                _verdictRow(
                  ok: upload >= 3,
                  title: 'HD video calls',
                  subtitle: upload >= 3 ? 'Your video should look sharp' : 'Your video may look blurry or freeze',
                ),
                _verdictRow(
                  ok: upload >= 6,
                  title: 'Going live in 1080p',
                  subtitle: upload >= 6 ? 'Fast enough for a steady stream' : 'Too slow for a steady 1080p stream',
                ),
                _verdictRow(
                  ok: upload >= 10,
                  title: 'Uploading videos',
                  subtitle: 'A 1\u00A0GB video takes about ${_uploadTime(upload)}',
                ),
              ],
              if (latency != null) _latencyRow(latency, jitterMs ?? 0),
            ],
          ),
        ],
      ],
    );
  }

  Widget _latencyRow(double latency, double jitter) {
    if (jitter > 30) {
      return _verdictRow(
        ok: false,
        title: 'Live streams and calls',
        subtitle: 'Unsteady connection · ${formatMs(jitter)} jitter',
      );
    }
    final ok = latency <= 100;
    return _verdictRow(
      ok: ok,
      title: 'Live streams and calls',
      subtitle: '${ok ? 'Responsive' : 'Noticeable delay'} · ${formatMs(latency)} ping',
    );
  }

  /// 1 GB is 8,000 megabits, in the same decimal units as Mbps.
  static String _uploadTime(double mbps) {
    if (mbps <= 0) return 'a very long time';
    final seconds = (8000 / mbps).round();
    if (seconds < 60) return '$seconds\u00A0s';
    final minutes = (seconds / 60).round();
    if (minutes < 120) return '$minutes\u00A0min';
    return '${(minutes / 60).round()}\u00A0h';
  }

  Widget _verdictRow({required bool ok, required String title, required String subtitle}) {
    return DanaviewLibraryRow(
      leading: DanaviewTileIcon(
        ok ? Icons.check_circle_rounded : Icons.error_rounded,
        color: ok ? DanaviewColors.success : DanaviewColors.warning,
        size: 40,
      ),
      title: title,
      subtitle: subtitle,
      subtitleMaxLines: 2,
    );
  }
}
