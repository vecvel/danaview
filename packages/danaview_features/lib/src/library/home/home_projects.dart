// The Home's editor projects (DESIGN_SYSTEM §10.3 and §10.4): the Overview's Recent projects
// section (the newest two project cards, "See all" in the header), the Videos tab's Projects row
// (a "New project" card, then the project cards, "See all" in the header) and the Projects screen
// that "See all" opens (every project in a card grid, with "New project" as the screen's one
// primary button and "Manage" opening the editor's own project list).
//
// This package never imports the editor (ARCH v1.2 rule 23): the app root maps the editor's
// project list onto [HomeProject]s by overriding [homeProjectsProvider] (lib/wiring), and opens a
// project or the New project sheet through [HomeCallbacks.onOpenProject] and
// [HomeCallbacks.onNewProject]. Without the editor the list stays empty and both are hidden.

import 'dart:io' show File;
import 'dart:math' as math;

import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../library_widgets.dart';
import 'home_callbacks.dart';
import 'home_grid.dart';
import 'home_media_card.dart';
import 'home_tabs.dart';

/// One editor project as the Home shows it.
@immutable
class HomeProject {
  /// A project [id] named [name], last edited at [updatedAt].
  const HomeProject({required this.id, required this.name, required this.updatedAt, this.thumbnailPath});

  /// The editor's project id (the router opens `/editor/<id>`).
  final String id;

  /// The project name.
  final String name;

  /// The last change.
  final DateTime updatedAt;

  /// The absolute poster path, or null (a neutral placeholder is drawn).
  final String? thumbnailPath;

  @override
  bool operator ==(Object other) =>
      other is HomeProject &&
      other.id == id &&
      other.name == name &&
      other.updatedAt == updatedAt &&
      other.thumbnailPath == thumbnailPath;

  @override
  int get hashCode => Object.hash(id, name, updatedAt, thumbnailPath);
}

/// The editor's projects, most recently edited first. Empty unless the app root overrides it
/// (only where the editor runs and was wired), so the Projects section stays hidden.
final homeProjectsProvider = Provider<List<HomeProject>>((ref) => const [], name: 'homeProjectsProvider');

/// The current time for the "Edited 2 h ago" lines (overridden in tests).
final homeProjectsClockProvider = Provider<DateTime Function()>((ref) => DateTime.now, name: 'homeProjectsClockProvider');

const List<String> _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "Edited just now", "Edited 5 min ago", "Edited 2 h ago", "Edited yesterday", "Edited 3 days
/// ago", "Edited 12 Oct", "Edited 12 Oct 2025" (the editor's Projects screen wording).
String homeProjectEditedLabel(DateTime updatedAt, DateTime now) {
  final diff = now.difference(updatedAt);
  if (diff.inMinutes < 1) return 'Edited just now';
  if (diff.inHours < 1) return 'Edited ${diff.inMinutes} min ago';
  final local = updatedAt.toLocal();
  final today = now.toLocal();
  final days = DateTime(today.year, today.month, today.day).difference(DateTime(local.year, local.month, local.day)).inDays;
  if (days <= 0) return 'Edited ${diff.inHours} h ago';
  if (days == 1) return 'Edited yesterday';
  if (days < 7) return 'Edited $days days ago';
  final date = '${local.day} ${_months[local.month - 1]}';
  return local.year == today.year ? 'Edited $date' : 'Edited $date ${local.year}';
}

/// How many project cards the Overview's Recent projects section shows at most.
const int homeProjectsOverviewLimit = 2;

/// Opens the Projects screen from [context] (inside the Home shell).
void homeOpenProjectsScreen(BuildContext context) =>
    const HomeDestinationRequestNotification(HomeDestination.projects).dispatch(context);

/// One project card: the poster in a 16:9 media card, the name and "Edited 2 h ago".
class HomeProjectCard extends StatelessWidget {
  /// The card of [project]; [onOpen] opens it in the editor.
  const HomeProjectCard({super.key, required this.project, required this.now, this.onOpen});

  /// The project.
  final HomeProject project;

  /// The current time.
  final DateTime now;

  /// Opens the project.
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final edited = homeProjectEditedLabel(project.updatedAt, now);
    final poster = project.thumbnailPath;
    return KeyedSubtree(
      key: ValueKey('home-project-${project.id}'),
      child: HomeMediaCard(
        title: project.name,
        subtitle: edited,
        icon: Icons.movie_edit,
        showPlay: false,
        thumbnail: poster == null ? null : _ProjectPoster(path: poster),
        semanticLabel: 'Project ${project.name}, $edited',
        onTap: onOpen,
      ),
    );
  }
}

