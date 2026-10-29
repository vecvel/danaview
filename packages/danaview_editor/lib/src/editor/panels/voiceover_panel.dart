// OWNER: UX-34
//
// The voiceover panel (ux.md §10.5, Audio tool › Record voiceover), offered only when the engine has
// a voice recorder (`EditorEngine.voiceRecorder != null`).
//
// * Permission: the first tap on Record with the permission undetermined shows the explanation
//   ("Danaview uses the microphone only while you record…"); Continue asks the OS. Denied shows
//   the ux.md §18 message with "Open Settings" (`voiceRecorder.openSystemSettings()`), plus
//   "Try again" while the denial is not permanent. Returning to the app re-checks the permission.
// * Countdown 3-2-1 before recording (skippable with "Start now", cancellable). With reduced
//   motion (`MediaQuery.disableAnimations`) the digits change without the scale/fade animation.
// * Recording starts at the playhead. With "Play project while recording" (default on) the
//   project plays from the playhead, started just before the recorder so the recorder's audio
//   session wins on iOS (FIX-IOS-RECORD); the engine mutes the preview while recording (IOS-14 /
//   AND-13), so the project sound is not recorded. The level meter draws the `levels` stream
//   (20 Hz) as bars; the elapsed time runs from the start.
// * Stop: the WAV the engine wrote under `projects/<id>/assets/recordings/` is imported through
//   the media pool as a recording (`MediaOrigin.recorded` → project-owned, kept in place) and placed
//   by core `InsertMedia` (no lane given: the first free voice-role audio lane, a new one when
//   needed; never rippling) at record start + the recorder's `startLatencyUs`, one history entry
//   "Record voiceover".
// * Interruptions (call, route change, device removed) and recorder failures stop the recording,
//   keep what was captured, add it like Stop and show "Recording stopped. 0:12 saved.".
// * Cancel discards the recording (`RecordingSession.cancel`, which deletes the partial file).
// * Closing the panel while recording keeps the recording (as Stop).
// * The panel owns its scrolling and never overflows at 280-1280 px and text scale 0.85-1.35.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show CompositeCommand, InsertMedia, InsertMode;
import 'package:danaview_editor_core/store.dart' show ImportRejected, ImportedMedia, ManagedStore, MediaPoolService;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart'
    show MicPermission, RecordedAsset, RecordingInterruption, RecordingSession, VoiceRecorder;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../app/editor_bootstrap.dart' show editorRuntimeProvider;
import '../../app/editor_providers.dart';
import '../../app/strings/voiceover_strings.dart';
import '../contracts/inspector_routes.dart';
import '../editor_scope.dart';
import '../state/editor_controller.dart';
import '../state/editor_session.dart';
import '../state/playhead_controller.dart';
import '../state/transport_controller.dart';
import '../timeline/timeline_semantics.dart' show editorAnnounce;

/// The absolute path of a new recording file named `name` in project [ProjectId]'s
/// `assets/recordings/` folder, or null when the editor's storage is not configured. Tests override
/// it.
final voiceoverRecordingPathProvider = Provider.family<String Function(String name)?, ProjectId>((ref, id) {
  final roots = ref.watch(editorRuntimeProvider)?.roots;
  if (roots == null) return null;
  return (name) => roots.resolve(AppRelativeLocator(AppRoot.support, ManagedStore.projectAssetRelPath(id.value, 'recordings', name)));
}, name: 'voiceoverRecordingPathProvider');

/// Where the voiceover flow is.
///
/// See ux.md §10.5.
enum VoiceoverPhase {
  /// The device has no voice recorder.
  unavailable,

  /// Ready to record.
  idle,

  /// The explanation before the OS permission prompt.
  explain,

  /// Microphone access is off.
  denied,

  /// The 3-2-1 countdown.
  countdown,

  /// Recording.
  recording,

  /// Stopping, importing and placing the recording (or discarding it).
  finishing,
}

/// A message for the user after a step of the flow.
///
/// See ux.md §10.5, §18.
@immutable
final class VoiceoverNotice {
  /// Creates a notice.
  const VoiceoverNotice(this.message, {this.toast = false, this.error = false});

  /// The copy.
  final String message;

  /// Shown as a toast (else only announced).
  final bool toast;

  /// An error.
  final bool error;

  @override
  String toString() => 'VoiceoverNotice($message)';
}

