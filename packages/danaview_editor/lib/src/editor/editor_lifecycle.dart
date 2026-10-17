// OWNER: UX-07
// FIX-M1 (QA-02 M-1): tier-aware close flush, "Still saving" and the background save on leave.
//
// Editor lifecycle (ux.md §4.7): back handling, app lifecycle saves, memory pressure and
// orientation, plus the port the shell needs from the open editor.
//
// * EditorShellDelegate is what the shell asks of the editor controller. Its members follow the
//   EditorController API of ux.md §16.3 (open, close, undo, redo, saveNow, onApp*) plus three shell
//   hooks (shellStatus, dismissForBack, flushBeforeClose), so UX-08's controller can implement it
//   directly; `editorShellProvider` (editor_screen.dart) picks it up from editorControllerProvider.
// * Back order (Android back and predictive back, Esc through EditorBackDispatcher.handleBack):
//   cancel gesture -> close panel -> clear selection -> exit fullscreen -> close the editor with a
//   flush ("Saving…" in the top bar). PopScope(canPop:
//   false) keeps the route from popping on its own and disables the iOS edge back-swipe (V-U3,
//   verified on Flutter 3.44.2: ModalRoute.popGestureEnabled is false while the pop disposition is
//   doNotPop), so a swipe from the edge never leaves the editor or loses edits.
//   The close button skips the dismiss steps: it always closes the editor (with the flush).
//   "Go to Projects" (unknown project) leaves through `requestClose(exitWith: onOpenProjects)`.
//   When the route is removed without the close flow (the router replaced the stack), dispose
//   still calls delegate.close() once.
// * Close flush (FIX-M1, QA-02 M-1): the shell waits [EditorLifecycle.flushTimeoutFor] the device
//   tier (high 4 s, mid 6 s, low 8 s, minimal 10 s) with "Saving…" in the top bar. A flush that
//   failed asks "Couldn't save your latest changes / Leave anyway?". A flush that is still running
//   at the timeout is never abandoned: the save keeps going in the repository's write queue (the
//   writer isolate), and the shell asks "Still saving your latest changes" instead. That dialog
//   leaves on its own as soon as the save lands, turns into the failure copy when it fails, and
//   "Leave" lets the save finish in the background (the session is released without waiting).
// * Regions register their own steps (UX-13 cancels a drag, UX-18 leaves fullscreen) with
//   `EditorBackDispatcher.of(context).register(step, handler)`; the delegate is asked after them.
// * App lifecycle: inactive -> delegate.onAppInactive (+ registered gestures cancelled), hidden ->
//   delegate.onAppHidden (flush), resumed -> delegate.onAppResumed; memory pressure ->
//   delegate.onMemoryPressure. Orientation: ScreenOrientationPolicy.enter(free) while mounted.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:danaview_editor_core/model.dart' show TimeUs;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart' show DeviceTier;
import 'package:danaview_features/orientation.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import 'layout/editor_shell_strings.dart';

// -------------------------------------------------------------------------------------------------
// Port
// -------------------------------------------------------------------------------------------------

/// Phase of the open editor as the shell sees it.
enum EditorShellPhase {
  /// The project is opening (repository, preview session, exact seek).
  opening,

  /// Ready to edit.
  ready,

  /// The project id is unknown (deleted, never existed): "This project isn't available".
  notFound,

  /// The project couldn't be opened (see [EditorShellStatus.failureTitle]).
  failed,
}

/// The save indicator under the project name (ux.md §6.4, §14.3).
enum EditorSaveIndicator {
  /// Everything is on disk.
  saved,

  /// A save is running.
  saving,

  /// Unsaved edits (autosave pending).
  edited,

  /// The last save failed ("Couldn't save · Retry").
  failed,
}

/// What the shell shows about the open editor. Nothing here changes per playback frame.
@immutable
final class EditorShellStatus {
  /// Creates a status.
  const EditorShellStatus({
    this.phase = EditorShellPhase.opening,
    this.projectName,
    this.save = EditorSaveIndicator.saved,
    this.canUndo = false,
    this.canRedo = false,
    this.undoLabel,
    this.redoLabel,
    this.inspectorOpen = false,
    this.failureTitle,
    this.failureMessage,
  });

