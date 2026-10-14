// OWNER: UX-33
//
// Copy of the audio panel and the audio actions (ux.md §10.4): volume, mute, fades, keep pitch,
// the lane's audio role, Extract audio and Add music. Plain, specific and with a next step where
// one exists (ARCH §19).

import 'dart:math' as math;

import 'package:danaview_editor_core/model.dart' show AudioRole;

/// Copy of the audio panel (ux.md §10.4).
abstract final class AudioStrings {
  // ---- Rows ----------------------------------------------------------------------------------

  /// Volume row.
  static const String volume = 'Volume';

  /// Mute row.
  static const String mute = 'Mute';

  /// Mute row subtitle.
  static const String muteHint = 'Silences this clip only';

  /// Fades heading.
  static const String fadesHeading = 'Fades';

  /// Fade-in row.
  static const String fadeIn = 'Fade in';

  /// Fade-out row.
  static const String fadeOut = 'Fade out';

  /// Under the fades: the longest fade this clip allows ("Up to 2.5 s on this clip").
  static String fadeLimit(double seconds) => 'Up to ${_seconds(seconds)} on this clip';

  /// Keep pitch row.
  static const String keepPitch = 'Keep pitch';

  /// Keep pitch subtitle.
  static const String keepPitchHint = 'Voices sound natural when the speed changes';

  /// Role heading.
  static const String roleHeading = 'Lane role';

  /// Under the role chips.
  static const String roleHint = 'Applies to every clip on this lane';

  /// The name of [role].
  static String roleName(AudioRole role) => switch (role) {
        AudioRole.original => 'Original',
        AudioRole.voice => 'Voice',
        AudioRole.music => 'Music',
        AudioRole.effects => 'Effects',
      };

  /// The volume readout in decibels ("+6.0 dB", "0.0 dB", "−∞ dB").
  static String decibels(double gain) {
    if (gain <= 0.0001) return '−∞ dB';
    final db = 20 * math.log(gain) / math.ln10;
    final rounded = (db * 10).roundToDouble() / 10;
    if (rounded == 0) return '0.0 dB';
    return rounded > 0 ? '+${rounded.toStringAsFixed(1)} dB' : '−${(-rounded).toStringAsFixed(1)} dB';
  }

  /// Semantics label of the readout.
  static String decibelsSemantics(double gain) => 'Volume level ${decibels(gain).replaceAll('−∞', 'minus infinity').replaceAll('−', 'minus ')}';

  // ---- Extract audio -------------------------------------------------------------------------

  /// Extract audio button.
  static const String extract = 'Extract audio';

  /// Explanation under the button.
  static const String extractHint = 'Moves the sound to its own clip on an audio lane. The video stays as it is and both stay in sync.';

  /// After extracting.
  static const String extracted = 'Audio extracted to its own clip';

  /// A video whose audio was already extracted.
  static const String alreadyExtracted = "This clip's audio is on its own clip. Edit it there.";

  /// Selects the extracted audio clip.
  static const String selectExtracted = 'Select audio clip';

  // ---- Add music -----------------------------------------------------------------------------

  /// Title of the import sheet of Add music.
  static const String importTitle = 'Add music';

  /// Announcement after music was placed.
  static const String musicAdded = 'Music added at the playhead';

  /// The picker failed.
  static const String pickerFailed = "Couldn't open your files. Try again.";

  // ---- States and reasons --------------------------------------------------------------------

  /// The clip is gone (deleted while the panel was open).
  static const String clipGone = 'This clip is no longer in the project.';

  /// Note on a locked lane.
  static const String trackLocked = 'This lane is locked. Unlock it to change the audio.';

  /// Reason: the project does not accept edits.
  static const String notEditable = 'The project is still opening.';

  /// Reason: the project was opened read-only.
  static const String readOnly = 'This project is open read-only, so music can’t be added.';

  /// Reason: no clip with sound is selected.
  static const String selectClip = 'Select a clip with sound first.';

  /// Reason: the selected clip is on a locked lane.
  static const String actionTrackLocked = 'The selected clip is on a locked lane.';

  /// Reason: extract needs a video clip.
  static const String extractNeedsVideo = 'Select a video clip with sound first.';

  /// Reason: the video has no sound.
  static const String extractNoAudio = 'This video has no sound to extract.';

  /// Reason: the audio was already extracted.
  static const String extractDone = "This clip's audio is already on its own clip.";

  // ---- History -------------------------------------------------------------------------------

  /// History label of the header reset.
  static const String historyReset = 'Reset audio';

  /// History label of the keep pitch switch.
  static const String historyKeepPitch = 'Keep pitch';

  /// History label of a fade change.
  static const String historyFade = 'Change fade';

  static String _seconds(double s) {
    final text = s.toStringAsFixed(1);
    return '$text s';
  }
}
