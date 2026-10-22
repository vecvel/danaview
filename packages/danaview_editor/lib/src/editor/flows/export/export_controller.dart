// OWNER: UX-39
//
// The export controller (ARCH §14.1, ux.md §11, D-22, D-23, D-24, D-39, D-44).
//
// 1. `prepare()` runs the pre-checks in order: empty timeline (toast; the sheet does not open),
//    missing media (relink), pending reverse / freeze jobs (wait with progress, continues by
//    itself), then builds the setup from the project's last-used settings (remembered per project
//    in `EditorPrefs`).
// 2. `start()`: free space against the estimate (+ one segment on iOS), the first-export notice
//    (background copy and, on Android, the notification explainer and permission; the permission
//    request is bounded by `ExportEnvironment.notificationPermissionTimeout`, after which the export goes on without
//    notifications and the progress view says so once, UX-39), the sprite
//    pre-pass (API-04, "Preparing"), `compileExport` (CORE-33; original media only), the engine's
//    `preflight` (warnings the user confirms; with `layersVsResolution` the free-space check is
//    repeated with the multi-pass precompose intermediates added, `max(2·I, I + output) − output`,
//    D-45(B)) and `ExportService.start` (with `ExportStrings.notificationTexts`, so the Android
//    notification follows the app's copy, INT-07).
// 3. Progress at <= 4 Hz with phase, ETA after three samples, backgrounded copy per
//    `BackgroundExportKind`; cancel (the sheet confirms; the engine deletes the partial file);
//    the screen stays awake while it runs.
// 4. Completion: the first destination (Photos / Gallery by default, Files, Share), "Keep a copy in
//    Danaview" through `DocumentsExportWriter` only (D-44), SRT / VTT side files, Play in Danaview; the
//    temp file is deleted by `OwnedFileDeleter` when the card is left or the controller goes away.
// 5. Failures map to `EditorFailure` (`ExportFailed` kinds) with the fallbacks "Try again",
//    "Export with H.264", "Lower resolution" and "Free up space"; "Copy details" carries the
//    failure code and the settings, never paths.
// 6. `reattach()` after a relaunch or reopen: running -> progress, resumable -> "Resume export",
//    interrupted -> a one-shot notice, completed while detached -> a one-shot card (D-39).
// 7. FIX-QA05-D8-2: the files in use (running output, completion card's video and side files, a
//    finished-while-away file) are held in `ExportEnvironment.outputLeases`, so the export sweep
//    keeps them, and `ExportEnvironment.onJobEnded` runs the sweep after every job's terminal state.
//
// Editing is blocked while exporting (D-24) because the sheet is modal and not dismissible while the
// export runs; the controller itself never touches the project.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:danaview_editor_core/formats.dart' show SubtitleCodec, SubtitleCueData, SubtitleFormat;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/plan.dart';
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' hide MediaAccessFailure;

import '../../../app/editor_prefs.dart';
import '../../../app/editor_providers.dart';
import '../../../app/strings/export_strings.dart';
import '../../state/editor_session.dart';
import '../../state/editor_state.dart';
import 'export_environment.dart';
import 'export_state.dart';

export 'export_environment.dart' show ExportEnvironment, ExportHost, exportCapabilitiesOf, exportEnvironmentProvider, exportHostProvider;
export 'export_state.dart';

/// What `prepare()` found.
enum ExportPrepare {
  /// The setup is ready.
  ready,

  /// The timeline is empty: toast "Add a clip before exporting." and do not open the sheet.
  emptyTimeline,

  /// Media is missing: the sheet shows the relink step.
  needsRelink,

  /// Reverse or freeze jobs are running: the sheet waits.
  waiting,

  /// The project is not open or something unexpected failed (the state is `ExportUiFailed`).
  failed,
}

/// What `reattach()` found.
enum ExportReattach {
  /// Nothing to show.
  none,

  /// An export is running: the sheet shows its progress.
  running,

  /// An iOS export can be resumed.
  resumable,

  /// An export was interrupted (one-shot).
  interrupted,

  /// An export finished while Danaview was away (one-shot, D-39).
  finished,
}

/// Preflight warning codes that ask for a confirmation before the export starts.
const Set<String> exportBlockingWarnings = {'softwareEncoder', 'layersVsResolution', 'hevcUnavailable'};

/// The preflight warning that means the plan needs more decoders than the device sustains, so the
/// export may run the multi-pass precompose and its intermediates count in the disk check (D-45(B)).
const String precomposeWarning = 'layersVsResolution';

/// Pre-checks, settings, progress and handoff of an export (ARCH §14.1).
class ExportController extends StateNotifier<ExportUiState> {
  /// Creates the controller. [editorState] reads the editor's state (media health, background
  /// tasks), [listenEditor] subscribes to it while the controller waits for background jobs and
  /// [host] supplies the router's navigation callbacks.
  ExportController({
    required this.id,
    required EditorSession session,
    required EditorEngine engine,
    required EditorPrefs prefs,
    required ExportEnvironment Function() environment,
    required EditorState Function() editorState,
    VoidCallback Function(void Function(EditorState state) listener)? listenEditor,
    ExportHost Function()? host,
    ExportUiState initial = const ExportUiIdle(),
  })  : _session = session,
        _engine = engine,
        _prefs = prefs,
        _environment = environment,
        _editorState = editorState,
        _listenEditor = listenEditor,
        _host = host,
        super(initial);

  /// The project.
  final ProjectId id;

  final EditorSession _session;
  final EditorEngine _engine;
  final EditorPrefs _prefs;
  final ExportEnvironment Function() _environment;
  final EditorState Function() _editorState;
  final VoidCallback Function(void Function(EditorState state) listener)? _listenEditor;
  final ExportHost Function()? _host;

  ExportEnvironment? _env;
  ExportEnvironment get _e => _env ??= _environment();

  int _epoch = 0;
  bool _cancelRequested = false;
  bool _rechecking = false;
  VoidCallback? _unlistenEditor;

  ExportUiSetup? _lastSetup;
  ExportReady? _ready;
  EncodeSettings? _lastEncode;
  int? _maxHeightForPlan;
  ExportJob? _job;
  StreamSubscription<ExportProgress>? _progressSub;
  final List<(DateTime, double)> _samples = [];
  ExportDraft? _runDraft;
  EditProject? _runProject;
  String _runFileName = 'Danaview export';
  BackgroundExportKind _runKind = BackgroundExportKind.none;
  bool _notificationsUnanswered = false;
  String? _resumableJobId;
  bool _wakelockOn = false;
  bool _cleaned = false;
  String? _runOutput;

  /// The preferences key of the remembered settings of [id].
  static String draftKey(ProjectId id) => 'editor.export.last.${id.value}';