  /// The opening status.
  static const EditorShellStatus opening = EditorShellStatus();

  /// Phase.
  final EditorShellPhase phase;

  /// Project name (null while opening).
  final String? projectName;

  /// Save indicator.
  final EditorSaveIndicator save;

  /// Whether undo is possible.
  final bool canUndo;

  /// Whether redo is possible.
  final bool canRedo;

  /// Label of the entry undo would revert ("Split clip").
  final String? undoLabel;

  /// Label of the entry redo would apply.
  final String? redoLabel;

  /// Whether an inspector panel (or a docked flow) is open.
  final bool inspectorOpen;

  /// Headline when [phase] is [EditorShellPhase.failed] (from editor_messages).
  final String? failureTitle;

  /// Next step when [phase] is [EditorShellPhase.failed].
  final String? failureMessage;

  /// A copy with the given fields replaced.
  EditorShellStatus copyWith({
    EditorShellPhase? phase,
    String? projectName,
    EditorSaveIndicator? save,
    bool? canUndo,
    bool? canRedo,
    String? undoLabel,
    String? redoLabel,
    bool? inspectorOpen,
    String? failureTitle,
    String? failureMessage,
  }) =>
      EditorShellStatus(
        phase: phase ?? this.phase,
        projectName: projectName ?? this.projectName,
        save: save ?? this.save,
        canUndo: canUndo ?? this.canUndo,
        canRedo: canRedo ?? this.canRedo,
        undoLabel: undoLabel ?? this.undoLabel,
        redoLabel: redoLabel ?? this.redoLabel,
        inspectorOpen: inspectorOpen ?? this.inspectorOpen,
        failureTitle: failureTitle ?? this.failureTitle,
        failureMessage: failureMessage ?? this.failureMessage,
      );

  @override
  bool operator ==(Object other) =>
      other is EditorShellStatus &&
      other.phase == phase &&
      other.projectName == projectName &&
      other.save == save &&
      other.canUndo == canUndo &&
      other.canRedo == canRedo &&
      other.undoLabel == undoLabel &&
      other.redoLabel == redoLabel &&
      other.inspectorOpen == inspectorOpen &&
      other.failureTitle == failureTitle &&
      other.failureMessage == failureMessage;

  @override
  int get hashCode =>
      Object.hash(phase, projectName, save, canUndo, canRedo, undoLabel, redoLabel, inspectorOpen, failureTitle, failureMessage);

  @override
  String toString() => 'EditorShellStatus(${phase.name}, "$projectName", ${save.name}, undo: $canUndo, redo: $canRedo, '
      'inspector: $inspectorOpen)';
}

/// The steps a back press tries before it closes the editor, in order (ux.md §4.7, ARCH §17.6).
enum EditorBackStep {
  /// Cancel the gesture or transaction in progress (a drag, a trim, a manipulation).
  cancelGesture,

  /// Close the open inspector panel or docked flow.
  closePanel,

  /// Clear the selection.
  clearSelection,

  /// Leave the fullscreen preview.
  exitFullscreen,
}

/// What the editor shell needs from the open editor (UX-07).
///
/// UX-08's `EditorController` implements it (the names and signatures follow ux.md §16.3, so
/// `Future<CloseOutcome> close()` and `Future<SaveOutcome> saveNow(...)` are valid overrides);
/// until it does, `editorShellProvider` falls back to a detached shell that only resolves the
/// project name. Every method must be safe to call in any phase and must not throw.
abstract interface class EditorShellDelegate {
  /// Shell-facing status; notifies only when a field changes (never per playback frame).
  ValueListenable<EditorShellStatus> get shellStatus;

  /// Opens the project and the preview session, then seeks exactly to [initialPlayhead] (ARCH
  /// §17.1). Called once by `EditorLifecycle` when the editor route enters. Failures are reported
  /// through [shellStatus] (`notFound`, `failed`).
  Future<void> open({TimeUs? initialPlayhead});

  /// Dismisses what [step] covers when there is something to dismiss (cancel the open transaction,
  /// close the inspector, clear the selection, leave fullscreen) and returns true; returns false
  /// when there is nothing, so the back press moves on to the next step.
  bool dismissForBack(EditorBackStep step);

