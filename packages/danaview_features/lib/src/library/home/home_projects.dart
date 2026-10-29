// The Home's editor projects (DESIGN_SYSTEM §10.3 #3 and §10.4 `Projects`): the Overview's
// Projects section (a grid of project cards with "Open projects" in the header) and the Projects
// tab (the same cards for every project, with "New project" as the screen's one primary button).
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

/// How many project cards the Overview's Projects section shows at most.
const int homeProjectsOverviewLimit = 6;

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

/// The Overview's Projects section (§10.3 #3): a grid of the newest project cards with "Open
/// projects" in the header. It draws nothing without projects or without an open callback.
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
    final openAll = callbacks.onOpenProjects;
    return Column(
      key: const ValueKey('home-projects'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        DanaviewLibrarySectionHeader(
          'Projects',
          prominent: true,
          action: openAll == null
              ? null
              : DanaviewButton.text(
                  key: const ValueKey('home-projects-open-all'),
                  label: 'Open projects',
                  size: DanaviewButtonSize.sm,
                  onPressed: openAll,
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

/// The Projects tab (§10.4): every project as a card grid, with "New project" as the screen's one
/// primary button; an empty state with the same button when there are none.
class HomeProjectsTab extends ConsumerWidget {
  /// The tab.
  const HomeProjectsTab({super.key});

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
            SliverPadding(
              padding: padding.copyWith(bottom: 0),
              sliver: SliverToBoxAdapter(
                child: DanaviewLibrarySectionHeader(
                  'Projects',
                  prominent: true,
                  topSpacing: 0,
                  action: callbacks.onOpenProjects == null
                      ? null
                      : DanaviewButton.text(
                          key: const ValueKey('home-projects-manage'),
                          label: 'Manage',
                          size: DanaviewButtonSize.sm,
                          onPressed: callbacks.onOpenProjects,
                        ),
                ),
              ),
            ),
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
