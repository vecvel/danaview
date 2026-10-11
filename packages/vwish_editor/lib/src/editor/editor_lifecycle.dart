// OWNER: UX-07
//
// Editor lifecycle (ux.md §4.7): back handling, app lifecycle saves, memory pressure and
// orientation, plus the port the shell needs from the open editor.
//
// * EditorShellDelegate is what the shell asks of the editor controller. Its members follow the
//   EditorController API of ux.md §16.3 (open, close, undo, redo, saveNow, onApp*) plus three shell
//   hooks (shellStatus, dismissForBack, flushBeforeClose), so UX-08's controller can implement it
//   directly; `editorShellProvider` (editor_screen.dart) picks it up from editorControllerProvider.
// * Back order (Android back, the iOS edge swipe, Esc through EditorBackDispatcher.handleBack):
//   cancel gesture -> close panel -> clear selection -> exit fullscreen -> close the editor with a
//   flush ("Saving…" in the top bar, up to 3 s; on failure "Leave anyway?"). PopScope(canPop:
//   false) keeps the route from popping on its own; the iOS back swipe is disabled with it (V-U3).
//   The close button skips the dismiss steps: it always closes the editor (with the flush).
// * Regions register their own steps (UX-13 cancels a drag, UX-18 leaves fullscreen) with
//   `EditorBackDispatcher.of(context).register(step, handler)`; the delegate is asked after them.
// * App lifecycle: inactive -> delegate.onAppInactive (+ registered gestures cancelled), hidden ->
//   delegate.onAppHidden (flush), resumed -> delegate.onAppResumed; memory pressure ->
//   delegate.onMemoryPressure. Orientation: ScreenOrientationPolicy.enter(free) while mounted.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:vwish_editor_core/model.dart' show TimeUs;
import 'package:vwish_features/orientation.dart';
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

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
  /// waits up to 3 s ([EditorLifecycle.flushTimeout]) and treats a timeout as false.
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
  static EditorBackDispatcher? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_EditorLifecycleScope>()?.dispatcher;

  /// Registers [handler] for [step]; it returns true when it dismissed something. Handlers
  /// registered later run first; the delegate is asked after every handler of the step. Returns a
  /// function that unregisters it (call it from `dispose`).
  VoidCallback register(EditorBackStep step, bool Function() handler);

  /// One back press (Android back, Esc, the iOS swipe): the first step that dismisses something
  /// wins and is returned; when none does, the editor closes (with the flush) and null is
  /// returned.
  Future<EditorBackStep?> handleBack();

  /// The close button: flushes ("Saving…", up to 3 s), asks "Leave anyway?" when the flush failed,
  /// then leaves through the screen's `onClose`.
  Future<void> requestClose();

  /// True while the editor is closing (the top bar shows "Saving…").
  ValueListenable<bool> get closing;
}

// -------------------------------------------------------------------------------------------------
// Lifecycle widget
// -------------------------------------------------------------------------------------------------

/// Back handling, lifecycle saves and orientation for the editor (ux.md §4.7).
class EditorLifecycle extends StatefulWidget {
  /// Creates the lifecycle around [child] for [delegate]; [onExit] leaves the editor route.
  const EditorLifecycle({
    super.key,
    required this.delegate,
    required this.onExit,
    this.initialPlayhead,
    this.confirmLeave,
    required this.child,
  });

  /// How long the close flush may take before the shell asks "Leave anyway?".
  static const Duration flushTimeout = Duration(seconds: 3);

  /// The open editor.
  final EditorShellDelegate delegate;

  /// Leaves the editor (the router's `onClose`). Called after the close flow, one frame after the
  /// route was allowed to pop, so `Navigator.maybePop` works as well as `pop`.
  final VoidCallback onExit;

  /// Exact seek target on open.
  final TimeUs? initialPlayhead;

  /// Asks whether to leave after a failed flush (default: a Vwish confirm dialog).
  final Future<bool> Function(BuildContext context)? confirmLeave;

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
  Future<void> requestClose() async {
    if (_closing.value || _leaving || !mounted) return;
    final phase = _delegate.shellStatus.value.phase;
    if (phase == EditorShellPhase.notFound || phase == EditorShellPhase.failed) {
      // Nothing was opened, so there is nothing to save.
      unawaited(_release());
      _exit();
      return;
    }
    _closing.value = true;
    var saved = false;
    try {
      saved = await _delegate.flushBeforeClose().timeout(EditorLifecycle.flushTimeout, onTimeout: () => false);
    } catch (e, s) {
      _report(e, s, 'saving before close');
    }
    if (!mounted) return;
    if (!saved) {
      final ask = widget.confirmLeave ?? _confirmLeave;
      final leave = await ask(context);
      if (!mounted) return;
      if (!leave) {
        _closing.value = false;
        return;
      }
    }
    await _release();
    if (!mounted) return;
    _exit();
  }

  Future<void> _release() async {
    try {
      await _delegate.close().timeout(EditorLifecycle.flushTimeout);
    } catch (e, s) {
      if (e is! TimeoutException) _report(e, s, 'closing the editor');
    }
  }

  void _exit() {
    if (_leaving || !mounted) return;
    setState(() => _leaving = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onExit());
    WidgetsBinding.instance.scheduleFrame();
  }

  static Future<bool> _confirmLeave(BuildContext context) => showVwishConfirm(
        context,
        title: EditorShellStrings.leaveTitle,
        message: EditorShellStrings.leaveMessage,
        confirmLabel: EditorShellStrings.leave,
        cancelLabel: EditorShellStrings.stay,
        destructive: true,
        icon: Icons.save_rounded,
      );

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
        FlutterErrorDetails(exception: e, stack: s, library: 'vwish_editor', context: ErrorDescription(what)),
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

class _EditorLifecycleScope extends InheritedWidget {
  const _EditorLifecycleScope({required this.dispatcher, required super.child});

  final EditorBackDispatcher dispatcher;

  @override
  bool updateShouldNotify(_EditorLifecycleScope oldWidget) => !identical(oldWidget.dispatcher, dispatcher);
}
