// OWNER: HOM-12
//
// The action groups of the multi-select bar (ARCH v1.2 V2-107, Q-H2; BUILD_PLAN HOM-12). The bar
// owns no action itself: it asks every registered [SelectionGroupBuilder] for a group for the
// current selection and draws the groups it gets, in [SelectionActionGroup.order]. This ticket
// registers the media group (media_actions.dart); HOM-22 adds the file group from its own
// `file_actions.dart` by overriding [selectionActionGroupsProvider] at the app root (INT-103) or by
// passing it to `HomeSelectionBar.extraGroups`, so neither ticket edits the other's files.

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../home/home_callbacks.dart';
import '../home/home_tabs.dart';
import 'media_actions.dart';
import 'selection_model.dart';

/// Everything a group builder may look at to decide its actions.
@immutable
final class SelectionActionContext {
  /// The context of one bar build.
  const SelectionActionContext({
    required this.selection,
    required this.callbacks,
    required this.platform,
    this.playerShowsPhotos = false,
    this.onOpenPlayer,
  });

  /// The current selection (never empty when a builder is asked).
  final HomeSelection selection;

  /// The Home's optional callbacks (null ones hide their actions).
  final HomeCallbacks callbacks;

  /// The platform (editor actions exist only where the editor runs, ARCH v1.2 §3).
  final TargetPlatform platform;

  /// Whether the player can show still photos in a queue (ARCH V2-V4, [playerShowsPhotosProvider]).
  final bool playerShowsPhotos;

  /// Shows the player after "Play all" queued the items; null leaves the screen as it is.
  final VoidCallback? onOpenPlayer;

  /// Whether this platform runs the editor (montage and batch edit).
  bool get editorAvailable => homeEditorPlatform(platform);
}

/// What an action receives when it is invoked.
@immutable
final class SelectionInvocation {
  /// An invocation from [context] with the bar's [ref].
  const SelectionInvocation({required this.context, required this.ref, required this.action, required this.clearSelection});

  /// The bar's build context (for sheets, dialogs and toasts).
  final BuildContext context;

  /// The bar's ref (for the player, the library and the selection).
  final WidgetRef ref;

  /// The context the action was built in (selection, callbacks, platform).
  final SelectionActionContext action;

  /// Leaves selection mode.
  final VoidCallback clearSelection;

  /// The selection the action was offered for, in selection order.
  HomeSelection get selection => action.selection;
}

/// One button of the bar.
@immutable
final class SelectionAction {
  /// An action; [id] names it in keys and tests.
  const SelectionAction({required this.id, required this.label, required this.icon, required this.onInvoke, this.semanticLabel});

  /// A stable id (`montage`, `batch-edit`, `play`, `add-to-playlist`, …).
  final String id;

  /// The visible label.
  final String label;

  /// The icon before the label.
  final IconData icon;

  /// The spoken label when it says more than [label].
  final String? semanticLabel;

  /// Runs the action.
  final void Function(SelectionInvocation invocation) onInvoke;
}

/// A titled group of actions (Media, Files, …).
@immutable
final class SelectionActionGroup {
  /// A group; [order] sorts groups along the bar (lower first).
  const SelectionActionGroup({required this.id, required this.title, required this.actions, this.order = 0});

  /// A stable id (`media`, `files`).
  final String id;

  /// The spoken group title.
  final String title;

  /// The actions, left to right.
  final List<SelectionAction> actions;

  /// Where the group sits along the bar.
  final int order;
}

/// Gives the group for a selection, or null when it has nothing to offer.
typedef SelectionGroupBuilder = SelectionActionGroup? Function(SelectionActionContext context);

/// The registered group builders. The default is the media group; the app root overrides this
/// with `[mediaSelectionGroup, <HOM-22's file group>]` once HOM-22 lands.
final selectionActionGroupsProvider = Provider<List<SelectionGroupBuilder>>((ref) => const [mediaSelectionGroup]);

/// Whether the player shows still photos in a queue (ARCH v1.2 C-23, [VERIFY] V2-V4).
///
/// V2-V4 answer (HOM-12, 2026-10-22, run on this Mac against the app's bundled
/// media_kit_libs_macos_video 1.1.4 libmpv with `vo=null`, `image-display-duration=1`): a JPEG
/// in a playlist opens through mpv's `mf` demuxer with the `mjpeg` decoder and lasts exactly
/// `image-display-duration`; PNG, TIFF, GIF and BMP are demuxed but fail with "no decoders",
/// and HEIC doesn't open at all. media_kit_libs_ios_video 1.1.4 is the same libmpv-darwin build
/// (its Avcodec carries the same `mjpeg` decoder strings and no PNG decoder), so iOS gives the
/// same answer: **JPEG only** ([playerDecodesPhoto]). The player (v1.0/1.1 package) never sets
/// `image-display-duration`, so a photo would flash for mpv's 1 s default, and most iPhone photos
/// are HEIC; "Play all" therefore still skips photos with a notice everywhere. Android
/// (media_kit_libs_android_video 1.3.8, fetched at Gradle time) is recorded by the Windows lane;
/// Windows and Linux are unverified. Override this provider with true where the player sets a
/// slideshow duration; JPEG photos then join the queue and other formats stay skipped.
final playerShowsPhotosProvider = Provider<bool>((ref) => playerShowsPhotos(defaultTargetPlatform));

/// The verified V2-V4 result of [platform] (see [playerShowsPhotosProvider]).
bool playerShowsPhotos(TargetPlatform platform) => switch (platform) {
      TargetPlatform.iOS || TargetPlatform.macOS => false,
      TargetPlatform.android || TargetPlatform.windows || TargetPlatform.linux || TargetPlatform.fuchsia => false,
    };

/// The groups [builders] give for [context], sorted by order (empty groups dropped).
List<SelectionActionGroup> selectionGroupsFor(SelectionActionContext context, Iterable<SelectionGroupBuilder> builders) {
  if (context.selection.isEmpty) return const [];
  final groups = [
    for (final build in builders)
      if (build(context) case final group? when group.actions.isNotEmpty) group,
  ];
  // List.sort isn't stable; keep registration order for equal orders.
  final indexed = groups.indexed.toList()
    ..sort((a, b) {
      final c = a.$2.order.compareTo(b.$2.order);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
  return List.unmodifiable(indexed.map((e) => e.$2));
}