class _ProjectPoster extends StatelessWidget {
  const _ProjectPoster({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Image.file(
      File(path),
      fit: BoxFit.cover,
      cacheWidth: math.max(1, (320 * dpr).round()),
      gaplessPlayback: true,
      excludeFromSemantics: true,
      errorBuilder: (context, error, stack) => const HomeMediaPlaceholder(icon: Icons.movie_edit),
    );
  }
}

/// The Overview's Recent projects section (§10.3): the newest project cards ([limit]) with "See
/// all" in the header, which opens the Projects screen. It draws nothing without projects or
/// without an open callback.
class HomeProjectsSection extends ConsumerWidget {
  /// The section.
  const HomeProjectsSection({super.key, this.limit = homeProjectsOverviewLimit});

  /// How many cards at most.
  final int limit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final callbacks = HomeCallbacksScope.of(context);
    final projects = ref.watch(homeProjectsProvider);
    final open = callbacks.onOpenProject;
    if (projects.isEmpty || open == null) return const SizedBox.shrink(key: ValueKey('home-projects-hidden'));
    final now = ref.watch(homeProjectsClockProvider)();
    return Column(
      key: const ValueKey('home-projects'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        DanaviewLibrarySectionHeader(
          'Recent projects',
          prominent: true,
          action: DanaviewButton.text(
            key: const ValueKey('home-projects-see-all'),
            label: 'See all',
            size: DanaviewButtonSize.sm,
            onPressed: () => homeOpenProjectsScreen(context),
          ),
        ),
        HomeCardGrid(
          key: const ValueKey('home-projects-grid'),
          columnsFor: homeProjectColumns,
          extent: homeProjectCardExtent,
          children: [
            for (final p in projects.take(limit)) HomeProjectCard(project: p, now: now, onOpen: () => open(p.id)),
          ],
        ),
      ],
    );
  }
}

/// The height of a project card [width] wide (no More menu).
double homeProjectCardExtent(double width, BuildContext context) => homeMediaCardExtent(width, context, menu: false);

/// Columns of project cards in a [width]-wide column: the adaptive 2 / 4 / 6.
int homeProjectColumns(double width) => homeAdaptiveColumns(width);

/// The Projects screen's body (§10.4): every project as a card grid, with "New project" as the
/// screen's one primary button; an empty state with the same button when there are none.
/// "Manage" (the editor's own project list) sits in the screen's top bar
/// ([HomeProjectsManageButton]) or, with [showHeader], in a "Projects" header over the grid.
class HomeProjectsTab extends ConsumerWidget {
  /// The body.
  const HomeProjectsTab({super.key, this.showHeader = true});