  TargetPlatform get _platform => _e.targetPlatform;

  // -----------------------------------------------------------------------------------------------
  // Pre-checks and setup
  // -----------------------------------------------------------------------------------------------

  /// Runs the pre-checks (ux.md §11.1) and shows the setup, the relink step or the wait.
  Future<ExportPrepare> prepare() async {
    if (!mounted) return ExportPrepare.failed;
    final epoch = ++_epoch;
    _stopListeningEditor();
    _set(const ExportUiIdle());
    try {
      final project = _session.committedProject;
      if (project == null || !_session.isOpen) {
        _set(const ExportUiFailed(UnknownFailure('notOpen')));
        return ExportPrepare.failed;
      }
      if (project.duration <= 0) return ExportPrepare.emptyTimeline;
      final caps = await _capabilities();
      if (!_live(epoch)) return ExportPrepare.failed;
      final limits = _limitsOf(caps, project);
      final draft = _sanitize(_loadDraft(project), limits);
      final blocked = await _requirements(project, draft.settings, limits.caps);
      if (!_live(epoch)) return ExportPrepare.failed;
      if (blocked.empty) return ExportPrepare.emptyTimeline;
      final offline = _offlineCount(blocked.requirements);
      if (offline > 0) {
        _set(ExportUiNeedsRelink(offline));
        return ExportPrepare.needsRelink;
      }
      final pending = blocked.requirements.pendingReverse.length + blocked.requirements.pendingStill.length;
      if (pending > 0) {
        _set(ExportUiWaiting(pending, progress: _jobProgress()));
        _listenForJobs();
        return ExportPrepare.waiting;
      }
      _set(_buildSetup(project, limits, draft));
      return ExportPrepare.ready;
    } on Object catch (e) {
      _fail(EditorFailures.fromError(e, context: EngineFailureContext.export));
      return ExportPrepare.failed;
    }
  }

  Future<_Blocking> _requirements(EditProject project, ExportSettings settings, ExportCapabilities caps) async {
    final resolver = await _e.resolveAssets(_session, project);
    final result = await _e.compile(ExportCompileInput(
      project: project,
      settings: settings,
      manifest: SpriteManifest.empty,
      resolver: resolver,
      capabilities: caps,
      spriteRequests: const [],
    ));
    return switch (result) {
      ExportBlocked() => _Blocking(result.requirements, empty: result.emptyTimeline),
      ExportReady() => _Blocking(PlanRequirements()),
    };
  }

  int _offlineCount(PlanRequirements r) {
    final ids = <String>{...r.offline};
    final health = _editorState().media;
    if (health.relinkRequired) ids.addAll(health.missing.map((m) => m.value));
    return ids.length;
  }

  double? _jobProgress() {
    final values = [
      for (final t in _editorState().tasks)
        if ((t.kind == EditorTaskKind.reverse || t.kind == EditorTaskKind.freeze) && t.progress != null) t.progress!,
    ];
    if (values.isEmpty) return null;
    return values.reduce((a, b) => a + b) / values.length;
  }

  void _listenForJobs() {
    final listen = _listenEditor;
    if (listen == null || _unlistenEditor != null) return;
    _unlistenEditor = listen(_onEditorState);
  }

  void _stopListeningEditor() {
    _unlistenEditor?.call();
    _unlistenEditor = null;
  }

  void _onEditorState(EditorState editor) {
    final s = state;
    if (s is! ExportUiWaiting) return;
    final progress = _jobProgress();
    if (progress != s.progress) _set(ExportUiWaiting(s.count, progress: progress));
    if (_rechecking) return;
    _rechecking = true;
    unawaited(_recheckWaiting().whenComplete(() => _rechecking = false));
  }

  Future<void> _recheckWaiting() async {
    if (!mounted || state is! ExportUiWaiting) return;
    final epoch = _epoch;
    try {
      final project = _session.committedProject;
      if (project == null) return;
      final caps = await _capabilities();
      final limits = _limitsOf(caps, project);
      final draft = _sanitize(_loadDraft(project), limits);
      final blocked = await _requirements(project, draft.settings, limits.caps);
      if (!_live(epoch) || state is! ExportUiWaiting) return;
      final offline = _offlineCount(blocked.requirements);
      final pending = blocked.requirements.pendingReverse.length + blocked.requirements.pendingStill.length;
      if (offline > 0) {
        _stopListeningEditor();
        _set(ExportUiNeedsRelink(offline));
      } else if (pending > 0) {
        final cur = state;
        if (cur is ExportUiWaiting && cur.count != pending) _set(ExportUiWaiting(pending, progress: _jobProgress()));
      } else {
        _stopListeningEditor();
        _set(_buildSetup(project, limits, draft));
      }
    } on Object catch (e) {
      if (mounted) {
        _stopListeningEditor();
        _fail(EditorFailures.fromError(e, context: EngineFailureContext.export));
      }
    }
  }

  Future<EditorCapabilities> _capabilities() async {
    final known = _session.capabilities;
    if (known != null) return known;
    try {
      return await _engine.capabilities();
    } on Object {
      return const EditorCapabilities(supported: true);
    }
  }

  ExportLimits _limitsOf(EditorCapabilities caps, EditProject project) {
    final export = exportCapabilitiesOf(caps);
    return ExportLimits(
      caps: export,
      hardwareH264: caps.hardwareH264,
      hardwareHevc: caps.hardwareHevc,
      backgroundKind: caps.backgroundKind,
      offer4kPreset: export.maxExportShortSide >= 2160 && export.maxExportLongSide >= 3840 && _sourceReaches4k(project),
    );
  }

  static bool _sourceReaches4k(EditProject project) {
    if (project.settings.canvas.baseShortSide >= 2160) return true;
    for (final a in project.pool.assets.values) {
      final w = a.probe.width ?? 0;
      final h = a.probe.height ?? 0;
      if ((w > h ? w : h) >= 3840) return true;
    }
    return false;
  }

  ExportDraft _loadDraft(EditProject project) {
    final saved = ExportDraft.tryParse(_prefs.readString(draftKey(id)));
    if (saved != null) return saved;
    final preset = ExportPresetId.values.where((e) => e.name == project.view.lastExportPresetId).firstOrNull;
    return ExportDraft(settings: ExportSettings(preset: preset ?? ExportPresetId.youtube));
  }

