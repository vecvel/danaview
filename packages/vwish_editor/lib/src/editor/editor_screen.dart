// OWNER: UX-07
//
// EditorScreen (ARCH §17.1, §17.2; ux.md §4.7, §6): the editor for one project.
//
// * Composition: EditorScope (the ProjectId for every region) -> EditorLifecycle (back order,
//   app lifecycle saves, orientation, close flow) -> a solid Vwish surface whose body depends on
//   the open editor's phase: the EditorScaffold (layout planner + regions) while opening and when
//   ready, or the "This project isn't available" / "Couldn't open this project" empty state.
// * The open editor is an [EditorShellDelegate] from [editorShellProvider]: UX-08's
//   EditorController when it implements the port, else a [DetachedEditorShell] that only resolves
//   the project's name from the repository (so the shell works before the controller lands).
//   INT-02 and tests may override the provider.
// * Top bar actions: close -> the close flow; undo/redo -> the delegate; "Couldn't save · Retry"
//   -> saveNow(manual: true); the title button, long-press on undo and Export invoke the
//   `projectSheet`, `history` and `export` action bindings (UX-29, UX-15/UX-08, UX-39) and are
//   disabled while those are unbound.
// * Navigation callbacks come from the router (INT-02): `onClose` leaves the editor after the
//   close flush, `onOpenProjects` is "Go to Projects" (null hides it).

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Icons, Scaffold;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vwish_editor_core/model.dart' show ProjectId, TimeUs;
import 'package:vwish_editor_core/store.dart' show ProjectRepository, ProjectSummary, StoreFailure, StoreFailureKind;
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import '../app/editor_providers.dart';
import 'contracts/contracts.dart';
import 'editor_lifecycle.dart';
import 'editor_scope.dart';
import 'layout/editor_layout_scope.dart';
import 'layout/editor_scaffold.dart';
import 'layout/editor_shell_strings.dart';
import 'layout/editor_top_bar.dart';
import 'wiring/action_bindings.dart';

export 'editor_lifecycle.dart'
    show EditorBackDispatcher, EditorBackStep, EditorSaveIndicator, EditorShellDelegate, EditorShellPhase, EditorShellStatus;

// -------------------------------------------------------------------------------------------------
// The open editor
// -------------------------------------------------------------------------------------------------

/// The open editor of a project as the shell sees it (ux.md §4.7).
///
/// Resolves to `editorControllerProvider(id).notifier` when UX-08's `EditorController` implements
/// [EditorShellDelegate]; until then (the controller factory throws `UnimplementedError`, or the
/// controller doesn't implement the port) to a [DetachedEditorShell]. Kept alive while an
/// `EditorScreen` for the id is mounted.
final editorShellProvider = Provider.autoDispose.family<EditorShellDelegate, ProjectId>(
  (ref, id) {
    final controller = _controllerOrNull(ref, id);
    if (controller is EditorShellDelegate) return controller;
    final shell = DetachedEditorShell(id: id, repository: ref.watch(projectRepositoryProvider));
    ref.onDispose(shell.dispose);
    return shell;
  },
  name: 'editorShellProvider',
);

Object? _controllerOrNull(Ref<Object?> ref, ProjectId id) {
  try {
    return ref.watch(editorControllerProvider(id).notifier);
    // The placeholder factory (D-33) throws until UX-08 lands; any other failure propagates.
    // ignore: avoid_catching_errors
  } on UnimplementedError {
    return null;
  }
}

/// A shell for the editor while no controller backs it: it resolves the project's name from the
/// repository's summaries (`ready`), or reports an unknown id (`notFound`) or a store failure
/// (`failed`). Nothing can be edited, so there is nothing to undo, save or dismiss.
final class DetachedEditorShell implements EditorShellDelegate {
  /// Creates the shell for [id] in [repository].
  DetachedEditorShell({required this.id, required ProjectRepository repository}) : _repository = repository;

  /// The project.
  final ProjectId id;

  final ProjectRepository _repository;
  final ValueNotifier<EditorShellStatus> _status = ValueNotifier<EditorShellStatus>(EditorShellStatus.opening);
  StreamSubscription<List<ProjectSummary>>? _summaries;
  bool _disposed = false;

  @override
  ValueListenable<EditorShellStatus> get shellStatus => _status;

  void _set(EditorShellStatus status) {
    if (!_disposed) _status.value = status;
  }

  @override
  Future<void> open({TimeUs? initialPlayhead}) async {
    if (_disposed || _summaries != null) return;
    _summaries = _repository.watchSummaries().listen(
      (summaries) {
        final summary = summaries.where((s) => s.id == id).firstOrNull;
        _set(summary == null
            ? const EditorShellStatus(phase: EditorShellPhase.notFound)
            : EditorShellStatus(phase: EditorShellPhase.ready, projectName: summary.name));
      },
      onError: (Object error, StackTrace stack) {
        if (error is StoreFailure && error.kind == StoreFailureKind.notFound) {
          _set(const EditorShellStatus(phase: EditorShellPhase.notFound));
        } else {
          _set(const EditorShellStatus(phase: EditorShellPhase.failed, failureTitle: EditorShellStrings.failedTitle));
        }
      },
    );
  }

