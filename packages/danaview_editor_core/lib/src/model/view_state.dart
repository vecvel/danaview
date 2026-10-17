// OWNER: CORE-03
//
// Persisted, non-history editor view state (ARCH §6.1). Changing it bumps `docRevision` only.

import 'package:meta/meta.dart';

import '../time/time.dart';

/// How the timeline follows the playhead.
enum PlayheadFollowMode {
  /// The playhead stays centred and scrolling scrubs (touch default).
  centreLocked,

  /// The playhead moves; the view scrolls by itself (pointer default).
  free,
}

/// Editor view state saved with the project (never in undo history).
@immutable
final class ViewState {
  /// Creates view state.
  const ViewState({
    this.playhead = 0,
    this.pixelsPerSecond = 0,
    this.scrollTimeUs = 0,
    this.scrollLanePx = 0,
    this.rippleEnabled = true,
    this.snappingEnabled = true,
    this.followMode,
    this.lastExportPresetId,
  });

  /// Default view (zoom 0 = "fit whole project" on first layout).
  static const ViewState initial = ViewState();

  /// Playhead (on grid).
  final TimeUs playhead;

  /// Timeline zoom in logical px per second; 0 = fit on next layout.
  final double pixelsPerSecond;

  /// Time at the left edge of the timeline viewport.
  final TimeUs scrollTimeUs;

  /// Vertical scroll of the lanes, in logical px.
  final double scrollLanePx;

  /// Ripple toggle (R).
  final bool rippleEnabled;

  /// Snapping toggle (N).
  final bool snappingEnabled;

  /// Explicit follow mode; null = device default.
  final PlayheadFollowMode? followMode;

  /// Last export preset used in this project, if any.
  final String? lastExportPresetId;

  /// A copy with the given fields replaced.
  ViewState copyWith({
    TimeUs? playhead,
    double? pixelsPerSecond,
    TimeUs? scrollTimeUs,
    double? scrollLanePx,
    bool? rippleEnabled,
    bool? snappingEnabled,
    PlayheadFollowMode? followMode,
    String? lastExportPresetId,
  }) =>
      ViewState(
        playhead: playhead ?? this.playhead,
        pixelsPerSecond: pixelsPerSecond ?? this.pixelsPerSecond,
        scrollTimeUs: scrollTimeUs ?? this.scrollTimeUs,
        scrollLanePx: scrollLanePx ?? this.scrollLanePx,
        rippleEnabled: rippleEnabled ?? this.rippleEnabled,
        snappingEnabled: snappingEnabled ?? this.snappingEnabled,
        followMode: followMode ?? this.followMode,
        lastExportPresetId: lastExportPresetId ?? this.lastExportPresetId,
      );

  @override
  bool operator ==(Object other) =>
      other is ViewState &&
      other.playhead == playhead &&
      other.pixelsPerSecond == pixelsPerSecond &&
      other.scrollTimeUs == scrollTimeUs &&
      other.scrollLanePx == scrollLanePx &&
      other.rippleEnabled == rippleEnabled &&
      other.snappingEnabled == snappingEnabled &&
      other.followMode == followMode &&
      other.lastExportPresetId == lastExportPresetId;

  @override
  int get hashCode => Object.hash(playhead, pixelsPerSecond, scrollTimeUs, scrollLanePx, rippleEnabled,
      snappingEnabled, followMode, lastExportPresetId);
}
