// OWNER: UX-08
//
// EditorSession: the open editing session of one project, as providers see it (ARCH §17.3). It
// wraps core `EditSession` (history, transactions, dry runs) together with the preview session,
// `PlanSync` and the session's plan compiler. `EditorController` attaches them in `open()` and
// detaches them in `close()`; other controllers read them through `editorSessionProvider(id)`:
//
// * UX-13 calls `dryRun` per pointer move (drag ghosts, ARCH §17.4);
// * UX-14 drives transport and seeks on `preview` and starts its playhead from `openedAt` /
//   `initialSeek`;
// * UX-18 calls `planSync.resync()` for "Restart preview";
// * UX-35's Tasks controller waits for [EditorSession.mediaResolved] before it resolves sources
//   (FIX-QA05-D5): the session compiler's media snapshot is only warm after its first resolve pass
//   (INT-02 refreshes it before each plan compile), and before that every media reads offline;
// * `EditorController.close` marks the session [EditorSession.closing] before anything else
//   (FIX-M15, QA-02 M-15): the Tasks controller drops its pending resume work at once, and media
//   resolves that finish after that are ignored, so nothing in the close waits on a job resume or
//   on a media resolve.
//
// Mutations never go through here: every edit is `EditorController.apply` / `beginTransaction`.
//
// `EditorPosterCapture.capture` is the `PosterProvider` INT-02 passes to `FileProjectRepository`:
// on lifecycle and close saves it renders an engine thumbnail of the clip under the playhead.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/eval.dart' show ClipTimeMap;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show EditCommand, EditPreview, EditSession, HistoryEntry, ItemNotFound;
import 'package:danaview_editor_core/store.dart' show LoadedProject;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';

import 'plan_compiler_port.dart';

/// The open editing session of one project (ARCH §17.3).
class EditorSession {
  /// Creates the (detached) session of [id].
  EditorSession(this.id);

  /// Project id.
  final ProjectId id;

  static final Expando<EditorSession> _byEdit = Expando<EditorSession>('EditorSession');

  final ValueNotifier<bool> _attached = ValueNotifier<bool>(false);
  final ValueNotifier<int> _mediaResolves = ValueNotifier<int>(0);
  final ValueNotifier<bool> _closing = ValueNotifier<bool>(false);
  EditSession? _edit;
  LoadedProject? _loaded;
  EditorEngine? _engine;
  EditorCapabilities? _capabilities;
  PreviewSession? _preview;
  PlanSync? _planSync;
  SessionPlanCompiler? _compiler;
  TimeUs _openedAt = 0;
  SeekAck? _initialSeek;
  bool _disposed = false;

  /// The editor session that wraps [edit], or null.
  static EditorSession? of(EditSession edit) => _byEdit[edit];

  /// True while a project is attached (between open and close); notifies on change.
  ValueListenable<bool> get attached => _attached;

  /// Whether a project is attached.
  bool get isOpen => _edit != null;

  /// Media-resolve passes of the session's compiler since the project attached (one per finished
  /// plan compile, FIX-QA05-D5); 0 until the first one. Notifies on change.
  ValueListenable<int> get mediaResolves => _mediaResolves;

  /// Whether the compiler's media snapshot is warm: [SessionPlanCompiler.resolve] answers for the
  /// attached project (before the first pass it may read every media as offline).
  bool get mediaResolved => _mediaResolves.value > 0;

  /// Records a finished media-resolve pass of [compiler] (called by `EditorController` when a plan
  /// compile of the attached session's compiler completes, successfully or not). A pass of a
  /// compiler that is no longer attached is ignored.
  void markMediaResolved(SessionPlanCompiler compiler) {
    if (_disposed || !isOpen || _closing.value || !identical(compiler, _compiler)) return;
    _mediaResolves.value++;
  }

  /// True from the moment `EditorController.close` starts until the session detaches (FIX-M15);
  /// notifies on change. Background work stops resuming while it is set.
  ValueListenable<bool> get closing => _closing;

  /// Whether the attached session is closing (see [closing]).
  bool get isClosing => _closing.value;

  /// Marks the attached session as closing (called first by `EditorController.close`). Does
  /// nothing when nothing is attached.
  void markClosing() {
    if (_disposed || !isOpen || _closing.value) return;
    _closing.value = true;
  }

  /// Core session (history, transactions). Throws [StateError] before open.
  EditSession get edit => _edit ?? (throw StateError('EditorSession $id is not open'));

  /// Core session, or null before open.
  EditSession? get editOrNull => _edit;

  /// The project as opened (health, warnings, recovery), or null.
  LoadedProject? get loaded => _loaded;

  /// The current project (the working copy while a transaction is open), or null before open.
  EditProject? get project => _edit?.project;

  /// The committed project, or null before open.
  EditProject? get committedProject => _edit?.committedProject;

  /// The engine the preview runs on, or null before open.
  EditorEngine? get engine => _engine;

  /// Device capabilities used for this session, or null before open.
  EditorCapabilities? get capabilities => _capabilities;

  /// The live preview, or null (not open, or the preview failed to start).
  PreviewSession? get preview => _preview;

  /// Keeps the preview's plan in step with the project, or null without a preview.
  PlanSync? get planSync => _planSync;

  /// The session's plan compiler, or null before open.
  SessionPlanCompiler? get compiler => _compiler;

  /// The playhead the editor opened at (quantized, inside the project).
  TimeUs get openedAt => _openedAt;

  /// The exact-seek acknowledgement of the open, or null when the preview didn't start.
  SeekAck? get initialSeek => _initialSeek;

