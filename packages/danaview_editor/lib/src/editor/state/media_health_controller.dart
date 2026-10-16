// OWNER: UX-40
//
// MediaHealthController (ux.md §13.1): the availability of the open project's media.
//
// * It subscribes to `MediaPoolService.watchAvailability(session)` when the project opens (the real
//   service checks on the first listen), again on every [refresh] (app resume, after a relink), and
//   stops when the editor closes.
// * What it knows: the report per asset ([MediaHealthState.byMedia]) and which assets the timeline
//   uses. An asset the timeline does not use never nags: the banner, the preview's "Media missing"
//   card and the export block follow only the assets in use ([MediaHealthState.health]).
// * `missing`, `accessLost` and `changed` assets are offline (they block export); `derivedMissing`
//   renditions are rebuilt silently and never shown.
// * It publishes [MediaHealth] to `EditorController.setMediaHealth`, which the preview's offline
//   card, the toolbar and the export pre-check read, and keeps the banner's "dismissed for this
//   session" flag: the banner comes back on [resurfaceBanner] (the export pre-check) and whenever
//   more media goes missing than the user dismissed.
// * Every later report that changes the availability of any asset also calls `onAvailabilityChanged`
//   (`EditorController.mediaAvailabilityChanged`), which compiles the plan again: the compiler
//   reads the latest report before it resolves, and the commit of a relink compiles before the
//   re-check after it reports (FIX-UX-40-1: relinked media stayed offline in the preview).
//
// `mediaHealthControllerProvider(id)` is started by the widget that shows the banner
// (`EditorHealthHost`): reading it is what starts the subscription.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart' show EditProject, MediaId, ProjectId;
import 'package:danaview_editor_core/ops.dart' show mediaReferencedBy;
import 'package:danaview_editor_core/store.dart' show MediaAvailability, MediaAvailabilityReport, MediaPoolService;

import '../../app/editor_providers.dart';
import 'editor_session.dart';
import 'editor_state.dart';

/// What the editor knows about the availability of its media.
@immutable
final class MediaHealthState {
  /// Creates the state.
  MediaHealthState({
    Map<MediaId, MediaAvailability> byMedia = const {},
    Set<MediaId> used = const {},
    this.checked = false,
    this.dismissedCount = 0,
  })  : byMedia = Map.unmodifiable(byMedia),
        used = Set.unmodifiable(used);

  /// Nothing known yet.
  static final MediaHealthState unknown = MediaHealthState();

  /// The last report: availability per pool asset.
  final Map<MediaId, MediaAvailability> byMedia;

  /// The assets the timeline uses (clips and imported LUT looks).
  final Set<MediaId> used;

  /// Whether a first report arrived.
  final bool checked;

  /// How many files were offline when the user dismissed the banner (0: not dismissed).
  final int dismissedCount;

  static bool _offline(MediaAvailability? a) =>
      a == MediaAvailability.missing || a == MediaAvailability.accessLost || a == MediaAvailability.changed;

  /// Offline assets, used or not (the sheet lists all of them).
  Set<MediaId> get offline => {
        for (final e in byMedia.entries)
          if (_offline(e.value)) e.key,
      };

  /// Offline assets the timeline uses.
  Set<MediaId> get offlineUsed => {
        for (final e in byMedia.entries)
          if (_offline(e.value) && used.contains(e.key)) e.key,
      };

  /// Offline assets in use that are plainly missing (not access lost, not changed).
  int get missingCount => offlineUsed.where((id) => byMedia[id] == MediaAvailability.missing).length;

  /// Whether every offline file in use is plainly missing (the banner says "missing").
  bool get onlyMissing => offlineUsed.isNotEmpty && missingCount == offlineUsed.length;

  /// Files that block export and the banner counts.
  int get count => offlineUsed.length;

  /// The availability of [id] (available when unknown).
  MediaAvailability of(MediaId id) => byMedia[id] ?? MediaAvailability.available;

  /// What `EditorState.media` shows.
  MediaHealth get health {
    final ids = offlineUsed;
    return ids.isEmpty ? MediaHealth.ok : MediaHealth(missing: ids, relinkRequired: true);
  }

  /// Whether the banner is shown: something is offline, and the user did not dismiss it for this
  /// many files.
  bool get bannerVisible => count > 0 && dismissedCount < count;

  /// A copy with the given fields replaced.
  MediaHealthState copyWith({Map<MediaId, MediaAvailability>? byMedia, Set<MediaId>? used, bool? checked, int? dismissedCount}) =>
      MediaHealthState(
        byMedia: byMedia ?? this.byMedia,
        used: used ?? this.used,
        checked: checked ?? this.checked,
        dismissedCount: dismissedCount ?? this.dismissedCount,
      );

  @override
  bool operator ==(Object other) =>
      other is MediaHealthState &&
      other.checked == checked &&
      other.dismissedCount == dismissedCount &&
      mapEquals(other.byMedia, byMedia) &&
      setEquals(other.used, used);

  @override
  int get hashCode => Object.hash(checked, dismissedCount, Object.hashAllUnordered(byMedia.keys), Object.hashAllUnordered(used));

  @override
  String toString() => 'MediaHealthState(offline: $count, checked: $checked, dismissedAt: $dismissedCount)';
}

