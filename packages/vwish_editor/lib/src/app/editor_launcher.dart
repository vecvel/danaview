// OWNER: UX-41
//
// The player's Edit action (ARCH §17.1, ux.md §4.4, §4.6): `EditorLauncher.openFromPlayer`.
//
//   1. Pause the player. The position comes from the request (the player's last snapshot).
//   2. Device gate (`EditorCapabilities.supported`): below the gate (android_too_old,
//      gles3_missing, insufficient_memory, …) explain why and stop.
//   3. Compatibility pre-check, each step bounded by 300 ms: `File.exists` (content URIs skip it)
//      and `EditorEngine.compatibility`. A missing file shows the player's toast; `NotEditable`
//      shows "This video can't be edited" with platform-specific copy (R7: MKV/WebM/AVI on iOS).
//      A step that doesn't answer in time doesn't block: the import's probe decides later.
//   4. Reuse `findUntouchedProjectFor(path)` (Edit twice never litters Projects) or create one
//      with `create(fromMedia, initialPlayhead: position)`. A direct create shows a
//      non-dismissible "Preparing editor…" after 300 ms. When the import must make a managed copy
//      (e.g. the Android "open with" cache), UX-06's ImportMediaSheet runs it instead: free-space
//      preflight (size + 64 MB) with its refusal copy, copy progress and Cancel, which deletes the
//      created project and with it the partial copy.
//   5. `PlayerHandoff.suspend` (release on `lowMemoryDevice`, else pause).
//   6. Open the editor through the router's callback (INT-04 pushes `/editor/:id?t=<µs>`); when
//      that route pops, `PlayerHandoff.resume` restores the player paused at the original
//      position. The orientation owner stack (ScreenOrientationPolicy) restores the player's
//      orientation when the editor releases its `free` owner.
//
// `vwish_features` never imports the editor, and the editor sees `vwish_features` only through
// chrome/orientation/storage (ARCH §4.2 rule 7), so the request and the player are ports here:
// the app root adapts `PlayerEditRequest` and `PlayerController.suspendForEditor` /
// `resumeAfterEditor` to [EditorLaunchRequest] and [PlayerHandoff].

import 'dart:async';
import 'dart:io' show File;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Icons, Theme;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vwish_editor_core/model.dart'
    show ContentUriLocator, FileLocator, FromPlayerOrigin, MediaAccessFailure, MediaAccessPort, MediaLocator, MediaOrigin, PickedMedia, ProjectId, ProjectOrigin, TimeUs;
import 'package:vwish_editor_core/store.dart';
import 'package:vwish_editor_engine_api/vwish_editor_engine_api.dart';
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import '../editor/flows/import_media_sheet.dart';
import '../editor/state/editor_state.dart' show EditorFailure, EditorFailures, ImportFailed;
import 'editor_messages.dart';
import 'editor_providers.dart';
import 'strings/launcher_strings.dart';

/// What the player hands to the editor (the app root maps `PlayerEditRequest` to this).
///
/// See ARCH §17.1.
@immutable
final class EditorLaunchRequest {
  /// Creates a request.
  const EditorLaunchRequest({required this.pathOrUri, required this.title, required this.position, this.wasPlaying = false});

  /// Local path, `file://` or `content://` URI of the video.
  final String pathOrUri;

  /// The title the player shows (the project name).
  final String title;

  /// The player's last position; the editor opens there.
  final Duration position;

  /// Whether it was playing when Edit was chosen.
  final bool wasPlaying;

  @override
  bool operator ==(Object other) =>
      other is EditorLaunchRequest && other.pathOrUri == pathOrUri && other.title == title && other.position == position && other.wasPlaying == wasPlaying;

  @override
  int get hashCode => Object.hash(pathOrUri, title, position, wasPlaying);

  @override
  String toString() => 'EditorLaunchRequest(${position.inMilliseconds} ms, wasPlaying: $wasPlaying)';
}

/// The player, as the launcher sees it (ux.md §4.6). The app root implements it with
/// `PlayerController.pause`, `suspendForEditor(PlayerHandoffMode.pause | release)`,
/// `resumeAfterEditor(token)` and `showPlayerToast`.
///
/// See ARCH §17.1.
abstract interface class PlayerHandoff {
  /// Pauses playback (step 1).
  Future<void> pause();

  /// Steps aside for the editor: pause, or with [release] stop the engine (low-memory devices).
  Future<void> suspend({required bool release});

  /// Restores the player after the editor closed: paused at the original position.
  Future<void> resume();

  /// Shows [message] the way the player shows its own toasts.
  void showToast(String message);
}

/// Opens the editor on [id] with the playhead at [at] (µs) and completes when that route pops.
/// INT-04: `(id, at) => context.push(editorLocation(id, at: at))`.
typedef EditorRouteOpener = Future<void> Function(ProjectId id, TimeUs at);

