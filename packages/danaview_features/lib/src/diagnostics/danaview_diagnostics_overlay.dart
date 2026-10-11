import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import '../controllers/providers.dart';
import '../player/danaview_player_actions.dart';

/// "Stats for Nerds" card; a direct child of the player's Stack, pinned top-left inside [padding].
class DanaviewDiagnosticsOverlay extends ConsumerWidget {
  final VoidCallback onClose;

  /// Space to keep clear around the card (safe area plus the player's top bar).
  final EdgeInsets padding;

  const DanaviewDiagnosticsOverlay({super.key, required this.onClose, this.padding = EdgeInsets.zero});

  static const double _maxWidth = 320;
  static const String _unknown = '—';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(playerControllerProvider);
    final stats = state.stats;

    final rows = <(String, String)>[
      ('Resolution', stats.resolution ?? _unknown),
      ('FPS', '${stats.fps.toStringAsFixed(2)} / est ${stats.estimatedFps.toStringAsFixed(2)}'),
      ('Video codec', stats.videoCodec ?? _unknown),
      ('Audio codec', stats.audioCodec ?? _unknown),
      ('HW decode', stats.hwdec ?? _unknown),
      ('Dropped frames', '${stats.droppedFrames} / ${stats.voDelayedFrames} delayed'),
      ('A/V desync', '${(stats.avDesync * 1000).toStringAsFixed(1)} ms'),
      ('Video bitrate', '${stats.videoBitrate.toStringAsFixed(1)} kbps'),
      ('Audio channels', stats.audioChannels ?? _unknown),
      ('Color space', stats.colorSpace ?? _unknown),
    ];

    void copyReport() {
      final report = StringBuffer('--- Danaview Diagnostics ---\n');
      for (final (label, value) in rows) {
        report.writeln('$label: $value');
      }
      report
        ..writeln('Media: ${state.currentSource?.uri ?? _unknown}')
        ..write('--------------------------------');
      Clipboard.setData(ClipboardData(text: report.toString()));
      showPlayerToast(context, 'Diagnostics copied to clipboard', kind: DanaviewToastKind.success);
    }

    return Positioned.fill(
      child: Padding(
        padding: padding + const EdgeInsets.all(12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Align(
              alignment: AlignmentDirectional.topStart,
              child: DanaviewSurface(
                shadow: DanaviewShadow.subtle,
                constraints: BoxConstraints(
                  maxWidth: math.min(_maxWidth, constraints.maxWidth),
                  maxHeight: constraints.maxHeight,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
                      child: Row(
                        children: [
                          const Icon(Icons.query_stats_rounded, size: 18, color: DanaviewColors.primaryLight),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              'Stats for Nerds',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: DanaviewTextStyles.headline,
                            ),
                          ),
                          DanaviewIconButton(
                            icon: Icons.close_rounded,
                            size: 32,
                            iconSize: 18,
                            tooltip: 'Close',
                            semanticLabel: 'Close stats',
                            onPressed: onClose,
                          ),
                        ],
                      ),
                    ),
                    Container(height: DanaviewBorders.width, color: DanaviewColors.hairline),
                    Flexible(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final (label, value) in rows) _StatRow(label: label, value: value),
                            const SizedBox(height: 12),
                            DanaviewButton.secondary(
                              label: 'Copy report',
                              icon: Icons.copy_rounded,
                              size: DanaviewButtonSize.sm,
                              expand: true,
                              onPressed: copyReport,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: DanaviewTextStyles.caption),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: DanaviewColors.textPrimary,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
