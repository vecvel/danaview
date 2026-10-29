// OWNER: UX-05
//
// One project on the Projects screen (ux.md §5.1): a poster letterboxed in a fixed 16:9 area
// (`Image.file` decoded at the card width, or a placeholder tile), the name, a one-line meta line
// (`1:24 · 9:16 · Edited 2 h ago`) and badges (missing media, unsaved changes, needs update,
// read-only, damaged). Two layouts: a grid card, and a horizontal row for windows narrower than
// 340 px. The card opens on tap; its menu (Open, Rename, Duplicate, Delete) opens from the more
// button, on long-press and on secondary click, and the same actions are semantics custom actions.

import 'dart:io' show File;
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/widgets.dart';
import 'package:danaview_editor_core/model.dart' as core show AspectRatio;
import 'package:danaview_editor_core/store.dart' show ProjectHealth, ProjectSummary;
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../app/strings/projects_strings.dart';

/// How a [ProjectCard] is laid out.
enum ProjectCardLayout {
  /// Poster on top, text below (grid columns).
  grid,

  /// Poster (96 px) on the left, text on the right (one column below 340 px).
  row,
}

/// One badge of a project card.
@immutable
final class ProjectBadge {
  /// Creates a badge.
  const ProjectBadge(this.label, this.color, this.icon);

  /// Text.
  final String label;

  /// Tint (computed contrast against the card surface ≥ 4.5:1).
  final Color color;

  /// Leading icon.
  final IconData icon;

  /// The badges [summary] shows, most important first.
  static List<ProjectBadge> of(ProjectSummary summary) => [
        if (summary.health == ProjectHealth.corrupt)
          const ProjectBadge(ProjectsStrings.corruptBadge, DanaviewColors.errorLight, Icons.report_rounded),
        if (summary.health == ProjectHealth.needsNewerApp)
          const ProjectBadge(ProjectsStrings.needsUpdateBadge, DanaviewColors.warning, Icons.system_update_rounded),
        if (summary.health == ProjectHealth.readOnlyNewer)
          const ProjectBadge(ProjectsStrings.readOnlyBadge, DanaviewColors.textSecondary, Icons.lock_outline_rounded),
        if (summary.missingMediaCount > 0)
          ProjectBadge(ProjectsStrings.missingBadge(summary.missingMediaCount), DanaviewColors.errorLight, Icons.link_off_rounded),
        if (summary.hasRecovery) const ProjectBadge(ProjectsStrings.recoveryBadge, DanaviewColors.warning, Icons.restore_rounded),
      ];
}

/// A semantics action of a card (rename, duplicate, delete).
@immutable
final class ProjectCardAction {
  /// Creates an action.
  const ProjectCardAction(this.label, this.onInvoke);

  /// Spoken label.
  final String label;

  /// Runs the action.
  final VoidCallback onInvoke;
}

/// One project in the grid or list (ux.md §5.1).
class ProjectCard extends StatelessWidget {
  /// Creates the card.
  const ProjectCard({
    super.key,
    required this.summary,
    required this.now,
    this.layout = ProjectCardLayout.grid,
    this.reserveBadgeLine = false,
    this.onOpen,
    this.menuEntries = const [],
    this.semanticActions = const [],
  });

  /// The project.
  final ProjectSummary summary;

  /// The current time (for "Edited 2 h ago").
  final DateTime now;

  /// Grid card or horizontal row.
  final ProjectCardLayout layout;

  /// Grid cards: keep an (invisible) badge line so every card of a grid row has the same height.
  final bool reserveBadgeLine;

  /// Opens the project.
  final VoidCallback? onOpen;

  /// The card menu (more button, long-press, secondary click); empty hides the button.
  final List<DanaviewMenuEntry> menuEntries;

  /// Semantics custom actions (rename, duplicate, delete).
  final List<ProjectCardAction> semanticActions;

