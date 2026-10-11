// OWNER: UX-25
//
// Copy of the speed panel, the speed curve editor and the speed action (ux.md §10.3, D-15): plain,
// specific and with a next step where one exists (ARCH §19). Spoken labels name the point and what
// a gesture does, so a screen reader user can do everything the curve gestures do.

import 'package:vwish_editor_core/ops.dart' show SpeedRampPresets;

/// Copy of the speed panel (ux.md §10.3).
abstract final class SpeedStrings {
  // ---- Modes and presets ---------------------------------------------------------------------

  /// Segment: one speed for the whole clip.
  static const String modeConstant = 'Constant';

  /// Segment: speed ramping.
  static const String modeCurve = 'Curve';

  /// Semantics label of the mode control.
  static const String modeLabel = 'Speed mode';

  /// Label of the custom speed field.
  static const String customSpeed = 'Custom';

  /// Semantics label of the custom speed field.
  static const String customSpeedSemantics = 'Custom speed';

  /// Heading of the ramp presets.
  static const String presetsHeading = 'Presets';

  /// Heading of the curve.
  static const String curveHeading = 'Speed curve';

  /// The chip of a curve that matches no preset.
  static const String presetCustom = 'Custom';

  /// The name of the ramp preset [id] ("Jump cut"), or null for an unknown id.
  static String? presetName(String id) => switch (id) {
        SpeedRampPresets.montage => 'Montage',
        SpeedRampPresets.hero => 'Hero',
        SpeedRampPresets.bullet => 'Bullet',
        SpeedRampPresets.jumpCut => 'Jump cut',
        SpeedRampPresets.flashIn => 'Flash in',
        SpeedRampPresets.flashOut => 'Flash out',
        _ => null,
      };

  /// [rate] as shown ("0.25×", "1×", "2.5×").
  static String rate(double rate) {
    var text = rate.toStringAsFixed(2);
    if (text.contains('.')) {
      text = text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    }
    return '$text×';
  }

  // ---- Result --------------------------------------------------------------------------------

  /// The duration readout: the clip's length at normal speed and its length now.
  static String durationRow(String from, String to) => 'Duration $from → $to';

  /// Semantics label of the duration readout.
  static String durationSemantics(String from, String to) => 'Duration, $from at normal speed, $to now';

  /// Switch: keep the audio pitch.
  static const String keepPitch = 'Keep audio pitch';

  /// Hint under the keep pitch switch.
  static const String keepPitchHint = 'Stretches the sound instead of making it higher or lower.';

  /// Capability note of a constant speed above what the device plays audio at.
  static String audioMutedAbove(double maxAudioSpeed) => 'Audio is muted above ${rate(maxAudioSpeed)} on this device';

  /// Capability note of a curve that goes above what the device plays audio at.
  static String audioMutedWhere(double maxAudioSpeed) =>
      'Audio is muted where the speed is above ${rate(maxAudioSpeed)} on this device';

  // ---- Entry points (UX-35 actions) ---------------------------------------------------------

  /// Reverse button.
  static const String reverse = 'Reverse';

  /// Reverse button while the clip plays backwards.
  static const String reversed = 'Reversed';

  /// Freeze frame button.
  static const String freeze = 'Freeze frame';

  /// Shown when the clip's media or the action is not available.
  static const String actionUnavailable = 'Not available yet';

  // ---- Curve editor --------------------------------------------------------------------------

  /// Semantics label of the whole curve ("Speed curve, 5 points").
  static String curveSemantics(int points) => 'Speed curve, $points points';

  /// Semantics hint of the whole curve.
  static const String curveHint = 'Double tap the curve to add a point. Touch and hold a point to delete it.';

  /// Visible hint under the curve.
  static const String curveGestures = 'Double-tap the curve to add a point. Touch and hold a point to delete it.';

  /// Semantics label of a point ("Point 2 of 5").
  static String pointLabel(int index, int count) => 'Point ${index + 1} of $count';

  /// Semantics value of a point: its speed and where it sits in the clip.
  static String pointValue(double speed, double position) => '${rate(speed)}, at ${(position * 100).round()}% of the clip';

  /// Semantics action: move a point earlier.
  static const String moveEarlier = 'Move earlier';

  /// Semantics action: move a point later.
  static const String moveLater = 'Move later';

  /// Semantics action and button: delete the selected point.
  static const String deletePoint = 'Delete point';

  /// Button: add a point.
  static const String addPoint = 'Add point';

  /// Field: speed of the selected point.
  static const String pointSpeed = 'Point speed';

  /// Field: position of the selected point.
  static const String pointPosition = 'Point position';

  /// Heading of the selected point's fields ("Point 2 of 5").
  static String selectedPoint(int index, int count) => 'Selected: point ${index + 1} of $count';

  /// The announcement after a point was added.
  static String pointAdded(int count) => 'Point added, $count points';

  /// The announcement after a point was deleted.
  static String pointDeleted(int count) => 'Point deleted, $count points';

  /// Shown when the curve cannot take another point.
  static const String curveFull = 'The curve has the most points it can have';

  // ---- States --------------------------------------------------------------------------------

  /// The clip is no longer on the timeline.
  static const String clipGone = 'This clip is no longer on the timeline';

  /// The track of the clip is locked.
  static const String trackLocked = 'This track is locked. Unlock it to change the speed.';

  /// Select a clip first (the Speed action).
  static const String selectClip = 'Select a video or audio clip to change its speed';

  /// The project is not open for editing (the Speed action).
  static const String notEditable = 'The project is still opening';

  /// The track of the selected clip is locked (the Speed action).
  static const String actionTrackLocked = 'This track is locked';
}
