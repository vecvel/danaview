// OWNER: UX-37
//
// Progress of the Auto captions flow (ai.md §11.3 "Downloading" and "Running", ux.md §12.2 steps
// 3 and 5): the resumable model download (received of total, rate, Cancel) and the job phases
// (preparing audio, loading the model, detecting the language, creating captions with percent and
// ETA, finishing up), the paused lines and a one-line partial preview (not a live region). Cancel
// stops the work and adds nothing; Hide closes the sheet and keeps the job running (Tasks sheet).

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:danaview_transcription/danaview_transcription.dart' show ModelDownloadProgress, PauseReason, TranscriptionPhase, TranscriptionProgress;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../../app/strings/captions_strings.dart';

/// Text styles of the Auto captions flow (Figtree only, ARCH §1.3).
abstract final class CaptionsText {
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
}

/// Download or job progress with Cancel (and Hide for a job).
class CaptionsProgressPanel extends StatelessWidget {
  /// Download progress.
  const CaptionsProgressPanel.download({
    super.key,
    required this.download,
    required this.onCancel,
    this.onHide,
    this.resumed = false,
  })  : progress = null,
        waitingForExport = false,
        _isDownload = true;

  /// Job progress.
  const CaptionsProgressPanel.job({
    super.key,
    required this.progress,
    required this.onCancel,
    required this.onHide,
    this.waitingForExport = false,
  })  : download = null,
        resumed = false,
        _isDownload = false;

  /// Download progress (download mode).
  final ModelDownloadProgress? download;

  /// Job progress (job mode).
  final TranscriptionProgress? progress;

  /// The download continues a partial file.
  final bool resumed;

  /// The job waits for an export.
  final bool waitingForExport;

  /// Cancel.
  final VoidCallback onCancel;

  /// Hide (job mode; closes the sheet, keeps running).
  final VoidCallback? onHide;

  final bool _isDownload;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: ValueKey(_isDownload ? 'captions-download' : 'captions-running'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_isDownload) ..._downloadRows() else ..._jobRows(),
        const SizedBox(height: DanaviewSpacing.lg),
        DanaviewButtonBar(
          children: [
            DanaviewButton.secondary(key: const ValueKey('captions-cancel'), label: CaptionsStrings.cancel, onPressed: onCancel),
            if (onHide != null) DanaviewButton.ghost(key: const ValueKey('captions-hide'), label: CaptionsStrings.hide, onPressed: onHide),
          ],
        ),
      ],
    );
  }

  List<Widget> _downloadRows() {
    final p = download;
    final fraction = p == null || p.total <= 0 ? null : p.received / p.total;
    return [
      Text(
        p == null ? (resumed ? CaptionsStrings.resumingDownload : CaptionsStrings.preparingDownload) : CaptionsStrings.downloadLine(p, resumed: resumed),
        key: const ValueKey('captions-download-line'),
        style: CaptionsText.body,
      ),
      const SizedBox(height: DanaviewSpacing.sm),
      DanaviewProgressBar(value: fraction, semanticLabel: CaptionsStrings.downloadingLabel),
      if (p != null && p.bytesPerSecond > 0) ...[
        const SizedBox(height: DanaviewSpacing.xs),
        Text(CaptionsStrings.rate(p.bytesPerSecond), style: CaptionsText.caption),
      ],
      const SizedBox(height: DanaviewSpacing.sm),
      Text(CaptionsStrings.downloadContinues, style: CaptionsText.secondary),
    ];
  }

  List<Widget> _jobRows() {
    final p = progress;
    final paused = p?.paused;
    final line = p == null ? CaptionsStrings.phaseLine(const TranscriptionProgress(phase: TranscriptionPhase.preparing, fraction: 0)) : CaptionsStrings.phaseLine(p);
    final partial = p?.partialText;
    return [
      Text(line, key: const ValueKey('captions-phase-line'), style: CaptionsText.body),
      if (waitingForExport || paused != null) ...[
        const SizedBox(height: DanaviewSpacing.xs),
        Row(
          key: const ValueKey('captions-paused'),
          children: [
            const Icon(Icons.pause_circle_outline_rounded, size: 16, color: DanaviewColors.warning),
            const SizedBox(width: DanaviewSpacing.xs),
            Expanded(
              child: Text(
                CaptionsStrings.pausedLine(paused ?? PauseReason.waitingForExport),
                style: CaptionsText.secondary,
              ),
            ),
          ],
        ),
      ],
      const SizedBox(height: DanaviewSpacing.sm),
      DanaviewProgressBar(
        key: const ValueKey('captions-progress-bar'),
        value: p?.fraction.clamp(0.0, 1.0),
        semanticFormatter: CaptionsStrings.spokenProgress,
      ),
      if (partial != null && partial.isNotEmpty) ...[
        const SizedBox(height: DanaviewSpacing.sm),
        // One line, ellipsized; excluded from semantics so screen readers are not flooded.
        ExcludeSemantics(
          child: Text(
            partial,
            key: const ValueKey('captions-partial'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: CaptionsText.secondary.copyWith(fontStyle: FontStyle.italic),
          ),
        ),
      ],
      const SizedBox(height: DanaviewSpacing.sm),
      Text(CaptionsStrings.keepsRunning, style: CaptionsText.caption.copyWith(color: DanaviewColors.textSecondary)),
    ];
  }
}