  /// A draft that only uses what [limits] offer.
  ExportDraft _sanitize(ExportDraft draft, ExportLimits limits) {
    var s = draft.settings;
    if (s.preset == ExportPresetId.youtube4k && !limits.offer4kPreset) s = s.copyWith(preset: ExportPresetId.youtube);
    if (s.container == ExportContainer.mov && !limits.canMov) s = s.copyWith(container: ExportContainer.mp4);
    if (s.codec == VideoCodec.hevc && !limits.canHevc) s = s.copyWith(codec: VideoCodec.h264);
    final sizes = limits.shortSides;
    if (sizes.isNotEmpty && !sizes.contains(s.shortSide)) {
      s = s.copyWith(shortSide: sizes.lastWhere((v) => v <= s.shortSide, orElse: () => sizes.first));
    }
    final fps = s.fps;
    if (fps != null && !limits.fpsOptions(s.shortSide).contains(fps)) s = s.copyWith(fps: null);
    return draft.copyWith(settings: s);
  }

  ExportUiSetup _buildSetup(EditProject project, ExportLimits limits, ExportDraft draft, {ExportIssue? issue}) {
    final setup = ExportUiSetup(
      draft: draft,
      resolved: resolveExportSettings(project, draft.settings, capabilities: limits.caps),
      limits: limits,
      projectAspect: project.settings.canvas.aspect,
      subtitleTracks: _subtitleTracks(project, draft.settings),
      issue: issue,
    );
    _lastSetup = setup;
    return setup;
  }

  List<ExportSubtitleTrack> _subtitleTracks(EditProject project, ExportSettings settings) => [
        for (final track in project.timeline.tracks)
          if (track.kind == TrackKind.subtitle && track.subtitle != null && track.items.isNotEmpty)
            ExportSubtitleTrack(
              id: track.id,
              name: track.name.isEmpty ? 'Captions' : track.name,
              language: track.subtitle!.language,
              burnIn: settings.burnInSubtitles[track.id] ?? track.subtitle!.burnIn,
              cueCount: track.items.length,
            ),
      ];

  // -----------------------------------------------------------------------------------------------
  // Editing the draft
  // -----------------------------------------------------------------------------------------------

  /// Selects [preset]; Custom starts from the current resolution.
  void selectPreset(ExportPresetId preset) {
    final s = state;
    if (s is! ExportUiSetup || s.draft.settings.preset == preset) return;
    var settings = s.draft.settings.copyWith(preset: preset);
    if (preset == ExportPresetId.custom) {
      final current = s.resolved.encode;
      final short = current.width < current.height ? current.width : current.height;
      final sizes = s.limits.shortSides;
      final pick = sizes.contains(short) ? short : (sizes.isEmpty ? 1080 : sizes.lastWhere((v) => v <= short, orElse: () => sizes.first));
      settings = settings.copyWith(shortSide: pick, fps: null, codec: s.resolved.encode.codec, container: s.resolved.encode.container);
    }
    _updateSetup(s, s.draft.copyWith(settings: settings));
  }

  /// Edits the settings (custom values, quality, side files, burn-in).
  void updateSettings(ExportSettings Function(ExportSettings settings) update) {
    final s = state;
    if (s is! ExportUiSetup) return;
    var next = update(s.draft.settings);
    final fps = next.fps;
    if (fps != null && !s.limits.fpsOptions(next.shortSide).contains(fps)) next = next.copyWith(fps: null);
    _updateSetup(s, s.draft.copyWith(settings: next));
  }

  /// Chooses where the video goes first.
  void setDestination(ExportDestination destination) {
    final s = state;
    if (s is! ExportUiSetup || s.draft.destination == destination) return;
    _updateSetup(s, s.draft.copyWith(destination: destination));
  }

  /// Turns "Keep a copy in Danaview" on or off.
  void setKeepCopy(bool on) {
    final s = state;
    if (s is! ExportUiSetup || s.draft.keepCopy == on) return;
    _updateSetup(s, s.draft.copyWith(keepCopy: on));
  }

  /// Burns subtitle track [track] into the video or not.
  void setBurnIn(TrackId track, bool on) => updateSettings((s) => s.copyWith(burnInSubtitles: {...s.burnInSubtitles, track: on}));

  /// Writes a [format] side file next to the export or not.
  void setSideFile(SideFileFormat format, bool on) =>
      updateSettings((s) => s.copyWith(sideFiles: on ? {...s.sideFiles, format} : ({...s.sideFiles}..remove(format))));

  void _updateSetup(ExportUiSetup current, ExportDraft draft) {
    final project = _session.committedProject;
    if (project == null) return;
    final next = _buildSetup(project, current.limits, draft);
    _set(next);
    _remember(draft);
  }

  void _remember(ExportDraft draft) {
    unawaited(_prefs.writeString(draftKey(id), draft.toJsonString()).catchError((Object e) {
      debugPrint('[Export] Could not remember the settings: ${e.runtimeType}');
    }));
  }

  // -----------------------------------------------------------------------------------------------
  // Start
  // -----------------------------------------------------------------------------------------------

  /// The Export button: storage check, first-export notice, pre-pass, compile, preflight, start.
  Future<void> start() async {
    final s = state;
    if (s is! ExportUiSetup || s.checkingStorage) return;
    await _begin(s);
  }

  Future<void> _begin(ExportUiSetup setup, {bool noticeDone = false}) async {
    final epoch = ++_epoch;
    _cancelRequested = false;
    _notificationsUnanswered = false;
    _lastSetup = setup;
    _remember(setup.draft);
    _set(setup.copyWith(checkingStorage: true, clearIssue: true));
    try {
      final issue = await _storageIssue(setup);
      if (!_live(epoch)) return;
      if (issue != null) {
        _set(setup.copyWith(issue: issue, checkingStorage: false));
        return;
      }
      final kind = setup.limits.backgroundKind;
      if (!noticeDone && !_prefs.exportBackgroundNoticeShown && kind != BackgroundExportKind.continued) {
        _set(ExportUiNotice(
          setup: setup.copyWith(checkingStorage: false),
          kind: kind,
          explainNotifications: kind == BackgroundExportKind.foregroundService && !_prefs.exportNotificationPermissionAsked,
        ));
        return;
      }
      await _prepareAndStart(setup.copyWith(checkingStorage: false), epoch);
    } on Object catch (e) {
      if (_live(epoch)) await _failExport(e, live: () => _live(epoch));
    }
  }

  /// Free space against the estimate (+ one 10 s segment on iOS) + [extraBytes] (the multi-pass
  /// precompose intermediates, D-45(B)).
  Future<ExportIssue?> _storageIssue(ExportUiSetup setup, {int extraBytes = 0}) async {
    final encode = setup.resolved.encode;
    var needed = setup.resolved.estimatedBytes + extraBytes;
    if (_platform == TargetPlatform.iOS) needed += (encode.videoBitrate * 10 / 8).round(); // one 10 s segment (§14.2)
    final int free;
    await _e.ensureWorkDir();
    try {
      free = await _engine.freeBytes(_e.workDir);
    } on Object {
      return null; // the engine could not tell: let the export try
    }
    return free < needed ? ExportIssue(ExportIssueKind.lowStorage, neededBytes: needed, freeBytes: free) : null;
  }