  /// Draws the "Projects" header with Manage (off inside the Projects screen, whose top bar has
  /// both).
  final bool showHeader;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final callbacks = HomeCallbacksScope.of(context);
    final projects = ref.watch(homeProjectsProvider);
    final now = ref.watch(homeProjectsClockProvider)();
    final open = callbacks.onOpenProject;
    final create = callbacks.onNewProject;
    final newProject = create == null
        ? null
        : DanaviewButton.primary(
            key: const ValueKey('home-projects-new'),
            label: 'New project',
            icon: Icons.add_rounded,
            onPressed: create,
          );
    return LayoutBuilder(
      builder: (context, constraints) {
        final insets = danaviewLibraryInsets(constraints.maxWidth);
        final padding = insets.copyWith(top: DanaviewSpacing.lg, bottom: MediaQuery.paddingOf(context).bottom + DanaviewSpacing.xxl);
        final width = constraints.maxWidth - padding.horizontal;
        return CustomScrollView(
          key: const PageStorageKey('home-projects-tab'),
          slivers: [
            if (showHeader)
              SliverPadding(
                padding: padding.copyWith(bottom: 0),
                sliver: const SliverToBoxAdapter(child: _ProjectsHeader()),
              )
            else
              SliverToBoxAdapter(child: SizedBox(height: padding.top)),
            if (projects.isEmpty)
              SliverPadding(
                padding: padding.copyWith(top: 0),
                sliver: SliverToBoxAdapter(
                  child: DanaviewInlineEmpty(
                    key: const ValueKey('home-projects-empty'),
                    icon: Icons.movie_edit,
                    title: 'No projects yet',
                    message: 'Edit videos and photos, then export them back to your library.',
                    action: newProject,
                  ),
                ),
              )
            else ...[
              if (newProject != null)
                SliverPadding(
                  padding: padding.copyWith(top: 0, bottom: DanaviewSpacing.md),
                  sliver: SliverToBoxAdapter(child: Align(alignment: AlignmentDirectional.centerStart, child: newProject)),
                ),
              SliverPadding(
                padding: padding.copyWith(top: 0),
                sliver: homeSliverCardGrid(
                  key: const ValueKey('home-projects-tab-grid'),
                  columns: homeProjectColumns(width),
                  width: width,
                  extent: homeProjectCardExtent,
                  itemCount: projects.length,
                  itemBuilder: (context, i) {
                    final p = projects[i];
                    return HomeProjectCard(project: p, now: now, onOpen: open == null ? null : () => open(p.id));
                  },
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// The "Projects" header over the project grid, with Manage.
class _ProjectsHeader extends StatelessWidget {
  const _ProjectsHeader();

  @override
  Widget build(BuildContext context) => const DanaviewLibrarySectionHeader(
        'Projects',
        prominent: true,
        topSpacing: 0,
        action: HomeProjectsManageButton(),
      );
}

/// "Manage": opens the editor's own project list (the Projects screen's top bar, or the header of
/// [HomeProjectsTab]). Draws nothing when the app gave no `onOpenProjects`.
class HomeProjectsManageButton extends StatelessWidget {
  /// The button.
  const HomeProjectsManageButton({super.key});

  @override
  Widget build(BuildContext context) {
    final openAll = HomeCallbacksScope.of(context).onOpenProjects;
    if (openAll == null) return const SizedBox.shrink();
    return DanaviewButton.text(
      key: const ValueKey('home-projects-manage'),
      label: 'Manage',
      size: DanaviewButtonSize.sm,
      onPressed: openAll,
    );
  }
}

/// Whether the Videos tab shows its Projects row: the app opens or creates projects (only where
/// the editor runs and was wired) on an editor platform.
bool homeProjectsRowShown(BuildContext context) {
  final callbacks = HomeCallbacksScope.of(context);
  final available = callbacks.onOpenProject != null || callbacks.onNewProject != null;
  return homeProjectsShown(platform: Theme.of(context).platform, projectsAvailable: available);
}

/// The Videos tab's Projects section (editor only): one horizontal row whose first card is "New
/// project", then the project cards, most recently edited first; "See all" opens the Projects
/// screen. It draws nothing where the editor is not wired, or when it would hold no card.
class HomeProjectsRow extends ConsumerWidget {
  /// The row.
  const HomeProjectsRow({super.key, this.topSpacing});

  /// Space above the header (the header's default when null).
  final double? topSpacing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final callbacks = HomeCallbacksScope.of(context);
    final projects = ref.watch(homeProjectsProvider);
    final open = callbacks.onOpenProject;
    final create = callbacks.onNewProject;
    if (!homeProjectsRowShown(context) || (projects.isEmpty && create == null)) {
      return const SizedBox.shrink(key: ValueKey('home-projects-row-hidden'));
    }
    final now = ref.watch(homeProjectsClockProvider)();
    return Column(
      key: const ValueKey('home-projects-row'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        DanaviewLibrarySectionHeader(
          'Projects',
          prominent: true,
          topSpacing: topSpacing ?? DanaviewSpacing.xl,
          action: DanaviewButton.text(
            key: const ValueKey('home-projects-row-see-all'),
            label: 'See all',
            size: DanaviewButtonSize.sm,
            onPressed: () => homeOpenProjectsScreen(context),
          ),
        ),
        HomeMediaCardRow(
          children: [
            if (create != null)
              KeyedSubtree(
                key: const ValueKey('home-projects-new-card'),
                child: HomeMediaCard(
                  title: 'New project',
                  subtitle: 'Edit videos and photos',
                  icon: Icons.add_rounded,
                  showPlay: false,
                  semanticLabel: 'New project',
                  onTap: create,
                ),
              ),
            for (final p in projects) HomeProjectCard(project: p, now: now, onOpen: open == null ? null : () => open(p.id)),
          ],
        ),
      ],
    );
  }
}