/// The voiceover flow of one panel: permission, countdown, recording and placement (ux.md §10.5).
///
/// It outlives the panel widget while a recording finishes (closing the panel keeps the recording).
class VoiceoverController extends ChangeNotifier {
  /// Creates the controller.
  VoiceoverController({
    required this.recorder,
    required this.editor,
    required this.session,
    required this.pool,
    required this.playhead,
    required this.transport,
    required this.recordingPath,
    String Function()? fileName,
  })  : _fileName = fileName ?? _defaultFileName,
        _phase = recorder == null ? VoiceoverPhase.unavailable : VoiceoverPhase.idle;

  /// Seconds of the countdown.
  static const int countdownFrom = 3;

  /// The engine's recorder (null: unsupported).
  final VoiceRecorder? recorder;

  /// The editor.
  final EditorController editor;

  /// The editor session (its edit session receives the imported recording).
  final EditorSession session;

  /// The media pool service (imports the recording).
  final MediaPoolService pool;

  /// The playhead (the record start).
  final PlayheadController playhead;

  /// The transport ("Play project while recording").
  final TransportController transport;

  /// Absolute path of a new recording file, or null when storage is not configured.
  final String Function(String name)? recordingPath;

  final String Function() _fileName;

  static String _defaultFileName() => 'vo_${DateTime.now().toUtc().microsecondsSinceEpoch}.wav';

  /// Notices for the panel (toasts and announcements). Null when nobody shows them.
  void Function(VoiceoverNotice notice)? onNotice;

  VoiceoverPhase _phase;

  /// Where the flow is.
  VoiceoverPhase get phase => _phase;

  MicPermission? _permission;

  /// The last known permission (null before the first check).
  MicPermission? get permission => _permission;

  /// Whether the project plays while recording (ux.md §10.5, default on).
  bool get playProject => _playProject;
  bool _playProject = true;

  set playProject(bool value) {
    if (_playProject == value) return;
    _playProject = value;
    _notify();
  }

  int _count = countdownFrom;

  /// The countdown digit (3, 2, 1) while [phase] is [VoiceoverPhase.countdown].
  int get countdown => _count;

  TimeUs _recordStart = 0;

  /// The playhead time the recording started at.
  TimeUs get recordStart => _recordStart;

  /// The latest input level 0..1 (20 Hz while recording).
  final ValueNotifier<double> level = ValueNotifier<double>(0);

  Timer? _countdownTimer;
  RecordingSession? _recording;
  StreamSubscription<double>? _levels;
  StreamSubscription<RecordingInterruption>? _interruptions;
  bool _startedPlayback = false;
  bool _disposed = false;
  bool _starting = false;

  /// Whether the flow is between Record and the end of finishing.
  bool get busy =>
      _phase == VoiceoverPhase.countdown || _phase == VoiceoverPhase.recording || _phase == VoiceoverPhase.finishing || _starting;

