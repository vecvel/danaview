// OWNER: UX-05
//
// The Projects screen (ARCH §17.1, ux.md §5): a responsive grid of project cards (one column of
// horizontal cards below 340 px), sort (Recent, Name; remembered) and search (more than 8
// projects), the recovery banner (UX-40's widget) when a project closed unexpectedly, the storage
// footer, and the empty, loading, error and unsupported-device states. "New" opens UX-06's New
// project sheet and opens the created project. Deleting hides a card at once and shows an undo bar
// for 5 s; the deletion is committed when the bar expires, when the screen goes away or when the
// app is hidden. Navigation comes from the router (INT-02).
//
// QA-04: the time from the screen's first build to the first frame with the project list is
// recorded as `EditorPerfMarks.projectsFirstPaint`.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' show Icons, Scaffold;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart' show ProjectId, TimeUs;
import 'package:danaview_editor_core/store.dart' show ProjectSummary;
import 'package:danaview_features/chrome.dart';
import 'package:danaview_features/storage.dart' show formatDataSize;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../app/editor_availability.dart';
import '../app/strings/projects_strings.dart';
import '../debug/perf_hooks.dart';
import 'new_project_sheet.dart';
import 'project_actions.dart';
import 'project_card.dart';
import 'projects_controller.dart';
import 'recovery_banner.dart';

/// Opens a project in the editor (the router pushes `/editor/:id?t=`).
typedef OpenProjectCallback = void Function(ProjectId id, {TimeUs? initialPlayhead});

/// Smallest grid card width (ux.md §5.1).
const double _minCardWidth = 160;

/// Gap between cards.
const double _cardGap = 12;

/// Widest content area (6 columns of 160 px cards fit).
const double _maxContentWidth = 1120;

/// Below this window width the list uses one column of horizontal cards (ux.md §5.1).
const double _rowLayoutBelow = 340;

/// Side padding of the Projects content: the library gutter, centred at most [_maxContentWidth].
EdgeInsets projectsInsets(double width) {
  final gutter = DanaviewBreakpoints.isCompactWidth(width) ? DanaviewSpacing.lg : DanaviewSpacing.xl;
  final extra = math.max(0.0, (width - 2 * gutter - _maxContentWidth) / 2);
  return EdgeInsets.symmetric(horizontal: gutter + extra);
}

/// Grid columns for a window [width] (ux.md §5.1): 1 below 340 px, else
/// `clamp(floor((width - 2·gutter + 12) / (160 + 12)), 2, 6)`.
int projectsColumns(double width) {
  if (width < _rowLayoutBelow) return 1;
  final inner = width - projectsInsets(width).horizontal;
  return ((inner + _cardGap) / (_minCardWidth + _cardGap)).floor().clamp(2, 6);
}

/// The Projects screen (ARCH §17.1, ux.md §5). Navigation comes from the router (INT-02).
class ProjectsScreen extends ConsumerStatefulWidget {
  /// Creates the screen.
  const ProjectsScreen({super.key, required this.onBack, required this.onOpenProject, this.onManageStorage});

  /// Leaves the screen.
  final VoidCallback onBack;

  /// Opens a project.
  final OpenProjectCallback onOpenProject;

  /// Opens Settings › Storage (the footer link); null shows the footer without a link.
  final VoidCallback? onManageStorage;

