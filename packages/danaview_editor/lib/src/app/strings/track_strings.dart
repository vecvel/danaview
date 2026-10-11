// OWNER: UX-11
//
// Copy of the track headers, the track menu and the add-track sheet (ux.md §8.10, §8.3): plain,
// specific, with a next step where one exists (ARCH §19). Spoken labels name the track so a
// screen reader user hears which lane a control belongs to. No ids or paths appear in the text.

import 'package:danaview_editor_core/model.dart' show AudioRole, TrackKind;

/// Copy of the track headers and the track menu (ux.md §8.10).
abstract final class TrackStrings {
  // ---- Kinds and roles -----------------------------------------------------------------------

  /// Name of a lane kind ("Video").
  static String kindName(TrackKind kind) => switch (kind) {
        TrackKind.video => 'Video',
        TrackKind.overlay => 'Overlay',
        TrackKind.audio => 'Audio',
        TrackKind.text => 'Text',
        TrackKind.subtitle => 'Subtitles',
      };

  /// Lower-case lane kind for sentences ("video track").
  static String kindNoun(TrackKind kind) => switch (kind) {
        TrackKind.video => 'video track',
        TrackKind.overlay => 'overlay track',
        TrackKind.audio => 'audio track',
        TrackKind.text => 'text track',
        TrackKind.subtitle => 'subtitles track',
      };

  /// Name of an audio role.
  static String roleName(AudioRole role) => switch (role) {
        AudioRole.original => 'Original',
        AudioRole.voice => 'Voice',
        AudioRole.music => 'Music',
        AudioRole.effects => 'Effects',
      };

  // ---- Flags ---------------------------------------------------------------------------------

  /// Menu label: lock switch.
  static const String locked = 'Locked';

  /// Menu label: visibility switch (on = shown).
  static const String visible = 'Visible';

  /// Menu label: mute switch.
  static const String muted = 'Muted';

  /// Menu label: solo switch.
  static const String solo = 'Solo';

  /// Menu hint under Locked.
  static const String lockedHint = 'A locked track can’t be edited.';

  /// Menu hint under Solo.
  static const String soloHint = 'Only soloed tracks are heard.';

  /// Spoken label of the lock toggle ("Lock Music 1"; the toggled state says whether it is on).
  static String lockToggle(String name) => 'Lock $name';

  /// Spoken label of the visibility toggle.
  static String visibleToggle(String name) => 'Show $name';

  /// Spoken label of the mute toggle.
  static String muteToggle(String name) => 'Mute $name';

  /// Spoken label of the solo toggle.
  static String soloToggle(String name) => 'Solo $name';

  /// Tooltip of a flag toggle in its current state.
  static String lockTooltip(bool on) => on ? 'Unlock track' : 'Lock track';

  /// Tooltip of the visibility toggle in its current state (on = shown).
  static String visibleTooltip(bool shown) => shown ? 'Hide track' : 'Show track';

  /// Tooltip of the mute toggle in its current state.
  static String muteTooltip(bool on) => on ? 'Unmute track' : 'Mute track';

  /// Tooltip of the solo toggle in its current state.
  static String soloTooltip(bool on) => on ? 'Stop solo' : 'Solo track';

  /// Spoken summary of a header ("Music 1, audio track, locked, muted").
  static String headerLabel(String name, TrackKind kind, {bool isMain = false, bool locked = false, bool hidden = false, bool muted = false, bool solo = false}) {
    final parts = <String>[
      name,
      isMain ? 'main video track' : kindNoun(kind),
      if (locked) 'locked',
      if (hidden) 'hidden',
      if (muted) 'muted',
      if (solo) 'solo',
    ];
    return parts.join(', ');
  }

  /// Short label of the solo glyph and toggle.
  static const String soloGlyph = 'S';

  // ---- Menu ----------------------------------------------------------------------------------

  /// Menu title of a track.
  static String menuTitle(String name) => name;

  /// Row: the track name.
  static const String nameRow = 'Name';

  /// Rename dialog title.
  static const String renameTitle = 'Rename track';

  /// Rename dialog hint.
  static const String renameHint = 'Track name';