  void _set(VoiceoverPhase phase) {
    if (_phase == phase) return;
    _phase = phase;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _tell(VoiceoverNotice notice) => onNotice?.call(notice);

  static bool _isDenied(MicPermission p) => p == MicPermission.denied || p == MicPermission.permanentlyDenied;

  // ---- Permission --------------------------------------------------------------------------------

  /// Reads the permission; shows the denied state when access is off (and leaves it once it is on).
  Future<void> refreshPermission() async {
    final r = recorder;
    if (r == null) return;
    final MicPermission p;
    try {
      p = await r.permission();
    } on Object catch (e) {
      debugPrint('[VoiceoverPanel] Permission check failed: ${e.runtimeType}');
      return;
    }
    if (_disposed) return;
    _permission = p;
    if (_phase == VoiceoverPhase.idle && _isDenied(p)) {
      _set(VoiceoverPhase.denied);
    } else if (_phase == VoiceoverPhase.denied && !_isDenied(p)) {
      _set(VoiceoverPhase.idle);
    } else {
      _notify();
    }
  }

  /// The Record button: the countdown when allowed, else the explanation or the denied state.
  Future<void> record() async {
    final r = recorder;
    if (r == null || busy || _phase == VoiceoverPhase.explain) return;
    final MicPermission p;
    try {
      p = await r.permission();
    } on Object catch (e) {
      debugPrint('[VoiceoverPanel] Permission check failed: ${e.runtimeType}');
      _tell(const VoiceoverNotice(VoiceoverStrings.startFailed, toast: true, error: true));
      return;
    }
    if (_disposed) return;
    _permission = p;
    switch (p) {
      case MicPermission.granted:
        _beginCountdown();
      case MicPermission.undetermined:
        _set(VoiceoverPhase.explain);
      case MicPermission.denied:
      case MicPermission.permanentlyDenied:
        _set(VoiceoverPhase.denied);
    }
  }

  /// Continue on the explanation: the OS prompt, then the countdown when granted.
  Future<void> confirmExplanation() async {
    if (_phase != VoiceoverPhase.explain) return;
    await _ask();
  }

  /// Not now on the explanation.
  void dismissExplanation() {
    if (_phase == VoiceoverPhase.explain) _set(VoiceoverPhase.idle);
  }

  /// Try again in the denied state (not permanently denied).
  Future<void> tryAgain() async {
    if (_phase != VoiceoverPhase.denied) return;
    await _ask();
  }

  Future<void> _ask() async {
    final r = recorder;
    if (r == null) return;
    MicPermission p;
    try {
      p = await r.requestPermission();
    } on Object catch (e) {
      debugPrint('[VoiceoverPanel] Permission request failed: ${e.runtimeType}');
      p = MicPermission.denied;
    }
    if (_disposed) return;
    _permission = p;
    if (p == MicPermission.granted) {
      _beginCountdown();
    } else if (p == MicPermission.undetermined) {
      _set(VoiceoverPhase.idle);
    } else {
      _set(VoiceoverPhase.denied);
    }
  }

  /// Opens the app's page in the system settings.
  Future<void> openSettings() async {
    try {
      await recorder?.openSystemSettings();
    } on Object catch (e) {
      debugPrint('[VoiceoverPanel] Opening settings failed: ${e.runtimeType}');
    }
  }

  // ---- Countdown ---------------------------------------------------------------------------------

  void _beginCountdown() {
    _count = countdownFrom;
    _set(VoiceoverPhase.countdown);
    _notify();
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_phase != VoiceoverPhase.countdown) {
        timer.cancel();
        return;
      }
      if (_count <= 1) {
        timer.cancel();
        unawaited(_start());
        return;
      }
      _count--;
      _notify();
    });
  }

  /// Skips the rest of the countdown.
  Future<void> skipCountdown() async {
    if (_phase != VoiceoverPhase.countdown) return;
    _countdownTimer?.cancel();
    await _start();
  }

  // ---- Recording ---------------------------------------------------------------------------------

  Future<void> _start() async {
    final r = recorder;
    if (r == null || _phase != VoiceoverPhase.countdown || _starting) return;
    _countdownTimer?.cancel();
    final pathOf = recordingPath;
    if (pathOf == null || !editor.canEdit || editor.readOnly) {
      _set(VoiceoverPhase.idle);
      _tell(VoiceoverNotice(editor.readOnly ? VoiceoverStrings.readOnly : VoiceoverStrings.startFailed, toast: true, error: true));
      return;
    }
    _starting = true;
    // The project starts playing BEFORE the recorder (FIX-IOS-RECORD): starting a preview switches
    // the shared iOS audio session to playback (IOS-11), which silently stops the microphone input
    // of a recording already capturing (QA-01 s13: a 3 s take came back as 0-288 ms). Started
    // first, the recorder's own session (.playAndRecord) wins and is restored when it ends. The
    // engine mutes the preview as soon as the recorder starts.
    if (_playProject && playhead.value < playhead.duration && transport.canPlay && !transport.playing.value) {
      _startedPlayback = true;
      try {
        await transport.play();
      } on Object catch (e) {
        _startedPlayback = false;
        debugPrint('[VoiceoverPanel] Playing the project failed: ${e.runtimeType}');
      }
      if (_disposed || _phase != VoiceoverPhase.countdown) {
        _starting = false;
        await _stopPlayback();
        return;
      }
    }
    // The record start is the playhead when the recorder is asked to start; `startLatencyUs` is
    // measured from that moment to the first captured sample, so start + latency is the timeline
    // time of the first sample while the project plays.
    final recordStart = playhead.value;
    RecordingSession recording;
    try {
      recording = await r.start(outputPath: pathOf(_fileName()));
    } on Object catch (e) {
      _starting = false;
      debugPrint('[VoiceoverPanel] Recording failed to start: ${e.runtimeType}');
      await _stopPlayback();
      if (_disposed) return;
      _set(VoiceoverPhase.idle);
      _tell(const VoiceoverNotice(VoiceoverStrings.startFailed, toast: true, error: true));
      return;
    }
    _starting = false;
    if (_disposed || _phase != VoiceoverPhase.countdown) {
      // Cancelled (or the panel went away during a countdown) while the recorder started.
      await _stopPlayback();
      await _discard(recording);
      return;
    }
    _recording = recording;
    _recordStart = recordStart;
    level.value = 0;
    _levels = recording.levels.listen((v) => level.value = v.isNaN ? 0 : v.clamp(0.0, 1.0).toDouble(), onError: (Object _) {});
    _interruptions = recording.interruptions.listen(
      (why) => unawaited(_finish(interrupted: true)),
      onError: (Object e) {
        debugPrint('[VoiceoverPanel] Recorder failure: ${e.runtimeType}');
        unawaited(_finish(interrupted: true));
      },
    );
    _set(VoiceoverPhase.recording);
  }

  /// Stops and adds the recording.
  Future<void> stop() => _finish(interrupted: false);

  /// Cancels the countdown, or discards the recording.
  Future<void> cancel() async {
    switch (_phase) {
      case VoiceoverPhase.countdown:
        _countdownTimer?.cancel();
        _set(VoiceoverPhase.idle);
      case VoiceoverPhase.recording:
        final recording = _recording;
        _recording = null;
        _set(VoiceoverPhase.finishing);
        await _stopPlayback();
        _endListening();
        if (recording != null) await _discard(recording);
        _set(VoiceoverPhase.idle);
        _tell(const VoiceoverNotice(VoiceoverStrings.discarded));
      default:
        break;
    }
  }

  Future<void> _discard(RecordingSession recording) async {
    try {
      await recording.cancel();
    } on Object catch (e) {
      debugPrint('[VoiceoverPanel] Discarding failed: ${e.runtimeType}');
    }
  }

  Future<void> _stopPlayback() async {
    if (!_startedPlayback) return;
    _startedPlayback = false;
    try {
      await transport.pause();
    } on Object catch (e) {
      debugPrint('[VoiceoverPanel] Pausing failed: ${e.runtimeType}');
    }
  }

  /// Stops listening to the session's streams (the cancels are not awaited: the session closes
  /// its streams itself when it stops).
  void _endListening() {
    final levels = _levels, interruptions = _interruptions;
    _levels = null;
    _interruptions = null;
    if (levels != null) unawaited(levels.cancel());
    if (interruptions != null) unawaited(interruptions.cancel());
    if (!_disposed) level.value = 0;
  }

  Future<void> _finish({required bool interrupted}) async {
    final recording = _recording;
    if (_phase != VoiceoverPhase.recording || recording == null) return;
    _recording = null;
    _set(VoiceoverPhase.finishing);
    await _stopPlayback();
    _endListening();
    RecordedAsset asset;
    try {
      asset = await recording.stop();
    } on Object catch (e) {
      debugPrint('[VoiceoverPanel] Finishing the recording failed: ${e.runtimeType}');
      _set(VoiceoverPhase.idle);
      _tell(const VoiceoverNotice(VoiceoverStrings.saveFailed, toast: true, error: true));
      return;
    }
    debugPrint('[VoiceoverPanel] Recorded ${asset.durationUs} us (start latency ${asset.startLatencyUs} us)');
    final notice = await _place(asset);
    _set(VoiceoverPhase.idle);
    if (notice != null) {
      _tell(notice);
    } else {
      _tell(interrupted
          ? VoiceoverNotice(VoiceoverStrings.interrupted(asset.durationUs), toast: true)
          : VoiceoverNotice(VoiceoverStrings.added(asset.durationUs)));
    }
  }

  /// Imports [asset] and inserts it at record start + latency; returns an error notice or null.
  Future<VoiceoverNotice?> _place(RecordedAsset asset) async {
    final edit = session.editOrNull;
    if (edit == null || !editor.mounted) return const VoiceoverNotice(VoiceoverStrings.saveFailed, toast: true, error: true);
    final n = 1 + edit.project.pool.assets.values.where((a) => a.kind == MediaKind.recording).length;
    final picked = PickedMedia(uri: asset.path, displayName: VoiceoverStrings.displayName(n), origin: MediaOrigin.recorded);
    final List<Object> outcomes;
    try {
      outcomes = await pool.import(edit, [picked]);
    } on Object catch (e) {
      debugPrint('[VoiceoverPanel] Importing the recording failed: ${e.runtimeType}');
      return const VoiceoverNotice(VoiceoverStrings.saveFailed, toast: true, error: true);
    }
    final outcome = outcomes.isEmpty ? null : outcomes.first;
    if (outcome is! ImportedMedia) {
      final reason = outcome is ImportRejected ? outcome.reason : '';
      debugPrint('[VoiceoverPanel] The recording was not imported: ${reason.isEmpty ? outcome.runtimeType : reason}');
      return VoiceoverNotice(reason == 'diskFull' ? VoiceoverStrings.diskFull : VoiceoverStrings.saveFailed, toast: true, error: true);
    }
    if (!editor.mounted) return const VoiceoverNotice(VoiceoverStrings.saveFailed, toast: true, error: true);
    final at = voiceoverClipStart(_recordStart, asset);
    final result = editor.apply(CompositeCommand(VoiceoverStrings.history, [InsertMedia([outcome.asset.id], at, mode: InsertMode.newLane)]));
    if (!result.applied) debugPrint('[VoiceoverPanel] Placing the recording was refused: $result');
    // A refused insert is explained by the editor's own toast (ARCH §19 rule 4); the recording
    // stays in the media bin.
    return result.applied ? null : const VoiceoverNotice('', toast: false);
  }

  @override
  void dispose() {
    _disposed = true;
    _countdownTimer?.cancel();
    onNotice = null;
    if (_phase == VoiceoverPhase.recording) {
      // Closing the panel keeps the recording.
      unawaited(_finish(interrupted: false).whenComplete(_release));
    } else {
      _release();
    }
    super.dispose();
  }

  void _release() {
    final recording = _recording;
    _recording = null;
    if (recording != null) unawaited(_discard(recording));
    _endListening();
  }
}