  /// Continues from the first-export notice: marks it shown and, on Android, asks for the
  /// notification permission in context (a refusal does not stop the export).
  Future<void> confirmNotice() async {
    final s = state;
    if (s is! ExportUiNotice) return;
    final epoch = ++_epoch;
    _set(const ExportUiPreparing());
    await _prefs.markExportBackgroundNoticeShown();
    _notificationsUnanswered = false;
    if (s.explainNotifications) {
      await _prefs.markExportNotificationPermissionAsked();
      try {
        await _engine.access.requestNotificationPermission().timeout(_e.notificationPermissionTimeout);
      } on TimeoutException {
        // Nobody answered the system dialog (or the platform never reported back): export without
        // notifications rather than wait forever; a late answer is ignored.
        debugPrint('[Export] Notification permission unanswered after ${_e.notificationPermissionTimeout.inSeconds} s; exporting without notifications');
        _notificationsUnanswered = true;
      } on Object catch (e) {
        debugPrint('[Export] Notification permission request failed: ${e.runtimeType}');
      }
    }
    if (!_live(epoch)) return;
    try {
      await _prepareAndStart(s.setup, epoch);
    } on Object catch (e) {
      if (_live(epoch)) await _failExport(e, live: () => _live(epoch));
    }
  }

  /// Back from the notice or the warnings to the setup.
  void backToSetup() {
    final s = state;
    final setup = switch (s) {
      ExportUiNotice(:final setup) => setup,
      ExportUiWarnings(:final setup) => setup,
      ExportUiFailed() => _lastSetup,
      _ => null,
    };
    if (setup == null) return;
    _epoch++;
    _ready = null;
    _set(setup.copyWith(checkingStorage: false, clearIssue: true));
  }

  Future<void> _prepareAndStart(ExportUiSetup setup, int epoch) async {
    final project = _session.committedProject;
    if (project == null) {
      _fail(const UnknownFailure('notOpen'));
      return;
    }
    _set(const ExportUiPreparing());
    final caps = await _capabilities();
    final limits = setup.limits;
    final settings = setup.draft.settings;
    final runner = _e.spriteRunner(caps);
    final requests = exportSpriteRequests(project, settings, capabilities: limits.caps, metrics: runner.metrics);
    SpriteManifest manifest = SpriteManifest.empty;
    if (requests.isNotEmpty) {
      try {
        manifest = await runner.run(
          requests,
          cacheDir: _e.spritesDir,
          onProgress: (f) {
            if (_live(epoch) && state is ExportUiPreparing && !_cancelRequested) _set(ExportUiPreparing(fraction: f));
          },
          isCancelled: () => !_live(epoch) || _cancelRequested,
        );
      } on SpritePrepassCancelled {
        if (mounted) _backToSetupAfterCancel(setup);
        return;
      }
    }
    if (!_live(epoch)) return;
    if (_cancelRequested) {
      _backToSetupAfterCancel(setup);
      return;
    }
    final resolver = await _e.resolveAssets(_session, project);
    final result = await _e.compile(ExportCompileInput(
      project: project,
      settings: settings,
      manifest: manifest,
      resolver: resolver,
      capabilities: limits.caps,
      spriteRequests: requests,
    ));
    if (!_live(epoch)) return;
    switch (result) {
      case ExportBlocked(:final emptyTimeline, :final requirements, :final missingSprites):
        if (emptyTimeline) {
          _set(setup);
        } else if (_offlineCount(requirements) > 0) {
          _set(ExportUiNeedsRelink(_offlineCount(requirements)));
        } else if (requirements.pendingReverse.isNotEmpty || requirements.pendingStill.isNotEmpty) {
          _set(ExportUiWaiting(requirements.pendingReverse.length + requirements.pendingStill.length, progress: _jobProgress()));
          _listenForJobs();
        } else {
          debugPrint('[Export] ${missingSprites.length} sprites missing after the pre-pass');
          _fail(const UnknownFailure('sprites'));
        }
      case ExportReady():
        await _preflight(result, setup, epoch);
    }
  }

  Future<void> _preflight(ExportReady ready, ExportUiSetup setup, int epoch) async {
    _lastEncode = ready.encode;
    final preflight = await _engine.exporter.preflight(ready.plan, ready.encode);
    if (!_live(epoch)) return;
    _maxHeightForPlan = preflight.maxHeightForPlan;
    if (!preflight.ok) {
      _fail(const ExportFailed(ExportFailureKind.encoderSizeLimit));
      return;
    }
    if (preflight.warnings.any((w) => w.code == precomposeWarning)) {
      // The engine may run the multi-pass precompose (D-45(B)): its intermediates need room on
      // the work volume too (ARCH §14.1 step 5 "counted in the disk check").
      final issue = await _storageIssue(setup, extraBytes: ready.precomposeExtraBytes);
      if (!_live(epoch)) return;
      if (issue != null) {
        _set(setup.copyWith(issue: issue, checkingStorage: false));
        return;
      }
    }
    final blocking = [for (final w in preflight.warnings) if (exportBlockingWarnings.contains(w.code)) w];
    _ready = ready;
    if (blocking.isNotEmpty) {
      _set(ExportUiWarnings(setup: setup, warnings: blocking));
      return;
    }
    await _startJob(ready, setup, epoch);
  }

  /// Continues after the user accepted the preflight warnings.
  Future<void> confirmWarnings() async {
    final s = state;
    final ready = _ready;
    if (s is! ExportUiWarnings || ready == null) return;
    final epoch = ++_epoch;
    _set(const ExportUiPreparing());
    try {
      await _startJob(ready, s.setup, epoch);
    } on Object catch (e) {
      if (_live(epoch)) await _failExport(e, live: () => _live(epoch));
    }
  }

  Future<void> _startJob(ExportReady ready, ExportUiSetup setup, int epoch) async {
    final project = _session.committedProject;
    final draft = setup.draft;
    final ext = ready.encode.container == ExportContainer.mov ? 'mov' : 'mp4';
    final token = _e.newToken();
    await _e.ensureWorkDir();
    final outputPath = p.join(_e.workDir, 'export-$token.$ext');
    _runOutput = outputPath;
    _syncLeases();
    final title = project?.name ?? 'Danaview export';
    final job = await _engine.exporter.start(
      ready.plan,
      ready.encode,
      outputPath: outputPath,
      title: title,
      whenDetached: draft.destination == ExportDestination.photos ? ExportDetachedHandoff.saveToGallery : ExportDetachedHandoff.keepForLater,
      notificationTexts: ExportStrings.notificationTexts,
    );
    _ready = null;
    if (!_live(epoch)) {
      // Closed while starting: the engine keeps running natively and is reattached later (D-39).
      return;
    }
    _runDraft = draft;
    _runProject = project;
    _runFileName = _friendlyName(title, ext);
    _runKind = setup.limits.backgroundKind;
    _attach(job);
  }

