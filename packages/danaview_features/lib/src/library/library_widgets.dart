import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:danaview_platform/danaview_platform.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

/// Side margin of library content at [width]: 16 below 600, 24 below 1024, 32 from 1024.
double danaviewLibraryGutter(double width) => DanaviewSpacing.pageGutter(width);

/// Side padding of library content: full width minus [danaviewLibraryGutter] each side (no cap).
EdgeInsets danaviewLibraryInsets(double width) => DanaviewSpacing.pageInsets(width);

/// The narrowest card of a library grid (~280 pt; 264 so a 600 pt window gets two columns).
const double danaviewLibraryGridMinTileWidth = 264;

/// The gap between library grid cards, both ways.
const double danaviewLibraryGridGap = DanaviewSpacing.md;

/// The content width from which library lists become card grids: a 600 pt window minus its
/// 24 pt gutters. Phones keep list rows.
const double danaviewLibraryGridMinContentWidth = 600 - 2 * DanaviewSpacing.xl;

/// How many grid columns fit [contentWidth] (1 = keep the list rows).
int danaviewLibraryGridColumns(double contentWidth) {
  if (contentWidth < danaviewLibraryGridMinContentWidth) return 1;
  return math.max(
    1,
    ((contentWidth + danaviewLibraryGridGap) / (danaviewLibraryGridMinTileWidth + danaviewLibraryGridGap)).floor(),
  );
}

/// One card of a library grid (the grid form of a [DanaviewLibraryGroup] row): a §8 `surface`
/// card, radius 12, with the hairline-depth recipe.
class DanaviewLibraryCard extends StatelessWidget {
  const DanaviewLibraryCard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Unclipped so a row's keyboard focus ring is never cut off.
    return DecoratedBox(
      decoration: DanaviewDepth.card(borderRadius: DanaviewRadius.controlAll, shadows: DanaviewShadows.none),
      child: child,
    );
  }
}

/// One row of a library grid: [columns] equal-width cells of equal height (the tallest card), the
/// last row padded with empty cells so cards keep their width.
class DanaviewLibraryGridRow extends StatelessWidget {
  const DanaviewLibraryGridRow({super.key, required this.columns, required this.children});

  final int columns;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < columns; i++) ...[
            if (i > 0) const SizedBox(width: danaviewLibraryGridGap),
            Expanded(child: i < children.length ? DanaviewLibraryCard(child: children[i]) : const SizedBox.shrink()),
          ],
        ],
      ),
    );
  }
}