/// How [EditorLauncher.openFromPlayer] ended.
enum EditorLaunchOutcome {
  /// The editor opened and has closed again.
  opened,

  /// The file is gone (toast shown).
  fileMissing,

  /// The file can't be edited here (explained).
  notEditable,

  /// The device is below the editor gate (explained).
  deviceUnsupported,

  /// The import was cancelled, or refused for lack of space.
  cancelled,

  /// Preparing the project failed (explained).
  failed,

  /// Another launch is still running.
  busy,
}

/// Opens the editor from the player's Edit action (ARCH §17.1).
///
/// See ARCH §17.1, ux.md §4.4, §4.6.
class EditorLauncher {
  /// Creates a launcher. Tests inject [fileExists], [fileSize], [playerOrigin] and the timings.
  EditorLauncher({
    required this.engine,
    required this.repository,
    required this.capabilities,
    required this.spaceCheck,
    this.access,
    Future<bool> Function(String path)? fileExists,
    Future<int?> Function(String path)? fileSize,
    Future<ProjectOrigin> Function(String pathOrUri, String displayName)? playerOrigin,
    this.checkTimeout = const Duration(milliseconds: 300),
    this.preparingDelay = const Duration(milliseconds: 300),
    TargetPlatform? platform,
  })  : _fileExists = fileExists ?? _defaultExists,
        _fileSize = fileSize ?? _defaultSize,
        _playerOrigin = playerOrigin,
        _platform = platform;

  /// The engine (compatibility pre-check).
  final EditorEngine engine;

  /// The project store (reuse or create).
  final ProjectRepository repository;

  /// Device capabilities (gate and `lowMemoryDevice`).
  final Future<EditorCapabilities> Function() capabilities;

  /// The free-space preflight and "will this be copied" decision (UX-06).
  final ImportSpaceCheck Function() spaceCheck;

  /// Fingerprints the played file for `FromPlayerOrigin`; null stores a plain Projects origin.
  final MediaAccessPort? access;

  /// Bound of each compatibility step (ARCH §17.1: 300 ms).
  final Duration checkTimeout;

  /// How long creating may take before "Preparing editor…" shows.
  final Duration preparingDelay;

  final Future<bool> Function(String path) _fileExists;
  final Future<int?> Function(String path) _fileSize;
  final Future<ProjectOrigin> Function(String pathOrUri, String displayName)? _playerOrigin;
  final TargetPlatform? _platform;

  bool _running = false;

  /// Whether a launch is running.
  bool get isRunning => _running;

  static Future<bool> _defaultExists(String path) => File(path).exists();

  static Future<int?> _defaultSize(String path) async {
    try {
      return await File(path).length();
    } on Object {
      return null;
    }
  }

  /// Runs the Edit flow for [request] (see the file header). Never throws; [player] is paused
  /// first and, once the editor opened, resumed when [openEditor] completes.
  Future<EditorLaunchOutcome> openFromPlayer(
    EditorLaunchRequest request,
    BuildContext context, {
    required PlayerHandoff player,
    required EditorRouteOpener openEditor,
  }) async {
    if (_running) return EditorLaunchOutcome.busy;
    _running = true;
    try {
      return await _run(request, context, player, openEditor);
    } on Object catch (e) {
      debugPrint('[EditorLauncher] Launch failed: ${e.runtimeType}');
      if (context.mounted) await _explainFailure(context, EditorFailures.fromError(e));
      return EditorLaunchOutcome.failed;
    } finally {
      _running = false;
    }
  }