  @override
  bool dismissForBack(EditorBackStep step) => false;

  @override
  Future<bool> flushBeforeClose() async => true;

  @override
  Future<void> close() async {
    // Not awaited: cancelling a repository stream may wait on its producer, and closing must not.
    final summaries = _summaries;
    _summaries = null;
    if (summaries != null) unawaited(summaries.cancel());
  }

  @override
  bool undo() => false;

  @override
  bool redo() => false;

  @override
  Future<void> saveNow({bool manual = false}) async {}

  @override
  void onAppInactive() {}

  @override
  void onAppHidden() {}

  @override
  void onAppResumed() {}

  @override
  void onMemoryPressure() {}

  /// Stops listening and releases the status notifier.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(close());
    _status.dispose();
  }
}

// -------------------------------------------------------------------------------------------------
// Screen
// -------------------------------------------------------------------------------------------------

/// The editor for one project (ARCH §17.1, §17.2). Navigation comes from the router (INT-02).
class EditorScreen extends ConsumerWidget {
  /// Creates the screen.
  const EditorScreen({super.key, required this.projectId, this.initialPlayhead, required this.onClose, this.onOpenProjects});

  /// The project to open.
  final ProjectId projectId;

  /// Exact seek target on open (`/editor/:id?t=`), or null.
  final TimeUs? initialPlayhead;

  /// Leaves the editor (after the close flush).
  final VoidCallback onClose;

  /// Opens the Projects screen ('Go to Projects'); null hides that action.
  final VoidCallback? onOpenProjects;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shell = ref.watch(editorShellProvider(projectId));
    return EditorScope(
      projectId: projectId,
      child: EditorLifecycle(
        delegate: shell,
        onExit: onClose,
        initialPlayhead: initialPlayhead,
        child: Scaffold(
          backgroundColor: VwishColors.background,
          resizeToAvoidBottomInset: false,
          body: _ShellStatusSelector<(EditorShellPhase, bool)>(
            status: shell.shellStatus,
            select: (s) => (s.phase, s.inspectorOpen),
            builder: (context, selected) => switch (selected.$1) {
              EditorShellPhase.opening || EditorShellPhase.ready => EditorScaffold(
                  inspectorOpen: selected.$2,
                  loading: selected.$1 == EditorShellPhase.opening,
                  topBar: (context, transport) => _EditorTopBarHost(shell: shell, transport: transport),
                ),
              EditorShellPhase.notFound || EditorShellPhase.failed => _EditorUnavailable(shell: shell, onOpenProjects: onOpenProjects),
            },
          ),
        ),
      ),
    );
  }
}

/// Rebuilds [builder] only when [select] of the status changes (ux.md §16.6).
class _ShellStatusSelector<T> extends StatefulWidget {
  const _ShellStatusSelector({super.key, required this.status, required this.select, required this.builder});

  final ValueListenable<EditorShellStatus> status;
  final T Function(EditorShellStatus status) select;
  final Widget Function(BuildContext context, T selected) builder;

  @override
  State<_ShellStatusSelector<T>> createState() => _ShellStatusSelectorState<T>();
}

class _ShellStatusSelectorState<T> extends State<_ShellStatusSelector<T>> {
  late T _selected = widget.select(widget.status.value);

  @override
  void initState() {
    super.initState();
    widget.status.addListener(_changed);
  }

  @override
  void didUpdateWidget(_ShellStatusSelector<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.status, widget.status)) {
      oldWidget.status.removeListener(_changed);
      widget.status.addListener(_changed);
    }
    _selected = widget.select(widget.status.value);
  }

  @override
  void dispose() {
    widget.status.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final next = widget.select(widget.status.value);
    if (next != _selected) setState(() => _selected = next);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _selected);
}

// -------------------------------------------------------------------------------------------------
// Top bar
// -------------------------------------------------------------------------------------------------

/// The top bar wired to the open editor, the close flow and the action bindings.
class _EditorTopBarHost extends ConsumerWidget {
  const _EditorTopBarHost({required this.shell, this.transport});

  final EditorShellDelegate shell;
  final Widget? transport;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kind = EditorLayoutScope.of(context).kind;
    final dispatcher = EditorBackDispatcher.of(context);
    final bindings = ref.watch(editorActionBindingsProvider);
    final id = EditorScope.idOf(context);

    VoidCallback? action(EditorActionId actionId) {
      final binding = bindings[actionId];
      if (binding == null) return null;
      final ctx = _ShellActionContext(id, context, ref);
      if (binding.isVisible?.call(ctx) == false || binding.isEnabled?.call(ctx) == false) return null;
      return () => _run(binding, ctx);
    }