  @override
  Widget build(BuildContext context) {
    final badges = ProjectBadge.of(summary);
    final meta = ProjectsStrings.meta(summary.duration, summary.aspect, summary.updatedAt, now);
    final label = ProjectsStrings.cardSemantics(name: summary.name, meta: meta, badges: [for (final b in badges) b.label]);
    if (menuEntries.isEmpty) return _card(context, badges, meta, label, null);
    return DanaviewMenuAnchor(
      entries: menuEntries,
      width: 220,
      alignment: DanaviewMenuAlignment.end,
      builder: (context, open, isOpen) => _card(context, badges, meta, label, open),
    );
  }

  Widget _card(BuildContext context, List<ProjectBadge> badges, String meta, String label, VoidCallback? openMenu) {
    final more = openMenu == null
        ? null
        : DanaviewIconButton(
            icon: Icons.more_horiz_rounded,
            size: 36,
            iconSize: 20,
            color: DanaviewColors.textSecondary,
            tooltip: ProjectsStrings.moreActions,
            semanticLabel: '${ProjectsStrings.moreActions}: ${summary.name}',
            onPressed: openMenu,
          );
    final content = switch (layout) {
      ProjectCardLayout.grid => _GridBody(summary: summary, meta: meta, badges: badges, reserveBadgeLine: reserveBadgeLine, more: more),
      ProjectCardLayout.row => _RowBody(summary: summary, meta: meta, badges: badges, more: more),
    };
    return Semantics(
      customSemanticsActions: {
        for (final action in semanticActions) CustomSemanticsAction(label: action.label): action.onInvoke,
      },
      child: Listener(
        // Secondary click opens the menu (desktop and iPad pointers).
        onPointerDown: openMenu == null
            ? null
            : (event) {
                if (event.buttons == kSecondaryMouseButton) openMenu();
              },
        child: DanaviewPressable(
          key: ValueKey('project-card-${summary.id}'),
          onTap: onOpen,
          onLongPress: openMenu,
          semanticLabel: label,
          borderRadius: DanaviewRadius.mediaAll,
          child: DanaviewSurface(
            color: DanaviewColors.surface,
            shadow: DanaviewShadow.subtle,
            child: content,
          ),
        ),
      ),
    );
  }
}

class _GridBody extends StatelessWidget {
  const _GridBody({required this.summary, required this.meta, required this.badges, required this.reserveBadgeLine, required this.more});