  void _attach(ExportJob job) {
    _job = job;
    _cleaned = false;
    _samples.clear();
    _setWakelock(true);
    _set(ExportUiRunning(phase: ExportPhase.preparing, fraction: 0, backgroundKind: _runKind, notificationsUnanswered: _notificationsUnanswered));
    _progressSub?.cancel();
    _progressSub = job.progress.listen(_onProgress, onError: (Object _) {});
    unawaited(job.result.then(_onResult, onError: (Object e) => _onJobError(e)));
  }

  void _onProgress(ExportProgress p) {
    if (!mounted || _job == null) return;
    if (state is! ExportUiRunning) return;
    final now = _e.now();
    if (p.pausedInBackground) {
      _samples.clear();
    } else {
      _samples.add((now, p.fraction));
      if (_samples.length > 8) _samples.removeAt(0);
    }
    _set(ExportUiRunning(
      phase: p.phase,
      fraction: p.fraction.clamp(0.0, 1.0),
      framesDone: p.framesDone,
      framesTotal: p.framesTotal,
      backgrounded: p.backgrounded,
      pausedInBackground: p.pausedInBackground,
      eta: p.pausedInBackground ? null : _eta(),
      warnings: p.warnings,
      backgroundKind: _runKind,
      notificationsUnanswered: _notificationsUnanswered,
    ));
  }

  /// Time left once three samples show progress: remaining fraction over the observed rate.
  Duration? _eta() {
    if (_samples.length < 3) return null;
    final first = _samples.first;
    final last = _samples.last;
    final dt = last.$1.difference(first.$1).inMicroseconds / 1e6;
    final df = last.$2 - first.$2;
    if (dt <= 0 || df <= 0 || last.$2 >= 1) return null;
    final seconds = (1 - last.$2) / (df / dt);
    if (!seconds.isFinite) return null;
    return Duration(seconds: seconds.ceil());
  }

  Future<void> _onResult(ExportResult result) async {
    _job = null;
    _notificationsUnanswered = false;
    _setWakelock(false);
    unawaited(_progressSub?.cancel());
    _progressSub = null;
    if (!mounted) {
      await _deleteQuietly(result.path);
      _jobEnded();
      return;
    }
    await _complete(result);
    _jobEnded();
  }

  void _onJobError(Object e) {
    final job = _job;
    _job = null;
    _notificationsUnanswered = false;
    _setWakelock(false);
    unawaited(_progressSub?.cancel());
    _progressSub = null;
    _jobEnded();
    if (!mounted || job == null) return;
    if (e is EngineCancelled || (e is EngineFailure && e.code == EngineErrorCode.cancelled)) {
      _set(const ExportUiCancelled());
      return;
    }
    unawaited(_failExport(e));
  }

  // -----------------------------------------------------------------------------------------------
  // Cancel, resume, retry
  // -----------------------------------------------------------------------------------------------

  /// Cancels the export (the sheet already confirmed when a job is running): the job deletes its
  /// partial file and the state becomes [ExportUiCancelled]; while preparing it returns to the setup.
  Future<void> cancel() async {
    final s = state;
    if (s is ExportUiPreparing) {
      _cancelRequested = true;
      _set(ExportUiPreparing(fraction: s.fraction, cancelling: true));
      return;
    }
    final job = _job;
    if (s is! ExportUiRunning || job == null) return;
    _set(const ExportUiCancelling());
    try {
      await job.cancel();
    } on Object catch (e) {
      if (mounted && state is ExportUiCancelling) {
        _job = null;
        _setWakelock(false);
        _fail(EditorFailures.fromError(e, context: EngineFailureContext.export));
      }
    }
  }

  void _backToSetupAfterCancel(ExportUiSetup setup) {
    _cancelRequested = false;
    _set(setup.copyWith(checkingStorage: false, clearIssue: true));
  }

  /// Resumes an iOS segment-resumable job (D-22).
  Future<void> resume() async {
    final s = state;
    if (s is! ExportUiInterrupted || !s.canResume) return;
    final jobId = s.jobId!;
    final epoch = ++_epoch;
    _set(const ExportUiPreparing());
    try {
      final job = await _engine.exporter.resume(jobId);
      if (!_live(epoch)) return;
      _loadRunContext();
      _attach(job);
    } on Object catch (e) {
      if (_live(epoch)) await _failExport(e, live: () => _live(epoch));
    }
  }

  /// Back to the setup after an interrupted export ("Start again"); one-shot records are consumed.
  Future<void> startAgain() async {
    final jobId = _resumableJobId;
    if (state is ExportUiInterrupted) await _consume(jobId);
    await prepare();
  }

  /// "Try again" after a failure: the same setup runs again.
  Future<void> retry() async {
    final setup = _lastSetup;
    if (state is! ExportUiFailed) return;
    if (setup == null) {
      await prepare();
      return;
    }
    await _begin(setup.copyWith(checkingStorage: false, clearIssue: true), noticeDone: true);
  }

  /// "Export with H.264": the same size and frame rate as Custom with H.264, started right away.
  Future<void> exportWithH264() async {
    final setup = _lastSetup;
    if (setup == null || state is! ExportUiFailed) return;
    final project = _session.committedProject;
    if (project == null) return;
    final settings = _customEquivalent(setup, codec: VideoCodec.h264);
    final next = _buildSetup(project, setup.limits, setup.draft.copyWith(settings: settings));
    _remember(next.draft);
    await _begin(next, noticeDone: true);
  }

  /// "Lower resolution": the next smaller size the encoder supports, back in the setup.
  void lowerResolution() {
    final cur = state;
    final setup = cur is ExportUiSetup ? cur : _lastSetup;
    if (setup == null) return;
    final project = _session.committedProject;
    if (project == null) return;
    final failed = state is ExportUiFailed;
    final encode = failed ? (_lastEncode ?? setup.resolved.encode) : setup.resolved.encode;
    final current = encode.width < encode.height ? encode.width : encode.height;
    final max = failed ? (_maxHeightForPlan ?? current) : current;
    final sizes = setup.limits.shortSides;
    final lower = sizes.where((s) => s < current && s <= max).toList();
    final target = lower.isEmpty ? (sizes.isEmpty ? 720 : sizes.first) : lower.last;
    final settings = _customEquivalent(setup, shortSide: target);
    final next = _buildSetup(project, setup.limits, setup.draft.copyWith(settings: settings));
    _remember(next.draft);
    _set(next);
  }