  @override
  ConsumerState<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends ConsumerState<ProjectsScreen> {
  EditorPerfSpan? _firstPaint = EditorPerfHooks.begin(EditorPerfMarks.projectsFirstPaint);
  StreamSubscription<ProjectsNotice>? _notices;
  late final AppLifecycleListener _lifecycle;
  bool _creating = false;

  ProjectsController get _controller => ref.read(projectsControllerProvider.notifier);

  @override
  void initState() {
    super.initState();
    _notices = _controller.notices.listen((notice) {
      if (mounted) showProjectsFailure(context, notice);
    });
    // Deletions waiting in the undo window happen before the app may be killed.
    _lifecycle = AppLifecycleListener(onHide: () => unawaited(_controller.commitPendingDeletes()));
  }

  @override
  void dispose() {
    _firstPaint?.end(args: const {'state': 'closed'});
    unawaited(_notices?.cancel());
    _lifecycle.dispose();
    super.dispose();
  }

  void _open(ProjectId id) => widget.onOpenProject(id);

  Future<void> _create() async {
    if (_creating) return;
    _creating = true;
    try {
      final id = await showNewProjectSheet(context);
      if (id != null && mounted) _open(id);
    } finally {
      _creating = false;
    }
  }

  void _markFirstPaint(ProjectsState state) {
    final span = _firstPaint;
    if (span == null || state.projects.isLoading) return;
    _firstPaint = null;
    final args = state.projects.hasError ? const {'state': 'error'} : {'projects': state.count};
    WidgetsBinding.instance.addPostFrameCallback((_) => span.end(args: args));
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(projectsControllerProvider);
    final support = ref.watch(editorDeviceSupportProvider).valueOrNull;
    final unsupported = support is EditorUnsupported ? support : null;
    _markFirstPaint(state);
    final showNew = unsupported == null && state.projects.hasValue;
    return Scaffold(
      backgroundColor: DanaviewColors.background,
      body: Stack(
        children: [
          Positioned.fill(
            child: DanaviewLibraryFrame(
              topBar: _ProjectsTopBar(
                title: ProjectsStrings.title,
                subtitle: unsupported == null && state.projects.hasValue && state.count > 0 ? ProjectsStrings.count(state.count) : null,
                onBack: widget.onBack,
                actions: [
                  if (showNew)
                    DanaviewButton.primary(
                      key: const ValueKey('projects-new'),
                      label: ProjectsStrings.newShort,
                      icon: Icons.add_rounded,
                      size: DanaviewButtonSize.sm,
                      semanticLabel: ProjectsStrings.newSemantic,
                      onPressed: _create,
                    ),
                ],
              ),
              body: unsupported != null ? _UnsupportedState(reason: unsupported.reason, onBack: widget.onBack) : _body(state),
            ),
          ),
          if (state.pendingDelete.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _UndoBar(state: state, onUndo: _controller.undoLatestDelete),
            ),
        ],
      ),
    );
  }

  Widget _body(ProjectsState state) {
    return state.projects.when(
      skipLoadingOnRefresh: false,
      loading: () => const Center(child: DanaviewSpinner(semanticLabel: ProjectsStrings.loading)),
      error: (_, __) => DanaviewEmptyState(
        icon: Icons.error_outline_rounded,
        iconColor: DanaviewColors.errorLight,
        title: ProjectsStrings.errorTitle,
        message: ProjectsStrings.errorMessage,
        actions: [DanaviewButton.primary(label: ProjectsStrings.retry, icon: Icons.refresh_rounded, onPressed: _controller.refresh)],
      ),
      data: (_) => state.count == 0 && state.recoverable.isEmpty
          ? DanaviewEmptyState(
              key: const ValueKey('projects-empty'),
              icon: Icons.movie_edit,
              title: ProjectsStrings.emptyTitle,
              message: ProjectsStrings.emptyMessage,
              actions: [
                DanaviewButton.primary(label: ProjectsStrings.newProject, icon: Icons.add_rounded, onPressed: _create),
              ],
            )
          : _list(state),
    );
  }

  Widget _list(ProjectsState state) {
    final actions = ProjectActions(controller: _controller, onOpen: _open);
    final now = ref.watch(projectsClockProvider)();
    final visible = state.visible;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final insets = projectsInsets(width);
        final columns = projectsColumns(width);
        final layout = columns == 1 ? ProjectCardLayout.row : ProjectCardLayout.grid;
        final rows = (visible.length / columns).ceil();
        final bottomSafe = MediaQuery.paddingOf(context).bottom;
        Widget card(ProjectSummary summary, {required bool reserveBadgeLine}) => ProjectCard(
              summary: summary,
              now: now,
              layout: layout,
              reserveBadgeLine: reserveBadgeLine,
              onOpen: () => actions.open(context, summary),
              menuEntries: actions.menuFor(context, summary),
              semanticActions: actions.semanticActionsFor(context, summary),
            );
        return CustomScrollView(
          key: const ValueKey('projects-list'),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            if (state.recoverable.isNotEmpty)
              SliverPadding(
                padding: insets.copyWith(top: DanaviewSpacing.md),
                sliver: const SliverToBoxAdapter(child: RecoveryBanner()),
              ),
            SliverPadding(
              padding: insets.copyWith(top: DanaviewSpacing.md, bottom: DanaviewSpacing.md),
              sliver: SliverToBoxAdapter(
                child: _Toolbar(
                  sort: state.sort,
                  searchable: state.searchable,
                  query: state.query,
                  onSort: _controller.setSort,
                  onQuery: _controller.setQuery,
                ),
              ),
            ),
            if (visible.isEmpty && state.query.trim().isNotEmpty)
              SliverPadding(
                padding: insets,
                sliver: SliverToBoxAdapter(
                  child: DanaviewInlineEmpty(
                    key: const ValueKey('projects-no-match'),
                    icon: Icons.search_off_rounded,
                    title: ProjectsStrings.noMatchTitle(state.query.trim()),
                    message: ProjectsStrings.noMatchMessage,
                  ),
                ),
              )
            else
              SliverPadding(
                padding: insets,
                sliver: SliverList.builder(
                  itemCount: rows,
                  itemBuilder: (context, row) {
                    final start = row * columns;
                    final items = visible.sublist(start, math.min(start + columns, visible.length));
                    final reserve = items.any((s) => ProjectBadge.of(s).isNotEmpty);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: _cardGap),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var i = 0; i < columns; i++) ...[
                            if (i > 0) const SizedBox(width: _cardGap),
                            Expanded(
                              child: i < items.length ? card(items[i], reserveBadgeLine: reserve) : const SizedBox.shrink(),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
              ),
            if (state.totalBytes > 0 || widget.onManageStorage != null)
              SliverPadding(
                padding: insets.copyWith(top: DanaviewSpacing.sm),
                sliver: SliverToBoxAdapter(
                  child: _Footer(totalBytes: state.totalBytes, onManageStorage: widget.onManageStorage),
                ),
              ),
            SliverToBoxAdapter(
              child: SizedBox(height: bottomSafe + DanaviewSpacing.xl + (state.pendingDelete.isNotEmpty ? 76 : 0)),
            ),
          ],
        );
      },
    );
  }
}

