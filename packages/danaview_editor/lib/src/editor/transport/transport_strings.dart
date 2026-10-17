// OWNER: UX-14
//
// Copy of the transport bar and the playback actions (ux.md §7.6, §7.7). One place, so the widget
// tests, tooltips and semantics labels use the same strings.

/// Copy of the transport bar.
abstract final class TransportStrings {
  /// Play button label and tooltip.
  static const String play = 'Play';

  /// Pause button label and tooltip.
  static const String pause = 'Pause';

  /// Frame back button.
  static const String previousFrame = 'Previous frame';

  /// Frame forward button.
  static const String nextFrame = 'Next frame';

  /// Previous edit point button.
  static const String previousEdit = 'Previous edit point';

  /// Next edit point button.
  static const String nextEdit = 'Next edit point';

  /// Add marker button.
  static const String addMarker = 'Add marker';

  /// Snapping toggle.
  static const String snapping = 'Snapping';

  /// Ripple toggle.
  static const String ripple = 'Ripple editing';

  /// Zoom out button.
  static const String zoomOut = 'Zoom out';

  /// Zoom in button.
  static const String zoomIn = 'Zoom in';

  /// Fullscreen button.
  static const String fullscreen = 'Fullscreen preview';

  /// Preview quality menu button.
  static const String quality = 'Preview quality';

  /// "More" menu button.
  static const String more = 'More';

  /// Semantics label of the time readout.
  static const String time = 'Playhead position';

  /// Semantics hint of the time readout.
  static const String timeHint = 'Opens time entry';

  /// Semantics value of the time readout ("00:12:15 of 01:30:00").
  static String timeValue(String position, String duration) => '$position of $duration';

  // ---- Timecode entry ----------------------------------------------------------------------------

  /// Title of the time entry dialog.
  static const String entryTitle = 'Go to time';

  /// Hint of the time entry field.
  static const String entryHint = '1:23, 83.5s, +2s or -10f';

  /// Confirm button of the time entry dialog.
  static const String entryConfirm = 'Go';

  /// Validator message of the time entry dialog.
  static const String entryInvalid = 'Use minutes:seconds or seconds, like 1:23 or 83.5s';

  // ---- Quality menu ------------------------------------------------------------------------------

  /// Auto quality.
  static const String qualityAuto = 'Auto';

  /// Full quality.
  static const String qualityFull = 'Full';

  /// Half quality.
  static const String qualityHalf = 'Half';

  /// Quarter quality.
  static const String qualityQuarter = 'Quarter';

  /// Proxy toggle.
  static const String useProxies = 'Use optimized media (proxies)';

  /// Footer of the quality menu.
  static const String qualityNote = 'Only affects the preview. Exports always use full quality and original media.';

  // ---- Action reasons ----------------------------------------------------------------------------

  /// Playback needs the preview.
  static const String noPreview = 'The preview isn\'t running';

  /// Playback needs content.
  static const String emptyProject = 'Add a clip to play';

  /// Seeking needs an open project.
  static const String notOpen = 'The project is still opening';
}