  /// The settings of [setup] as Custom (what a preset resolved to) with some fields replaced.
  ExportSettings _customEquivalent(ExportUiSetup setup, {VideoCodec? codec, int? shortSide}) {
    final encode = setup.resolved.encode;
    final short = encode.width < encode.height ? encode.width : encode.height;
    final fps = const [24, 25, 30, 48, 50, 60].contains(encode.fps) ? encode.fps : null;
    final s = setup.draft.settings;
    final wasCustom = s.preset == ExportPresetId.custom;
    return ExportSettings(
      preset: ExportPresetId.custom,
      shortSide: shortSide ?? (const [720, 1080, 1440, 2160].contains(short) ? short : s.shortSide),
      fps: wasCustom ? s.fps : fps,
      container: encode.container,
      codec: codec ?? encode.codec,
      quality: s.quality,
      videoBitrateMbps: wasCustom ? s.videoBitrateMbps : null,
      audioBitrateKbps: encode.audioBitrate ~/ 1000,
      burnInSubtitles: s.burnInSubtitles,
      sideFiles: s.sideFiles,
    );
  }

  /// The "Copy details" text of [failure]: the code and the encode settings, never paths.
  String detailsOf(EditorFailure failure) {
    final e = _lastEncode;
    final settings = e == null
        ? ''
        : '\n${e.width}x${e.height} ${e.fps}fps ${e.codec.name} ${e.container.name} '
            'video ${e.videoBitrate ~/ 1000}kbps audio ${e.audioBitrate ~/ 1000}kbps';
    return 'Danaview export: ${failure.code}$settings';
  }

  // -----------------------------------------------------------------------------------------------
  // Completion and handoff
  // -----------------------------------------------------------------------------------------------

  Future<void> _complete(ExportResult result) async {
    final draft = _runDraft ?? ExportDraft(settings: ExportSettings());
    ExportUiCompleted completed = ExportUiCompleted(
      result: result,
      fileName: _runFileName,
      destination: draft.destination,
      handoff: ExportHandoffStatus.pending,
      busy: true,
      playablePath: result.path,
    );
    _set(completed);
    final sides = await _writeSideFiles(draft.settings, result.path);
    if (!mounted) return;
    completed = completed.copyWith(sideFiles: sides);
    _set(completed);

    final (status, failure) = await _handoffTo(draft.destination, result.path, _runFileName);
    if (!mounted) return;
    completed = completed.copyWith(
      handoff: status,
      savedToLibrary: status == ExportHandoffStatus.saved && draft.destination == ExportDestination.photos,
      handoffFailure: failure,
    );
    _set(completed);

    if (draft.keepCopy) {
      completed = await _keepCopy(completed, sides);
      if (!mounted) return;
    }
    _set(completed.copyWith(busy: false));
  }

  Future<(ExportHandoffStatus, EditorFailure?)> _handoffTo(ExportDestination destination, String path, String name) async {
    try {
      final files = _engine.files;
      final r = switch (destination) {
        ExportDestination.photos => await files.saveToPhotos(path),
        ExportDestination.files => await files.saveToFiles(path, name),
        ExportDestination.share => await files.share(path),
      };
      return switch (r.outcome) {
        FileHandoffOutcome.done => (ExportHandoffStatus.saved, null),
        FileHandoffOutcome.cancelled => (ExportHandoffStatus.notSaved, null),
        FileHandoffOutcome.denied => (
            ExportHandoffStatus.denied,
            destination == ExportDestination.photos
                ? const PermissionDenied(EditorPermission.photosAdd)
                : const ExportFailed(ExportFailureKind.destinationDenied),
          ),
        FileHandoffOutcome.failed => (ExportHandoffStatus.failed, const ExportFailed(ExportFailureKind.destinationDenied)),
      };
    } on Object catch (e) {
      return (ExportHandoffStatus.failed, EditorFailures.fromError(e, context: EngineFailureContext.export));
    }
  }

  Future<ExportUiCompleted> _keepCopy(ExportUiCompleted completed, List<ExportSideFile> sides) async {
    String? keptName;
    String? playable;
    var failed = false;
    try {
      final kept = await _e.documentsWriter.keepCopy(completed.result.path, fileName: completed.fileName);
      keptName = p.basename(kept);
      playable = kept;
    } on Object catch (e) {
      failed = true;
      debugPrint('[Export] Keep a copy failed: ${e.runtimeType}');
    }
    for (final side in sides) {
      try {
        await _e.documentsWriter.keepCopy(side.path, fileName: side.name);
      } on Object catch (e) {
        debugPrint('[Export] Keep a caption copy failed: ${e.runtimeType}');
      }
    }
    return completed.copyWith(keptCopyName: keptName, keepCopyFailed: failed, playablePath: playable);
  }

  /// Writes the SRT / VTT side files of the run's project into the work folder.
  Future<List<ExportSideFile>> _writeSideFiles(ExportSettings settings, String exportPath) async {
    await _e.ensureWorkDir();
    final project = _runProject;
    if (project == null || settings.sideFiles.isEmpty) return const [];
    final out = <ExportSideFile>[];
    final used = <String>{};
    final stem = p.basenameWithoutExtension(exportPath);
    var n = 0;
    for (final track in project.timeline.tracks) {
      final data = track.subtitle;
      if (track.kind != TrackKind.subtitle || data == null || track.items.isEmpty) continue;
      final cues = [
        for (final item in track.items)
          if (item is SubtitleCue) SubtitleCueData(item.start, item.end, item.text),
      ];
      for (final format in SideFileFormat.values) {
        if (!settings.sideFiles.contains(format)) continue;
        final codecFormat = format == SideFileFormat.srt ? SubtitleFormat.srt : SubtitleFormat.vtt;
        var name = SubtitleCodec.suggestedFileName(project.name, data.language ?? 'und', codecFormat);
        for (var k = 2; used.contains(name); k++) {
          final ext = p.extension(name);
          name = '${p.basenameWithoutExtension(name)} ($k)$ext';
        }
        used.add(name);
        final path = p.join(_e.workDir, '$stem-captions-${n++}.${format.name}');
        try {
          await _e.fs.writeBytesSynced(path, SubtitleCodec.serialize(cues, codecFormat));
          out.add(ExportSideFile(name: name, path: path, format: format));
        } on Object catch (e) {
          debugPrint('[Export] Could not write a caption file: ${e.runtimeType}');
        }
      }
    }
    return out;
  }

  /// Hands the finished video to Photos / Gallery.
  Future<void> saveToLibrary() => _redo(ExportDestination.photos);

  /// Hands the finished video to Files.
  Future<void> saveToFiles() => _redo(ExportDestination.files);

  /// Shares the finished video.
  Future<void> share() => _redo(ExportDestination.share);