/// The library top bar (back, title with the project count, actions) aligned with the Projects
/// content, which may be wider than other library pages (up to 6 columns of cards).
class _ProjectsTopBar extends StatelessWidget {
  const _ProjectsTopBar({required this.title, required this.subtitle, required this.onBack, required this.actions});

  final String title;
  final String? subtitle;
  final VoidCallback onBack;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final insets = projectsInsets(constraints.maxWidth);
        final sub = subtitle;
        return Padding(
          padding: EdgeInsets.fromLTRB(math.max(4.0, insets.left - 12), 6, math.max(4.0, insets.right - 8), 6),
          child: Row(
            children: [
              DanaviewIconButton(icon: Icons.arrow_back_ios_new_rounded, iconSize: 18, tooltip: ProjectsStrings.back, onPressed: onBack),
              const SizedBox(width: DanaviewSpacing.xs),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: DanaviewTextStyles.title),
                    ),
                    if (sub != null) Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: DanaviewTextStyles.caption),
                  ],
                ),
              ),
              if (actions.isNotEmpty) ...[
                const SizedBox(width: DanaviewSpacing.xs),
                ...actions,
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Below this toolbar width the Sort control collapses to a 44 px icon button next to the search.
const double projectsToolbarCompactWidth = 480;

/// The search field (with more than 8 projects) and the Sort control right next to it in one row:
/// the search takes all the width Sort leaves (12 px gap, Sort ends at the content edge). Narrower
/// than [projectsToolbarCompactWidth] Sort is an icon button opening the same menu.
class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.sort, required this.searchable, required this.query, required this.onSort, required this.onQuery});

  final ProjectSort sort;
  final bool searchable;
  final String query;
  final ValueChanged<ProjectSort> onSort;
  final ValueChanged<String> onQuery;

  @override
  Widget build(BuildContext context) {
    final dropdown = DanaviewDropdown<ProjectSort>(
      key: const ValueKey('projects-sort'),
      value: sort,
      label: ProjectsStrings.sortLabel,
      icon: Icons.sort_rounded,
      maxWidth: 220,
      menuWidth: 180,
      options: [for (final s in ProjectSort.values) DanaviewOption(value: s, label: ProjectsStrings.sortName(s))],
      onChanged: onSort,
    );
    if (!searchable) return Align(alignment: AlignmentDirectional.centerStart, child: dropdown);
    final search = DanaviewSearchField(
      key: const ValueKey('projects-search'),
      hint: ProjectsStrings.searchHint,
      semanticLabel: ProjectsStrings.searchHint,
      onChanged: onQuery,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < projectsToolbarCompactWidth) {
          return Row(
            key: const ValueKey('projects-toolbar-compact'),
            children: [
              Expanded(child: search),
              const SizedBox(width: DanaviewSpacing.md),
              DanaviewMenuAnchor(
                width: 180,
                alignment: DanaviewMenuAlignment.end,
                entries: [
                  const DanaviewMenuHeader(ProjectsStrings.sortLabel),
                  for (final s in ProjectSort.values)
                    DanaviewMenuItem(label: ProjectsStrings.sortName(s), selected: s == sort, onTap: () => onSort(s)),
                ],
                builder: (context, open, isOpen) => DanaviewIconButton(
                  key: const ValueKey('projects-sort'),
                  icon: Icons.sort_rounded,
                  size: DanaviewSpacing.minTapTarget,
                  variant: DanaviewIconButtonVariant.filled,
                  selected: isOpen,
                  tooltip: ProjectsStrings.sortButton(sort),
                  semanticLabel: ProjectsStrings.sortButton(sort),
                  onPressed: open,
                ),
              ),
            ],
          );
        }
        return Row(
          key: const ValueKey('projects-toolbar'),
          children: [
            Expanded(child: search),
            const SizedBox(width: DanaviewSpacing.md),
            dropdown,
          ],
        );
      },
    );
  }
}