/// Where a recording that started at playhead [recordStart] is placed: the start plus the
/// recorder's measured input latency (ARCH §12.4, `RecordedAsset.startLatencyUs`). Core snaps it to
/// the nearest frame.
TimeUs voiceoverClipStart(TimeUs recordStart, RecordedAsset asset) => recordStart + math.max(0, asset.startLatencyUs);

/// The voiceover panel (ux.md §10.5).
class VoiceoverPanel extends ConsumerStatefulWidget {
  /// Creates the panel for [route].
  const VoiceoverPanel({super.key, required this.route});

  /// What the panel edits.
  final VoiceoverInspector route;

  @override
  ConsumerState<VoiceoverPanel> createState() => _VoiceoverPanelState();
}

class _VoiceoverPanelState extends ConsumerState<VoiceoverPanel> {
  VoiceoverController? _controller;
  AppLifecycleListener? _lifecycle;

  VoiceoverController _controllerOf(BuildContext context) {
    final existing = _controller;
    if (existing != null) return existing;
    final id = EditorScope.idOf(context);
    final c = VoiceoverController(
      recorder: ref.read(editorEngineProvider).voiceRecorder,
      editor: ref.read(editorControllerProvider(id).notifier),
      session: ref.read(editorSessionProvider(id)),
      pool: ref.read(mediaPoolServiceProvider),
      playhead: ref.read(playheadProvider(id)),
      transport: ref.read(transportProvider(id)),
      recordingPath: ref.read(voiceoverRecordingPathProvider(id)),
    )..onNotice = _show;
    _controller = c;
    unawaited(c.refreshPermission());
    _lifecycle = AppLifecycleListener(onResume: () {
      if (c.phase == VoiceoverPhase.denied || c.phase == VoiceoverPhase.idle) unawaited(c.refreshPermission());
    });
    return c;
  }

