// OWNER: UX-34
//
// Copy of the voiceover panel and the Record voiceover action (ux.md §10.5): the microphone
// explanation, the denied state, the countdown, recording, finishing, interruptions and failures.
// Plain, specific and with a next step where one exists (ARCH §19, ux.md §18).

import 'package:danaview_editor_core/model.dart' show TimeUs, microsPerSecond;

/// Copy of the voiceover panel (ux.md §10.5).
abstract final class VoiceoverStrings {
  // ---- Permission ----------------------------------------------------------------------------

  /// Explanation heading (before the OS prompt).
  static const String explainTitle = 'Record with your microphone';

  /// Explanation shown before the OS prompt (ux.md §10.5).
  static const String explainBody =
      'Danaview uses the microphone only while you record. Recordings stay in this project on your device.';

  /// Continues to the OS prompt.
  static const String explainContinue = 'Continue';

  /// Leaves the explanation without asking.
  static const String explainNotNow = 'Not now';

  /// Microphone access is off (ux.md §18 `PermissionDenied(microphone)`).
  static const String denied = 'Microphone access is off. Turn it on in Settings to record a voiceover.';

  /// Opens the app's system settings.
  static const String openSettings = 'Open Settings';

  /// Asks for the permission again (Android, not permanently denied).
  static const String tryAgain = 'Try again';

  // ---- Idle ----------------------------------------------------------------------------------

  /// Record button (semantics and tooltip).
  static const String record = 'Start recording';

  /// Stop button (semantics and tooltip).
  static const String stop = 'Stop recording';

  /// Under the record button: where the recording starts ("Records from 0:05").
  static String recordsFrom(TimeUs t) => 'Records from ${clock(t)}';

  /// Play project switch.
  static const String playProject = 'Play project while recording';

  /// Play project switch subtitle.
  static const String playProjectHint = 'Project sound is muted so it isn\'t recorded';

  /// The project is open read-only or not ready.
  static const String notEditable = 'This project can\'t be edited right now.';

  /// The project is open read-only.
  static const String readOnly = 'This project is open read-only.';

  /// The device has no voice recorder.
  static const String unavailable = 'Recording a voiceover isn\'t available on this device.';

  // ---- Countdown -----------------------------------------------------------------------------

  /// Countdown semantics ("Recording starts in 3").
  static String countdown(int n) => 'Recording starts in $n';

  /// Skips the countdown.
  static const String skip = 'Start now';

  /// Cancels the countdown or the recording.
  static const String cancel = 'Cancel';

  // ---- Recording -----------------------------------------------------------------------------

  /// Recording state label.
  static const String recording = 'Recording';

  /// Elapsed time semantics ("Recording, 0:12").
  static String elapsedSemantics(TimeUs t) => 'Recording, ${clock(t)}';

  /// Level meter semantics.
  static const String level = 'Microphone level';

  /// Under the stop button.
  static const String stopHint = 'Stop to add the recording to the timeline. Cancel discards it.';

  /// Finishing.
  static const String finishing = 'Adding the recording…';

  // ---- Results -------------------------------------------------------------------------------

  /// History label of the inserted clip.
  static const String history = 'Record voiceover';

  /// Announced after the clip was added.
  static String added(TimeUs duration) => 'Voiceover added. ${clock(duration)} recorded.';

  /// Interruption toast (ux.md §10.5: "Recording stopped. 0:12 saved.").
  static String interrupted(TimeUs duration) => 'Recording stopped. ${clock(duration)} saved.';

  /// Cancelled (announced).
  static const String discarded = 'Recording discarded.';

  /// The recorder could not start.
  static const String startFailed = 'Recording couldn\'t start. Check that no other app is using the microphone and try again.';

  /// The recording could not be finished or added.
  static const String saveFailed = 'The recording couldn\'t be added to the project. Try again.';

  /// Not enough space for the recording.
  static const String diskFull = 'Not enough storage to keep the recording. Free some space and try again.';

  /// Bin name of the [n]-th recording of a project ("Voiceover 2.wav").
  static String displayName(int n) => 'Voiceover $n.wav';

  // ---- Action --------------------------------------------------------------------------------

  /// Disabled action reason.
  static const String actionUnavailable = unavailable;

  // ---- Formatting ----------------------------------------------------------------------------

  /// "m:ss" (or "h:mm:ss") of [t], rounded down to the second.
  static String clock(TimeUs t) {
    final total = (t < 0 ? 0 : t) ~/ microsPerSecond;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final sec = (total % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$sec' : '$m:$sec';
  }
}