  /// Rename dialog message.
  static const String renameMessage = 'Leave it empty to use the default name.';

  /// Rename confirm button.
  static const String renameConfirm = 'Rename';

  /// Rename validation: too long.
  static const String nameTooLong = 'Use 60 characters or fewer.';

  /// Section: track height.
  static const String heightSection = 'Track height';

  /// Hint under the height choice.
  static const String heightHint = 'Applies to every track.';

  /// Height: compact.
  static const String heightCompact = 'Compact';

  /// Height: normal.
  static const String heightNormal = 'Normal';

  /// Height: large.
  static const String heightLarge = 'Large';

  /// Section: audio role.
  static const String roleSection = 'Audio role';

  /// Row: move the track up.
  static const String moveUp = 'Move up';

  /// Row: move the track down.
  static const String moveDown = 'Move down';

  /// Why a track can't move up (it is the first of its kind).
  static const String moveUpTop = 'Already the top track of its kind.';

  /// Why a track can't move down (it is the last of its kind).
  static const String moveDownBottom = 'Already the bottom track of its kind.';

  /// Why the main track can't move.
  static const String mainCantMove = 'The main track stays at the bottom.';

  /// Why an action is disabled on a locked track.
  static const String unlockFirst = 'Unlock the track first.';

  /// Section: add a track.
  static const String addSection = 'Add track';

  /// Row: add a track of [kind].
  static String addTrack(TrackKind kind) => switch (kind) {
        TrackKind.video => 'Add video track',
        TrackKind.overlay => 'Add overlay track',
        TrackKind.audio => 'Add audio track',
        TrackKind.text => 'Add text track',
        TrackKind.subtitle => 'Add subtitles track',
      };

  /// Hint of an add row: where the new track goes.
  static String addTrackHint(TrackKind kind) => switch (kind) {
        TrackKind.video => 'Above the other video tracks.',
        TrackKind.overlay => 'On top of the overlay tracks.',
        TrackKind.audio => 'Added as a Music track. You can change its role.',
        TrackKind.text => 'On top of the text tracks.',
        TrackKind.subtitle => 'On top of everything else.',
      };

  /// Add-track sheet title.
  static const String addSheetTitle = 'Add track';

  /// Row: select every clip on the track.
  static const String selectAll = 'Select all on track';

  /// Why select all is disabled (nothing to select).
  static const String selectAllEmpty = 'This track has no clips.';

  /// Section: subtitle tracks.
  static const String subtitlesSection = 'Subtitles';

  /// Row: caption style.
  static const String subtitleStyle = 'Style';

  /// Row: import SRT or VTT.
  static const String subtitleImport = 'Import SRT/VTT';

  /// Row: export SRT or VTT.
  static const String subtitleExport = 'Export SRT/VTT';

  /// Row: burn captions into the video.
  static const String burnIn = 'Burn into video';

  /// Hint under the burn-in switch.
  static const String burnInHint = 'The default for exports. You can change it in the export sheet.';

  /// Row: regenerate captions.
  static const String subtitleRegenerate = 'Regenerate captions';

  /// Row: delete the track.
  static const String delete = 'Delete track';

  /// Why the main track can't be deleted.
  static const String mainCantDelete = 'The main track can’t be deleted.';

  /// Delete confirmation title.
  static String deleteTitle(String name) => 'Delete $name?';

  /// Delete confirmation message for a track with [clips] clips.
  static String deleteMessage(int clips) =>
      clips == 1 ? 'Its clip is removed from the timeline. You can undo this.' : 'Its $clips clips are removed from the timeline. You can undo this.';

  /// Delete confirmation button.
  static const String deleteConfirm = 'Delete';

  /// Cancel button.
  static const String cancel = 'Cancel';

  /// Sheet semantics label.
  static String sheetLabel(String name) => 'Track menu, $name';

  /// Why track actions are disabled (read-only project or the editor is not open).
  static const String notEditable = 'The project can’t be edited right now.';

  /// Shown when the track disappeared while its menu was open.
  static const String trackGone = 'This track no longer exists.';
}