  void _show(VoiceoverNotice notice) {
    if (!mounted || notice.message.isEmpty) return;
    if (notice.toast) {
      DanaviewToast.show(
        context,
        notice.message,
        icon: notice.error ? Icons.error_outline_rounded : Icons.mic_rounded,
        kind: notice.error ? DanaviewToastKind.error : DanaviewToastKind.info,
      );
    }
    editorAnnounce(context, notice.message);
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controllerOf(context);
    final id = EditorScope.idOf(context);
    final ready = ref.watch(editorControllerProvider(id).select((s) => s.isReady));
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final editor = c.editor;
        final readOnly = editor.readOnly;
        final canRecord = ready && editor.canEdit && !readOnly;
        final body = switch (c.phase) {
          VoiceoverPhase.unavailable => const _Message(key: ValueKey<String>('voiceover.unavailable'), text: VoiceoverStrings.unavailable),
          VoiceoverPhase.idle => _Idle(controller: c, enabled: canRecord, blocker: readOnly ? VoiceoverStrings.readOnly : (canRecord ? null : VoiceoverStrings.notEditable)),
          VoiceoverPhase.explain => _Explain(controller: c),
          VoiceoverPhase.denied => _Denied(controller: c),
          VoiceoverPhase.countdown => _Countdown(controller: c),
          VoiceoverPhase.recording => _Recording(controller: c),
          VoiceoverPhase.finishing => const _Finishing(),
        };
        return CustomScrollView(
          key: const ValueKey<String>('voiceover.scroll'),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(DanaviewSpacing.lg, DanaviewSpacing.sm, DanaviewSpacing.lg, DanaviewSpacing.lg),
              sliver: SliverToBoxAdapter(child: body),
            ),
          ],
        );
      },
    );
  }
}