  /// Dry-runs [command] on the current project (drag ghosts, ≤ 2 ms); rejected before open.
  EditPreview dryRun(EditCommand command) {
    final e = _edit;
    if (e == null) return EditPreview.rejected(const ItemNotFound('session'));
    return e.dryRun(command);
  }

  /// The newest history labels, newest first (history sheet: 50).
  List<String> recentLabels(int max) => _edit?.recentLabels(max) ?? const [];

  /// History entries, oldest first.
  List<HistoryEntry> get historyEntries => _edit?.entries ?? const [];

  /// Attaches the opened project (called by `EditorController.open`).
  void attach({
    required EditSession edit,
    required LoadedProject loaded,
    required EditorEngine engine,
    required EditorCapabilities capabilities,
    required SessionPlanCompiler compiler,
    PreviewSession? preview,
    PlanSync? planSync,
  }) {
    _edit = edit;
    _loaded = loaded;
    _engine = engine;
    _capabilities = capabilities;
    _compiler = compiler;
    _preview = preview;
    _planSync = planSync;
    _byEdit[edit] = this;
    if (!_disposed) {
      _mediaResolves.value = 0;
      _closing.value = false;
      _attached.value = true;
    }
  }

  /// Records where the editor opened (called by `EditorController.open` after the exact seek).
  void markOpenedAt(TimeUs t, SeekAck? ack) {
    _openedAt = t;
    _initialSeek = ack;
  }

  /// Replaces the preview after "Restart preview" re-created it.
  void replacePreview(PreviewSession? preview, PlanSync? planSync) {
    _preview = preview;
    _planSync = planSync;
  }

  /// Detaches everything (called by `EditorController.close`); the caller disposes the preview.
  void detach() {
    final e = _edit;
    if (e != null) _byEdit[e] = null;
    _edit = null;
    _loaded = null;
    _preview = null;
    _planSync = null;
    _compiler = null;
    _initialSeek = null;
    if (!_disposed) {
      _mediaResolves.value = 0;
      _attached.value = false;
      _closing.value = false;
    }
  }

  /// Releases the notifier (provider disposal).
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _attached.dispose();
    _mediaResolves.dispose();
    _closing.dispose();
  }

  @override
  String toString() => 'EditorSession($id, ${isOpen ? 'open' : 'detached'})';
}

/// Builds the value of `editorSessionProvider` for [id]. The session lives as long as the
/// editor controller that watches it (the controller keeps itself alive until `close()`
/// completes).
EditorSession createEditorSession(Ref<Object?> ref, ProjectId id) {
  final session = EditorSession(id);
  ref.onDispose(session.dispose);
  return session;
}

// -------------------------------------------------------------------------------------------------
// Poster
// -------------------------------------------------------------------------------------------------

/// Renders the project poster on lifecycle and close saves (ux.md §16.3: "poster capture on
/// hide/close"). Pass [capture] as `FileProjectRepository(poster: EditorPosterCapture.capture)`.
abstract final class EditorPosterCapture {
  /// Thumbnail height of the poster (the Projects grid shows it at most ~180 px tall at 2x).
  static const int heightPx = 360;

  /// Thumbnail interval: the poster is the frame within 100 ms of the playhead.
  static const int intervalMs = 100;

  /// How long a capture may take before the save goes on without a poster.
  static const Duration timeout = Duration(milliseconds: 1500);

  /// The poster JPEG of [edit] (an engine thumbnail of the clip under the playhead), or null when
  /// there is nothing to show or the engine can't render it. Never throws.
  static Future<Uint8List?> capture(EditSession edit) async {
    final session = EditorSession.of(edit);
    final engine = session?.engine;
    final compiler = session?.compiler;
    if (session == null || engine == null || compiler == null) return null;
    final project = edit.committedProject;
    final target = targetOf(project);
    if (target == null) return null;
    ThumbnailHandle? handle;
    try {
      final media = compiler.resolve(project, target.$1.media);
      if (media == null) return null;
      handle = engine.thumbnails.request(
        ThumbnailRequest(
          media: media,
          intervalMs: intervalMs,
          tileIndex: target.$2 ~/ (intervalMs * 1000),
          heightPx: heightPx,
          framesPerTile: 1,
        ),
        priority: ThumbPriority.background,
      );
      final tile = await handle.result.timeout(timeout);
      return tile.encoded.isEmpty ? null : tile.encoded;
    } catch (_) {
      handle?.cancel();
      return null;
    }
  }

  /// The visual clip the poster shows and its source time: the main-lane clip under the playhead,
  /// else any visible visual clip under it, else the project's first visual clip.
  @visibleForTesting
  static (MediaClip, TimeUs)? targetOf(EditProject project) {
    final rate = project.settings.frameRate;
    final t = project.view.playhead;
    MediaClip? under;
    MediaClip? first;
    for (final track in project.tracks) {
      if (track.hidden || !track.kind.isVisual) continue;
      for (final item in track.items) {
        if (item is! MediaClip || item.visual == null) continue;
        first ??= item;
        if (item.start <= t && t < item.end && (under == null || track.isMain)) under = item;
      }
    }
    final clip = under ?? first;
    if (clip == null) return null;
    final asset = project.pool[clip.media];
    if (asset != null && asset.kind != MediaKind.video) return (clip, 0);
    final at = clip == under ? t : clip.start;
    final q = rate.quantize(at);
    final clamped = q < clip.start ? clip.start : (q >= clip.end ? clip.end - 1 : q);
    return (clip, ClipTimeMap.forClip(clip, rate).toSource(clamped));
  }
}