  Future<EditorLaunchOutcome> _run(EditorLaunchRequest request, BuildContext context, PlayerHandoff player, EditorRouteOpener openEditor) async {
    final platform = _platform ?? Theme.of(context).platform;
    // 1. Pause.
    await _quietly(player.pause);
    final fileName = _fileNameOf(request);

    // 2. Device gate.
    EditorCapabilities? caps;
    try {
      caps = await capabilities();
    } on Object catch (e) {
      debugPrint('[EditorLauncher] Capabilities failed: ${e.runtimeType}');
    }
    if (caps == null || !caps.supported) {
      final reason = caps?.unsupportedReason ?? UnsupportedReasons.engineNotAvailable;
      if (context.mounted) {
        await _explain(context, title: LauncherStrings.unsupportedDeviceTitle, message: LauncherStrings.unsupportedDeviceMessage(reason));
      }
      return EditorLaunchOutcome.deviceUnsupported;
    }

    // 3. Compatibility pre-check (≤ 300 ms each).
    final path = ImportPolicy.pathOf(request.pathOrUri);
    final isContent = request.pathOrUri.startsWith('content://');
    if (!isContent) {
      final exists = path == null ? false : await _bounded(_fileExists(path), fallback: true);
      if (!exists) {
        if (context.mounted) player.showToast(LauncherStrings.missing);
        return EditorLaunchOutcome.fileMissing;
      }
    }
    final compat = await _bounded<EditCompatibility>(engine.compatibility(request.pathOrUri), fallback: const Editable());
    if (compat case NotEditable(:final code)) {
      if (code == EditCompatibilityCodes.notFound) {
        if (context.mounted) player.showToast(LauncherStrings.missing);
        return EditorLaunchOutcome.fileMissing;
      }
      if (context.mounted) {
        await _explain(
          context,
          title: LauncherStrings.notEditableTitle,
          message: LauncherStrings.notEditableMessage(code, platform: platform, fileName: fileName),
        );
      }
      return EditorLaunchOutcome.notEditable;
    }
    if (!context.mounted) return EditorLaunchOutcome.cancelled;

    // 4. Reuse or create.
    final at = request.position.isNegative ? 0 : request.position.inMicroseconds;
    final pick = PickedMedia(
      uri: request.pathOrUri,
      displayName: fileName,
      origin: MediaOrigin.player,
      sizeBytes: path == null ? null : await _fileSize(path),
    );
    var copies = false;
    try {
      copies = await spaceCheck().needsCopy(pick);
    } on Object catch (e) {
      debugPrint('[EditorLauncher] Copy decision failed: ${e.runtimeType}');
    }
    if (!context.mounted) return EditorLaunchOutcome.cancelled;

    final ProjectId id;
    if (copies) {
      final reused = await repository.findUntouchedProjectFor(request.pathOrUri);
      if (reused != null) {
        id = reused;
      } else {
        if (!context.mounted) return EditorLaunchOutcome.cancelled;
        final spec = await _specFor(request, pick, at);
        if (!context.mounted) return EditorLaunchOutcome.cancelled;
        final result = await showImportMediaSheet(
          context,
          picks: [pick],
          job: createProjectImportJob(repository: repository, spec: spec),
          title: LauncherStrings.copyTitle,
        );
        final created = result?.projectId;
        if (created == null) {
          final cancelled = result == null || result.job == null || (result.job?.cancelled ?? false);
          return cancelled ? EditorLaunchOutcome.cancelled : EditorLaunchOutcome.failed;
        }
        id = created;
      }
    } else {
      final prepared = await _withPreparing(context, () async {
        final reused = await repository.findUntouchedProjectFor(request.pathOrUri);
        if (reused != null) return reused;
        return repository.create(await _specFor(request, pick, at));
      });
      switch (prepared) {
        case _Prepared(:final value):
          id = value;
        case _PrepareFailed(:final error):
          if (context.mounted) await _explainFailure(context, _failureOf(error));
          return EditorLaunchOutcome.failed;
      }
    }

    // 5. Hand the decoders over.
    await _quietly(() => player.suspend(release: caps!.lowMemoryDevice));

    // 6. Open the editor; restore the player when it closes.
    try {
      await openEditor(id, at);
    } finally {
      await _quietly(player.resume);
    }
    return EditorLaunchOutcome.opened;
  }

  Future<FromMediaProjectSpec> _specFor(EditorLaunchRequest request, PickedMedia pick, TimeUs at) async {
    final origin = await _originOf(request.pathOrUri, pick.displayName);
    return FromMediaProjectSpec(picks: [pick], name: projectNameFor(request.title), initialPlayhead: at, origin: origin);
  }

  Future<ProjectOrigin> _originOf(String pathOrUri, String displayName) async {
    final custom = _playerOrigin;
    if (custom != null) return custom(pathOrUri, displayName);
    final port = access;
    if (port == null) return ProjectOrigin.projects;
    final MediaLocator locator;
    if (pathOrUri.startsWith('content://')) {
      locator = ContentUriLocator(pathOrUri);
    } else {
      final path = ImportPolicy.pathOf(pathOrUri);
      if (path == null) return ProjectOrigin.projects;
      locator = FileLocator(path);
    }
    try {
      final stat = await port.stat(locator);
      if (stat == null) return ProjectOrigin.projects;
      final hash = await port.quickHash(locator);
      return FromPlayerOrigin(quickHash: hash, sizeBytes: stat.sizeBytes, displayName: displayName);
    } on MediaAccessFailure {
      return ProjectOrigin.projects;
    }
  }