// -------------------------------------------------------------------------------------------------
// States
// -------------------------------------------------------------------------------------------------

class _Idle extends StatelessWidget {
  const _Idle({required this.controller, required this.enabled, required this.blocker});

  final VoiceoverController controller;
  final bool enabled;
  final String? blocker;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Column(
      key: const ValueKey<String>('voiceover.idle'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (blocker case final text?) ...[
          _Note(key: const ValueKey<String>('voiceover.blocker'), text: text, icon: Icons.lock_rounded),
          const SizedBox(height: DanaviewSpacing.sm),
        ],
        Center(
          child: _RoundRecordButton(
            key: const ValueKey<String>('voiceover.record'),
            recording: false,
            onTap: enabled ? () => unawaited(c.record()) : null,
          ),
        ),
        const SizedBox(height: DanaviewSpacing.sm),
        ValueListenableBuilder<TimeUs>(
          valueListenable: c.playhead,
          builder: (context, t, _) => Text(
            VoiceoverStrings.recordsFrom(t),
            key: const ValueKey<String>('voiceover.from'),
            textAlign: TextAlign.center,
            style: _captionStyle.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ),
        const SizedBox(height: DanaviewSpacing.md),
        DanaviewSwitchRow(
          key: const ValueKey<String>('voiceover.playProject'),
          title: VoiceoverStrings.playProject,
          subtitle: VoiceoverStrings.playProjectHint,
          value: c.playProject,
          onChanged: (v) => c.playProject = v,
        ),
      ],
    );
  }
}

class _Explain extends StatelessWidget {
  const _Explain({required this.controller});

  final VoiceoverController controller;

  @override
  Widget build(BuildContext context) => Column(
        key: const ValueKey<String>('voiceover.explain'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            const Icon(Icons.mic_rounded, size: 20, color: DanaviewColors.primaryLight),
            const SizedBox(width: DanaviewSpacing.sm),
            Expanded(
              child: Semantics(
                header: true,
                child: Text(VoiceoverStrings.explainTitle, style: _bodyStyle.copyWith(fontWeight: FontWeight.w600)),
              ),
            ),
          ]),
          const SizedBox(height: DanaviewSpacing.sm),
          Text(VoiceoverStrings.explainBody, style: _bodyStyle.copyWith(color: DanaviewColors.textSecondary)),
          const SizedBox(height: DanaviewSpacing.lg),
          Wrap(
            spacing: DanaviewSpacing.sm,
            runSpacing: DanaviewSpacing.sm,
            children: [
              DanaviewButton.primary(
                key: const ValueKey<String>('voiceover.continue'),
                label: VoiceoverStrings.explainContinue,
                onPressed: () => unawaited(controller.confirmExplanation()),
              ),
              DanaviewButton.ghost(
                key: const ValueKey<String>('voiceover.notNow'),
                label: VoiceoverStrings.explainNotNow,
                onPressed: controller.dismissExplanation,
              ),
            ],
          ),
        ],
      );
}

class _Denied extends StatelessWidget {
  const _Denied({required this.controller});

  final VoiceoverController controller;

  @override
  Widget build(BuildContext context) => Column(
        key: const ValueKey<String>('voiceover.denied'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Note(text: VoiceoverStrings.denied, icon: Icons.mic_off_rounded),
          const SizedBox(height: DanaviewSpacing.md),
          Wrap(
            spacing: DanaviewSpacing.sm,
            runSpacing: DanaviewSpacing.sm,
            children: [
              DanaviewButton.primary(
                key: const ValueKey<String>('voiceover.openSettings'),
                label: VoiceoverStrings.openSettings,
                icon: Icons.settings_rounded,
                onPressed: () => unawaited(controller.openSettings()),
              ),
              if (controller.permission != MicPermission.permanentlyDenied)
                DanaviewButton.secondary(
                  key: const ValueKey<String>('voiceover.tryAgain'),
                  label: VoiceoverStrings.tryAgain,
                  onPressed: () => unawaited(controller.tryAgain()),
                ),
            ],
          ),
        ],
      );
}

class _Countdown extends StatelessWidget {
  const _Countdown({required this.controller});

  final VoiceoverController controller;