    return ValueListenableBuilder<bool>(
      valueListenable: dispatcher.closing,
      builder: (context, closing, _) => ValueListenableBuilder<EditorShellStatus>(
        valueListenable: shell.shellStatus,
        builder: (context, status, _) => EditorTopBar(
          kind: kind,
          status: status,
          closing: closing,
          onClose: () => unawaited(dispatcher.requestClose()),
          onTitle: status.phase == EditorShellPhase.ready ? action(EditorActionId.projectSheet) : null,
          onRetrySave: () => unawaited(shell.saveNow(manual: true)),
          onUndo: () => shell.undo(),
          onRedo: () => shell.redo(),
          onHistory: action(EditorActionId.history),
          onExport: status.phase == EditorShellPhase.ready ? action(EditorActionId.export) : null,
          transport: transport,
        ),
      ),
    );
  }

  static void _run(EditorActionBinding binding, EditorActionContext ctx) {
    try {
      final result = binding.handler(ctx);
      if (result is Future<void>) unawaited(result.catchError((Object e, StackTrace s) => _report(binding, e, s)));
    } catch (e, s) {
      _report(binding, e, s);
    }
  }

  static void _report(EditorActionBinding binding, Object e, StackTrace s) => FlutterError.reportError(FlutterErrorDetails(
        exception: e,
        stack: s,
        library: 'vwish_editor',
        context: ErrorDescription('running the ${binding.id.name} action from the editor top bar'),
      ));
}

/// The action context of a top bar button.
final class _ShellActionContext implements EditorActionContext {
  _ShellActionContext(this.projectId, this.context, this._ref);

  @override
  final ProjectId projectId;

  @override
  final BuildContext context;

  final WidgetRef _ref;

  @override
  EditorActionSource get source => EditorActionSource.button;

  @override
  T read<T>(ProviderListenable<T> provider) => _ref.read(provider);
}

// -------------------------------------------------------------------------------------------------
// Unknown project / open failure
// -------------------------------------------------------------------------------------------------

class _EditorUnavailable extends StatelessWidget {
  const _EditorUnavailable({required this.shell, required this.onOpenProjects});

  /// Below this height (in landscape) the close button sits beside the message.
  static const double _sideBySideBelow = 480;

  final EditorShellDelegate shell;
  final VoidCallback? onOpenProjects;

  @override
  Widget build(BuildContext context) {
    final dispatcher = EditorBackDispatcher.of(context);
    final status = shell.shellStatus.value;
    final notFound = status.phase == EditorShellPhase.notFound;
    final goToProjects = onOpenProjects;
    final closeButton = Padding(
      padding: const EdgeInsets.symmetric(horizontal: EditorTopBar.sidePadding, vertical: VwishSpacing.xxs),
      child: VwishIconButton(
        icon: Icons.close_rounded,
        iconSize: 22,
        tooltip: EditorShellStrings.closeEditor,
        onPressed: () => unawaited(dispatcher.requestClose()),
      ),
    );
    final icon = notFound ? Icons.folder_off_rounded : Icons.error_outline_rounded;
    final iconColor = notFound ? VwishColors.primaryLight : VwishColors.errorLight;
    final title = notFound ? EditorShellStrings.unavailableTitle : (status.failureTitle ?? EditorShellStrings.failedTitle);
    final message = notFound ? EditorShellStrings.unavailableMessage : status.failureMessage;
    final action = goToProjects != null
        ? VwishButton.primary(
            label: EditorShellStrings.goToProjects,
            icon: Icons.video_library_rounded,
            onPressed: () => unawaited(dispatcher.requestClose(exitWith: goToProjects)),
          )
        : VwishButton.secondary(
            label: EditorShellStrings.close,
            onPressed: () => unawaited(dispatcher.requestClose()),
          );
    final empty = VwishEmptyState(icon: icon, iconColor: iconColor, title: title, message: message, actions: [action]);
    // Short landscape screens: icon beside the text, so the action stays above the fold.
    final compact = SingleChildScrollView(
      padding: const EdgeInsets.all(VwishSpacing.lg),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: iconColor.withValues(alpha: 0.14), borderRadius: VwishRadius.lgAll),
                child: Icon(icon, size: 24, color: iconColor),
              ),
              const SizedBox(width: VwishSpacing.md),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, maxLines: 3, overflow: TextOverflow.ellipsis, style: VwishTextStyles.title),
                    if (message != null) ...[
                      const SizedBox(height: VwishSpacing.xxs),
                      Text(message, style: VwishTextStyles.bodySecondary),
                    ],
                    const SizedBox(height: VwishSpacing.md),
                    action,
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return SafeArea(
      child: LayoutBuilder(
        // Short landscape screens put the close button beside a compact message (icon beside the
        // text) so the action stays on screen; taller screens use the kit's empty state.
        builder: (context, constraints) => constraints.maxHeight < _sideBySideBelow && constraints.maxWidth > constraints.maxHeight
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [closeButton, Expanded(child: compact)],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(alignment: AlignmentDirectional.centerStart, child: closeButton),
                  Expanded(child: empty),
                ],
              ),
      ),
    );
  }
}
