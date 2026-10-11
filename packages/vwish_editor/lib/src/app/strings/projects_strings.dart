// OWNER: UX-05
//
// Copy of the Projects screen (ux.md §5.1, §5.2): titles, card meta lines, badges, actions,
// confirmations, toasts, failures and the empty, error and unsupported-device states. Plain,
// specific, with a next step (ARCH §19). Never includes media paths.

import 'package:vwish_editor_core/model.dart' show AspectRatio, TimeUs;
import 'package:vwish_editor_engine_api/vwish_editor_engine_api.dart' show UnsupportedReasons;

import '../editor_prefs.dart' show ProjectSortPreference;

/// Copy of the Projects screen (ux.md §5).
abstract final class ProjectsStrings {
  /// Screen title.
  static const String title = 'Projects';

  /// Top-bar button that opens the New project sheet.
  static const String newShort = 'New';

  /// Spoken label of the top-bar New button.
  static const String newSemantic = 'New project';

  /// Empty-state button.
  static const String newProject = 'New project';

  /// `1 project`, `3 projects` (top-bar subtitle).
  static String count(int n) => n == 1 ? '1 project' : '$n projects';

  // ---- Toolbar ---------------------------------------------------------------------------------

  /// Sort dropdown label.
  static const String sortLabel = 'Sort';

  /// Label of a sort order.
  static String sortName(ProjectSortPreference sort) => switch (sort) {
        ProjectSortPreference.recent => 'Recent',
        ProjectSortPreference.name => 'Name',
      };

  /// Search field hint.
  static const String searchHint = 'Search projects';

  /// No project matches the search.
  static String noMatchTitle(String query) => 'No projects match "$query"';

  /// Next step when nothing matches.
  static const String noMatchMessage = 'Check the spelling or clear the search.';

  // ---- States --------------------------------------------------------------------------------

  /// Loading state (spoken).
  static const String loading = 'Loading projects';

  /// Empty state title.
  static const String emptyTitle = 'No projects yet';

  /// Empty state message.
  static const String emptyMessage = 'Make a video from clips, photos and music on this device. '
      'Your originals stay where they are.';

  /// Error state title.
  static const String errorTitle = "Projects couldn't be loaded";

  /// Error state message.
  static const String errorMessage = 'Something went wrong while reading your projects. Try again.';

  /// Retry button.
  static const String retry = 'Try again';

  /// Back button of the unsupported state.
  static const String back = 'Back';

  /// Unsupported-device title.
  static const String unsupportedTitle = "Video editing isn't available on this device";

  /// Why the device can't edit (an `EditorCapabilities.unsupportedReason`), with what still works.
  static String unsupportedMessage(String reason) => switch (reason) {
        UnsupportedReasons.androidTooOld => 'Video editing needs Android 10 or later. You can still play all your videos.',
        UnsupportedReasons.gles3Missing ||
        UnsupportedReasons.metalMissing =>
          "This device's graphics can't run the video editor. You can still play all your videos.",
        UnsupportedReasons.insufficientMemory =>
          'Video editing needs a device with at least 2 GB of memory. You can still play all your videos.',
        _ => "This version of Vwish can't edit videos on this device. You can still play all your videos.",
      };

  // ---- Cards ---------------------------------------------------------------------------------

  /// `m:ss` or `h:mm:ss` of a timeline duration.
  static String clock(TimeUs duration) {
    final totalSeconds = duration <= 0 ? 0 : duration ~/ 1000000;
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
  }

  /// `16:9`.
  static String aspect(AspectRatio aspect) => '${aspect.w}:${aspect.h}';

  static const List<String> _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  /// `Edited just now`, `Edited 5 min ago`, `Edited 2 h ago`, `Edited yesterday`,
  /// `Edited 3 days ago`, `Edited 12 Oct`, `Edited 12 Oct 2025`.
  static String edited(DateTime updatedAt, DateTime now) {
    final local = updatedAt.toLocal();
    final today = now.toLocal();
    final diff = today.difference(local);
    if (diff.inMinutes < 1) return 'Edited just now';
    if (diff.inHours < 1) return 'Edited ${diff.inMinutes} min ago';
    final days = DateTime(today.year, today.month, today.day).difference(DateTime(local.year, local.month, local.day)).inDays;
    if (days <= 0) return 'Edited ${diff.inHours} h ago';
    if (days == 1) return 'Edited yesterday';
    if (days < 7) return 'Edited $days days ago';
    final date = '${local.day} ${_months[local.month - 1]}';
    return local.year == today.year ? 'Edited $date' : 'Edited $date ${local.year}';
  }

  /// The card's one-line meta: `1:24 · 9:16 · Edited 2 h ago`.
  static String meta(TimeUs duration, AspectRatio aspectRatio, DateTime updatedAt, DateTime now) =>
      '${clock(duration)} · ${aspect(aspectRatio)} · ${edited(updatedAt, now)}';

  /// Badge: missing media.
  static String missingBadge(int count) => count == 1 ? '1 missing' : '$count missing';

  /// Badge: a newer journal can be restored.
  static const String recoveryBadge = 'Unsaved changes';

  /// Badge: made by a newer app, blocked.
  static const String needsUpdateBadge = 'Needs update';