  @override
  Widget build(BuildContext context) {
    final n = controller.countdown;
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final digit = Text(
      '$n',
      key: ValueKey<String>('voiceover.count.$n'),
      style: _bodyStyle.copyWith(fontSize: 48, height: 1.1, fontWeight: FontWeight.w700, fontFeatures: const [FontFeature.tabularFigures()]),
    );
    return Column(
      key: const ValueKey<String>('voiceover.countdown'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          liveRegion: true,
          label: VoiceoverStrings.countdown(n),
          excludeSemantics: true,
          child: Center(
            child: reduced
                ? KeyedSubtree(key: const ValueKey<String>('voiceover.countStill'), child: digit)
                : AnimatedSwitcher(
                    key: const ValueKey<String>('voiceover.countAnimated'),
                    duration: DanaviewMotion.normal,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: ScaleTransition(scale: Tween<double>(begin: 1.4, end: 1).animate(animation), child: child),
                    ),
                    child: digit,
                  ),
          ),
        ),
        const SizedBox(height: DanaviewSpacing.md),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: DanaviewSpacing.sm,
          runSpacing: DanaviewSpacing.sm,
          children: [
            DanaviewButton.primary(
              key: const ValueKey<String>('voiceover.skip'),
              label: VoiceoverStrings.skip,
              icon: Icons.mic_rounded,
              onPressed: () => unawaited(controller.skipCountdown()),
            ),
            DanaviewButton.ghost(
              key: const ValueKey<String>('voiceover.cancel'),
              label: VoiceoverStrings.cancel,
              onPressed: () => unawaited(controller.cancel()),
            ),
          ],
        ),
      ],
    );
  }
}

class _Recording extends StatelessWidget {
  const _Recording({required this.controller});

  final VoiceoverController controller;

  @override
  Widget build(BuildContext context) => Column(
        key: const ValueKey<String>('voiceover.recording'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Elapsed(key: ValueKey<String>('voiceover.elapsed')),
          const SizedBox(height: DanaviewSpacing.sm),
          _LevelMeter(key: const ValueKey<String>('voiceover.meter'), level: controller.level),
          const SizedBox(height: DanaviewSpacing.md),
          Center(
            child: _RoundRecordButton(
              key: const ValueKey<String>('voiceover.stop'),
              recording: true,
              onTap: () => unawaited(controller.stop()),
            ),
          ),
          const SizedBox(height: DanaviewSpacing.sm),
          Text(VoiceoverStrings.stopHint, textAlign: TextAlign.center, style: _captionStyle),
          const SizedBox(height: DanaviewSpacing.sm),
          Center(
            child: DanaviewButton.ghost(
              key: const ValueKey<String>('voiceover.discard'),
              label: VoiceoverStrings.cancel,
              onPressed: () => unawaited(controller.cancel()),
            ),
          ),
        ],
      );
}

class _Finishing extends StatelessWidget {
  const _Finishing();

  @override
  Widget build(BuildContext context) => Row(
        key: const ValueKey<String>('voiceover.finishing'),
        children: [
          const DanaviewSpinner(size: 18, semanticLabel: VoiceoverStrings.finishing),
          const SizedBox(width: DanaviewSpacing.sm),
          Expanded(child: Text(VoiceoverStrings.finishing, style: _bodyStyle.copyWith(color: DanaviewColors.textSecondary))),
        ],
      );
}

// -------------------------------------------------------------------------------------------------
// Parts
// -------------------------------------------------------------------------------------------------

/// The big round record/stop button (a single-icon button, so it may be round, ARCH §1.3 rule 3):
/// primary while idle, the error colour while recording.
class _RoundRecordButton extends StatelessWidget {
  const _RoundRecordButton({super.key, required this.recording, required this.onTap});

  static const double diameter = 64;

  final bool recording;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final base = DanaviewColors.primary;
    final fill = enabled ? base : DanaviewColors.disabled(base);
    final fg = DanaviewColors.foregroundOn(base);
    return DanaviewPressable(
      circle: true,
      enabled: enabled,
      onTap: onTap,
      semanticLabel: recording ? VoiceoverStrings.stop : VoiceoverStrings.record,
      tooltip: recording ? VoiceoverStrings.stop : VoiceoverStrings.record,
      child: SizedBox.square(
        dimension: diameter,
        child: DecoratedBox(
          decoration: BoxDecoration(shape: BoxShape.circle, color: fill, boxShadow: DanaviewShadows.subtle),
          child: Center(
            child: Icon(
              recording ? Icons.stop_rounded : Icons.mic_rounded,
              size: 30,
              color: enabled ? fg : DanaviewColors.disabled(fg),
            ),
          ),
        ),
      ),
    );
  }
}

