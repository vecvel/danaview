// The Home's chrome (DESIGN_SYSTEM §10.1, §10.5): the top bar (logo tile, the "Danaview" large
// title and the round toolbar buttons), the search row (search field and the square filter
// button, equal heights) and, on compact widths, the phone tab bar (Library · Editor ·
// AI Studio · More). Kit tokens only; every icon-only control has a tooltip and a semantics label,
// and every target is at least 44 pt.

import 'dart:math' as math;

import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';

/// Whether the Home at [width] is a phone layout: the top bar keeps only Import, and the editor
/// and settings move to the bottom tab bar (§10.5).
bool homeIsCompact(double width) => DanaviewBreakpoints.isCompactWidth(width);

/// The labels and keys of the Home chrome (tests and the app read them).
abstract final class HomeChromeLabels {
  /// The Import (+) button's tooltip and semantics label.
  static const String import = 'Import';

  /// The Import menu item that opens the import sheet (Files Home only).
  static const String importToLibrary = 'Import to Danaview…';

  /// The filter button's tooltip.
  static const String filter = 'Filter';

  /// The video editor button's tooltip.
  static const String editor = 'Video editor';

  /// The video editor button's semantics label.
  static const String editorSemantics = 'Open video editor';

  /// The settings button's tooltip.
  static const String settings = 'Settings';
}

/// The scroll distance over which the large title collapses into the inline title (§10.1).
const double homeTitleCollapseDistance = 44;

/// The inline (collapsed) title's size: iOS's 17 pt navigation-bar title.
const double homeInlineTitleSize = 17;

/// How far the title has collapsed for a scroll [offset] past the top: 0 (large) to 1 (inline).
/// With Reduce Motion ([reduceMotion]) there is no in-between: any scroll shows the end state.
double homeTitleCollapseFor(double offset, {bool reduceMotion = false}) {
  if (!offset.isFinite || offset <= 0) return 0;
  if (reduceMotion) return 1;
  return (offset / homeTitleCollapseDistance).clamp(0.0, 1.0);
}

/// The top bar's row height: the toolbar buttons (a 44 pt target on touch, the 34 pt circle with
/// a pointer), or the large title's line when the text scale makes it taller.
double homeTopBarRowHeight(BuildContext context) => math.max(
      context.isTouchPlatform ? DanaviewSpacing.minTapTarget : DanaviewIconButton.toolbarSize,
      MediaQuery.textScalerOf(context).scale(DanaviewTextStyles.largeTitle.fontSize!) * DanaviewTextStyles.largeTitle.height!,
    );

/// The Home's top bar row: the logo tile, "Danaview" and the trailing [actions].
///
/// [collapse] (0 to 1) morphs the large title into the inline title iOS shows once the content
/// scrolls (§10.1): the title shrinks from 30 pt to 17 pt in place and the logo tile from 28/32 pt
/// to 22 pt. Both are paint-only transforms, so a scroll frame neither lays out the text again nor
/// moves the buttons; the row keeps its height. The title stays one "Danaview" header for screen
/// readers whatever the collapse.
class HomeTopBar extends StatelessWidget {
  /// A bar with [actions] (toolbar circles) at the end.
  const HomeTopBar({super.key, required this.actions, required this.compact, this.collapse = 0});

  /// The round buttons, in order.
  final List<Widget> actions;

  /// Phone layout: a 28 pt logo tile (32 pt otherwise).
  final bool compact;

  /// 0 shows the large title, 1 the inline title.
  final double collapse;

  @override
  Widget build(BuildContext context) {
    final t = collapse.clamp(0.0, 1.0);
    final logo = compact ? 28.0 : 32.0;
    final logoScale = 1 - t * (1 - 22 / logo);
    final titleScale = 1 - t * (1 - homeInlineTitleSize / DanaviewTextStyles.largeTitle.fontSize!);
    return SizedBox(
      height: homeTopBarRowHeight(context),
      child: Row(
        children: [
          Transform.scale(
            key: const ValueKey('home-title-logo'),
            scale: logoScale,
            alignment: AlignmentDirectional.centerStart,
            child: DanaviewLogo(size: logo),
          ),
          const SizedBox(width: DanaviewSpacing.sm),
          Expanded(
            child: Transform.translate(
              // The shrunken logo leaves room: the inline title follows it.
              offset: Offset(logo * (logoScale - 1) * (Directionality.of(context) == TextDirection.rtl ? -1 : 1), 0),
              child: Transform.scale(
                key: const ValueKey('home-title'),
                scale: titleScale,
                alignment: AlignmentDirectional.centerStart,
                child: Semantics(
                  header: true,
                  child: Text(
                    'Danaview',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DanaviewTextStyles.largeTitle,
                  ),
                ),
              ),
            ),
          ),
          // Fixed-size buttons: the title ellipsizes first.
          for (final action in actions) ...[
            const SizedBox(width: DanaviewSpacing.sm),
            action,
          ],
        ],
      ),
    );
  }
}

/// The Import (+) toolbar circle: an accent glyph that opens [entries] (Open file, Open folder,
/// Open link, New playlist, Add folder and, with the Files Home, Import to Danaview…).
class HomeImportButton extends StatelessWidget {
  /// The button; [entries] are the menu's rows.
  const HomeImportButton({super.key, required this.entries});

  /// The menu.
  final List<DanaviewMenuEntry> entries;

