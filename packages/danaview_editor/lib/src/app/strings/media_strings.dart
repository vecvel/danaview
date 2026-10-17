// OWNER: UX-36
//
// Copy of the media bin, its card actions and the drag and drop flows (ux.md §10.1, §15.3, D-18):
// filters, search, badges, usage counts, the add / overlay / replace / remove actions with the
// reasons they are unavailable, the media info sheet and the external drop messages. Plain,
// specific, with a next step where one exists (ARCH §19). No ids or paths appear in the text.

import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:danaview_editor_core/model.dart' show MediaKind;

/// Copy of the media panel and the drop flows.
abstract final class MediaStrings {
  // ---- Header ----------------------------------------------------------------------------------

  /// The photo-library picker button: `Photos` on iOS, `Gallery` elsewhere.
  static String photosButton(TargetPlatform platform) => platform == TargetPlatform.iOS ? 'Photos' : 'Gallery';

  /// The document picker button.
  static const String filesButton = 'Files';

  /// The "put the picks on the timeline" switch.
  static const String addToTimeline = 'Add to timeline';

  /// What the switch does.
  static const String addToTimelineHint = 'Place new media at the playhead as well as in the bin.';

  /// Title of the import sheet opened by the panel.
  static const String importTitle = 'Add media';

  /// The picker could not be shown.
  static const String pickerFailed = "Couldn't open the picker. Check that Danaview may access your media in Settings, then try again.";

  // ---- Filters and search ----------------------------------------------------------------------

  /// Filter: everything.
  static const String filterAll = 'All';

  /// Filter: videos.
  static const String filterVideo = 'Video';

  /// Filter: photos (images and freeze frames).
  static const String filterPhotos = 'Photos';

  /// Filter: audio (music files and recordings).
  static const String filterAudio = 'Audio';

  /// Filter: colour lookup tables.
  static const String filterLut = 'LUT';

  /// Search field hint.
  static const String searchHint = 'Search media';

  /// Search field semantics.
  static const String searchLabel = 'Search the media bin';

  // ---- Empty states ----------------------------------------------------------------------------

  /// Title of an empty bin.
  static const String emptyTitle = 'No media yet';

  /// What to do in an empty bin.
  static const String emptyMessage = 'Add videos, photos or music from your library, or drop files here.';

  /// Title when the filter or search matches nothing.
  static const String noMatchTitle = 'No matches';

  /// What to do when nothing matches.
  static const String noMatchMessage = 'Try another filter or clear the search.';

  // ---- Cards ------------------------------------------------------------------------------------

  /// "Used ×2" caption of a card.
  static String used(int count) => count == 0 ? 'Not used' : 'Used ×$count';

  /// Spoken form of [used].
  static String usedSpoken(int count) => count == 0 ? 'Not used on the timeline' : (count == 1 ? 'Used once' : 'Used $count times');

  /// Badge: the file is offline.
  static const String badgeMissing = 'Missing';

  /// Badge: Danaview lost access to the file.
  static const String badgeNoAccess = 'No access';

  /// Badge: the file changed since it was added.
  static const String badgeChanged = 'Changed';

  /// Badge: the engine is still making the asset.
  static const String badgeProcessing = 'Processing';

  /// Badge: the asset could not be made.
  static const String badgeFailed = 'Failed';

  /// Badge: a proxy is being made.
  static const String badgeOptimizing = 'Optimizing';

  /// Badge: the proxy is ready.
  static const String badgeProxyReady = 'Proxy ready';

  /// The kind of an asset, for semantics and the info sheet.
  static String kindName(MediaKind kind) => switch (kind) {
        MediaKind.video => 'Video',
        MediaKind.audio => 'Audio',
        MediaKind.image => 'Photo',
        MediaKind.lut => 'LUT',
        MediaKind.still => 'Freeze frame',
        MediaKind.recording => 'Recording',
      };

  /// Spoken description of a card: "beach.mp4, Video, 0:12, used twice, missing".
  static String cardSemantics(
          {required String name, required MediaKind kind, required String? duration, required int used, String? status}) =>
      [name, kindName(kind), if (duration != null) duration, usedSpoken(used), if (status != null) status].join(', ');

  /// Tooltip and semantics of a card's "+" button.
  static String addButton(String name) => 'Add $name at the playhead';

  /// Tooltip and semantics of a card's menu button.
  static String menuButton(String name) => 'More actions for $name';

