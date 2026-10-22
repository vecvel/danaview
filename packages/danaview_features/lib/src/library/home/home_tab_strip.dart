// OWNER: HOM-05
//
// The Home's tab strip (ARCH v1.2 V2-101, §1.4): a row of pill tabs built from kit primitives
// (DanaviewPressable, kit colours and Figtree through the kit theme; no Material tab chrome). It
// scrolls sideways when the tabs don't fit, so nothing overflows from 280 px at text scale 1.35;
// every tab is a ≥ 44 px target with a semantics label and selected state; Tab moves focus,
// Enter/Space select (DanaviewPressable), and Left/Right (or Home/End) move the selection along
// the strip and keep the selected tab in view.

import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'home_tabs.dart';

/// The key of the tab of [tab] in the strip.
ValueKey<String> homeTabKey(HomeTab tab) => ValueKey('home-tab-${tab.name}');

/// Colours of the strip's pills; the foregrounds are computed against their fills (ARCH §1.4).
abstract final class HomeTabStripColors {
  /// The selected pill's fill.
  static const Color selectedFill = DanaviewColors.primary;

  /// The selected label: whichever of white or near-black contrasts more with [selectedFill].
  static Color get selectedForeground => DanaviewColors.foregroundOn(selectedFill);

  /// The unselected pill's fill (drawn over the screen background).
  static const Color idleFill = DanaviewColors.surfaceElevated;

  /// The unselected label.
  static const Color idleForeground = DanaviewColors.textSecondary;
}

/// The tab strip of the Files & Media Home.
class HomeTabStrip extends StatefulWidget {
  /// A strip of [tabs] with [selected] highlighted; [onSelected] gets the tapped or keyed tab.
  const HomeTabStrip({
    super.key,
    required this.tabs,
    required this.selected,
    required this.onSelected,
    this.padding = EdgeInsets.zero,
  });

  /// The visible tabs, in order.
  final List<HomeTab> tabs;

  /// The current tab.
  final HomeTab selected;

  /// Called with the tab the user picked.
  final ValueChanged<HomeTab> onSelected;

  /// Space around the row inside the scroll view (the screen's gutters).
  final EdgeInsets padding;

  /// The strip's height: one 44 px target row.
  static const double height = DanaviewSpacing.minTapTarget;

  @override
  State<HomeTabStrip> createState() => _HomeTabStripState();
}

class _HomeTabStripState extends State<HomeTabStrip> {
  final Map<HomeTab, GlobalKey> _keys = {};
  final Map<HomeTab, FocusNode> _focus = {};

  GlobalKey _keyOf(HomeTab tab) => _keys.putIfAbsent(tab, GlobalKey.new);

  FocusNode _focusOf(HomeTab tab) => _focus.putIfAbsent(tab, () => FocusNode(debugLabel: 'home-tab-${tab.name}'));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(widget.selected, animate: false));
  }

  @override
  void didUpdateWidget(HomeTabStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(widget.selected, animate: true));
    }
  }

  @override
  void dispose() {
    for (final node in _focus.values) {
      node.dispose();
    }
    super.dispose();
  }

  void _reveal(HomeTab tab, {required bool animate}) {
    if (!mounted) return;
    final context = _keys[tab]?.currentContext;
    if (context == null) return;
    Scrollable.ensureVisible(
      context,
      alignment: 0.5,
      duration: animate ? DanaviewMotion.normal : Duration.zero,
      curve: DanaviewMotion.curve,
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final tabs = widget.tabs;
    final current = tabs.indexOf(widget.selected);
    if (current < 0 || tabs.isEmpty) return KeyEventResult.ignored;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final key = event.logicalKey;
    final int target;
    if (key == LogicalKeyboardKey.arrowRight) {
      target = rtl ? current - 1 : current + 1;
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      target = rtl ? current + 1 : current - 1;
    } else if (key == LogicalKeyboardKey.home) {
      target = 0;
    } else if (key == LogicalKeyboardKey.end) {
      target = tabs.length - 1;
    } else {
      return KeyEventResult.ignored;
    }
    if (target < 0 || target >= tabs.length) return KeyEventResult.handled;
    final next = tabs[target];
    _focusOf(next).requestFocus();
    if (next != widget.selected) widget.onSelected(next);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: 'Home sections',
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onKey,
        child: SizedBox(
          height: HomeTabStrip.height,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: widget.padding,
            child: Row(
              children: [
                for (var i = 0; i < widget.tabs.length; i++) ...[
                  if (i > 0) const SizedBox(width: DanaviewSpacing.xs + 2),
                  _HomeTabPill(
                    key: _keyOf(widget.tabs[i]),
                    tab: widget.tabs[i],
                    index: i,
                    count: widget.tabs.length,
                    selected: widget.tabs[i] == widget.selected,
                    focusNode: _focusOf(widget.tabs[i]),
                    onTap: () => widget.onSelected(widget.tabs[i]),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeTabPill extends StatelessWidget {
  const _HomeTabPill({
    super.key,
    required this.tab,
    required this.index,
    required this.count,
    required this.selected,
    required this.focusNode,
    required this.onTap,
  });

  final HomeTab tab;
  final int index;
  final int count;
  final bool selected;
  final FocusNode focusNode;
  final VoidCallback onTap;

  static const double _pillHeight = 36;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? HomeTabStripColors.selectedForeground : HomeTabStripColors.idleForeground;
    final fill = selected ? HomeTabStripColors.selectedFill : HomeTabStripColors.idleFill;
    return KeyedSubtree(
      key: homeTabKey(tab),
      child: DanaviewPressable.builder(
        onTap: onTap,
        focusNode: focusNode,
        selected: selected,
        semanticLabel: '${tab.label} tab, ${index + 1} of $count',
        pressedScale: 0.97,
        builder: (context, state) {
          final overlay = state.focused
              ? DanaviewColors.primarySoft
              : state.hovered || state.pressed
                  ? DanaviewColors.hover
                  : DanaviewColors.hover.withValues(alpha: 0);
          // The full strip height is the hit area (≥ 44 px); the pill is drawn inside it.
          return SizedBox(
            height: HomeTabStrip.height,
            child: Center(
              child: AnimatedContainer(
                duration: DanaviewMotion.fast,
                curve: DanaviewMotion.curve,
                constraints: const BoxConstraints(minHeight: _pillHeight, minWidth: 56),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                alignment: Alignment.center,
                decoration: BoxDecoration(color: fill, borderRadius: DanaviewRadius.xlAll),
                foregroundDecoration: BoxDecoration(
                  color: selected ? null : overlay,
                  borderRadius: DanaviewRadius.xlAll,
                  border: Border.fromBorderSide(
                    state.focused
                        ? DanaviewBorders.focus.copyWith(width: 2, color: DanaviewColors.primaryLight)
                        : selected
                            ? DanaviewBorders.hairline.copyWith(color: Colors.transparent)
                            : DanaviewBorders.hairline,
                  ),
                ),
                child: ExcludeSemantics(
                  child: Text(
                    tab.label,
                    maxLines: 1,
                    softWrap: false,
                    style: DanaviewTextStyles.label.copyWith(
                      color: fg,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                      height: 1.2,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