  /// Badge: made by a newer app, opens read-only.
  static const String readOnlyBadge = 'Read-only';

  /// Badge: no valid copy.
  static const String corruptBadge = 'Damaged';

  /// Spoken description of a card.
  static String cardSemantics({
    required String name,
    required String meta,
    required List<String> badges,
  }) =>
      [name, meta, ...badges].join('. ');

  /// Card menu button.
  static const String moreActions = 'Project actions';

  /// Poster placeholder (spoken).
  static const String noPoster = 'No preview yet';

  // ---- Footer --------------------------------------------------------------------------------

  /// `Projects use 1.4 GB`.
  static String footer(String size) => 'Projects use $size';

  /// Footer link.
  static const String manageStorage = 'Manage storage';

  // ---- Actions -------------------------------------------------------------------------------

  /// Menu: open.
  static const String open = 'Open';

  /// Menu: rename.
  static const String rename = 'Rename';

  /// Menu: duplicate.
  static const String duplicate = 'Duplicate';

  /// Menu: delete.
  static const String delete = 'Delete';

  /// Rename sheet title.
  static const String renameTitle = 'Rename project';

  /// Rename field hint.
  static const String renameHint = 'Project name';

  /// Rename confirm button.
  static const String save = 'Save';

  /// Cancel button.
  static const String cancel = 'Cancel';

  /// Longest name, in characters (ux.md §5.2).
  static const int maxNameLength = 80;

  /// Validation of a project name (1–80 characters after trimming), or null when valid.
  static String? validateName(String value) {
    final n = value.trim().runes.length;
    if (n == 0) return 'Enter a name.';
    if (n > maxNameLength) return 'Use $maxNameLength characters or fewer.';
    return null;
  }

  /// Toast after a rename.
  static String renamed(String name) => 'Renamed to "$name"';

  /// Toast after a duplicate.
  static String duplicated(String name) => 'Duplicated as "$name"';

  /// Toast after a duplicate whose new name is not known yet.
  static const String duplicatedPlain = 'Project duplicated';

  /// Delete confirmation title.
  static String deleteTitle(String name) => 'Delete "$name"?';

  /// Delete confirmation message (ux.md §5.2).
  static const String deleteMessage = 'The project and media made in it (voice recordings, freeze frames, reversed clips) '
      'are removed. Your original videos, photos and music stay where they are.';

  /// Delete confirmation button.
  static const String deleteConfirm = 'Delete';

  /// Undo bar text.
  static String deleted(String name) => 'Deleted "$name"';

  /// Undo bar text when several deletions wait.
  static String deletedMany(int count) => '$count projects deleted';

  /// Undo button.
  static const String undo = 'Undo';

  /// Dialog: project made by a newer app (ux.md §5.2).
  static const String needsUpdateTitle = 'Update Vwish to open this project';

  /// Dialog message: project made by a newer app.
  static const String needsUpdateMessage = 'This project was made with a newer version of Vwish. Update Vwish to open it. '
      'Nothing was changed.';

  /// Dialog: project damaged.
  static const String corruptTitle = "This project can't be opened";

  /// Dialog message: project damaged.
  static const String corruptMessage = 'Its project file is damaged and no earlier copy was found. '
      'Your original videos, photos and music are safe. You can delete the project.';

  /// Dialog button.
  static const String ok = 'OK';

  // ---- Failures ------------------------------------------------------------------------------

  /// Failure: the project is open in the editor.
  static const String busyTitle = 'This project is open';

  /// Failure detail: busy.
  static const String busyDetail = 'Close it in the editor, then try again.';

  /// Failure: the project no longer exists.
  static const String notFoundTitle = 'This project no longer exists';

  /// Failure detail: not found.
  static const String notFoundDetail = 'It may have been deleted. The list is up to date now.';

  /// Failure: invalid name.
  static const String invalidNameTitle = "That name can't be used";

  /// Failure detail: invalid name.
  static const String invalidNameDetail = 'Use 1 to 80 characters.';

  /// Failure: no space.
  static const String diskFullTitle = 'Not enough storage space';

  /// Failure detail: no space.
  static const String diskFullDetail = 'Free up space on this device, then try again.';

  /// Failure: made by a newer app.
  static const String newerTitle = 'This project needs a newer Vwish';

  /// Failure detail: newer.
  static const String newerDetail = 'Update Vwish to change it.';

  /// Failure: damaged.
  static const String corruptFailureTitle = 'This project is damaged';

  /// Failure detail: damaged.
  static const String corruptFailureDetail = 'It can only be deleted.';

  /// Failure: anything else.
  static const String ioTitle = "Couldn't finish that";

  /// Failure detail: anything else.
  static const String ioDetail = 'Try again. If it keeps happening, restart Vwish.';

  /// Prefix naming the action that failed: `Couldn't delete "Trip"`.
  static String actionFailed(String action, String name) => switch (action) {
        'rename' => 'Couldn\'t rename "$name"',
        'duplicate' => 'Couldn\'t duplicate "$name"',
        'delete' => 'Couldn\'t delete "$name"',
        'restore' => 'Couldn\'t restore "$name"',
        'discard' => 'Couldn\'t discard the changes to "$name"',
        _ => 'Couldn\'t create the project',
      };
}