  Future<void> _redo(ExportDestination destination) async {
    final s = state;
    if (s is! ExportUiCompleted || s.busy) return;
    _set(s.copyWith(busy: true, clearFailure: true));
    final (status, failure) = await _handoffTo(destination, s.result.path, s.fileName);
    if (!mounted) return;
    final cur = state;
    if (cur is! ExportUiCompleted) return;
    _set(cur.copyWith(
      busy: false,
      destination: destination,
      handoff: status == ExportHandoffStatus.saved || cur.handoff != ExportHandoffStatus.saved ? status : cur.handoff,
      savedToLibrary: cur.savedToLibrary || (status == ExportHandoffStatus.saved && destination == ExportDestination.photos),
      handoffFailure: failure,
      clearFailure: failure == null,
    ));
  }

  /// Hands one caption side file to Files.
  Future<void> saveSideFile(int index) async {
    final s = state;
    if (s is! ExportUiCompleted || s.busy || index < 0 || index >= s.sideFiles.length) return;
    final file = s.sideFiles[index];
    _set(s.copyWith(busy: true));
    final (status, _) = await _handoffTo(ExportDestination.files, file.path, file.name);
    if (!mounted) return;
    final cur = state;
    if (cur is! ExportUiCompleted) return;
    final list = [...cur.sideFiles];
    if (index < list.length && status == ExportHandoffStatus.saved) list[index] = list[index].asSaved();
    _set(cur.copyWith(busy: false, sideFiles: list));
  }

  /// Plays the exported file through the router (the kept copy when there is one).
  Future<void> play() async {
    final s = state;
    final path = s is ExportUiCompleted ? s.playablePath : null;
    final play = _host?.call().onPlay;
    if (path == null || play == null) return;
    await play(path);
  }

  /// Leaves the completion card: deletes the temporary files (`OwnedFileDeleter`, D-44).
  Future<void> done() async {
    final s = state;
    if (s is! ExportUiCompleted) return;
    await _cleanup(s);
  }

  Future<void> _cleanup(ExportUiCompleted s) async {
    if (_cleaned) return;
    _cleaned = true;
    await _deleteQuietly(s.result.path);
    for (final side in s.sideFiles) {
      await _deleteQuietly(side.path);
    }
    _syncLeases();
  }

  Future<void> _deleteQuietly(String path) async {
    try {
      await _e.deleter.delete(path);
    } on Object catch (e) {
      debugPrint('[Export] Could not delete a temporary file: ${e.runtimeType}');
    }
  }

  /// Opens the router's Settings › Storage, when it supplied the callback.
  Future<void> freeUpSpace() async => _host?.call().onFreeUpSpace?.call();

  /// Opens the system settings, when the router supplied the callback.
  Future<void> openSettings() async => _host?.call().onOpenSettings?.call();

  /// Whether the router can open Settings › Storage.
  bool get canFreeUpSpace => _host?.call().onFreeUpSpace != null;

  /// Whether the router can open the system settings.
  bool get canOpenSettings => _host?.call().onOpenSettings != null;

  /// Whether the router can play a file.
  bool get canPlay => _host?.call().onPlay != null;

  // -----------------------------------------------------------------------------------------------
  // Reattach (D-22, D-39)
  // -----------------------------------------------------------------------------------------------

  /// Looks for an export that survived the editor closing: running -> progress, resumable ->
  /// "Resume export", interrupted -> a one-shot notice, completed while detached -> a one-shot card.
  Future<ExportReattach> reattach() async {
    if (!mounted) return ExportReattach.none;
    final List<ExportJobState> jobs;
    try {
      jobs = await _engine.exporter.activeJobs();
    } on Object catch (e) {
      debugPrint('[Export] activeJobs failed: ${e.runtimeType}');
      return ExportReattach.none;
    }
    if (!mounted || state is ExportUiRunning || state is ExportUiCompleted) return ExportReattach.none;
    ExportJobState? pick<T extends ExportJobState>() => jobs.whereType<T>().firstOrNull;
    final running = pick<ExportRunning>();
    if (running is ExportRunning) {
      _loadRunContext();
      _attach(running.job);
      return ExportReattach.running;
    }
    final resumable = pick<ExportResumable>();
    if (resumable is ExportResumable) {
      _resumableJobId = resumable.jobId;
      _set(ExportUiInterrupted(jobId: resumable.jobId, doneFraction: resumable.doneFraction));
      return ExportReattach.resumable;
    }
    final finished = pick<ExportCompletedWhileDetached>();
    if (finished is ExportCompletedWhileDetached) {
      _loadRunContext();
      _set(ExportUiFinishedAway(jobId: finished.jobId, result: finished.result, savedToGallery: finished.savedToGallery));
      return ExportReattach.finished;
    }
    final interrupted = pick<ExportInterrupted>();
    if (interrupted is ExportInterrupted) {
      _resumableJobId = interrupted.jobId;
      _set(const ExportUiInterrupted());
      return ExportReattach.interrupted;
    }
    return ExportReattach.none;
  }

  void _loadRunContext() {
    final project = _session.committedProject;
    _runProject = project;
    _runDraft = ExportDraft.tryParse(_prefs.readString(draftKey(id))) ?? ExportDraft(settings: ExportSettings());
    _runFileName = _friendlyName(project?.name ?? 'Danaview export', 'mp4');
    _runKind = _session.capabilities?.backgroundKind ?? BackgroundExportKind.none;
  }

  Future<void> _consume(String? jobId) async {
    if (jobId == null) return;
    try {
      await _engine.exporter.consumeJobRecord(jobId);
    } on Object catch (e) {
      debugPrint('[Export] consumeJobRecord failed: ${e.runtimeType}');
    }
  }

  /// Marks a one-shot record as seen (call when its card is dismissed).
  Future<void> acknowledgeRecord() async {
    final s = state;
    if (s is ExportUiFinishedAway) {
      await _consume(s.jobId);
    } else if (s is ExportUiInterrupted && !s.canResume) {
      await _consume(_resumableJobId);
    }
  }

  /// Shares the file of a finished-while-away export.
  Future<void> shareFinished() => _finishedHandoff(ExportDestination.share);

  /// Saves the file of a finished-while-away export to Files.
  Future<void> saveFinishedToFiles() => _finishedHandoff(ExportDestination.files);

  Future<void> _finishedHandoff(ExportDestination destination) async {
    final s = state;
    final result = s is ExportUiFinishedAway ? s.result : null;
    if (s is! ExportUiFinishedAway || result == null || s.busy) return;
    _set(s.copyWith(busy: true, failed: false));
    final (status, _) = await _handoffTo(destination, result.path, _runFileName);
    if (!mounted) return;
    final cur = state;
    if (cur is ExportUiFinishedAway) _set(cur.copyWith(busy: false, failed: status == ExportHandoffStatus.failed || status == ExportHandoffStatus.denied));
  }