  final ProjectSummary summary;
  final String meta;
  final List<ProjectBadge> badges;
  final bool reserveBadgeLine;
  final Widget? more;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(
            aspectRatio: 16 / 9, child: ExcludeSemantics(child: ProjectPoster(path: summary.thumbnailPath, aspect: summary.aspect))),
        Padding(
          padding:
              EdgeInsets.fromLTRB(DanaviewSpacing.md, DanaviewSpacing.sm, more == null ? DanaviewSpacing.md : DanaviewSpacing.xxs, DanaviewSpacing.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: ExcludeSemantics(child: _Name(summary.name, maxLines: 1))),
                  if (more != null) more!,
                ],
              ),
              ExcludeSemantics(
                child: Padding(
                  padding: EdgeInsets.only(right: more == null ? 0 : DanaviewSpacing.sm),
                  child: _Meta(meta, maxLines: 1),
                ),
              ),
              if (badges.isNotEmpty || reserveBadgeLine) ...[
                const SizedBox(height: DanaviewSpacing.sm),
                ExcludeSemantics(child: _BadgeLine(badges)),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _RowBody extends StatelessWidget {
  const _RowBody({required this.summary, required this.meta, required this.badges, required this.more});

  final ProjectSummary summary;
  final String meta;
  final List<ProjectBadge> badges;
  final Widget? more;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(DanaviewSpacing.sm, DanaviewSpacing.sm, more == null ? DanaviewSpacing.md : DanaviewSpacing.xxs, DanaviewSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: ClipRRect(
              borderRadius: DanaviewRadius.thumbAll,
              child: AspectRatio(
                  aspectRatio: 16 / 9, child: ExcludeSemantics(child: ProjectPoster(path: summary.thumbnailPath, aspect: summary.aspect))),
            ),
          ),
          const SizedBox(width: DanaviewSpacing.md),
          Expanded(
            child: ExcludeSemantics(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Name(summary.name, maxLines: 2),
                  const SizedBox(height: 2),
                  _Meta(meta, maxLines: 2),
                  if (badges.isNotEmpty) ...[
                    const SizedBox(height: DanaviewSpacing.xs + 2),
                    Wrap(
                      spacing: DanaviewSpacing.xs,
                      runSpacing: DanaviewSpacing.xs,
                      children: [for (final b in badges) DanaviewBadge(b.label, color: b.color, icon: b.icon)],
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (more != null) more!,
        ],
      ),
    );
  }
}

class _Name extends StatelessWidget {
  const _Name(this.name, {required this.maxLines});

  final String name;
  final int maxLines;

  @override
  Widget build(BuildContext context) => Text(
        name,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: DanaviewTextStyles.headline.copyWith(fontWeight: FontWeight.w600),
      );
}

class _Meta extends StatelessWidget {
  const _Meta(this.meta, {required this.maxLines});

  final String meta;
  final int maxLines;

  @override
  Widget build(BuildContext context) => Text(
        meta,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: DanaviewTextStyles.caption.copyWith(color: DanaviewColors.textSecondary),
      );
}

/// Badges on one line; each shrinks (ellipsis) when the card is narrow. An empty line keeps the
/// height of a badge so grid rows stay even.
class _BadgeLine extends StatelessWidget {
  const _BadgeLine(this.badges);

  final List<ProjectBadge> badges;

  @override
  Widget build(BuildContext context) {
    if (badges.isEmpty) {
      return const Visibility(
        visible: false,
        maintainSize: true,
        maintainAnimation: true,
        maintainState: true,
        child: Align(alignment: Alignment.centerLeft, child: DanaviewBadge(' ', icon: Icons.circle)),
      );
    }
    return Row(
      children: [
        for (final (i, b) in badges.indexed) ...[
          if (i > 0) const SizedBox(width: DanaviewSpacing.xs),
          Flexible(child: DanaviewBadge(b.label, color: b.color, icon: b.icon)),
        ],
      ],
    );
  }
}

/// A project poster letterboxed (project aspect) inside the space it is given, or a placeholder.
class ProjectPoster extends StatelessWidget {
  /// Creates the poster for the absolute [path] (null: placeholder) of a project with [aspect].
  const ProjectPoster({super.key, required this.path, required this.aspect});

  /// Absolute poster path, or null.
  final String? path;

  /// The project's canvas aspect.
  final core.AspectRatio aspect;

  @override
  Widget build(BuildContext context) {
    final poster = path;
    return ColoredBox(
      color: DanaviewColors.surfaceElevatedHigher,
      child: Center(
        child: AspectRatio(
          aspectRatio: aspect.value.clamp(0.25, 4.0),
          child: poster == null
              ? const _PosterPlaceholder()
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final dpr = MediaQuery.devicePixelRatioOf(context);
                    final width = constraints.hasBoundedWidth ? constraints.maxWidth : 320.0;
                    return Image.file(
                      File(poster),
                      fit: BoxFit.cover,
                      cacheWidth: math.max(1, (width * dpr).round()),
                      gaplessPlayback: true,
                      excludeFromSemantics: true,
                      errorBuilder: (context, error, stack) => const _PosterPlaceholder(),
                    );
                  },
                ),
        ),
      ),
    );
  }
}

class _PosterPlaceholder extends StatelessWidget {
  const _PosterPlaceholder();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: DanaviewColors.surfaceElevated,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final side = math.min(constraints.maxWidth, constraints.maxHeight);
          if (!side.isFinite || side < 20) return const SizedBox.expand();
          return Center(
            child: Semantics(
              label: ProjectsStrings.noPoster,
              child: DanaviewIconTile(Icons.movie_edit, size: math.min(40, side * 0.7)),
            ),
          );
        },
      ),
    );
  }
}