  /// Semantics hint of a card (tap previews it, long press drags it).
  static const String cardHint = 'Double tap to preview. Press and hold, then drag to the timeline.';

  // ---- Actions ----------------------------------------------------------------------------------

  /// Add at the playhead.
  static const String addAtPlayhead = 'Add at playhead';

  /// Add as a picture-in-picture overlay.
  static const String addAsOverlay = 'Add as overlay';

  /// Replace the selected clip's media.
  static const String replaceSelected = 'Replace selected clip';

  /// Relink an offline file.
  static const String relink = 'Relink…';

  /// Show the media info sheet.
  static const String info = 'Info';

  /// Remove the asset from the project.
  static const String remove = 'Remove from project';

  /// Close the detail strip.
  static const String closePreview = 'Close preview';

  /// Title of the detail strip's region.
  static const String previewRegion = 'Media preview';

  // ---- Reasons ----------------------------------------------------------------------------------

  /// The project can't be edited.
  static const String notEditable = 'This project can’t be edited right now.';

  /// A LUT can't go on the timeline.
  static const String lutNotPlaceable = 'LUTs are applied from Filters, not placed on the timeline.';

  /// The asset failed to be made.
  static const String assetFailed = 'This media could not be prepared. Remove it and add it again.';

  /// Overlays need pictures or video.
  static const String overlayNeedsVisual = 'Only videos and photos can be overlays.';

  /// Replace needs a selected clip.
  static const String replaceNeedsClip = 'Select a clip on the timeline first.';

  /// The selected clip is on a locked track.
  static const String replaceLocked = 'The selected clip is on a locked track.';

  /// The selected clip can't take this kind of media.
  static const String replaceKindMismatch = 'The selected clip can’t use this kind of media.';

  /// Remove is blocked while the media is on the timeline.
  static const String removeInUse = 'It is on the timeline. Delete its clips first.';

  // ---- Toasts -----------------------------------------------------------------------------------

  /// After a remove.
  static const String removed = 'Removed from the project. Undo brings it back.';

  /// After a replace.
  static const String replaced = 'Media replaced';

  /// The overlay lane could not be made.
  static const String overlayFailed = "Couldn't add the overlay. Try again.";

  // ---- Info sheet -------------------------------------------------------------------------------

  /// Sheet title.
  static const String infoTitle = 'Media info';

  /// Row: name.
  static const String infoName = 'Name';

  /// Row: kind.
  static const String infoKind = 'Type';

  /// Row: duration.
  static const String infoDuration = 'Duration';

  /// Row: resolution.
  static const String infoResolution = 'Resolution';

  /// Row: frame rate.
  static const String infoFrameRate = 'Frame rate';

  /// Row: video codec.
  static const String infoVideoCodec = 'Video codec';

  /// Row: audio codec.
  static const String infoAudioCodec = 'Audio codec';

  /// Row: file size.
  static const String infoSize = 'Size';

  /// Row: where the file lives.
  static const String infoLocation = 'Stored';

  /// Row: how often it is used.
  static const String infoUsage = 'On the timeline';

  /// Row: availability.
  static const String infoStatus = 'Status';

  /// Status: fine.
  static const String statusAvailable = 'Available';

  /// Status: being made.
  static const String statusProcessing = 'Being prepared';

  /// Where an external file stays.
  static const String locationExternal = 'Original file (not copied)';

  /// Where a managed copy lives.
  static const String locationManaged = 'Copied into Danaview';

  /// Where a project-owned file lives.
  static const String locationProject = 'Made for this project';

  /// Frame rate with a unit.
  static String fps(double fps) => '${fps == fps.roundToDouble() ? fps.round() : fps.toStringAsFixed(2)} fps';

  // ---- Drag and drop ----------------------------------------------------------------------------

  /// Title of the import sheet of an external drop.
  static const String dropTitle = 'Add dropped media';

  /// Pill over the timeline while a drag is over it and cannot be accepted.
  static const String dropRefused = 'Can’t drop here';

  /// Toast when a drop arrives and the project can't be edited.
  static const String dropNotEditable = 'This project is read-only, so dropped files were not added.';

  /// Announced after a dragged card was dropped on the timeline.
  static const String dropped = 'Added to the timeline';

  /// The pill showing where a dragged card lands: "Starts 00:04:00".
  static String dropStart(String time) => 'Starts $time';
}