/// Library rows that wrap into a card grid where [danaviewLibraryGridColumns] fits more than one
/// column, and stay one [DanaviewLibraryGroup] card (rows split by hairlines) on phones.
class DanaviewLibraryCardGrid extends StatelessWidget {
  const DanaviewLibraryCardGrid({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    // Its own layer wherever it sits (a Home column, a tab's sliver), so the rows rasterize the same
    // in every host (HOM-07/HOM-08 pixel-equality).
    return RepaintBoundary(child: _grid());
  }

  Widget _grid() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = danaviewLibraryGridColumns(constraints.maxWidth);
        if (columns == 1) return DanaviewLibraryGroup(children: children);
        return Column(
          key: const ValueKey('library-card-grid'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var start = 0; start < children.length; start += columns) ...[
              if (start > 0) const SizedBox(height: danaviewLibraryGridGap),
              DanaviewLibraryGridRow(
                columns: columns,
                children: children.sublist(start, math.min(start + columns, children.length)),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// A lazy sliver grid of [itemCount] library rows in [columns] columns (see
/// [danaviewLibraryGridColumns]); callers keep their sliver list when [columns] is 1.
Widget danaviewLibrarySliverGrid({
  required int columns,
  required int itemCount,
  required IndexedWidgetBuilder itemBuilder,
}) {
  final rows = (itemCount + columns - 1) ~/ columns;
  return SliverList.separated(
    itemCount: rows,
    separatorBuilder: (_, __) => const SizedBox(height: danaviewLibraryGridGap),
    itemBuilder: (context, row) {
      final start = row * columns;
      final end = math.min(start + columns, itemCount);
      return DanaviewLibraryGridRow(
        columns: columns,
        children: [for (var i = start; i < end; i++) itemBuilder(context, i)],
      );
    },
  );
}

/// Thin rounded watched-progress bar.
class DanaviewProgressLine extends StatelessWidget {
  const DanaviewProgressLine({
    super.key,
    required this.progress,
    this.height = 3,
    this.color = DanaviewColors.primary,
  });

  final double progress;
  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final value = progress.clamp(0.0, 1.0);
    final radius = BorderRadius.circular(height);
    return Semantics(
      label: '${(value * 100).round()}% watched',
      child: Container(
        height: height,
        decoration: BoxDecoration(color: DanaviewColors.trackBackground, borderRadius: radius),
        alignment: AlignmentDirectional.centerStart,
        child: FractionallySizedBox(
          widthFactor: value,
          heightFactor: 1,
          child: DecoratedBox(decoration: BoxDecoration(color: color, borderRadius: radius)),
        ),
      ),
    );
  }
}

/// A grouped-list row for media, folders and playlists (§8): a neutral icon tile, a 17 pt title,
/// a footnote line with an optional episode badge, an optional progress bar and a compact trailing
/// control.
class DanaviewLibraryRow extends StatelessWidget {
  const DanaviewLibraryRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.badge,
    this.progress,
    this.onTap,
    this.dimmed = false,
    this.highlighted = false,
    this.titleMaxLines = 1,
    this.subtitleMaxLines = 1,
    this.semanticLabel,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final String? badge;
  final double? progress;
  final VoidCallback? onTap;

  /// Fades the leading tile and mutes the title (e.g. a missing file); the subtitle switches to the
  /// error color so the explanation stays readable, and [trailing] stays usable.
  final bool dimmed;
  final bool highlighted;
  final int titleMaxLines;

  /// Raise for subtitles that carry instructions rather than metadata.
  final int subtitleMaxLines;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final showProgress = (progress ?? 0) > 0;
    final content = Row(
      children: [
        if (leading != null) ...[
          dimmed ? Opacity(opacity: 0.45, child: leading) : leading!,
          const SizedBox(width: DanaviewSpacing.md),
        ],
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: titleMaxLines,
                overflow: TextOverflow.ellipsis,
                // Whole-pixel line boxes (22 + 2 + 16), so rows land on the same pixel grid in
                // every host and the HOM-08 crops compare equal.
                style: DanaviewTextStyles.bodyLarge.copyWith(
                  height: 22 / 17,
                  color: dimmed ? DanaviewColors.textSecondary : DanaviewColors.textPrimary,
                ),
              ),
              if (subtitle != null || badge != null) ...[
                const SizedBox(height: 2),
                Row(
                  children: [
                    if (badge != null) ...[
                      DanaviewBadge(badge!),
                      const SizedBox(width: 6),
                    ],
                    if (subtitle != null)
                      Flexible(
                        child: Text(
                          subtitle!,
                          maxLines: subtitleMaxLines,
                          overflow: TextOverflow.ellipsis,
                          style: DanaviewTextStyles.footnote.copyWith(
                            height: 16 / 13,
                            color: dimmed ? DanaviewColors.errorLight : DanaviewColors.textSecondary,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              if (showProgress) ...[
                const SizedBox(height: DanaviewSpacing.sm),
                DanaviewProgressLine(progress: progress!),
              ],
            ],
          ),
        ),
      ],
    );

    return DanaviewPressable.builder(
      onTap: onTap,
      semanticLabel: semanticLabel,
      isButton: onTap != null,
      builder: (context, state) {
        // Owner rule: no hover or press fill; only hardware-keyboard focus tints.
        final background = state.focused
            ? DanaviewColors.hairlineSubtle
            : highlighted
                ? DanaviewColors.primarySoft
                : const Color(0x00FFFFFF);
        return AnimatedContainer(
          duration: DanaviewMotion.fast,
          curve: DanaviewMotion.curve,
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 4, 8),
          decoration: ShapeDecoration(color: background, shape: DanaviewDepth.shape(DanaviewRadius.controlAll)),
          foregroundDecoration: DanaviewDepth.focusRing(focused: state.focused),
          child: Row(
            children: [
              Expanded(child: content),
              if (trailing != null) ...[
                const SizedBox(width: DanaviewSpacing.xs),
                trailing!,
              ] else
                const SizedBox(width: 8),
            ],
          ),
        );
      },
    );
  }
}

/// Inset hairline between grouped-list rows: it starts after the 28 pt icon tile (12 + 28 + 12).
class DanaviewRowDivider extends StatelessWidget {
  const DanaviewRowDivider({super.key, this.indent = 52});

  final double indent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsetsDirectional.only(start: indent),
      child: const SizedBox(
        height: DanaviewBorders.width,
        child: ColoredBox(color: DanaviewColors.divider),
      ),
    );
  }
}

/// A §8 grouped list of library rows: one `surface` card, radius 12, rows split by inset dividers.
class DanaviewLibraryGroup extends StatelessWidget {
  const DanaviewLibraryGroup({super.key, required this.children, this.dividers = true});

  final List<Widget> children;
  final bool dividers;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: DanaviewDepth.card(borderRadius: DanaviewRadius.controlAll, shadows: DanaviewShadows.none),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (dividers && i > 0) const DanaviewRowDivider(),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// A compact explanatory state that sits inside a section instead of a list (§8 empty state:
/// a neutral icon tile, a 17/600 title, a 15/400 body and one secondary action).
class DanaviewInlineEmpty extends StatelessWidget {
  const DanaviewInlineEmpty({
    super.key,
    this.icon,
    this.glyph,
    required this.title,
    this.message,
    this.action,
    this.iconColor = DanaviewColors.textPrimary,
  }) : assert(icon != null || glyph != null, 'Pass an icon or a glyph');

  final IconData? icon;

  /// Drawn instead of [icon] when set.
  final DanaviewGlyphKind? glyph;
  final String title;
  final String? message;
  final Widget? action;

  /// The glyph colour: white by default; status icons (an error) pass their status colour.
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return DanaviewSurface(
      color: DanaviewColors.surface,
      borderRadius: DanaviewRadius.controlAll,
      padding: const EdgeInsets.all(DanaviewSpacing.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (glyph != null)
            DanaviewIconTile.glyph(glyph!, color: iconColor, size: 40)
          else
            DanaviewIconTile(icon!, color: iconColor, size: 40),
          const SizedBox(width: DanaviewSpacing.md),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 2),
                Text(title, style: DanaviewTextStyles.rowTitle),
                if (message != null) ...[
                  const SizedBox(height: 4),
                  Text(message!, style: DanaviewTextStyles.subhead),
                ],
                if (action != null) ...[
                  const SizedBox(height: DanaviewSpacing.md),
                  action!,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Opaque top bar for pushed library screens: back, title with an optional subtitle, actions.
/// Library page chrome: an opaque area behind the status bar (and the pinned [topBar]) that [body]
/// scrolls under, so content never looks cut off at the clock; a hairline marks the edge once scrolled.
class DanaviewLibraryFrame extends StatefulWidget {
  const DanaviewLibraryFrame({super.key, this.topBar, required this.body});

  final Widget? topBar;
  final Widget body;

  @override
  State<DanaviewLibraryFrame> createState() => _DanaviewLibraryFrameState();
}

class _DanaviewLibraryFrameState extends State<DanaviewLibraryFrame> {
  bool _scrolled = false;

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth == 0 && notification.metrics.axis == Axis.vertical) {
      final scrolled = notification.metrics.pixels > notification.metrics.minScrollExtent;
      if (scrolled != _scrolled) setState(() => _scrolled = scrolled);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final edge = _scrolled
        ? DanaviewColors.hairline
        : widget.topBar != null
            ? DanaviewColors.hairlineSubtle
            : DanaviewColors.hairline.withValues(alpha: 0);
    return Column(
      children: [
        // The window has no native title bar on desktop; this one drags it and holds its buttons.
        if (PlatformBridge.isDesktop && !context.isTouchPlatform) const DanaviewTitleBar(),
        DecoratedBox(
          decoration: BoxDecoration(
            color: DanaviewColors.background,
            border: Border(bottom: BorderSide(color: edge, width: DanaviewBorders.width)),
          ),
          child: SafeArea(bottom: false, child: widget.topBar ?? const SizedBox(width: double.infinity)),
        ),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: SafeArea(
              top: false,
              bottom: false,
              child: NotificationListener<ScrollNotification>(onNotification: _onScroll, child: widget.body),
            ),
          ),
        ),
      ],
    );
  }
}

class DanaviewLibraryTopBar extends StatelessWidget {
  const DanaviewLibraryTopBar({
    super.key,
    required this.title,
    this.subtitle,
    this.onBack,
    this.actions = const [],
  });

  final String title;
  final String? subtitle;
  final VoidCallback? onBack;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final insets = danaviewLibraryInsets(constraints.maxWidth);
        return Padding(
          padding: EdgeInsets.fromLTRB(
            math.max(4.0, insets.left - 12),
            6,
            math.max(4.0, insets.right - 8),
            6,
          ),
          child: Row(
            children: [
              if (onBack != null)
                DanaviewIconButton(
                  icon: Icons.arrow_back_ios_new_rounded,
                  iconSize: 18,
                  tooltip: 'Back',
                  onPressed: onBack,
                )
              else
                const SizedBox(width: 12),
              const SizedBox(width: DanaviewSpacing.xs),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: DanaviewTextStyles.title,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: DanaviewTextStyles.caption,
                      ),
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

/// Section title with an optional compact action (capped at half the width). [prominent]
/// gives the §6 `sectionHeader` style of Home and the tabs (20/700 white, 24 above, 8 below);
/// otherwise it is the quiet list-header style.
class DanaviewLibrarySectionHeader extends StatelessWidget {
  const DanaviewLibrarySectionHeader(
    this.title, {
    super.key,
    this.action,
    this.topSpacing = DanaviewSpacing.xl,
    this.prominent = false,
  });

  final String title;
  final Widget? action;
  final double topSpacing;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    if (!prominent) {
      return DanaviewSectionHeader(
        title,
        action: action,
        padding: EdgeInsets.fromLTRB(4, topSpacing, 0, DanaviewSpacing.sm),
      );
    }
    return DanaviewSectionHeader.large(
      title,
      action: action,
      padding: EdgeInsets.fromLTRB(0, topSpacing, 0, DanaviewSpacing.sm),
    );
  }
}

/// Calls [onReturn] when the route becomes visible again after a page on top of it was
/// popped, and when the app comes back to the foreground.
class DanaviewRefreshOnReturn extends StatefulWidget {
  const DanaviewRefreshOnReturn({super.key, required this.onReturn, required this.child});

  final VoidCallback onReturn;
  final Widget child;

  @override
  State<DanaviewRefreshOnReturn> createState() => _DanaviewRefreshOnReturnState();
}

class _DanaviewRefreshOnReturnState extends State<DanaviewRefreshOnReturn> with WidgetsBindingObserver {
  Animation<double>? _secondary;
  bool _covered = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = ModalRoute.of(context)?.secondaryAnimation;
    if (next == _secondary) return;
    _secondary?.removeStatusListener(_onSecondaryStatus);
    _secondary = next?..addStatusListener(_onSecondaryStatus);
  }

  void _onSecondaryStatus(AnimationStatus status) {
    if (status == AnimationStatus.forward || status == AnimationStatus.completed) {
      _covered = true;
    } else if (status == AnimationStatus.dismissed && _covered) {
      _covered = false;
      widget.onReturn();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) widget.onReturn();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _secondary?.removeStatusListener(_onSecondaryStatus);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