/// `Projects use 1.4 GB · Manage storage ›`.
class _Footer extends StatelessWidget {
  const _Footer({required this.totalBytes, required this.onManageStorage});

  final int totalBytes;
  final VoidCallback? onManageStorage;

  @override
  Widget build(BuildContext context) {
    final style = DanaviewTextStyles.caption.copyWith(color: DanaviewColors.textSecondary);
    final open = onManageStorage;
    return Wrap(
      key: const ValueKey('projects-footer'),
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: DanaviewSpacing.xs,
      children: [
        if (totalBytes > 0) Text(ProjectsStrings.footer(formatDataSize(totalBytes)), style: style, textAlign: TextAlign.center),
        if (open != null)
          DanaviewButton.ghost(
            key: const ValueKey('projects-manage-storage'),
            label: ProjectsStrings.manageStorage,
            trailingIcon: Icons.chevron_right_rounded,
            size: DanaviewButtonSize.sm,
            onPressed: open,
          ),
      ],
    );
  }
}

/// The undo bar of pending deletions (ux.md §5.2): the latest one can be brought back.
class _UndoBar extends StatelessWidget {
  const _UndoBar({required this.state, required this.onUndo});

  final ProjectsState state;
  final VoidCallback onUndo;

  @override
  Widget build(BuildContext context) {
    final pending = state.pendingDelete;
    final text = pending.length == 1
        ? ProjectsStrings.deleted(state.summaryOf(pending.first)?.name ?? '')
        : ProjectsStrings.deletedMany(pending.length);
    return LayoutBuilder(
      builder: (context, constraints) {
        final insets = projectsInsets(constraints.maxWidth);
        return SafeArea(
          top: false,
          minimum: const EdgeInsets.only(bottom: DanaviewSpacing.md),
          child: Padding(
            padding: insets,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Semantics(
                  liveRegion: true,
                  container: true,
                  child: DanaviewSurface(
                    key: const ValueKey('projects-undo-bar'),
                    color: DanaviewColors.surfaceElevatedHigher,
                    shadow: DanaviewShadow.soft,
                    padding: const EdgeInsets.fromLTRB(DanaviewSpacing.md, DanaviewSpacing.xs, DanaviewSpacing.xs, DanaviewSpacing.xs),
                    child: Row(
                      children: [
                        const Icon(Icons.delete_outline_rounded, size: 20, color: DanaviewColors.textSecondary),
                        const SizedBox(width: DanaviewSpacing.sm),
                        Expanded(
                          child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: DanaviewTextStyles.body),
                        ),
                        const SizedBox(width: DanaviewSpacing.xs),
                        DanaviewButton.tonal(
                          key: const ValueKey('projects-undo'),
                          label: ProjectsStrings.undo,
                          icon: Icons.undo_rounded,
                          size: DanaviewButtonSize.sm,
                          onPressed: onUndo,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The device can't run the editor (ARCH §3.2): why, and what still works.
class _UnsupportedState extends StatelessWidget {
  const _UnsupportedState({required this.reason, required this.onBack});

  final String reason;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => DanaviewEmptyState(
        key: const ValueKey('projects-unsupported'),
        icon: Icons.movie_edit,
        iconColor: DanaviewColors.warning,
        title: ProjectsStrings.unsupportedTitle,
        message: ProjectsStrings.unsupportedMessage(reason),
        actions: [DanaviewButton.secondary(label: ProjectsStrings.back, icon: Icons.arrow_back_rounded, onPressed: onBack)],
      );
}