  /// Deletes the kept file of a finished-while-away export and consumes its record.
  Future<void> deleteFinished() async {
    final s = state;
    if (s is! ExportUiFinishedAway) return;
    final result = s.result;
    if (result != null) await _deleteQuietly(result.path);
    await _consume(s.jobId);
  }

  // -----------------------------------------------------------------------------------------------
  // Plumbing
  // -----------------------------------------------------------------------------------------------

  /// A file name for the user: the project name without unsafe characters, plus the extension.
  static String _friendlyName(String projectName, String ext) {
    var base = projectName.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
    while (base.endsWith('.')) {
      base = base.substring(0, base.length - 1).trimRight();
    }
    if (base.isEmpty) base = 'Danaview export';
    if (base.length > 80) base = base.substring(0, 80).trimRight();
    return '$base.$ext';
  }

  bool _live(int epoch) => mounted && epoch == _epoch;

  void _set(ExportUiState next) {
    if (!mounted) return;
    state = next;
    _syncLeases();
  }

  /// The export files this controller uses now (FIX-QA05-D8-2): the running job's output, the
  /// completion card's video and caption side files until they are cleaned up, and the file of a
  /// finished-while-away card. The export sweep never deletes them.
  Set<String> get _usedPaths {
    final s = state;
    final running = _job != null || s is ExportUiPreparing || s is ExportUiRunning || s is ExportUiCancelling;
    return {
      if (running && _runOutput != null) _runOutput!,
      if (s is ExportUiCompleted && !_cleaned) ...[s.result.path, for (final side in s.sideFiles) side.path],
      if (s is ExportUiFinishedAway && s.result != null) s.result!.path,
    };
  }

  void _syncLeases() {
    try {
      final paths = _usedPaths;
      if (paths.isEmpty) {
        _env?.outputLeases?.release(this);
      } else {
        _e.outputLeases?.hold(this, paths);
      }
    } on Object catch (e) {
      debugPrint('[Export] Could not update the export file leases: ${e.runtimeType}');
    }
  }

  /// An export job reached a terminal state: the runtime sweeps orphaned export files.
  void _jobEnded() {
    try {
      _env?.onJobEnded?.call();
    } on Object catch (e) {
      debugPrint('[Export] The export sweep hook failed: ${e.runtimeType}');
    }
  }

  void _fail(EditorFailure failure) {
    _set(ExportUiFailed(failure, details: detailsOf(failure)));
  }

  /// Fails with the mapping of [e], except that an otherwise `unknown` export failure caused by
  /// storage is the storage failure ("Not enough space to export", Free up space; QA-05 D8): the
  /// engine's detail names a vanished file or a full disk, the editor cache or exports folder
  /// vanished (the system purges the cache under low storage), or the free space no longer covers
  /// the export. [live] (default: the controller is mounted) is checked again after the checks.
  Future<void> _failExport(Object e, {bool Function()? live}) async {
    final mapped = EditorFailures.fromError(e, context: EngineFailureContext.export);
    final before = state;
    var failure = mapped;
    if (mapped is ExportFailed && mapped.kind == ExportFailureKind.unknown) {
      try {
        if (await _storageCaused(e)) {
          debugPrint('[Export] ${mapped.code} came from storage (a vanished file or a full disk); reporting exportFailed.diskFull');
          failure = const ExportFailed(ExportFailureKind.diskFull);
        }
      } on Object catch (x) {
        debugPrint('[Export] Storage check after a failure failed: ${x.runtimeType}');
      }
    }
    if (!mounted || !(live?.call() ?? true) || !identical(state, before)) return;
    _fail(failure);
  }

  /// Engine details that mean a file vanished or the disk is full.
  static final RegExp storageFailureDetail = RegExp(
    r'ENOENT|ENOSPC|EDQUOT|No such file|No space left|not enough space|disk full|FileNotFound|FileDataSourceException',
    caseSensitive: false,
  );

  Future<bool> _storageCaused(Object e) async {
    if (e is EngineFailure && storageFailureDetail.hasMatch(e.debugDetail)) return true;
    for (final dir in [_e.roots.editorCache, _e.workDir]) {
      if (!(await _e.fs.stat(dir)).exists) return true;
    }
    final setup = _lastSetup;
    return setup != null && await _storageIssue(setup) != null;
  }

  void _setWakelock(bool on) {
    if (_wakelockOn == on) return;
    _wakelockOn = on;
    try {
      _e.wakelock(on);
    } on Object catch (e) {
      debugPrint('[Export] Wakelock failed: ${e.runtimeType}');
    }
  }

  @override
  void dispose() {
    _stopListeningEditor();
    unawaited(_progressSub?.cancel());
    final s = state;
    final env = _env;
    if (_wakelockOn && env != null) {
      _wakelockOn = false;
      try {
        env.wakelock(false);
      } on Object {
        // The wakelock is best-effort.
      }
    }
    if (s is ExportUiCompleted && !_cleaned && env != null) {
      _cleaned = true;
      unawaited(_disposeCleanup(env, s));
    }
    env?.outputLeases?.release(this);
    super.dispose();
  }

  Future<void> _disposeCleanup(ExportEnvironment env, ExportUiCompleted s) async {
    for (final path in [s.result.path, ...s.sideFiles.map((f) => f.path)]) {
      try {
        await env.deleter.delete(path);
      } on Object {
        // Left for the next work-folder wipe.
      }
    }
  }
}

class _Blocking {
  _Blocking(this.requirements, {this.empty = false});

  final PlanRequirements requirements;
  final bool empty;
}

/// Builds the value of `exportControllerProvider` for [id]. The controller reads the open session,
/// the engine and the prefs; the environment (storage roots, deleter, writer, pre-pass) comes from
/// [exportEnvironmentProvider] when it is first needed.
ExportController createExportController(Ref<Object?> ref, ProjectId id) {
  return ExportController(
    id: id,
    session: ref.watch(editorSessionProvider(id)),
    engine: ref.read(editorEngineProvider),
    prefs: ref.read(editorPrefsProvider),
    environment: () => ref.read(exportEnvironmentProvider),
    editorState: () => ref.read(editorControllerProvider(id)),
    host: () => ref.read(exportHostProvider),
    listenEditor: (listener) {
      final sub = ref.container.listen<EditorState>(editorControllerProvider(id), (_, next) => listener(next));
      return sub.close;
    },
  );
}

/// Whether [state] is an export in progress that must not be dismissed (D-24: non-dismissible).
bool exportIsBusy(ExportUiState state) => switch (state) {
      ExportUiRunning() || ExportUiCancelling() || ExportUiPreparing() => true,
      _ => false,
    };