/// The elapsed recording time (from mount; the recording starts when this state is shown).
class _Elapsed extends StatefulWidget {
  const _Elapsed({super.key});

  @override
  State<_Elapsed> createState() => _ElapsedState();
}

class _ElapsedState extends State<_Elapsed> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  int _seconds = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      final s = elapsed.inSeconds;
      if (s != _seconds) setState(() => _seconds = s);
    })
      ..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = _seconds * microsPerSecond;
    return Semantics(
      label: VoiceoverStrings.elapsedSemantics(t),
      excludeSemantics: true,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(shape: BoxShape.circle, color: DanaviewColors.primaryLight),
            child: SizedBox.square(dimension: 10),
          ),
          const SizedBox(width: DanaviewSpacing.sm),
          Flexible(
            child: Text(
              VoiceoverStrings.clock(t),
              key: const ValueKey<String>('voiceover.time'),
              style: _bodyStyle.copyWith(fontSize: 22, fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ),
        ],
      ),
    );
  }
}

/// The input level as a row of bars: the newest level on the right (`DanaviewProgressBar`-style
/// rounded bars on the track colour).
class _LevelMeter extends StatefulWidget {
  const _LevelMeter({super.key, required this.level});

  static const int bars = 28;
  static const double height = 36;

  final ValueListenable<double> level;

  @override
  State<_LevelMeter> createState() => _LevelMeterState();
}

class _LevelMeterState extends State<_LevelMeter> {
  final List<double> _history = List<double>.filled(_LevelMeter.bars, 0, growable: true);

  @override
  void initState() {
    super.initState();
    widget.level.addListener(_onLevel);
  }

  @override
  void didUpdateWidget(_LevelMeter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.level != widget.level) {
      oldWidget.level.removeListener(_onLevel);
      widget.level.addListener(_onLevel);
    }
  }

  @override
  void dispose() {
    widget.level.removeListener(_onLevel);
    super.dispose();
  }

  void _onLevel() {
    setState(() {
      _history
        ..removeAt(0)
        ..add(widget.level.value);
    });
  }

  @override
  Widget build(BuildContext context) => Semantics(
        label: VoiceoverStrings.level,
        value: '${(widget.level.value * 100).round()}%',
        child: SizedBox(
          height: _LevelMeter.height,
          width: double.infinity,
          child: CustomPaint(painter: _LevelPainter(List<double>.of(_history))),
        ),
      );
}

class _LevelPainter extends CustomPainter {
  _LevelPainter(this.levels);

  final List<double> levels;

  @override
  void paint(Canvas canvas, Size size) {
    if (levels.isEmpty || size.width <= 0) return;
    final slot = size.width / levels.length;
    final w = math.max(1.0, slot * 0.6);
    final track = Paint()..color = DanaviewColors.trackBackground;
    final fill = Paint();
    for (var i = 0; i < levels.length; i++) {
      final v = levels[i].clamp(0.0, 1.0);
      final x = i * slot + (slot - w) / 2;
      final r = Radius.circular(w / 2);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, 0, w, size.height), r), track);
      final h = math.max(w, size.height * v);
      fill.color = v > 0.9 ? DanaviewColors.error : (v > 0.7 ? DanaviewColors.warning : DanaviewColors.primaryLight);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, (size.height - h) / 2, w, h), r), fill);
    }
  }

  @override
  bool shouldRepaint(_LevelPainter old) => !listEquals(old.levels, levels);
}

TextStyle get _captionStyle => DanaviewTextStyles.caption.copyWith(fontFamily: DanaviewFonts.family, color: DanaviewColors.textSecondary);

TextStyle get _bodyStyle => DanaviewTextStyles.body.copyWith(fontFamily: DanaviewFonts.family, color: DanaviewColors.textPrimary);

class _Message extends StatelessWidget {
  const _Message({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => _Note(text: text, icon: Icons.mic_off_rounded);
}

/// A quiet explanation with an icon.
class _Note extends StatelessWidget {
  const _Note({super.key, required this.text, required this.icon});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: DanaviewColors.surfaceElevatedHigher,
          borderRadius: DanaviewRadius.controlAll,
          border: Border.fromBorderSide(DanaviewBorders.hairline),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 16, color: DanaviewColors.warning)),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: _captionStyle.copyWith(color: DanaviewColors.textPrimary))),
          ]),
        ),
      );
}