  /// Flushes the latest edits before the editor closes; true when they are on disk. The shell
  /// waits up to [EditorLifecycle.flushTimeoutFor] the device tier; a flush still running then
  /// (or a false result while [shellStatus] still shows `saving`) is treated as "still saving",
  /// so the save must keep going after the shell stops waiting.
  Future<bool> flushBeforeClose();

  /// Releases the session (preview, repository). Called after [flushBeforeClose] when the editor
  /// leaves; never throws.
  Future<void> close();

  /// Undoes the last edit; false when there was nothing to undo.
  bool undo();

  /// Redoes the last undone edit; false when there was nothing to redo.
  bool redo();

  /// Saves now; [manual] for ⌘S, the project sheet and "Couldn't save · Retry".
  Future<void> saveNow({bool manual = false});

  /// The app became inactive (a call, the app switcher): pause playback, cancel an interrupted
  /// gesture, request an autosave.
  void onAppInactive();

  /// The app was hidden or paused: flush the save immediately; keep the preview session.
  void onAppHidden();

  /// The app came back: refresh the preview and re-seek to the playhead.
  void onAppResumed();

  /// The system is low on memory: trim caches.
  void onMemoryPressure();
}

// -------------------------------------------------------------------------------------------------
// Back dispatcher
// -------------------------------------------------------------------------------------------------

/// Runs back presses through the steps of [EditorBackStep], then closes the editor.
///
/// Get it with [EditorBackDispatcher.of] below an [EditorLifecycle].
abstract interface class EditorBackDispatcher {
  /// The dispatcher of the enclosing editor.
  static EditorBackDispatcher of(BuildContext context) {
    final d = maybeOf(context);
    assert(d != null, 'EditorBackDispatcher.of called outside an EditorLifecycle');
    return d!;
  }

  /// The dispatcher of the enclosing editor, or null.
  static EditorBackDispatcher? maybeOf(BuildContext context) => context.getInheritedWidgetOfExactType<_EditorLifecycleScope>()?.dispatcher;

  /// Registers [handler] for [step]; it returns true when it dismissed something. Handlers
  /// registered later run first; the delegate is asked after every handler of the step. Returns a
  /// function that unregisters it (call it from `dispose`).
  VoidCallback register(EditorBackStep step, bool Function() handler);

  /// One back press (Android back, Esc, the iOS swipe): the first step that dismisses something
  /// wins and is returned; when none does, the editor closes (with the flush) and null is
  /// returned.
  Future<EditorBackStep?> handleBack();

  /// The close button: flushes ("Saving…", up to [EditorLifecycle.flushTimeoutFor] the tier), asks
  /// "Leave anyway?" when the flush failed ("Still saving" when it is still running), then leaves through the screen's `onClose`, or through [exitWith] when given ("Go to
  /// Projects"). Nothing is flushed when the project never opened (`notFound`, `failed`).
  Future<void> requestClose({VoidCallback? exitWith});

  /// True while the editor is closing (the top bar shows "Saving…").
  ValueListenable<bool> get closing;
}

// -------------------------------------------------------------------------------------------------
// Lifecycle widget
// -------------------------------------------------------------------------------------------------

/// What the "Leave anyway?" confirmation is about (FIX-M1).
@immutable
final class EditorLeaveRequest {
  /// Creates the request.
  const EditorLeaveRequest({required this.stillSaving, required this.flush});

  /// True when the save was still running when the shell stopped waiting (it keeps going in the
  /// background); false when it failed.
  final bool stillSaving;

  /// The close flush (true when the edits landed); it may complete while the confirmation shows.
  final Future<bool> flush;
}

/// Back handling, lifecycle saves and orientation for the editor (ux.md §4.7).
class EditorLifecycle extends StatefulWidget {
  /// Creates the lifecycle around [child] for [delegate]; [onExit] leaves the editor route.
  const EditorLifecycle({
    super.key,
    required this.delegate,
    required this.onExit,
    this.initialPlayhead,
    this.confirmLeave,
    this.flushTimeout,
    required this.child,
  });