  @override
  Widget build(BuildContext context) {
    return DanaviewMenuAnchor(
      entries: entries,
      width: 240,
      alignment: DanaviewMenuAlignment.end,
      builder: (context, open, isOpen) => DanaviewIconButton.toolbar(
        key: const ValueKey('home-import'),
        icon: Icons.add_rounded,
        accent: true,
        tooltip: HomeChromeLabels.import,
        semanticLabel: HomeChromeLabels.import,
        selected: isOpen,
        onPressed: open,
      ),
    );
  }
}

/// The search field's height at the current text scale (its line plus padding), at least
/// [DanaviewSpacing.controlHeight]: the filter button matches it.
double homeSearchFieldHeight(BuildContext context) => math.max(
      DanaviewSpacing.controlHeight,
      MediaQuery.textScalerOf(context).scale(15) * 1.3 + 2 * DanaviewSpacing.md,
    );

/// The search row under the title: [search] takes all the width the square [filter] button
/// leaves; both are the same height. Search hits open under the field.
class HomeSearchRow extends StatelessWidget {
  /// A row of [search] and [filter].
  const HomeSearchRow({super.key, required this.search, required this.filter});

  /// The search field (and its hits).
  final Widget search;

  /// The filter button.
  final Widget filter;

  @override
  Widget build(BuildContext context) {
    final height = homeSearchFieldHeight(context);
    return Row(
      // The hits open below the field; the filter button stays level with the field.
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: search),
        const SizedBox(width: DanaviewSpacing.sm),
        SizedBox(width: height, height: height, child: filter),
      ],
    );
  }
}

/// The square filter button (§8): radius 12, a `tune` glyph, raised like a field. It opens the
/// type menu ([entries]), never an inline dropdown.
class HomeFilterButton extends StatelessWidget {
  /// The button; [entries] are the menu's rows, [active] marks a filter other than Home.
  const HomeFilterButton({super.key, required this.entries, this.active = false, this.semanticLabel});

  /// The menu.
  final List<DanaviewMenuEntry> entries;

  /// A filter is applied: the glyph turns `primaryLight`.
  final bool active;

  /// The spoken label (defaults to the tooltip).
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return DanaviewMenuAnchor(
      entries: entries,
      width: 220,
      alignment: DanaviewMenuAlignment.end,
      builder: (context, open, isOpen) => DanaviewPressable.builder(
        key: const ValueKey('home-filter'),
        onTap: open,
        tooltip: HomeChromeLabels.filter,
        semanticLabel: semanticLabel ?? HomeChromeLabels.filter,
        builder: (context, state) => AnimatedContainer(
          duration: DanaviewMotion.fast,
          curve: DanaviewMotion.curve,
          alignment: Alignment.center,
          decoration: DanaviewDepth.raised(),
          foregroundDecoration: DanaviewDepth.focusRing(focused: state.focused),
          child: Icon(
            Icons.tune_rounded,
            size: 20,
            color: active || isOpen ? DanaviewColors.primaryLight : DanaviewColors.textPrimary,
          ),
        ),
      ),
    );
  }
}

/// One item of the phone tab bar.
@immutable
class HomeTabBarItem {
  /// An item labelled [label] with [icon]; [onTap] navigates.
  const HomeTabBarItem({
    required this.label,
    required this.icon,
    required this.onTap,
    this.selected = false,
    this.tooltip,
    this.semanticLabel,
    this.key,
  });

  /// The visible label.
  final String label;

  /// The 20 pt glyph.
  final IconData icon;

  /// Opens the destination.
  final VoidCallback onTap;

  /// The current destination (Library on the Home).
  final bool selected;

  /// The pointer tooltip (defaults to none).
  final String? tooltip;

  /// The spoken label (defaults to [label]).
  final String? semanticLabel;

  /// The item's key.
  final Key? key;
}

/// The phone tab bar (§8, §10.5): `surface` at 92 % with a 7 % top hairline, 20 pt glyphs and
/// 11 pt labels; the selected item is `primaryLight`, idle items `tabIdle`.
class HomePhoneTabBar extends StatelessWidget {
  /// A bar of [items].
  const HomePhoneTabBar({super.key, required this.items});

  /// The items, in order.
  final List<HomeTabBarItem> items;

  /// The bar's height above the bottom safe area.
  static const double height = 50;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: 'Tab bar',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: DanaviewColors.surface.withValues(alpha: 0.92),
          border: const Border(top: BorderSide(color: DanaviewColors.hairline, width: DanaviewBorders.width)),
        ),
        child: SafeArea(
          top: false,
          // Sized to its items (at least [height]); the Scaffold slot's constraints are loose.
          child: IntrinsicHeight(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: height),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [for (final item in items) Expanded(child: _TabBarButton(item: item))],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TabBarButton extends StatelessWidget {
  const _TabBarButton({required this.item});

  final HomeTabBarItem item;

  @override
  Widget build(BuildContext context) {
    final color = item.selected ? DanaviewColors.primaryLight : DanaviewColors.tabIdle;
    return DanaviewPressable.builder(
      key: item.key,
      onTap: item.onTap,
      tooltip: item.tooltip,
      selected: item.selected,
      semanticLabel: item.semanticLabel ?? item.label,
      builder: (context, state) => Container(
        constraints: const BoxConstraints(minHeight: DanaviewSpacing.minTapTarget),
        padding: const EdgeInsets.only(top: 6, bottom: 4),
        foregroundDecoration: DanaviewDepth.focusRing(focused: state.focused),
        child: ExcludeSemantics(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(item.icon, size: 20, color: color),
              const SizedBox(height: 2),
              Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: DanaviewTextStyles.tabLabel.copyWith(color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