  /// The project name for a player title: trimmed, at most 80 characters, never empty.
  static String projectNameFor(String title) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return 'Untitled project';
    final chars = trimmed.characters;
    return chars.length <= 80 ? trimmed : chars.take(80).toString().trim();
  }

  static String _fileNameOf(EditorLaunchRequest request) {
    final path = ImportPolicy.pathOf(request.pathOrUri);
    if (path != null) {
      final slash = path.lastIndexOf('/');
      final name = slash < 0 ? path : path.substring(slash + 1);
      if (name.isNotEmpty) return name;
    }
    return request.title.trim().isEmpty ? 'Video' : request.title.trim();
  }

  Future<T> _bounded<T>(Future<T> future, {required T fallback}) async {
    try {
      return await future.timeout(checkTimeout);
    } on TimeoutException {
      future.ignore();
      return fallback;
    } on Object catch (e) {
      debugPrint('[EditorLauncher] Pre-check failed: ${e.runtimeType}');
      return fallback;
    }
  }

  static Future<void> _quietly(Future<void> Function() action) async {
    try {
      await action();
    } on Object catch (e) {
      debugPrint('[EditorLauncher] Player handoff step failed: ${e.runtimeType}');
    }
  }

  /// Runs [work]; when it takes longer than [preparingDelay], a non-dismissible "Preparing
  /// editor…" shows until it ends (and is closed before this returns).
  Future<_PrepareResult> _withPreparing(BuildContext context, Future<ProjectId> Function() work) async {
    final done = ValueNotifier<bool>(false);
    Future<void>? shown;
    final timer = Timer(preparingDelay, () {
      if (!context.mounted || done.value) return;
      shown = showVwishDialog<void>(
        context,
        barrierDismissible: false,
        builder: (_) => _PreparingView(done: done),
      );
    });
    _PrepareResult result;
    try {
      result = _Prepared(await work());
    } on Object catch (e) {
      result = _PrepareFailed(e);
    } finally {
      timer.cancel();
      done.value = true;
    }
    await shown;
    done.dispose();
    return result;
  }

  static EditorFailure _failureOf(Object error) => switch (error) {
        ProjectCreateFailure(:final outcomes) => ImportFailed(
            outcomes.whereType<ImportRejected>().map((r) => r.reason).firstOrNull ?? 'unsupported',
          ),
        _ => EditorFailures.fromError(error),
      };

  Future<void> _explainFailure(BuildContext context, EditorFailure failure) {
    final message = EditorMessages.forFailure(failure);
    return _explain(
      context,
      title: LauncherStrings.failedTitle,
      message: message.detail == null ? message.title : '${message.title} ${message.detail}',
    );
  }

  static Future<void> _explain(BuildContext context, {required String title, required String message}) => showVwishDialog<void>(
        context,
        builder: (dialogContext) => VwishDialog(
          icon: Icons.movie_edit,
          title: title,
          message: message,
          actions: [
            VwishButton.primary(label: LauncherStrings.ok, onPressed: () => Navigator.of(dialogContext).pop()),
          ],
        ),
      );
}

sealed class _PrepareResult {
  const _PrepareResult();
}

final class _Prepared extends _PrepareResult {
  const _Prepared(this.value);
  final ProjectId value;
}

final class _PrepareFailed extends _PrepareResult {
  const _PrepareFailed(this.error);
  final Object error;
}

/// The non-dismissible "Preparing editor…" wait; closes itself once [done] turns true.
class _PreparingView extends StatefulWidget {
  const _PreparingView({required this.done});

  final ValueListenable<bool> done;

  @override
  State<_PreparingView> createState() => _PreparingViewState();
}

class _PreparingViewState extends State<_PreparingView> {
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    widget.done.addListener(_onDone);
    _onDone();
  }

  @override
  void dispose() {
    widget.done.removeListener(_onDone);
    super.dispose();
  }

  void _onDone() {
    if (!widget.done.value || _closing) return;
    _closing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Semantics(
        liveRegion: true,
        child: VwishDialog(
          key: const ValueKey('editor-launcher-preparing'),
          content: Row(
            children: [
              const VwishSpinner(size: 24),
              const SizedBox(width: VwishSpacing.md),
              Expanded(
                child: Text(
                  LauncherStrings.preparing,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: VwishTextStyles.body,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The launcher the router uses: `ref.read(editorLauncherProvider).openFromPlayer(r, context,
/// player: …, openEditor: …)`.
///
/// See ARCH §17.1.
final editorLauncherProvider = Provider<EditorLauncher>((ref) {
  final repository = ref.watch(projectRepositoryProvider);
  final pool = ref.watch(mediaPoolServiceProvider);
  return EditorLauncher(
    engine: ref.watch(editorEngineProvider),
    repository: repository,
    capabilities: () => ref.read(editorCapabilitiesProvider.future),
    spaceCheck: () => ref.read(importSpaceCheckProvider),
    access: switch ((pool, repository)) {
      (final FileMediaPoolService p, _) => p.access,
      (_, final FileProjectRepository r) => r.access,
      _ => null,
    },
  );
}, name: 'editorLauncherProvider');