  /// How long the close flush may take on [tier] before the shell asks (FIX-M1, QA-02 M-1): a
  /// slower device, or one under load, gets longer before "Still saving" shows.
  static Duration flushTimeoutFor(DeviceTier tier) => switch (tier) {
        DeviceTier.high => const Duration(seconds: 4),
        DeviceTier.mid => const Duration(seconds: 6),
        DeviceTier.low => const Duration(seconds: 8),
        DeviceTier.minimal => const Duration(seconds: 10),
      };

  /// The close flush timeout before the device tier is known (the mid tier).
  static final Duration defaultFlushTimeout = flushTimeoutFor(DeviceTier.mid);

  /// How long the close flush may take before the shell asks; null is [defaultFlushTimeout]. The
  /// editor screen passes [flushTimeoutFor] the device tier.
  final Duration? flushTimeout;

  /// The open editor.
  final EditorShellDelegate delegate;

  /// Leaves the editor (the router's `onClose`). Called after the close flow, one frame after the
  /// route was allowed to pop, so `Navigator.maybePop` works as well as `pop`.
  final VoidCallback onExit;

  /// Exact seek target on open.
  final TimeUs? initialPlayhead;

  /// Asks whether to leave after a failed or still-running flush (default: a Danaview dialog
  /// that leaves on its own when a still-running save lands).
  final Future<bool> Function(BuildContext context, EditorLeaveRequest request)? confirmLeave;

  /// The editor.
  final Widget child;

  @override
  State<EditorLifecycle> createState() => _EditorLifecycleState();
}

class _EditorLifecycleState extends State<EditorLifecycle> with WidgetsBindingObserver implements EditorBackDispatcher {
  final Map<EditorBackStep, List<bool Function()>> _handlers = {for (final s in EditorBackStep.values) s: <bool Function()>[]};
  final ValueNotifier<bool> _closing = ValueNotifier<bool>(false);
  late final AppLifecycleListener _appLifecycle;
  bool _leaving = false;
  bool _released = false;
  VoidCallback? _exitWith;

  EditorShellDelegate get _delegate => widget.delegate;