/// Subscribes to a project's availability reports and publishes the result (see the file header).
class MediaHealthController extends StateNotifier<MediaHealthState> {
  /// Creates the controller. [source] opens a fresh availability stream (the real service checks
  /// when it is listened to); [publish] receives the [MediaHealth] after every change.
  /// [onAvailabilityChanged] runs when a report changes the availability of any asset (the plan
  /// is compiled again).
  MediaHealthController({
    required Stream<MediaAvailabilityReport> Function() source,
    required ValueChanged<MediaHealth> publish,
    VoidCallback? onAvailabilityChanged,
  })  : _source = source,
        _publish = publish,
        _onAvailabilityChanged = onAvailabilityChanged,
        super(MediaHealthState.unknown);

  final Stream<MediaAvailabilityReport> Function() _source;
  final ValueChanged<MediaHealth> _publish;
  final VoidCallback? _onAvailabilityChanged;
  StreamSubscription<MediaAvailabilityReport>? _subscription;
  EditProject? _project;
  Object? _usedTimeline;
  MediaHealth _published = MediaHealth.ok;
  Map<MediaId, MediaAvailability>? _reported;

  /// Whether the controller is watching availability.
  bool get isWatching => _subscription != null;

  /// Starts watching (idempotent). [project] is the open project (for what is in use).
  void start(EditProject? project) {
    projectChanged(project);
    if (_subscription != null) return;
    _listen();
  }

  void _listen() {
    _subscription = _source().listen(
      _onReport,
      onError: (Object error, StackTrace stack) => debugPrint('[MediaHealth] Availability failed: ${error.runtimeType}'),
    );
  }

  /// Stops watching (the editor closed).
  void stop() {
    final sub = _subscription;
    _subscription = null;
    if (sub != null) unawaited(sub.cancel());
  }

  /// Checks again: on app resume and after a relink. The previous subscription is replaced so the
  /// pool service runs a fresh check.
  void refresh() {
    if (!mounted || _project == null) return;
    stop();
    _listen();
  }

  void _onReport(MediaAvailabilityReport report) {
    if (!mounted) return;
    final previous = _reported;
    _reported = Map.of(report.byMedia);
    // The first report only confirms what the open compiled (it had no report yet, and a file it
    // could not resolve is already a placeholder). Later changes compile again, before the state
    // changes, so the new plan is scheduled before the banner goes.
    if (previous != null && !mapEquals(previous, report.byMedia)) _onAvailabilityChanged?.call();
    if (!mounted) return;
    _set(state.copyWith(byMedia: report.byMedia, checked: true));
  }

  /// The timeline or pool changed: recompute what is in use.
  void projectChanged(EditProject? project) {
    if (!mounted) return;
    _project = project;
    if (project == null || identical(_usedTimeline, project.timeline)) return;
    _usedTimeline = project.timeline;
    _set(state.copyWith(used: mediaReferencedBy(project.timeline)));
  }

  void _set(MediaHealthState next) {
    var value = next;
    // Once everything is back, a later loss shows the banner again.
    if (value.count == 0 && value.dismissedCount != 0) value = value.copyWith(dismissedCount: 0);
    if (value == state) return;
    state = value;
    final health = value.health;
    if (health != _published) {
      _published = health;
      _publish(health);
    }
  }

  /// Hides the banner for this session (until more files go missing or [resurfaceBanner]).
  void dismissBanner() {
    if (!mounted || state.count == 0) return;
    state = state.copyWith(dismissedCount: state.count);
  }

  /// Shows the banner again (the export pre-check).
  void resurfaceBanner() {
    if (!mounted || state.dismissedCount == 0) return;
    state = state.copyWith(dismissedCount: 0);
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}

/// The media health of [id]: started by the widget that shows the banner, stopped when the editor
/// closes (the session detaches).
final mediaHealthControllerProvider = StateNotifierProvider.autoDispose.family<MediaHealthController, MediaHealthState, ProjectId>(
  (ref, id) => createMediaHealthController(ref, id),
  name: 'mediaHealthControllerProvider',
);

/// Builds the value of [mediaHealthControllerProvider] for [id].
MediaHealthController createMediaHealthController(Ref<Object?> ref, ProjectId id) {
  final session = ref.watch(editorSessionProvider(id));
  final pool = ref.watch(mediaPoolServiceProvider);
  final editor = ref.read(editorControllerProvider(id).notifier);
  final controller = MediaHealthController(
    source: () => _watch(pool, session),
    publish: editor.setMediaHealth,
    onAvailabilityChanged: editor.mediaAvailabilityChanged,
  );

  void attachment() {
    if (session.attached.value) {
      controller.start(session.committedProject);
    } else {
      controller.stop();
    }
  }

  session.attached.addListener(attachment);
  ref.onDispose(() => session.attached.removeListener(attachment));
  ref.listen<EditProject?>(
    editorControllerProvider(id).select((s) => s.project),
    (_, project) {
      if (session.attached.value) controller.projectChanged(project);
    },
  );
  attachment();
  return controller;
}

Stream<MediaAvailabilityReport> _watch(MediaPoolService pool, EditorSession session) {
  final edit = session.editOrNull;
  return edit == null ? const Stream<MediaAvailabilityReport>.empty() : pool.watchAvailability(edit);
}
