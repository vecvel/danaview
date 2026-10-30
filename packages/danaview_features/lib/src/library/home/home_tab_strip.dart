// OWNER: HOM-05
// EXTENDED: Home four tabs (no pill is selected while the filter shows every file)
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

/// The tab strip of the Files & Media Home (DESIGN_SYSTEM §10.2): capsule pills that scroll sideways.
class HomeTabStrip extends StatefulWidget {
  /// A strip of [tabs] with [selected] highlighted (none while null, the filter's "Show: All"
  /// view); [onSelected] gets the tapped or keyed tab.
  const HomeTabStrip({
    super.key,
    required this.tabs,
    required this.selected,
    required this.onSelected,
    this.padding = EdgeInsets.zero,
  });

  /// The visible tabs, in order.
  final List<HomeTab> tabs;

  /// The current tab, or null when the Home shows a view that is no tab (every file).
  final HomeTab? selected;

  /// Called with the tab the user picked.
  final ValueChanged<HomeTab> onSelected;

  /// Space around the row inside the scroll view (the screen's gutters).
  final EdgeInsets padding;

  /// The smallest hit height of a tab (an invisible minimum; the strip grows with the text).
  static const double minTargetHeight = DanaviewSpacing.minTapTarget;

  /// Space above and below the pills.
  static const double verticalPadding = DanaviewSpacing.sm;

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
    if (widget.selected case final selected?) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(selected, animate: false));
    }
  }

  @override
  void didUpdateWidget(HomeTabStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected && widget.selected != null) {
      final selected = widget.selected!;
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(selected, animate: true));
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
    if (tabs.isEmpty) return KeyEventResult.ignored;
    // With no selected tab (every file shown) the keys start from the focused pill.
    final focused = tabs.indexWhere((tab) => _focus[tab]?.hasFocus ?? false);
    final current = widget.selected == null ? focused : tabs.indexOf(widget.selected!);
    if (current < 0) return KeyEventResult.ignored;
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
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: HomeTabStrip.verticalPadding),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: widget.padding,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                for (var i = 0; i < widget.tabs.length; i++) ...[
                  if (i > 0) const SizedBox(width: DanaviewSpacing.sm),
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
        builder: (context, state) {
          // The §8 tab pill (DanaviewTabPill's look): a capsule sized to its label, padding
          // 13 x 6; selected is `primary` with a white 600 label, a 12 % hairline and an 18 % top
          // highlight; idle is raised `surfaceElevated` with a `textSecondary` label. Keyboard
          // focus draws the focus ring only; no hover or press tint (owner rule). The hit area
          // is at least 44 px high (an invisible minimum), so the strip grows with the text.
          return ConstrainedBox(
            constraints: const BoxConstraints(minHeight: HomeTabStrip.minTargetHeight),
            child: Center(
              widthFactor: 1,
              heightFactor: 1,
              child: AnimatedContainer(
                duration: DanaviewMotion.fast,
                curve: DanaviewMotion.curve,
                constraints: const BoxConstraints(minHeight: 32),
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
                alignment: Alignment.center,
                decoration: ShapeDecoration(
                  color: fill,
                  shape: DanaviewDepthBorder(
                    borderRadius: DanaviewRadius.capsuleAll,
                    side: selected ? DanaviewBorders.bright : DanaviewBorders.hairline,
                    highlight: selected ? DanaviewColors.highlightStrong : DanaviewColors.highlight,
                  ),
                ),
                foregroundDecoration: DanaviewDepth.focusRing(
                  focused: state.focused,
                  borderRadius: DanaviewRadius.capsuleAll,
                ),
                child: ExcludeSemantics(
                  child: Text(
                    tab.label,
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(
                      fontSize: 15,
                      color: fg,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
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