  @override
  ValueListenable<bool> get closing => _closing;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appLifecycle = AppLifecycleListener(
      onInactive: _onInactive,
      onHide: () => _guard(_delegate.onAppHidden),
      onResume: () => _guard(_delegate.onAppResumed),
    );
    unawaited(ScreenOrientationPolicy.enter(this, OrientationMode.free));
    _open();
  }

  @override
  void didUpdateWidget(EditorLifecycle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.delegate, widget.delegate)) _open();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _appLifecycle.dispose();
    unawaited(ScreenOrientationPolicy.release(this));
    if (!_released) {
      // The route went away without the close flow (the router replaced the stack): release the
      // session anyway; close() flushes and never throws.
      _released = true;
      unawaited(Future<void>.sync(_delegate.close).catchError((Object e, StackTrace s) => _report(e, s, 'closing the editor')));
    }
    _closing.dispose();
    super.dispose();
  }

  void _open() {
    final delegate = _delegate;
    unawaited(delegate.open(initialPlayhead: widget.initialPlayhead).catchError((Object e, StackTrace s) {
      _report(e, s, 'opening the editor');
    }));
  }

  void _onInactive() {
    // A gesture interrupted by a call or the app switcher is cancelled (ux.md §16.4).
    for (final handler in [..._handlers[EditorBackStep.cancelGesture]!.reversed]) {
      _call(handler);
    }
    _guard(_delegate.onAppInactive);
  }

  @override
  void didHaveMemoryPressure() => _guard(_delegate.onMemoryPressure);

  // ---- EditorBackDispatcher ----

  @override
  VoidCallback register(EditorBackStep step, bool Function() handler) {
    final list = _handlers[step]!..add(handler);
    return () => list.remove(handler);
  }

  @override
  Future<EditorBackStep?> handleBack() async {
    if (_closing.value || _leaving) return null;
    if (_delegate.shellStatus.value.phase == EditorShellPhase.ready) {
      for (final step in EditorBackStep.values) {
        if (_dismiss(step)) return step;
      }
    }
    await requestClose();
    return null;
  }

  bool _dismiss(EditorBackStep step) {
    for (final handler in [..._handlers[step]!.reversed]) {
      if (_call(handler)) return true;
    }
    return _call(() => _delegate.dismissForBack(step));
  }

  @override
  Future<void> requestClose({VoidCallback? exitWith}) async {
    if (_closing.value || _leaving || !mounted) {
      _closeLog('close request ignored (closing: ${_closing.value}, leaving: $_leaving, mounted: $mounted)');
      return;
    }
    _exitWith = exitWith;
    final phase = _delegate.shellStatus.value.phase;
    _closeLog('close requested (shell: ${phase.name})');
    if (phase == EditorShellPhase.notFound || phase == EditorShellPhase.failed) {
      // Nothing was opened, so there is nothing to save.
      unawaited(_release());
      _exit();
      return;
    }
    _closing.value = true;
    var saved = false;
    var flushDone = false;
    Future<bool> flush;
    try {
      flush = _delegate.flushBeforeClose();
    } catch (e, s) {
      _report(e, s, 'saving before close');
      flush = Future<bool>.value(false);
    }
    // Errors become "not saved"; the flush itself is never cancelled (FIX-M1).
    flush = flush.then((ok) => ok, onError: (Object e, StackTrace s) {
      _report(e, s, 'saving before close');
      return false;
    }).whenComplete(() => flushDone = true);
    saved = await flush.timeout(_flushTimeout, onTimeout: () => false);
    _closeLog('flushBeforeClose: ${saved ? 'saved' : (flushDone ? 'not saved' : 'still running')}');
    if (!mounted) return;
    var stillSaving = false;
    if (!saved) {
      stillSaving = !flushDone || _delegate.shellStatus.value.save == EditorSaveIndicator.saving;
      final request = EditorLeaveRequest(stillSaving: stillSaving, flush: flush);
      final custom = widget.confirmLeave;
      final leave = custom != null ? await custom(context, request) : await _confirmLeave(context, request);
      if (!mounted) return;
      if (!leave) {
        _closing.value = false;
        return;
      }
      // The save may have landed (or failed) while the dialog showed.
      stillSaving = !flushDone || _delegate.shellStatus.value.save == EditorSaveIndicator.saving;
      if (flushDone && await flush) {
        stillSaving = false;
        saved = true;
      }
      if (!mounted) return;
    }
    if (stillSaving) {
      // Leave now; the save finishes in the background and close() releases the session after it.
      unawaited(_release());
    } else {
      await _release();
    }
    if (!mounted) return;
    _exit();
  }

  Duration get _flushTimeout => widget.flushTimeout ?? EditorLifecycle.defaultFlushTimeout;

  Future<void> _release() async {
    if (_released) return;
    _released = true;
    _closeLog('release: start');
    try {
      await _delegate.close().timeout(_flushTimeout);
      _closeLog('release: end');
    } catch (e, s) {
      if (e is! TimeoutException) {
        _report(e, s, 'closing the editor');
      } else {
        // The delegate's close goes on in the background; leaving never waits for it (FIX-M15).
        _closeLog('release: close still running after ${_flushTimeout.inMilliseconds} ms, leaving anyway');
      }
    }
  }

  void _exit() {
    if (_leaving || !mounted) return;
    _closeLog('leaving the editor');
    setState(() => _leaving = true);
    final exit = _exitWith ?? widget.onExit;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _closeLog('exit callback');
      exit();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  /// A close-step log line (FIX-M15, QA-02 M-15): debug and profile builds only, no user text.
  static void _closeLog(String step) {
    if (kReleaseMode) return;
    debugPrint('[EditorLifecycle] $step');
  }

  Future<bool> _confirmLeave(BuildContext context, EditorLeaveRequest request) async {
    if (!request.stillSaving) {
      return showDanaviewConfirm(
        context,
        title: EditorShellStrings.leaveTitle,
        message: EditorShellStrings.leaveMessage,
        confirmLabel: EditorShellStrings.leave,
        cancelLabel: EditorShellStrings.stay,
        destructive: true,
        icon: Icons.save_rounded,
      );
    }
    var landed = false;
    final result = await showDanaviewDialog<bool>(
      context,
      builder: (_) => _StillSavingDialog(
        status: _delegate.shellStatus,
        flush: request.flush,
        onLanded: () => landed = true,
      ),
    );
    return landed || (result ?? false);
  }

  void _guard(void Function() body) => _call(() {
        body();
        return true;
      });

  bool _call(bool Function() body) {
    try {
      return body();
    } catch (e, s) {
      _report(e, s, 'handling an editor lifecycle event');
      return false;
    }
  }

  void _report(Object e, StackTrace s, String what) => FlutterError.reportError(
        FlutterErrorDetails(exception: e, stack: s, library: 'danaview_editor', context: ErrorDescription(what)),
      );

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: _leaving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(handleBack());
      },
      child: _EditorLifecycleScope(dispatcher: this, child: widget.child),
    );
  }
}

/// "Still saving your latest changes" (FIX-M1): shown when the close flush outlived the timeout.
/// Pops with true as soon as the save lands; shows the failure copy when it fails.
class _StillSavingDialog extends StatefulWidget {
  const _StillSavingDialog({required this.status, required this.flush, required this.onLanded});

  final ValueListenable<EditorShellStatus> status;
  final Future<bool> flush;
  final VoidCallback onLanded;

  @override
  State<_StillSavingDialog> createState() => _StillSavingDialogState();
}

class _StillSavingDialogState extends State<_StillSavingDialog> {
  bool _failed = false;
  bool _flushDone = false;
  bool _closed = false;
  late EditorSaveIndicator _last;

  @override
  void initState() {
    super.initState();
    _last = widget.status.value.save;
    widget.status.addListener(_onStatus);
    widget.flush.then((ok) {
      _flushDone = true;
      if (ok) {
        _land();
      } else if (widget.status.value.save != EditorSaveIndicator.saving) {
        _fail();
      }
    }, onError: (Object _) => _fail());
  }

  @override
  void dispose() {
    widget.status.removeListener(_onStatus);
    super.dispose();
  }

  void _onStatus() {
    final now = widget.status.value.save;
    final was = _last;
    _last = now;
    if (was != EditorSaveIndicator.saving || now == EditorSaveIndicator.saving) return;
    if (now == EditorSaveIndicator.saved) {
      _land();
    } else if (now == EditorSaveIndicator.failed || _flushDone) {
      _fail();
    }
  }

  void _fail() {
    if (!mounted || _closed || _failed) return;
    setState(() => _failed = true);
  }

  void _land() {
    if (!mounted || _closed) return;
    _closed = true;
    widget.onLanded();
    final route = ModalRoute.of(context);
    final navigator = Navigator.of(context);
    if (route == null) return;
    if (route.isCurrent) {
      navigator.pop(true);
    } else if (route.isActive) {
      navigator.removeRoute(route);
    }
  }

  void _answer(bool leave) {
    if (_closed) return;
    _closed = true;
    Navigator.of(context).pop(leave);
  }

  @override
  Widget build(BuildContext context) {
    return DanaviewDialog(
      icon: Icons.save_rounded,
      iconColor: _failed ? DanaviewColors.errorLight : DanaviewColors.primaryLight,
      title: _failed ? EditorShellStrings.leaveTitle : EditorShellStrings.stillSavingTitle,
      message: _failed ? EditorShellStrings.leaveMessage : EditorShellStrings.stillSavingMessage,
      actions: [
        DanaviewButton.secondary(label: EditorShellStrings.stay, onPressed: () => _answer(false)),
        DanaviewButton(
          label: EditorShellStrings.leave,
          variant: _failed ? DanaviewButtonVariant.destructive : DanaviewButtonVariant.primary,
          onPressed: () => _answer(true),
        ),
      ],
    );
  }
}

class _EditorLifecycleScope extends InheritedWidget {
  const _EditorLifecycleScope({required this.dispatcher, required super.child});

  final EditorBackDispatcher dispatcher;

  @override
  bool updateShouldNotify(_EditorLifecycleScope oldWidget) => !identical(oldWidget.dispatcher, dispatcher);
}
